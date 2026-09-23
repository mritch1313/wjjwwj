class_name VehicleController
extends RigidBody3D

## The car: a RigidBody3D driven by four raycast wheels (no VehicleBody3D, no
## transform teleporting).
##
## Why a hand written model instead of VehicleBody3D / VehicleWheel:
##   * VehicleWheel is a black box - no wheelspin, no lock-up, no load transfer
##     tuning, and its arcade "grip" makes a 1.4 t car feel like a toy,
##   * here every number that matters (spring, damper, Pacejka, friction circle,
##     engine curve, gearbox) lives in VehicleConfig and can be unit tested,
##   * the same controller drives the player car and every police car, so the
##     pursuit is fair by construction: police cars use the same physics with a
##     config that is at most 1% faster.
##
## Physics happens only through forces:
##   spring/damper + tyre forces at the contact points, engine torque through the
##   wheels, aero drag and downforce, nitro thrust.  The only place the transform
##   is written is `reset_car()`, an explicit respawn requested by the game flow
##   (falling out of the world, stuck against scenery, user "reset" button).

signal session_surface_changed(surface: int)
signal collision_impact(speed_ms: float, surface: int)
signal nitro_used()
signal gear_shifted(gear: int)
signal wheelspin_started()
signal locked_up()
signal drifted(drift_angle_deg: float, speed_kmh: float)
signal airtime_started()
signal landed(impact_speed_ms: float)
signal reset_done(position: Vector3)

const WHEEL_COUNT := 4
const GROUND_MASK := 1  # physics layer "world"

var config: VehicleConfig
## Marker used by the model factory and by the gameplay rules.
var vehicle_role: int = VehicleModelFactory.Role.CIVILIAN
## True only for the car the human drives (the police AI never sets it).
var is_player_vehicle: bool = false
var input: VehicleInput = VehicleInput.new()
var nitro: NitroSystem
var wheels: Array[WheelSystem] = []

## Optional world interface: `surface_provider(x, z, height) -> Surface.Type`.
## Colour used when the car has no external scene: the player repaints the car
## from the menu, so the value is stored here and re-applied on rebuild.
var paint_override: Color = Color(0.0, 0.0, 0.0, 0.0)

var surface_provider: Callable = Callable()
## Optional road interface: `road_provider(position) -> Vector3` (nearest road point).
var road_provider: Callable = Callable()

var engine_rpm: float = 0.0
var gear: int = 1
var gear_ratio: float = 0.0
var shift_timer: float = 0.0
var steer_angle: float = 0.0
var throttle_smoothed: float = 0.0
var brake_smoothed: float = 0.0
var current_surface: int = Surface.Type.ASPHALT
var drift_angle_deg: float = 0.0
var drift_time_s: float = 0.0
var airtime_s: float = 0.0
var grounded_wheels: int = 0
var wheelspin: bool = false
var abs_active: bool = false
var total_distance_m: float = 0.0
var odometer_start: Vector3 = Vector3.ZERO
var _last_forward_speed: float = 0.0
var _visual_root: Node3D = null
var _body_mesh: MeshInstance3D = null
var _wheel_visuals: Array[Node3D] = []
var _previous_forward: bool = true
var _previous_surface: int = Surface.Type.ASPHALT
var _recovering: bool = false
var _visual_scene_path: String = ""


func _ready() -> void:
	if config == null:
		config = Config.vehicle_player
	mass = config.mass_kg
	center_of_mass_mode = RigidBody3D.CENTER_OF_MASS_MODE_CUSTOM
	center_of_mass = config.center_of_mass_offset
	linear_damp = 0.0
	angular_damp = config.angular_damping
	continuous_cd = true
	contact_monitor = true
	max_contacts_reported = 6
	collision_layer = 1 << 2  # "player_car" by default; PoliceCarFactory changes it
	collision_mask = GROUND_MASK | (1 << 4)
	can_sleep = false
	_setup_collision()
	_setup_wheels()
	_build_body_mesh()
	_build_wheel_visuals()
	_setup_nitro()
	if odometer_start == Vector3.ZERO:
		odometer_start = global_position
	body_entered.connect(_on_body_entered)


func _setup_collision() -> void:
	for child in get_children():
		if child is CollisionShape3D:
			child.queue_free()
	var shape := BoxShape3D.new()
	shape.size = config.body_size
	var node := CollisionShape3D.new()
	node.name = "BodyCollision"
	node.shape = shape
	node.position = Vector3(0.0, config.body_size.y * 0.5 - config.suspension_rest_length_m - config.wheel_radius_m, 0.0)
	add_child(node)


func _setup_wheels() -> void:
	wheels.clear()
	var positions := config.wheel_positions()
	for index in range(WHEEL_COUNT):
		var wheel := WheelSystem.new()
		wheel.setup(config, index, positions[index], config.wheel_radius_m)
		wheels.append(wheel)
	gear_ratio = config.gear_ratios[0]


func _setup_nitro() -> void:
	nitro = NitroSystem.new(config)
	nitro.activated.connect(func() -> void: nitro_used.emit())


func set_surface_provider(provider: Callable) -> void:
	surface_provider = provider


func set_road_provider(provider: Callable) -> void:
	road_provider = provider


## The AI writes into the same VehicleInput the touch controls feed.
func vehicle_input() -> VehicleInput:
	return input


## ------------------------------------------------------------------- physics
func _physics_process(delta: float) -> void:
	if _recovering or freeze:
		return
	_update_steering(delta)
	_update_gearbox(delta)
	var space := get_world_3d().direct_space_state
	var body_transform := global_transform
	var up := body_transform.basis.y.normalized()
	var forward := forward_direction()
	var velocity := linear_velocity
	grounded_wheels = 0
	var spin_count := 0
	var lock_count := 0
	for wheel in wheels:
		wheel.update_suspension(space, body_transform, velocity, angular_velocity, get_rid(), GROUND_MASK, delta)
		if not wheel.on_ground:
			continue
		grounded_wheels += 1
		# --- surface under this wheel drives the available grip
		var surface := current_surface
		if surface_provider.is_valid():
			surface = int(surface_provider.call(wheel.contact_point.x, wheel.contact_point.z, wheel.contact_point.y))
		wheel.set_surface(surface, Config.surfaces.friction_of(surface))
		# --- wheel axes (steered for the front wheels)
		var steer := wheel.steer_angle
		var wheel_forward := forward.rotated(up, -steer)
		var wheel_right := wheel_forward.cross(up).normalized()
		# --- wheel owns the drive torque
		wheel.drive_torque = _wheel_drive_torque(wheel)
		wheel.brake_torque = _wheel_brake_torque(wheel)
		wheel.handbrake = _rear_handbrake(wheel)
		# --- velocity at the contact point (includes yaw/pitch motion)
		var contact_offset := wheel.contact_point - global_position
		var contact_velocity := velocity + angular_velocity.cross(contact_offset)
		var tyre := wheel.compute_tyre_force(
			contact_velocity, wheel_forward, wheel_right, delta, input.use_abs, input.use_tcs
		)
		if wheel.on_ground and wheel.load > 0.0:
			apply_force(up * wheel.load, contact_offset)
			apply_force(tyre["force"], contact_offset)
		if wheel.is_spinning:
			spin_count += 1
		if wheel.is_locked:
			lock_count += 1
	_update_anti_roll(delta)
	_apply_aerodynamics(forward)
	_apply_nitro_thrust(forward, delta)
	_update_engine_state(delta)
	_update_visuals(delta)
	_update_state(delta, forward)


## ---------------------------------------------- engine, gearbox, drive torque
func _update_gearbox(delta: float) -> void:
	if shift_timer > 0.0:
		shift_timer = maxf(shift_timer - delta, 0.0)
	var reversing := is_reversing()
	var forward_speed := absf(forward_speed_ms())
	engine_rpm = _compute_rpm(forward_speed, reversing)
	if shift_timer > 0.0:
		return
	var gears := config.gear_ratios.size()
	if reversing:
		if gear != -1:
			gear = -1
			gear_shifted.emit(gear)
		gear_ratio = config.gear_ratios[0]
		return
	if gear <= 0:
		gear = 1
		gear_shifted.emit(gear)
	# --- automatic gearbox: shift by rpm fraction of the redline
	var ratio := engine_rpm / maxf(config.redline_rpm, 1.0)
	if ratio > config.shift_up_fraction and gear < gears:
		gear += 1
		shift_timer = config.shift_time_s
		gear_shifted.emit(gear)
	elif ratio < config.shift_down_fraction and gear > 1:
		gear -= 1
		shift_timer = config.shift_time_s
		gear_shifted.emit(gear)
	gear_ratio = config.gear_ratios[clampi(gear - 1, 0, gears - 1)]


func _compute_rpm(forward_speed: float, reversing: bool) -> float:
	# rpm follows the driven wheels through the current gear
	var driven := 0
	var omega := 0.0
	for wheel in wheels:
		if config.is_wheel_driven(wheel.index):
			driven += 1
			omega += absf(wheel.angular_velocity)
	if driven == 0:
		return config.idle_rpm
	omega /= float(driven)
	var wheel_rpm := omega * 60.0 / TAU
	var ratio := gear_ratio if gear_ratio > 0.0 else config.gear_ratios[0]
	var rpm := wheel_rpm * ratio * config.final_drive
	if reversing:
		rpm *= 1.6
	# the clutch keeps the engine above idle while the car is slow
	rpm = maxf(rpm, config.idle_rpm)
	return clampf(rpm, config.idle_rpm, config.redline_rpm * 1.02)


func _wheel_drive_torque(wheel: WheelSystem) -> float:
	if not config.is_wheel_driven(wheel.index):
		return 0.0
	if shift_timer > 0.0:
		return 0.0  # clutch out during a gear change
	var throttle := throttle_smoothed
	if is_reversing():
		throttle = maxf(throttle, brake_smoothed)
	if throttle <= 0.001:
		return -engine_braking(wheel) * signf(wheel.angular_velocity)
	var driven := 0
	for candidate in wheels:
		if config.is_wheel_driven(candidate.index):
			driven += 1
	var torque := VehicleController.engine_torque_at(engine_rpm, config, throttle)
	var wheel_torque := torque * gear_ratio * config.final_drive * 0.92
	if is_reversing():
		wheel_torque = -wheel_torque * 0.7
	return wheel_torque / float(maxi(driven, 1))


## Engine braking: a small torque that slows the driven wheels when off throttle.
func engine_braking(_wheel: WheelSystem) -> float:
	return config.engine_braking_torque_nm * gear_ratio * config.differential_lock


func _wheel_brake_torque(wheel: WheelSystem) -> float:
	if shift_timer > 0.0:
		return 0.0
	var pedal := brake_smoothed
	if is_reversing():
		pedal = 0.0
	return config.brake_torque_nm * pedal * 0.5  # per wheel, front/rear split is even


func _rear_handbrake(wheel: WheelSystem) -> float:
	# the handbrake only acts on the rear axle: that is what makes the car slide
	return input.handbrake if wheel.index >= 2 else 0.0


## ------------------------------------------------------------------ steering
func _update_steering(delta: float) -> void:
	throttle_smoothed = MathUtils.damp(throttle_smoothed, input.throttle, 12.0, delta)
	brake_smoothed = MathUtils.damp(brake_smoothed, input.brake, 14.0, delta)
	var speed := absf(forward_speed_ms())
	var target := clampf(input.steer, -1.0, 1.0) * deg_to_rad(config.max_steer_angle_deg)
	# steering authority decreases with speed (physics, not a hack: the front
	# wheels can only use so much slip before they let go)
	var falloff := 1.0 / (1.0 + speed / maxf(config.steer_falloff_kmh / 3.6, 1.0))
	target *= lerpf(0.55, 1.0, falloff)
	# counter-steer assist: when the car is sliding, help the player catch it
	var lateral := right_direction().dot(linear_velocity)
	if absf(lateral) > 1.5 and speed > 4.0:
		var slide_angle := atan2(lateral, maxf(speed, 1.0))
		target += clampf(slide_angle, -0.5, 0.5) * config.counter_steer_assist * deg_to_rad(config.max_steer_angle_deg)
	var rate := config.steer_speed_deg_per_s if absf(target) > absf(steer_angle) else config.steer_return_speed_deg_per_s
	steer_angle = move_toward(steer_angle, target, deg_to_rad(rate) * delta)
	# Ackermann: the inner wheel steers a little more than the outer one
	var half_track := config.track_width_m * 0.5
	var wheelbase := maxf(config.wheelbase_m, 0.5)
	var turn_radius := wheelbase / maxf(tan(absf(steer_angle)), 0.0001)
	for wheel in wheels:
		if not config.is_wheel_steered(wheel.index):
			wheel.steer_angle = 0.0
			continue
		var inner := wheel.index == 0  # front left is inner on a left turn
		var ackermann := steer_angle
		if absf(turn_radius) > 0.001:
			var sign_steer := signf(steer_angle) if absf(steer_angle) > 0.0001 else 1.0
			var offset := atan2(half_track, turn_radius)
			ackermann = steer_angle + (offset if (sign_steer > 0.0) == inner else -offset) * 0.6
		wheel.steer_angle = clampf(ackermann, -deg_to_rad(config.max_steer_angle_deg * 1.35), deg_to_rad(config.max_steer_angle_deg * 1.35))


## --------------------------------------------------------------- anti-roll --
func _update_anti_roll(_delta: float) -> void:
	if config.anti_roll_stiffness <= 0.0:
		return
	var up := global_transform.basis.y.normalized()
	var pairs := [Vector2i(0, 1), Vector2i(2, 3)]
	for pair in pairs:
		var left := wheels[pair.x]
		var right := wheels[pair.y]
		var difference := left.compression - right.compression
		var force := config.anti_roll_stiffness * difference
		var limit := config.suspension_max_force_n * 0.35
		force = clampf(force, -limit, limit)
		if left.on_ground:
			apply_force(up * force, left.anchor - global_position)
		if right.on_ground:
			apply_force(-up * force, right.anchor - global_position)


## ------------------------------------------------------------------ aerodyn --
func _apply_aerodynamics(forward: Vector3) -> void:
	var speed := linear_velocity.length()
	if speed > 0.1:
		var drag := -linear_velocity.normalized() * VehicleController.drag_force_at(speed, config)
		apply_central_force(drag)
	# downforce is split front/rear around the centre of mass so the car settles
	var speed_sq := speed * speed
	var downforce := 0.5 * config.air_density * config.downforce_coefficient * speed_sq
	if downforce > 1.0:
		var half_base := config.wheelbase_m * 0.5
		apply_force(Vector3.DOWN * downforce * 0.5, Vector3(0.0, 0.0, -half_base))
		apply_force(Vector3.DOWN * downforce * 0.5, Vector3(0.0, 0.0, half_base))
	# soft speed cap: instead of clamping the velocity we add quadratic drag that
	# makes exceeding the design top speed impossible (nitro raises the limit)
	var cap := top_speed_limit()
	var forward_speed := forward_speed_ms()
	if forward_speed > cap:
		var excess := forward_speed - cap
		apply_central_force(forward * -excess * mass * 2.5)


func _apply_nitro_thrust(forward: Vector3, delta: float) -> void:
	if nitro == null:
		return
	var thrust := nitro.update(delta, input.nitro)
	if thrust > 0.0:
		# thrust at the rear axle: pushing where the driven wheels are
		apply_force(forward * thrust, Vector3(0.0, 0.0, config.wheelbase_m * 0.5))
		if nitro.active:
			input.nitro = true


func top_speed_limit() -> float:
	if nitro != null and nitro.active:
		return nitro.top_speed_with_boost_ms()
	return config.top_speed_ms()


## --------------------------------------------------------------------- state
func _update_engine_state(delta: float) -> void:
	var spin := false
	var lock := false
	for wheel in wheels:
		spin = spin or wheel.is_spinning
		lock = lock or wheel.is_locked
	if spin and not wheelspin:
		wheelspin = true
		wheelspin_started.emit()
	elif not spin:
		wheelspin = false
	if lock and not abs_active:
		abs_active = true
		locked_up.emit()
	elif not lock:
		abs_active = false
	_update_surface()


func _update_surface() -> void:
	var position := global_position
	var surface := current_surface
	if surface_provider.is_valid():
		surface = int(surface_provider.call(position.x, position.z, position.y))
	elif grounded_wheels > 0:
		surface = wheels[0].ground_surface
	if surface != current_surface:
		_previous_surface = current_surface
		current_surface = surface
		session_surface_changed.emit(surface)


func _update_state(delta: float, forward: Vector3) -> void:
	var velocity := linear_velocity
	var flat_velocity := Vector3(velocity.x, 0.0, velocity.z)
	var speed := flat_velocity.length()
	if speed > 1.0:
		drift_angle_deg = rad_to_deg(forward.signed_angle_to(flat_velocity.normalized(), Vector3.UP))
	else:
		drift_angle_deg = 0.0
	var drifting := absf(drift_angle_deg) > 18.0 and speed > 7.0 and grounded_wheels >= 2
	if drifting:
		drift_time_s += delta
		if drift_time_s > 0.35:
			drifted.emit(drift_angle_deg, speed * 3.6)
	else:
		drift_time_s = 0.0
	var airborne := grounded_wheels == 0
	if airborne:
		airtime_s += delta
	elif airtime_s > 0.0:
		if airtime_s > 0.25:
			landed.emit(absf(_last_forward_speed))
		airtime_s = 0.0
	if airtime_s > 0.0 and airtime_s < delta * 1.5:
		airtime_started.emit()
	# --- direction change (used by the camera and by the AI prediction)
	var going_forward := forward_speed_ms() >= -0.2
	if going_forward != _previous_forward:
		_previous_forward = going_forward
	# --- odometer
	var moved := Vector3(velocity.x, 0.0, velocity.z).length() * delta
	total_distance_m += moved
	_last_forward_speed = forward_speed_ms()


func _update_visuals(_delta: float) -> void:
	if _wheel_visuals.size() < WHEEL_COUNT:
		return
	var body_transform := global_transform
	for index in range(WHEEL_COUNT):
		var pivot := _wheel_visuals[index]
		var wheel := wheels[index]
		var world_anchor := body_transform * wheel.anchor
		var rest := config.suspension_rest_length_m
		var offset := clampf(wheel.suspension_length, rest - config.suspension_max_travel_m, rest + config.suspension_max_travel_m) if wheel.on_ground else rest
		var local := wheel.anchor - Vector3(0.0, offset, 0.0)
		pivot.position = pivot.position.lerp(local, 0.35)
		# roll the wheel and turn the front wheels with the steering
		var roll := wheel.spin_visual
		var spin_basis := Basis(Vector3.RIGHT, roll)
		var steer_basis := Basis(Vector3.UP, -wheel.steer_angle if config.is_wheel_steered(index) else 0.0)
		pivot.basis = steer_basis * spin_basis


## ---------------------------------------------------------------- accessors --
func forward_direction() -> Vector3:
	return -global_transform.basis.z.normalized()


func right_direction() -> Vector3:
	return global_transform.basis.x.normalized()


func up_direction() -> Vector3:
	return global_transform.basis.y.normalized()


## Signed speed along the car's own forward axis (negative = reversing).
func forward_speed_ms() -> float:
	return forward_direction().dot(linear_velocity)


func speed_kmh() -> float:
	return absf(forward_speed_ms()) * 3.6


func total_speed_kmh() -> float:
	return linear_velocity.length() * 3.6


func is_airborne() -> bool:
	return grounded_wheels == 0


func is_reversing() -> bool:
	return forward_speed_ms() < -0.4 or (input.brake > 0.35 and forward_speed_ms() < 1.0 and input.throttle < 0.15)


func is_drifting() -> bool:
	return absf(drift_angle_deg) > 18.0 and grounded_wheels >= 2


func is_braking() -> bool:
	return input.brake > 0.05


func slip_amount() -> float:
	var total := 0.0
	for wheel in wheels:
		total += absf(wheel.slip_ratio)
	return total / float(WHEEL_COUNT)


func average_wheel_slip_angle_deg() -> float:
	var total := 0.0
	for wheel in wheels:
		total += absf(rad_to_deg(wheel.slip_angle))
	return total / float(WHEEL_COUNT)


## Distance to the road network (INF when there is none) - used by the game flow
## to decide whether the player is off-road and by the AI for its target speed.
func distance_to_road() -> float:
	if not road_provider.is_valid():
		return 0.0
	var point: Vector3 = road_provider.call(global_position)
	return Vector2(point.x - global_position.x, point.z - global_position.z).length()


## --------------------------------------------------------------------- reset
## The only place that writes the transform: an explicit respawn onto the road
## (falls out of the world, stuck against scenery, "reset car" button).
func reset_car(onto_road: bool = true) -> void:
	_recovering = true
	var target := global_position
	var yaw := atan2(forward_direction().x, forward_direction().z)
	if onto_road and road_provider.is_valid():
		var point: Vector3 = road_provider.call(global_position)
		if point.distance_to(global_position) > 0.01:
			target = point
			var probe := point + Vector3(0.0, 0.0, 10.0)
			var ahead: Vector3 = road_provider.call(probe)
			var direction := ahead - point
			if direction.length() > 2.0 and direction.length() < 40.0:
				yaw = atan2(direction.x, direction.z)
	target.y += config.suspension_rest_length_m + config.wheel_radius_m + 0.35
	global_transform = Transform3D(Basis(Vector3.UP, yaw), target)
	linear_velocity = Vector3.ZERO
	angular_velocity = Vector3.ZERO
	throttle_smoothed = 0.0
	brake_smoothed = 0.0
	steer_angle = 0.0
	for wheel in wheels:
		wheel.angular_velocity = 0.0
		wheel.is_locked = false
		wheel.is_spinning = false
	if nitro != null:
		nitro.refill()
	reset_done.emit(target)
	# defer the physics activation so the assignment cannot fight the solver
	call_deferred("_finish_recovery")


func _finish_recovery() -> void:
	_recovering = false


## Alias used by the game flow / pause menu ("return the car to the road").
func recover_to_road() -> void:
	reset_car(true)


func _on_body_entered(body: Node) -> void:
	var speed := linear_velocity.length()
	if speed < 3.0:
		return
	collision_impact.emit(speed, current_surface)


## --------------------------------------------------------------- visual art --
func set_visual_scene(path: String) -> void:
	_visual_scene_path = path
	rebuild_visual()


func _build_body_mesh() -> void:
	for child in get_children():
		if child is MeshInstance3D and child.name == "Body":
			child.queue_free()
	if not _visual_scene_path.is_empty() and ResourceLoader.exists(_visual_scene_path):
		var scene: PackedScene = load(_visual_scene_path)
		if scene != null:
			var instance := scene.instantiate()
			instance.name = "Body"
			add_child(instance)
			_visual_root = instance
			_body_mesh = null
			return
	var builder := MeshBuilder.new()
	# The paint override is honoured by the model factory through the vehicle
	# config: the body colour always comes from `paint_color`/`paint_palette`.
	var paint := paint_override if paint_override.a > 0.0 else config.paint_color_for(0)
	var livery_config := config
	if paint_override.a > 0.0:
		livery_config = config.duplicate() as VehicleConfig
		livery_config.paint_color = paint
	VehicleModelFactory.build_car(
		builder,
		Transform3D(),
		livery_config,
		vehicle_role,
		0,
		MathUtils.rng_for(Vector2i(11, 13), 3),
		"",
		true
	)
	var mesh := builder.commit()
	var instance := MeshInstance3D.new()
	instance.name = "Body"
	instance.mesh = mesh
	add_child(instance)
	_visual_root = instance
	_body_mesh = instance


func _build_wheel_visuals() -> void:
	var builder := MeshBuilder.new()
	VehicleModelFactory.build_wheel(builder, config)
	var wheel_mesh := builder.commit()
	for index in range(WHEEL_COUNT):
		var pivot := Node3D.new()
		pivot.name = "WheelPivot%d" % index
		add_child(pivot)
		var instance := MeshInstance3D.new()
		instance.name = "Wheel"
		instance.mesh = wheel_mesh
		pivot.add_child(instance)
		_wheel_visuals.append(pivot)


func rebuild_visual() -> void:
	_build_body_mesh()


## ------------------------------------------------------- static physics math
## Engine torque for a given rpm/throttle (shared by the car and by the tests).
static func engine_torque_at(rpm: float, vehicle_config: VehicleConfig, throttle: float) -> float:
	if throttle <= 0.0:
		return 0.0
	var peak := maxf(vehicle_config.max_torque_nm, 1.0)
	var table := vehicle_config.torque_curve
	if table.is_empty():
		return peak * throttle
	var redline := maxf(vehicle_config.redline_rpm, 1.0)
	var t := clampf(rpm / redline, 0.0, 1.0)
	var index := int(t * float(table.size() - 1))
	var next := mini(index + 1, table.size() - 1)
	var fraction := t * float(table.size() - 1) - float(index)
	var torque := lerpf(table[index], table[next], fraction) * peak
	if rpm > vehicle_config.redline_rpm:
		# soft limiter: cuts torque instead of hard-cutting the throttle
		var over := (rpm - vehicle_config.redline_rpm) / maxf(vehicle_config.redline_rpm * 0.1, 1.0)
		torque *= clampf(1.0 - over, 0.0, 1.0)
	return torque * throttle


static func drag_force_at(speed_ms: float, vehicle_config: VehicleConfig) -> float:
	return 0.5 * vehicle_config.air_density * vehicle_config.drag_area * speed_ms * speed_ms


## Analytical top speed: solves "drive force = drag + rolling resistance" with the
## real torque curve and the top gear, then caps it with the electronic limiter
## (`top_speed_kmh`).  This is what makes the balance numbers in the config
## verifiable rather than decorative.
static func estimate_top_speed_ms(vehicle_config: VehicleConfig) -> float:
	var ratio: float = vehicle_config.gear_ratios[vehicle_config.gear_ratios.size() - 1] * vehicle_config.final_drive
	var rolling := vehicle_config.mass_kg * 9.81 * vehicle_config.rolling_resistance
	var low := 1.0
	var high := 140.0
	for iteration in range(40):
		var mid := (low + high) * 0.5
		var rpm := mid / vehicle_config.wheel_radius_m * 60.0 / TAU * ratio
		var torque := engine_torque_at(minf(rpm, vehicle_config.redline_rpm), vehicle_config, 1.0)
		var force := torque * ratio * 0.92 / vehicle_config.wheel_radius_m
		if force > drag_force_at(mid, vehicle_config) + rolling:
			low = mid
		else:
			high = mid
	return minf(low, vehicle_config.top_speed_ms())


func status() -> Dictionary:
	return {
		"speed_kmh": speed_kmh(),
		"forward_speed_ms": forward_speed_ms(),
		"rpm": engine_rpm,
		"gear": gear,
		"steer_deg": rad_to_deg(steer_angle),
		"drifting": is_drifting(),
		"lockup": abs_active,
		"wheelspin": wheelspin,
		"grounded_wheels": grounded_wheels,
		"surface": current_surface,
		"surface_name": Surface.name_of(current_surface),
		"slip": slip_amount(),
		"distance_m": total_distance_m,
		"nitro": nitro.status() if nitro != null else {},
		"input": input.to_dictionary(),
		"wheels": wheels.map(func(wheel: WheelSystem) -> Dictionary: return wheel.debug_info()),
	}
