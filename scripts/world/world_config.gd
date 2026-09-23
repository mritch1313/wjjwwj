class_name WorldConfig
extends Resource

## Everything that defines the size and the content of the open world.
## Edit data/resources/world_default.tres (or call WorldConfig.new()) and the
## whole world - regions, roads, city, desert, landmarks - changes with it.

@export_group("World size")
## Edge length of the playable square world in metres.  The default 4096 m
## means a 4 x 4 km world that can be crossed in ~2 minutes at top speed.
@export var world_size_m: float = 4096.0
## Edge of one streamed chunk in metres.  Chunk content (terrain patch, road
## ribbons, buildings, props, colliders) is generated and freed per chunk.
## 192 m keeps the number of *detailed* chunks small on mobile while still
## giving smooth streaming.
@export var chunk_size_m: float = 192.0
@export var seed: int = 20260923

@export_group("Terrain")
@export var terrain_height_scale: float = 30.0
@export var terrain_base_frequency: float = 0.00055
@export var terrain_detail_frequency: float = 0.0035
@export var terrain_detail_strength: float = 2.2
## Hills grow towards the map border so the world has a natural rim.
@export var border_hill_start: float = 0.72
@export var border_hill_height: float = 95.0
@export var water_level: float = -5.5
@export var lake_center: Vector2 = Vector2(1180.0, -980.0)
@export var lake_radius: float = 420.0
## Terrain quad size per LOD ring (denser close to the camera).
@export var terrain_quad_near: float = 3.0
@export var terrain_quad_mid: float = 6.0
@export var terrain_quad_far: float = 12.0

@export_group("Regions")
@export var city_center_radius: float = 620.0
@export var city_outer_radius: float = 980.0
@export var suburb_outer_radius: float = 1520.0
@export var desert_center: Vector2 = Vector2(-1450.0, 1250.0)
@export var desert_radius: float = 1050.0
@export var desert_blend_radius: float = 380.0
@export var forest_center: Vector2 = Vector2(1350.0, 1150.0)
@export var forest_radius: float = 700.0

@export_group("Roads")
@export var city_block_pitch: float = 145.0
@export var avenue_every: int = 3
@export var road_width_street: float = 13.0
@export var road_width_avenue: float = 23.0
@export var road_width_highway: float = 27.0
@export var road_width_ramp: float = 12.0
@export var road_width_rural: float = 9.0
@export var road_width_dirt: float = 7.5
@export var sidewalk_width: float = 3.2
@export var ring_road_radius: float = 1180.0
@export var ring_road_ramp_length: float = 165.0
@export var interchange_flyover_height: float = 9.5
@export var rural_road_count: int = 26
@export var dirt_road_count: int = 18

@export_group("City")
@export var city_block_buildings_min: int = 2
@export var city_block_buildings_max: int = 9
@export var downtown_height_max: float = 78.0
@export var city_height_max: float = 42.0
@export var suburb_height_max: float = 15.0
@export var rural_building_height_max: float = 12.0
@export var city_floor_height: float = 3.4
@export var parking_lot_chance: float = 0.14
@export var plaza_chance: float = 0.07
@export var vacant_lot_chance: float = 0.08

@export_group("Scatter density (per 128 m chunk)")
@export var props_per_chunk_near: int = 190
@export var props_per_chunk_mid: int = 120
@export var props_per_chunk_far: int = 45
@export var trees_per_chunk_country: int = 70
@export var trees_per_chunk_forest: int = 210
@export var bushes_per_chunk: int = 55
@export var rocks_per_chunk: int = 26
@export var grass_tufts_per_chunk: int = 90
@export var desert_rocks_per_chunk: int = 34

@export_group("Landmarks")
@export var landmark_count: int = 14
@export var gas_station_count: int = 5

@export_group("Streaming")
@export var near_radius_m: float = 192.0
@export var mid_radius_m: float = 384.0
@export var max_chunks_loaded: int = 64
@export var generation_budget_ms: float = 6.0
@export var max_generations_per_frame: int = 2


func chunk_size() -> float:
	return chunk_size_m


func world_half_extent() -> float:
	return world_size_m * 0.5


func chunk_count_per_axis() -> int:
	return int(round(world_size_m / chunk_size_m))


func chunk_origin(cell: Vector2i) -> Vector3:
	var half := world_half_extent()
	return Vector3(-half + float(cell.x) * chunk_size_m, 0.0, -half + float(cell.y) * chunk_size_m)


func cell_of_position(position: Vector3) -> Vector2i:
	var half := world_half_extent()
	return Vector2i(
		int(floor((position.x + half) / chunk_size_m)),
		int(floor((position.z + half) / chunk_size_m))
	)


func is_inside_world(position: Vector3) -> bool:
	var half := world_half_extent() - chunk_size_m
	return absf(position.x) < half and absf(position.z) < half
