class_name SettingsManager
extends Node

## User preferences + graphics presets (autoload "Settings").
## Everything is persisted to user://settings.cfg so the phone remembers the
## chosen quality level, control layout and audio volumes.

signal quality_changed(preset: GraphicsQuality)
signal settings_changed

enum SteeringMode { BUTTONS, WHEEL }

const CONFIG_PATH := "user://settings.cfg"

var quality_index: int = 1
var language: String = "ru"

var camera_sensitivity: float = 0.30
var camera_invert_y: bool = false
var camera_distance_scale: float = 1.0

var steering_mode: int = SteeringMode.BUTTONS
var auto_accelerate: bool = false
var nitro_button_enabled: bool = true
var vibration: bool = true

var master_volume_db: float = 0.0
var engine_volume_db: float = -3.0
var sfx_volume_db: float = -3.0
var siren_volume_db: float = -6.0

var show_minimap: bool = true
var hud_scale: float = 1.0
var keep_screen_on: bool = true
var show_debug_overlay: bool = false

var police_count: int = 3
var ai_level: int = 2
var player_paint_index: int = 0

var _quality: GraphicsQuality = null


func _ready() -> void:
	_load()
	_quality = Config.quality_preset(quality_index)
	if keep_screen_on and OS.has_feature("mobile"):
		DisplayServer.screen_set_keep_on(true)
	apply_audio_bus_volumes()


## The colour of the player car (body material override).
func player_paint_color() -> Color:
	return Config.vehicle_player.paint_color_for(player_paint_index)


func cycle_player_paint(step: int = 1) -> Color:
	var total := Config.vehicle_player.paint_count()
	if total <= 1:
		return player_paint_color()
	player_paint_index = posmod(player_paint_index + step, total)
	save_now()
	return player_paint_color()


func preset() -> GraphicsQuality:
	if _quality == null:
		_quality = Config.quality_preset(quality_index)
	return _quality


func quality_title() -> String:
	return preset().title


func set_quality_index(index: int, save_now: bool = true) -> void:
	quality_index = clampi(index, 0, Config.quality_preset_count() - 1)
	_quality = Config.quality_preset(quality_index)
	apply_renderer_settings()
	quality_changed.emit(_quality)
	if save_now:
		_save()


func apply_renderer_settings() -> void:
	var q := preset()
	var viewport := get_viewport()
	if viewport != null:
		viewport.msaa_3d = q.msaa_3d
		# 3D render scaling needs a RenderingDevice (Mobile/Forward+ renderers);
		# the Compatibility renderer ignores it, which is fine.
		if RenderingServer.get_rendering_device() != null:
			viewport.scaling_3d_scale = q.render_scale
	RenderingServer.directional_soft_shadow_filter_set_quality(q.shadow_filter_quality)
	RenderingServer.positional_soft_shadow_filter_set_quality(q.shadow_filter_quality)
	Perf.set_quality_scale(q)


func apply_audio_bus_volumes() -> void:
	_set_bus_volume("Master", master_volume_db)
	_set_bus_volume("Engine", engine_volume_db)
	_set_bus_volume("SFX", sfx_volume_db)
	_set_bus_volume("Siren", siren_volume_db)


func _set_bus_volume(bus_name: String, volume_db: float) -> void:
	var bus_index := AudioServer.get_bus_index(bus_name)
	if bus_index < 0:
		return
	AudioServer.set_bus_volume_db(bus_index, volume_db)
	AudioServer.set_bus_mute(bus_index, volume_db <= -60.0)


## Public wrapper: the game flow saves the settings after changing them.
func save_now() -> void:
	_save()


func notify_changed(save_now: bool = true) -> void:
	apply_audio_bus_volumes()
	settings_changed.emit()
	if save_now:
		_save()


func _load() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(CONFIG_PATH) != OK:
		return
	quality_index = int(cfg.get_value("display", "quality", 1))
	language = String(cfg.get_value("display", "language", "ru"))
	camera_sensitivity = float(cfg.get_value("camera", "sensitivity", 0.30))
	camera_invert_y = bool(cfg.get_value("camera", "invert_y", false))
	camera_distance_scale = float(cfg.get_value("camera", "distance_scale", 1.0))
	steering_mode = int(cfg.get_value("controls", "steering_mode", SteeringMode.BUTTONS))
	auto_accelerate = bool(cfg.get_value("controls", "auto_accelerate", false))
	nitro_button_enabled = bool(cfg.get_value("controls", "nitro_button", true))
	vibration = bool(cfg.get_value("controls", "vibration", true))
	master_volume_db = float(cfg.get_value("audio", "master_db", 0.0))
	engine_volume_db = float(cfg.get_value("audio", "engine_db", -3.0))
	sfx_volume_db = float(cfg.get_value("audio", "sfx_db", -3.0))
	siren_volume_db = float(cfg.get_value("audio", "siren_db", -6.0))
	show_minimap = bool(cfg.get_value("ui", "minimap", true))
	hud_scale = float(cfg.get_value("ui", "hud_scale", 1.0))
	keep_screen_on = bool(cfg.get_value("ui", "keep_screen_on", true))
	show_debug_overlay = bool(cfg.get_value("ui", "debug", false))
	police_count = int(cfg.get_value("game", "police_count", 3))
	ai_level = int(cfg.get_value("game", "ai_level", 2))
	player_paint_index = int(cfg.get_value("game", "paint_index", 0))


func _save() -> void:
	var cfg := ConfigFile.new()
	cfg.set_value("display", "quality", quality_index)
	cfg.set_value("display", "language", language)
	cfg.set_value("camera", "sensitivity", camera_sensitivity)
	cfg.set_value("camera", "invert_y", camera_invert_y)
	cfg.set_value("camera", "distance_scale", camera_distance_scale)
	cfg.set_value("controls", "steering_mode", steering_mode)
	cfg.set_value("controls", "auto_accelerate", auto_accelerate)
	cfg.set_value("controls", "nitro_button", nitro_button_enabled)
	cfg.set_value("controls", "vibration", vibration)
	cfg.set_value("audio", "master_db", master_volume_db)
	cfg.set_value("audio", "engine_db", engine_volume_db)
	cfg.set_value("audio", "sfx_db", sfx_volume_db)
	cfg.set_value("audio", "siren_db", siren_volume_db)
	cfg.set_value("ui", "minimap", show_minimap)
	cfg.set_value("ui", "hud_scale", hud_scale)
	cfg.set_value("ui", "keep_screen_on", keep_screen_on)
	cfg.set_value("ui", "debug", show_debug_overlay)
	cfg.set_value("game", "police_count", police_count)
	cfg.set_value("game", "ai_level", ai_level)
	cfg.set_value("game", "paint_index", player_paint_index)
	cfg.save(CONFIG_PATH)
