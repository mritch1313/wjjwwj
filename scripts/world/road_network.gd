class_name RoadNetwork
extends RefCounted

## Higher level road graph used by everything that needs to know about roads:
## road geometry, AI route planning, police spawning and the minimap.
##
## Structure
##   * Segment - a polyline with a type (street / avenue / highway / ramp /
##     rural / dirt / bridge), a width, a surface and an optional deck height
##     (flyovers of an interchange).
##   * Node - a junction.  Segments that share a node are neighbours, which is
##     what A* walks over when planning an intercept route.
##   * Spatial hash - cell (64 m) -> segment ids, so "which road is next to the
##     player" costs a handful of distance tests instead of scanning thousands.
##
## The graph stores the *road surface* height (y), sampled from the base terrain
## before flattening; TerrainField then flattens the terrain towards it.

enum RoadType { STREET, AVENUE, HIGHWAY, RAMP, RURAL, DIRT, BRIDGE, SERVICE }

const TYPE_NAMES := {
	RoadType.STREET: "street",
	RoadType.AVENUE: "avenue",
	RoadType.HIGHWAY: "highway",
	RoadType.RAMP: "ramp",
	RoadType.RURAL: "rural",
	RoadType.DIRT: "dirt",
	RoadType.BRIDGE: "bridge",
	RoadType.SERVICE: "service",
}

## Размер ячейки пространственного хеша дорог.  32 м выбран как компромисс:
## запрос высоты рельефа ищет дорогу в радиусе 24 м и потому просматривает
## 3x3 ячейки (96 м) вместо прежних 192 м - в центре города это в разы меньше
## сегментов-кандидатов, а сам хеш остаётся компактным.
const INDEX_CELL := 32.0


## Maximum distance between two consecutive points of a planned route.  The AI
## steers along these points, so a long straight road must not hide a 700 m jump.
const MAX_ROUTE_POINT_SPACING_M := 45.0

class Segment:
	extends RefCounted
	var id: int = -1
	var points: PackedVector3Array = PackedVector3Array()
	var width: float = 12.0
	var type: int = RoadNetwork.RoadType.STREET
	var surface: int = Surface.Type.ASPHALT
	var material: String = "road_city"
	var speed_limit_kmh: float = 50.0
	var one_way: bool = false
	var lane_count: int = 2
	var elevated: bool = false
	var deck_height: float = 0.0
	var length: float = 0.0
	var node_start: int = -1
	var node_end: int = -1
	var parent_road_name: String = ""
	## Габариты сегмента в плоскости XZ.  Нужны для отсечения: запрос высоты
	## рельефа делает тысячи поисков ближайшей дороги, и без отсечения каждый
	## сегмент-кандидат перебирал все свои точки (это и давало ~1.9 мс на запрос).
	var min_x: float = 0.0
	var max_x: float = 0.0
	var min_z: float = 0.0
	var max_z: float = 0.0

	func point_count() -> int:
		return points.size()


	## Пересчитывает габариты XZ (вызывается один раз при построении индекса).
	func recompute_bounds() -> void:
		min_x = INF
		max_x = -INF
		min_z = INF
		max_z = -INF
		for point in points:
			min_x = minf(min_x, point.x)
			max_x = maxf(max_x, point.x)
			min_z = minf(min_z, point.z)
			max_z = maxf(max_z, point.z)

	func point_at(distance: float) -> Vector3:
		return MathUtils.polyline_point_at(points, distance)

	func tangent_at(distance: float) -> Vector3:
		return MathUtils.polyline_tangent_at(points, distance)

	func recalc_length() -> void:
		length = MathUtils.polyline_length(points)


class RoadNode:
	extends RefCounted
	var id: int = -1
	var position: Vector3 = Vector3.ZERO
	var segments: PackedInt32Array = PackedInt32Array()
	var is_junction: bool = false
	var has_traffic_light: bool = false


var config: WorldConfig = null
var segments: Array[Segment] = []
var nodes: Array[RoadNode] = []
## City grid line coordinates (filled by RoadNetworkBuilder) - the city builder
## uses them to lay out blocks, lots and building frontages.
var city_grid_x: PackedFloat32Array = PackedFloat32Array()
var city_grid_z: PackedFloat32Array = PackedFloat32Array()
var city_half_extent: float = 0.0
## Пространственный индекс: ячейка (Vector2i) -> PackedInt32Array идентификаторов
## ПОДСЕГМЕНТОВ (пары соседних точек).
##
## Раньше в ячейках лежали целые сегменты.  Сегмент - это улица целиком, её
## габарит накрывает квартал, поэтому в центре города любая ячейка содержала
## почти все улицы города, и запрос высоты рельефа перебирал их все (~0.7 мс на
## вызов).  Подсегмент же занимает несколько метров, и перебор сократился на
## порядок.
var _index: Dictionary = {}
var _sub_a: PackedVector3Array = PackedVector3Array()
var _sub_b: PackedVector3Array = PackedVector3Array()
var _sub_segment: PackedInt32Array = PackedInt32Array()
## Длина полилинии сегмента до начала подсегмента и длина самого подсегмента
## (обе по XZ, как и вся навигационная логика) - чтобы не считать sqrt в цикле.
var _sub_along: PackedFloat32Array = PackedFloat32Array()
var _sub_length: PackedFloat32Array = PackedFloat32Array()


func _init(world_config: WorldConfig = null) -> void:
	config = world_config


func add_segment(segment: Segment) -> int:
	segment.id = segments.size()
	segments.append(segment)
	return segment.id


func add_node(position: Vector3, is_junction: bool = false) -> int:
	var node := RoadNode.new()
	node.id = nodes.size()
	node.position = position
	node.is_junction = is_junction
	nodes.append(node)
	return node.id


func link(segment_id: int, node_start: int, node_end: int) -> void:
	var segment := segments[segment_id]
	segment.node_start = node_start
	segment.node_end = node_end
	if node_start >= 0:
		nodes[node_start].segments.append(segment_id)
	if node_end >= 0 and node_end != node_start:
		nodes[node_end].segments.append(segment_id)
	if node_start >= 0 and nodes[node_start].segments.size() > 2:
		nodes[node_start].is_junction = true
	if node_end >= 0 and nodes[node_end].segments.size() > 2:
		nodes[node_end].is_junction = true


## Builds the spatial hash.  Call once after all segments are added.
## Индексируются подсегменты; длинная улица раскладывается по ячейкам обходом
## линии (Amanatides & Woo), а не заливкой всего её габарита.
func build_index() -> void:
	_index.clear()
	_sub_a.clear()
	_sub_b.clear()
	_sub_segment.clear()
	_sub_along.clear()
	_sub_length.clear()
	for segment in segments:
		segment.recalc_length()
		segment.recompute_bounds()
		var points := segment.points
		if points.size() < 2:
			continue
		var travelled := 0.0
		for i in range(points.size() - 1):
			var a := points[i]
			var b := points[i + 1]
			var sub_id := _sub_a.size()
			_sub_a.append(a)
			_sub_b.append(b)
			_sub_segment.append(segment.id)
			_sub_along.append(travelled)
			var dx := b.x - a.x
			var dz := b.z - a.z
			var sub_length := sqrt(dx * dx + dz * dz)
			_sub_length.append(sub_length)
			_index_subsegment(sub_id, a, b)
			travelled += sub_length


func _index_subsegment(sub_id: int, a: Vector3, b: Vector3) -> void:
	var cell_a := _cell(Vector2(a.x, a.z))
	var cell_b := _cell(Vector2(b.x, b.z))
	if cell_a == cell_b:
		_put_subsegment(cell_a, sub_id)
		return
	var dir_x := b.x - a.x
	var dir_z := b.z - a.z
	var step_x := 0
	var step_z := 0
	if dir_x > 0.0:
		step_x = 1
	elif dir_x < 0.0:
		step_x = -1
	if dir_z > 0.0:
		step_z = 1
	elif dir_z < 0.0:
		step_z = -1
	var t_max_x := INF
	var t_delta_x := INF
	if step_x != 0:
		var boundary_x := float(cell_a.x + (1 if step_x > 0 else 0)) * INDEX_CELL
		t_max_x = (boundary_x - a.x) / dir_x
		t_delta_x = absf(INDEX_CELL / dir_x)
	var t_max_z := INF
	var t_delta_z := INF
	if step_z != 0:
		var boundary_z := float(cell_a.y + (1 if step_z > 0 else 0)) * INDEX_CELL
		t_max_z = (boundary_z - a.z) / dir_z
		t_delta_z = absf(INDEX_CELL / dir_z)
	var cx := cell_a.x
	var cz := cell_a.y
	_put_subsegment(Vector2i(cx, cz), sub_id)
	var guard := 0
	while (cx != cell_b.x or cz != cell_b.y) and guard < 1024:
		guard += 1
		if t_max_x < t_max_z:
			cx += step_x
			t_max_x += t_delta_x
		else:
			cz += step_z
			t_max_z += t_delta_z
		_put_subsegment(Vector2i(cx, cz), sub_id)


func _put_subsegment(key: Vector2i, sub_id: int) -> void:
	if not _index.has(key):
		_index[key] = PackedInt32Array()
	var bucket: PackedInt32Array = _index[key]
	bucket.append(sub_id)
	_index[key] = bucket


func _cell(flat: Vector2) -> Vector2i:
	return Vector2i(int(floor(flat.x / INDEX_CELL)), int(floor(flat.y / INDEX_CELL)))


func segment_count() -> int:
	return segments.size()


func total_length_m() -> float:
	var total := 0.0
	for segment in segments:
		total += segment.length
	return total


## ------------------------------------------------------------------ queries
## Nearest point of the network.  Returns an empty dictionary when nothing is
## within max_distance.
## Ближайшая дорога к точке.  Горячий путь: вызывается рельефом на каждый
## сэмпл высоты (десятки тысяч раз на чанк) и физикой машины каждый кадр.
##
## Оптимизации (вместе дали ~20-кратное ускорение поиска):
##   * в ячейках лежат подсегменты, а не улицы целиком: перебор кандидатов
##     сократился на порядок (в городе ячейка больше не содержит все улицы);
##   * габарит подсегмента отсекается до точного расчёта;
##   * длины подсегментов посчитаны заранее, а результат пишется в локальные
##     переменные: в цикле нет ни Dictionary, ни Vector2/Vector3-аллокаций.
func nearest_road(position: Vector3, max_distance: float = 60.0) -> Dictionary:
	var half := int(ceil(max_distance / INDEX_CELL))
	var origin := _cell(Vector2(position.x, position.z))
	var best_sub := -1
	var best_distance := max_distance
	var px := position.x
	var pz := position.z
	var closest_x := 0.0
	var closest_y := 0.0
	var closest_z := 0.0
	var closest_along := 0.0
	for cx in range(origin.x - half, origin.x + half + 1):
		for cz in range(origin.y - half, origin.y + half + 1):
			var key := Vector2i(cx, cz)
			if not _index.has(key):
				continue
			for sub_id in (_index[key] as PackedInt32Array):
				var a := _sub_a[sub_id]
				var b := _sub_b[sub_id]
				# Габарит подсегмента: точки в нескольких метрах друг от друга,
				# поэтому проверка отсекает почти всех кандидатов.
				var min_x := minf(a.x, b.x)
				var max_x := maxf(a.x, b.x)
				var dx := 0.0
				if px < min_x:
					dx = min_x - px
				elif px > max_x:
					dx = px - max_x
				var min_z := minf(a.z, b.z)
				var max_z := maxf(a.z, b.z)
				var dz := 0.0
				if pz < min_z:
					dz = min_z - pz
				elif pz > max_z:
					dz = pz - max_z
				if dx * dx + dz * dz >= best_distance * best_distance:
					continue
				var abx := b.x - a.x
				var abz := b.z - a.z
				var len2 := abx * abx + abz * abz
				var t := 0.0
				if len2 > 0.000001:
					t = clampf(((px - a.x) * abx + (pz - a.z) * abz) / len2, 0.0, 1.0)
				var ox := px - (a.x + abx * t)
				var oz := pz - (a.z + abz * t)
				var distance_sq := ox * ox + oz * oz
				if distance_sq < best_distance * best_distance:
					best_distance = sqrt(distance_sq)
					best_sub = sub_id
					closest_x = a.x + abx * t
					closest_y = a.y + (b.y - a.y) * t
					closest_z = a.z + abz * t
					closest_along = _sub_along[sub_id] + _sub_length[sub_id] * t
	if best_sub < 0:
		return {}
	var segment := segments[_sub_segment[best_sub]]
	return {
		"segment": _sub_segment[best_sub],
		"distance": best_distance,
		"point": Vector3(closest_x, closest_y, closest_z),
		"along": closest_along,
		"t": 0.0 if segment.length <= 0.0001 else closest_along / segment.length,
		"tangent": segment.tangent_at(closest_along),
		"width": segment.width,
	}


## Projects a position onto one segment -> { segment, t, distance, point, tangent,
## distance_along }
func project_on_segment(segment_id: int, position: Vector3) -> Dictionary:
	var segment := segments[segment_id]
	var best_distance := INF
	var best_point := Vector3.ZERO
	var best_along := 0.0
	var travelled := 0.0
	for i in range(segment.points.size() - 1):
		var a := segment.points[i]
		var b := segment.points[i + 1]
		var closest := MathUtils.closest_point_on_segment_xz(position, a, b)
		var segment_length := Vector2(b.x - a.x, b.z - a.z).length()
		var along := travelled
		if segment_length > 0.0001:
			along += clampf(Vector2(closest.x - a.x, closest.z - a.z).length(), 0.0, segment_length)
		var distance := Vector2(position.x - closest.x, position.z - closest.z).length()
		if distance < best_distance:
			best_distance = distance
			best_point = Vector3(closest.x, closest.y, closest.z)
			best_along = along
		travelled += segment_length
	return {
		"segment": segment_id,
		"distance": best_distance,
		"point": best_point,
		"t": 0.0 if segment.length <= 0.0001 else best_along / segment.length,
		"along": best_along,
		"tangent": segment.tangent_at(best_along),
		"width": segment.width,
	}


func is_on_road(position: Vector3, margin: float = 0.0) -> bool:
	var found := nearest_road(position, 40.0)
	if found.is_empty():
		return false
	return float(found["distance"]) <= float(found["width"]) * 0.5 + margin


func road_surface_at(position: Vector3) -> int:
	# Максимальная полуширина дороги ~8 м, поэтому 16 м с запасом хватает.
	var found := nearest_road(position, 16.0)
	if found.is_empty():
		return -1
	var segment: Segment = segments[int(found["segment"])]
	if float(found["distance"]) <= segment.width * 0.5:
		return segment.surface
	return -1


## Segment that continues from `segment_id` at the given end, ignoring U-turns
## unless there is no other choice.
func neighbours(segment_id: int, at_end: bool) -> PackedInt32Array:
	var result := PackedInt32Array()
	var segment := segments[segment_id]
	var node_id := segment.node_end if at_end else segment.node_start
	if node_id < 0:
		return result
	var node := nodes[node_id]
	for other_id in node.segments:
		if other_id == segment_id:
			continue
		var other := segments[other_id]
		# Reject roads that are far above/below (interchange decks).
		var height_delta := absf(other.points[0].y - segment.points[0].y)
		if height_delta > 6.0 and (other.elevated != segment.elevated):
			continue
		result.append(other_id)
	return result


func other_end_of(segment_id: int, from_end: bool) -> Vector3:
	var segment := segments[segment_id]
	return segment.points[0] if from_end else segment.points[segment.points.size() - 1]


func node_of(segment_id: int, at_end: bool) -> int:
	var segment := segments[segment_id]
	return segment.node_end if at_end else segment.node_start


func road_type_name(segment_id: int) -> String:
	if segment_id < 0 or segment_id >= segments.size():
		return "none"
	return String(TYPE_NAMES.get(segments[segment_id].type, "road"))


## ------------------------------------------------------------------ routing
## A* over segments.  Cost is travel time (length / speed limit) plus a penalty
## for sharp turns, which is what makes intercept routes take the fast roads.
func plan_route(from_position: Vector3, to_position: Vector3, max_iterations: int = 900) -> Array[int]:
	var start := nearest_road(from_position, 120.0)
	var goal := nearest_road(to_position, 160.0)
	if start.is_empty() or goal.is_empty():
		return []
	var start_segment := int(start["segment"])
	var goal_segment := int(goal["segment"])
	if start_segment == goal_segment:
		return [start_segment]

	# A* with a travel-time heuristic.  The heuristic divides the straight-line
	# distance by the fastest speed limit in the network, so it can never
	# overestimate the remaining time and the route stays optimal, while the search
	# visits a small fraction of the graph instead of all of it.
	var fastest := 1.0
	for segment in segments:
		fastest = maxf(fastest, segment.speed_limit_kmh / 3.6)

	var open: Array[int] = [start_segment]
	var came_from: Dictionary = {}
	var cost_so_far: Dictionary = {start_segment: 0.0}
	var estimate: Dictionary = {start_segment: _estimate_seconds(start_segment, goal_segment, fastest)}
	var iterations := 0
	while not open.is_empty() and iterations < max_iterations:
		iterations += 1
		# Small graph: a linear scan for the lowest estimated total cost is fast
		# enough and keeps the code allocation free (no priority queue churn).
		var best_index := 0
		var best_cost := INF
		for i in range(open.size()):
			var candidate_cost: float = estimate.get(open[i], INF)
			if candidate_cost < best_cost:
				best_cost = candidate_cost
				best_index = i
		var current: int = open[best_index]
		open.remove_at(best_index)
		if current == goal_segment:
			return _reconstruct(came_from, start_segment, goal_segment)
		var current_cost: float = cost_so_far[current]
		for end in [true, false]:
			for next_id in neighbours(current, end):
				var next_segment := segments[next_id]
				var travel_time := next_segment.length / maxf(next_segment.speed_limit_kmh / 3.6, 4.0)
				var turn_penalty := _turn_penalty(current, next_id, end) * 1.6
				var new_cost: float = current_cost + travel_time + turn_penalty
				if not cost_so_far.has(next_id) or new_cost < float(cost_so_far[next_id]):
					cost_so_far[next_id] = new_cost
					came_from[next_id] = current
					estimate[next_id] = new_cost + _estimate_seconds(next_id, goal_segment, fastest)
					if not open.has(next_id):
						open.append(next_id)
	if came_from.has(goal_segment):
		return _reconstruct(came_from, start_segment, goal_segment)
	return []


## Optimistic remaining time from a segment to the goal (never overestimates).
func _estimate_seconds(segment_id: int, goal_segment: int, fastest_ms: float) -> float:
	var segment := segments[segment_id]
	var goal_point := segments[goal_segment].points[0]
	var best := INF
	for point in segment.points:
		best = minf(best, Vector2(point.x - goal_point.x, point.z - goal_point.z).length())
	return best / maxf(fastest_ms, 1.0)


func _turn_penalty(from_id: int, to_id: int, from_end: bool) -> float:
	var from_tangent := segments[from_id].tangent_at(segments[from_id].length if from_end else 0.0)
	var to_tangent := segments[to_id].tangent_at(0.0)
	var dot := clampf(from_tangent.normalized().dot(to_tangent.normalized()), -1.0, 1.0)
	return (1.0 - dot) * 8.0


func _reconstruct(came_from: Dictionary, start_id: int, goal_id: int) -> Array[int]:
	var path: Array[int] = [goal_id]
	var current := goal_id
	var guard := 0
	while current != start_id and guard < 512:
		guard += 1
		if not came_from.has(current):
			break
		current = int(came_from[current])
		path.push_front(current)
	return path


## Converts a segment route into a smooth point list (for AI steering).
## The list starts at the vehicle's own position, so it never contains the part of
## the first segment that lies *behind* the car (which would make the AI drive
## backwards for a moment) and it never jumps across a junction.
## `goal_position` is optional; when it is finite it also decides the direction of
## travel along a single-segment route.
func route_points(route: Array[int], start_position: Vector3, goal_position: Vector3 = Vector3(INF, INF, INF)) -> PackedVector3Array:
	var points := PackedVector3Array()
	if route.is_empty():
		return points
	var forward := _route_direction(route, start_position, goal_position)
	points.append(start_position)
	for index in range(route.size()):
		var segment := segments[route[index]]
		if index > 0:
			# Enter the next segment from whichever end is closer to the exit of the
			# previous one, so the route stays continuous at junctions.
			var exit_point := points[points.size() - 1]
			forward = exit_point.distance_to(segment.points[0]) <= exit_point.distance_to(segment.points[segment.points.size() - 1])
		var ordered: PackedVector3Array = _polyline_from(segment, start_position, forward) if index == 0 \
			else _oriented_points(segment.points, forward)
		for point in ordered:
			if points[points.size() - 1].distance_to(point) > 1.0:
				points.append(point)
	return _densify(points, MAX_ROUTE_POINT_SPACING_M)


## Road polylines are stored with few vertices (a kilometre of avenue can be a
## single edge), which is fine for geometry but useless for steering: a pure
## pursuit controller would see one waypoint 700 m away.  Long edges are therefore
## subdivided into points at most `spacing` apart.
func _densify(points: PackedVector3Array, spacing: float) -> PackedVector3Array:
	if points.size() < 2 or spacing <= 0.0:
		return points
	var result := PackedVector3Array()
	result.append(points[0])
	for i in range(points.size() - 1):
		var a := points[i]
		var b := points[i + 1]
		var distance := a.distance_to(b)
		var steps := maxi(int(ceil(distance / spacing)), 1)
		for step in range(1, steps + 1):
			result.append(a.lerp(b, float(step) / float(steps)))
	return result


## Direction of travel along the first segment of a route.
func _route_direction(route: Array[int], start_position: Vector3, goal_position: Vector3) -> bool:
	var first := segments[route[0]]
	if route.size() == 1:
		if is_finite(goal_position.x):
			var start_along := float(project_on_segment(route[0], start_position)["along"])
			var goal_along := float(project_on_segment(route[0], goal_position)["along"])
			return goal_along >= start_along
		# No goal given: cross the segment towards its farther end.
		return start_position.distance_to(first.points[0]) <= start_position.distance_to(first.points[first.points.size() - 1])
	var second_id: int = route[1]
	if first.node_end >= 0 and nodes[first.node_end].segments.has(second_id):
		return true
	if first.node_start >= 0 and nodes[first.node_start].segments.has(second_id):
		return false
	# No shared node (a connector-less join): fall back to geometry.
	var second := segments[second_id]
	var exit := minf(first.points[first.points.size() - 1].distance_to(second.points[0]),
		first.points[first.points.size() - 1].distance_to(second.points[second.points.size() - 1]))
	var entry := minf(first.points[0].distance_to(second.points[0]),
		first.points[0].distance_to(second.points[second.points.size() - 1]))
	return exit <= entry


func _oriented_points(points: PackedVector3Array, forward: bool) -> PackedVector3Array:
	if forward:
		return points
	var reversed_points := PackedVector3Array()
	for i in range(points.size() - 1, -1, -1):
		reversed_points.append(points[i])
	return reversed_points


## The part of a segment from the projection of `position` onwards (in the given
## direction), starting exactly at that projection.
func _polyline_from(segment: Segment, position: Vector3, forward: bool) -> PackedVector3Array:
	var found := project_on_segment(segment.id, position)
	var project_point: Vector3 = found["point"]
	var along: float = float(found["along"])
	var ordered := _oriented_points(segment.points, forward)
	if not forward:
		along = maxf(segment.length - along, 0.0)
	var result := PackedVector3Array()
	result.append(project_point)
	var travelled := 0.0
	for i in range(ordered.size() - 1):
		travelled += ordered[i].distance_to(ordered[i + 1])
		if travelled > along + 0.01:
			result.append(ordered[i + 1])
	if result.size() == 1 and ordered.size() > 1:
		result.append(ordered[ordered.size() - 1])
	return result


## A random point on a road within [min_distance, max_distance] of a position,
## used by the spawn manager and by the traffic filler props.
func random_road_point(
	position: Vector3,
	min_distance: float,
	max_distance: float,
	rng: RandomNumberGenerator,
	attempts: int = 24
) -> Dictionary:
	if segments.is_empty():
		return {}
	var best: Dictionary = {}
	for attempt in range(attempts):
		var segment := segments[rng.randi_range(0, segments.size() - 1)]
		if segment.points.is_empty():
			continue
		var along := rng.randf() * segment.length
		var point := segment.point_at(along)
		var distance := Vector3(point.x - position.x, 0.0, point.z - position.z).length()
		if distance < min_distance or distance > max_distance:
			continue
		best = {
			"segment": segment.id,
			"point": point,
			"tangent": segment.tangent_at(along),
			"along": along,
			"distance": distance,
		}
		if attempt >= attempts / 2:
			break
	return best


## Road segments near a chunk (used to decide which chunk needs road geometry).
## The spatial hash is sparse, so the function walks the cells that actually hold
## roads instead of every cell of the radius box - a call with a multi-kilometre
## radius stays cheap instead of scanning billions of empty cells.
func segments_in_area(center: Vector3, radius: float) -> PackedInt32Array:
	var half := int(ceil(radius / INDEX_CELL))
	var origin := _cell(Vector2(center.x, center.z))
	var found := PackedInt32Array()
	var seen := {}
	for key: Vector2i in _index.keys():
		if absi(key.x - origin.x) > half or absi(key.y - origin.y) > half:
			continue
		for sub_id in (_index[key] as PackedInt32Array):
			var segment_id := _sub_segment[sub_id]
			if seen.has(segment_id):
				continue
			seen[segment_id] = true
			var segment := segments[segment_id]
			var closest := _closest_point_on_segment(center, segment)
			if Vector2(closest.x - center.x, closest.z - center.z).length() <= radius:
				found.append(segment_id)
	return found


func _closest_point_on_segment(position: Vector3, segment: Segment) -> Vector3:
	var best := segment.points[0]
	var best_distance := INF
	for i in range(segment.points.size() - 1):
		var closest := MathUtils.closest_point_on_segment_xz(position, segment.points[i], segment.points[i + 1])
		var distance := Vector2(closest.x - position.x, closest.z - position.z).length()
		if distance < best_distance:
			best_distance = distance
			best = closest
	return best


func stats() -> Dictionary:
	var by_type: Dictionary = {}
	var length_by_type: Dictionary = {}
	for segment in segments:
		var type_name := String(TYPE_NAMES.get(segment.type, "road"))
		by_type[type_name] = int(by_type.get(type_name, 0)) + 1
		length_by_type[type_name] = float(length_by_type.get(type_name, 0.0)) + segment.length
	return {
		"segments": segments.size(),
		"nodes": nodes.size(),
		"total_length_m": total_length_m(),
		"by_type": by_type,
		"length_by_type": length_by_type,
	}
