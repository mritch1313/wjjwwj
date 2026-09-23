class_name AssetLibrary
extends Node

## Central material / mesh registry (autoload "Assets").
##
## The visual side of the game is deliberately separated from gameplay logic:
## world factories, vehicle model factory and UI only ever ask for a material or
## a mesh *by name*.  Replacing art therefore means editing the tables below or
## dropping a resource into res://data/resources/materials/ - no gameplay script
## has to change.
##
## Every material is created once and cached, so the whole 4x4 km world runs on
## a few dozen shared materials (important on mobile: less state switching).

const MATERIAL_DIR := "res://data/resources/materials/"
const TEXTURE_DIR := "res://assets/textures/"

## name -> { texture, uv (texture repeats per metre), roughness, metallic,
##           alpha, cull, emission, emission_energy, unshaded, shading }
const TEXTURE_MATERIALS := {
	# ------------------------------------------------------------------ roads
	"road_asphalt": {
		"texture": "road_asphalt_plain", "uv": Vector2(0.1, 1.0 / 6.0),
		"roughness": 0.92, "specular": 0.25,
	},
	"road_city": {
		"texture": "road_asphalt_city", "uv": Vector2(1.0, 1.0 / 8.0),
		"roughness": 0.9, "specular": 0.3, "uv_mode": "ribbon",
	},
	"road_avenue": {
		"texture": "road_asphalt_avenue", "uv": Vector2(1.0, 1.0 / 8.0),
		"roughness": 0.9, "specular": 0.3, "uv_mode": "ribbon",
	},
	"road_highway": {
		"texture": "road_asphalt_highway", "uv": Vector2(1.0, 1.0 / 10.0),
		"roughness": 0.88, "specular": 0.32, "uv_mode": "ribbon",
	},
	"road_rural": {
		"texture": "road_asphalt_rural", "uv": Vector2(1.0, 1.0 / 8.0),
		"roughness": 0.94, "specular": 0.2, "uv_mode": "ribbon",
	},
	"road_dirt": {
		"texture": "road_dirt_track", "uv": Vector2(1.0, 1.0 / 7.0),
		"roughness": 0.98, "specular": 0.08, "uv_mode": "ribbon",
	},
	"road_gravel": {
		"texture": "road_gravel_road", "uv": Vector2(1.0, 1.0 / 6.0),
		"roughness": 0.97, "specular": 0.12, "uv_mode": "ribbon",
	},
	"sidewalk": {
		"texture": "surface_sidewalk", "uv": Vector2(0.25, 0.25),
		"roughness": 0.85, "specular": 0.3,
	},
	"curb": {
		"texture": "surface_curb", "uv": Vector2(1.0, 0.25),
		"roughness": 0.8, "specular": 0.35, "uv_mode": "ribbon",
	},
	"parking": {
		"texture": "surface_parking", "uv": Vector2(0.1, 0.1),
		"roughness": 0.9, "specular": 0.28,
	},
	"pavement": {
		"texture": "surface_plaza", "uv": Vector2(0.125, 0.125),
		"roughness": 0.8, "specular": 0.35,
	},
	"concrete": {
		"texture": "surface_concrete", "uv": Vector2(0.25, 0.25),
		"roughness": 0.82, "specular": 0.3,
	},
	"concrete_wall": {
		"texture": "concrete_wall", "uv": Vector2(0.2, 0.2),
		"roughness": 0.85, "specular": 0.25,
	},
	"plinth": {
		"texture": "building_plinth", "uv": Vector2(0.35, 0.35),
		"roughness": 0.75, "specular": 0.3,
	},
	"wet_concrete": {
		"texture": "surface_concrete", "uv": Vector2(0.25, 0.25),
		"roughness": 0.35, "specular": 0.7,
	},

	# --------------------------------------------------------------- terrain
	"grass": {
		"texture": "terrain_grass", "uv": Vector2(0.5, 0.5),
		"roughness": 1.0, "specular": 0.05,
	},
	"grass_dry": {
		"texture": "terrain_grass_dry", "uv": Vector2(0.5, 0.5),
		"roughness": 1.0, "specular": 0.05,
	},
	"ground_dirt": {
		"texture": "terrain_dirt", "uv": Vector2(0.5, 0.5),
		"roughness": 1.0, "specular": 0.05,
	},
	"sand": {
		"texture": "terrain_sand", "uv": Vector2(0.4, 0.4),
		"roughness": 1.0, "specular": 0.08,
	},
	"ground_rock": {
		"texture": "terrain_rock", "uv": Vector2(0.4, 0.4),
		"roughness": 0.95, "specular": 0.12,
	},
	"ground_gravel": {
		"texture": "terrain_gravel", "uv": Vector2(0.4, 0.4),
		"roughness": 0.97, "specular": 0.1,
	},
	"water": {
		"texture": "", "color": Color(0.13, 0.31, 0.36, 0.78),
		"roughness": 0.12, "specular": 0.85, "alpha": true, "transparency": true,
	},

	# --------------------------------------------------------------- facades
	"facade_brick_a": {"texture": "facade_brick_a", "uv": Vector2(1, 1), "roughness": 0.9, "specular": 0.2},
	"facade_brick_b": {"texture": "facade_brick_b", "uv": Vector2(1, 1), "roughness": 0.9, "specular": 0.2},
	"facade_plaster_a": {"texture": "facade_plaster_a", "uv": Vector2(1, 1), "roughness": 0.85, "specular": 0.25},
	"facade_plaster_b": {"texture": "facade_plaster_b", "uv": Vector2(1, 1), "roughness": 0.85, "specular": 0.25},
	"facade_concrete_a": {"texture": "facade_concrete_a", "uv": Vector2(1, 1), "roughness": 0.88, "specular": 0.22},
	"facade_concrete_b": {"texture": "facade_concrete_b", "uv": Vector2(1, 1), "roughness": 0.88, "specular": 0.22},
	"facade_office": {"texture": "facade_office_glass", "uv": Vector2(1, 1), "roughness": 0.35, "specular": 0.7, "metallic": 0.15},
	"facade_glass": {"texture": "facade_glass_curtain", "uv": Vector2(1, 1), "roughness": 0.25, "specular": 0.8, "metallic": 0.2},
	"facade_industrial": {"texture": "facade_industrial", "uv": Vector2(1, 1), "roughness": 0.7, "specular": 0.35, "metallic": 0.25},
	"facade_storefront": {"texture": "facade_storefront", "uv": Vector2(1, 1), "roughness": 0.55, "specular": 0.45},
	"facade_roller_door": {"texture": "facade_roller_door", "uv": Vector2(1, 1), "roughness": 0.72, "specular": 0.35, "metallic": 0.3},

	# ----------------------------------------------------------------- roofs
	"roof_flat": {"texture": "roof_flat", "uv": Vector2(0.15, 0.15), "roughness": 0.95, "specular": 0.15},
	"roof_tiles": {"texture": "roof_tiles", "uv": Vector2(0.25, 0.25), "roughness": 0.85, "specular": 0.25},
	"roof_metal": {"texture": "roof_metal", "uv": Vector2(0.15, 0.15), "roughness": 0.55, "specular": 0.5, "metallic": 0.4},
	"roof_gravel": {"texture": "terrain_gravel", "uv": Vector2(0.5, 0.5), "roughness": 1.0, "specular": 0.1},

	# ------------------------------------------------------------------ misc
	"wall_garden": {"texture": "wall_garden", "uv": Vector2(0.35, 0.35), "roughness": 0.9, "specular": 0.2},
	"metal_corrugated": {"texture": "metal_corrugated", "uv": Vector2(0.3, 0.3), "roughness": 0.55, "specular": 0.5, "metallic": 0.35},
	"container_side": {"texture": "container_side", "uv": Vector2(0.3, 0.3), "roughness": 0.7, "specular": 0.4, "metallic": 0.2},
	"wood_planks": {"texture": "wood_planks", "uv": Vector2(0.4, 0.4), "roughness": 0.85, "specular": 0.2},
	"wood_dark": {"texture": "wood_planks", "uv": Vector2(0.4, 0.4), "roughness": 0.8, "specular": 0.2, "color": Color(0.62, 0.55, 0.46)},
	"rock_granite": {"texture": "rock_granite", "uv": Vector2(0.4, 0.4), "roughness": 0.88, "specular": 0.25},
	"sandstone": {"texture": "sandstone", "uv": Vector2(0.35, 0.35), "roughness": 0.9, "specular": 0.2},
	"tree_bark": {"texture": "tree_bark", "uv": Vector2(0.6, 0.6), "roughness": 0.95, "specular": 0.1},
	"graffiti_wall": {"texture": "concrete_wall", "uv": Vector2(0.2, 0.2), "roughness": 0.8, "specular": 0.3, "color": Color(0.72, 0.66, 0.6)},

	# -------------------------------------------------------------- fences
	"fence_picket": {"texture": "fence_picket_alpha", "uv": Vector2(0.5, 0.5), "alpha_scissor": true, "cull": false, "roughness": 0.9, "specular": 0.15},
	"fence_chain": {"texture": "fence_chain_alpha", "uv": Vector2(0.5, 0.5), "alpha_scissor": true, "cull": false, "roughness": 0.5, "specular": 0.6, "metallic": 0.4},
	"fence_bars": {"texture": "fence_metal_bars_alpha", "uv": Vector2(0.5, 0.5), "alpha_scissor": true, "cull": false, "roughness": 0.5, "specular": 0.6, "metallic": 0.5},
	"fence_bars_dark": {"texture": "fence_metal_bars_alpha", "uv": Vector2(0.5, 0.5), "alpha_scissor": true, "cull": false, "roughness": 0.6, "metallic": 0.4, "color": Color(0.35, 0.37, 0.4)},

	# ------------------------------------------------------------- foliage
	"foliage_a": {"texture": "foliage_a", "uv": Vector2(1, 1), "alpha_scissor": true, "cull": false, "roughness": 0.9, "specular": 0.15, "no_shadow": true},
	"foliage_b": {"texture": "foliage_b", "uv": Vector2(1, 1), "alpha_scissor": true, "cull": false, "roughness": 0.9, "specular": 0.15, "no_shadow": true},
	"foliage_pine": {"texture": "foliage_pine", "uv": Vector2(1, 1), "alpha_scissor": true, "cull": false, "roughness": 0.9, "specular": 0.12, "no_shadow": true},
	"foliage_palm": {"texture": "foliage_palm", "uv": Vector2(1, 1), "alpha_scissor": true, "cull": false, "roughness": 0.85, "specular": 0.15, "no_shadow": true},
	"bush": {"texture": "bush_a", "uv": Vector2(1, 1), "alpha_scissor": true, "cull": false, "roughness": 0.9, "specular": 0.12, "no_shadow": true},
	"grass_tuft": {"texture": "grass_tuft", "uv": Vector2(1, 1), "alpha_scissor": true, "cull": false, "roughness": 1.0, "specular": 0.05, "no_shadow": true},

	# --------------------------------------------------------------- signs
	"sign_face": {"texture": "sign_atlas", "uv": Vector2(1, 1), "alpha_scissor": true, "cull": false, "roughness": 0.4, "specular": 0.6, "metal_back": true},
	"shop_sign_a": {"texture": "shop_sign_a", "uv": Vector2(1, 1), "roughness": 0.5, "specular": 0.5},
	"shop_sign_b": {"texture": "shop_sign_b", "uv": Vector2(1, 1), "roughness": 0.5, "specular": 0.5},
	"shop_sign_c": {"texture": "shop_sign_c", "uv": Vector2(1, 1), "roughness": 0.5, "specular": 0.5},
	"shop_sign_d": {"texture": "shop_sign_d", "uv": Vector2(1, 1), "roughness": 0.5, "specular": 0.5},
	"awning_a": {"texture": "awning_a", "uv": Vector2(1, 1), "roughness": 0.8, "specular": 0.25},
	"awning_b": {"texture": "awning_b", "uv": Vector2(1, 1), "roughness": 0.8, "specular": 0.25},
	"awning_c": {"texture": "awning_c", "uv": Vector2(1, 1), "roughness": 0.8, "specular": 0.25},
	"billboard_ad_a": {"texture": "billboard_ad_a", "uv": Vector2(1, 1), "roughness": 0.45, "specular": 0.5},
	"billboard_ad_b": {"texture": "billboard_ad_b", "uv": Vector2(1, 1), "roughness": 0.45, "specular": 0.5},

	# --------------------------------------------------------------- cars
	"car_body_player": {"texture": "", "color": Color(0.62, 0.09, 0.11), "roughness": 0.28, "specular": 0.75, "metallic": 0.35},
	"car_body_police": {"texture": "", "color": Color(0.08, 0.09, 0.12), "roughness": 0.3, "specular": 0.7, "metallic": 0.3},
	"car_body_police_door": {"texture": "", "color": Color(0.9, 0.91, 0.93), "roughness": 0.35, "specular": 0.6, "metallic": 0.2},
	"car_body_traffic": {"texture": "", "color": Color(0.72, 0.72, 0.74), "roughness": 0.35, "specular": 0.6, "metallic": 0.25},
	"car_glass": {"texture": "", "color": Color(0.1, 0.14, 0.18, 0.72), "roughness": 0.08, "specular": 0.9, "metallic": 0.1, "alpha": true},
	"car_trim": {"texture": "", "color": Color(0.09, 0.09, 0.1), "roughness": 0.7, "specular": 0.3},
	"car_chrome": {"texture": "", "color": Color(0.75, 0.77, 0.8), "roughness": 0.2, "specular": 0.9, "metallic": 0.85},
	"car_light_front": {"texture": "car_light_front", "uv": Vector2(1, 1), "color": Color(1, 1, 1), "roughness": 0.2, "emission": Color(1.0, 0.96, 0.82), "emission_energy": 1.4},
	"car_light_rear": {"texture": "car_light_rear", "uv": Vector2(1, 1), "color": Color(1, 1, 1), "roughness": 0.3, "emission": Color(0.85, 0.12, 0.1), "emission_energy": 0.9},
	"car_tire": {"texture": "car_tire", "uv": Vector2(1, 1), "roughness": 0.95, "specular": 0.08},
	"car_rim": {"texture": "car_rim", "uv": Vector2(1, 1), "roughness": 0.35, "specular": 0.7, "metallic": 0.6},
	"car_plate": {"texture": "car_plate", "uv": Vector2(1, 1), "roughness": 0.5, "specular": 0.4},
	"police_lightbar_red": {"texture": "", "color": Color(0.9, 0.1, 0.1), "emission": Color(1.0, 0.1, 0.08), "emission_energy": 2.2, "unshaded": true},
	"police_lightbar_blue": {"texture": "", "color": Color(0.1, 0.25, 0.95), "emission": Color(0.15, 0.35, 1.0), "emission_energy": 2.2, "unshaded": true},
	"police_stripe": {"texture": "", "color": Color(0.93, 0.94, 0.96), "roughness": 0.4, "specular": 0.5},

	# --------------------------------------------------------------- props
	"metal_dark": {"texture": "", "color": Color(0.16, 0.17, 0.19), "roughness": 0.55, "specular": 0.5, "metallic": 0.5},
	"metal_grey": {"texture": "", "color": Color(0.52, 0.55, 0.58), "roughness": 0.45, "specular": 0.6, "metallic": 0.6},
	"metal_painted_red": {"texture": "", "color": Color(0.66, 0.2, 0.16), "roughness": 0.5, "specular": 0.5},
	"plastic_orange": {"texture": "", "color": Color(0.9, 0.42, 0.08), "roughness": 0.6, "specular": 0.4},
	"rubber_black": {"texture": "", "color": Color(0.07, 0.07, 0.08), "roughness": 0.9, "specular": 0.2},
	"lamp_glass": {"texture": "", "color": Color(1.0, 0.95, 0.8), "emission": Color(1.0, 0.9, 0.7), "emission_energy": 2.0, "unshaded": true},
	"lamp_glass_off": {"texture": "", "color": Color(0.75, 0.78, 0.8), "roughness": 0.25, "specular": 0.8},
	"traffic_light_red": {"texture": "", "color": Color(0.75, 0.1, 0.08), "emission": Color(1, 0.1, 0.1), "emission_energy": 1.6, "unshaded": true},
	"traffic_light_green": {"texture": "", "color": Color(0.15, 0.75, 0.25), "emission": Color(0.2, 1, 0.3), "emission_energy": 1.6, "unshaded": true},
	"traffic_light_off": {"texture": "", "color": Color(0.1, 0.1, 0.1), "roughness": 0.5, "specular": 0.4},
	"crate_wood": {"texture": "wood_planks", "uv": Vector2(0.5, 0.5), "roughness": 0.9, "specular": 0.15},
	"crate_blue": {"texture": "container_side", "uv": Vector2(0.5, 0.5), "roughness": 0.7, "specular": 0.4},
	"dumpster": {"texture": "", "color": Color(0.24, 0.42, 0.3), "roughness": 0.6, "specular": 0.45, "metallic": 0.3},
	"marking_white": {"texture": "", "color": Color(0.92, 0.92, 0.88), "roughness": 0.7, "specular": 0.3},
	"marking_yellow": {"texture": "", "color": Color(0.88, 0.76, 0.25), "roughness": 0.7, "specular": 0.3},
	"asphalt_dark": {"texture": "road_asphalt_plain", "uv": Vector2(0.2, 0.2), "color": Color(0.75, 0.75, 0.78), "roughness": 0.92},

	# ----------------------------------------------------- distant background
	# The unstreamed LOD3 ring behind the world and the skyline it carries.  These
	# are only ever seen from far away, so they are unshaded, take their colour
	# from the vertex colour baked by BackgroundBuilder and cast no shadows - the
	# cheapest thing a mobile GPU can draw thousands of metres away.
	"terrain_background": {"texture": "", "color": Color(0.55, 0.6, 0.5), "roughness": 1.0, "specular": 0.0, "unshaded": true, "no_shadow": true},
	"city_silhouette": {"texture": "", "color": Color(0.45, 0.48, 0.55), "roughness": 0.95, "specular": 0.1, "no_shadow": true},
	"landmark_water_tank": {"texture": "", "color": Color(0.72, 0.74, 0.76), "roughness": 0.5, "specular": 0.5, "metallic": 0.35, "no_shadow": true},
	"structure_metal": {"texture": "", "color": Color(0.45, 0.48, 0.5), "roughness": 0.45, "specular": 0.6, "metallic": 0.55},
	"sign_blue": {"texture": "", "color": Color(0.1, 0.35, 0.72), "roughness": 0.5, "specular": 0.4},
	"siren_light_red": {"texture": "", "color": Color(0.8, 0.1, 0.1), "emission": Color(1.0, 0.12, 0.1), "emission_energy": 1.8, "unshaded": true, "no_shadow": true},
}

var _materials: Dictionary = {}
var _meshes: Dictionary = {}
var _textures: Dictionary = {}


func _ready() -> void:
	_ensure_signal_buses()


func _ensure_signal_buses() -> void:
	# Audio buses are created in code so the project does not depend on a .tres
	# that could be lost - buses: Master, Engine, SFX, Siren.
	for bus_name in ["Engine", "SFX", "Siren"]:
		if AudioServer.get_bus_index(bus_name) == -1:
			var index := AudioServer.bus_count
			AudioServer.add_bus(index)
			AudioServer.set_bus_name(index, bus_name)
			AudioServer.set_bus_send(index, "Master")


func texture(texture_name: String) -> Texture2D:
	if texture_name.is_empty():
		return null
	if _textures.has(texture_name):
		return _textures[texture_name]
	var path := TEXTURE_DIR + texture_name + ".png"
	if not ResourceLoader.exists(path):
		push_warning("Assets: texture %s not found" % path)
		return null
	var loaded: Texture2D = load(path)
	_textures[texture_name] = loaded
	return loaded


func material(material_name: String) -> Material:
	if material_name.is_empty():
		return null
	if _materials.has(material_name):
		return _materials[material_name]
	# 1) allow an explicit editor override
	var override_path := MATERIAL_DIR + material_name + ".tres"
	if ResourceLoader.exists(override_path):
		var overridden: Material = load(override_path)
		_materials[material_name] = overridden
		return overridden
	# 2) build from the data table
	if not TEXTURE_MATERIALS.has(material_name):
		push_warning("Assets: unknown material '%s', falling back to concrete" % material_name)
		return material("concrete")
	var definition: Dictionary = TEXTURE_MATERIALS[material_name]
	var mat := StandardMaterial3D.new()
	mat.resource_name = material_name
	var texture_name := String(definition.get("texture", ""))
	if not texture_name.is_empty():
		var tex := texture(texture_name)
		if tex != null:
			mat.albedo_texture = tex
			var uv: Vector2 = definition.get("uv", Vector2(0.25, 0.25))
			mat.uv1_scale = Vector3(uv.x, uv.y, 1.0)
	mat.albedo_color = definition.get("color", Color.WHITE)
	mat.metallic = float(definition.get("metallic", 0.0))
	mat.roughness = float(definition.get("roughness", 0.8))
	mat.metallic_specular = float(definition.get("specular", 0.35))
	# Vertex colours give per instance variation as well as baked AO on facades.
	mat.vertex_color_use_as_albedo = true
	mat.vertex_color_is_srgb = true
	if bool(definition.get("alpha_scissor", false)):
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA_SCISSOR
		mat.alpha_scissor_threshold = 0.4
		mat.texture_filter = BaseMaterial3D.TEXTURE_FILTER_NEAREST_WITH_MIPMAPS
	elif bool(definition.get("alpha", false)):
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if bool(definition.get("transparency", false)):
		mat.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	if not bool(definition.get("cull", true)):
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	if definition.has("emission"):
		mat.emission_enabled = true
		mat.emission = definition["emission"]
		mat.emission_energy_multiplier = float(definition.get("emission_energy", 1.0))
	if bool(definition.get("unshaded", false)):
		mat.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	if bool(definition.get("no_shadow", false)):
		# В Godot 4 тени включаются у MeshInstance3D, а не у материала, поэтому
		# признак хранится в метаданных: слой чанка (WorldChunk) и сборщики мешей
		# читают его и выставляют cast_shadow у своего узла.
		mat.set_meta("no_shadow", true)
	if bool(definition.get("metal_back", false)):
		mat.cull_mode = BaseMaterial3D.CULL_DISABLED
	_materials[material_name] = mat
	return mat


## ---------------- generated meshes (cached by name for props and vehicles) --
func cache_mesh(mesh_name: String, mesh: Mesh) -> Mesh:
	_meshes[mesh_name] = mesh
	return mesh


func mesh(mesh_name: String) -> Mesh:
	if _meshes.has(mesh_name):
		return _meshes[mesh_name]
	return null


func has_mesh(mesh_name: String) -> bool:
	return _meshes.has(mesh_name)


func clear_runtime_cache() -> void:
	# Called when the quality preset changes: procedural chunks hold their own
	# references, so dropping ours only releases memory when nothing else uses it.
	_meshes.clear()


func material_names() -> Array:
	return TEXTURE_MATERIALS.keys()
