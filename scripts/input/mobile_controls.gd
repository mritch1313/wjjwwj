class_name MobileControls
extends Control

## On-screen driving controls for a portrait phone.
##
## Раскладка (низ экрана - «руки», верх занят HUD и миникартой):
##   слева снизу  : руль (круглый стик) либо две кнопки «влево / вправо»
##   справа снизу : ГАЗ (большая круглая педаль), ТОРМОЗ/НАЗАД, РУЧНИК, N2O
##   свободное поле: свайп - свободный обзор камеры
##
## Всё рисуется кодом (без текстур) и масштабируется от размера экрана, поэтому
## управление одинаково работает и на 720p телефоне, и на планшете.
##
## Кнопки круглые: попадание считается по радиусу с запасом, палец «прилипает»
## к кнопке, пока не уйдёт слишком далеко, а при отрыве пальца состояние
## сбрасывается всегда - раньше кнопка могла остаться нажатой навсегда.

signal pause_requested()
signal camera_mode_requested()
signal reset_requested()
signal nitro_pressed()
signal horn_pressed()

const STICK_RADIUS := 92.0
const DEADZONE := 0.12
## Запас к радиусу кнопки: попасть пальцем проще, чем в точный круг.
const HIT_PADDING := 1.16
## Насколько далеко палец может уйти от кнопки, не отпуская её.
const HOLD_PADDING := 1.7

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
var _steer_radius: float = STICK_RADIUS
var _left_center: Vector2 = Vector2.ZERO
var _right_center: Vector2 = Vector2.ZERO
var _steer_button_radius: float = 54.0
var _throttle_center: Vector2 = Vector2.ZERO
var _throttle_radius: float = 62.0
var _brake_center: Vector2 = Vector2.ZERO
var _brake_radius: float = 54.0
var _handbrake_center: Vector2 = Vector2.ZERO
var _handbrake_radius: float = 40.0
var _nitro_center: Vector2 = Vector2.ZERO
var _nitro_size: Vector2 = Vector2(96.0, 62.0)
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
	if not size.is_equal_approx(viewport_size):
		set_deferred("size", viewport_size)
	_scale = clampf(viewport_size.x / 720.0, 0.72, 2.0) * clampf(Settings.hud_scale, 0.8, 1.4)
	var bottom := viewport_size.y
	var right := viewport_size.x
	var margin := 22.0 * _scale

	# --- слева: руль
	_steer_radius = STICK_RADIUS * _scale
	_steer_button_radius = 56.0 * _scale
	_steer_center = Vector2(margin + _steer_radius, bottom - margin - _steer_radius)
	_left_center = _steer_center + Vector2(-_steer_button_radius - 8.0 * _scale, 0.0)
	_right_center = _steer_center + Vector2(_steer_button_radius + 8.0 * _scale, 0.0)

	# --- справа: педали.  Газ - самая большая кнопка в правом нижнем углу.
	_throttle_radius = 64.0 * _scale
	_throttle_center = Vector2(right - margin - _throttle_radius, bottom - margin - _throttle_radius)
	_brake_radius = 56.0 * _scale
	_brake_center = _throttle_center + Vector2(-_throttle_radius - _brake_radius - 10.0 * _scale, 6.0 * _scale)
	_handbrake_radius = 42.0 * _scale
	_handbrake_center = Vector2(
		_throttle_center.x - _throttle_radius * 0.35,
		_throttle_center.y - _throttle_radius - _handbrake_radius - 14.0 * _scale
	)
	_nitro_size = Vector2(112.0, 66.0) * _scale
	_nitro_center = Vector2(
		_brake_center.x - _nitro_size.x * 0.5 - 6.0 * _scale,
		bottom - margin - _nitro_size.y * 0.5 - 6.0 * _scale
	)
	queue_redraw()


## ------------------------------------------------------------------ drawing --
func _draw() -> void:
	var outline := Color(0.78, 0.86, 1.0, 0.55)
	var glass := Color(0.07, 0.09, 0.13, 0.52)
	var accent := Color(0.24, 0.66, 1.0, 0.92)
	var warn := Color(1.0, 0.72, 0.22, 0.95)
	var boost := Color(0.86, 0.38, 1.0, 0.95)

	if _mode == SettingsManager.SteeringMode.WHEEL:
		_draw_steer_stick(glass, outline, accent)
	else:
		_draw_pad(_left_center, _steer_button_radius, "◀", steer_value < -DEADZONE, glass, outline, accent)
		_draw_pad(_right_center, _steer_button_radius, "▶", steer_value > DEADZONE, glass, outline, accent)

	_draw_pad(_throttle_center, _throttle_radius, "▲", throttle_pressed, glass, outline, accent)
	_draw_capsule(_brake_center, _brake_radius, "ТОРМОЗ", brake_pressed, glass, outline, warn)
	_draw_pad(_handbrake_center, _handbrake_radius, "РУЧН", handbrake_active, glass, outline, warn)
	_draw_pill(_nitro_center, _nitro_size, "N2O", nitro_active, glass, outline, boost)
	_draw_hint()


## Круглая кнопка с подписью и подсветкой нажатия.
func _draw_pad(center: Vector2, radius: float, label: String, active: bool, glass: Color, outline: Color, glow: Color) -> void:
	if active:
		draw_circle(center, radius + 6.0 * _scale, Color(glow.r, glow.g, glow.b, 0.22))
	draw_circle(center, radius, glow if active else glass)
	draw_arc(center, radius, 0.0, TAU, 40, glow if active else outline, 2.5 * _scale, true)
	if _font != null:
		var text_size := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, int(22.0 * _scale))
		draw_string(
			_font, center - Vector2(text_size.x * 0.5, -text_size.y * 0.32), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, int(22.0 * _scale),
			Color(1.0, 1.0, 1.0, 0.95) if active else Color(0.86, 0.91, 1.0, 0.85)
		)


## Круглая кнопка с мелкой подписью по центру (тормоз, ручник).
func _draw_capsule(center: Vector2, radius: float, label: String, active: bool, glass: Color, outline: Color, glow: Color) -> void:
	if active:
		draw_circle(center, radius + 5.0 * _scale, Color(glow.r, glow.g, glow.b, 0.22))
	draw_circle(center, radius, glow if active else glass)
	draw_arc(center, radius, 0.0, TAU, 40, glow if active else outline, 2.5 * _scale, true)
	if _font != null:
		var font_size := int(12.0 * _scale)
		var text_size := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
		draw_string(
			_font, center - Vector2(text_size.x * 0.5, -text_size.y * 0.32), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size,
			Color(1.0, 1.0, 1.0, 0.95) if active else Color(0.86, 0.91, 1.0, 0.85)
		)


## Овальная кнопка (нитро).
func _draw_pill(center: Vector2, pill: Vector2, label: String, active: bool, glass: Color, outline: Color, glow: Color) -> void:
	var rect := Rect2(center - pill * 0.5, pill)
	var radius := pill.y * 0.5
	if active:
		draw_style_box(_style_box(radius + 4.0 * _scale, Color(glow.r, glow.g, glow.b, 0.22), Color.TRANSPARENT, 0.0), rect.grow(4.0 * _scale))
	draw_style_box(_style_box(radius, glow if active else glass, glow if active else outline, 2.5 * _scale), rect)
	if _font != null:
		var font_size := int(20.0 * _scale)
		var text_size := _font.get_string_size(label, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
		draw_string(
			_font, center - Vector2(text_size.x * 0.5, -text_size.y * 0.32), label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size,
			Color(1.0, 1.0, 1.0, 0.95) if active else Color(0.9, 0.86, 1.0, 0.9)
		)


## Круглый руль: внешнее кольцо, ручка в точке, куда сдвинут палец.
func _draw_steer_stick(glass: Color, outline: Color, accent: Color) -> void:
	draw_circle(_steer_center, _steer_radius, glass)
	draw_arc(_steer_center, _steer_radius, 0.0, TAU, 64, outline, 3.0 * _scale, true)
	draw_arc(_steer_center, _steer_radius * 0.62, PI * 0.15, PI * 0.85, 24, Color(outline.r, outline.g, outline.b, 0.30), 2.0 * _scale, true)
	var handle := _steer_center + Vector2(steer_value * _steer_radius * 0.62, 0.0)
	draw_circle(handle, _steer_radius * 0.30, Color(accent.r, accent.g, accent.b, 0.85))
	draw_arc(handle, _steer_radius * 0.30, 0.0, TAU, 32, Color(1.0, 1.0, 1.0, 0.75), 2.0 * _scale, true)
	if _font != null:
		var font_size := int(13.0 * _scale)
		draw_string(
			_font, _steer_center + Vector2(-_steer_radius * 0.62, _steer_radius + 18.0 * _scale), "РУЛЬ",
			HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.82, 0.88, 1.0, 0.6)
		)


func _style_box(radius: float, fill: Color, border: Color, border_width: float) -> StyleBoxFlat:
	var box := StyleBoxFlat.new()
	box.bg_color = fill
	box.set_corner_radius_all(int(maxf(radius, 0.0)))
	if border_width > 0.0:
		box.border_color = border
		box.set_border_width_all(int(maxf(border_width, 0.0)))
	return box


## Подсказка внизу по центру: как выглядит управление.
func _draw_hint() -> void:
	if _font == null:
		return
	var text := "СВАЙП — КАМЕРА"
	var font_size := int(11.0 * _scale)
	var text_size := _font.get_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, -1, font_size)
	var center := Vector2(size.x * 0.5, size.y - 8.0 * _scale)
	draw_string(
		_font, center - Vector2(text_size.x * 0.5, 0.0), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, font_size, Color(0.8, 0.86, 1.0, 0.35)
	)


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


func _in_circle(center: Vector2, radius: float, position: Vector2) -> bool:
	return center.distance_to(position) <= radius * HIT_PADDING


func _in_pill(center: Vector2, pill: Vector2, position: Vector2) -> bool:
	var half := pill * 0.5 * HIT_PADDING
	return absf(position.x - center.x) <= half.x and absf(position.y - center.y) <= half.y


func _handle_touch(event: InputEventScreenTouch) -> void:
	if event.pressed:
		# Порядок важен: сначала самые крупные и важные кнопки.
		if _in_circle(_throttle_center, _throttle_radius, event.position):
			_touches[event.index] = "throttle"
			throttle_pressed = true
			_rebuild_input()
			return
		if _in_circle(_brake_center, _brake_radius, event.position):
			_touches[event.index] = "brake"
			brake_pressed = true
			_rebuild_input()
			return
		if _in_pill(_nitro_center, _nitro_size, event.position):
			_touches[event.index] = "nitro"
			nitro_active = true
			nitro_pressed.emit()
			_rebuild_input()
			return
		if _in_circle(_handbrake_center, _handbrake_radius, event.position):
			_touches[event.index] = "handbrake"
			handbrake_active = true
			_rebuild_input()
			return
		if _mode == SettingsManager.SteeringMode.WHEEL:
			if _in_circle(_steer_center, _steer_radius, event.position):
				_steer_touch_id = event.index
				_touches[event.index] = "steer"
				_update_steer_from_position(event.position)
				return
		else:
			if _in_circle(_left_center, _steer_button_radius, event.position):
				_touches[event.index] = "steer_left"
				steer_value = -1.0
				_rebuild_input()
				return
			if _in_circle(_right_center, _steer_button_radius, event.position):
				_touches[event.index] = "steer_right"
				steer_value = 1.0
				_rebuild_input()
				return
		# Всё остальное - свободный обзор камерой (правая часть экрана и центр,
		# чтобы свайп не начинался под большим пальцем на педали).
		if event.position.y < size.y * 0.72:
			_camera_touch_id = event.index
			_touches[event.index] = "camera"
		return

	var kind: String = String(_touches.get(event.index, ""))
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
		"steer":
			if event.index == _steer_touch_id:
				_steer_touch_id = -1
			steer_value = 0.0
		"steer_left", "steer_right":
			if not _steer_button_held():
				steer_value = 0.0
		"camera":
			if event.index == _camera_touch_id:
				_camera_touch_id = -1
	_rebuild_input()


## Держит ли палец одну из кнопок руля (после отпускания второй кнопки руль
## сбрасывается только если не нажата оставшаяся).
func _steer_button_held() -> bool:
	for kind in _touches.values():
		if kind == "steer_left" or kind == "steer_right":
			return true
	return false


func _handle_drag(event: InputEventScreenDrag) -> void:
	var kind: String = String(_touches.get(event.index, ""))
	match kind:
		"steer":
			_update_steer_from_position(event.position)
		"camera":
			camera_drag += event.relative
		_:
			# Палец сполз с кнопки слишком далеко - отпускаем её, чтобы машина не
			# осталась на газу навсегда.
			if kind == "throttle" and not _in_circle(_throttle_center, _throttle_radius * HOLD_PADDING, event.position):
				_release_touch(event.index, "throttle")
			elif kind == "brake" and not _in_circle(_brake_center, _brake_radius * HOLD_PADDING, event.position):
				_release_touch(event.index, "brake")
			elif kind == "handbrake" and not _in_circle(_handbrake_center, _handbrake_radius * HOLD_PADDING, event.position):
				_release_touch(event.index, "handbrake")
			elif kind == "nitro" and not _in_pill(_nitro_center, _nitro_size * HOLD_PADDING, event.position):
				_release_touch(event.index, "nitro")
	_rebuild_input()


func _release_touch(index: int, kind: String) -> void:
	_touches.erase(index)
	match kind:
		"throttle":
			throttle_pressed = false
		"brake":
			brake_pressed = false
		"nitro":
			nitro_active = false
		"handbrake":
			handbrake_active = false


func _update_steer_from_position(position: Vector2) -> void:
	var offset := position - _steer_center
	var radius := _steer_radius * 0.8
	var value := clampf(offset.x / maxf(radius, 1.0), -1.0, 1.0)
	steer_value = 0.0 if absf(value) < DEADZONE else value


## The control object handed to the car.
func _rebuild_input() -> void:
	# Тормоз сильнее газа: если нажаты оба, машина тормозит, а не «едет и
	# тормозит одновременно».
	input.throttle = 0.0 if brake_pressed else (1.0 if throttle_pressed else 0.0)
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


## Вызывается при смене раскладки в настройках.
func touch_controls_refresh() -> void:
	_mode = Settings.steering_mode
	_update_layout()
	reset_state()


## Нажата ли точка внутри какой-либо кнопки (для тестов и отладки).
func hit_area_at(position: Vector2) -> String:
	if _in_circle(_throttle_center, _throttle_radius, position):
		return "throttle"
	if _in_circle(_brake_center, _brake_radius, position):
		return "brake"
	if _in_pill(_nitro_center, _nitro_size, position):
		return "nitro"
	if _in_circle(_handbrake_center, _handbrake_radius, position):
		return "handbrake"
	if _mode == SettingsManager.SteeringMode.WHEEL:
		if _in_circle(_steer_center, _steer_radius, position):
			return "steer"
	elif _in_circle(_left_center, _steer_button_radius, position):
		return "steer_left"
	elif _in_circle(_right_center, _steer_button_radius, position):
		return "steer_right"
	return "camera" if position.y < size.y * 0.72 else ""


func status() -> Dictionary:
	return {
		"steer": snappedf(steer_value, 0.01),
		"throttle": input.throttle,
		"brake": input.brake,
		"handbrake": input.handbrake,
		"nitro": input.nitro,
		"touches": _touches.size(),
		"mode": "WHEEL" if _mode == SettingsManager.SteeringMode.WHEEL else "BUTTONS",
		"throttle_center": _throttle_center,
		"brake_center": _brake_center,
		"steer_center": _steer_center,
	}
