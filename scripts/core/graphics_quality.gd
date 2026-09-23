class_name GraphicsQuality
extends Resource

## One graphics preset.  The three shipped presets live in
## data/resources/graphics_low.tres / graphics_medium.tres / graphics_high.tres
## and can be edited without recompiling anything.

@export var title: String = "Medium"
@export var description: String = ""

@export_group("World streaming")
## Radius of the fully detailed world around the camera, in metres.
@export var view_distance_m: float = 448.0
@export var max_chunks_loaded: int = 49
@export var generation_budget_ms: float = 6.0
@export var max_generations_per_frame: int = 2

@export_group("Level of detail")
## Scales every LOD switch distance (1.0 = reference).
@export var lod_bias: float = 1.0
@export var near_lod_distance_m: float = 72.0
@export var mid_lod_distance_m: float = 190.0
@export var far_lod_distance_m: float = 380.0
@export var distant_silhouettes: bool = true

@export_group("Density")
@export var prop_density: float = 0.85
@export var foliage_density: float = 0.85
@export var terrain_quad_scale: float = 1.0

@export_group("Lighting")
@export var shadows_enabled: bool = true
@export var shadow_distance_m: float = 120.0
@export var shadow_map_size: int = 2048
@export var shadow_filter_quality: int = 1
@export var ssao: bool = false
@export var glow: bool = false
@export var fog_quality: float = 1.0

@export_group("Rendering")
@export var render_scale: float = 1.0
@export var msaa_3d: int = 0
@export var mipmap_bias: float = -0.25
@export var particles_enabled: bool = true
@export var particle_amount: float = 1.0
@export var max_dynamic_lights: int = 6


## ----------------------------------------------------------------- presets --
## Tuned for a low-end 720p Android phone (Infinix HOT 40i class).
## A designer can override any preset with res://data/resources/graphics_*.tres.

static func low() -> GraphicsQuality:
	var q := GraphicsQuality.new()
	q.title = "Low"
	q.description = "Best performance: shorter view distance, no realtime shadows."
	q.view_distance_m = 320.0
	q.max_chunks_loaded = 36
	q.generation_budget_ms = 5.0
	q.max_generations_per_frame = 2
	q.lod_bias = 0.75
	q.near_lod_distance_m = 56.0
	q.mid_lod_distance_m = 150.0
	q.far_lod_distance_m = 300.0
	q.distant_silhouettes = true
	q.prop_density = 0.5
	q.foliage_density = 0.55
	q.terrain_quad_scale = 1.35
	q.shadows_enabled = false
	q.shadow_distance_m = 60.0
	q.shadow_map_size = 1024
	q.shadow_filter_quality = 0
	q.ssao = false
	q.glow = false
	q.fog_quality = 0.6
	q.render_scale = 0.7
	q.msaa_3d = 0
	q.mipmap_bias = 0.0
	q.particles_enabled = true
	q.particle_amount = 0.4
	q.max_dynamic_lights = 3
	return q


static func medium() -> GraphicsQuality:
	var q := GraphicsQuality.new()
	q.title = "Medium"
	q.description = "Default phone preset: shadows near the player, 450 m view."
	q.view_distance_m = 448.0
	q.max_chunks_loaded = 49
	q.generation_budget_ms = 6.0
	q.max_generations_per_frame = 2
	q.lod_bias = 1.0
	q.near_lod_distance_m = 72.0
	q.mid_lod_distance_m = 190.0
	q.far_lod_distance_m = 380.0
	q.distant_silhouettes = true
	q.prop_density = 0.85
	q.foliage_density = 0.85
	q.terrain_quad_scale = 1.0
	q.shadows_enabled = true
	q.shadow_distance_m = 120.0
	q.shadow_map_size = 2048
	q.shadow_filter_quality = 2
	q.ssao = false
	q.glow = false
	q.fog_quality = 1.0
	q.render_scale = 0.85
	q.msaa_3d = 0
	q.mipmap_bias = -0.25
	q.particles_enabled = true
	q.particle_amount = 1.0
	q.max_dynamic_lights = 6
	return q


static func high() -> GraphicsQuality:
	var q := GraphicsQuality.new()
	q.title = "High"
	q.description = "For powerful devices: 640 m view distance, denser world."
	q.view_distance_m = 640.0
	q.max_chunks_loaded = 81
	q.generation_budget_ms = 8.0
	q.max_generations_per_frame = 3
	q.lod_bias = 1.25
	q.near_lod_distance_m = 88.0
	q.mid_lod_distance_m = 240.0
	q.far_lod_distance_m = 460.0
	q.distant_silhouettes = true
	q.prop_density = 1.0
	q.foliage_density = 1.0
	q.terrain_quad_scale = 1.0
	q.shadows_enabled = true
	q.shadow_distance_m = 180.0
	q.shadow_map_size = 2048
	q.shadow_filter_quality = 3
	q.ssao = false
	q.glow = false
	q.fog_quality = 1.0
	q.render_scale = 1.0
	q.msaa_3d = 1
	q.mipmap_bias = -0.35
	q.particles_enabled = true
	q.particle_amount = 1.2
	q.max_dynamic_lights = 8
	return q


## How many presets exist (LOW / MEDIUM / HIGH).
static func count() -> int:
	return 3


## Preset by index - the single source of truth for the settings menu.
static func preset_at(index: int) -> GraphicsQuality:
	match clampi(index, 0, 2):
		0:
			return low()
		2:
			return high()
		_:
			return medium()


func lod_distance(level: int) -> float:
	match level:
		0: return near_lod_distance_m * lod_bias
		1: return mid_lod_distance_m * lod_bias
		2: return far_lod_distance_m * lod_bias
	return far_lod_distance_m * lod_bias * 1.6


func to_dictionary() -> Dictionary:
	return {
		"title": title,
		"view_distance_m": view_distance_m,
		"max_chunks_loaded": max_chunks_loaded,
		"lod_bias": lod_bias,
		"prop_density": prop_density,
		"foliage_density": foliage_density,
		"shadows_enabled": shadows_enabled,
		"shadow_distance_m": shadow_distance_m,
		"particles_enabled": particles_enabled,
	}
