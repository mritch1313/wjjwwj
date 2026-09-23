class_name Hud
extends CanvasLayer

## The whole in-game interface, built in code (so there is no .tscn to keep in
## sync and it scales from a 720p phone to a tablet):
##   * speed + gear, nitro charge with the boost indicator,
##   * the pursuit panel: distance to the closest police car, the current roles,
##     the arrest progress and the escape timer,
##   * toasts, the minimap and an optional debug overlay (F1 / the pause menu).

signal pause_requested()
signal pursuit_requested()
signal reset_requested()

const BASE_WIDTH := 720.0

var player: VehicleController = null
var police_manager: PoliceManager = null
var minimap: Minimap = null

var show_debug: bool = false

var _root: Control = null
var _speed_label: Label = null
var _gear_label: Label = null
var _nitro_bar: ColorRect = null
var _nitro_label: Label = null
var _pursuit_panel: PanelContainer = null
var _pursuit_label: Label = null
var _roles_label: Label = null
var _arrest_bar: ColorRect = null
var _arrest_label: Label = null
var _toast_label: Label = null
var _debug_label: Label = null
var _hint_label: Label = null
var _pause_button: Button = null
var _chase_button: Button = null
var _font_scale: float = 1.0
var _toast_timer_s: float = 0.0
var _panel_timer_s: float = 0.0
var _last_debug_update_s: float = 0.0
var _debug_lines: PackedStringArray = PackedStringArray()


func _ready() -> void:
	layer = 5
	_build()
	Game.toast.connect(show_toast)
	Game.pursuit_started.connect(_on_pursuit_started)
	Game.pursuit_ended.connect(_on_pursuit_ended)
	get_viewport().size_changed.connect(_apply_layout)
	_apply_layout()


## ------------------------------------------------------------------- building
func _build() -> void:
	_root = Control.new()
	_root.name = "HudRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)

	# --- speed block (top left, under the pause button)
	var speed_panel := PanelContainer.new()
	speed_panel.name = "SpeedPanel"
	speed_panel.add_theme_stylebox_override("panel", _panel_style())
	_root.add_child(speed_panel)
	var speed_box := VBoxContainer.new()
	speed_box.name = "SpeedBox"
	speed_box.add_theme_constant_override("separation", 0)
	speed_panel.add_child(speed_box)
	_speed_label = Label.new()
	_speed_label.name = "Speed"
	_speed_label.text = "0"
	_speed_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	speed_box.add_child(_speed_label)
	_gear_label = Label.new()
	_gear_label.name = "Gear"
	_gear_label.text = "км/ч · N"
	_gear_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	speed_box.add_child(_gear_label)

	# --- nitro bar (below the speed block)
	_nitro_bar = ColorRect.new()
	_nitro_bar.name = "NitroBar"
	_nitro_bar.color = Color(0.25, 0.7, 1.0, 0.9)
	_root.add_child(_nitro_bar)
	_nitro_label = Label.new()
	_nitro_label.name = "NitroLabel"
	_nitro_label.text = "NITRO"
	_root.add_child(_nitro_label)

	# --- pursuit panel (top centre-right)
	_pursuit_panel = PanelContainer.new()
	_pursuit_panel.name = "PursuitPanel"
	_pursuit_panel.add_theme_stylebox_override("panel", _panel_style())
	_pursuit_panel.visible = false
	_root.add_child(_pursuit_panel)
	var pursuit_box := VBoxContainer.new()
	pursuit_box.add_theme_constant_override("separation", 2)
	_pursuit_panel.add_child(pursuit_box)
	_pursuit_label = Label.new()
	_pursuit_label.text = L10n.t("pursuit_active")
	pursuit_box.add_child(_pursuit_label)
	_roles_label = Label.new()
	_roles_label.text = ""
	pursuit_box.add_child(_roles_label)
	_arrest_bar = ColorRect.new()
	_arrest_bar.color = Color(0.95, 0.35, 0.25, 0.9)
	_arrest_bar.custom_minimum_size = Vector2(0.0, 8.0)
	pursuit_box.add_child(_arrest_bar)
	_arrest_label = Label.new()
	_arrest_label.text = ""
	pursuit_box.add_child(_arrest_label)

	# --- minimap (top right)
	minimap = Minimap.new()
	minimap.name = "Minimap"
	_root.add_child(minimap)

	# --- quick "start the chase" button (free roam only)
	_chase_button = Button.new()
	_chase_button.name = "ChaseButton"
	_chase_button.text = L10n.t("start_pursuit")
	_chase_button.focus_mode = Control.FOCUS_NONE
	_chase_button.pressed.connect(func() -> void: pursuit_requested.emit())
	_root.add_child(_chase_button)

	# --- pause button
	_pause_button = Button.new()
	_pause_button.name = "Pause"
	_pause_button.text = "II"
	_pause_button.focus_mode = Control.FOCUS_NONE
	_pause_button.pressed.connect(func() -> void: pause_requested.emit())
	_root.add_child(_pause_button)

	# --- toast + hint + debug
	_toast_label = Label.new()
	_toast_label.name = "Toast"
	_toast_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_toast_label.modulate.a = 0.0
	_root.add_child(_toast_label)
	_hint_label = Label.new()
	_hint_label.name = "Hint"
	_hint_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_hint_label.text = L10n.t("tips_free_roam")
	_root.add_child(_hint_label)
	_debug_label = Label.new()
	_debug_label.name = "Debug"
	_debug_label.visible = false
	_root.add_child(_debug_label)
	_apply_fonts()


func _panel_style() -> StyleBoxFlat:
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.05, 0.07, 0.62)
	style.border_color = Color(0.55, 0.72, 0.95, 0.35)
	style.set_border_width_all(1)
	style.set_corner_radius_all(8)
	style.set_content_margin_all(8.0)
	return style


## --------------------------------------------------------------- layout/fonts
func _apply_fonts() -> void:
	if _speed_label == null:
		return
	_speed_label.add_theme_font_size_override("font_size", int(46.0 * _font_scale))
	_gear_label.add_theme_font_size_override("font_size", int(17.0 * _font_scale))
	_nitro_label.add_theme_font_size_override("font_size", int(13.0 * _font_scale))
	_pursuit_label.add_theme_font_size_override("font_size", int(18.0 * _font_scale))
	_roles_label.add_theme_font_size_override("font_size", int(14.0 * _font_scale))
	_arrest_label.add_theme_font_size_override("font_size", int(14.0 * _font_scale))
	_toast_label.add_theme_font_size_override("font_size", int(20.0 * _font_scale))
	_hint_label.add_theme_font_size_override("font_size", int(15.0 * _font_scale))
	_debug_label.add_theme_font_size_override("font_size", int(13.0 * _font_scale))


func _apply_layout() -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	_font_scale = clampf(viewport_size.x / BASE_WIDTH, 0.7, 1.8) * Settings.hud_scale
	_apply_fonts()
	var margin := 10.0 * _font_scale
	var map_size := clampf(viewport_size.x * 0.34, 130.0, 300.0) * Settings.hud_scale
	minimap.size = Vector2(map_size, map_size * 0.85)
	minimap.position = Vector2(viewport_size.x - minimap.size.x - margin, margin)
	minimap.range_m = clampf(240.0 + map_size, 280.0, 620.0)
	_pause_button.size = Vector2(44.0, 40.0) * _font_scale
	_pause_button.position = Vector2(margin, margin)
	_chase_button.size = Vector2(150.0, 40.0) * _font_scale
	_chase_button.position = Vector2(margin + _pause_button.size.x + 6.0 * _font_scale, margin)
	minimap.visible = Settings.show_minimap
	_root.get_node("SpeedPanel").position = Vector2(margin, margin + _pause_button.size.y + 6.0 * _font_scale)
	_root.get_node("SpeedPanel").size = Vector2(170.0, 0.0) * _font_scale
	_nitro_bar.size = Vector2(170.0 * _font_scale, 12.0 * _font_scale)
	_nitro_bar.position = _root.get_node("SpeedPanel").position + Vector2(0.0, 86.0 * _font_scale)
	_nitro_label.position = _nitro_bar.position + Vector2(0.0, -1.0 * _font_scale)
	_nitro_label.size = _nitro_bar.size
	_nitro_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_pursuit_panel.position = Vector2(margin, _nitro_bar.position.y + 26.0 * _font_scale)
	_pursuit_panel.size = Vector2(viewport_size.x * 0.52, 0.0)
	_toast_label.size = Vector2(viewport_size.x * 0.9, 0.0)
	_toast_label.position = Vector2(viewport_size.x * 0.05, viewport_size.y * 0.30)
	_hint_label.size = Vector2(viewport_size.x * 0.9, 0.0)
	_hint_label.position = Vector2(viewport_size.x * 0.05, viewport_size.y * 0.55)
	_debug_label.position = Vector2(margin, viewport_size.y * 0.62)
	_debug_label.size = Vector2(viewport_size.x - margin * 2.0, 0.0)


## ------------------------------------------------------------------- binding
func bind(player_car: VehicleController, police: PoliceManager, roads: RoadNetwork) -> void:
	player = player_car
	police_manager = police
	minimap.player = player_car
	minimap.police_manager = police
	minimap.set_world(roads)
	if police != null:
		if not police.arrest_progress.is_connected(_on_arrest_progress):
			police.arrest_progress.connect(_on_arrest_progress)


func _process(delta: float) -> void:
	if player == null or not is_instance_valid(player):
		return
	_speed_label.text = "%d" % roundi(player.speed_kmh())
	var gear_text := "R" if player.is_reversing() else ("N" if absf(player.forward_speed_ms()) < 0.3 else str(player.gear))
	_gear_label.text = "%s · %s" % [L10n.t("speed"), gear_text]
	var nitro_value: Variant = player.nitro
	if nitro_value is NitroSystem:
		var nitro := nitro_value as NitroSystem
		var ratio := nitro.charge_ratio()
		_nitro_bar.size.x = maxf(170.0 * _font_scale * ratio, 1.0)
		_nitro_bar.color = Color(1.0, 0.55, 0.2, 0.95) if nitro.active else Color(0.25, 0.7, 1.0, 0.9)
		_nitro_label.text = "%s %d%%" % [L10n.t("nitro"), roundi(ratio * 100.0)]
	# --- toasts fade out
	if _toast_timer_s > 0.0:
		_toast_timer_s -= delta
		_toast_label.modulate.a = clampf(_toast_timer_s, 0.0, 1.0)
	elif _toast_label.modulate.a > 0.0:
		_toast_label.modulate.a = maxf(_toast_label.modulate.a - delta, 0.0)
	# --- the hint disappears as soon as the player drives
	if _hint_label.modulate.a > 0.0 and player.total_distance_m > 40.0:
		_hint_label.modulate.a = maxf(_hint_label.modulate.a - delta * 0.5, 0.0)
	# the quick chase button only makes sense while cruising around
	_chase_button.visible = not Game.is_pursuit_active() and Game.world != null
	# --- pursuit panel (updated a few times per second, not every frame)
	_panel_timer_s -= delta
	if _panel_timer_s <= 0.0:
		_panel_timer_s = 0.2
		_update_pursuit_panel()
	if show_debug:
		_last_debug_update_s -= delta
		if _last_debug_update_s <= 0.0:
			_last_debug_update_s = 0.25
			_update_debug()


func _update_pursuit_panel() -> void:
	var active := Game.is_pursuit_active()
	_pursuit_panel.visible = active
	if not active:
		return
	var status := Game.pursuit_status()
	var roles: Array = status.get("roles", [])
	var role_text := PackedStringArray()
	for role in roles:
		role_text.append(String(role))
	_pursuit_label.text = "%s · %s %d · %s %d м" % [
		L10n.t("pursuit_active"),
		L10n.t("police_units"), int(status.get("cars", 0)),
		L10n.t("distance_to_player"), roundi(float(status.get("closest_distance", 0.0))),
	]
	_roles_label.text = "%s: %s" % [L10n.t("pursuit_roles"), " ".join(role_text)]
	var arrest: Dictionary = status.get("arrest", {})
	var progress := float(arrest.get("progress", 0.0))
	_arrest_bar.size.x = maxf(_pursuit_panel.size.x * progress, 1.0)
	var escape := clampf(float(status.get("hidden_time_s", 0.0)) / maxf(Config.gameplay.escape_time_s, 0.001), 0.0, 1.0)
	if progress > 0.02:
		_arrest_label.text = "%s %d%%" % [L10n.t("arrest_progress"), roundi(progress * 100.0)]
		_arrest_bar.color = Color(0.95, 0.35, 0.25, 0.95)
	elif escape > 0.02:
		_arrest_label.text = "%s %d%%" % [L10n.t("escape_progress"), roundi(escape * 100.0)]
		_arrest_bar.color = Color(0.35, 0.85, 0.45, 0.95)
	else:
		_arrest_label.text = L10n.t("escape_hint")
		_arrest_bar.color = Color(0.5, 0.6, 0.75, 0.6)


func _update_debug() -> void:
	_debug_lines = PackedStringArray()
	_debug_lines.append("%s %d" % [L10n.t("fps"), Engine.get_frames_per_second()])
	_debug_lines.append("кадр %d мс / цель %d мс" % [int(Perf.average_frame_ms), int(Perf.target_frame_ms)])
	if Game.world != null and Game.world.has_method("stats"):
		var world_stats: Dictionary = Game.world.call("stats")
		_debug_lines.append("%s %d  треугольники %d" % [
			L10n.t("chunks"), int(world_stats.get("chunks", 0)), int(world_stats.get("triangles", 0))
		])
	if player != null and is_instance_valid(player):
		var car := player.status()
		_debug_lines.append("авто %.0f км/ч  rpm %d  передача %d" % [
			float(car["speed_kmh"]), int(car["rpm"]), int(car["gear"])
		])
		_debug_lines.append("занос %.1f°  скольжение %.2f  колёс %d  покрытие %s" % [
			float(car["drifting"]) * 0.0 + float(player.drift_angle_deg),
			float(car["slip"]), int(car["grounded_wheels"]), String(car["surface_name"])
		])
		var wheels: Array = car.get("wheels", [])
		var loads := PackedStringArray()
		for wheel in wheels:
			loads.append("%d" % int(float(wheel.get("load", 0.0)) / 100.0))
		_debug_lines.append("нагрузка колёс (x100 Н): %s" % " ".join(loads))
	if police_manager != null and is_instance_valid(police_manager):
		for row in police_manager.debug_rows():
			var planner: Dictionary = row.get("planner", {})
			_debug_lines.append("P%d %s %.0fм %.0fкм/ч цель %d узл%s" % [
				int(row.get("index", 0)), String(row.get("role", "?")),
				float(row.get("distance", 0.0)), float(row.get("speed_kmh", 0.0)),
				int(planner.get("waypoints", 0)),
				" (граф)" if bool(planner.get("road_graph", false)) else " (прямая)",
			])
	_debug_label.text = "\n".join(_debug_lines)


## ------------------------------------------------------------------- signals
func show_toast(message: String) -> void:
	_toast_label.text = message
	_toast_label.modulate.a = 1.0
	_toast_timer_s = 3.0


func set_debug(enabled: bool) -> void:
	show_debug = enabled
	_debug_label.visible = enabled
	Settings.show_debug_overlay = enabled
	Settings.save_now()


func _on_arrest_progress(_progress: float, _reason: String) -> void:
	# the panel is refreshed on its own timer; this only keeps the HUD reactive
	if not Game.is_pursuit_active():
		_pursuit_panel.visible = false


func _on_pursuit_started(_count: int, _level: int) -> void:
	_pursuit_panel.visible = true
	_hint_label.modulate.a = 0.0


func _on_pursuit_ended(_reason: String, _duration: float) -> void:
	_pursuit_panel.visible = false


func status() -> Dictionary:
	return {
		"show_debug": show_debug,
		"font_scale": _font_scale,
		"minimap": minimap.stats() if minimap != null else {},
		"debug_lines": _debug_lines,
	}
