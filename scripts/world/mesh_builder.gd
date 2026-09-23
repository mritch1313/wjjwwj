class_name MeshBuilder
extends RefCounted

## Low level procedural geometry toolkit used by every visual factory
## (buildings, scenery, cars, landmarks, roads).
##
## * One builder collects several *material groups*; commit() returns a single
##   ArrayMesh with one surface per material.  That keeps draw calls low on
##   mobile: a whole city block becomes 4-8 surfaces instead of hundreds of nodes.
## * Geometry is written straight into vertex arrays (no SurfaceTool round trip),
##   which makes generation fast enough to run on the phone and makes merging
##   several builders into one mesh trivial.
## * Normals are written explicitly (no smoothing pass) so hard surface edges
##   stay crisp, and the result is deterministic for a given seed.
## * Per vertex colours carry albedo variation; with vertex_color_use_as_albedo
##   enabled they give cheap visual diversity without extra materials.

var triangle_count: int = 0
var vertex_count: int = 0

var _groups: Dictionary = {}


func is_empty() -> bool:
	return _groups.is_empty()


func material_names() -> Array:
	return _groups.keys()


func _group(material_name: String) -> Array:
	if not _groups.has(material_name):
		_groups[material_name] = [
			PackedVector3Array(),  # vertices
			PackedVector3Array(),  # normals
			PackedColorArray(),    # colors
			PackedVector2Array(),  # uvs
		]
	return _groups[material_name]


func _vertex(group: Array, position: Vector3, normal: Vector3, uv: Vector2, color: Color) -> void:
	# Packed arrays are value types: `group[0].push_back(x)` or a bare `as` cast
	# would push into a *copy* and the surface would stay empty.  Write the local
	# copy back into the group array instead.
	var vertices: PackedVector3Array = group[0]
	var normals: PackedVector3Array = group[1]
	var colors: PackedColorArray = group[2]
	var uvs: PackedVector2Array = group[3]
	vertices.push_back(position)
	normals.push_back(normal)
	colors.push_back(color)
	uvs.push_back(uv)
	group[0] = vertices
	group[1] = normals
	group[2] = colors
	group[3] = uvs
	vertex_count += 1


## Quad a-b-c-d (counter clockwise when seen from the normal side).
func add_quad(
	material_name: String,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	d: Vector3,
	color: Color = Color.WHITE,
	uv_a: Vector2 = Vector2.ZERO,
	uv_b: Vector2 = Vector2.RIGHT,
	uv_c: Vector2 = Vector2.ONE,
	uv_d: Vector2 = Vector2.DOWN,
	normal: Vector3 = Vector3.UP
) -> void:
	var group := _group(material_name)
	_vertex(group, a, normal, uv_a, color)
	_vertex(group, b, normal, uv_b, color)
	_vertex(group, c, normal, uv_c, color)
	_vertex(group, a, normal, uv_a, color)
	_vertex(group, c, normal, uv_c, color)
	_vertex(group, d, normal, uv_d, color)
	triangle_count += 2


func add_triangle(
	material_name: String,
	a: Vector3,
	b: Vector3,
	c: Vector3,
	color: Color = Color.WHITE,
	uv_a: Vector2 = Vector2.ZERO,
	uv_b: Vector2 = Vector2.RIGHT,
	uv_c: Vector2 = Vector2.ONE,
	normal: Vector3 = Vector3.ZERO
) -> void:
	var resolved := normal
	if resolved.length_squared() < 0.0000001:
		resolved = (b - a).cross(c - a)
	resolved = Vector3.UP if resolved.length_squared() < 0.0000001 else resolved.normalized()
	var group := _group(material_name)
	_vertex(group, a, resolved, uv_a, color)
	_vertex(group, b, resolved, uv_b, color)
	_vertex(group, c, resolved, uv_c, color)
	triangle_count += 1


## Axis aligned (optionally rotated/scaled) box with per-face UV projection.
func add_box(
	material_name: String,
	transform: Transform3D,
	size: Vector3,
	color: Color = Color.WHITE,
	uv_scale: Vector2 = Vector2(0.25, 0.25),
	top_material: String = "",
	bottom_material: String = "",
	skip_bottom: bool = false
) -> void:
	var hx := size.x * 0.5
	var hy := size.y * 0.5
	var hz := size.z * 0.5
	var top := material_name if top_material.is_empty() else top_material
	var bottom := material_name if bottom_material.is_empty() else bottom_material
	var u_res := Vector2(size.x, size.z) * uv_scale
	var s_res := Vector2(size.z, size.y) * uv_scale
	var f_res := Vector2(size.x, size.y) * uv_scale

	var p_top := func(x: float, z: float) -> Vector3: return transform * Vector3(x * hx, hy, z * hz)
	add_quad(
		top, p_top.call(-1, -1), p_top.call(-1, 1), p_top.call(1, 1), p_top.call(1, -1),
		color, Vector2.ZERO, Vector2(0, u_res.y), Vector2(u_res.x, u_res.y), Vector2(u_res.x, 0), Vector3.UP
	)
	if not skip_bottom:
		var p_bottom := func(x: float, z: float) -> Vector3: return transform * Vector3(x * hx, -hy, z * hz)
		add_quad(
			bottom, p_bottom.call(-1, 1), p_bottom.call(-1, -1), p_bottom.call(1, -1), p_bottom.call(1, 1),
			color, Vector2.ZERO, Vector2(0, u_res.y), Vector2(u_res.x, u_res.y), Vector2(u_res.x, 0), Vector3.DOWN
		)
	var p_x_pos := func(y: float, z: float) -> Vector3: return transform * Vector3(hx, y * hy, z * hz)
	add_quad(
		material_name, p_x_pos.call(1, -1), p_x_pos.call(1, 1), p_x_pos.call(-1, 1), p_x_pos.call(-1, -1),
		color, Vector2.ZERO, Vector2(0, s_res.y), Vector2(s_res.x, s_res.y), Vector2(s_res.x, 0),
		(transform.basis * Vector3.RIGHT).normalized()
	)
	var p_x_neg := func(y: float, z: float) -> Vector3: return transform * Vector3(-hx, y * hy, z * hz)
	add_quad(
		material_name, p_x_neg.call(-1, 1), p_x_neg.call(-1, -1), p_x_neg.call(1, -1), p_x_neg.call(1, 1),
		color, Vector2.ZERO, Vector2(0, s_res.y), Vector2(s_res.x, s_res.y), Vector2(s_res.x, 0),
		(transform.basis * Vector3.LEFT).normalized()
	)
	var p_z_pos := func(x: float, y: float) -> Vector3: return transform * Vector3(x * hx, y * hy, hz)
	add_quad(
		material_name, p_z_pos.call(1, -1), p_z_pos.call(1, 1), p_z_pos.call(-1, 1), p_z_pos.call(-1, -1),
		color, Vector2.ZERO, Vector2(0, f_res.y), Vector2(f_res.x, f_res.y), Vector2(f_res.x, 0),
		(transform.basis * Vector3.BACK).normalized()
	)
	var p_z_neg := func(x: float, y: float) -> Vector3: return transform * Vector3(x * hx, y * hy, -hz)
	add_quad(
		material_name, p_z_neg.call(-1, 1), p_z_neg.call(-1, -1), p_z_neg.call(1, -1), p_z_neg.call(1, 1),
		color, Vector2.ZERO, Vector2(0, f_res.y), Vector2(f_res.x, f_res.y), Vector2(f_res.x, 0),
		(transform.basis * Vector3.FORWARD).normalized()
	)


## Cone / tapered cylinder / cylinder.  radius_top 0 gives a cone.
func add_cylinder(
	material_name: String,
	transform: Transform3D,
	radius_bottom: float,
	radius_top: float,
	height: float,
	segments: int = 8,
	color: Color = Color.WHITE,
	uv_scale: Vector2 = Vector2(0.25, 0.25),
	cap_top: bool = true,
	cap_bottom: bool = false,
	smooth: bool = true
) -> void:
	var seg := maxi(segments, 3)
	var circumference := TAU * maxf(radius_bottom, radius_top)
	var group := _group(material_name)
	for i in range(seg):
		var a0 := TAU * float(i) / float(seg)
		var a1 := TAU * float(i + 1) / float(seg)
		var n0 := Vector3(cos(a0), 0.0, sin(a0))
		var n1 := Vector3(cos(a1), 0.0, sin(a1))
		var p0b := transform * Vector3(n0.x * radius_bottom, -height * 0.5, n0.z * radius_bottom)
		var p1b := transform * Vector3(n1.x * radius_bottom, -height * 0.5, n1.z * radius_bottom)
		var p0t := transform * Vector3(n0.x * radius_top, height * 0.5, n0.z * radius_top)
		var p1t := transform * Vector3(n1.x * radius_top, height * 0.5, n1.z * radius_top)
		var u0 := circumference * float(i) / float(seg) * uv_scale.x
		var u1 := circumference * float(i + 1) / float(seg) * uv_scale.x
		if smooth:
			var n0w := (transform.basis * n0).normalized()
			var n1w := (transform.basis * n1).normalized()
			_vertex(group, p0b, n0w, Vector2(u0, 0.0), color)
			_vertex(group, p1b, n1w, Vector2(u1, 0.0), color)
			_vertex(group, p1t, n1w, Vector2(u1, height * uv_scale.y), color)
			_vertex(group, p0b, n0w, Vector2(u0, 0.0), color)
			_vertex(group, p1t, n1w, Vector2(u1, height * uv_scale.y), color)
			_vertex(group, p0t, n0w, Vector2(u0, height * uv_scale.y), color)
			triangle_count += 2
		else:
			add_quad(
				material_name, p0b, p1b, p1t, p0t, color,
				Vector2(u0, 0.0), Vector2(u1, 0.0),
				Vector2(u1, height * uv_scale.y), Vector2(u0, height * uv_scale.y),
				(transform.basis * ((n0 + n1) * 0.5).normalized()).normalized()
			)
	if cap_top and radius_top > 0.0001:
		var center_top := transform * Vector3(0.0, height * 0.5, 0.0)
		for i in range(seg):
			var a0 := TAU * float(i) / float(seg)
			var a1 := TAU * float(i + 1) / float(seg)
			var n0 := Vector3(cos(a0), 0.0, sin(a0))
			var n1 := Vector3(cos(a1), 0.0, sin(a1))
			add_triangle(
				material_name,
				center_top,
				transform * Vector3(n0.x * radius_top, height * 0.5, n0.z * radius_top),
				transform * Vector3(n1.x * radius_top, height * 0.5, n1.z * radius_top),
				color, Vector2.ZERO,
				Vector2(n0.x * radius_top, n0.z * radius_top) * uv_scale,
				Vector2(n1.x * radius_top, n1.z * radius_top) * uv_scale
			)
	if cap_bottom and radius_bottom > 0.0001:
		var center_bottom := transform * Vector3(0.0, -height * 0.5, 0.0)
		for i in range(seg):
			var a0 := TAU * float(i) / float(seg)
			var a1 := TAU * float(i + 1) / float(seg)
			var n0 := Vector3(cos(a0), 0.0, sin(a0))
			var n1 := Vector3(cos(a1), 0.0, sin(a1))
			add_triangle(
				material_name,
				center_bottom,
				transform * Vector3(n1.x * radius_bottom, -height * 0.5, n1.z * radius_bottom),
				transform * Vector3(n0.x * radius_bottom, -height * 0.5, n0.z * radius_bottom),
				color, Vector2.ZERO,
				Vector2(n1.x * radius_bottom, n1.z * radius_bottom) * uv_scale,
				Vector2(n0.x * radius_bottom, n0.z * radius_bottom) * uv_scale
			)


## Horizontal tube - used for power lines, guardrails and tower braces.
func add_tube(
	material_name: String,
	transform: Transform3D,
	radius: float,
	length: float,
	segments: int = 6,
	color: Color = Color.WHITE,
	uv_scale: Vector2 = Vector2(0.3, 0.3),
	caps: bool = true
) -> void:
	add_cylinder(material_name, transform, radius, radius, length, segments, color, uv_scale, caps, caps, true)


## Extrudes a 2D footprint (local XZ plane) into a prism - used for L shaped
## buildings and irregular props.  Points must be ordered counter clockwise.
func add_prism(
	material_name: String,
	transform: Transform3D,
	points: PackedVector2Array,
	height: float,
	color: Color = Color.WHITE,
	uv_scale: Vector2 = Vector2(0.25, 0.25),
	top_material: String = "",
	cap_top: bool = true
) -> void:
	if points.size() < 3:
		return
	var half := height * 0.5
	for i in range(points.size()):
		var a := points[i]
		var b := points[(i + 1) % points.size()]
		var edge := b - a
		var normal := (transform.basis * Vector3(edge.y, 0.0, -edge.x)).normalized()
		var len_uv := edge.length() * uv_scale.x
		add_quad(
			material_name,
			transform * Vector3(a.x, -half, a.y), transform * Vector3(b.x, -half, b.y),
			transform * Vector3(b.x, half, b.y), transform * Vector3(a.x, half, a.y),
			color, Vector2.ZERO, Vector2(len_uv, 0.0),
			Vector2(len_uv, height * uv_scale.y), Vector2(0.0, height * uv_scale.y),
			normal
		)
	if cap_top:
		var center := Vector2.ZERO
		for point in points:
			center += point
		center /= float(points.size())
		var top_mat := material_name if top_material.is_empty() else top_material
		for i in range(points.size()):
			var a := points[i]
			var b := points[(i + 1) % points.size()]
			add_triangle(
				top_mat,
				transform * Vector3(center.x, half, center.y),
				transform * Vector3(a.x, half, a.y),
				transform * Vector3(b.x, half, b.y),
				color,
				Vector2(center.x, center.y) * uv_scale,
				Vector2(a.x, a.y) * uv_scale,
				Vector2(b.x, b.y) * uv_scale
			)


## Gable (triangular) roof.  size.y is the roof height above the eaves.
func add_gable_roof(
	material_name: String,
	transform: Transform3D,
	size: Vector3,
	color: Color = Color.WHITE,
	uv_scale: Vector2 = Vector2(0.25, 0.25)
) -> void:
	var hx := size.x * 0.5
	var hy := size.y
	var hz := size.z * 0.5
	var slope_len := sqrt(hx * hx + hy * hy)
	var slope_uv := slope_len * uv_scale.x
	var depth_uv := size.z * uv_scale.y
	add_quad(
		material_name,
		transform * Vector3(-hx, 0.0, -hz), transform * Vector3(-hx, 0.0, hz),
		transform * Vector3(0.0, hy, hz), transform * Vector3(0.0, hy, -hz),
		color, Vector2.ZERO, Vector2(0, depth_uv), Vector2(slope_uv, depth_uv), Vector2(slope_uv, 0),
		(transform.basis * Vector3(-hy, hx, 0.0)).normalized()
	)
	add_quad(
		material_name,
		transform * Vector3(hx, 0.0, hz), transform * Vector3(hx, 0.0, -hz),
		transform * Vector3(0.0, hy, -hz), transform * Vector3(0.0, hy, hz),
		color, Vector2.ZERO, Vector2(0, depth_uv), Vector2(slope_uv, depth_uv), Vector2(slope_uv, 0),
		(transform.basis * Vector3(hy, hx, 0.0)).normalized()
	)
	add_triangle(
		material_name, transform * Vector3(-hx, 0, -hz), transform * Vector3(hx, 0, -hz), transform * Vector3(0, hy, -hz),
		color, Vector2.ZERO, Vector2(size.x * uv_scale.x, 0),
		Vector2(size.x * uv_scale.x * 0.5, size.y * uv_scale.y)
	)
	add_triangle(
		material_name, transform * Vector3(hx, 0, hz), transform * Vector3(-hx, 0, hz), transform * Vector3(0, hy, hz),
		color, Vector2.ZERO, Vector2(size.x * uv_scale.x, 0),
		Vector2(size.x * uv_scale.x * 0.5, size.y * uv_scale.y)
	)


## Pyramid / hip roof.  ridge_ratio 0 = pyramid, 0.8 = long ridge.
func add_hip_roof(
	material_name: String,
	transform: Transform3D,
	size: Vector3,
	ridge_ratio: float = 0.0,
	color: Color = Color.WHITE,
	uv_scale: Vector2 = Vector2(0.25, 0.25)
) -> void:
	var hx := size.x * 0.5
	var hy := size.y
	var hz := size.z * 0.5
	var ridge := hz * clampf(ridge_ratio, 0.0, 0.9)
	var slope_u := sqrt(hx * hx + hy * hy) * uv_scale.x
	var ridge_len := hz - ridge
	var side_uv := sqrt(ridge_len * ridge_len + hy * hy) * uv_scale.x
	var normal_left := (transform.basis * Vector3(-hy, hx, 0.0)).normalized()
	var normal_right := (transform.basis * Vector3(hy, hx, 0.0)).normalized()
	if ridge > 0.01:
		add_quad(
			material_name,
			transform * Vector3(-hx, 0.0, -hz), transform * Vector3(-hx, 0.0, hz),
			transform * Vector3(0.0, hy, ridge), transform * Vector3(0.0, hy, -ridge),
			color, Vector2.ZERO, Vector2(0, size.z * uv_scale.y),
			Vector2(side_uv, size.z * uv_scale.y), Vector2(side_uv, 0), normal_left
		)
		add_quad(
			material_name,
			transform * Vector3(hx, 0.0, hz), transform * Vector3(hx, 0.0, -hz),
			transform * Vector3(0.0, hy, -ridge), transform * Vector3(0.0, hy, ridge),
			color, Vector2.ZERO, Vector2(0, size.z * uv_scale.y),
			Vector2(side_uv, size.z * uv_scale.y), Vector2(side_uv, 0), normal_right
		)
	else:
		add_triangle(material_name, transform * Vector3(-hx, 0, -hz), transform * Vector3(-hx, 0, hz), transform * Vector3(0, hy, 0),
			color, Vector2.ZERO, Vector2(0, size.z * uv_scale.y), Vector2(slope_u, size.z * uv_scale.y * 0.5), normal_left)
		add_triangle(material_name, transform * Vector3(hx, 0, hz), transform * Vector3(hx, 0, -hz), transform * Vector3(0, hy, 0),
			color, Vector2.ZERO, Vector2(0, size.z * uv_scale.y), Vector2(slope_u, size.z * uv_scale.y * 0.5), normal_right)
	add_triangle(
		material_name, transform * Vector3(hx, 0, hz), transform * Vector3(-hx, 0, hz), transform * Vector3(0, hy, ridge),
		color, Vector2.ZERO, Vector2(size.x * uv_scale.x, 0),
		Vector2(size.x * uv_scale.x * 0.5, size.y * uv_scale.y)
	)
	add_triangle(
		material_name, transform * Vector3(-hx, 0, -hz), transform * Vector3(hx, 0, -hz), transform * Vector3(0, hy, -ridge),
		color, Vector2.ZERO, Vector2(size.x * uv_scale.x, 0),
		Vector2(size.x * uv_scale.x * 0.5, size.y * uv_scale.y)
	)


## Crossed alpha tested planes - the cheap way to get dense foliage and bushes.
## `planes` = 2 (cross) or 3 (star).  Material must use alpha scissor.
func add_foliage_planes(
	material_name: String,
	transform: Transform3D,
	size: Vector2,
	planes: int = 2,
	color: Color = Color.WHITE,
	uv_offset: Vector2 = Vector2.ZERO,
	uv_scale: Vector2 = Vector2.ONE
) -> void:
	var count := maxi(planes, 1)
	var half_w := size.x * 0.5
	for i in range(count):
		var angle := PI * float(i) / float(count)
		var local := transform * Transform3D(Basis(Vector3.UP, angle), Vector3.ZERO)
		var uv_a := uv_offset
		var uv_b := uv_offset + Vector2(uv_scale.x, 0.0)
		var uv_c := uv_offset + uv_scale
		var uv_d := uv_offset + Vector2(0.0, uv_scale.y)
		add_quad(
			material_name,
			local * Vector3(-half_w, 0.0, 0.0), local * Vector3(half_w, 0.0, 0.0),
			local * Vector3(half_w, size.y, 0.0), local * Vector3(-half_w, size.y, 0.0),
			color, uv_a, uv_b, uv_c, uv_d, (local.basis * Vector3.FORWARD).normalized()
		)


## A billboard quad (signs, ads).  Optionally double sided.
func add_billboard(
	material_name: String,
	transform: Transform3D,
	size: Vector2,
	color: Color = Color.WHITE,
	double_sided: bool = false,
	uv_offset: Vector2 = Vector2.ZERO,
	uv_scale: Vector2 = Vector2.ONE
) -> void:
	var half_w := size.x * 0.5
	var half_h := size.y * 0.5
	var normal := (transform.basis * Vector3.FORWARD).normalized()
	add_quad(
		material_name,
		transform * Vector3(-half_w, -half_h, 0.0), transform * Vector3(half_w, -half_h, 0.0),
		transform * Vector3(half_w, half_h, 0.0), transform * Vector3(-half_w, half_h, 0.0),
		color,
		uv_offset + Vector2(0, uv_scale.y), uv_offset + Vector2(uv_scale.x, uv_scale.y),
		uv_offset + uv_scale, uv_offset + Vector2(0, 0), normal
	)
	if double_sided:
		add_quad(
			material_name,
			transform * Vector3(half_w, -half_h, 0.0), transform * Vector3(-half_w, -half_h, 0.0),
			transform * Vector3(-half_w, half_h, 0.0), transform * Vector3(half_w, half_h, 0.0),
			color,
			uv_offset + Vector2(uv_scale.x, uv_scale.y), uv_offset + Vector2(0, uv_scale.y),
			uv_offset, uv_offset + Vector2(uv_scale.x, 0), -normal
		)


## Deformed low poly boulder (octahedron split once, vertices jittered).
func add_rock(
	material_name: String,
	transform: Transform3D,
	radius: float,
	rng: RandomNumberGenerator,
	color: Color = Color.WHITE,
	uv_scale: Vector2 = Vector2(0.4, 0.4)
) -> void:
	var base: Array[Vector3] = [
		Vector3(1, 0, 0), Vector3(-1, 0, 0), Vector3(0, 1, 0),
		Vector3(0, -1, 0), Vector3(0, 0, 1), Vector3(0, 0, -1),
	]
	var faces: Array = [
		[base[0], base[2], base[4]], [base[2], base[1], base[4]],
		[base[1], base[3], base[4]], [base[3], base[0], base[4]],
		[base[2], base[0], base[5]], [base[1], base[2], base[5]],
		[base[3], base[1], base[5]], [base[0], base[3], base[5]],
	]
	var jitter := 0.45
	var offsets: Dictionary = {}
	for face in faces:
		for vertex in (face as Array):
			var key: String = str((vertex as Vector3).snapped(Vector3(0.001, 0.001, 0.001)))
			if not offsets.has(key):
				offsets[key] = Vector3(
					rng.randf_range(-jitter, jitter),
					rng.randf_range(-jitter * 0.5, jitter * 0.5),
					rng.randf_range(-jitter, jitter)
				)
	for face in faces:
		var tri: Array = face
		var points: Array[Vector3] = []
		for vertex in tri:
			var v: Vector3 = vertex
			var key: String = str(v.snapped(Vector3(0.001, 0.001, 0.001)))
			var offset: Vector3 = offsets[key]
			var scaled: Vector3 = (v + offset).normalized() * (radius * rng.randf_range(0.88, 1.14))
			points.append(transform * scaled)
		add_triangle(
			material_name, points[0], points[1], points[2], color,
			Vector2(points[0].x, points[0].z) * uv_scale,
			Vector2(points[1].x, points[1].z) * uv_scale,
			Vector2(points[2].x, points[2].z) * uv_scale
		)


## Merges another builder's geometry into this one (chunk assembly).
func append_builder(other: MeshBuilder) -> void:
	if other == null:
		return
	for material_name in other._groups.keys():
		var source: Array = other._groups[material_name]
		var target := _group(String(material_name))
		var vertices: PackedVector3Array = target[0]
		var normals: PackedVector3Array = target[1]
		var colors: PackedColorArray = target[2]
		var uvs: PackedVector2Array = target[3]
		vertices.append_array(source[0])
		normals.append_array(source[1])
		colors.append_array(source[2])
		uvs.append_array(source[3])
		target[0] = vertices
		target[1] = normals
		target[2] = colors
		target[3] = uvs
	triangle_count += other.triangle_count
	vertex_count += other.vertex_count


## Finalises all material groups into one ArrayMesh with one surface each.
func commit() -> ArrayMesh:
	if _groups.is_empty():
		return null
	var mesh := ArrayMesh.new()
	for material_name in _groups.keys():
		var group: Array = _groups[material_name]
		var vertices: PackedVector3Array = group[0]
		if vertices.is_empty():
			continue
		var arrays: Array = []
		arrays.resize(Mesh.ARRAY_MAX)
		arrays[Mesh.ARRAY_VERTEX] = vertices
		arrays[Mesh.ARRAY_NORMAL] = group[1]
		arrays[Mesh.ARRAY_COLOR] = group[2]
		arrays[Mesh.ARRAY_TEX_UV] = group[3]
		var surface_index := mesh.get_surface_count()
		mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
		mesh.surface_set_material(surface_index, Assets.material(String(material_name)))
	_groups.clear()
	return mesh
