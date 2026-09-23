class_name WheelSystem
extends RefCounted

## One wheel of the car: raycast suspension + a compact but real tyre model.
##
## The model is the classic "raycast vehicle" one:
##   1. a ray from the suspension anchor finds the ground and measures the
##      compression of the spring,
##   2. the spring/damper force is applied at the contact point,
##   3. the tyre forces come from slip: the longitudinal one from the wheel's own
##      angular velocity (so wheelspin and brake lock-up are simulated instead of
##      being faked), the lateral one from the slip angle,
##   4. both are fitted into a friction circle so the car cannot corner at full
##      throttle with no consequence.
##
## `compute_tyre_force` and `_pacejka` are deliberately free of any scene tree
## dependency, which is why they can be unit tested head-lessly.

const WHEEL_INERTIA_FACTOR := 0.5
const WHEEL_MASS_KG := 24.0
const MAX_SLIP_RATIO := 3.0
## Below this road speed a braked, stopped wheel is parked rather than locked.
const LOCK_SLIDE_SPEED_MS := 0.2
## Magic Formula shape factor, and B chosen so that the curve peaks exactly where
## the slip crosses the configured peak (B = tan(pi / 2C)); a larger B made the
## tyre lose most of its grip at a couple of degrees of slip angle.
const PACEJKA_C := 1.55
const PACEJKA_B := 1.616318

var config: VehicleConfig
var index: int = 0
var anchor: Vector3 = Vector3.ZERO
var steer_angle: float = 0.0
var angular_velocity: float = 0.0
var drive_torque: float = 0.0
var brake_torque: float = 0.0
var handbrake: float = 0.0
var on_ground: bool = false
var suspension_length: float = 0.0
var compression: float = 0.0
var compression_velocity: float = 0.0
var load: float = 0.0
var contact_point: Vector3 = Vector3.ZERO
var contact_normal: Vector3 = Vector3.UP
var ground_surface: int = Surface.Type.ASPHALT
var lateral_force: float = 0.0
var longitudinal_force: float = 0.0
var slip_ratio: float = 0.0
var slip_angle: float = 0.0
var surface_grip: float = 1.0
var spin_visual: float = 0.0
var is_locked: bool = false
var is_spinning: bool = false
var wheel_radius: float = 0.34

var _previous_compression: float = 0.0


func setup(vehicle_config: VehicleConfig, wheel_index: int, position: Vector3, radius: float) -> void:
	config = vehicle_config
	index = wheel_index
	anchor = position
	wheel_radius = radius


func inertia() -> float:
	return WHEEL_INERTIA_FACTOR * WHEEL_MASS_KG * wheel_radius * wheel_radius


## ---------------------------------------------------------------- suspension
func update_suspension(
	space: PhysicsDirectSpaceState3D,
	body_transform: Transform3D,
	linear_velocity: Vector3,
	_body_angular_velocity: Vector3,
	exclude_rid: RID,
	collision_mask: int,
	delta: float
) -> void:
	var up := body_transform.basis.y.normalized()
	var down := -up
	var world_anchor := body_transform * anchor
	var max_length := config.suspension_rest_length_m + config.suspension_max_travel_m
	var ray_length := max_length + wheel_radius
	var query := PhysicsRayQueryParameters3D.create(world_anchor, world_anchor + down * ray_length)
	query.collision_mask = collision_mask
	query.exclude = [exclude_rid]
	query.hit_from_inside = false
	var result := space.intersect_ray(query)
	if result.is_empty():
		on_ground = false
		load = 0.0
		lateral_force = 0.0
		longitudinal_force = 0.0
		# free wheel: it keeps spinning down towards idle when airborne
		angular_velocity = maxf(0.0, angular_velocity - 6.0 * delta)
		compression = 0.0
		compression_velocity = 0.0
		return
	on_ground = true
	contact_point = result["position"]
	contact_normal = result["normal"]
	var distance := world_anchor.distance_to(contact_point)
	var spring_length := clampf(distance - wheel_radius, 0.0, max_length)
	suspension_length = spring_length
	compression = config.suspension_rest_length_m - spring_length
	compression_velocity = (compression - _previous_compression) / maxf(delta, 0.0001)
	_previous_compression = compression
	var spring_force := config.suspension_spring_n_per_m * compression
	var damping := config.suspension_compression_damping if compression_velocity > 0.0 else config.suspension_rebound_damping
	spring_force += damping * compression_velocity
	load = clampf(spring_force, 0.0, config.suspension_max_force_n)
	# The body angular velocity is accepted (and ignored) so the caller can pass
	# the rigid body state as it is: the contact point velocity is computed in the
	# controller, which has the offset vector at hand.

	# grip of the surface under this wheel is applied by the caller (it owns the
	# terrain query); the tyre forces themselves are computed in apply_forces.


func set_surface(surface: int, grip: float) -> void:
	ground_surface = surface
	surface_grip = grip


## -------------------------------------------------------------- tyre model --
## ground_velocity: velocity of the contact point in world space
## forward_dir / lateral_dir: wheel axes in world space (already steered)
## Returns the force vector to apply to the body at the contact point.
func compute_tyre_force(
	ground_velocity: Vector3,
	forward_dir: Vector3,
	lateral_dir: Vector3,
	delta: float,
	use_abs: bool,
	use_tcs: bool
) -> Dictionary:
	var forward_speed := ground_velocity.dot(forward_dir)
	var lateral_speed := ground_velocity.dot(lateral_dir)
	var speed := ground_velocity.length()

	# --- longitudinal slip from the wheel's own rotation
	var surface_speed := angular_velocity * wheel_radius
	var denominator := maxf(absf(forward_speed), 1.6)
	slip_ratio = clampf((surface_speed - forward_speed) / denominator, -MAX_SLIP_RATIO, MAX_SLIP_RATIO)
	slip_angle = atan2(lateral_speed, maxf(absf(forward_speed), 0.8))

	var grip_scale := surface_grip
	var max_lateral := config.lateral_grip * load * grip_scale
	var max_longitudinal := config.longitudinal_grip * load * grip_scale
	# Load sensitivity: a heavier tyre gives proportionally less grip per newton.
	# The reduction is measured from the static wheel load, so a light wheel does
	# not get a bonus and nothing saturates into a hard clamp (which used to make
	# a 5000 N tyre exactly as efficient as a 2500 N one).
	var reference_load := maxf(config.mass_kg * 9.81 * 0.25, 1.0)
	var load_factor := 1.0 / (1.0 + config.load_sensitivity * maxf(load - reference_load, 0.0))
	load_factor = clampf(load_factor, 0.45, 1.0)
	max_lateral *= load_factor
	max_longitudinal *= load_factor

	# --- simplified Pacejka curves
	var fx := _pacejka(slip_ratio, config.longitudinal_slip_peak) * max_longitudinal
	var fy := _pacejka(slip_angle * 8.0, config.lateral_slip_peak * 8.0) * max_lateral
	if handbrake > 0.01:
		fy *= lerpf(1.0, config.handbrake_lateral_factor, handbrake)
	# --- friction ellipse: the combined force may not exceed the tyre budget
	var budget := maxf(max_longitudinal, max_lateral)
	var magnitude := sqrt(fx * fx + fy * fy)
	if magnitude > budget and magnitude > 0.0001:
		var scale := budget / magnitude
		fx *= scale
		fy *= scale
	var speed_falloff := clampf(1.0 - (speed - 42.0) / 90.0, 0.72, 1.0)
	fx *= speed_falloff
	fy *= speed_falloff
	longitudinal_force = fx
	lateral_force = fy

	# --- reaction torque on the wheel (this is what spins / locks it)
	var reaction_torque := fx * wheel_radius
	var total_wheel_torque := drive_torque - reaction_torque
	# brake torque opposes rotation and can lock the wheel
	var brake_capability := brake_torque + handbrake * config.handbrake_torque_nm
	var omega_new := angular_velocity + total_wheel_torque / maxf(inertia(), 0.001) * delta
	if brake_capability > 0.001:
		var brake_delta := brake_capability / maxf(inertia(), 0.001) * delta
		if absf(omega_new) <= brake_delta:
			# wheel stopped: the tyre slides on the surface
			omega_new = 0.0
			# A stopped wheel that still moves relative to the road is a locked one;
			# only a car that is genuinely standing still is not "sliding".
			is_locked = absf(forward_speed) > LOCK_SLIDE_SPEED_MS
			# kinetic friction (lower than static) while locked
			fx *= 0.72
			longitudinal_force = fx
		elif omega_new > 0.0:
			omega_new -= brake_delta
			is_locked = false
		else:
			omega_new += brake_delta
			is_locked = false
	else:
		is_locked = false
	# --- traction control / ABS (optional, mirrors real driving aids)
	if use_abs and brake_capability > 0.001 and absf(forward_speed) > 3.0 and absf(slip_ratio) > 0.8 and on_ground:
		# release part of the brake torque before the wheel locks up
		brake_torque *= 0.55
	if use_tcs and drive_torque > 0.0 and absf(slip_ratio) > 0.55 and on_ground and forward_speed > 1.5:
		drive_torque *= clampf(1.0 - (absf(slip_ratio) - 0.55) * 1.6, 0.15, 1.0)
	angular_velocity = clampf(omega_new, -260.0, 260.0)
	is_spinning = absf(slip_ratio) > 0.5 and drive_torque > 1.0
	spin_visual += angular_velocity * delta

	var force := forward_dir * fx + lateral_dir * fy
	# rolling resistance and the "scrub" of a locked wheel
	if on_ground:
		var resistance := -forward_dir * config.rolling_resistance * load * signf(forward_speed)
		if is_locked:
			resistance *= 4.0
		force += resistance
	return {"force": force, "forward_force": fx, "lateral_force": fy, "reaction_torque": reaction_torque}


func _pacejka(slip: float, peak: float) -> float:
	# Normalised slip -> 0..1 tyre force coefficient (Magic Formula, simplified).
	# The peak of this shape sits at |slip| == peak, so the config value really is
	# "the slip at which the tyre grips best".
	var normalised := slip / maxf(peak, 0.01)
	return sin(PACEJKA_C * atan(PACEJKA_B * normalised))


func apply_spring_force(body: RigidBody3D, up: Vector3, spring_force: float) -> void:
	if not on_ground:
		return
	body.apply_force(up * spring_force, contact_point - body.global_position)


func ground_speed_factor() -> float:
	return clampf(surface_grip, 0.0, 1.5)


func debug_info() -> Dictionary:
	return {
		"index": index,
		"on_ground": on_ground,
		"load": snappedf(load, 1.0),
		"slip_ratio": snappedf(slip_ratio, 0.01),
		"slip_angle_deg": snappedf(rad_to_deg(slip_angle), 0.1),
		"fx": snappedf(longitudinal_force, 1.0),
		"fy": snappedf(lateral_force, 1.0),
		"locked": is_locked,
		"spinning": is_spinning,
		"surface": ground_surface,
	}
