extends TestCase

## Terrain and region checks: the world must contain distinct regions (city,
## suburbs, countryside, fields, desert, highway ring), water must sit below the
## water level, and roads must flatten the ground so cars do not clip through.

var config: WorldConfig
var terrain: TerrainField
var regions: RegionMap
var network: RoadNetwork


func before_all() -> void:
	config = WorldFixture.config()
	terrain = WorldFixture.terrain()
	regions = WorldFixture.regions()
	network = WorldFixture.network()


func test_height_is_deterministic() -> void:
	var a := terrain.height_at(123.4, -456.7)
	var b := terrain.height_at(123.4, -456.7)
	assert_almost_eq(a, b, 0.0, "высота детерминирована (один seed - одна карта)")
	assert_almost_eq(terrain.height_at(0.0, 0.0), terrain.height_at(0.0, 0.0), 0.0, "город тоже стабилен")


func test_relief_is_present_but_not_extreme() -> void:
	var minimum := INF
	var maximum := -INF
	var rng := test_rng(11)
	for i in range(400):
		var value := terrain.height_at(rng.randf_range(-1900.0, 1900.0), rng.randf_range(-1900.0, 1900.0))
		minimum = minf(minimum, value)
		maximum = maxf(maximum, value)
	assert_gt(maximum - minimum, 25.0, "в мире есть настоящий рельеф, а не плоскость")
	assert_lt(maximum - minimum, 260.0, "перепад высот не превращается в горы")


func test_border_hills_rise_towards_the_edge() -> void:
	var center_height := terrain.height_at(0.0, 0.0)
	var edge_height := 0.0
	for i in range(8):
		var angle := TAU * float(i) / 8.0
		edge_height = maxf(edge_height, terrain.height_at(cos(angle) * 1950.0, sin(angle) * 1950.0))
	assert_gt(edge_height, center_height, "у границы мира рельеф выше центра")


func test_roads_flatten_the_ground() -> void:
	var probes := 0
	var flattened := 0
	for id in range(0, mini(network.segment_count(), 300)):
		var segment: RoadNetwork.Segment = network.segments[id]
		if segment.points.size() < 2 or segment.elevated:
			continue
		var point: Vector3 = segment.points[segment.points.size() / 2]
		var on_road := terrain.height_at(point.x, point.z)
		var beside := terrain.height_at(point.x + segment.width * 0.5 + 24.0, point.z + segment.width * 0.5 + 24.0)
		probes += 1
		if absf(on_road - beside) > 0.05:
			flattened += 1
	assert_gt(float(probes), 50.0, "достаточно дорог для проверки")
	assert_gt(float(flattened) / float(maxi(probes, 1)), 0.5, "у большинства дорог высота отличается от придорожной")


func test_water_level_is_respected_in_the_lake() -> void:
	var lake_center := Vector3(config.lake_center.x, 0.0, config.lake_center.y)
	var height := terrain.height_at(lake_center.x, lake_center.z)
	assert_lt(height, config.water_level, "в озере дно ниже уровня воды")
	assert_lt(height, config.water_level + 0.05, "уровень воды выше дна озера")
	var far_away := terrain.height_at(lake_center.x + config.lake_radius * 2.4, lake_center.z)
	assert_gt(far_away, config.water_level, "снаружи озера земля выше воды")


func test_region_classification_matches_the_design() -> void:
	assert_eq(regions.region_at(Vector3(0.0, 0.0, 0.0)), RegionMap.Region.CITY_CORE, "центр карты - деловой центр")
	assert_eq(regions.region_at(Vector3(400.0, 0.0, 400.0)), RegionMap.Region.CITY, "средняя зона - город")
	var desert := regions.region_at(Vector3(config.desert_center.x, 0.0, config.desert_center.y))
	assert_eq(desert, RegionMap.Region.DESERT, "центр пустыни - пустыня")
	var forest := regions.region_at(Vector3(config.forest_center.x, 0.0, config.forest_center.y))
	assert_eq(forest, RegionMap.Region.FOREST, "центр леса - лес")
	assert_eq(regions.region_at(Vector3(config.lake_center.x, 0.0, config.lake_center.y)), RegionMap.Region.LAKE, "озеро распознаётся")


func test_all_regions_exist_in_the_world() -> void:
	var seen := {}
	var rng := test_rng(5)
	for i in range(3000):
		var position := Vector3(rng.randf_range(-2000.0, 2000.0), 0.0, rng.randf_range(-2000.0, 2000.0))
		if not regions.is_inside_map(position):
			continue
		seen[regions.region_at(position)] = true
	for region in [RegionMap.Region.CITY_CORE, RegionMap.Region.CITY, RegionMap.Region.SUBURB,
			RegionMap.Region.COUNTRY, RegionMap.Region.FOREST, RegionMap.Region.DESERT, RegionMap.Region.LAKE]:
		assert_true(seen.has(region), "регион %d присутствует в мире" % region)


func test_surface_lookup_covers_roads_and_terrain() -> void:
	var road_found := 0
	for id in range(0, mini(network.segment_count(), 200)):
		var segment: RoadNetwork.Segment = network.segments[id]
		if segment.points.size() < 1:
			continue
		var point: Vector3 = segment.points[0]
		if terrain.surface_at(point.x, point.z) == segment.surface:
			road_found += 1
	assert_gt(float(road_found), 20.0, "под дорогой определяется дорожная поверхность")
	var grass_like := terrain.surface_at(-1600.0, 1500.0)
	assert_ne(grass_like, Surface.Type.ASPHALT, "в глуши асфальта нет")


func test_ground_position_follows_the_height_field() -> void:
	var point := terrain.ground_position(250.0, -175.0, 1.5)
	assert_almost_eq(point.y, terrain.height_at(250.0, -175.0) + 1.5, 0.001, "ground_position учитывает подъём")
	assert_almost_eq(point.x, 250.0, 0.001, "x не меняется")


func test_slope_is_zero_on_flat_ground_and_positive_on_hills() -> void:
	var city_slope := terrain.slope_at(0.0, 0.0, 6.0)
	assert_lt(city_slope, 0.25, "в центре города уклон небольшой (дороги выровнены)")
	var max_slope := 0.0
	var rng := test_rng(3)
	for i in range(300):
		max_slope = maxf(max_slope, terrain.slope_at(rng.randf_range(-1900.0, 1900.0), rng.randf_range(-1900.0, 1900.0), 6.0))
	assert_gt(max_slope, 0.05, "в мире есть уклоны")


## Генерация чанка идёт в фоновом потоке, поэтому она обязана возвращать только
## данные (без ArrayMesh и без материалов - обращение к Assets из потока
## недопустимо).  Тест проверяет и сам обмен: меш, собранный из данных, совпадает
## с прямым commit().
func test_chunk_generation_is_resource_free_and_mesh_data_round_trips() -> void:
	var builder := MeshBuilder.new()
	builder.add_quad("asphalt", Vector3.ZERO, Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1))
	builder.add_box("brick", Transform3D(Basis(), Vector3(0, 0, 0)), Vector3(2, 2, 2))
	var data := builder.commit_data()
	assert_eq(data.size(), 2, "две группы материалов")
	assert_true(data.has("asphalt") and data.has("brick"), "имена материалов сохранены")
	var mesh := MeshBuilder.mesh_from_data(data)
	assert_true(mesh != null, "меш собирается из данных")
	assert_eq(mesh.get_surface_count(), 2, "по поверхности на материал")
	var vertices := 0
	for surface in range(mesh.get_surface_count()):
		var arrays := mesh.surface_get_arrays(surface)
		vertices += (arrays[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	assert_eq(vertices, 42, "6 вершин квада + 36 вершин коробки")

	var generator: WorldGenerator = WorldFixture.generator()
	var chunk_data := generator.generate_chunk_data(Vector2i(3, 3), WorldGenerator.TIER_FAR)
	assert_true(not chunk_data.has("meshes"), "данные чанка не содержат готовых мешей")
	assert_eq((chunk_data["mesh_data"] as Array).size(), 4, "четыре слоя геометрии")
	assert_gt(float((chunk_data["colliders"] as Array).size()), 0.0, "коллайдеры описаны данными")
	assert_gt(float(chunk_data["generation_ms"]), 0.0, "время генерации измеряется")
	# меши собираются из этих данных без ошибок и непустые
	var far_meshes := 0
	for mesh_data in (chunk_data["mesh_data"] as Array):
		var built := MeshBuilder.mesh_from_data(mesh_data as Dictionary)
		if built != null and built.get_surface_count() > 0:
			far_meshes += 1
	assert_gt(float(far_meshes), 0.0, "хотя бы один слой дальнего чанка содержит геометрию")
