class_name MainScene
extends Node3D

## Root of the game: builds the world, the player car, the camera, the touch
## controls, the HUD, the menu and the police, then wires them together through
## the Game autoload.
##
## The scene file (scenes/main/main.tscn) is intentionally minimal - everything
## gameplay related is created here in code, which keeps node paths out of the
## equation and makes the setup testable head-less.
##
## Startup order matters on a phone:
##   1. renderer settings + environment (cheap),
##   2. WorldGenerator world data (roads/city/regions) - one long step,
##   3. streamed chunk warm-up around the player - several smaller steps with a
##      progress bar, so the player never sees an empty world,
##   4. everything else (car, camera, HUD, police) and the menu.

## Сколько чанков строим за один шаг заставки.  После ускорения MeshBuilder
## чанк строится в разы быстрее, поэтому за шаг можно брать больше, и мир
## появляется быстрее.
const WARMUP_CHUNKS_PER_STEP := 2
## Сколько секунд машина может лежать на крыше, прежде чем игра сама вернёт её
## на дорогу: перевёрнутая машина иначе остаётся перевёрнутой навсегда, потому
## что игрок в этом положении обычно ничего не может сделать.
const FLIP_RECOVERY_TIME_S := 4.0
## Сколько секунд машина может стоять без опоры, прежде чем игра вернёт её на
## дорогу (застревание в геометрии, проваливание сквозь тонкую коллизию).
const STUCK_RECOVERY_TIME_S := 3.0
## LOD внешнего вида для всех машин сцены, не только полицейских: обычные
## машины мира тоже подробные модели, и в городе их десятки.  Машина игрока
## всегда остаётся на полном уровне.
const WORLD_CAR_LOD_INTERVAL_S := 0.5
const WORLD_CAR_LOD_MID_M := 45.0
const WORLD_CAR_LOD_FAR_M := 110.0

var world: WorldStreamer = null
var player: PlayerCar = null
var chase_camera: ChaseCamera = null
var police: PoliceManager = null
var hud: Hud = null
var menu: MainMenu = null
var touch_controls: MobileControls = null
var sun: DirectionalLight3D = null
var world_environment: WorldEnvironment = null

var world_ready: bool = false
var player_start_position: Vector3 = Vector3.ZERO

var _quality: GraphicsQuality = null
var _upside_down_time_s: float = 0.0
var _stuck_time_s: float = 0.0
var _car_lod_timer_s: float = 0.0


func _ready() -> void:
	randomize()
	_quality = Settings.preset()
	Settings.apply_orientation()
	Settings.apply_renderer_settings()
	Settings.apply_audio_bus_volumes()
	_build_environment()
	_build_interface()
	_load_world()


## -------------------------------------------------------------- environment --
func _build_environment() -> void:
	if ResourceLoader.exists("res://data/environment/default_environment.tres"):
		var environment_resource: Resource = load("res://data/environment/default_environment.tres")
		if environment_resource is Environment:
			world_environment = WorldEnvironment.new()
			world_environment.name = "WorldEnvironment"
			world_environment.environment = environment_resource
			add_child(world_environment)
	sun = DirectionalLight3D.new()
	sun.name = "Sun"
	sun.light_energy = 1.12
	sun.light_color = Color(1.0, 0.96, 0.88)
	sun.rotation_degrees = Vector3(-46.0, 38.0, 0.0)
	sun.directional_shadow_mode = DirectionalLight3D.SHADOW_PARALLEL_2_SPLITS
	sun.shadow_bias = 0.06
	sun.shadow_normal_bias = 1.4
	add_child(sun)
	apply_quality(_quality)
	Settings.quality_changed.connect(apply_quality)
	Perf.scalers_changed.connect(_on_scalers_changed)


## Автоадаптация (Perf) снижает качество, когда телефон не держит кадр: здесь
## её решения доходят до рендера - тени, разрешение и радиус стриминга.
func _on_scalers_changed(_value: float) -> void:
	if sun != null and _quality != null:
		sun.shadow_enabled = _quality.shadows_enabled and Perf.shadows_allowed
	Settings.apply_render_scale(_quality.render_scale * Perf.resolution_scale if _quality != null else 1.0)
	if world != null:
		world.apply_quality(_quality)


## Применяет пресет качества к освещению.  Раньше тени были включены всегда
## (sun.shadow_enabled = true без оглядки на пресет), поэтому даже на "Low" с
## выключенными тенями телефон платил за карту теней 2048 и мягкие фильтры -
## на слабом GPU это главный расход кадра.
func apply_quality(quality: GraphicsQuality) -> void:
	if quality == null or sun == null:
		return
	sun.shadow_enabled = quality.shadows_enabled and Perf.shadows_allowed
	sun.directional_shadow_max_distance = quality.shadow_distance_m
	sun.directional_shadow_blend_splits = quality.shadow_filter_quality > 0
	RenderingServer.directional_shadow_atlas_set_size(
		maxi(quality.shadow_map_size, 512), quality.shadow_filter_quality > 0
	)
	Settings.apply_renderer_settings()


func _build_interface() -> void:
	var ui_layer := CanvasLayer.new()
	ui_layer.name = "Controls"
	ui_layer.layer = 5
	add_child(ui_layer)
	touch_controls = MobileControls.new()
	touch_controls.name = "MobileControls"
	ui_layer.add_child(touch_controls)

	hud = Hud.new()
	hud.name = "Hud"
	add_child(hud)

	menu = MainMenu.new()
	menu.name = "MainMenu"
	menu.process_mode = Node.PROCESS_MODE_ALWAYS
	menu.start_pursuit_requested.connect(_on_start_pursuit_requested)
	menu.free_roam_requested.connect(_on_free_roam_requested)
	menu.resume_requested.connect(_on_resume_requested)
	menu.quit_to_free_roam_requested.connect(_on_quit_to_free_roam)
	menu.quality_changed.connect(_on_quality_changed)
	menu.paint_changed.connect(_on_paint_changed)
	menu.lift_car_requested.connect(_on_lift_car_requested)
	add_child(menu)

	touch_controls.pause_requested.connect(_on_pause_requested)
	touch_controls.camera_mode_requested.connect(_on_camera_mode_requested)
	touch_controls.reset_requested.connect(_on_reset_requested)
	hud.pause_requested.connect(_on_pause_requested)
	hud.pursuit_requested.connect(_on_hud_pursuit_requested)
	hud.reset_requested.connect(_on_reset_requested)
	_apply_camera_distance()


## ---------------------------------------------------------------- the world --
func _load_world() -> void:
	menu.show_loading(true, 0.0)
	await get_tree().process_frame
	world = WorldStreamer.new()
	world.name = "World"
	add_child(world)
	world.setup(Config.world)
	world.apply_quality(_quality)
	Game.register_world(world)
	await get_tree().process_frame
	_spawn_player()
	await get_tree().process_frame
	world.set_camera_target(player)
	await _warmup_world()
	world_ready = true
	menu.show_loading(false)
	menu.show_menu(true)
	Game.begin_free_roam()
	Game.toast.emit(L10n.t("world_ready"))


func _warmup_world() -> void:
	var terrain := world.terrain()
	var spawn_manager := SpawnManager.new(Config.gameplay, terrain, world.road_network())
	spawn_manager.set_seed(Config.world.seed)
	var start := spawn_manager.find_player_start(Config.gameplay.player_start_position)
	player_start_position = start["point"]
	# Заставка ждёт только маленькое кольцо вокруг машины: остальное догружается
	# в игре.  Раньше ожидание растягивалось на минуты, потому что загрузка
	# ждала чанки в радиусе трети обзора.
	var total_steps := 6
	# Условие выхода: готов чанк под машиной (и соседи в половине длины чанка).
	# Машина не должна появиться раньше земли под ней, но и ждать полный обзор на
	# заставке смысла нет - остальное догружается в игре.
	var spawn_radius := world.config.chunk_size_m * 0.5
	for step in range(total_steps):
		if world.is_ready_around(player_start_position, spawn_radius) and step >= 2:
			break
		world.warmup(player_start_position, WARMUP_CHUNKS_PER_STEP)
		menu.report_loading(float(step + 1) / float(total_steps), world.loaded_chunk_count())
		await get_tree().process_frame


## Поднимает точку появления, пока габарит машины не окажется свободен: иначе
## машина появляется внутри забора, столба или дома и застревает там навсегда.
## Проверка идёт запросом формы по слою мира; если места нет и выше, машина
## просто ставится на пару метров над дорогой - падение безопаснее застревания.
func _free_spawn_position(candidate: Vector3) -> Vector3:
	var space := get_world_3d().direct_space_state
	if space == null:
		return candidate
	var shape := BoxShape3D.new()
	shape.size = Vector3(1.9, 1.1, 4.6)
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.collision_mask = 1
	query.margin = 0.05
	var lift := 0.0
	for attempt in range(6):
		query.transform = Transform3D(Basis(), candidate + Vector3.UP * lift)
		var hits := space.intersect_shape(query, 1)
		if hits.is_empty():
			return candidate + Vector3.UP * lift
		lift += 0.8
	print("       (место появления занято, машина поднята на %.1f м)" % lift)
	return candidate + Vector3.UP * lift


func _spawn_player() -> void:
	var terrain := world.terrain()
	var spawn_manager := SpawnManager.new(Config.gameplay, terrain, world.road_network())
	spawn_manager.set_seed(Config.world.seed)
	var start := spawn_manager.find_player_start(Config.gameplay.player_start_position)
	player_start_position = start["point"]
	var tangent: Vector3 = start.get("tangent", Vector3.FORWARD)
	var yaw := atan2(tangent.x, tangent.z)
	var spawn_position := Vector3(
		player_start_position.x,
		terrain.height_at(player_start_position.x, player_start_position.z) + Config.gameplay.reset_height_offset,
		player_start_position.z
	)
	player = PlayerCar.new()
	player.name = "PlayerCar"
	player.touch_controls_path = ^"../../Controls/MobileControls"
	add_child(player)
	player.set_physics_process(true)
	player.set_input_source(touch_controls)
	spawn_position = _free_spawn_position(spawn_position)
	player.global_position = spawn_position
	player.rotation = Vector3(0.0, yaw, 0.0)
	var roads := world.road_network()
	# The controller asks the provider for the surface under a point as
	# (x, z, height); a road wins over the terrain, which is what makes asphalt
	# grippier than the field next to it in the physics.
	player.set_surface_provider(func(x: float, z: float, height: float) -> int:
		var probe := Vector3(x, height, z)
		var road_surface := roads.road_surface_at(probe) if roads != null else -1
		if road_surface >= 0:
			return road_surface
		return terrain.surface_at(x, z)
	)
	player.set_road_provider(func(position: Vector3) -> Vector3:
		if roads == null:
			return position
		var found := roads.nearest_road(position, 90.0)
		return found.get("point", position)
	)
	Game.register_player(player)

	chase_camera = ChaseCamera.new()
	chase_camera.name = "ChaseCamera"
	add_child(chase_camera)
	chase_camera.set_target(player)
	chase_camera.apply_quality(_quality)
	Game.register_camera(chase_camera)
	if chase_camera.camera() != null:
		chase_camera.camera().current = true

	police = PoliceManager.new()
	police.name = "Police"
	add_child(police)
	police.configure(player, chase_camera.camera(), roads, terrain)
	Game.register_police_manager(police)

	hud.bind(player, police, roads)
	Game.register_hud(hud)


## ------------------------------------------------------------- game actions --
func _on_start_pursuit_requested(police_count: int, ai_level: int) -> void:
	if not world_ready:
		return
	get_tree().paused = false
	Game.start_pursuit(police_count, ai_level)


func _on_free_roam_requested() -> void:
	if not world_ready:
		return
	menu.show_menu(false)
	get_tree().paused = false
	Game.begin_free_roam()


func _on_resume_requested() -> void:
	menu.show_pause(false)
	get_tree().paused = false


func _on_quit_to_free_roam() -> void:
	menu.show_pause(false)
	menu.show_menu(false)
	get_tree().paused = false
	Game.back_to_free_roam()
	if player != null and is_instance_valid(player):
		player.reset_to_road()


func _on_pause_requested() -> void:
	if not world_ready:
		return
	if menu.get_tree().paused:
		_on_resume_requested()
		return
	menu.show_pause(true)


func _on_camera_mode_requested() -> void:
	if chase_camera != null:
		chase_camera.cycle_mode()
		Game.toast.emit("Камера: %s" % chase_camera.status().get("mode", "CHASE"))


func _on_reset_requested() -> void:
	if player != null and is_instance_valid(player):
		player.reset_to_road()


func _on_hud_pursuit_requested() -> void:
	_on_start_pursuit_requested(Settings.police_count, Settings.ai_level)


func _on_quality_changed(_index: int) -> void:
	_quality = Settings.preset()
	Perf.set_quality_scale(_quality)
	if world != null:
		world.apply_quality(_quality)
	if chase_camera != null:
		chase_camera.apply_quality(_quality)
	_apply_lighting_quality()


func _apply_camera_distance() -> void:
	if chase_camera == null:
		return
	var factor: float = clampf(Settings.camera_distance_scale, 0.7, 1.6)
	chase_camera.min_distance = 5.4 * factor
	chase_camera.max_distance = 11.0 * factor
	chase_camera.distance = clampf(chase_camera.distance, chase_camera.min_distance, chase_camera.max_distance)


## Кнопка «Y» в настройках: каждое нажатие поднимает машину игрока на метр (см.
## VehicleController.lift_up).  Работает и в свободной езде, и в погоне.
func _on_lift_car_requested(meters: float) -> void:
	if player == null:
		return
	player.lift_up(meters)


func _on_paint_changed(_index: int) -> void:
	if player != null and is_instance_valid(player):
		player.paint_override = Settings.player_paint_color()
		player.rebuild_visual()


func _apply_lighting_quality() -> void:
	if sun == null:
		return
	sun.shadow_enabled = _quality.shadows_enabled
	sun.directional_shadow_max_distance = _quality.shadow_distance_m
	RenderingServer.directional_shadow_atlas_set_size(_quality.shadow_map_size, true)


## --------------------------------------------------------------- input glue --
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause"):
		_on_pause_requested()
	elif event.is_action_pressed("reset_car"):
		_on_reset_requested()
	elif event.is_action_pressed("camera_toggle"):
		_on_camera_mode_requested()
	elif event.is_action_pressed("start_chase"):
		_on_start_pursuit_requested(Settings.police_count, Settings.ai_level)
	elif event.is_action_pressed("debug_toggle"):
		hud.set_debug(not hud.show_debug)


func _process(delta: float) -> void:
	if player == null or not is_instance_valid(player):
		return
	_check_flip_recovery(delta)
	_update_world_car_lod(delta)
	if touch_controls != null:
		var camera_delta: Vector2 = touch_controls.consume_camera_drag()
		if camera_delta != Vector2.ZERO and chase_camera != null:
			var sensitivity: float = Settings.camera_sensitivity
			var invert := -1.0 if Settings.camera_invert_y else 1.0
			chase_camera.add_orbit(
				-camera_delta.x * sensitivity * 0.01,
				camera_delta.y * sensitivity * 0.01 * invert
			)


## A car that ended up on its roof cannot be driven any more: after a few
## seconds of being upside down (and with no wheel touching the ground) the game
## puts it back onto the road, exactly like the "reset car" button does.
func _update_world_car_lod(delta: float) -> void:
	_car_lod_timer_s -= delta
	if _car_lod_timer_s > 0.0:
		return
	_car_lod_timer_s = WORLD_CAR_LOD_INTERVAL_S
	for node in get_tree().get_nodes_in_group("world_cars"):
		var car := node as VehicleController
		if car == null or not is_instance_valid(car):
			continue
		var distance := car.global_position.distance_to(player.global_position)
		var lod := 0
		if distance > WORLD_CAR_LOD_FAR_M:
			lod = 2
		elif distance > WORLD_CAR_LOD_MID_M:
			lod = 1
		car.set_visual_lod(lod)


func _check_flip_recovery(delta: float) -> void:
	var upside_down := player.global_basis.y.dot(Vector3.UP) < -0.15
	if upside_down and player.grounded_wheels == 0:
		_upside_down_time_s += delta
	else:
		_upside_down_time_s = 0.0
	if _upside_down_time_s >= FLIP_RECOVERY_TIME_S:
		_upside_down_time_s = 0.0
		_recover_player()
		return
	# Страховка от проваливания: если машина оказалась ниже рельефа (например,
	# проскочила тонкую коллизию на скорости) или стоит без опоры, игра
	# возвращает её на дорогу - раньше в этом случае помогала только кнопка
	# "Вернуть машину", а в погоне игрок о ней не вспоминает.
	var ground := world.height_at(player.global_position.x, player.global_position.z) if world != null else 0.0
	var buried := player.global_position.y < ground - 1.2
	var stranded := player.grounded_wheels == 0 and absf(player.forward_speed_ms()) < 1.5
	if buried:
		_stuck_time_s = STUCK_RECOVERY_TIME_S
	else:
		_stuck_time_s = _stuck_time_s + delta if stranded else 0.0
	if _stuck_time_s >= STUCK_RECOVERY_TIME_S:
		_stuck_time_s = 0.0
		_recover_player()


func _recover_player() -> void:
	if player != null and is_instance_valid(player):
		player.call("recover_to_road")


func status() -> Dictionary:
	return {
		"world_ready": world_ready,
		"quality": _quality.title if _quality != null else "?",
		"player": player.status() if player != null and is_instance_valid(player) else {},
		"world": world.stats() if world != null else {},
		"police": police.status() if police != null else {},
		"state": Game.state,
	}
