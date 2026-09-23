class_name RoadNetworkBuilder
extends RefCounted

## Deterministically generates the whole road network of the open world:
## a jittered city grid with avenues and diagonals, a city boundary boulevard,
## four highway radials that cross the map, a ring highway with flyover
## interchanges, rural roads reaching into the countryside, dirt tracks in the
## fields and a lake bridge.
##
## Everything is derived from WorldConfig.seed, so the same world is produced
## on every device and in CI (tests/unit/test_road_network.gd asserts this).

## Junction lookup.  Two roads that meet share a node only if their endpoints are
## close in the ground plane *and* at a similar height: the key ignores `y`,
## because the same junction gets a slightly different height from each road's own
## grading pass, and comparing the full 3D position would leave every street
## disconnected (the graph would have no neighbours at all).
const NODE_SNAP_M := 4.0
const NODE_HEIGHT_TOLERANCE_M := 6.0
## Tolerances of the graph welding pass (see _weld_network).
const WELD_MAX_GAP_M := 30.0
const WELD_MAX_HEIGHT_M := 5.0
const WELD_CROSSING_HEIGHT_M := 4.0
const WELD_MIN_SPLIT_FRACTION := 0.03

var config: WorldConfig
var network: RoadNetwork
var poi_slots: Array[Dictionary] = []
var interchange_centers: PackedVector3Array = PackedVector3Array()
var rng: RandomNumberGenerator
## Statistics of the welding pass (exposed for the world dump and the tests).
var welded_crossings: int = 0
var welded_connectors: int = 0

var _height_sampler: Callable
var _node_lookup: Dictionary = {}
var _rural_endpoints: Array[Dictionary] = []


func _init(world_config: WorldConfig, height_sampler: Callable) -> void:
	config = world_config
	_height_sampler = height_sampler
	network = RoadNetwork.new(world_config)
	rng = RandomNumberGenerator.new()
	rng.seed = world_config.seed


func build() -> RoadNetwork:
	network = RoadNetwork.new(config)
	_node_lookup.clear()
	_rural_endpoints.clear()
	poi_slots.clear()
	interchange_centers = PackedVector3Array()
	rng.seed = config.seed
	_build_city_grid()
	_build_city_diagonals()
	_build_boundary_boulevard()
	_build_highway_radials()
	_build_ring_highway()
	_build_rural_roads()
	_build_dirt_roads()
	_build_poi_access()
	_weld_network()
	network.build_index()
	return network


## ------------------------------------------------------------------ helpers
func _base_height(x: float, z: float) -> float:
	return float(_height_sampler.call(x, z))


func _node_at(position: Vector3) -> int:
	var key := Vector2i(int(round(position.x / NODE_SNAP_M)), int(round(position.z / NODE_SNAP_M)))
	for node_id in _nodes_in_cell(key):
		var node: RoadNetwork.RoadNode = network.nodes[node_id]
		if absf(node.position.y - position.y) > NODE_HEIGHT_TOLERANCE_M:
			continue
		if Vector2(node.position.x - position.x, node.position.z - position.z).length() <= NODE_SNAP_M:
			return node_id
	var node_id := network.add_node(position)
	if not _node_lookup.has(key):
		_node_lookup[key] = PackedInt32Array()
	var bucket: PackedInt32Array = _node_lookup[key]
	bucket.append(node_id)
	_node_lookup[key] = bucket
	return node_id


func _nodes_in_cell(key: Vector2i) -> PackedInt32Array:
	var bucket: Variant = _node_lookup.get(key)
	if bucket == null:
		return PackedInt32Array()
	return bucket


## Samples the terrain along a polyline, smooths it (roads are graded) and
## returns the resulting 3D points.
func _sample_road_points(flat_points: PackedVector2Array, deck_offset: float = 0.0, smoothing: int = 2) -> PackedVector3Array:
	var heights := PackedFloat32Array()
	heights.resize(flat_points.size())
	for i in range(flat_points.size()):
		heights[i] = _base_height(flat_points[i].x, flat_points[i].y)
	for _pass in range(smoothing):
		var smoothed := PackedFloat32Array()
		smoothed.resize(heights.size())
		for i in range(heights.size()):
			var previous: float = heights[maxi(i - 1, 0)]
			var next: float = heights[mini(i + 1, heights.size() - 1)]
			var center: float = heights[i]
			# Weighted towards the centre; ends keep their value.
			smoothed[i] = (previous + center * 2.0 + next) * 0.25
		heights = smoothed
	var points := PackedVector3Array()
	points.resize(flat_points.size())
	for i in range(flat_points.size()):
		points[i] = Vector3(flat_points[i].x, heights[i] + deck_offset, flat_points[i].y)
	return points


## ------------------------------------------------------------ graph welding
## The roads are generated one after another, so two roads that cross *inside* a
## segment (a diagonal through the city grid, a ramp meeting the ring highway)
## used to sit in separate connected components: A* could not route through them
## and the police could not drive them.  Two passes turn the geometry into a real
## junction graph:
##   1. every crossing of two roads at a compatible height becomes a shared node
##      and both polylines are split there,
##   2. road ends a few metres apart are joined by a short connector, which closes
##      the small gaps the generators leave at interchanges.
## Both passes only ever add nodes/segments, so the visual geometry stays where
## the generator put it (the split point lies exactly on the original polyline).
func _weld_network() -> void:
	_split_road_crossings()
	_connect_dangling_ends()


func _split_road_crossings() -> void:
	var original_count := network.segment_count()
	var cuts: Dictionary = {}
	for i in range(original_count):
		var a: RoadNetwork.Segment = network.segments[i]
		for j in range(i + 1, original_count):
			var b: RoadNetwork.Segment = network.segments[j]
			# A flyover crosses a street without touching it: only roads that share
			# the "on the ground / elevated" state can form a junction.
			if a.elevated != b.elevated:
				continue
			for hit in _crossings_between(a, b):
				_register_cut(cuts, i, hit["a"])
				_register_cut(cuts, j, hit["b"])
	for segment_id in cuts.keys():
		# Split from the far end towards the start so the distances measured on the
		# original polyline stay valid for the part that is still being cut.
		var entries: Array = cuts[segment_id]
		entries.sort_custom(func(x: Dictionary, y: Dictionary) -> bool: return float(x["distance"]) > float(y["distance"]))
		for entry in entries:
			if _split_segment_at(int(segment_id), float(entry["distance"]), entry["point"]) >= 0:
				welded_crossings += 1


func _register_cut(cuts: Dictionary, segment_id: int, entry: Dictionary) -> void:
	if not cuts.has(segment_id):
		cuts[segment_id] = []
	(cuts[segment_id] as Array).append(entry)


## Intersections of two polylines in the ground plane, with the height each road
## has at that spot.  Roads that cross with a large height difference (different
## grading, stacked decks) are reported as *no* junction.
func _crossings_between(a: RoadNetwork.Segment, b: RoadNetwork.Segment) -> Array:
	var result: Array = []
	var a_travelled := 0.0
	for i in range(a.points.size() - 1):
		var a0 := a.points[i]
		var a1 := a.points[i + 1]
		var a0_flat := Vector2(a0.x, a0.z)
		var a1_flat := Vector2(a1.x, a1.z)
		var a_edge := a0_flat.distance_to(a1_flat)
		if a_edge < 0.5:
			continue
		var b_travelled := 0.0
		for j in range(b.points.size() - 1):
			var b0 := b.points[j]
			var b1 := b.points[j + 1]
			var b0_flat := Vector2(b0.x, b0.z)
			var b1_flat := Vector2(b1.x, b1.z)
			var b_edge := b0_flat.distance_to(b1_flat)
			if b_edge < 0.5:
				continue
			var hit: Variant = Geometry2D.segment_intersects_segment(a0_flat, a1_flat, b0_flat, b1_flat)
			if hit == null:
				continue
			var point_flat: Vector2 = hit
			var ta := a0_flat.distance_to(point_flat) / a_edge
			var tb := b0_flat.distance_to(point_flat) / b_edge
			if ta < WELD_MIN_SPLIT_FRACTION or ta > 1.0 - WELD_MIN_SPLIT_FRACTION:
				continue
			if tb < WELD_MIN_SPLIT_FRACTION or tb > 1.0 - WELD_MIN_SPLIT_FRACTION:
				continue
			var point_a := a0.lerp(a1, ta)
			var point_b := b0.lerp(b1, tb)
			if absf(point_a.y - point_b.y) > WELD_CROSSING_HEIGHT_M:
				continue
			result.append({
				"a": {"distance": a_travelled + a_edge * ta, "point": point_a},
				"b": {"distance": b_travelled + b_edge * tb, "point": point_b},
			})
			b_travelled += b_edge
		a_travelled += a_edge
	return result


## Splits one segment at `distance` along its own polyline.  The left part keeps
## the id (and its start node), the right part becomes a new segment.  Both get
## the shared junction node returned by `_node_at`, which is what welds the graph.
func _split_segment_at(segment_id: int, distance: float, point: Vector3) -> int:
	var segment: RoadNetwork.Segment = network.segments[segment_id]
	var edge := _edge_index_at(segment.points, distance)
	if edge < 0:
		return -1
	var left_points := PackedVector3Array()
	for k in range(edge + 1):
		left_points.append(segment.points[k])
	left_points.append(point)
	var right_points := PackedVector3Array([point])
	for k in range(edge + 1, segment.points.size()):
		right_points.append(segment.points[k])
	if right_points.size() < 2:
		return -1
	var node_start := segment.node_start
	var node_end := segment.node_end
	segment.points = left_points
	segment.recalc_length()
	var right := _clone_segment(segment)
	right.points = right_points
	right.recalc_length()
	var right_id := network.add_segment(right)
	var middle := _node_at(point)
	_relink(segment_id, node_start, middle)
	_relink(right_id, middle, node_end)
	return right_id


func _edge_index_at(points: PackedVector3Array, distance: float) -> int:
	var travelled := 0.0
	for i in range(points.size() - 1):
		travelled += points[i].distance_to(points[i + 1])
		if travelled >= distance:
			return i
	return -1


func _clone_segment(source: RoadNetwork.Segment) -> RoadNetwork.Segment:
	var segment := RoadNetwork.Segment.new()
	segment.type = source.type
	segment.width = source.width
	segment.surface = source.surface
	segment.material = source.material
	segment.speed_limit_kmh = source.speed_limit_kmh
	segment.one_way = source.one_way
	segment.lane_count = source.lane_count
	segment.elevated = source.elevated
	segment.deck_height = source.deck_height
	segment.parent_road_name = source.parent_road_name
	return segment


## Re-links a segment without appending it to a node twice (unlike Network.link,
## which is meant for freshly created segments).
func _relink(segment_id: int, node_start: int, node_end: int) -> void:
	var segment: RoadNetwork.Segment = network.segments[segment_id]
	segment.node_start = node_start
	segment.node_end = node_end
	for node_id in [node_start, node_end]:
		if node_id < 0:
			continue
		var node: RoadNetwork.RoadNode = network.nodes[node_id]
		if not node.segments.has(segment_id):
			node.segments.append(segment_id)
		if node.segments.size() > 2:
			node.is_junction = true


func _connect_dangling_ends() -> void:
	var ends := PackedInt32Array()
	for node in network.nodes:
		if node.segments.size() == 1:
			ends.append(node.id)
	var used := {}
	for node_id in ends:
		if used.has(node_id):
			continue
		var node: RoadNetwork.RoadNode = network.nodes[node_id]
		var best := -1
		var best_gap := WELD_MAX_GAP_M
		for other_id in ends:
			if other_id == node_id or used.has(other_id):
				continue
			var other: RoadNetwork.RoadNode = network.nodes[other_id]
			var gap := Vector2(other.position.x - node.position.x, other.position.z - node.position.z).length()
			if gap < 1.0 or gap >= best_gap:
				continue
			if absf(other.position.y - node.position.y) > WELD_MAX_HEIGHT_M:
				continue
			best = other_id
			best_gap = gap
		if best < 0:
			continue
		if _make_connector(node_id, best):
			used[node_id] = true
			used[best] = true


## A short piece of road that closes a gap between two road ends.
func _make_connector(from_node: int, to_node: int) -> bool:
	var from_position: Vector3 = network.nodes[from_node].position
	var to_position: Vector3 = network.nodes[to_node].position
	var source_id: int = network.nodes[from_node].segments[0]
	var source: RoadNetwork.Segment = network.segments[source_id]
	var segment := RoadNetwork.Segment.new()
	segment.points = PackedVector3Array([from_position, to_position])
	segment.type = source.type
	segment.width = source.width
	segment.surface = source.surface
	segment.material = source.material
	segment.speed_limit_kmh = source.speed_limit_kmh
	segment.lane_count = source.lane_count
	segment.elevated = source.elevated
	segment.parent_road_name = "connector"
	segment.recalc_length()
	var connector_id := network.add_segment(segment)
	_relink(connector_id, from_node, to_node)
	welded_connectors += 1
	return true


func _make_segment(
	flat_points: PackedVector2Array,
	type: int,
	width: float,
	surface: int,
	material: String,
	speed_limit: float,
	elevated: bool = false,
	deck_height: float = 0.0,
	lanes: int = 2,
	one_way: bool = false,
	name: String = ""
) -> int:
	if flat_points.size() < 2:
		return -1
	var points := _sample_road_points(flat_points, deck_height)
	var segment := RoadNetwork.Segment.new()
	segment.points = points
	segment.type = type
	segment.width = width
	segment.surface = surface
	segment.material = material
	segment.speed_limit_kmh = speed_limit
	segment.elevated = elevated
	segment.deck_height = deck_height
	segment.lane_count = lanes
	segment.one_way = one_way
	segment.parent_road_name = name
	var segment_id := network.add_segment(segment)
	var start_node := _node_at(points[0])
	var end_node := _node_at(points[points.size() - 1])
	network.link(segment_id, start_node, end_node)
	return segment_id


func _default_material_for(type: int) -> String:
	match type:
		RoadNetwork.RoadType.HIGHWAY: return "road_highway"
		RoadNetwork.RoadType.AVENUE: return "road_avenue"
		RoadNetwork.RoadType.RAMP: return "road_highway"
		RoadNetwork.RoadType.RURAL: return "road_rural"
		RoadNetwork.RoadType.DIRT: return "road_dirt"
		RoadNetwork.RoadType.BRIDGE: return "road_rural"
		RoadNetwork.RoadType.SERVICE: return "road_asphalt"
		_: return "road_city"


## ---------------------------------------------------------------- city grid
func _build_city_grid() -> void:
	var half := config.city_outer_radius
	var pitch := config.city_block_pitch
	# The grid lines sit exactly `city_block_pitch` apart (the block layout, the
	# lots and the tests all rely on that); the streets themselves are still
	# irregular because their middle points are jittered below and some blocks are
	# left without a road.
	var line_count := int(floor(half * 2.0 / pitch))
	var coordinates: PackedFloat32Array = PackedFloat32Array()
	for i in range(line_count + 1):
		coordinates.append(-half + float(i) * pitch)

	network.city_grid_x = coordinates
	network.city_grid_z = coordinates
	network.city_half_extent = half

	var is_avenue := func(index: int) -> bool:
		return index % config.avenue_every == 0

	# --- streets running along +Z (constant X)
	for i in range(coordinates.size()):
		var x := coordinates[i]
		var avenue: bool = is_avenue.call(i)
		var width: float = config.road_width_avenue if avenue else config.road_width_street
		for j in range(coordinates.size() - 1):
			# Occasionally leave a gap so the grid is not perfectly regular.
			if rng.randf() < 0.045 and not avenue:
				continue
			var z0 := coordinates[j]
			var z1 := coordinates[j + 1]
			var points := PackedVector2Array()
			points.append(Vector2(x, z0))
			var mid_jitter := rng.randf_range(-4.0, 4.0)
			points.append(Vector2(x + mid_jitter, (z0 + z1) * 0.5))
			points.append(Vector2(x, z1))
			_make_segment(
				points,
				RoadNetwork.RoadType.AVENUE if avenue else RoadNetwork.RoadType.STREET,
				width,
				Surface.Type.ASPHALT,
				"road_avenue" if avenue else "road_city",
				60.0 if avenue else 50.0,
				false, 0.0, 4 if avenue else 2, false, "city_grid"
			)

	# --- streets running along +X (constant Z)
	for j in range(coordinates.size()):
		var z := coordinates[j]
		var avenue: bool = is_avenue.call(j)
		var width: float = config.road_width_avenue if avenue else config.road_width_street
		for i in range(coordinates.size() - 1):
			if rng.randf() < 0.045 and not avenue:
				continue
			var x0 := coordinates[i]
			var x1 := coordinates[i + 1]
			var points := PackedVector2Array()
			points.append(Vector2(x0, z))
			points.append(Vector2((x0 + x1) * 0.5, z + rng.randf_range(-4.0, 4.0)))
			points.append(Vector2(x1, z))
			_make_segment(
				points,
				RoadNetwork.RoadType.AVENUE if avenue else RoadNetwork.RoadType.STREET,
				width,
				Surface.Type.ASPHALT,
				"road_avenue" if avenue else "road_city",
				60.0 if avenue else 50.0,
				false, 0.0, 4 if avenue else 2, false, "city_grid"
			)


func _build_city_diagonals() -> void:
	var half := config.city_outer_radius * 0.92
	for angle_index in range(2):
		var angle := PI * 0.25 + float(angle_index) * PI * 0.5
		var direction := Vector2(cos(angle), sin(angle))
		var points := PackedVector2Array()
		var steps := 14
		for i in range(steps + 1):
			var t := float(i) / float(steps)
			var distance := lerpf(-half, half, t)
			var wobble := sin(t * 6.0 + float(angle_index)) * 22.0
			var point := direction * distance + Vector2(-direction.y, direction.x) * wobble
			points.append(point)
		_make_segment(
			points, RoadNetwork.RoadType.AVENUE, config.road_width_avenue,
			Surface.Type.ASPHALT, "road_avenue", 70.0, false, 0.0, 4, false, "diagonal"
		)


func _build_boundary_boulevard() -> void:
	var radius := config.ring_road_radius * 0.78
	var steps := 40
	var points := PackedVector2Array()
	for i in range(steps + 1):
		var angle := TAU * float(i) / float(steps)
		var variation := 1.0 + sin(angle * 3.0) * 0.06 + cos(angle * 5.0) * 0.04
		points.append(Vector2(cos(angle), sin(angle)) * radius * variation)
	_make_segment(
		points, RoadNetwork.RoadType.AVENUE, config.road_width_avenue * 0.9,
		Surface.Type.ASPHALT, "road_avenue", 70.0, false, 0.0, 4, false, "boulevard"
	)


## ------------------------------------------------------------ highway radials
func _build_highway_radials() -> void:
	var inner := config.ring_road_radius * 0.78
	var outer := config.world_half_extent() - 90.0
	var angles := [0.0, PI * 0.5, PI, PI * 1.5]
	for index in range(angles.size()):
		var angle: float = angles[index] + rng.randf_range(-0.12, 0.12)
		var direction := Vector2(cos(angle), sin(angle))
		var lateral := Vector2(-direction.y, direction.x)
		# Two carriageways separated by a median -> two one-way segments.
		for side in [-1.0, 1.0]:
			var points := PackedVector2Array()
			var steps := 26
			for i in range(steps + 1):
				var t := float(i) / float(steps)
				var distance := lerpf(inner, outer, t)
				# Gentle meander so the highway is not a ruler line.
				var offset: float = sin(t * 3.4 + float(index)) * 55.0 + float(side) * 6.5
				points.append(direction * distance + lateral * offset)
			_make_segment(
				points, RoadNetwork.RoadType.HIGHWAY, 12.0, Surface.Type.ASPHALT,
				"road_highway", 110.0, false, 0.0, 3, true, "highway_radial_%d" % index
			)


## ------------------------------------------- ring highway + interchanges
func _build_ring_highway() -> void:
	var radius := config.ring_road_radius
	var steps := 72
	var lane_offset := 7.0
	for side in [-1.0, 1.0]:
		var points := PackedVector2Array()
		for i in range(steps + 1):
			var angle := TAU * float(i) / float(steps)
			var variation := 1.0 + sin(angle * 2.0) * 0.03
			var local_radius: float = radius * variation + float(side) * lane_offset
			points.append(Vector2(cos(angle), sin(angle)) * local_radius)
		_make_segment(
			points, RoadNetwork.RoadType.HIGHWAY, 12.0, Surface.Type.ASPHALT,
			"road_highway", 110.0, false, 0.0, 3, true, "ring_highway_%s" % ("outer" if side > 0.0 else "inner")
		)

	# --- four interchanges where the radials meet the ring highway
	var interchange_angles := [0.0, PI * 0.5, PI, PI * 1.5]
	for index in range(interchange_angles.size()):
		var angle: float = interchange_angles[index]
		var center := Vector2(cos(angle), sin(angle)) * radius
		interchange_centers.append(Vector3(center.x, _base_height(center.x, center.y), center.y))
		var radial := Vector2(cos(angle), sin(angle))
		var lateral := Vector2(-radial.y, radial.x)
		# flyover: the radial passes over the ring on an elevated deck
		var deck := config.interchange_flyover_height
		var flyover_points := PackedVector2Array()
		for i in range(9):
			var t := float(i) / 8.0
			flyover_points.append(center + radial * lerpf(-110.0, 110.0, t))
		_make_segment(
			flyover_points, RoadNetwork.RoadType.HIGHWAY, 12.0, Surface.Type.CONCRETE,
			"road_highway", 100.0, true, deck, 3, true, "flyover_%d" % index
		)
		# four ramps per interchange: from the ring road up to the flyover
		for ramp_index in range(4):
			var sign_radial := 1.0 if ramp_index < 2 else -1.0
			var sign_lateral := 1.0 if ramp_index % 2 == 0 else -1.0
			var entry := center + lateral * sign_lateral * lerpf(34.0, 96.0, 0.4) - radial * sign_radial * 62.0
			var exit := center + lateral * sign_lateral * 12.0 + radial * sign_radial * 74.0
			var points := PackedVector2Array()
			var ramp_steps := 12
			for i in range(ramp_steps + 1):
				var t := float(i) / float(ramp_steps)
				var curve := entry.lerp(exit, t)
				curve += lateral * sign_lateral * sin(t * PI) * 26.0
				points.append(curve)
			_make_segment(
				points, RoadNetwork.RoadType.RAMP, config.road_width_ramp,
				Surface.Type.ASPHALT, "road_highway", 50.0, true, deck * 0.35, 2, true,
				"ramp_%d_%d" % [index, ramp_index]
			)


## --------------------------------------------------------------- rural roads
func _build_rural_roads() -> void:
	var ring_radius := config.ring_road_radius
	var limit := config.world_half_extent() - 70.0
	for index in range(config.rural_road_count):
		var angle := TAU * float(index) / float(config.rural_road_count) + rng.randf_range(-0.08, 0.08)
		var direction := Vector2(cos(angle), sin(angle))
		var points := PackedVector2Array()
		var position := direction * (ring_radius * 1.02)
		points.append(position)
		var steps := 30
		var heading := direction
		for step in range(steps):
			# Wander a little, but keep pushing outwards.
			var turn := rng.randf_range(-0.16, 0.16)
			heading = heading.rotated(turn)
			heading = heading.lerp(direction, 0.25).normalized()
			position += heading * 96.0
			points.append(position)
			if absf(position.x) > limit or absf(position.y) > limit:
				break
		if points.size() < 3:
			continue
		# --- lake: turn the stretch that crosses the water into a bridge
		var lake_center := config.lake_center
		var crosses_lake := false
		for point in points:
			if (point - lake_center).length() < config.lake_radius * 0.8:
				crosses_lake = true
				break
		var type := RoadNetwork.RoadType.RURAL
		var surface := Surface.Type.ASPHALT
		var material := "road_rural"
		if crosses_lake:
			type = RoadNetwork.RoadType.BRIDGE
			surface = Surface.Type.CONCRETE
			material = "road_rural"
		_rural_endpoints.append({"position": Vector3(points[points.size() - 1].x, 0.0, points[points.size() - 1].y), "segment_angle": angle})
		var segment_id := _make_segment(
			points, type, config.road_width_rural, surface, material, 80.0,
			crosses_lake, 0.0, 2, false, "rural_%d" % index
		)
		if crosses_lake and segment_id >= 0:
			_raise_bridge(segment_id)


## Lifts the part of a road that crosses the lake onto a bridge deck.
func _raise_bridge(segment_id: int) -> void:
	var segment := network.segments[segment_id]
	var center := config.lake_center
	var deck_y := config.water_level + 4.6
	var points := segment.points
	for i in range(points.size()):
		var flat := Vector2(points[i].x, points[i].z)
		var distance := (flat - center).length()
		if distance < config.lake_radius * 0.9:
			var blend := 1.0 - smoothstep(config.lake_radius * 0.55, config.lake_radius * 0.9, distance)
			points[i] = Vector3(points[i].x, lerpf(points[i].y, deck_y, clampf(blend, 0.0, 1.0)), points[i].z)
	segment.points = points
	segment.elevated = true
	segment.deck_height = deck_y - _base_height(center.x, center.y)
	segment.surface = Surface.Type.CONCRETE


func _build_dirt_roads() -> void:
	var limit := config.world_half_extent() - 90.0
	for index in range(config.dirt_road_count):
		var anchor: Dictionary = {}
		if not _rural_endpoints.is_empty() and rng.randf() < 0.75:
			anchor = _rural_endpoints[rng.randi_range(0, _rural_endpoints.size() - 1)]
		var start_angle := rng.randf() * TAU
		var position := Vector2.ZERO
		if anchor.is_empty():
			position = Vector2(cos(start_angle), sin(start_angle)) * (config.ring_road_radius * rng.randf_range(1.05, 1.6))
		else:
			var base: Vector3 = anchor["position"]
			position = Vector2(base.x, base.z)
		var points := PackedVector2Array()
		points.append(position)
		var heading := Vector2(cos(start_angle), sin(start_angle))
		for step in range(16):
			heading = heading.rotated(rng.randf_range(-0.42, 0.42))
			position += heading * 78.0
			if absf(position.x) > limit or absf(position.y) > limit:
				break
			points.append(position)
		if points.size() < 3:
			continue
		_make_segment(
			points, RoadNetwork.RoadType.DIRT, config.road_width_dirt,
			Surface.Type.DIRT, "road_dirt", 45.0, false, 0.0, 2, false, "dirt_%d" % index
		)


## Short service stubs where landmarks (gas stations, depots) meet a road.
func _build_poi_access() -> void:
	var pois := [
		{"kind": "gas_station", "count": config.gas_station_count},
		{"kind": "depot", "count": 4},
		{"kind": "farm", "count": 6},
		{"kind": "warehouse", "count": 5},
	]
	var limit := config.world_half_extent() - 160.0
	for entry in pois:
		var kind := String(entry["kind"])
		for index in range(int(entry["count"])):
			var found: Dictionary = {}
			for attempt in range(28):
				var candidate := Vector2(rng.randf_range(-limit, limit), rng.randf_range(-limit, limit))
				var probe := Vector3(candidate.x, 0.0, candidate.y)
				var road := network.nearest_road(probe, 240.0)
				if road.is_empty():
					continue
				var distance: float = road["distance"]
				if distance < 26.0 or distance > 240.0:
					continue
				found = road
				found["position"] = candidate
				break
			if found.is_empty():
				continue
			var road_point: Vector3 = found["point"]
			var tangent: Vector3 = found["tangent"]
			var side := 1.0 if rng.randf() < 0.5 else -1.0
			var lateral := Vector3(-tangent.z, 0.0, tangent.x).normalized() * side
			var lot_center := Vector3(road_point.x, 0.0, road_point.z) + lateral * 34.0
			var access := PackedVector2Array()
			access.append(Vector2(road_point.x, road_point.z))
			access.append(Vector2(road_point.x + lateral.x * 16.0, road_point.z + lateral.z * 16.0))
			access.append(Vector2(lot_center.x, lot_center.z))
			_make_segment(
				access, RoadNetwork.RoadType.SERVICE, 9.0, Surface.Type.ASPHALT,
				"road_asphalt", 30.0, false, 0.0, 2, false, "access_%s_%d" % [kind, index]
			)
			poi_slots.append({
				"kind": kind,
				"center": Vector3(lot_center.x, _base_height(lot_center.x, lot_center.z), lot_center.z),
				"facing": -lateral,
				"road_point": road_point,
			})
