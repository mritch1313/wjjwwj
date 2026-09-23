class_name PlayerCar
extends VehicleController

## The player's car: a VehicleController plus everything that is specific to
## being driven by a human on a phone.
##
## It does *not* reimplement the vehicle.  The physics stays in
## VehicleController (RigidBody3D + 4 raycast wheels + tyre model), and this
## class only does three jobs:
##   1. input routing - the on-screen controls own a `VehicleInput` object and
##      this car simply reads it.  A keyboard fallback is kept so the game can be
##      played and validated on a desktop.
##   2. driver assists that a touchscreen needs (auto accelerate, speed
##      sensitive steering, gentle counter-steer help while sliding).  They only
##      change the *input*, never the physics, so the car still behaves like a
##      car and the police cars - which get no assists - are not cheated.
##   3. reporting: surface, impacts, drifts and nitro go to the Game flow, which
##      records them in the save file and shows them in the HUD.

@export var assists_enabled: bool = true
## Drag a finger on the right half of the screen to look around.
var touch_controls_path: NodePath = ^"../Controls/MobileControls"

var source_connected: bool = false
var using_touch_controls: bool = false

var _touch_controls: MobileControls = null
var _keyboard_input := VehicleInput.new()
var _assist_timer_s: float = 0.0
var _last_surface: int = Surface.Type.ASPHALT


func _ready() -> void:
	config = Config.vehicle_player
	super()  # VehicleController builds the collision, wheels and nitro
	# The player car is spawned as a "civilian" body: same physics as the police,
	# only the paint and the livery differ.
	vehicle_role = VehicleModelFactory.Role.CIVILIAN
	is_player_vehicle = true
	paint_override = Settings.player_paint_color()
	session_surface_changed.connect(_on_surface_changed)
	collision_impact.connect(_on_collision_impact)
	nitro_used.connect(_on_nitro_used)
	drifted.connect(_on_drifted)
	landed.connect(_on_landed)
	reset_done.connect(_on_reset_done)
	_resolve_touch_controls()
	rebuild_visual()


## ---------------------------------------------------------------- input glue
func _resolve_touch_controls() -> void:
	if not is_inside_tree() or touch_controls_path.is_empty():
		return
	var node := get_node_or_null(touch_controls_path)
	if node is MobileControls:
		set_input_source(node.vehicle_input)


## Called by the scene (and by the tests) with the object the controls write to.
func set_input_source(source: Variant) -> void:
	if source is MobileControls:
		_touch_controls = source
		input = source.vehicle_input
		using_touch_controls = true
		return
	if source is VehicleInput:
		input = source
		using_touch_controls = false
		return
	# no touch controls (headless test, desktop without UI): keep the keyboard
	input = _keyboard_input
	using_touch_controls = false


func _physics_process(delta: float) -> void:
	_route_input(delta)
	super(delta)


func _route_input(delta: float) -> void:
	if input == null:
		input = _keyboard_input
	# --- keyboard (desktop) drives the same object as the touch buttons
	var keyboard_active := _read_keyboard()
	if keyboard_active and input != _keyboard_input and _touch_controls != null:
		# the desktop is being used while the on-screen pad is idle: copy the
		# keyboard values into the shared object so the car responds
		input.throttle = _keyboard_input.throttle
		input.brake = _keyboard_input.brake
		input.steer = _keyboard_input.steer
		input.handbrake = _keyboard_input.handbrake
		input.nitro = _keyboard_input.nitro
	# --- assists (input only, never physics)
	input.use_abs = true
	input.use_tcs = true
	if not assists_enabled:
		return
	if Settings.auto_accelerate and input.throttle <= 0.001 and input.brake <= 0.001:
		# keep a slow roll instead of standing still: the player only steers
		input.throttle = 0.55 if absf(forward_speed_ms()) < 3.0 else 0.35
	# speed sensitive steering: the faster we go, the smaller the input is per
	# finger movement (a real car does this mechanically)
	var speed_ratio := clampf(absf(forward_speed_ms()) / maxf(top_speed_limit(), 1.0), 0.0, 1.0)
	if input.handbrake < 0.5:
		input.steer = clampf(input.steer * lerpf(1.0, 0.58, speed_ratio), -1.0, 1.0)
	# counter-steer help while sliding: a small nudge against the slide, only
	# when the player is not steering themselves
	_assist_timer_s += delta
	if is_drifting() and absf(input.steer) < 0.35:
		var correction := clampf(-drift_angle_deg / 55.0, -0.45, 0.45)
		input.steer = clampf(input.steer + correction, -1.0, 1.0)


func _read_keyboard() -> bool:
	if not InputMap.has_action("throttle"):
		return false
	var steer := Input.get_axis("steer_left", "steer_right") if InputMap.has_action("steer_left") else 0.0
	var throttle := Input.get_action_strength("throttle") if InputMap.has_action("throttle") else 0.0
	var brake := Input.get_action_strength("brake_reverse") if InputMap.has_action("brake_reverse") else 0.0
	var handbrake := Input.get_action_strength("handbrake") if InputMap.has_action("handbrake") else 0.0
	var nitro_pressed := Input.is_action_pressed("nitro") if InputMap.has_action("nitro") else false
	var active := absf(steer) > 0.01 or throttle > 0.01 or brake > 0.01 or handbrake > 0.01 or nitro_pressed
	_keyboard_input.throttle = maxf(throttle, 0.0)
	_keyboard_input.brake = maxf(brake, 0.0)
	_keyboard_input.steer = clampf(steer, -1.0, 1.0)
	_keyboard_input.handbrake = handbrake
	_keyboard_input.nitro = nitro_pressed
	return active


## ------------------------------------------------------------------ reporting
func _on_surface_changed(surface: int) -> void:
	_last_surface = surface
	Game.on_player_surface(surface)


func _on_collision_impact(speed_ms: float, surface: int) -> void:
	Game.on_player_impact(speed_ms, surface)
	# a hard hit shakes the camera a little (it is a presentation detail, so it
	# is optional and guarded)
	var camera: Node = Game.chase_camera
	if camera != null and camera.has_method("shake"):
		camera.call("shake", clampf(speed_ms * 0.02, 0.05, 0.4))


func _on_nitro_used() -> void:
	Game.on_nitro_used()


func _on_drifted(angle_deg: float, speed_kmh: float) -> void:
	Game.on_player_drift(0.35)
	if absf(angle_deg) > 35.0 and speed_kmh > 60.0:
		Game.maybe_report_pursuit_toast()


func _on_landed(impact_speed_ms: float) -> void:
	if impact_speed_ms > 7.0:
		Game.on_player_impact(impact_speed_ms, current_surface)


func _on_reset_done(_position: Vector3) -> void:
	Game.toast.emit(L10n.t("world_recovered"))
	if _touch_controls != null:
		_touch_controls.reset_state()


## The pause menu / the "reset" button call this name.
func reset_to_road() -> void:
	recover_to_road()


func paint(paint_index: int) -> void:
	paint_override = Config.vehicle_player.paint_color_for(paint_index)
	rebuild_visual()


## Called by the settings screen when the control layout changes.
func touch_controls_refresh() -> void:
	if _touch_controls != null:
		_touch_controls.steering_mode = Settings.steering_mode
		_touch_controls.queue_redraw()


func speed_sensitive_steer_ratio() -> float:
	return clampf(absf(forward_speed_ms()) / maxf(top_speed_limit(), 1.0), 0.0, 1.0)


func player_status() -> Dictionary:
	var result := status()
	result["touch_controls"] = using_touch_controls
	result["assists"] = assists_enabled
	result["steer_ratio"] = speed_sensitive_steer_ratio()
	result["last_surface"] = Surface.name_of(_last_surface)
	return result
