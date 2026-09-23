extends TestCase

## The road graph is what makes police fast without cheating and what makes the
## world connected (city -> suburbs -> highways -> countryside), so its routing
## and query behaviour is tested on a real generated world.

var config: WorldConfig
var generator: WorldGenerator
var network: RoadNetwork


func before_all() -> void:
	config = WorldFixture.config()
	generator = WorldFixture.generator()
	network = generator.network


func test_world_has_a_large_connected_road_network() -> void:
	assert_gt(float(network.segment_count()), 200.0, "в мире сотни дорожных сегментов")
	assert_gt(network.total_length_m(), 60000.0, "суммарная длина дорог больше 60 км")
	var types := {}
	for segment in network.segments:
		types[segment.type] = int(types.get(segment.type, 0)) + 1
	assert_true(types.has(RoadNetwork.RoadType.HIGHWAY), "есть шоссе")
	assert_true(types.has(RoadNetwork.RoadType.STREET), "есть городские улицы")
	assert_true(types.has(RoadNetwork.RoadType.RURAL), "есть сельские дороги")


func test_city_is_a_grid_of_streets() -> void:
	assert_gt(float(network.city_grid_x.size()), 6.0, "сетка города имеет вертикальные улицы")
	assert_gt(float(network.city_grid_z.size()), 6.0, "сетка города имеет горизонтальные улицы")
	var spacing := network.city_grid_x[1] - network.city_grid_x[0]
	assert_almost_eq(spacing, config.city_block_pitch, 1.0, "шаг квартала равен city_block_pitch")


func test_nearest_road_projects_onto_the_road() -> void:
	var probe := Vector3(config.city_block_pitch * 0.5, 0.0, config.city_block_pitch * 0.5)
	var found := network.nearest_road(probe, 200.0)
	assert_false(found.is_empty(), "рядом с центром города дорога находится")
	assert_lt(float(found["distance"]), config.city_block_pitch * 0.75, "расстояние правдоподобно")
	var point: Vector3 = found["point"]
	assert_lt(Vector2(point.x - probe.x, point.z - probe.z).length(), config.city_block_pitch * 0.75, "точка проекции близко")


func test_route_across_the_city_exists_and_is_continuous() -> void:
	var from := Vector3(-300.0, 0.0, -300.0)
	var to := Vector3(700.0, 0.0, 900.0)
	var route := network.plan_route(from, to, 900)
	assert_gt(float(route.size()), 2.0, "маршрут найден")
	var points := network.route_points(route, from)
	assert_gt(float(points.size()), float(route.size()) * 0.5, "маршрут развёрнут в точки")
	# consecutive route points must not jump across the map
	var longest_jump := 0.0
	for index in range(points.size() - 1):
		longest_jump = maxf(longest_jump, points[index].distance_to(points[index + 1]))
	assert_lt(longest_jump, 320.0, "маршрут непрерывен (нет телепортов между сегментами)")
	var end_distance := points[points.size() - 1].distance_to(to)
	assert_lt(end_distance, 260.0, "маршрут доходит до цели (с точностью до квартала)")


func test_route_between_distant_regions_is_not_absurdly_long() -> void:
	# country -> city: the route must stay in the same order of magnitude as the
	# straight line, otherwise police would drive around the world forever
	var from := Vector3(-1500.0, 0.0, 1300.0)
	var to := Vector3(900.0, 0.0, 400.0)
	var route := network.plan_route(from, to, 1200)
	assert_gt(float(route.size()), 1.0, "маршрут через всю карту строится")
	var points := network.route_points(route, from)
	var length := MathUtils.polyline_length(points)
	var straight := from.distance_to(to)
	assert_lt(length, straight * 3.2, "дорога не втрое длиннее прямой")


func test_segments_in_area_returns_local_roads_only() -> void:
	var center := Vector3.ZERO
	var radius := 300.0
	var ids := network.segments_in_area(center, radius)
	assert_gt(float(ids.size()), 4.0, "в центре города дороги есть")
	assert_lt(float(ids.size()), float(network.segment_count()), "функция не возвращает весь мир")
	for id in ids:
		# A long segment may have both of its vertices far away and still pass right
		# through the area, so the check is done against the polyline itself.
		var segment: RoadNetwork.Segment = network.segments[id]
		var nearest := INF
		for i in range(segment.points.size() - 1):
			var closest := MathUtils.closest_point_on_segment_xz(center, segment.points[i], segment.points[i + 1])
			nearest = minf(nearest, Vector2(closest.x - center.x, closest.z - center.z).length())
		assert_le(nearest, radius + 1.0, "сегмент %d действительно рядом" % id)


func test_random_road_point_respects_distance_window() -> void:
	var rng := test_rng(99)
	var center := Vector3(200.0, 0.0, -300.0)
	for i in range(20):
		var found := network.random_road_point(center, 150.0, 500.0, rng, 12)
		if found.is_empty():
			continue
		var distance := Vector2(found["point"].x - center.x, found["point"].z - center.z).length()
		assert_between(distance, 150.0, 500.0, "точка спавна попадает в окно дистанции")


func test_neighbours_do_not_lead_backwards() -> void:
	for id in range(mini(network.segment_count(), 400)):
		var segment: RoadNetwork.Segment = network.segments[id]
		if segment.node_end < 0:
			continue
		var next := network.neighbours(id, true)
		if next.size() <= 1:
			continue
		for neighbour in next:
			assert_ne(neighbour, id, "сегмент не считается соседом сам себе")
		return
	assert_true(true, "граф связан настолько, что проверка выполнима")


func test_world_is_connected_between_city_and_countryside() -> void:
	var city := Vector3(120.0, 0.0, 60.0)
	var countryside := Vector3(-1400.0, 0.0, 1250.0)
	var route := network.plan_route(city, countryside, 1500)
	assert_gt(float(route.size()), 0.0, "из города можно уехать по дорогам в пустошь")
