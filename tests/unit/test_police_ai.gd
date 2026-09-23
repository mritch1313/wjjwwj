extends TestCase

## Police decision making.  The AI deliberately exposes its prediction, routing
## and reaction logic as plain functions so it can be checked here without a
## running physics world - and so that "difficulty comes from decisions, never
## from physics" is testable rather than a claim.
##
## The API under test (TrajectoryPredictor / RoutePlanner) is the one the police
## actually calls: see scripts/police/police_ai.gd.

var network: RoadNetwork
var terrain: TerrainField
var config: PoliceConfig


func before_all() -> void:
	network = WorldFixture.network()
	terrain = WorldFixture.terrain()
	config = Config.police


## The player state dictionary the predictor consumes.  The tests drive along +Z
## (forward = Vector3(0, 0, 1)) so "ahead of the car" is a positive z, which makes
## the numbers below readable; the predictor itself only follows the vector it is
## given, whatever its direction.
func _state(steer: float = 0.0, speed: float = 30.0, braking: bool = false) -> Dictionary:
	return {
		"position": Vector3.ZERO,
		"forward": Vector3(0.0, 0.0, 1.0),
		"speed_ms": speed,
		"steer": steer,
		"wheelbase": 2.72,
		"braking": braking,
	}


func test_straight_driving_predicts_a_straight_line() -> void:
	var points := TrajectoryPredictor.predict(_state(0.0), 2.0)
	assert_gt(float(points.size()), 5.0, "предсказание содержит несколько точек")
	var last: Vector3 = points[points.size() - 1]
	assert_almost_eq(last.x, 0.0, 0.6, "без руля машина едет прямо")
	assert_gt(last.z, 40.0, "предсказание уходит вперёд")
	assert_gt(last.z, 30.0 * 2.0 * 0.85, "учтена скорость автомобиля")


func test_steering_curves_the_prediction_to_the_same_side() -> void:
	var left := TrajectoryPredictor.predict(_state(-0.4), 2.0)
	var right := TrajectoryPredictor.predict(_state(0.4), 2.0)
	var left_last: Vector3 = left[left.size() - 1]
	var right_last: Vector3 = right[right.size() - 1]
	assert_lt(left_last.x, -3.0, "поворот налево уводит предсказание влево")
	assert_gt(right_last.x, 3.0, "поворот направо уводит предсказание вправо")


func test_high_speed_reduces_effective_turning() -> void:
	var slow := TrajectoryPredictor.predict(_state(0.4, 8.0), 2.0)
	var fast := TrajectoryPredictor.predict(_state(0.4, 45.0), 2.0)
	var slow_angle := absf(atan2(slow[slow.size() - 1].x, slow[slow.size() - 1].z))
	var fast_angle := absf(atan2(fast[fast.size() - 1].x, fast[fast.size() - 1].z))
	assert_lt(fast_angle, slow_angle, "на скорости машина поворачивает хуже (understeer)")


func test_braking_shortens_the_prediction() -> void:
	var coasting := TrajectoryPredictor.predict(_state(0.0, 30.0, false), 2.0)
	var braking := TrajectoryPredictor.predict(_state(0.0, 30.0, true), 2.0)
	assert_lt(
		braking[braking.size() - 1].z, coasting[coasting.size() - 1].z,
		"тормозящая машина уедет меньше"
	)
	assert_lt(
		TrajectoryPredictor.predicted_speed(_state(0.0, 30.0, true), 1.5),
		TrajectoryPredictor.predicted_speed(_state(0.0, 30.0, false), 1.5),
		"predicted_speed учитывает торможение"
	)


func test_nitro_extends_the_prediction() -> void:
	# nitro raises the achievable speed (NitroSystem.SPEED_FACTOR), so the same
	# prediction horizon carries the car further
	var normal_speed: float = 30.0
	var boosted_speed: float = normal_speed * NitroSystem.SPEED_FACTOR
	var normal := TrajectoryPredictor.predict(_state(0.0, normal_speed), 2.0)
	var boosted := TrajectoryPredictor.predict(_state(0.0, boosted_speed), 2.0)
	assert_gt(
		boosted[boosted.size() - 1].z, normal[normal.size() - 1].z,
		"с нитро машина уедет дальше"
	)


func test_intercept_point_is_reachable_and_in_the_future() -> void:
	# Pursuer 20 m behind the player, 10 m/s faster: it gains 10 m every second, so
	# the first predicted point the player reaches is not reachable (20 m of gap at
	# 30 m/s takes 0.67 s, the cop needs 1.5 s) but a point ~2.2 s ahead already is.
	var predictions := TrajectoryPredictor.predict(_state(0.0), 4.0)
	var pursuer := Vector3(0.0, 0.0, -20.0)
	var cop_speed := 40.0
	var result := TrajectoryPredictor.intercept_point(predictions, pursuer, cop_speed)
	assert_false(result.is_empty(), "точка перехвата найдена")
	assert_true(bool(result["reachable"]), "перехват достижим, когда полиция быстрее игрока")
	assert_gt(float(result["time_s"]), 0.0, "перехват в будущем, а не сейчас")
	var point: Vector3 = result["point"]
	assert_gt(point.z, 2.0, "перехват впереди игрока, а не за хвостом")
	var distance := Vector2(point.x - pursuer.x, point.z - pursuer.z).length()
	assert_lt(distance, cop_speed * (float(result["time_s"]) + 1.0), "до точки реально доехать за отведённое время")


func test_unreachable_intercept_is_reported_honestly() -> void:
	var predictions := TrajectoryPredictor.predict(_state(0.0, 45.0), 2.0)
	var result := TrajectoryPredictor.intercept_point(predictions, Vector3(0.0, 0.0, -400.0), 12.0)
	assert_false(result.is_empty(), "даже недостижимая цель возвращает ориентир")
	assert_false(bool(result["reachable"]), "невозможный перехват помечается как недостижимый (без читерства)")


func test_escape_routes_are_on_the_road_network() -> void:
	var routes := TrajectoryPredictor.escape_routes(Vector3.ZERO, Vector3.FORWARD, network, 420.0, 4)
	assert_gt(float(routes.size()), 0.0, "варианты отхода найдены на реальной сети")
	var best: Dictionary = routes[0]
	var point: Vector3 = best["point"]
	assert_gt(float(best["distance"]), 40.0, "отход не рядом с текущей позицией")
	assert_gt(best["segment"], -1, "отход привязан к сегменту дороги")
	# the road point must be a real road: the network agrees there is asphalt here
	var surface := network.road_surface_at(Vector3(point.x, 0.0, point.z))
	assert_ge(float(surface), 0.0, "точка отхода лежит на дороге")


func test_route_planner_follows_roads_and_replans() -> void:
	var planner := RoutePlanner.new(network)
	var from := Vector3(0.0, 0.0, 0.0)
	var goal := Vector3(900.0, 0.0, 700.0)
	planner.plan(from, goal, 0.0)
	assert_true(planner.has_route(), "маршрут построен")
	assert_true(planner.using_road_graph, "маршрут проходит по дорогам, а не по прямой")
	var lookahead := planner.next_waypoint(from, 20.0)
	assert_gt(lookahead.distance_to(from), 4.0, "есть куда рулить")
	assert_true(planner.needs_replan(3.0, 3.0, goal), "маршрут перестраивается по времени")
	assert_false(planner.needs_replan(0.2, 3.0, goal), "маршрут не перестраивается каждый кадр")
	assert_gt(planner.remaining_distance(from), 100.0, "остаток пути измеряется")


func test_route_planner_falls_back_to_a_direct_line_off_road() -> void:
	var planner := RoutePlanner.new(network)
	var middle_of_nothing := Vector3(-1500.0, 0.0, 1300.0)
	# road_bias = 0 -> pure straight line, which is what a PIN car uses
	planner.plan(middle_of_nothing, Vector3(0.0, 0.0, 0.0), 0.0, 0.0)
	assert_true(planner.has_route(), "запасной маршрут есть всегда")
	assert_false(planner.using_road_graph, "без road_bias планировщик честно помечает прямую линию")


func test_planner_detects_being_stuck() -> void:
	var planner := RoutePlanner.new(network)
	planner.plan(Vector3.ZERO, Vector3(200.0, 0.0, 200.0), 0.0)
	for i in range(180):
		planner.update_progress(1.0 / 60.0, Vector3.ZERO, 0.2, 20.0)
	assert_true(planner.is_stalled(config.stuck_time_s), "стоящая машина распознаётся как застрявшая")
	planner.update_progress(1.0, Vector3(30.0, 0.0, 0.0), 25.0, 20.0)
	assert_false(planner.is_stalled(config.stuck_time_s), "поехавшая машина перестаёт считаться застрявшей")


func test_next_corner_detects_turns() -> void:
	var planner := RoutePlanner.new(network)
	# hand-built L shaped route: straight, then 90 degree turn
	# reset() clears the waypoint list, so it has to run before the hand-built
	# route is installed.
	planner.reset()
	planner.waypoints = PackedVector3Array([
		Vector3(0, 0, 0), Vector3(0, 0, 30), Vector3(0, 0, 60), Vector3(40, 0, 60), Vector3(80, 0, 60),
	])
	var corner := planner.next_corner(90.0)
	assert_false(corner.is_empty(), "поворот найден")
	assert_gt(float(corner["angle"]), 0.6, "угол поворота близок к 90 градусам")
	planner.reset()
	planner.waypoints = PackedVector3Array([Vector3(0, 0, 0), Vector3(0, 0, 40), Vector3(0, 0, 80)])
	assert_true(planner.next_corner(90.0).is_empty(), "на прямой поворотов нет")


func test_corner_speed_estimate_is_physical() -> void:
	var tight := TrajectoryPredictor.corner_speed_ms(12.0, 1.0)
	var wide := TrajectoryPredictor.corner_speed_ms(80.0, 1.0)
	assert_lt(tight, wide, "крутой поворот проходится медленнее")
	assert_between(tight * 3.6, 25.0, 70.0, "скорость в крутом повороте правдоподобна")


func test_braking_helpers_are_consistent() -> void:
	var fast_distance := TrajectoryPredictor.braking_distance_m(40.0, 8.5)
	var slow_distance := TrajectoryPredictor.braking_distance_m(8.0, 8.5)
	assert_gt(fast_distance, 0.0, "тормозной путь положителен")
	assert_lt(slow_distance, fast_distance, "чем медленнее, тем короче тормозной путь")
	assert_gt(TrajectoryPredictor.time_to_stop(40.0, 8.5), TrajectoryPredictor.time_to_stop(8.0, 8.5),
		"остановка со скорости занимает больше времени")


func test_police_levels_stay_within_the_fair_speed_factor() -> void:
	for level in range(1, config.level_count() + 1):
		var params := config.params_for_level(level)
		assert_le(params.speed_factor(), PursuitBalance.POLICE_SPEED_FACTOR,
			"уровень %d не получает преимущества сверх договорённого" % level)
		assert_almost_eq(params.grip_factor, 1.0, 0.0001,
			"уровень %d не получает искусственного сцепления" % level)
		assert_gt(params.prediction_horizon_s, -0.001, "уровень %d задаёт горизонт предсказания" % level)


func test_role_names_and_colors_are_defined_for_every_role() -> void:
	for role in [PoliceRole.Type.CHASE, PoliceRole.Type.INTERCEPT, PoliceRole.Type.BLOCK,
			PoliceRole.Type.PIN, PoliceRole.Type.SUPPORT, PoliceRole.Type.REGROUP]:
		assert_ne(PoliceRole.name_of(role), "", "у роли %d есть имя" % role)
		assert_gt(PoliceRole.color_of(role).a, 0.0, "у роли %d есть цвет для миникарты" % role)
	assert_eq(PoliceRole.name_of(PoliceRole.Type.INTERCEPT), "INTERCEPT", "имя роли перехвата стабильно для HUD")
