extends TestCase

## Game flow: starting a pursuit stores the setup, clamps values, drives the
## police manager and ends with the right state.  The police manager is replaced
## by a small recording stub (the real one needs a physics world), which keeps
## the test focused on the flow rules themselves.

class StubPolice:
	extends Node
	var started: int = 0
	var stopped: int = 0
	var last_count: int = 0
	var last_level: int = 0
	var cleared: int = 0

	func start_pursuit(count: int, level: int) -> void:
		started += 1
		last_count = count
		last_level = level

	func stop_pursuit() -> void:
		stopped += 1

	func clear_police() -> void:
		cleared += 1

	func set_ai_level(_level: int) -> void:
		pass

	func set_police_count(_count: int) -> void:
		pass

	func active_count() -> int:
		return 3

	func status() -> Dictionary:
		return {"active": true, "cars": 3}

	func reset_counters() -> void:
		started = 0
		stopped = 0
		cleared = 0
		last_count = 0
		last_level = 0


var stub: StubPolice


func before_all() -> void:
	stub = StubPolice.new()
	Game.register_police_manager(stub)


func after_all() -> void:
	Game.police_manager = null
	stub.free()


## Test methods run in alphabetical order and share the singleton, so every test
## starts from a clean free-roam session and fresh stub counters.
func before_each() -> void:
	stub.reset_counters()
	Game.back_to_free_roam()


func test_start_pursuit_clamps_and_forwards_the_setup() -> void:
	Game.start_pursuit(99, 9)
	assert_eq(stub.last_count, Config.gameplay.max_police_count, "число машин ограничено максимумом")
	assert_eq(stub.last_level, Config.police.level_count(), "уровень ИИ ограничен максимумом")
	assert_true(Game.is_pursuit_active(), "состояние - погоня")
	assert_true(Save.last_police_count == stub.last_count, "выбор сохранён в профиле")
	Game.start_pursuit(0, 0)
	assert_eq(stub.last_count, Config.gameplay.min_police_count, "нулевое значение поднимается до минимума")
	assert_ge(float(stub.last_level), 1.0, "уровень не может быть нулевым")


func test_pursuit_timer_runs_and_stops_on_arrest() -> void:
	Game.start_pursuit(3, 2)
	Game.pursuit_time_s = 42.0
	Game.stop_pursuit("arrested")
	assert_eq(Game.state, GameState.State.ARRESTED, "задержание переводит игру в состояние ARRESTED")
	assert_almost_eq(Game.last_pursuit_duration_s, 42.0, 0.001, "длительность погони зафиксирована")
	assert_eq(stub.stopped, 1, "менеджер полиции остановлен один раз")


func test_escape_records_an_escape() -> void:
	var before := Save.escapes
	Game.start_pursuit(2, 1)
	Game.pursuit_time_s = 17.0
	Game.stop_pursuit("escaped")
	assert_eq(Game.state, GameState.State.ESCAPED, "уход от погони приводит к ESCAPED")
	assert_eq(Save.escapes, before + 1, "профиль игрока учёл уход от погони")


func test_back_to_free_roam_clears_the_police() -> void:
	var before := stub.cleared
	Game.back_to_free_roam()
	assert_eq(Game.state, GameState.State.FREE_ROAM, "состояние - свободная езда")
	assert_eq(stub.cleared, before + 1, "полиция убрана с карты")


func test_registry_round_trip() -> void:
	Game.registry_set("test_key", 1234)
	assert_eq(int(Game.registry_get("test_key", 0)), 1234, "реестр хранит значения между системами")
	assert_eq(Game.registry_get("missing_key", "fallback"), "fallback", "реестр возвращает значение по умолчанию")


func test_ai_level_change_is_persisted() -> void:
	Game.set_ai_level(4)
	assert_eq(Settings.ai_level, 4, "уровень ИИ сохранён в настройках")
	Game.set_ai_level(99)
	assert_eq(Settings.ai_level, Config.police.level_count(), "уровень ограничен доступными")
	Game.set_ai_level(2)
