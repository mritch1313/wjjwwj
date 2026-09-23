extends TestCase

## Two acceptance criteria live here:
##  * police spawns are *validated* (ground, free space, distance window, not in
##    front of the camera) instead of appearing on top of the player,
##  * the player is only arrested when the car is genuinely immobilised,
##    surrounded and boxed in - never by touching a police car.
##
## The arrest rules are checked through the public `update()` entry point with an
## explicit `blocked` value, so no physics world is needed head-lessly: the ray
## fan itself only runs in game (`blocked_ratio` with a real space state).

var config: GameplayConfig
var terrain: TerrainField
var network: RoadNetwork
var spawn: SpawnManager


func before_all() -> void:
	config = Config.gameplay
	terrain = WorldFixture.terrain()
	network = WorldFixture.network()
	spawn = SpawnManager.new(config, terrain, network)
	spawn.set_seed(4242)


## ------------------------------------------------------------------- spawning
func test_spawn_position_is_on_dry_ground_within_the_distance_window() -> void:
	var player := Vector3(120.0, 0.0, 60.0)
	var found := spawn.find_spawn_position(player, Vector3.FORWARD, null, [], null)
	assert_false(found.is_empty(), "валидная точка спавна найдена: %s" % spawn.last_rejection)
	var point: Vector3 = found["point"]
	var distance := Vector2(point.x - player.x, point.z - player.z).length()
	assert_between(distance, config.spawn_min_distance_m, config.spawn_max_distance_m, "спавн внутри окна дистанции")
	assert_gt(terrain.height_at(point.x, point.z), terrain.config.water_level, "спавн не под водой")
	assert_le(terrain.slope_at(point.x, point.z, 6.0), 0.5, "спавн на ровном месте")
	assert_true(found.has("tangent"), "спавн задаёт направление по дороге")


func test_spawn_rejects_points_too_close_to_other_police() -> void:
	var player := Vector3(-200.0, 0.0, 300.0)
	var first := spawn.find_spawn_position(player, Vector3.FORWARD, null, [], null)
	assert_false(first.is_empty(), "первая точка найдена")
	var occupied: Array = [first["point"]]
	var second := spawn.find_spawn_position(player, Vector3.FORWARD, null, occupied, null)
	if second.is_empty():
		assert_true(true, "при отсутствии свободных мест менеджер честно ничего не возвращает")
	else:
		var gap := Vector2(
			float(second["point"].x) - float(first["point"].x),
			float(second["point"].z) - float(first["point"].z)
		).length()
		assert_ge(gap, config.spawn_min_separation_m, "вторая машина не появляется внутри первой")


func test_spawn_produces_positions_ahead_of_the_player() -> void:
	var player := Vector3(0.0, 0.0, 0.0)
	var ahead := 0
	var found_any := 0
	for i in range(12):
		var found := spawn.find_spawn_position(player, Vector3.FORWARD, null, [], null)
		if found.is_empty():
			continue
		found_any += 1
		var point: Vector3 = found["point"]
		if (point - player).dot(Vector3.FORWARD) > 0.0:
			ahead += 1
	assert_gt(float(found_any), 0.0, "спавн вообще находит точки")
	assert_ge(float(ahead), 2.0, "среди точек спавна есть позиции впереди игрока (для перехвата)")


func test_spawn_reports_the_reason_when_it_fails() -> void:
	var manager := SpawnManager.new(config, terrain, network)
	manager.set_seed(7)
	# Impossible window: the world is 4 km across, so no road point can be 20 km away
	# from the player and the spawner has to say so instead of returning silently.
	var impossible := GameplayConfig.new()
	impossible.spawn_min_distance_m = 20000.0
	impossible.spawn_max_distance_m = 21000.0
	var strict := SpawnManager.new(impossible, terrain, network)
	strict.find_spawn_position(Vector3.ZERO, Vector3.FORWARD, null, [], null)
	assert_ne(strict.last_rejection, "", "причина отказа сообщается, а не молчится")
	assert_true(
		strict.last_rejection in ["too_close", "too_far", "no_road_network", "bad_ground", "blocked", "no_candidates"],
		"причина отказа из известного списка: %s" % strict.last_rejection)


func test_player_start_is_snapped_to_a_road() -> void:
	var found := spawn.find_player_start(Vector3(118.0, 0.0, 74.0))
	assert_false(found.is_empty(), "стартовая позиция найдена")
	var point: Vector3 = found["point"]
	var road := network.nearest_road(point, 60.0)
	assert_false(road.is_empty(), "игрок стартует рядом с дорогой")
	assert_lt(float(road["distance"]), 12.0, "игрок стартует практически на дороге")
	assert_gt(terrain.height_at(point.x, point.z), terrain.config.water_level + 0.4, "старт не в воде")


## --------------------------------------------------------------------- arrest
func _police_near() -> Array:
	return [Vector3(3.0, 0.0, 0.0), Vector3(-3.0, 0.0, 0.0), Vector3(0.0, 0.0, 4.0)]


func test_arrest_does_not_trigger_while_the_player_is_moving() -> void:
	var arrest := ArrestSystem.new(config)
	var caught := false
	for i in range(300):
		caught = arrest.update(1.0 / 60.0, Vector3.ZERO, 12.0, 4, _police_near(), 0.95) or caught
	assert_false(caught, "движущуюся машину задержать нельзя")
	assert_eq(arrest.last_reason, "still_moving", "причина честно сообщается")
	assert_almost_eq(arrest.progress(), 0.0, 0.001, "прогресс задержания не растёт на ходу")


func test_arrest_triggers_only_when_pinned_for_the_hold_time() -> void:
	var arrest := ArrestSystem.new(config)
	var caught := false
	var steps := int(config.arrest_hold_time_s * 60.0)
	for i in range(steps - 6):
		caught = arrest.update(1.0 / 60.0, Vector3.ZERO, 0.3, 4, _police_near(), 0.9) or caught
	assert_false(caught, "до истечения времени удержания задержания нет")
	assert_gt(arrest.progress(), 0.85, "прогресс задержания почти достигнут")
	for i in range(12):
		caught = arrest.update(1.0 / 60.0, Vector3.ZERO, 0.3, 4, _police_near(), 0.9) or caught
	assert_true(caught, "после удержания задержание срабатывает")
	assert_true(arrest.is_arrested, "состояние задержания сохранено")


func test_arrest_requires_police_close_by() -> void:
	var arrest := ArrestSystem.new(config)
	var far_away: Array = [Vector3(90.0, 0.0, 0.0), Vector3(0.0, 0.0, 120.0)]
	var caught := false
	for i in range(600):
		caught = arrest.update(1.0 / 60.0, Vector3.ZERO, 0.2, 4, far_away, 0.95) or caught
	assert_false(caught, "без машин рядом задержания нет, даже если игрок стоит")
	assert_eq(arrest.last_reason, "not_surrounded", "причина - полиция не удерживает")


func test_arrest_requires_being_wedged_in() -> void:
	var arrest := ArrestSystem.new(config)
	var caught := false
	for i in range(600):
		caught = arrest.update(1.0 / 60.0, Vector3.ZERO, 0.2, 4, _police_near(), 0.2) or caught
	assert_false(caught, "на свободной дороге игрока не задерживают (есть куда уехать)")
	assert_eq(arrest.last_reason, "free_space", "причина - есть свободное пространство")


func test_arrest_counter_decays_when_pressure_is_released() -> void:
	var arrest := ArrestSystem.new(config)
	for i in range(60):
		arrest.update(1.0 / 60.0, Vector3.ZERO, 0.2, 4, _police_near(), 0.9)
	var partial := arrest.progress()
	assert_gt(partial, 0.0, "прогресс накопился")
	for i in range(180):
		arrest.update(1.0 / 60.0, Vector3.ZERO, 0.2, 4, _police_near(), 0.0)
	assert_lt(arrest.progress(), partial, "без блокировки прогресс ареста спадает")
	assert_almost_eq(arrest.progress(), 0.0, 0.01, "через несколько секунд счётчик обнуляется")


func test_airborne_or_tilted_car_is_not_arrested() -> void:
	var arrest := ArrestSystem.new(config)
	var caught := false
	for i in range(600):
		caught = arrest.update(1.0 / 60.0, Vector3.ZERO, 0.1, 0, _police_near(), 0.9) or caught
	assert_false(caught, "перевёрнутую/подлетевшую машину не 'арестовывают'")
	assert_eq(arrest.last_reason, "not_upright", "причина - машина не на колёсах")


func test_blocked_ratio_is_safe_without_a_physics_world() -> void:
	var arrest := ArrestSystem.new(config)
	assert_almost_eq(arrest.blocked_ratio(null, Vector3.ZERO, [], 1.0 / 60.0), 0.0, 0.0001,
		"без физического мира луч-фан не падает и возвращает 0")


func test_arrest_status_exposes_progress_for_the_hud() -> void:
	var arrest := ArrestSystem.new(config)
	arrest.update(1.0 / 60.0, Vector3.ZERO, 0.2, 4, _police_near(), 0.9)
	var status := arrest.status()
	assert_true(status.has("progress"), "статус содержит прогресс")
	assert_true(status.has("reason"), "статус содержит причину")
	assert_between(float(status["progress"]), 0.0, 1.0, "прогресс в диапазоне 0..1")


func test_gameplay_config_values_are_sane() -> void:
	assert_le(config.min_police_count, config.max_police_count, "минимум полиции не больше максимума")
	assert_lt(config.spawn_min_distance_m, config.spawn_max_distance_m, "окно спавна не вывернуто")
	assert_gt(config.spawn_min_separation_m, 0.0, "минимальная дистанция между машинами задана")
	assert_gt(config.arrest_hold_time_s, 0.0, "время удержания задано")
	assert_between(config.arrest_blocked_ratio, 0.0, 1.0, "порог блокировки в диапазоне 0..1")
	assert_gt(config.escape_time_s, 0.0, "время отрыва задано")
