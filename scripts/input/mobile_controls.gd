class_name MobileControls
extends Control

## On-screen driving controls for a portrait phone.
##
## Layout (bottom half of the screen is the "hands" area):
##   left lower corner  : steering (either two arrow buttons or a virtual wheel)
##   right lower corner : throttle (big pedal), brake/reverse, handbrake, nitro
##   right middle area  : free drag for the camera (the HUD forwards the delta)
##   top right          : pause
##
## The control writes into a VehicleInput object; the player car reads it every
## physics frame, exactly like an AI brain would.  Everything is drawn in code
## (no textures) and scales with the viewport, so the game stays usable from a
## small 720p phone to a tablet.

signal pause_requested()
signal camera_mode_requested()
signal reset_requested()
signal nitro_pressed()
signal horn_pressed()

const STICK_RADIUS := 86.0
const DEADZONE := 0.12

@export var steering_mode: int = SettingsManager.SteeringMode.BUTTONS:
	set(value):
		steering_mode = value
		_mode = value
		if is_inside_tree():
			_update_layout()

var input := VehicleInput.new()
var camera_drag: Vector2 = Vector2.ZERO
var throttle_pressed: bool = false
var brake_pressed: bool = false
var nitro_active: bool = false
var handbrake_active: bool = false
var steer_value: float = 0.0

## Alias used by the player car: it only needs the input object.
var vehicle_input: VehicleInput:
	get:
		return input

var _mode: int = SettingsManager.SteeringMode.BUTTONS
var _steer_touch_id: int = -1
var _camera_touch_id: int = -1
var _touches: Dictionary = {}

var _steer_center: Vector2 = Vector2.ZERO
var _throttle_rect: Rect2 = Rect2()
var _brake_rect: Rect2 = Rect2()
var _handbrake_rect: Rect2 = Rect2()
var _nitro_rect: Rect2 = Rect2()
var _left_rect: Rect2 = Rect2()
var _right_rect: Rect2 = Rect2()
var _pause_rect: Rect2 = Rect2()
var _scale: float = 1.0
var _font: Font = null



func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_PASS
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_font = ThemeDB.fallback_font
	_mode = Settings.steering_mode
	get_viewport().size_changed.connect(_update_layout)
	_update_layout()


func _update_layout() -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	# Анкеры растянуты на весь экран, поэтому size здесь только дублирует их:
	# ставим его отложенно, иначе Godot ругается на переопределение размера.
	if not size.is_equal_approx(viewport_size):
		set_deferred("size", viewport_size)
	_scale = clampf(viewport_size.x / 720.0, 0.75, 2.0) * Settings.hud_scale
	var bottom := viewport_size.y
	var margin := 18.0 * _scale
	var pedal := 96.0 * _scale
	# --- left: steering
	_steer_center = Vector2(margin + STICK_RADIUS * _scale, bottom - margin - STICK_RADIUS * _scale - 10.0 * _scale)
	var arrow := 78.0 * _scale
	_left_rect = Rect2(_steer_center - Vector2(STICK_RADIUS * _scale, STICK_RADIUS * _scale * 0.5), Vector2(arrow, arrow))
	_right_rect = Rect2(
		_steer_center + Vector2(STICK_RADIUS * _scale - arrow, -STICK_RADIUS * _scale * 0.5),
		Vector2(arrow, arrow)
	)
	# --- right: pedals
	_throttle_rect = Rect2(viewport_size.x - margin - pedal, bottom - margin - pedal * 2.35, pedal, pedal * 1.35)
	_brake_rect = Rect2(viewport_size.x - margin - pedal * 2.1, bottom - margin - pedal, pedal, pedal)
	_handbrake_rect = Rect2(viewport_size.x - margin - pedal * 1.05, bottom - margin - pedal * 1.05, pedal * 0.9, pedal * 0.9)
	_nitro_rect = Rect2(viewport_size.x - margin - pedal * 0.95, bottom - margin - pedal * 2.15, pedal * 0.85, pedal * 0.75)
	# --- top right: pause
	_pause_rect = Rect2(viewport_size.x - margin - 64.0 * _scale, margin, 64.0 * _scale, 64.0 * _scale)
	queue_redraw()


## ------------------------------------------------------------------ drawing --
func _draw() -> void:
	var opacity := clampf(0.55 + 0.4 * (1.0 / maxf(Settings.hud_scale, 0.5)), 0.45, 0.95)
	var button_color := Color(0.12, 0.14, 0.18, opacity * 0.6)
	var active_color := Color(0.20, 0.62, 0.95, opacity)
	if _mode == SettingsManager.SteeringMode.WHEEL:
		_draw_wheel(button_color, active_color)
	else:
		_draw_arrow(_left_rect, "◀", steer_value < -DEADZONE, button_color, active_color)
		_draw_arrow(_right_rect, "▶", steer_value > DEADZONE, button_color, active_color)
	_draw_arrow(_throttle_rect, "▲", throttle_pressed, button_color, active_color)
	_draw_arrow(_brake_rect, "▼", brake_pressed, button_color, active_color)
	_draw_arrow(_handbrake_rect, "H", handbrake_active, button_color, Color(0.95, 0.72, 0.2, opacity))
	_draw_arrow(_nitro_rect, "N2O", nitro_active, button_color, Color(0.9, 0.35, 0.95, opacity))
	_draw_arrow(_pause_rect, "II", false, button_color, active_color)


func _draw_arrow(rect: Rect2, label: String, active: bool, idle: Color, glow: Color) -> void:
	var color := glow if active else idle
	draw_rect(rect, color, true)
	draw_rect(rect, Color(0.85, 0.9, 1.0, 0.35), false, 2.0)
	if _font == null:
		return
	var font_size := int(clampf(rect.size.y * 0.42, 12.0, 34.0))
	var text_size := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size)
	var position := rect.position + (rect.size - text_size) * 0.5 + Vector2(0.0, text_size.y * 0.78)
	draw_string(_font, position, label, HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.97, 0.98, 1.0))


func _draw_wheel(idle: Color, glow: Color) -> void:
	var radius := STICK_RADIUS * _scale
	draw_circle(_steer_center, radius, idle)
	draw_arc(_steer_center, radius * 0.92, 0.0, TAU, 32, Color(0.85, 0.9, 1.0, 0.25), 2.0, true)
	# the "wheel" is drawn as a disc that can be dragged around its centre
	var knob := _steer_center + Vector2(steer_value * radius * 0.6, 0.0)
	draw_circle(knob, radius * 0.28, glow)
	if _font != null:
		draw_string(_font, _steer_center - Vector2(radius * 0.35, -6.0), "◀ ▶", HORIZONTAL_ALIGNMENT_LEFT, -1, int(16.0 * _scale), Color(0.9, 0.95, 1.0, 0.6))


## -------------------------------------------------------------------- input --
func _input(event: InputEvent) -> void:
	if event is InputEventScreenTouch:
		_handle_touch(event)
	elif event is InputEventScreenDrag:
		_handle_drag(event)
	elif event is InputEventMouseButton:
		var mouse := event as InputEventMouseButton
		var touch := InputEventScreenTouch.new()
		touch.index = 0
		touch.position = mouse.position
		touch.pressed = mouse.pressed
		_handle_touch(touch)
	elif event is InputEventMouseMotion:
		var motion := event as InputEventMouseMotion
		if _touches.has(0):
			var drag := InputEventScreenDrag.new()
			drag.index = 0
			drag.position = motion.position
			_handle_drag(drag)


func _handle_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		if _pause_rect.has_point(event.position):
			pause_requested.emit()
			return
		if _nitro_rect.has_point(event.position):
			_touches[event.index] = "nitro"
			nitro_active = true
			nitro_pressed.emit()
			return
		if _handbrake_rect.has_point(event.position):
			_touches[event.index] = "handbrake"
			handbrake_active = true
			return
		if _throttle_rect.has_point(event.position):
			_touches[event.index] = "throttle"
			throttle_pressed = true
			return
		if _brake_rect.has_point(event.position):
			_touches[event.index] = "brake"
			brake_pressed = true
			return
		if _mode == SettingsManager.SteeringMode.WHEEL:
			if _steer_center.distance_to(event.position) < STICK_RADIUS * _scale * 1.6:
				_steer_touch_id = event.index
				_touches[event.index] = "steer"
				_update_steer_from_position(event.position)
				return
		else:
			if _left_rect.has_point(event.position) or _right_rect.has_point(event.position):
				_touches[event.index] = "steer_button"
				steer_value = -1.0 if _left_rect.has_point(event.position) else 1.0
				return
		# anything else on the right half is a camera drag
		if event.position.x > get_viewport().get_visible_rect().size.x * 0.35:
			_camera_touch_id = event.index
			_touches[event.index] = "camera"
	else:
		var kind: String = _touches.get(event.index, "")
		_touches.erase(event.index)
		match kind:
			"throttle":
				throttle_pressed = false
			"brake":
				brake_pressed = false
			"nitro":
				nitro_active = false
			"handbrake":
				handbrake_active = false
			"steer", "steer_button":
				if event.index == _steer_touch_id:
					_steer_touch_id = -1
				steer_value = 0.0
			"camera":
				if event.index == _camera_touch_id:
					_camera_touch_id = -1
	_rebuild_input()


## Keyboard/actions are handled by the scene (MainScene._unhandled_input) so that
## the same key never triggers two different code paths.
func _handle_drag(event: InputEventScreenDrag) -> void:
	var kind: String = _touches.get(event.index, "")
	if kind == "steer":
		_update_steer_from_position(event.position)
	elif kind == "camera" or event.index == _camera_touch_id:
		camera_drag += event.relative
	_rebuild_input()


func _update_steer_from_position(position: Vector2) -> void:
	var offset := position - _steer_center
	var radius := STICK_RADIUS * _scale * 0.8
	var value := clampf(offset.x / maxf(radius, 1.0), -1.0, 1.0)
	steer_value = 0.0 if absf(value) < DEADZONE else value


## The control object handed to the car.
func _rebuild_input() -> void:
	input.throttle = 1.0 if throttle_pressed else 0.0
	input.brake = 1.0 if brake_pressed else 0.0
	input.handbrake = 1.0 if handbrake_active else 0.0
	input.nitro = nitro_active
	input.steer = steer_value
	if input.throttle <= 0.0 and Settings.auto_accelerate and input.brake <= 0.0:
		input.throttle = 1.0


## The HUD pulls the camera drag once per frame (and applies it to the camera).
func consume_camera_drag() -> Vector2:
	var value := camera_drag
	camera_drag = Vector2.ZERO
	return value


func reset_state() -> void:
	_touches.clear()
	_steer_touch_id = -1
	_camera_touch_id = -1
	steer_value = 0.0
	throttle_pressed = false
	brake_pressed = false
	handbrake_active = false
	nitro_active = false
	camera_drag = Vector2.ZERO
	input.reset()
	_rebuild_input()


func status() -> Dictionary:
	return {
		"steer": snappedf(steer_value, 0.01),
		"throttle": input.throttle,
		"brake": input.brake,
		"handbrake": input.handbrake,
		"nitro": input.nitro,
		"touches": _touches.size(),
		"mode": "WHEEL" if _mode == SettingsManager.SteeringMode.WHEEL else "BUTTONS",
	}
