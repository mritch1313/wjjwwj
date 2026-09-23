class_name RoadBuilder
extends RefCounted

## Turns RoadNetwork segments into actual road geometry for one chunk:
## carriageway ribbon with baked lane markings, kerbs, sidewalks, gravel
## shoulders, guardrails, median barriers, intersection patches, crosswalks,
## bridge decks with railings and piers.
##
## Everything is merged into the chunk's MeshBuilder, so a chunk with a kilometre
## of road still costs a handful of draw calls.
##
## UV conventions
##   * ribbon materials ("road_city", "road_highway", ...): U = 0..1 across the
##     road, V = metres along the road (the material scales V by 1/period, which
##     is why the markings repeat at the right spacing).
##   * block materials ("sidewalk", "concrete", ...): UV in metres, the material
##     scales them (0.25 = one texture per 4 m).

const SAMPLE_STEP := 4.0

var config: WorldConfig
var terrain: TerrainField
var network: RoadNetwork


func _init(world_config: WorldConfig, world_terrain: TerrainField) -> void:
	config = world_config
	terrain = world_terrain
	network = world_terrain.road_network()


## Builds every road piece that touches the chunk rectangle.
## tier: 0 = полный профиль дороги вблизи, 1 и выше = только полотно
## (бордюры, тротуары, отбойники, разметка и водостоки с 200-400 м не видны,
## а стоят десятки тысяч треугольников в каждом городском чанке).
## Геометрия части сегментов сети - для пошаговой генерации чанка: порядок
## работы тот же, что в build_chunk(), поэтому результат не меняется.
func build_segment_slice(
	builder: MeshBuilder,
	segment_ids: PackedInt32Array,
	from_index: int,
	to_index: int,
	rect: Rect2,
	rng: RandomNumberGenerator,
	colliders: Array,
	detailed: bool
) -> void:
	if network == null:
		return
	for index in range(from_index, mini(to_index, segment_ids.size())):
		var segment := network.segments[segment_ids[index]]
		for run in _clip_segment(segment, rect):
			_add_ribbon(builder, segment, run, rng, colliders, detailed)


## Перекрёстки порциями (см. build_segment_slice).
func build_junction_slice(
	builder: MeshBuilder, node_ids: PackedInt32Array, from_index: int, to_index: int, rng: RandomNumberGenerator
) -> void:
	if network == null:
		return
	for index in range(from_index, mini(to_index, node_ids.size())):
		_add_intersection(builder, network.nodes[node_ids[index]], rng)


## Сегменты сети, влияющие на чанк, и его перекрёстки: список считается один раз,
## а строится по частям (см. build_segment_slice).
func collect_segments(rect: Rect2) -> PackedInt32Array:
	if network == null:
		return PackedInt32Array()
	var center := Vector3(rect.get_center().x, 0.0, rect.get_center().y)
	var radius := rect.size.length() * 0.5 + 20.0
	return network.segments_in_area(center, radius)


func collect_junctions(rect: Rect2) -> PackedInt32Array:
	var found := PackedInt32Array()
	if network == null:
		return found
	for node in network.nodes:
		if not node.is_junction:
			continue
		if not rect.has_point(Vector2(node.position.x, node.position.z)):
			continue
		found.append(node.id)
	return found


func build_chunk(builder: MeshBuilder, rect: Rect2, rng: RandomNumberGenerator, tier: int = 0) -> Array:
	var colliders := []
	if network == null:
		return colliders
	# 0 = ближний уровень (константы уровней живут в WorldGenerator; здесь
	# сравнение с нулём, чтобы у строителя дорог не было циклической зависимости)
	var detailed := tier <= 0
	var center := Vector3(rect.get_center().x, 0.0, rect.get_center().y)
	var radius := rect.size.length() * 0.5 + 20.0
	for segment_id in network.segments_in_area(center, radius):
		var segment := network.segments[segment_id]
		var runs := _clip_segment(segment, rect)
		for run in runs:
			_add_ribbon(builder, segment, run, rng, colliders, detailed)
	if not detailed:
		return colliders
	for node in network.nodes:
		if not node.is_junction:
			continue
		if not rect.has_point(Vector2(node.position.x, node.position.z)):
			continue
		_add_intersection(builder, node, rng)
	return colliders


## Samples a segment at a global 4 m step and returns the runs of points that
## stay inside (or just outside) the chunk rectangle.  The sampling grid is
## global, so neighbouring chunks produce identical vertices in the overlap and
## the seams never crack.
func _clip_segment(segment: RoadNetwork.Segment, rect: Rect2) -> Array:
	var runs := []
	var margin := SAMPLE_STEP * 1.5
	var expanded := rect.grow(margin)
	var total := segment.length
	if total <= 0.001:
		return runs
	var steps := int(ceil(total / SAMPLE_STEP))
	var current: Array[Vector3] = []
	for i in range(steps + 1):
		var distance := minf(float(i) * SAMPLE_STEP, total)
		var point := segment.point_at(distance)
		var inside := expanded.has_point(Vector2(point.x, point.z))
		if inside:
			current.append(point)
		else:
			if current.size() >= 2:
				runs.append(current)
			current = []
	if current.size() >= 2:
		runs.append(current)
	return runs


func _add_ribbon(
	builder: MeshBuilder,
	segment: RoadNetwork.Segment,
	points: Array,
	rng: RandomNumberGenerator,
	colliders: Array,
	detailed: bool = true
) -> void:
	var half_width := segment.width * 0.5
	# 7 см: шаг глубины на дистанции 400-600 м порядка 3 см, при меньшем
	# подъёме полотно и земля мерцали вдали (z-fighting).
	var deck_lift := 0.07
	var is_elevated := segment.elevated and segment.deck_height > 1.0
	var uv_period := 8.0
	if segment.type == RoadNetwork.RoadType.HIGHWAY:
		uv_period = 10.0
	elif segment.type == RoadNetwork.RoadType.DIRT:
		uv_period = 7.0

	# cross sections
	var distances := PackedFloat32Array()
	var matrix := []  # Packed arrays per section: [left, right, along, tangent]
	var travelled := 0.0
	for i in range(points.size()):
		var point: Vector3 = points[i]
		if i > 0:
			travelled += points[i - 1].distance_to(point)
		var tangent: Vector3 = (points[mini(i + 1, points.size() - 1)] - points[maxi(i - 1, 0)]).normalized()
		if tangent.length() < 0.001:
			tangent = Vector3.FORWARD
		var lateral := Vector3(-tangent.z, 0.0, tangent.x).normalized()
		# Высота точки дороги уже равна рельефу под ней: height_at() выравнивает
		# землю под полотно (в пределах half_width вес сглаживания равен единице),
		# поэтому повторный запрос рельефа на каждую точку полотна ничего не менял,
		# а стоил дороже всей остальной геометрии дороги (запрос - ~40 мкс на
		# точку, точек на чанк тысячи).
		var y := point.y + deck_lift
		matrix.append({
			"left": Vector3(point.x + lateral.x * half_width, y, point.z + lateral.z * half_width),
			"right": Vector3(point.x - lateral.x * half_width, y, point.z - lateral.z * half_width),
			"center": Vector3(point.x, y, point.z),
			"along": travelled,
			"lateral": lateral,
			"tangent": tangent,
		})

	for i in range(matrix.size() - 1):
		var a: Dictionary = matrix[i]
		var b: Dictionary = matrix[i + 1]
		var v0: float = float(a["along"]) / uv_period
		var v1: float = float(b["along"]) / uv_period
		builder.add_quad(
			segment.material,
			a["left"], b["left"], b["right"], a["right"],
			Color(0.94 + rng.randf() * 0.12, 0.94 + rng.randf() * 0.1, 0.94 + rng.randf() * 0.1),
			Vector2(0.0, v0), Vector2(0.0, v1), Vector2(1.0, v1), Vector2(1.0, v0),
			Vector3.UP
		)

	# Коллизия полотна: визуальная дорога раньше не имела физики вообще, и на
	# эстакадах (полотно выше земли на метры) машина проваливалась вниз, а на
	# насыпи ехала по земле под асфальтом.  Верхняя поверхность полотна
	# повторяет видимые квады один в один, поэтому колёса стоят точно на
	# асфальте и на мостах.
	var quads := matrix.size() - 1
	if quads > 0:
		var deck_faces := PackedVector3Array()
		deck_faces.resize(quads * 6)
		var write := 0
		for i in range(quads):
			var fa: Dictionary = matrix[i]
			var fb: Dictionary = matrix[i + 1]
			deck_faces[write] = fa["left"]
			deck_faces[write + 1] = fb["left"]
			deck_faces[write + 2] = fb["right"]
			deck_faces[write + 3] = fa["left"]
			deck_faces[write + 4] = fb["right"]
			deck_faces[write + 5] = fa["right"]
			write += 6
		colliders.append({
			"shape": "trimesh",
			"faces": deck_faces,
			"transform": Transform3D.IDENTITY,
		})

	if not detailed:
		return
	# kerbs + sidewalks (city) or gravel shoulders (rural / desert)
	var city_road := segment.type == RoadNetwork.RoadType.STREET or segment.type == RoadNetwork.RoadType.AVENUE
	var service_road := segment.type == RoadNetwork.RoadType.SERVICE
	if city_road or service_road:
		if is_elevated:
			_add_parapets(builder, matrix, rng)
		else:
			_add_kerbs_and_sidewalks(builder, matrix, segment, rng)
	elif is_elevated:
		_add_parapets(builder, matrix, rng)
		_add_piers(builder, matrix, colliders)
	else:
		_add_shoulders(builder, matrix, segment, rng)

	if segment.type == RoadNetwork.RoadType.HIGHWAY and not is_elevated:
		_add_median_and_guardrails(builder, matrix, rng)


func _add_kerbs_and_sidewalks(
	builder: MeshBuilder,
	matrix: Array,
	segment: RoadNetwork.Segment,
	rng: RandomNumberGenerator
) -> void:
	var half_width := segment.width * 0.5
	var sidewalk_width := config.sidewalk_width
	var kerb_height := 0.16
	var kerb_depth := 0.28
	for i in range(matrix.size() - 1):
		var a: Dictionary = matrix[i]
		var b: Dictionary = matrix[i + 1]
		var v0: float = float(a["along"])
		var v1: float = float(b["along"])
		for side in [1.0, -1.0]:
			var sign := float(side)
			var a_edge: Vector3 = a["center"] + (a["lateral"] as Vector3) * sign * half_width
			var b_edge: Vector3 = b["center"] + (b["lateral"] as Vector3) * sign * half_width
			var a_kerb := a_edge + Vector3(0.0, kerb_height, 0.0)
			var b_kerb := b_edge + Vector3(0.0, kerb_height, 0.0)
			# kerb top face
			var a_outer := a_edge + (a["lateral"] as Vector3) * sign * kerb_depth + Vector3(0.0, kerb_height, 0.0)
			var b_outer := b_edge + (b["lateral"] as Vector3) * sign * kerb_depth + Vector3(0.0, kerb_height, 0.0)
			var normal := ((a["lateral"] as Vector3) * sign).normalized()
			if sign > 0.0:
				builder.add_quad(
					"curb", a_kerb, b_kerb, b_outer, a_outer, Color(0.95, 0.95, 0.93),
					Vector2(0.0, v0 * 0.25), Vector2(0.0, v1 * 0.25),
					Vector2(1.0, v1 * 0.25), Vector2(1.0, v0 * 0.25), normal
				)
			else:
				builder.add_quad(
					"curb", b_outer, a_outer, a_kerb, b_kerb, Color(0.95, 0.95, 0.93),
					Vector2(1.0, v1 * 0.25), Vector2(1.0, v0 * 0.25),
					Vector2(0.0, v0 * 0.25), Vector2(0.0, v1 * 0.25), normal
				)
			# sidewalk slab
			var a_walk := a_outer + (a["lateral"] as Vector3) * sign * sidewalk_width
			var b_walk := b_outer + (b["lateral"] as Vector3) * sign * sidewalk_width
			if sign > 0.0:
				builder.add_quad(
					"sidewalk", a_outer, b_outer, b_walk, a_walk, Color(0.93 + rng.randf() * 0.12, 0.93, 0.92),
					Vector2(0.0, v0 * 0.25), Vector2(0.0, v1 * 0.25),
					Vector2(sidewalk_width, v1 * 0.25), Vector2(sidewalk_width, v0 * 0.25), Vector3.UP
				)
			else:
				builder.add_quad(
					"sidewalk", b_walk, a_walk, a_outer, b_outer, Color(0.93 + rng.randf() * 0.12, 0.93, 0.92),
					Vector2(sidewalk_width, v1 * 0.25), Vector2(sidewalk_width, v0 * 0.25),
					Vector2(0.0, v0 * 0.25), Vector2(0.0, v1 * 0.25), Vector3.UP
				)
			# curb face towards the road
			var a_face := a_edge
			var b_face := b_edge
			builder.add_quad(
				"curb",
				a_face, b_face, b_kerb, a_kerb,
				Color(0.88, 0.88, 0.86),
				Vector2(0.0, v0 * 0.25), Vector2(0.0, v1 * 0.25),
				Vector2(kerb_height * 4.0, v1 * 0.25), Vector2(kerb_height * 4.0, v0 * 0.25),
				-normal
			)


func _add_shoulders(
	builder: MeshBuilder,
	matrix: Array,
	segment: RoadNetwork.Segment,
	rng: RandomNumberGenerator
) -> void:
	var half_width := segment.width * 0.5
	var shoulder := 1.8 if segment.type != RoadNetwork.RoadType.DIRT else 1.2
	var material := "ground_gravel" if segment.surface != Surface.Type.SAND else "sand"
	for i in range(matrix.size() - 1):
		var a: Dictionary = matrix[i]
		var b: Dictionary = matrix[i + 1]
		var v0: float = float(a["along"])
		var v1: float = float(b["along"])
		for side in [1.0, -1.0]:
			var sign := float(side)
			var a_edge: Vector3 = a["center"] + (a["lateral"] as Vector3) * sign * half_width
			var b_edge: Vector3 = b["center"] + (b["lateral"] as Vector3) * sign * half_width
			var a_out := a_edge + (a["lateral"] as Vector3) * sign * shoulder
			var b_out := b_edge + (b["lateral"] as Vector3) * sign * shoulder
			# drape the shoulder onto the terrain so the road does not float
			a_out = Vector3(a_out.x, terrain.height_at(a_out.x, a_out.z) + 0.06, a_out.z)
			b_out = Vector3(b_out.x, terrain.height_at(b_out.x, b_out.z) + 0.06, b_out.z)
			if sign > 0.0:
				builder.add_quad(
					material, a_edge, b_edge, b_out, a_out, Color(0.92 + rng.randf() * 0.16, 0.92, 0.9),
					Vector2(0.0, v0 * 0.25), Vector2(0.0, v1 * 0.25),
					Vector2(shoulder, v1 * 0.25), Vector2(shoulder, v0 * 0.25), Vector3.UP
				)
			else:
				builder.add_quad(
					material, b_out, a_out, a_edge, b_edge, Color(0.92 + rng.randf() * 0.16, 0.92, 0.9),
					Vector2(shoulder, v1 * 0.25), Vector2(shoulder, v0 * 0.25),
					Vector2(0.0, v0 * 0.25), Vector2(0.0, v1 * 0.25), Vector3.UP
				)


func _add_parapets(builder: MeshBuilder, matrix: Array, rng: RandomNumberGenerator) -> void:
	var half_width := 0.0
	if matrix.size() > 0:
		half_width = (matrix[0]["center"] as Vector3).distance_to(matrix[0]["left"])
	var parapet_height := 1.0
	for i in range(matrix.size() - 1):
		var a: Dictionary = matrix[i]
		var b: Dictionary = matrix[i + 1]
		for side in [1.0, -1.0]:
			var sign := float(side)
			var a_pt: Vector3 = a["center"] + (a["lateral"] as Vector3) * sign * half_width
			var b_pt: Vector3 = b["center"] + (b["lateral"] as Vector3) * sign * half_width
			var a_top := a_pt + Vector3(0.0, parapet_height, 0.0)
			var b_top := b_pt + Vector3(0.0, parapet_height, 0.0)
			builder.add_box(
				"concrete_wall",
				Transform3D(Basis(Vector3.UP, atan2((b_pt - a_pt).x, (b_pt - a_pt).z)), (a_pt + b_pt) * 0.5 + Vector3(0.0, parapet_height * 0.5, 0.0)),
				Vector3(0.3, parapet_height, a_pt.distance_to(b_pt)), Color(0.94, 0.94, 0.93)
			)
			builder.add_box(
				"metal_grey",
				Transform3D(Basis(Vector3.UP, atan2((b_top - a_top).x, (b_top - a_top).z)), (a_top + b_top) * 0.5 + Vector3(0.0, 0.42, 0.0)),
				Vector3(0.14, 0.14, a_top.distance_to(b_top)), Color(0.9, 0.92, 0.94)
			)


func _add_piers(builder: MeshBuilder, matrix: Array, colliders: Array) -> void:
	var half_width := 0.0
	if matrix.size() > 0:
		half_width = (matrix[0]["center"] as Vector3).distance_to(matrix[0]["left"])
	var step := 5
	for i in range(0, matrix.size(), step):
		var section: Dictionary = matrix[i]
		var point: Vector3 = section["center"]
		var ground := terrain.base_height(point.x, point.z)
		var height := point.y - ground
		if height < 3.0:
			continue
		var lateral: Vector3 = section["lateral"]
		for side in [-0.55, 0.55]:
			var base := point + lateral * half_width * float(side)
			builder.add_box(
				"concrete",
				Transform3D(Basis(), Vector3(base.x, ground + height * 0.5, base.z)),
				Vector3(1.3, height, 1.3), Color(0.92, 0.92, 0.9)
			)
			colliders.append({
				"shape": "box",
				"transform": Transform3D(Basis(), Vector3(base.x, ground + height * 0.5, base.z)),
				"size": Vector3(1.3, height, 1.3),
			})
		# cross beam under the deck
		builder.add_box(
			"concrete",
			Transform3D(Basis(Vector3.UP, atan2(lateral.x, lateral.z)), Vector3(point.x, point.y - 0.55, point.z)),
			Vector3(half_width * 2.4, 0.9, 1.1), Color(0.9, 0.9, 0.88)
		)


func _add_median_and_guardrails(builder: MeshBuilder, matrix: Array, rng: RandomNumberGenerator) -> void:
	var half_width := 0.0
	if matrix.size() > 0:
		half_width = (matrix[0]["center"] as Vector3).distance_to(matrix[0]["left"])
	# guardrails along both edges
	var distance_accumulator := 0.0
	for i in range(matrix.size() - 1):
		var a: Dictionary = matrix[i]
		var b: Dictionary = matrix[i + 1]
		var a_pt: Vector3 = a["center"]
		var b_pt: Vector3 = b["center"]
		var length := a_pt.distance_to(b_pt)
		if length <= 0.01:
			continue
		distance_accumulator += length
		if distance_accumulator < 22.0:
			continue
		distance_accumulator = 0.0
		var tangent := (b_pt - a_pt).normalized()
		for side in [1.0, -1.0]:
			var lateral: Vector3 = (a["lateral"] as Vector3) * float(side)
			var start := a_pt + lateral * (half_width + 0.9)
			PropMeshes.guardrail(builder, start, tangent, 20.0, rng)
	# median barrier every so often
	if half_width > 8.0 and distance_accumulator < 12.0:
		var mid: Dictionary = matrix[matrix.size() / 2]
		var mid_point: Vector3 = mid["center"]
		PropMeshes.jersey_barrier(builder, Transform3D(Basis(Vector3.UP, atan2((mid["tangent"] as Vector3).x, (mid["tangent"] as Vector3).z)), mid_point), 6.0, rng)


## Junction patch + crosswalks so intersections read as real intersections.
func _add_intersection(builder: MeshBuilder, node: RoadNetwork.RoadNode, rng: RandomNumberGenerator) -> void:
	var max_width := 0.0
	for segment_id in node.segments:
		max_width = maxf(max_width, network.segments[segment_id].width)
	var size := max_width + 6.0
	var y := terrain.height_at(node.position.x, node.position.z) + 0.09
	var corners := [
		Vector3(-size * 0.5, 0.0, -size * 0.5),
		Vector3(size * 0.5, 0.0, -size * 0.5),
		Vector3(size * 0.5, 0.0, size * 0.5),
		Vector3(-size * 0.5, 0.0, size * 0.5),
	]
	var center := Vector3(node.position.x, y, node.position.z)
	var uv_scale := 0.08
	builder.add_quad(
		"road_asphalt",
		center + corners[3], center + corners[2], center + corners[1], center + corners[0],
		Color(0.95, 0.95, 0.95),
		Vector2(0, 0), Vector2(size * uv_scale, 0), Vector2(size * uv_scale, size * uv_scale), Vector2(0, size * uv_scale),
		Vector3.UP
	)
	# crosswalks on urban junctions
	var urban := terrain.urban_at(node.position.x, node.position.z) > 0.35
	if not urban:
		return
	for segment_id in node.segments:
		var segment := network.segments[segment_id]
		if segment.type == RoadNetwork.RoadType.DIRT or segment.elevated:
			continue
		var direction: Vector3 = segment.tangent_at(0.0) if node.position.distance_to(segment.points[0]) < 4.0 else -segment.tangent_at(segment.length)
		var lateral := Vector3(-direction.z, 0.0, direction.x).normalized()
		var stripes := int(maxf(segment.width / 1.15, 3.0))
		for i in range(stripes):
			var offset := (float(i) - float(stripes - 1) * 0.5) * 1.15
			var stripe_center := Vector3(node.position.x, terrain.height_at(node.position.x, node.position.z) + 0.11, node.position.z) + direction * (segment.width * 0.5 + 1.4) + lateral * offset
			builder.add_quad(
				"marking_white",
				stripe_center - lateral * 0.32 - direction * 0.45,
				stripe_center + lateral * 0.32 - direction * 0.45,
				stripe_center + lateral * 0.32 + direction * 0.45,
				stripe_center - lateral * 0.32 + direction * 0.45,
				Color(0.98, 0.98, 0.95),
				Vector2.ZERO, Vector2(0.64, 0), Vector2(0.64, 0.9), Vector2(0, 0.9),
				Vector3.UP
			)
