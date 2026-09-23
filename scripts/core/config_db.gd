class_name ConfigDB
extends Node

## Central registry of every tunable resource of the game (autoload "Config").
##
## Files live in res://data/resources/ and - if present - override the defaults
## declared in the scripts.  Missing files never crash the game: the code
## defaults are used and a warning is printed (CI also checks the files exist).

const RESOURCE_DIR := "res://data/resources/"

var vehicle_player: VehicleConfig = null
var vehicle_police: VehicleConfig = null
var police: PoliceConfig = null
var world: WorldConfig = null
var gameplay: GameplayConfig = null
var surfaces: SurfaceConfig = null
var _quality_presets: Array[GraphicsQuality] = []


func _ready() -> void:
	load_all()


func load_all() -> void:
	vehicle_player = _load_or_default("vehicle_player.tres", VehicleConfig.new())
	vehicle_police = _load_or_default("vehicle_police.tres", _default_police_vehicle())
	police = _load_or_default("police_default.tres", PoliceConfig.new())
	world = _load_or_default("world_default.tres", WorldConfig.new())
	gameplay = _load_or_default("gameplay_default.tres", GameplayConfig.new())
	surfaces = _load_or_default("surface_default.tres", SurfaceConfig.new())
	surfaces.ensure_complete()
	migrate_legacy()


## Keeps older tuning files usable after new fields are introduced.
func migrate_legacy() -> void:
	if police.levels.is_empty():
		police.ensure_levels()
	if police.max_speed_factor_vs_player <= 0.0:
		police.max_speed_factor_vs_player = PursuitBalance.POLICE_SPEED_FACTOR
	if gameplay.default_police_count > gameplay.max_police_count:
		gameplay.default_police_count = gameplay.max_police_count


func _default_police_vehicle() -> VehicleConfig:
	var cfg := VehicleConfig.new()
	cfg.display_name = "Police Interceptor"
	cfg.mass_kg = 1640.0
	cfg.max_torque_nm = 395.0
	cfg.center_of_mass_offset = Vector3(0.0, -0.5, 0.04)
	cfg.body_size = Vector3(1.92, 1.06, 4.72)
	cfg.top_speed_kmh = 158.0 * PursuitBalance.POLICE_SPEED_FACTOR
	cfg.suspension_spring_n_per_m = 48000.0
	cfg.brake_torque_nm = 3000.0
	cfg.drag_area = 0.86
	cfg.nitro_thrust_n = 0.0
	cfg.nitro_capacity_s = 0.0
	return cfg


func _load_or_default(file_name: String, fallback: Resource) -> Resource:
	var path := RESOURCE_DIR + file_name
	if ResourceLoader.exists(path):
		var loaded := load(path)
		if loaded != null and loaded.get_script() != null:
			return loaded
		push_warning("ConfigDB: %s is not a valid resource, using defaults." % path)
	else:
		print_verbose("ConfigDB: %s missing, using code defaults." % path)
	return fallback


## ------------------------------------------------------------------ quality --
func quality_preset_count() -> int:
	return _presets().size()


func quality_preset(index: int) -> GraphicsQuality:
	var presets := _presets()
	return presets[clampi(index, 0, presets.size() - 1)]


func quality_preset_names() -> PackedStringArray:
	var names := PackedStringArray()
	for preset in _presets():
		names.append(preset.title)
	return names


## Optional editor override: res://data/resources/graphics_low.tres etc.
func _presets() -> Array[GraphicsQuality]:
	if _quality_presets.is_empty():
		_quality_presets = [
			_quality_or_default("graphics_low.tres", GraphicsQuality.low()),
			_quality_or_default("graphics_medium.tres", GraphicsQuality.medium()),
			_quality_or_default("graphics_high.tres", GraphicsQuality.high()),
		]
	return _quality_presets


func _quality_or_default(file_name: String, fallback: GraphicsQuality) -> GraphicsQuality:
	var path := RESOURCE_DIR + file_name
	if ResourceLoader.exists(path):
		var loaded := load(path)
		if loaded is GraphicsQuality:
			return loaded
	return fallback
