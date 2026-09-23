class_name PoliceManager
extends Node3D

## Owns every police car of the pursuit: spawning, role assignment, the two AI
## update rates, the arrest evaluation and the despawn.
##
## Role assignment is central (not per car) because the roles only make sense as a
## group: exactly one interceptor, one blocker, one support car, the rest chase.
## The assignment is re-evaluated every `strategic_interval_s` and takes the
## geometry of the situation into account (who is closest, who can reach the
## player's predicted position first, which escape routes are open).
##
## Nothing here teleports a car: new police cars are *spawned* at validated
## points, cars that fall behind drive to the player like everybody else.

signal police_spawned(index: int, position: Vector3)
signal role_assigned(index: int, role: int)
signal arrest_progress(progress: float, reason: String)
signal player_caught()
signal player_escaped(seconds_hidden: float)

const POLICE_SEED_SALT := 9176
## Границы уровней детализации полицейских машин по расстоянию до игрока:
## ближе 120 м - полная модель, дальше 260 м - силуэт.
const LOD_MID_DISTANCE_M := 45.0
const LOD_FAR_DISTANCE_M := 110.0
const LOD_CHECK_INTERVAL_S := 0.4

var pursuit_active: bool = false
var ai_level: int = 2
var requested_count: int = 3
var current_count: int = 0

var cars: Array[VehicleController] = []
var brains: Array[PoliceAI] = []
var roles: PackedInt32Array = PackedInt32Array()

var arrest_system: ArrestSystem = null
var spawn_manager: SpawnManager = null

var player: VehicleController = null
var camera: Camera3D = null
var network: RoadNetwork = null
var terrain: TerrainField = null

var elapsed_s: float = 0.0
var hidden_time_s: float = 0.0
var escape_announced: bool = false
var last_spawn_time_s: float = -100.0
var last_spawn_status: Dictionary = {}
var total_arrests: int = 0
var total_escapes: int = 0
var spawn_failures: int = 0

var _lod_timer_s: float = 0.0
var _role_timer_s: float = 0.0
var _ai_accumulator: float = 0.0
var _rng := RandomNumberGenerator.new()
var _player_history: PackedVector3Array = PackedVector3Array()
var _history_timer: float = 0.0
var _player_was_on_road: bool = true


func _ready() -> void:
	_rng.seed = 4711


func configure(
	player_car: VehicleController,
	chase_camera: Camera3D,
	roads: RoadNetwork,
	world_terrain: TerrainField
) -> void:
	player = player_car
	camera = chase_camera
	network = roads
	terrain = world_terrain
	arrest_system = ArrestSystem.new(Config.gameplay)
	spawn_manager = SpawnManager.new(Config.gameplay, terrain, network)
	spawn_manager.set_seed(Config.world.seed + POLICE_SEED_SALT)


## ------------------------------------------------------------------ pursuit --
func start_pursuit(count: int, level: int) -> void:
	clear_police()
	ai_level = clampi(level, 1, Config.police.level_count())
	requested_count = clampi(count, Config.gameplay.min_police_count, Config.gameplay.max_police_count)
	pursuit_active = true
	elapsed_s = 0.0
	hidden_time_s = 0.0
	escape_announced = false
	_player_history = PackedVector3Array()
	if arrest_system != null:
		arrest_system.reset()
	# the first wave spawns immediately, later ones are staggered by the manager
	var initial := mini(requested_count, 2)
	for i in range(initial):
		_spawn_one()


func stop_pursuit() -> void:
	pursuit_active = false


func clear_police() -> void:
	for car in cars:
		if is_instance_valid(car):
			car.queue_free()
	cars.clear()
	brains.clear()
	roles = PackedInt32Array()
	current_count = 0
	pursuit_active = false


func set_ai_level(level: int) -> void:
	ai_level = clampi(level, 1, Config.police.level_count())
	for brain in brains:
		brain.set_params(Config.police.params_for_level(ai_level))


func set_police_count(count: int) -> void:
	requested_count = clampi(count, Config.gameplay.min_police_count, Config.gameplay.max_police_count)


func active_count() -> int:
	return cars.size()


func is_arrested() -> bool:
	return arrest_system != null and arrest_system.is_arrested


## ------------------------------------------------------------------- update --
func _physics_process(delta: float) -> void:
	if not pursuit_active or player == null or not is_instance_valid(player):
		return
	elapsed_s += delta
	_update_player_history(delta)
	_escalate()
	var context := _build_context()
	# --- driving update: every physics frame, cheap
	for i in range(cars.size()):
		var car := cars[i]
		var brain := brains[i]
		if not is_instance_valid(car) or brain == null:
			continue
		context["role"] = roles[i] if i < roles.size() else PoliceRole.Type.CHASE
		brain.update(delta, context)
	_update_visual_lod()
	_assign_roles_if_due(delta, context)
	_update_arrest(delta)
	_update_escape(delta)


## Какая детальность внешнего вида положена машине на таком расстоянии от
## игрока.  Вынесено отдельной функцией, чтобы правило проверялось тестом.
static func visual_lod_for_distance(distance_m: float) -> int:
	if distance_m > LOD_FAR_DISTANCE_M:
		return 2
	if distance_m > LOD_MID_DISTANCE_M:
		return 1
	return 0


## LOD внешнего вида полицейских машин по расстоянию до игрока.  Проверяется не
## каждый кадр (пересборка меша - дорогая операция), а по таймеру: за полсекунды
## дистанция меняется незначительно, зато лишних перестроений меша нет.
func _update_visual_lod() -> void:
	_lod_timer_s -= get_physics_process_delta_time()
	if _lod_timer_s > 0.0:
		return
	_lod_timer_s = LOD_CHECK_INTERVAL_S
	if player == null or not is_instance_valid(player):
		return
	for car in cars:
		if not is_instance_valid(car):
			continue
		var distance := car.global_position.distance_to(player.global_position)
		car.set_visual_lod(visual_lod_for_distance(distance))


## The pursuit grows: police cars keep arriving while the player is on the run,
## up to `escalate_max_count`, which is what makes a long chase feel escalating
## instead of static.
func _escalate() -> void:
	if cars.size() >= requested_count:
		return
	var next_at := last_spawn_time_s + Config.gameplay.respawn_delay_s
	if elapsed_s < next_at:
		return
	if cars.size() >= Config.gameplay.escalate_max_count:
		return
	_spawn_one()


func _update_player_history(delta: float) -> void:
	_history_timer -= delta
	if _history_timer > 0.0:
		return
	_history_timer = 0.35
	_player_history.append(player.global_position)
	while _player_history.size() > 16:
		_player_history.remove_at(0)


func _build_context() -> Dictionary:
	var on_road := true
	if network != null:
		var road := network.nearest_road(player.global_position, 40.0)
		on_road = not road.is_empty() and float(road.get("distance", 999.0)) <= float(road.get("width", 10.0)) * 0.5 + 4.0
	_player_was_on_road = on_road
	return {
		"player": player,
		"player_position": player.global_position,
		"player_forward": player.forward_direction(),
		"player_speed_ms": player.forward_speed_ms(),
		"player_steer": player.steer_angle / maxf(deg_to_rad(player.config.max_steer_angle_deg), 0.001),
		"player_braking": player.is_braking(),
		"player_on_road": on_road,
		"player_position_history": _player_history,
		"police_cars": cars,
		"police_roles": roles,
		"time_s": elapsed_s,
		"camera": camera,
		"role": roles[0] if roles.size() > 0 else PoliceRole.Type.CHASE,
	}


## ------------------------------------------------------------ role assignment
func _assign_roles_if_due(delta: float, context: Dictionary) -> void:
	_role_timer_s -= delta
	if _role_timer_s > 0.0:
		return
	_role_timer_s = maxf(Config.police.params_for_level(ai_level).strategic_interval_s, 0.5)
	var count := cars.size()
	if count == 0:
		return
	if roles.size() != count:
		roles.resize(count)
	var player_position: Vector3 = context["player_position"]
	var player_forward: Vector3 = context["player_forward"]
	var player_speed: float = context["player_speed_ms"]
	var params := Config.police.params_for_level(ai_level)

	# --- who is closest, who is behind, who is on a completely different road
	var order: Array[int] = []
	for i in range(count):
		if is_instance_valid(cars[i]):
			order.append(i)
	order.sort_custom(func(a: int, b: int) -> bool:
		return cars[a].global_position.distance_to(player_position) < cars[b].global_position.distance_to(player_position)
	)

	# --- the player is boxed in: everyone pins, otherwise nobody does
	var police_near := 0
	for i in order:
		if cars[i].global_position.distance_to(player_position) <= Config.gameplay.arrest_radius_m * 2.2:
			police_near += 1
	var pinning := params.can_role(PoliceRole.Type.PIN) \
		and absf(player_speed) < Config.gameplay.stopped_speed_ms * 2.5 \
		and police_near >= Config.gameplay.arrest_min_police_near
	var chasing_roles: Array[int] = []
	if pinning:
		for i in order:
			chasing_roles.append(PoliceRole.Type.PIN)
	else:
		# the closest car chases, the next one tries to cut the player off
		chasing_roles.append(PoliceRole.Type.CHASE)
		if order.size() > 1:
			chasing_roles.append(PoliceRole.Type.INTERCEPT if params.can_role(PoliceRole.Type.INTERCEPT) else PoliceRole.Type.CHASE)
		if order.size() > 2:
			chasing_roles.append(PoliceRole.Type.BLOCK if params.can_role(PoliceRole.Type.BLOCK) else PoliceRole.Type.CHASE)
		if order.size() > 3:
			chasing_roles.append(PoliceRole.Type.SUPPORT if params.can_role(PoliceRole.Type.SUPPORT) else PoliceRole.Type.CHASE)
	for i in range(order.size()):
		var index: int = order[i]
		var role: int = chasing_roles[i] if i < chasing_roles.size() else PoliceRole.Type.CHASE
		# a car that cannot see the player for a while searches the last known area
		if brains[index] != null and elapsed_s - brains[index].last_seen_time_s > Config.police.lose_sight_time_s:
			if role == PoliceRole.Type.CHASE or role == PoliceRole.Type.INTERCEPT:
				role = PoliceRole.Type.REGROUP
		if roles[index] != role:
			roles[index] = role
			role_assigned.emit(index, role)
		brains[index].set_params(params)
		brains[index].role = role


## ------------------------------------------------------------------- spawning
func _spawn_one() -> bool:
	if spawn_manager == null or player == null or cars.size() >= Config.gameplay.escalate_max_count:
		return false
	var occupied: Array = []
	for car in cars:
		if is_instance_valid(car):
			occupied.append(car)
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	var spawn := spawn_manager.find_spawn_position(
		player.global_position, player.forward_direction(), camera, occupied, space
	)
	last_spawn_status = spawn_manager.stats()
	if spawn.is_empty():
		spawn_failures += 1
		last_spawn_time_s = elapsed_s
		return false
	var position: Vector3 = spawn["point"]
	var tangent: Vector3 = spawn.get("tangent", Vector3.FORWARD)
	var yaw := atan2(tangent.x, tangent.z)
	var car := PoliceCarFactory.create(position, yaw, cars.size(), ai_level)
	car.set_surface_provider(func(x: float, z: float, _h: float) -> int:
		if network != null:
			var surface := network.road_surface_at(Vector3(x, 0.0, z))
			if surface >= 0:
				return surface
		return terrain.surface_at(x, z) if terrain != null else Surface.Type.ASPHALT
	)
	car.set_road_provider(func(point: Vector3) -> Vector3:
		if network == null:
			return point
		var road := network.nearest_road(point, 120.0)
		return road.get("point", point)
	)
	add_child(car)
	var brain := PoliceAI.new()
	brain.setup(car, Config.police, Config.gameplay, network, terrain, cars.size(), Config.world.seed + cars.size() * 7919 + int(elapsed_s))
	brain.set_params(Config.police.params_for_level(ai_level))
	cars.append(car)
	brains.append(brain)
	roles.append(PoliceRole.Type.CHASE)
	current_count = cars.size()
	last_spawn_time_s = elapsed_s
	police_spawned.emit(cars.size() - 1, position)
	return true


## -------------------------------------------------------------------- arrest
func _update_arrest(delta: float) -> void:
	if arrest_system == null or is_arrested():
		return
	var space := get_world_3d().direct_space_state if is_inside_tree() else null
	var blocked := 0.0
	if space != null:
		var exclude: Array = [player.get_rid()]
		for car in cars:
			if is_instance_valid(car):
				exclude.append(car.get_rid())
		blocked = arrest_system.blocked_ratio(space, player.global_position, exclude, delta)
	var caught := arrest_system.update(
		delta,
		player.global_position,
		player.forward_speed_ms(),
		player.grounded_wheels,
		cars,
		blocked
	)
	arrest_progress.emit(arrest_system.progress(), arrest_system.last_reason)
	if caught:
		total_arrests += 1
		pursuit_active = false
		player_caught.emit()


## -------------------------------------------------------------------- escape
func _update_escape(delta: float) -> void:
	if is_arrested():
		return
	var closest := INF
	for car in cars:
		if is_instance_valid(car):
			closest = minf(closest, car.global_position.distance_to(player.global_position))
	if closest > Config.gameplay.escape_distance_m:
		hidden_time_s += delta
	else:
		hidden_time_s = maxf(hidden_time_s - delta * 0.5, 0.0)
	var ratio := clampf(hidden_time_s / maxf(Config.gameplay.escape_time_s, 0.001), 0.0, 1.0)
	if ratio >= 1.0 and not escape_announced:
		escape_announced = true
		total_escapes += 1
		pursuit_active = false
		player_escaped.emit(hidden_time_s)


## --------------------------------------------------------------------- status
func status() -> Dictionary:
	var role_names: PackedStringArray = PackedStringArray()
	for role in roles:
		role_names.append(PoliceRole.name_of(role))
	var closest := INF
	var closest_index := -1
	for i in range(cars.size()):
		if not is_instance_valid(cars[i]):
			continue
		var distance := cars[i].global_position.distance_to(player.global_position) if player != null else 0.0
		if distance < closest:
			closest = distance
			closest_index = i
	return {
		"active": pursuit_active,
		"level": ai_level,
		"cars": cars.size(),
		"requested": requested_count,
		"max_cars": Config.gameplay.escalate_max_count,
		"closest_distance": 0.0 if closest == INF else closest,
		"closest_index": closest_index,
		"roles": role_names,
		"hidden_time_s": hidden_time_s,
		"elapsed_s": elapsed_s,
		"spawn_failures": spawn_failures,
		"last_spawn": last_spawn_status,
		"arrest": arrest_system.status() if arrest_system != null else {},
	}


func debug_rows() -> Array:
	var rows: Array = []
	for i in range(cars.size()):
		if not is_instance_valid(cars[i]) or brains[i] == null:
			continue
		var row := brains[i].status()
		row["speed_kmh"] = cars[i].speed_kmh()
		row["position"] = cars[i].global_position
		rows.append(row)
	return rows
