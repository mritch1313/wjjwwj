class_name RegionMap
extends RefCounted

## Maps a world position to a logical region (city core, city, suburbs,
## countryside, forest, desert, lake shore) and to its blend weights.
##
## The regions are smooth: instead of hard circles, every region returns a
## weight in [0, 1] so world generation can blend terrain colour, vegetation
## density and prop mix across the border.  That is what keeps the transition
## from "city block" to "field" gradual instead of a visible line.
##
## Pure class: it only reads WorldConfig, so it can be unit tested headlessly.

enum Region { CITY_CORE, CITY, SUBURB, COUNTRY, FOREST, DESERT, LAKE }

const REGION_NAMES := {
	Region.CITY_CORE: "city_core",
	Region.CITY: "city",
	Region.SUBURB: "suburbs",
	Region.COUNTRY: "countryside",
	Region.FOREST: "forest",
	Region.DESERT: "desert",
	Region.LAKE: "lake",
}

var config: WorldConfig


func _init(world_config: WorldConfig) -> void:
	config = world_config


static func name_of(region: int) -> String:
	return String(REGION_NAMES.get(region, "unknown"))


func city_distance(position: Vector3) -> float:
	return Vector2(position.x, position.z).length()


## Noise-perturbed radius so region borders are irregular, not perfect circles.
func _noisy_radius(radius: float, direction: Vector2, salt: int) -> float:
	var perturbation := MathUtils.fbm_2d(direction.x * 3.0, direction.y * 3.0, 3, salt) - 0.5
	return radius * (1.0 + perturbation * 0.35)


func region_at(position: Vector3) -> int:
	var weights := weights_at(position)
	var best := Region.COUNTRY
	var best_weight := -1.0
	for region in weights.keys():
		if float(weights[region]) > best_weight:
			best_weight = float(weights[region])
			best = region
	return best


## Blend weights for every region at a position (sum is roughly 1).
func weights_at(position: Vector3) -> Dictionary:
	var flat := Vector2(position.x, position.z)
	var distance_to_center := flat.length()
	var direction := Vector2.RIGHT if distance_to_center < 0.001 else flat / distance_to_center

	# --- desert blob (south west of the map by default)
	var desert_distance := (flat - config.desert_center).length()
	var desert_radius := _noisy_radius(config.desert_radius, (flat - config.desert_center).normalized() if desert_distance > 1.0 else Vector2.RIGHT, 701)
	var desert := 1.0 - smoothstep(desert_radius - config.desert_blend_radius, desert_radius, desert_distance)

	# --- forest blob
	var forest_distance := (flat - config.forest_center).length()
	var forest_radius := _noisy_radius(config.forest_radius, (flat - config.forest_center).normalized() if forest_distance > 1.0 else Vector2.RIGHT, 702)
	var forest := 1.0 - smoothstep(forest_radius - 260.0, forest_radius, forest_distance)

	# --- lake (water body with a sandy/muddy shore)
	var lake_distance := (flat - config.lake_center).length()
	var lake := 1.0 - smoothstep(config.lake_radius * 0.55, config.lake_radius * 1.15, lake_distance)

	# --- city rings
	var core_radius := _noisy_radius(config.city_center_radius * 0.42, direction, 703)
	var city_radius := _noisy_radius(config.city_center_radius, direction, 704)
	var outer_radius := _noisy_radius(config.city_outer_radius, direction, 705)
	var suburb_radius := _noisy_radius(config.suburb_outer_radius, direction, 706)

	var core := 1.0 - smoothstep(core_radius * 0.7, core_radius, distance_to_center)
	var city := (1.0 - smoothstep(city_radius * 0.85, city_radius, distance_to_center)) - core
	var outer := (1.0 - smoothstep(outer_radius * 0.9, outer_radius, distance_to_center)) - core - city
	var suburb := (1.0 - smoothstep(suburb_radius * 0.88, suburb_radius, distance_to_center)) - core - city - outer

	city = maxf(city, 0.0)
	outer = maxf(outer, 0.0)
	suburb = maxf(suburb, 0.0)

	# --- rim of the world: hills take over every other region
	var rim := smoothstep(config.world_half_extent() * config.border_hill_start, config.world_half_extent(), distance_to_center)
	core *= (1.0 - rim)
	city *= (1.0 - rim)
	outer *= (1.0 - rim)
	suburb *= (1.0 - rim)
	desert *= (1.0 - rim * 0.5)
	forest *= (1.0 - rim * 0.5)

	# --- how much open countryside fills the rest
	var country := maxf(0.0, 1.0 - core - city - outer - suburb - desert - forest)

	# Desert and forest replace the countryside where they overlap.
	country *= (1.0 - clampf(desert + forest, 0.0, 1.0))

	return {
		Region.CITY_CORE: core,
		Region.CITY: city + outer * 0.7,
		Region.SUBURB: suburb + outer * 0.3,
		Region.COUNTRY: country * (1.0 - lake * 0.6),
		Region.FOREST: forest,
		Region.DESERT: desert,
		Region.LAKE: lake,
	}


## 0 = pure city, 1 = pure wilderness.  Used to pick prop/vegetation sets.
func urbanity(position: Vector3) -> float:
	var flat := Vector2(position.x, position.z).length()
	var suburb_radius := config.suburb_outer_radius
	return clampf(smoothstep(config.city_outer_radius * 0.85, suburb_radius * 1.05, flat), 0.0, 1.0)


func is_city(position: Vector3) -> bool:
	return city_distance(position) < config.city_outer_radius


func is_inside_map(position: Vector3) -> bool:
	return config.is_inside_world(position)


## Suggested base terrain material for a region (before road surfaces apply).
func base_surface(region: int, slope: float) -> int:
	if slope > 0.62:
		return Surface.Type.GRAVEL
	match region:
		Region.DESERT:
			return Surface.Type.SAND
		Region.FOREST:
			return Surface.Type.DIRT
		Region.LAKE:
			return Surface.Type.SAND
		Region.CITY_CORE, Region.CITY, Region.SUBURB:
			return Surface.Type.GRASS
		_:
			return Surface.Type.GRASS


## Name of the terrain texture material for a region (vertex colours add variety).
func terrain_material_for(region: int, slope: float, dry: float) -> String:
	if slope > 0.66:
		return "ground_rock"
	match region:
		Region.DESERT:
			return "sand" if dry > 0.35 else "ground_gravel"
		Region.FOREST:
			return "grass" if dry < 0.6 else "grass_dry"
		Region.LAKE:
			return "sand"
		_:
			if dry > 0.72:
				return "ground_dirt"
			return "grass" if dry > 0.45 else "grass_dry"
