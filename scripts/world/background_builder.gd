class_name BackgroundBuilder
extends RefCounted

## The world does not end at the streaming radius: this builder creates one
## static, very cheap "background shell" that is generated once at startup and
## never touched again:
##   * a coarse terrain mesh out to ~2.4 km (sampled from the same height field,
##     so the horizon matches the streamed terrain),
##   * a distant skyline of the city (simple boxes, unshaded, no shadows),
##   * a few landmark silhouettes (water tower, masts) that read from far away.
##
## Total cost is a couple of thousand triangles, which is nothing next to one
## streamed chunk, but it removes the "the world is a tiny bubble" feeling.

const STEP := 48.0
const INNER_RADIUS := 700.0
const OUTER_RADIUS := 2400.0

var terrain: TerrainField
var region_map: RegionMap


func _init(world_terrain: TerrainField, world_regions: RegionMap) -> void:
	terrain = world_terrain
	region_map = world_regions


func build() -> Dictionary:
	var builder := MeshBuilder.new()
	_build_shell(builder)
	# Силуэт города НЕ запекается в меш подложки: это десятки одинаковых коробок
	# одного материала, поэтому они отдаются как MultiMesh (одна геометрия и один
	# вызов отрисовки вместо тридцати четырёх копий в вершинном буфере).
	var skyline := _skyline_transforms()
	var triangles := builder.triangle_count
	return {
		"mesh": builder.commit(),
		"triangles": triangles,
		"skyline_buildings": skyline.size(),
		"skyline_transforms": skyline,
		"skyline_mesh": skyline_mesh(),
	}


## Единичный куб для MultiMesh: размер каждой высотки задаётся масштабом в её
## трансформации, поэтому вся геометрия силуэта - это 12 треугольников.
static func skyline_mesh() -> Mesh:
	var builder := MeshBuilder.new()
	builder.add_box("city_silhouette", Transform3D(), Vector3.ONE, Color(0.30, 0.33, 0.40))
	return builder.commit()


## Ring of terrain between INNER_RADIUS and OUTER_RADIUS.  The inner edge is not
## drawn exactly from the streaming radius (a small overlap is hidden by fog).
func _build_shell(builder: MeshBuilder) -> void:
	var rings := int(ceil((OUTER_RADIUS - INNER_RADIUS) / STEP))
	var segments := 128
	for ring in range(rings):
		var r0 := INNER_RADIUS + float(ring) * STEP
		var r1 := minf(r0 + STEP, OUTER_RADIUS)
		var fade := clampf((r0 - INNER_RADIUS) / 400.0, 0.0, 1.0)
		for segment in range(segments):
			var a0 := TAU * float(segment) / float(segments)
			var a1 := TAU * float(segment + 1) / float(segments)
			var p00 := _point(r0, a0)
			var p10 := _point(r1, a0)
			var p11 := _point(r1, a1)
			var p01 := _point(r0, a1)
			builder.add_quad("terrain_background", p00, p01, p11, p10, _color_at(p00, fade))


func _point(radius: float, angle: float) -> Vector3:
	var x := cos(angle) * radius
	var z := sin(angle) * radius
	return Vector3(x, terrain.height_at(x, z), z)


func _color_at(point: Vector3, fade: float) -> Color:
	var region := region_map.region_at(point)
	var base := Color(0.36, 0.42, 0.24)
	match region:
		RegionMap.Region.DESERT:
			base = Color(0.72, 0.62, 0.42)
		RegionMap.Region.FOREST:
			base = Color(0.22, 0.31, 0.18)
		RegionMap.Region.CITY_CORE, RegionMap.Region.CITY, RegionMap.Region.SUBURB:
			base = Color(0.42, 0.42, 0.41)
	# the farther away, the more the geometry blends into the fog colour
	return base.lerp(Color(0.62, 0.68, 0.76), fade * 0.55)


## Трансформации высоток дальнего силуэта (позиция, поворот и масштаб-размер).
func _skyline_transforms() -> Array:
	var rng := MathUtils.rng_for(Vector2i(999, 999), 7)
	var center := Vector2.ZERO
	if region_map != null and region_map.config != null:
		center = Vector2(0.0, 0.0)
	var skyline: Array = []
	for i in range(34):
		var angle := rng.randf() * TAU
		var radius := rng.randf_range(120.0, 900.0)
		var x := center.x + cos(angle) * radius
		var z := center.y + sin(angle) * radius
		var ground := terrain.height_at(x, z)
		var height := rng.randf_range(34.0, 96.0) * clampf(1.0 - radius / 1100.0, 0.35, 1.0)
		var width := rng.randf_range(18.0, 34.0)
		var size := Vector3(width, height, width * rng.randf_range(0.8, 1.4))
		var basis := Basis(Vector3.UP, rng.randf() * TAU).scaled(size)
		skyline.append(Transform3D(basis, Vector3(x, ground + height * 0.5, z)))
	return skyline


## A single landmark silhouette (used for the water tower and radio masts that
## can be seen from far away).
static func build_landmark(builder: MeshBuilder, kind: String, position: Vector3) -> void:
	match kind:
		"water_tower":
			for i in range(4):
				var angle := TAU * float(i) / 4.0 + PI * 0.25
				var offset := Vector3(cos(angle) * 3.4, 9.0, sin(angle) * 3.4)
				builder.add_box("structure_metal", Transform3D(Basis(), position + offset), Vector3(0.5, 18.0, 0.5))
			builder.add_cylinder(
				"landmark_water_tank",
				Transform3D(Basis(), position + Vector3(0.0, 21.5, 0.0)),
				4.6, 4.6, 7.5, 12
			)
		"radio_mast":
			builder.add_cylinder("structure_metal", Transform3D(Basis(), position + Vector3(0.0, 22.0, 0.0)), 0.6, 0.6, 44.0, 8)
			builder.add_box("siren_light_red", Transform3D(Basis(), position + Vector3(0.0, 44.5, 0.0)), Vector3(0.4, 0.4, 0.4))
		"sign":
			builder.add_box("structure_metal", Transform3D(Basis(), position + Vector3(0.0, 3.0, 0.0)), Vector3(0.35, 6.0, 0.35))
			builder.add_box("sign_blue", Transform3D(Basis(), position + Vector3(0.0, 7.0, 0.0)), Vector3(6.0, 2.4, 0.25))
		_:
			builder.add_box("city_silhouette", Transform3D(Basis(), position + Vector3(0.0, 6.0, 0.0)), Vector3(6.0, 12.0, 6.0))
