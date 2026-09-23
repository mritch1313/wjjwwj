class_name MainMenu
extends CanvasLayer

## Every screen that is not the driving HUD: the main menu (police count, AI
## level, paint, graphics), the loading curtain, the pause menu, the settings
## panel and the result screen after a pursuit.
##
## All of it is built in code for the same reason as the HUD: one source of
## truth, no .tscn drift, and a layout that adapts to the phone's aspect ratio
## (the design target is a 720x1280 portrait screen).

signal start_pursuit_requested(police_count: int, ai_level: int)
signal free_roam_requested()
signal resume_requested()
signal quit_to_free_roam_requested()
signal quality_changed(index: int)
signal paint_changed(index: int)
## Кнопка «Y» в настройках: поднять машину игрока на метр (сколько угодно раз).
signal lift_car_requested(meters: float)

const BASE_WIDTH := 720.0

var ui_scale: float = 1.0
var ai_level: int = 2
var police_count: int = 3
var paint_index: int = 0
var quality_index: int = 1

var _root: Control = null
var _menu_panel: PanelContainer = null
var _pause_panel: PanelContainer = null
var _result_panel: PanelContainer = null
var _settings_panel: PanelContainer = null
var _loading_panel: PanelContainer = null
var _stats_label: Label = null
var _level_label: Label = null
var _level_description: Label = null
var _police_label: Label = null
var _paint_label: Label = null
var _quality_label: Label = null
var _result_title: Label = null
var _result_stats: VBoxContainer = null
var _loading_label: Label = null
var _loading_bar: ColorRect = null
var _loading_bar_bg: ColorRect = null
var _settings_hint: Label = null
var _orientation_button: Button = null
## Сколько раз нажимали «Y» в настройках: в сообщении видно суммарный подъём.
var _lift_count: int = 0
var _loading_progress: float = 0.0


func _ready() -> void:
	layer = 20
	process_mode = Node.PROCESS_MODE_ALWAYS
	ai_level = clampi(Settings.ai_level, 1, Config.police.level_count())
	police_count = clampi(Settings.police_count, Config.gameplay.min_police_count, Config.gameplay.max_police_count)
	paint_index = clampi(Settings.player_paint_index, 0, Config.vehicle_player.paint_count() - 1)
	quality_index = clampi(Settings.quality_index, 0, Config.quality_preset_count() - 1)
	_build()
	get_viewport().size_changed.connect(_layout)
	_layout()
	_refresh_labels()


## ------------------------------------------------------------------- building
func _build() -> void:
	_root = Control.new()
	_root.name = "MenuRoot"
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_root)
	_build_menu_panel()
	_build_pause_panel()
	_build_result_panel()
	_build_settings_panel()
	_build_loading_panel()


func _build_menu_panel() -> void:
	_menu_panel = _panel("MainMenuPanel")
	var box := _vbox(_menu_panel)
	_title(box, L10n.t("app_title"), 46)
	_title(box, L10n.t("app_subtitle"), 16)
	# --- police count
	_title(box, L10n.t("police_count"), 15, Color(0.62, 0.76, 0.98))
	var count_row := _hbox(box)
	_button(count_row, "−", func() -> void: _change_count(-1), 26, 56.0)
	_police_label = _value_label(count_row)
	_button(count_row, "+", func() -> void: _change_count(1), 26, 56.0)
	# --- AI level
	_title(box, L10n.t("ai_level"), 15, Color(0.62, 0.76, 0.98))
	var level_row := _hbox(box)
	_button(level_row, "−", func() -> void: _change_level(-1), 26, 56.0)
	_level_label = _value_label(level_row)
	_button(level_row, "+", func() -> void: _change_level(1), 26, 56.0)
	_level_description = _title(box, "", 13, Color(0.75, 0.8, 0.9))
	# --- paint colour
	_title(box, L10n.t("paint_color"), 15, Color(0.62, 0.76, 0.98))
	var paint_row := _hbox(box)
	_button(paint_row, "◀", func() -> void: _change_paint(-1), 22, 56.0)
	_paint_label = _value_label(paint_row)
	_button(paint_row, "▶", func() -> void: _change_paint(1), 22, 56.0)
	# --- graphics
	_title(box, L10n.t("quality"), 15, Color(0.62, 0.76, 0.98))
	var quality_row := _hbox(box)
	_button(quality_row, "◀", func() -> void: _change_quality(-1), 22, 56.0)
	_quality_label = _value_label(quality_row)
	_button(quality_row, "▶", func() -> void: _change_quality(1), 22, 56.0)
	# --- start buttons
	_button(box, L10n.t("start_pursuit"), _on_start_pressed, 26, 0.0, 14.0)
	_button(box, L10n.t("free_roam"), func() -> void: free_roam_requested.emit(), 20, 0.0, 4.0)
	_button(box, L10n.t("settings"), func() -> void: _show_settings(true), 17)
	_stats_label = _title(box, "", 13, Color(0.7, 0.78, 0.92))


func _build_pause_panel() -> void:
	_pause_panel = _panel("PausePanel")
	var box := _vbox(_pause_panel)
	_title(box, L10n.t("pause"), 34)
	_button(box, L10n.t("resume"), func() -> void: resume_requested.emit(), 22, 0.0, 10.0)
	_button(box, L10n.t("settings"), func() -> void: _show_settings(true), 18)
	_button(box, L10n.t("debug_toggle"), _toggle_debug, 17)
	_button(box, L10n.t("reset_car"), _reset_car, 17)
	_button(box, L10n.t("to_garage"), func() -> void: quit_to_free_roam_requested.emit(), 17)
	_pause_panel.visible = false


func _build_result_panel() -> void:
	_result_panel = _panel("ResultPanel")
	var box := _vbox(_result_panel)
	_result_title = _title(box, "", 30)
	_result_stats = VBoxContainer.new()
	_result_stats.add_theme_constant_override("separation", 4)
	box.add_child(_result_stats)
	_button(box, L10n.t("restart"), _on_start_pressed, 22, 0.0, 10.0)
	_button(box, L10n.t("to_garage"), func() -> void: quit_to_free_roam_requested.emit(), 18)
	_result_panel.visible = false


func _build_settings_panel() -> void:
	_settings_panel = _panel("SettingsPanel")
	var box := _vbox(_settings_panel)
	_title(box, L10n.t("settings"), 30)
	_button(box, L10n.t("auto_accelerate"), _toggle_auto_accelerate, 17)
	_button(box, L10n.t("steering_wheel") + " / " + L10n.t("steering_buttons"), _toggle_steering_mode, 17)
	_button(box, L10n.t("camera_invert"), _toggle_camera_invert, 17)
	_button(box, L10n.t("vibration"), _toggle_vibration, 17)
	_button(box, L10n.t("minimap"), _toggle_minimap, 17)
	_button(box, L10n.t("hud_scale"), _cycle_hud_scale, 17)
	_button(box, L10n.t("language"), _toggle_language, 17)
	_orientation_button = _button(box, _orientation_label(), _cycle_orientation, 17)
	_button(box, L10n.t("lift_car"), _lift_car, 17)
	_title(box, L10n.t("lift_car_hint"), 12, Color(0.66, 0.75, 0.88))
	_settings_hint = _title(box, "", 13, Color(0.7, 0.8, 0.95))
	_button(box, L10n.t("close"), func() -> void: _show_settings(false), 20, 0.0, 8.0)
	_settings_panel.visible = false


func _build_loading_panel() -> void:
	_loading_panel = _panel("LoadingPanel")
	var box := _vbox(_loading_panel)
	_title(box, L10n.t("loading_world"), 26)
	_loading_label = _title(box, L10n.t("generating_chunks"), 15, Color(0.75, 0.82, 0.92))
	_loading_bar_bg = ColorRect.new()
	_loading_bar_bg.color = Color(0.1, 0.12, 0.16, 0.9)
	_loading_bar_bg.custom_minimum_size = Vector2(0.0, 14.0)
	box.add_child(_loading_bar_bg)
	_loading_bar = ColorRect.new()
	_loading_bar.color = Color(0.3, 0.72, 1.0, 0.95)
	_loading_bar.size = Vector2(1.0, 14.0)
	_loading_bar_bg.add_child(_loading_bar)
	_loading_panel.visible = false


## -------------------------------------------------------------- ui factories
func _panel(node_name: String) -> PanelContainer:
	var panel := PanelContainer.new()
	panel.name = node_name
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.04, 0.05, 0.07, 0.88)
	style.border_color = Color(0.55, 0.72, 0.95, 0.4)
	style.set_border_width_all(2)
	style.set_corner_radius_all(14)
	style.set_content_margin_all(16.0)
	panel.add_theme_stylebox_override("panel", style)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(panel)
	panel.set_meta("top_offset", 40.0)
	return panel


func _vbox(parent: Node, separation: float = 8.0) -> VBoxContainer:
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", int(separation))
	parent.add_child(box)
	return box


func _hbox(parent: Node) -> HBoxContainer:
	var box := HBoxContainer.new()
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	box.add_theme_constant_override("separation", 10)
	parent.add_child(box)
	return box


func _title(parent: Node, text: String, font_size: int, color: Color = Color(0.96, 0.97, 1.0)) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	label.add_theme_font_size_override("font_size", font_size)
	label.add_theme_color_override("font_color", color)
	parent.add_child(label)
	return label


func _value_label(parent: Node) -> Label:
	var label := Label.new()
	label.text = "-"
	label.custom_minimum_size = Vector2(150.0, 0.0)
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 22)
	label.add_theme_color_override("font_color", Color(1.0, 0.9, 0.55))
	parent.add_child(label)
	return label


func _button(
	parent: Node,
	text: String,
	callback: Callable,
	font_size: int = 18,
	min_width: float = 0.0,
	margin_top: float = 0.0
) -> Button:
	var button := Button.new()
	button.text = text
	button.focus_mode = Control.FOCUS_NONE
	button.add_theme_font_size_override("font_size", font_size)
	button.custom_minimum_size = Vector2(min_width, maxf(float(font_size) * 2.0, 40.0))
	button.pressed.connect(callback)
	if margin_top > 0.0:
		var wrapper := MarginContainer.new()
		wrapper.add_theme_constant_override("margin_top", int(margin_top))
		wrapper.add_child(button)
		parent.add_child(wrapper)
	else:
		parent.add_child(button)
	return button


## -------------------------------------------------------------------- layout
func _layout() -> void:
	var viewport_size := get_viewport().get_visible_rect().size
	ui_scale = clampf(viewport_size.x / BASE_WIDTH, 0.7, 1.6)
	for panel in [_menu_panel, _pause_panel, _result_panel, _settings_panel, _loading_panel]:
		if panel == null:
			continue
		var width: float = minf(viewport_size.x - 24.0, 420.0 * ui_scale)
		panel.anchor_left = 0.5
		panel.anchor_right = 0.5
		panel.offset_left = -width * 0.5
		panel.offset_right = width * 0.5
		var top: float = float(panel.get_meta("top_offset", 40.0)) * ui_scale
		panel.offset_top = top
		panel.offset_bottom = top
		panel.grow_vertical = Control.GROW_DIRECTION_END
		panel.grow_horizontal = Control.GROW_DIRECTION_BOTH
		panel.reset_size()
	if _loading_bar != null and _loading_bar_bg != null:
		_loading_bar_bg.custom_minimum_size.x = minf(viewport_size.x - 90.0, 360.0 * ui_scale)
		_loading_bar.size = Vector2(maxf(_loading_bar_bg.size.x * clampf(_loading_progress, 0.02, 1.0), 2.0), 14.0)


## -------------------------------------------------------------------- actions
func _change_count(step: int) -> void:
	police_count = clampi(
		police_count + step, Config.gameplay.min_police_count, Config.gameplay.max_police_count
	)
	Settings.police_count = police_count
	Settings.save_now()
	Game.set_police_count(police_count)
	_refresh_labels()


func _change_level(step: int) -> void:
	ai_level = clampi(ai_level + step, 1, Config.police.level_count())
	Settings.ai_level = ai_level
	Settings.save_now()
	Game.set_ai_level(ai_level)
	_refresh_labels()


func _change_paint(step: int) -> void:
	paint_index = posmod(paint_index + step, Config.vehicle_player.paint_count())
	Settings.player_paint_index = paint_index
	Settings.save_now()
	paint_changed.emit(paint_index)
	_refresh_labels()


func _change_quality(step: int) -> void:
	quality_index = clampi(quality_index + step, 0, Config.quality_preset_count() - 1)
	Settings.set_quality_index(quality_index)
	quality_changed.emit(quality_index)
	_refresh_labels()
	Game.toast.emit(L10n.t("quality_applied") % Settings.quality_title())


func _on_start_pressed() -> void:
	show_menu(false)
	show_pause(false)
	_result_panel.visible = false
	_settings_panel.visible = false
	start_pursuit_requested.emit(police_count, ai_level)


func _toggle_debug() -> void:
	if Game.hud != null and Game.hud.has_method("set_debug"):
		Game.hud.call("set_debug", not Settings.show_debug_overlay)


func _reset_car() -> void:
	if Game.player != null and Game.player.has_method("recover_to_road"):
		Game.player.call("recover_to_road")
	resume_requested.emit()


func _toggle_auto_accelerate() -> void:
	Settings.auto_accelerate = not Settings.auto_accelerate
	Settings.save_now()
	_refresh_settings_hint()


func _toggle_steering_mode() -> void:
	Settings.steering_mode = (
		SettingsManager.SteeringMode.WHEEL
		if Settings.steering_mode == SettingsManager.SteeringMode.BUTTONS
		else SettingsManager.SteeringMode.BUTTONS
	)
	Settings.save_now()
	if Game.player != null and Game.player.has_method("touch_controls_refresh"):
		Game.player.call("touch_controls_refresh")
	_refresh_settings_hint()


func _toggle_camera_invert() -> void:
	Settings.camera_invert_y = not Settings.camera_invert_y
	Settings.save_now()
	_refresh_settings_hint()


func _toggle_vibration() -> void:
	Settings.vibration = not Settings.vibration
	Settings.save_now()
	_refresh_settings_hint()


func _toggle_minimap() -> void:
	Settings.show_minimap = not Settings.show_minimap
	Settings.save_now()
	_refresh_settings_hint()


func _cycle_hud_scale() -> void:
	var steps := [0.85, 1.0, 1.15, 1.3]
	var index := steps.find(Settings.hud_scale)
	Settings.hud_scale = steps[(index + 1) % steps.size()]
	Settings.save_now()
	_refresh_settings_hint()


## Ориентация экрана: по умолчанию портрет из проекта, но игрок может
## принудительно выбрать вертикальную или горизонтальную - на телефоне это
## вопрос удобства, а не только графики.
## Каждое нажатие добавляет машине метр высоты (см. MainScene._on_lift_car_requested).
func _lift_car() -> void:
	_lift_count += 1
	lift_car_requested.emit(1.0)
	Game.toast.emit(L10n.t("lift_car_applied") % _lift_count)


func _cycle_orientation() -> void:
	Settings.orientation_mode = (Settings.orientation_mode + 1) % 3
	Settings.apply_orientation()
	Settings.save_now()
	if _orientation_button != null:
		_orientation_button.text = _orientation_label()
	Game.toast.emit(L10n.t("orientation_applied") % _orientation_label())


func _orientation_label() -> String:
	match Settings.orientation_mode:
		1:
			return "%s: %s" % [L10n.t("orientation"), L10n.t("orientation_landscape")]
		2:
			return "%s: %s" % [L10n.t("orientation"), L10n.t("orientation_auto")]
		_:
			return "%s: %s" % [L10n.t("orientation"), L10n.t("orientation_portrait")]


func _toggle_language() -> void:
	Settings.language = "en" if Settings.language == "ru" else "ru"
	Settings.save_now()
	_refresh_settings_hint()


func _show_settings(visible_now: bool) -> void:
	_settings_panel.visible = visible_now
	if visible_now:
		_pause_panel.visible = false
		_menu_panel.visible = false
		_refresh_settings_hint()
	else:
		_menu_panel.visible = true
	_root.mouse_filter = Control.MOUSE_FILTER_STOP if _any_visible() else Control.MOUSE_FILTER_IGNORE


## ------------------------------------------------------------------- screens
func show_menu(visible_now: bool) -> void:
	_menu_panel.visible = visible_now
	if visible_now:
		_pause_panel.visible = false
		_result_panel.visible = false
		_settings_panel.visible = false
	_refresh_labels()
	_root.mouse_filter = Control.MOUSE_FILTER_STOP if _any_visible() else Control.MOUSE_FILTER_IGNORE


func show_pause(visible_now: bool) -> void:
	_pause_panel.visible = visible_now
	if visible_now:
		_menu_panel.visible = false
		_root.mouse_filter = Control.MOUSE_FILTER_STOP
	else:
		_root.mouse_filter = Control.MOUSE_FILTER_STOP if _any_visible() else Control.MOUSE_FILTER_IGNORE


func show_loading(visible_now: bool, progress: float = 0.0) -> void:
	_loading_panel.visible = visible_now
	_loading_progress = progress
	_layout()


func report_loading(progress: float, chunks: int) -> void:
	_loading_progress = clampf(progress, 0.0, 1.0)
	_loading_label.text = "%s %d%%  (%s %d)" % [
		L10n.t("generating_chunks"), roundi(_loading_progress * 100.0), L10n.t("chunks"), chunks
	]
	_layout()


func show_result(arrested: bool, duration_s: float) -> void:
	_result_panel.visible = true
	_menu_panel.visible = false
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	_result_title.text = L10n.t("arrested_title") if arrested else L10n.t("escaped_title")
	for child in _result_stats.get_children():
		_result_stats.remove_child(child)
		child.queue_free()
	var chase_stats: Dictionary = {}
	if Game.police_manager != null and Game.police_manager.has_method("status"):
		chase_stats = Game.police_manager.call("status")
	_result_stats.add_child(_stat_label(L10n.t("pursuit_time") + ": " + _format_time(duration_s)))
	_result_stats.add_child(_stat_label("%s: %.2f %s" % [
		L10n.t("driven_distance"), Game.total_distance_m / 1000.0, L10n.t("distance_km")
	]))
	_result_stats.add_child(_stat_label("%s: %d   %s: %d" % [
		L10n.t("arrests_total"), Save.arrests, L10n.t("escapes_total"), Save.escapes
	]))
	_result_stats.add_child(_stat_label("%s: %s" % [
		L10n.t("ai_level"), L10n.t("ai_level_short") % ai_level
	]))
	if not chase_stats.is_empty():
		_result_stats.add_child(_stat_label("%s: %d   %s: %.0f %s" % [
			L10n.t("police_units"), int(chase_stats.get("cars", 0)),
			L10n.t("distance_to_player"), float(chase_stats.get("closest_distance", 0.0)), "м"
		]))


func _stat_label(text: String) -> Label:
	var label := Label.new()
	label.text = text
	label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	label.add_theme_font_size_override("font_size", 16)
	label.add_theme_color_override("font_color", Color(0.88, 0.92, 1.0))
	return label


func _any_visible() -> bool:
	return _menu_panel.visible or _pause_panel.visible or _result_panel.visible or _settings_panel.visible


func _refresh_labels() -> void:
	if _police_label == null:
		return
	_police_label.text = str(police_count)
	_level_label.text = L10n.t("ai_level_short") % ai_level
	_level_description.text = Config.police.params_for_level(ai_level).description
	_paint_label.text = Config.vehicle_player.paint_color_name(paint_index)
	_quality_label.text = Settings.quality_title()
	var quality := Config.quality_preset(quality_index)
	if quality != null:
		_quality_label.tooltip_text = quality.description
	_stats_label.text = "%s: %.1f   %s: %d   %s: %d" % [
		L10n.t("driven_distance"), Save.total_distance_km,
		L10n.t("arrests_total"), Save.arrests,
		L10n.t("escapes_total"), Save.escapes,
	]


func _refresh_settings_hint() -> void:
	if _settings_hint == null:
		return
	_settings_hint.text = "%s: %s · %s: %s · %s: %.2f" % [
		L10n.t("auto_accelerate"), ("ВКЛ" if Settings.auto_accelerate else "ВЫКЛ"),
		L10n.t("language"), Settings.language.to_upper(),
		L10n.t("hud_scale"), Settings.hud_scale,
	]


func _format_time(seconds: float) -> String:
	var total := int(maxf(seconds, 0.0))
	return "%02d:%02d" % [total / 60, total % 60]


func status() -> Dictionary:
	return {
		"menu": _menu_panel.visible,
		"pause": _pause_panel.visible,
		"result": _result_panel.visible,
		"settings": _settings_panel.visible,
		"ai_level": ai_level,
		"police_count": police_count,
		"quality": Settings.quality_title(),
	}
