class_name PoliceAI
extends RefCounted

## The brain of one police car.
##
## Two update rates, because planning is expensive and driving is not:
##   * `update()` runs every physics frame and only produces control inputs
##     (steering towards the current waypoint, throttle/brake for the target
##     speed, handbrake for a slide, stuck recovery),
##   * `plan()` runs every `strategic_interval_s` seconds and decides *where* to
##     go: it reads the player's velocity, heading and predicted trajectory, the
##     road graph, its own state and the state of the other police cars, and picks
##     a role target.  Route planning happens here as well.
##
## Difficulty comes only from decisions - how far ahead the AI predicts, whether
## it uses the road graph, how disciplined it is under braking, how often it makes
## a mistake.  The car itself is the same physics as the player's, and the speed
## factor is capped at the fair 1.01 police advantage by PoliceLevelParams.

const ROLE_CHASE := PoliceRole.Type.CHASE
const ROLE_INTERCEPT := PoliceRole.Type.INTERCEPT
const ROLE_BLOCK := PoliceRole.Type.BLOCK
const ROLE_PIN := PoliceRole.Type.PIN
const ROLE_SUPPORT := PoliceRole.Type.SUPPORT
const ROLE_REGROUP := PoliceRole.Type.REGROUP

var car: VehicleController = null
var config: PoliceConfig = null
var gameplay: GameplayConfig = null
var params: PoliceLevelParams = null
var network: RoadNetwork = null
var terrain: TerrainField = null
var planner: RoutePlanner = null

var index: int = 0
var role: int = PoliceRole.Type.CHASE
var role_target: Vector3 = Vector3.ZERO
var has_target: bool = false

## Read by the manager/HUD.
var distance_to_player: float = 0.0
var last_seen_position: Vector3 = Vector3.ZERO
var last_seen_time_s: float = -1000.0
var visible: bool = false
var stuck_timer_s: float = 0.0
var reversing_until_s: float = 0.0
var mistake_timer_s: float = 0.0
var reaction_delay_timer_s: float = 0.0
var stuck_recoveries: int = 0
var collisions_with_police: int = 0
var plan_count: int = 0
var target_speed_ms: float = 0.0
var throttle_output: float = 0.0
var steer_output: float = 0.0
var brake_output: float = 0.0
var handbrake_output: float = 0.0
var blocked_by_police: bool = false
var predicted_points: PackedVector3Array = PackedVector3Array()

var _input := VehicleInput.new()
var _rng := RandomNumberGenerator.new()
var _plan_timer_s: float = 0.0
var _straight_line_timer_s: float = 0.0
var _last_position: Vector3 = Vector3.ZERO


func setup(
	police_car: VehicleController,
	police_config: PoliceConfig,
	gameplay_config: GameplayConfig,
	roads: RoadNetwork,
	world_terrain: TerrainField,
	car_index: int,
	seed_value: int
) -> void:
	car = police_car
	config = police_config
	gameplay = gameplay_config
	network = roads
	terrain = world_terrain
	index = car_index
	planner = RoutePlanner.new(roads)
	_rng.seed = seed_value
	_last_position = car.global_position if car != null else Vector3.ZERO
	last_seen_position = _last_position


func set_params(level_params: PoliceLevelParams) -> void:
	params = level_params


## ------------------------------------------------------------------ planning
## context = {
##   player_position, player_forward, player_speed_ms, player_steer, player_braking,
##   player_position_history: PackedVector3Array, player_on_road: bool,
##   police_cars: Array[VehicleController], police_roles: PackedInt32Array,
##   time_s: float, camera: Camera3D
## }
func plan(context: Dictionary, role_hint: int) -> void:
	if car == null or params == null:
		return
	plan_count += 1
	var player_position: Vector3 = context.get("player_position", Vector3.ZERO)
	var player_forward: Vector3 = context.get("player_forward", Vector3.FORWARD)
	var player_speed: float = context.get("player_speed_ms", 0.0)
	var on_road := bool(context.get("player_on_road", true))
	var time_s := float(context.get("time_s", 0.0))

	if role_hint != role:
		role = role_hint
		planner.reset()

	# --- perception: is the player in sight?
	distance_to_player = car.global_position.distance_to(player_position)
	visible = distance_to_player <= config.detection_radius_m
	if visible:
		last_seen_position = player_position
		last_seen_time_s = time_s
	elif time_s - last_seen_time_s > config.last_known_memory_s:
		# no fresh information: keep the last known spot, that's all we know
		pass

	# --- prediction (this is what separates a rookie from a veteran)
	var state := {
		"position": player_position,
		"forward": player_forward,
		"speed_ms": player_speed,
		"steer": float(context.get("player_steer", 0.0)),
		"wheelbase": Config.vehicle_player.wheelbase_m,
		"braking": bool(context.get("player_braking", false)),
	}
	predicted_points = TrajectoryPredictor.predict(state, maxf(params.prediction_horizon_s, 0.5))

	var target := _role_target(context, player_position, player_forward, player_speed, on_road, time_s)
	role_target = target
	has_target = true
	var distance_to_target := car.global_position.distance_to(target)
	var road_bias := params.road_bias
	if not on_road:
		# the player left the road: a good officer still cuts across, but a rookie
		# keeps trying to stay on the asphalt
		road_bias *= lerpf(0.35, 0.05, params.head_on_risk)
	if role == ROLE_PIN:
		road_bias = 0.0  # ramming distance: no routing, go straight at it
	if role == ROLE_BLOCK and distance_to_target < 60.0:
		road_bias = minf(road_bias, 0.4)
	var interval := params.reroute_interval_s
	var goal_moved := planner.goal.distance_to(target) > 18.0
	if planner.needs_replan(time_s, interval, target) or goal_moved or (not planner.has_route() and distance_to_target > 12.0):
		planner.plan(car.global_position, target, time_s, road_bias)


## Where should this role go?  This is the heart of the "police is smart, not
## magical" behaviour.
func _role_target(
	context: Dictionary,
	player_position: Vector3,
	player_forward: Vector3,
	player_speed: float,
	on_road: bool,
	time_s: float
) -> Vector3:
	var own_position := car.global_position
	var own_speed := maxf(car.forward_speed_ms(), 2.0)
	match role:
		ROLE_INTERCEPT:
			# drive to a point ahead of the player on its predicted path
			var interception := TrajectoryPredictor.intercept_point(predicted_points, own_position, own_speed)
			if bool(interception["reachable"]):
				return interception["point"]
			return player_position + player_forward * maxf(player_speed * 3.0, 25.0)
		ROLE_BLOCK:
			var lead := maxf(player_speed * 4.2, 40.0)
			var block_point := player_position + player_forward * lead
			if network != null:
				var road := network.nearest_road(block_point, 60.0)
				if not road.is_empty() and float(road.get("width", 10.0)) >= 9.0:
					return _ground_point(road["point"])
			return block_point
		ROLE_PIN:
			# aim at the player's rear quarter so the cars end up side by side
			var side := player_forward.cross(Vector3.UP).normalized()
			var offset_sign := 1.0 if (own_position - player_position).dot(side) >= 0.0 else -1.0
			return player_position - player_forward * 1.2 + side * offset_sign * 1.6
		ROLE_SUPPORT:
			var routes := TrajectoryPredictor.escape_routes(player_position, player_forward, network, config.intercept_radius_m, 4)
			if routes.size() > 0:
				var selected: Dictionary = routes[min(index, routes.size() - 1)]
				return selected["point"]
			return player_position + player_forward * 60.0
		ROLE_REGROUP:
			# lost the player: sweep the last known area / the road near it
			if network != null:
				var road := network.nearest_road(last_seen_position, 220.0)
				if not road.is_empty():
					return _ground_point(road["point"])
			return last_seen_position
		_:
			# CHASE: pure pursuit with a lead that depends on the level
			var lead_time := clampf(distance_to_player / 90.0, 0.15, 1.0) * maxf(params.prediction_horizon_s, 0.3)
			if not on_road:
				lead_time *= 0.6
			var chase_target := player_position + player_forward * maxf(player_speed, 4.0) * lead_time
			if params.uses_road_graph and distance_to_player < 40.0:
				# very close: aim slightly past the player so we don't just sit
				# on the bumper
				chase_target = player_position + player_forward * 6.0
			return chase_target


## ------------------------------------------------------------------ driving
func update(delta: float, context: Dictionary) -> void:
	if car == null or params == null:
		return
	var time_s := float(context.get("time_s", 0.0))
	var player_position: Vector3 = context.get("player_position", Vector3.ZERO)
	var police_cars: Array = context.get("police_cars", [])
	_plan_timer_s -= delta
	if _plan_timer_s <= 0.0:
		_plan_timer_s = params.strategic_interval_s
		plan(context, int(context.get("role", role)))
		mistake_timer_s = maxf(mistake_timer_s - params.strategic_interval_s, 0.0)
	distance_to_player = car.global_position.distance_to(player_position)

	var speed := car.forward_speed_ms()
	# --- stuck detection (slow while we want to go fast)
	var wants_to_move := planner.has_route() and has_target and _obstacle_ahead(context).is_empty()
	if wants_to_move and absf(speed) < config.stuck_speed_ms:
		stuck_timer_s += delta
	else:
		stuck_timer_s = maxf(stuck_timer_s - delta * 1.2, 0.0)

	if params.stuck_recovery and stuck_timer_s >= config.stuck_time_s and time_s > reversing_until_s:
		reversing_until_s = time_s + config.stuck_reverse_time_s
		stuck_timer_s = 0.0
		stuck_recoveries += 1
		planner.reset()

	if time_s < reversing_until_s:
		# back out of whatever we are stuck on, steering the other way
		_input.throttle = 0.0
		_input.brake = 1.0
		_input.steer = -signf(steer_output) if absf(steer_output) > 0.05 else 0.6
		_input.handbrake = 0.0
		_input.nitro = false
		_apply_input()
		return

	# --- reaction delay: a rookie keeps driving the previous plan for a moment
	if reaction_delay_timer_s > 0.0:
		reaction_delay_timer_s = maxf(reaction_delay_timer_s - delta, 0.0)
	elif _rng.randf() < params.reaction_delay_s * delta * 0.35:
		reaction_delay_timer_s = params.reaction_delay_s

	# --- mistakes: occasionally a lower level AI takes a wrong turn or twitches
	if params.mistake_chance > 0.0 and mistake_timer_s <= 0.0:
		if _rng.randf() < params.mistake_chance * delta:
			mistake_timer_s = _rng.randf_range(0.6, 2.2)
			if _rng.randf() < 0.35:
				planner.reset()

	var waypoint := role_target if not planner.has_route() else planner.lookahead_point(car.global_position, _lookahead_distance(speed))
	# off-road shortcuts for the smarter levels when the player itself is off-road
	if params.uses_road_graph and not bool(context.get("player_on_road", true)) and distance_to_player > 35.0:
		_straight_line_timer_s += delta
		if _straight_line_timer_s > 0.5:
			waypoint = player_position
	else:
		_straight_line_timer_s = 0.0

	var steer := _steering_to(waypoint, speed)
	var noise := params.steering_noise * (2.0 if mistake_timer_s > 0.0 else 1.0)
	steer = clampf(steer + _rng.randf_range(-noise, noise), -1.0, 1.0)
	if mistake_timer_s > 0.0:
		steer = clampf(steer + sin(time_s * 3.0) * noise * 0.5, -1.0, 1.0)
	steer = clampf(steer, -1.0, 1.0)
	if reaction_delay_timer_s > 0.0:
		# blend instead of snapping: an old plan applied smoothly
		steer = lerpf(steer_output, steer, 0.25)
	steer_output = steer

	# --- speed target
	var target_speed := _target_speed(context, speed)
	target_speed_ms = target_speed
	var obstacle := _obstacle_ahead(context)
	var spacing_slowdown := _spacing_slowdown(police_cars)
	blocked_by_police = spacing_slowdown < 1.0
	if blocked_by_police:
		target_speed *= spacing_slowdown
	if not obstacle.is_empty():
		var obstacle_distance := float(obstacle["distance"])
		var closing := obstacle_distance / maxf(speed, 0.5)
		if closing < 1.4:
			target_speed = minf(target_speed, float(obstacle["speed"]) * 0.8)
	# --- corners: brake before them, based on how much this level cares
	var corner := planner.next_corner(110.0)
	if not corner.is_empty() and params.corner_discipline > 0.0:
		var corner_distance := float(corner["distance"])
		var corner_angle := float(corner["angle"])
		var allowed: float = TrajectoryPredictor.corner_speed_ms(
			maxf(corner_distance, 8.0) / maxf(corner_angle, 0.2), 1.0
		)
		allowed *= lerpf(0.55, 1.05, params.corner_discipline)
		var brake_needed: bool = allowed < speed and corner_distance < speed * params.brake_lookahead_factor
		if brake_needed:
			target_speed = minf(target_speed, allowed)
	# --- a PIN car has to be able to touch the player: no conservative distance
	if role == ROLE_PIN and distance_to_player < 25.0:
		target_speed = maxf(target_speed, 8.0)
	# --- low speeds: the two role cars must not push the player away by ramming
	if role != ROLE_PIN and distance_to_player < config.min_spacing_m * 0.35 and params.head_on_risk < 0.5:
		target_speed = minf(target_speed, maxf(absf(car.forward_speed_ms()) - 2.0, 3.0))

	var error := target_speed - speed
	throttle_output = clampf(error * 0.45, 0.0, 1.0)
	brake_output = clampf(-error * 0.22, 0.0, 1.0)
	if absf(speed) < 0.6 and target_speed > 1.0 and throttle_output < 0.25:
		throttle_output = 0.35
	_input.throttle = throttle_output
	_input.brake = brake_output
	# --- handbrake for a genuine hairpin (high levels only)
	handbrake_output = 0.0
	if params.level >= 4 and not corner.is_empty():
		if float(corner["angle"]) > 1.1 and speed > 15.0 and float(corner["distance"]) < 20.0:
			handbrake_output = 0.6
	_input.handbrake = handbrake_output
	# --- nitro: never for a fair fight - police cars have no boost in the design
	_input.nitro = false
	_input.use_abs = true
	_input.use_tcs = true
	_apply_input()
	planner.update_progress(delta, car.global_position, absf(speed), maxf(target_speed, 4.0))


func _apply_input() -> void:
	if car == null:
		return
	car.input.throttle = clampf(_input.throttle, 0.0, 1.0)
	car.input.brake = clampf(_input.brake, 0.0, 1.0)
	car.input.steer = clampf(_input.steer, -1.0, 1.0)
	car.input.handbrake = clampf(_input.handbrake, 0.0, 1.0)
	car.input.nitro = false
	car.input.gear_hint = 0 if _input.brake < 0.5 else -1


## Ground height for a target point (falls back to the point itself).
func _ground_point(point: Vector3) -> Vector3:
	if terrain == null:
		return point
	return Vector3(point.x, terrain.height_at(point.x, point.z), point.z)


func _lookahead_distance(speed: float) -> float:
	# faster cars look further ahead; a low level looks too close and turns late
	var base: float = config.road_follow_lookahead_m
	return base + maxf(speed, 0.0) * lerpf(0.35, 0.75, params.corner_discipline)


func _steering_to(target: Vector3, speed: float) -> float:
	var position := car.global_position
	var forward := car.forward_direction()
	var to_target := target - position
	to_target.y = 0.0
	if to_target.length_squared() < 0.01:
		return 0.0
	var desired := to_target.normalized()
	# look further ahead when fast so the car does not oscillate
	var distance := to_target.length()
	var look := maxf(distance, 6.0)
	var angle := forward.signed_angle_to(desired, Vector3.UP)
	var steer := angle / deg_to_rad(Config.vehicle_player.max_steer_angle_deg)
	# aim less aggressively when far away (pure pursuit geometry)
	steer *= clampf(1.0 - look / 120.0, 0.35, 1.0)
	if speed < 2.0:
		steer *= 1.25
	return clampf(steer, -1.0, 1.0)


func _target_speed(context: Dictionary, speed: float) -> float:
	var base := params.max_speed_factor * Config.vehicle_player.top_speed_ms()
	var player_speed: float = context.get("player_speed_ms", 0.0)
	var player_top := Config.vehicle_player.top_speed_ms()
	# The fair rule: the police may be at most 1% faster than the player's top
	# speed, never more, and only on the road with a good level.
	var fair_cap := player_top * config.max_speed_factor_vs_player
	base = minf(base, fair_cap)
	# do not drive into the back of the player: keep a little spacing unless the
	# role is explicitly a PIN (level 4)
	if role != ROLE_PIN and distance_to_player < config.min_spacing_m:
		var spacing := lerpf(0.82, 1.0, clampf(distance_to_player / config.min_spacing_m, 0.0, 1.0))
		base = minf(base, maxf(absf(player_speed) * spacing, 4.0))
	# a blocking or supporting car does not need to run at top speed
	if role == ROLE_BLOCK or role == ROLE_SUPPORT:
		base = minf(base, 22.0)
	if role == ROLE_REGROUP:
		base = minf(base, base * 0.9)
	# off the road this car slows down by its own level's factor; the physics is
	# still the normal one, the AI simply does not ask for more
	if not bool(context.get("player_on_road", true)):
		base *= clampf(params.offroad_speed_factor, 0.3, 1.0)
	# never exceed the car's real top speed: no invisible engine
	var real_top := VehicleController.estimate_top_speed_ms(car.config)
	base = minf(base, real_top * 0.995)
	return maxf(base, 3.0)


## The car right in front of us (police or player) - used for spacing and to stop
## the police from constantly rear-ending each other.
func _obstacle_ahead(context: Dictionary) -> Dictionary:
	var police_cars: Array = context.get("police_cars", [])
	var position := car.global_position
	var forward := car.forward_direction()
	var best: Dictionary = {}
	var best_distance := config.avoidance_lookahead_m
	for entry in police_cars:
		if entry == car or not (entry is VehicleController):
			continue
		var other := entry as VehicleController
		var to_other := other.global_position - position
		to_other.y = 0.0
		var distance := to_other.length()
		if distance < 0.5 or distance > best_distance:
			continue
		if to_other.normalized().dot(forward) < 0.7:
			continue
		best = {"distance": distance, "speed": maxf(other.forward_speed_ms(), 0.0), "car": other}
		best_distance = distance
	# the player can also be "in the way" (beyond the role distance)
	var player_position: Vector3 = context.get("player_position", Vector3.ZERO)
	var to_player := player_position - position
	to_player.y = 0.0
	var player_distance := to_player.length()
	if player_distance > 0.5 and player_distance < best_distance and role == ROLE_CHASE:
		if to_player.normalized().dot(forward) > 0.75 and player_distance < config.min_spacing_m * 0.6:
			best = {"distance": player_distance, "speed": absf(float(context.get("player_speed_ms", 0.0))), "car": context.get("player", null)}
	return best


## Slow down when another police car is right in front of us (convoy spacing).
func _spacing_slowdown(police_cars: Array) -> float:
	var position := car.global_position
	var forward := car.forward_direction()
	var closest := INF
	for entry in police_cars:
		if entry == car or not (entry is VehicleController):
			continue
		var other := entry as VehicleController
		var to_other := other.global_position - position
		to_other.y = 0.0
		var distance := to_other.length()
		if distance > config.min_spacing_m:
			continue
		if to_other.normalized().dot(forward) < 0.5:
			continue
		closest = minf(closest, distance)
	if closest > config.min_spacing_m:
		return 1.0
	var factor := clampf(closest / config.min_spacing_m, 0.35, 1.0)
	return lerpf(factor, 1.0, 1.0 - config.friendly_collision_slowdown)


func status() -> Dictionary:
	return {
		"index": index,
		"role": PoliceRole.name_of(role),
		"target": role_target,
		"distance": snappedf(distance_to_player, 0.1),
		"target_speed": snappedf(target_speed_ms * 3.6, 0.1),
		"stuck_s": snappedf(stuck_timer_s, 0.1),
		"recoveries": stuck_recoveries,
		"plans": plan_count,
		"mistake": mistake_timer_s > 0.0,
		"planner": planner.status() if planner != null else {},
		"inputs": _input.to_dictionary(),
	}
