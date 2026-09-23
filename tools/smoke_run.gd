extends Node

## Смоук-тест собранной игры: поднимает главную сцену целиком (мир, машина,
## камера, HUD, меню, полиция), эмулирует игру за игрока и печатает итог.
##
## Запуск (head-less, как в CI):
##   godot --headless --path . res://tools/smoke_run.tscn
##
## Тест падает (код выхода 1), если:
##   * мир не собрался за отведённое время;
##   * машина не поехала при нажатом газе;
##   * погоня не началась или менеджер полиции не выпустил машины;
##   * HUD/миникарта/настройки графики не отвечают.
##
## Ошибки скриптов Godot печатает в stderr, поэтому в CI лог дополнительно
## проверяется на строку "SCRIPT ERROR" — именно так этот тест нашёл уже три
## реальных расхождения API между модулями.

## Ожидания измеряются в *кадрах физики* (60 Гц симуляции), а не в секундах
## настенных часов: в head-less прогоне один кадр может длиться десятки секунд
## (генерация чанков), зато физика всегда шагает ровно 1/60 с.  Значения ниже -
## это секунды симуляции, переведённые в кадры.
const PHYSICS_FPS := 60
const WORLD_READY_FRAMES := 400
const DRIVE_FRAMES := 12 * PHYSICS_FPS
const NITRO_FRAMES := 3 * PHYSICS_FPS
const CHASE_FRAMES := 15 * PHYSICS_FPS
## Аварийный предел по настенным часам, чтобы тест не завис в CI.
const WALL_CLOCK_LIMIT_S := 300.0

var main: Node = null
var failures: PackedStringArray = PackedStringArray()
var checks: int = 0
var elapsed := 0.0


func _ready() -> void:
	print("=== Смоук-тест игры ===")
	main = load("res://scenes/main/main.tscn").instantiate()
	add_child(main)
	await get_tree().process_frame
	await _run()
	_report()
	get_tree().quit(1 if failures.size() > 0 else 0)


func _fail(message: String) -> void:
	failures.append(message)
	print("  FAIL %s" % message)


func _check(condition: bool, message: String) -> void:
	checks += 1
	print(("  ok   " if condition else "  FAIL ") + message)
	if not condition:
		failures.append(message)


## То же ожидание, но с записью одной строки состояния каждые полсекунды
## симуляции: если условие так и не выполнилось, эти строки покажут, что именно
## происходило с машиной (стоит, буксует, улетела, потеряла землю).
func _wait_for_traced(
	condition: Callable,
	limit_frames: int,
	what: String,
	player_car: VehicleController,
	trace: PackedStringArray
) -> bool:
	var started := Time.get_ticks_msec()
	for frame in range(limit_frames):
		if condition.call():
			return true
		await get_tree().physics_frame
		if not is_instance_valid(main):
			return false
		if frame % (PHYSICS_FPS / 2) == 0:
			trace.append("кадр %4d: %s км/ч=%.1f колёс=%d наклон=%.1f° газ=%.2f" % [
				frame, str(player_car.global_position.snappedf(0.1)), player_car.speed_kmh(),
				player_car.grounded_wheels,
				rad_to_deg(player_car.global_basis.y.angle_to(Vector3.UP)),
				player_car.vehicle_input().throttle])
		if (Time.get_ticks_msec() - started) / 1000.0 > WALL_CLOCK_LIMIT_S:
			print("       (ожидание «%s» прервано по лимиту времени)" % what)
			return false
	print("       (ожидание «%s» истекло: %d кадров физики)" % [what, limit_frames])
	return false


## Диагностика провала «машина не едет»: одной строкой всё, что нужно, чтобы
## понять причину (высоты, наклон, состояние подвески, вход, сбросы).
func _dump_car_state(player_car: VehicleController, world_streamer: Node) -> void:
	var space: PhysicsDirectSpaceState3D = player_car.get_world_3d().direct_space_state
	var from: Vector3 = player_car.global_position + Vector3.UP * 8.0
	var query := PhysicsRayQueryParameters3D.create(from, from + Vector3.DOWN * 16.0)
	query.collision_mask = 1
	var hit: Dictionary = space.intersect_ray(query)
	var input: VehicleInput = player_car.vehicle_input()
	print("       позиция: %s  поворот: %s" % [
		player_car.global_position.snappedf(0.1),
		player_car.global_rotation_degrees.snappedf(0.1)])
	print("       автогаз=%s качество=%s поверхность=%d" % [
		str(Settings.auto_accelerate), Settings.preset().title, player_car.current_surface])
	print("       состояние машины: y=%.2f земля(луч)=%s земля(height_at)=%.2f" % [
		player_car.global_position.y,
		("нет" if hit.is_empty() else "%.2f" % hit["position"].y),
		world_streamer.call("height_at", player_car.global_position.x, player_car.global_position.z)])
	print("       наклон=%.1f° газ=%.2f колесо0: on_ground=%s load=%.0f сжатие=%.3f" % [
		rad_to_deg(player_car.global_basis.y.angle_to(Vector3.UP)), input.throttle,
		str(player_car.wheels[0].on_ground), player_car.wheels[0].load,
		player_car.wheels[0].compression])
	print("       freeze=%s recovering=%s grounded=%d состояние=%d" % [
		str(player_car.freeze), str(player_car.get("_recovering")),
		player_car.grounded_wheels, Game.state])


## Ждёт выполнения условия, прокручивая кадры физики (то есть время симуляции),
## с общим ограничением по настенным часам.
func _wait_for(condition: Callable, limit_frames: int, what: String) -> bool:
	var started := Time.get_ticks_msec()
	for _frame in range(limit_frames):
		if condition.call():
			return true
		await get_tree().physics_frame
		if not is_instance_valid(main):
			return false
		if (Time.get_ticks_msec() - started) / 1000.0 > WALL_CLOCK_LIMIT_S:
			print("       (ожидание «%s» прервано по лимиту времени)" % what)
			return false
	print("       (ожидание «%s» истекло: %d кадров физики)" % [what, limit_frames])
	return false


func _run() -> void:
	var started := Time.get_ticks_msec()
	var ready_ok := await _wait_for(
		func() -> bool: return bool(main.get("world_ready")), WORLD_READY_FRAMES, "мир собран"
	)
	elapsed = (Time.get_ticks_msec() - started) / 1000.0
	_check(ready_ok, "мир собран за %.1f с реального времени" % elapsed)
	if not ready_ok:
		return

	var world = main.get("world")
	var player = main.get("player")
	var hud = main.get("hud")
	var police = main.get("police")
	var camera = main.get("chase_camera")
	_check(world != null and world.loaded_chunk_count() > 0,
		"чанки загружены: %d" % (world.loaded_chunk_count() if world else -1))
	_check(player != null, "машина игрока создана")
	_check(camera != null and camera.has_method("camera") and camera.camera() != null,
		"камера от третьего лица создана")
	_check(hud != null, "HUD создан")
	_check(police != null, "менеджер полиции создан")
	if player == null or world == null:
		return

	# --- 1. Мир вокруг игрока: дорога под колёсами и поверхность из провайдера.
	var roads: RoadNetwork = world.road_network()
	var on_road := roads != null and not roads.nearest_road(player.global_position, 60.0).is_empty()
	_check(on_road, "игрок стоит рядом с дорогой")
	var surface: int = player.current_surface
	_check(surface >= 0, "поверхность под машиной определена (тип %d)" % surface)

	# --- 1a. Сенсорное управление: кнопки должны реально писать ввод в машину.
	var controls = main.get("touch_controls")
	if controls != null:
		var layout: Dictionary = controls.status()
		var throttle_point: Vector2 = layout["throttle_center"]
		_check(controls.hit_area_at(throttle_point) == "throttle",
			"центр педали газа попадает в кнопку газа")
		var press := InputEventScreenTouch.new()
		press.index = 3
		press.pressed = true
		press.position = throttle_point
		controls._input(press)
		_check(controls.vehicle_input.throttle > 0.99, "нажатие газа даёт тягу")
		var release := InputEventScreenTouch.new()
		release.index = 3
		release.pressed = false
		release.position = throttle_point
		controls._input(release)
		_check(controls.vehicle_input.throttle < 0.01, "отпускание газа гасит тягу")
		var brake_point: Vector2 = layout["brake_center"]
		var brake_press := InputEventScreenTouch.new()
		brake_press.index = 4
		brake_press.pressed = true
		brake_press.position = brake_point
		controls._input(brake_press)
		_check(controls.vehicle_input.brake > 0.99 and controls.vehicle_input.throttle < 0.01,
			"кнопка тормоза даёт торможение и задний ход")
		var brake_release := InputEventScreenTouch.new()
		brake_release.index = 4
		brake_release.pressed = false
		brake_release.position = brake_point
		controls._input(brake_release)
		var free_point := Vector2(player.global_position.x * 0.0 + 40.0, 60.0)
		if controls.hit_area_at(free_point) == "camera":
			_check(true, "свободная область экрана отдана камере")
		else:
			_check(false, "свободная область экрана отдана камере")
	else:
		_check(false, "сенсорное управление создано")

	# --- 1b. Кнопка «Y» в настройках: каждое нажатие поднимает машину на метр.
	var lift_start: float = player.global_position.y
	var lift_origin: Transform3D = player.global_transform
	var menu: MainMenu = main.menu
	if menu != null:
		menu.lift_car_requested.emit(1.0)
		menu.lift_car_requested.emit(1.0)
		menu.lift_car_requested.emit(1.0)
		var lifted: float = player.global_position.y - lift_start
		_check(lifted > 2.5 and lifted < 3.5, "кнопка «Y» подняла машину на %.2f м за три нажатия" % lifted)
	else:
		_check(false, "меню настроек доступно из сцены (для кнопки «Y»)")
	# Возвращаем машину ровно туда, где она стояла до подъёма (там заведомо
	# свободно), и гасим скорости: проверка разгона ниже должна начинаться
	# с земли, а не с трёх метров над дорогой.
	player.global_transform = lift_origin
	player.linear_velocity = Vector3.ZERO
	player.angular_velocity = Vector3.ZERO
	# Даём машине полсекунды, чтобы подвеска нашла землю после возврата.
	for frame in range(int(PHYSICS_FPS * 0.5)):
		await get_tree().physics_frame
	_check(player.global_position.distance_to(lift_origin.origin) < 3.0,
		"после кнопки «Y» машина вернулась на исходное место (%.1f м)" % player.global_position.distance_to(lift_origin.origin))
	print("       после «Y»: y=%.2f земля=%.2f колёс=%d наклон=%.1f° темп %.1f км/ч" % [
		player.global_position.y,
		world.terrain().height_at(player.global_position.x, player.global_position.z),
		player.grounded_wheels,
		rad_to_deg(player.global_basis.y.angle_to(Vector3.UP)),
		player.speed_kmh(),
	])

	# --- 2. Едем вперёд: скорость должна вырасти (проверяем физику, а не позицию).
	var input: VehicleInput = player.vehicle_input()
	var start_position: Vector3 = player.global_position
	# Газ держим каждый кадр: автоматический возврат машины на дорогу (после
	# переворота) сбрасывает ввод, и одиночная запись была бы потеряна.
	# Простейший автопилот «держимся дороги»: руль поворачиваем к ближайшей точке
	# дороги за 18 м впереди.  Без него машина на полном газу просто уезжает с
	# полосы в городскую застройку и тест проверял бы столкновения, а не разгон.
	var steer_along_road := func() -> void:
		var ahead: Vector3 = player.global_position + player.forward_direction() * 18.0
		var found: Dictionary = roads.nearest_road(ahead, 45.0)
		if found.is_empty():
			input.steer = 0.0
			return
		var desired: Vector3 = (found["point"] as Vector3) - player.global_position
		desired.y = 0.0
		if desired.length_squared() < 0.01:
			input.steer = 0.0
			return
		var angle: float = player.forward_direction().signed_angle_to(desired.normalized(), Vector3.UP)
		input.steer = clampf(angle / deg_to_rad(Config.vehicle_player.max_steer_angle_deg), -1.0, 1.0)
	var trace: PackedStringArray = PackedStringArray()
	var speed_ok := false
	# Две попытки: если первая не дала разгона (в CI физика идёт с ограничением
	# шагов на кадр, машина могла застрять в трафике), машина возвращается на
	# дорогу и пробует снова - тест не должен падать из-за одной неудачной пробы.
	for attempt in range(2):
		if attempt > 0:
			player.reset_car(true)
			await get_tree().physics_frame
			await get_tree().physics_frame
		speed_ok = await _wait_for_traced(
			func() -> bool:
				input.throttle = 1.0
				steer_along_road.call()
				return player.forward_speed_ms() > 8.0,
			DRIVE_FRAMES, "машина разогналась", player, trace
		)
		if speed_ok:
			break
	if not speed_ok:
		for line in trace:
			print("       ", line)
	_check(speed_ok, "машина поехала: %.1f км/ч (ждали 8 м/с за %.0f с симуляции)" % [
		player.speed_kmh(), float(DRIVE_FRAMES) / float(PHYSICS_FPS)])
	if not speed_ok:
		_dump_car_state(player, world)
	if player.grounded_wheels == 0:
		var ground_now: float = world.terrain().height_at(player.global_position.x, player.global_position.z)
		print("       диагностика: y=%.2f земля=%.2f разница=%.2f темп=%.1f км/ч" % [
			player.global_position.y, ground_now, player.global_position.y - ground_now, player.speed_kmh()
		])
		_dump_car_state(player, world)
	_check(player.grounded_wheels > 0, "колёса на земле (%d из 4)" % player.grounded_wheels)
	_check(player.global_position.distance_to(start_position) > 5.0,
		"машина проехала %.1f м" % player.global_position.distance_to(start_position))

	# --- 2b. Долгий заезд: машина не должна проваливаться под землю, даже если
	# стример не успел построить чанк впереди (раньше именно это и происходило).
	var terrain = world.terrain()
	var sink_frames := 0
	var worst_sink := 0.0
	var long_frames := int(PHYSICS_FPS * 12)
	for frame in range(long_frames):
		input.throttle = 1.0
		steer_along_road.call()
		await get_tree().physics_frame
		if terrain == null:
			break
		var ground: float = terrain.height_at(player.global_position.x, player.global_position.z)
		var depth: float = ground - player.global_position.y
		if depth > 1.2:
			sink_frames += 1
			worst_sink = maxf(worst_sink, depth)
	_check(sink_frames == 0, "за 12 с езды машина не провалилась под землю (провалов %d, худший %.1f м)" % [
		sink_frames, worst_sink])
	_check(world.loaded_chunk_count() > 0, "мир вокруг машины остался построен: %d чанков" % world.loaded_chunk_count())

	# --- 3. Нитро: тяга появляется и тратит заряд.
	var nitro: NitroSystem = player.nitro
	var charge_before := nitro.charge_ratio()
	input.nitro = true
	var boost_ok := await _wait_for(
		func() -> bool: return nitro.active, NITRO_FRAMES, "нитро включилось"
	)
	_check(boost_ok, "нитро включилось (заряд %d%%)" % int(nitro.charge_ratio() * 100.0))
	await _wait_for(func() -> bool: return false, int(PHYSICS_FPS * 0.6), "пауза")
	_check(nitro.charge_ratio() < charge_before, "заряд нитро расходуется")
	input.nitro = false
	input.throttle = 0.0
	input.steer = 0.0
	input.brake = 1.0

	# --- 4. Погоня: машины полиции появляются и едут за игроком.
	var pursuit_started := Time.get_ticks_msec()
	Game.start_pursuit(2, 2)
	var police_ok := await _wait_for(
		func() -> bool: return Game.active_police_count() > 0, CHASE_FRAMES, "полиция выехала"
	)
	_check(police_ok, "погоня началась: машин в погоне %d" % Game.active_police_count())
	_check(Game.is_pursuit_active(), "состояние игры - PURSUIT")
	if police_ok:
		# Даём полиции время проехать: проверяем, что её AI реально двигает машины.
		input.brake = 0.0
		input.throttle = 0.4
		var police_car: VehicleController = null
		for child in police.get_children():
			if child is VehicleController and not child.is_player_vehicle:
				police_car = child
				break
		if police_car != null:
			var police_start: Vector3 = police_car.global_position
			var moved := await _wait_for(
				func() -> bool: return police_car.global_position.distance_to(police_start) > 4.0,
				CHASE_FRAMES, "машина полиции поехала"
			)
			_check(moved, "машина полиции проехала %.1f м (роль %s)" % [
				police_car.global_position.distance_to(police_start), police_car.vehicle_role])
			_check(police_car.is_player_vehicle == false, "машина полиции не считается игроком")
		# Полиция ездит по тому же миру: под ней тоже не должно быть пустоты.
		# Даём менеджеру время поднять машину, если она всё же оказалась ниже
		# земли (в CI тайминги другие, и без паузы проверка была бы хрупкой).
		await _wait_for(func() -> bool: return false, PHYSICS_FPS, "пауза перед проверкой полиции")
		if terrain != null:
			var police_sunk := 0
			for car in police.cars:
				if not is_instance_valid(car):
					continue
				var police_ground: float = terrain.height_at(car.global_position.x, car.global_position.z)
				if police_ground - car.global_position.y > 1.2:
					police_sunk += 1
			_check(police_sunk == 0, "машины полиции не провалились под землю (провалилось %d)" % police_sunk)
		else:
			_check(false, "в менеджере полиции нет машин (только служебные узлы)")
	print("       (погоня длилась %.1f с)" % ((Time.get_ticks_msec() - pursuit_started) / 1000.0))

	# --- 5. Возврат в свободную езду чистит сцену.
	Game.stop_pursuit("escaped")
	Game.back_to_free_roam()
	_check(Game.state == GameState.State.FREE_ROAM, "после ESCAPED игра вернулась в свободную езду")

	# --- 6. Графика: пресеты качества различаются и реально применяются.
	if Config.quality_preset_count() >= 2:
		var low: GraphicsQuality = Config.quality_preset(0)
		var high: GraphicsQuality = Config.quality_preset(Config.quality_preset_count() - 1)
		_check(low.view_distance_m < high.view_distance_m,
			"LOW видит ближе, чем HIGH (%.0f < %.0f м)" % [low.view_distance_m, high.view_distance_m])
		var radius_before: float = world.view_radius
		world.apply_quality(low)
		_check(world.view_radius <= radius_before,
			"дальность стриминга пересчитана под качество: %.0f м" % world.view_radius)
		world.apply_quality(high)

	# --- 7. Миникарта переводит мир в пиксели.
	var minimap: Minimap = hud.minimap if hud != null else null
	if minimap != null:
		var mapped := minimap.world_to_map(
			player.global_position.x, player.global_position.z, player.global_position, 0.0
		)
		_check(mapped.length() >= 0.0 and not is_nan(mapped.x) and not is_nan(mapped.y),
			"миникарта переводит координаты мира в пиксели: %s" % str(mapped.snapped(Vector2.ONE)))
	else:
		_check(false, "миникарта не создана")

	print("=== Смоук-тест завершён: проверок %d, неудачных %d ===" % [checks, failures.size()])


func _report() -> void:
	if failures.is_empty():
		print("SMOKE PASSED")
		return
	for failure in failures:
		print("  - %s" % failure)
	print("SMOKE FAILED")
