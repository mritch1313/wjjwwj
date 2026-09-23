class_name TrajectoryPredictor
extends RefCounted

## Pure prediction maths used by the police AI.
##
## The predictor takes the player's state and extrapolates where the car *will*
## be, so that an interceptor can drive to a point ahead of the player instead of
## following its tail lights.  Everything here is a static function without a
## scene tree, which is what makes the AI testable head-lessly.

const STEP := 0.2
## Default maximum steering angle of the front wheels (the player's car).
const DEFAULT_MAX_STEER_RAD := 0.5934  # 34 degrees
## Fallback lateral acceleration of the tyres (m/s^2) when the caller does not
## pass the surface it is driving on.
const DEFAULT_LATERAL_ACCEL_MS2 := 9.6


## state = {position: Vector3, forward: Vector3, speed_ms: float, steer: float,
##          wheelbase: float, braking: bool}
##   * `steer` is the *normalised* steering input (-1..1), the same value the
##     player's own controller uses, so no conversion happens at the call site,
##   * optional keys: `max_steer_rad`, `grip` (surface grip relative to asphalt).
## Returns the predicted positions, `horizon_s` seconds ahead, every STEP seconds.
##
## The model is a bicycle model limited by the tyres: the yaw rate can never ask
## for more lateral acceleration than the surface can deliver, which is why a car
## at 160 km/h cannot follow a 10 m radius corner - the prediction shows the same
## understeer the physics does instead of pretending to be on rails.
static func predict(state: Dictionary, horizon_s: float) -> PackedVector3Array:
	var points := PackedVector3Array()
	var position: Vector3 = state.get("position", Vector3.ZERO)
	var forward: Vector3 = state.get("forward", Vector3.FORWARD)
	var speed: float = state.get("speed_ms", 0.0)
	var steer: float = clampf(state.get("steer", 0.0), -1.0, 1.0)
	var max_steer_rad: float = maxf(state.get("max_steer_rad", DEFAULT_MAX_STEER_RAD), 0.05)
	var wheelbase: float = maxf(state.get("wheelbase", 2.7), 0.5)
	var braking: bool = state.get("braking", false)
	var grip: float = maxf(state.get("grip", 1.0), 0.05)
	var lateral_accel := DEFAULT_LATERAL_ACCEL_MS2 * grip
	var steer_angle := steer * max_steer_rad
	var yaw := atan2(forward.x, forward.z)
	var steps := maxi(int(ceil(horizon_s / STEP)), 1)
	for i in range(steps):
		var yaw_rate := 0.0
		if absf(speed) > 0.5:
			# what the steering geometry asks for
			yaw_rate = speed / wheelbase * tan(steer_angle)
			# what the tyres can actually deliver at this speed
			var limit := lateral_accel / maxf(absf(speed), 0.5)
			yaw_rate = clampf(yaw_rate, -limit, limit)
		yaw += yaw_rate * STEP
		var direction := Vector3(sin(yaw), 0.0, cos(yaw))
		if braking:
			speed = maxf(speed - 6.5 * STEP, 0.0)
		position += direction * speed * STEP
		points.append(position)
	return points


## First predicted point the police car can actually reach in time, plus the
## time it needs.  When nothing is reachable the function returns the farthest
## predicted point with `reachable = false` - the AI then holds the chase
## instead of pretending to intercept.
static func intercept_point(
	predictions: PackedVector3Array,
	cop_position: Vector3,
	cop_speed_ms: float,
	start_index: int = 1
) -> Dictionary:
	if predictions.is_empty():
		return {"point": cop_position, "reachable": false, "time_s": 0.0, "index": -1}
	var best := -1
	var best_time := INF
	for index in range(maxi(start_index, 0), predictions.size()):
		var point: Vector3 = predictions[index]
		var distance := Vector2(point.x - cop_position.x, point.z - cop_position.z).length()
		var time_needed := distance / maxf(cop_speed_ms, 3.0)
		var player_time := float(index + 1) * STEP
		if time_needed < player_time and player_time < best_time:
			best_time = player_time
			best = index
	if best >= 0:
		var chosen: Vector3 = predictions[best]
		var chosen_distance := Vector2(chosen.x - cop_position.x, chosen.z - cop_position.z).length()
		return {
			"point": chosen,
			"reachable": true,
			"time_s": chosen_distance / maxf(cop_speed_ms, 3.0),
			"index": best,
		}
	return {
		"point": predictions[predictions.size() - 1],
		"reachable": false,
		"time_s": float(predictions.size()) * STEP,
		"index": predictions.size() - 1,
	}


## The player's own speed after `horizon_s`, taking braking into account.
static func predicted_speed(state: Dictionary, horizon_s: float) -> float:
	var speed: float = state.get("speed_ms", 0.0)
	if bool(state.get("braking", false)):
		return maxf(speed - 6.5 * horizon_s, 0.0)
	return speed


## Where can the player escape to?  Returns up to `max_routes` road points that
## leave the current position roughly along the player's heading, ordered by how
## useful they are for a police car that wants to cut the player off.
static func escape_routes(
	player_position: Vector3,
	player_forward: Vector3,
	network: RoadNetwork,
	search_radius: float = 420.0,
	max_routes: int = 4
) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	if network == null:
		return result
	var ids := network.segments_in_area(player_position, search_radius)
	var heading := Vector2(player_forward.x, player_forward.z).normalized()
	var candidates: Array[Dictionary] = []
	for id in ids:
		var segment: RoadNetwork.Segment = network.segments[id]
		if segment.points.size() < 2:
			continue
		# both ends of the segment are potential escape directions
		for at_end in [true, false]:
			var node := network.other_end_of(id, at_end)
			var to_node := Vector2(node.x - player_position.x, node.z - player_position.z)
			var distance := to_node.length()
			if distance < 60.0 or distance > search_radius:
				continue
			var direction := to_node / maxf(distance, 0.001)
			# prefer segments the player is heading towards and fast roads
			var alignment := direction.dot(heading)
			if alignment < -0.2:
				continue
			var score := alignment * 2.0 + segment.speed_limit_kmh / 120.0 + segment.width / 40.0
			score -= distance / search_radius * 0.5
			candidates.append({
				"point": node,
				"segment": id,
				"distance": distance,
				"score": score,
			})
	candidates.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return float(a["score"]) > float(b["score"]))
	for i in range(mini(max_routes, candidates.size())):
		result.append(candidates[i])
	return result


## Maximum speed that still lets a car follow a corner of `radius_m` without
## sliding: v = sqrt(a_lat * r), with a_lat taken from the asphalt friction.
## The AI uses it only to pick a braking point - the actual limit stays in the
## tyre model, so this can never make a police car grip better than the player.
static func corner_speed_ms(radius_m: float, grip_factor: float = 1.0) -> float:
	var radius := maxf(radius_m, 1.0)
	var lateral_accel := 9.81 * Surface.default_friction(Surface.Type.ASPHALT) * maxf(grip_factor, 0.05)
	return sqrt(lateral_accel * radius)


## Distance needed to slow from `speed_ms` to zero with a given deceleration.
static func braking_distance_m(speed_ms: float, decel_ms2: float = 7.0) -> float:
	var decel := maxf(decel_ms2, 1.0)
	return speed_ms * speed_ms / (2.0 * decel)


## Time needed to stop from `speed_ms` (kept for the AI and for the tests).
static func time_to_stop(speed_ms: float, decel_ms2: float = 7.0) -> float:
	return maxf(speed_ms, 0.0) / maxf(decel_ms2, 1.0)
