class_name RoutePlanner
extends RefCounted

## Plans routes for police cars on the RoadNetwork and follows them.
##
## The planner is the piece that makes a *smart* pursuit possible without
## cheating: instead of driving at the player in a straight line (which would
## mean ploughing through buildings), the AI plans a route over the road graph,
## then drives the route with pure-pursuit steering.  When the player leaves the
## roads the planner switches to a blended route (road + straight line), and when
## the route is missing entirely it degrades gracefully to a direct line.
##
## Everything here is free of a scene tree, so routing behaviour is unit tested.

const NODE_SPACING := 24.0
const MAX_PLAN_PER_FRAME := 2

var network: RoadNetwork
var waypoints: PackedVector3Array = PackedVector3Array()
var route: PackedInt32Array = PackedInt32Array()
var goal: Vector3 = Vector3.ZERO
var last_plan_time_s: float = -1000.0
var plan_count: int = 0
var failed_plans: int = 0
var using_road_graph: bool = false
var path_length_m: float = 0.0

var stall_timer_s: float = 0.0

var _index: int = 0
var _planned_interval_s: float = 1.0


func _init(roads: RoadNetwork) -> void:
	network = roads


func has_route() -> bool:
	return waypoints.size() >= 2


## Replans at most every `interval_s` seconds and only when the goal moved.
func needs_replan(current_time_s: float, interval_s: float, new_goal: Vector3, goal_tolerance_m: float = 18.0) -> bool:
	_planned_interval_s = interval_s
	if not has_route():
		return true
	if goal.distance_to(new_goal) > goal_tolerance_m:
		return true
	return current_time_s - last_plan_time_s >= interval_s


## road_bias 1.0 = stay on the road graph, 0.0 = straight line to the goal.
func plan(from: Vector3, to: Vector3, current_time_s: float, road_bias: float = 1.0) -> void:
	goal = to
	last_plan_time_s = current_time_s
	plan_count += 1
	waypoints = PackedVector3Array()
	route = PackedInt32Array()
	using_road_graph = false
	if network != null and road_bias > 0.05:
		var planned := network.plan_route(from, to, 900)
		if planned.size() >= 2:
			var points := network.route_points(planned, from, to)
			if points.size() >= 2:
				waypoints = _resample(points, NODE_SPACING)
				route = PackedInt32Array(planned)
				using_road_graph = true
	if waypoints.size() < 2:
		failed_plans += 1
		# no route: drive straight at the goal (this is what a police car does
		# when the player cuts across a field)
		waypoints = PackedVector3Array([from, to])
		using_road_graph = false
	path_length_m = MathUtils.polyline_length(waypoints)
	# blend towards the straight line when the AI is allowed off-road
	if using_road_graph and road_bias < 0.999:
		var blended := PackedVector3Array()
		var total := waypoints.size()
		for i in range(total):
			var t := float(i) / float(maxi(total - 1, 1))
			var straight := from.lerp(to, t)
			blended.append(waypoints[i].lerp(straight, 1.0 - clampf(road_bias, 0.0, 1.0)))
		waypoints = blended
	_index = _nearest_index(from)


func _resample(points: PackedVector3Array, spacing: float) -> PackedVector3Array:
	var result := PackedVector3Array()
	var travelled := 0.0
	result.append(points[0])
	for i in range(1, points.size()):
		travelled += points[i - 1].distance_to(points[i])
		if travelled >= spacing or i == points.size() - 1:
			result.append(points[i])
			travelled = 0.0
	if result.size() < 2:
		return points
	return result


func _nearest_index(position: Vector3) -> int:
	var best := 0
	var best_distance := INF
	for i in range(waypoints.size()):
		var distance := waypoints[i].distance_to(position)
		if distance < best_distance:
			best_distance = distance
			best = i
	return best


## Pure pursuit: the point `lookahead_m` further along the route.
func next_waypoint(position: Vector3, lookahead_m: float = 18.0) -> Vector3:
	if waypoints.is_empty():
		return goal
	# advance the index while the waypoint is already behind us
	while _index < waypoints.size() - 1 and waypoints[_index].distance_to(position) < lookahead_m * 0.6:
		_index += 1
	var target := waypoints[_index]
	var travelled := 0.0
	for i in range(_index, waypoints.size() - 1):
		travelled += waypoints[i].distance_to(waypoints[i + 1])
		if travelled >= lookahead_m:
			return waypoints[i + 1]
		target = waypoints[i + 1]
	return target


## Remaining distance along the route (for the "am I making progress" checks).
func remaining_distance(position: Vector3) -> float:
	if waypoints.is_empty():
		return position.distance_to(goal)
	return position.distance_to(waypoints[_index]) + MathUtils.polyline_length(_tail())


func _tail() -> PackedVector3Array:
	var tail := PackedVector3Array()
	for i in range(_index, waypoints.size()):
		tail.append(waypoints[i])
	return tail


## Curvature-based speed limit for the next `lookahead_m` metres of the route:
## the AI brakes before a bend instead of understeering into it.
func corner_speed_limit(lookahead_m: float, aggressive: float = 1.0) -> float:
	if waypoints.size() < 3:
		return INF
	var travelled := 0.0
	var tightest := INF
	for i in range(_index, waypoints.size() - 1):
		var segment := waypoints[i].distance_to(waypoints[i + 1])
		travelled += segment
		if travelled > lookahead_m:
			break
		if i == 0 or i + 1 >= waypoints.size():
			continue
		var a := waypoints[i] - waypoints[i - 1]
		var b := waypoints[i + 1] - waypoints[i]
		a.y = 0.0
		b.y = 0.0
		if a.length() < 0.5 or b.length() < 0.5:
			continue
		var angle := absf(a.normalized().signed_angle_to(b.normalized(), Vector3.UP))
		if angle < 0.12:
			continue
		# radius from the deflection angle over the segment length
		var radius := maxf(segment / maxf(angle, 0.05), 6.0)
		var limit := sqrt(radius * 9.81 * 1.0) * aggressive
		tightest = minf(tightest, limit)
	return tightest


## Alias kept for readability at the call sites in PoliceAI.
func lookahead_point(position: Vector3, lookahead_m: float = 18.0) -> Vector3:
	return next_waypoint(position, lookahead_m)


## The first real corner within `max_lookahead_m`: {} when the road runs straight.
func next_corner(max_lookahead_m: float = 90.0) -> Dictionary:
	if waypoints.size() < 3:
		return {}
	var travelled := 0.0
	for i in range(maxi(_index, 1), waypoints.size() - 1):
		var segment := waypoints[i].distance_to(waypoints[i + 1])
		travelled += segment
		if travelled > max_lookahead_m:
			break
		var a := waypoints[i] - waypoints[i - 1]
		var b := waypoints[i + 1] - waypoints[i]
		a.y = 0.0
		b.y = 0.0
		if a.length() < 0.5 or b.length() < 0.5:
			continue
		var angle := absf(a.normalized().signed_angle_to(b.normalized(), Vector3.UP))
		if angle > 0.35:
			return {"point": waypoints[i + 1], "distance": travelled, "angle": angle}
	return {}


## Progress watchdog: how long the car has been slower than expected.
func update_progress(delta: float, _position: Vector3, speed_ms: float, expected_speed_ms: float) -> void:
	if speed_ms < maxf(expected_speed_ms * 0.3, 1.5):
		stall_timer_s += delta
	else:
		stall_timer_s = maxf(stall_timer_s - delta * 1.5, 0.0)


func is_stalled(threshold_s: float) -> bool:
	return stall_timer_s >= threshold_s


func reset() -> void:
	waypoints = PackedVector3Array()
	route = PackedInt32Array()
	_index = 0
	using_road_graph = false
	path_length_m = 0.0
	stall_timer_s = 0.0


func status() -> Dictionary:
	return {
		"waypoints": waypoints.size(),
		"index": _index,
		"road_graph": using_road_graph,
		"plans": plan_count,
		"failed": failed_plans,
		"length_m": snappedf(path_length_m, 1.0),
	}
