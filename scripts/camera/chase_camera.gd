class_name ChaseCamera
extends Node3D

## Third person chase camera for a portrait phone:
##   * SpringArm3D handles collision avoidance (the arm shortens when a wall or a
##     building is in the way) - no camera clipping through geometry,
##   * the player can orbit freely at any time; the camera only returns behind the
##     car after a moment of no camera input *and* while driving forward,
##   * speed and nitro change the FOV for a sense of speed,
##   * `apply_quality()` switches distance/shadow settings per graphics preset.

signal mode_changed(mode: int)

enum Mode { CHASE, HOOD, FAR, FREE }

const MODES: Array[int] = [Mode.CHASE, Mode.HOOD, Mode.FAR]
const MODE_NAMES := {
	Mode.CHASE: "CHASE",
	Mode.HOOD: "HOOD",
	Mode.FAR: "FAR",
	Mode.FREE: "FREE",
}

@export var target_path: NodePath
@export var camera_node_path: NodePath

@export_group("Orbit")
var min_distance: float = 5.4
var max_distance: float = 11.0
var distance: float = 7.4
var height: float = 2.15
var look_ahead: float = 3.4
var pitch_min_deg: float = -32.0
var pitch_max_deg: float = 26.0

@export_group("Feel")
var yaw_follow_strength: float = 1.15
var yaw_free_time: float = 2.4
var smoothing_position: float = 9.0
var smoothing_yaw: float = 7.0
var collision_margin: float = 0.45
var shake_decay: float = 2.2

var base_fov: float = 68.0
var speed_fov_gain: float = 12.0
var nitro_fov_boost: float = 6.0

var mode: int = Mode.CHASE
var orbit_yaw: float = 0.0
var orbit_pitch: float = -0.16
var target: Node3D = null

var _camera: Camera3D = null
var _spring: SpringArm3D = null
var _manual_yaw_timer: float = 0.0
var _shake: float = 0.0
var _speed_factor: float = 0.0
var _reverse_bias: float = 0.0
var _last_valid_position: Vector3 = Vector3.ZERO
var _initialised: bool = false


func _ready() -> void:
	_ensure_nodes()
	if target == null and not target_path.is_empty():
		target = get_node_or_null(target_path)
	_apply_mode(Mode.CHASE)
	set_process(true)


func _ensure_nodes() -> void:
	if _spring == null:
		_spring = SpringArm3D.new()
		_spring.name = "SpringArm"
		_spring.spring_length = distance
		_spring.collision_mask = 1 | (1 << 1)  # world + props
		_spring.margin = collision_margin
		add_child(_spring)
	if _camera == null:
		_camera = Camera3D.new()
		_camera.name = "Camera"
		_camera.fov = base_fov
		_camera.near = 0.35
		_camera.far = 1600.0
		_spring.add_child(_camera)


func camera() -> Camera3D:
	_ensure_nodes()
	return _camera


func set_target(node: Node3D) -> void:
	target = node
	_last_valid_position = node.global_position if node != null else Vector3.ZERO
	_initialised = false


## Player camera input (touch drag / mouse drag / gamepad stick).
func add_orbit(yaw_delta: float, pitch_delta: float) -> void:
	orbit_yaw = wrapf(orbit_yaw - yaw_delta, -PI, PI)
	orbit_pitch = clampf(
		orbit_pitch + pitch_delta,
		deg_to_rad(pitch_min_deg),
		deg_to_rad(pitch_max_deg)
	)
	_manual_yaw_timer = yaw_free_time
	if mode != Mode.FREE and mode != Mode.HOOD:
		_apply_mode(Mode.FREE)


func add_distance(delta: float) -> void:
	distance = clampf(distance + delta, min_distance, max_distance)
	if _spring != null:
		_spring.spring_length = distance


func cycle_mode() -> int:
	var index := MODES.find(mode)
	var next_mode: int = MODES[(index + 1) % MODES.size()] if index >= 0 else Mode.CHASE
	_apply_mode(next_mode)
	return mode


func shake(amount: float) -> void:
	_shake = clampf(_shake + amount, 0.0, 1.6)


func _apply_mode(new_mode: int) -> void:
	mode = new_mode
	_manual_yaw_timer = 0.0 if new_mode != Mode.FREE else yaw_free_time
	match mode:
		Mode.HOOD:
			_spring.spring_length = 0.9
			height = 0.75
			distance = 0.9
		Mode.FAR:
			distance = clampf(max_distance * 1.15, min_distance, max_distance * 1.4)
			_spring.spring_length = distance
			height = 2.9
		Mode.CHASE, Mode.FREE:
			distance = clampf(7.4, min_distance, max_distance)
			_spring.spring_length = distance
			height = 2.15
	mode_changed.emit(mode)


func _process(delta: float) -> void:
	if target == null or not is_instance_valid(target):
		return
	_ensure_nodes()
	_manual_yaw_timer = maxf(_manual_yaw_timer - delta, 0.0)
	var target_position: Vector3 = target.global_position
	var forward: Vector3 = target.call("forward_direction") if target.has_method("forward_direction") else -target.global_transform.basis.z
	var speed: float = float(target.call("speed_kmh")) if target.has_method("speed_kmh") else 0.0
	var reversing := bool(target.call("is_reversing")) if target.has_method("is_reversing") else false
	_speed_factor = lerpf(_speed_factor, clampf(speed / 160.0, 0.0, 1.0), delta * 2.4)
	_reverse_bias = lerpf(_reverse_bias, -0.35 if reversing else 0.0, delta * 3.0)

	var heading := atan2(forward.x, forward.z)
	if mode != Mode.FREE and _manual_yaw_timer <= 0.0 and absf(speed) > 12.0:
		# follow the car (but only while driving: a stopped car should not spin
		# the camera when the player looks around)
		orbit_yaw = MathUtils.damp(orbit_yaw, heading, yaw_follow_strength, delta)
	if mode == Mode.FREE and _manual_yaw_timer <= 0.0 and absf(speed) > 18.0:
		# hand the camera back after a while of no input
		orbit_yaw = MathUtils.damp(orbit_yaw, heading, yaw_follow_strength * 0.6, delta)

	var look_target := target_position
	if reversing:
		look_target -= forward * look_ahead * 0.4
	else:
		look_target += forward * look_ahead * (0.4 + _speed_factor * 0.6)
	var desired := look_target - Vector3(sin(orbit_yaw + PI), 0.0, cos(orbit_yaw + PI)) * 0.0
	# position the arm: the yaw comes from the orbit angle, the pitch from the
	# player's look angle, so the camera can be moved around the car freely
	var horizontal := Vector3(sin(orbit_yaw), 0.0, cos(orbit_yaw))
	var arm_length := distance
	desired = look_target + horizontal * arm_length * cos(orbit_pitch) + Vector3.UP * (height + arm_length * sin(-orbit_pitch) * 0.9)
	desired.y = maxf(desired.y, target_position.y + 0.55)
	global_position = global_position.lerp(desired, 1.0 - exp(-smoothing_position * delta))
	var look := look_target + Vector3.UP * (0.9 + height * 0.18) + horizontal * 0.4
	if _shake > 0.02:
		var offset := Vector3(
			randf_range(-1.0, 1.0), randf_range(-1.0, 1.0), randf_range(-1.0, 1.0)
		) * _shake * 0.16
		look += offset
		_shake = maxf(_shake - delta * shake_decay, 0.0)
	look_at(look, Vector3.UP)
	_update_fov(delta)
	_last_valid_position = global_position
	_initialised = true


func _update_fov(delta: float) -> void:
	if _camera == null:
		return
	var target_fov := base_fov + _speed_factor * speed_fov_gain + _nitro_fov()
	if mode == Mode.HOOD:
		target_fov += 4.0
	_camera.fov = lerpf(_camera.fov, target_fov, 1.0 - exp(-3.0 * delta))


func _nitro_fov() -> float:
	if target == null or not is_instance_valid(target):
		return 0.0
	var nitro_value: Variant = target.get("nitro")
	if nitro_value == null or not (nitro_value is Object):
		return 0.0
	if bool(nitro_value.get("active")):
		return nitro_fov_boost
	return 0.0


func apply_quality(quality: GraphicsQuality) -> void:
	if quality == null:
		return
	base_fov = clampf(68.0 - (quality.view_distance_m - 448.0) / 90.0, 62.0, 72.0)
	if _camera != null:
		_camera.far = maxf(quality.view_distance_m * 3.4, 900.0)
	if _spring != null:
		_spring.collision_mask = 1 | (1 << 1)
	set_process(true)


func status() -> Dictionary:
	return {
		"mode": MODE_NAMES.get(mode, "?"),
		"distance": snappedf(distance, 0.01),
		"yaw_deg": snappedf(rad_to_deg(orbit_yaw), 0.1),
		"pitch_deg": snappedf(rad_to_deg(orbit_pitch), 0.1),
		"fov": snappedf(_camera.fov, 0.1) if _camera != null else 0.0,
		"manual": _manual_yaw_timer > 0.0,
	}
