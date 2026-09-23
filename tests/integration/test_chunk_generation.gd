extends TestCase

## Integration: the streamed world (WorldGenerator -> WorldChunk) must produce
## real geometry - terrain, roads, buildings and props - with colliders, and two
## neighbouring chunks must agree on the height at their shared edge (no seams).

var generator: WorldGenerator
var config: WorldConfig


func before_all() -> void:
	generator = WorldFixture.generator()
	config = WorldFixture.config()


func test_chunk_has_layered_geometry_and_colliders() -> void:
	var cell := Vector2i(10, 10)  # city centre chunk
	var result := generator.generate_chunk(cell, WorldGenerator.TIER_NEAR)
	assert_true(result.has("meshes"), "чанк возвращает меши по слоям")
	var meshes: Array = result["meshes"]
	assert_eq(meshes.size(), 4, "четыре слоя: рельеф, дороги, строения, растительность")
	var terrain_mesh: Mesh = meshes[0]
	assert_ne(terrain_mesh, null, "рельефный слой не пуст")
	var triangle_total := 0
	for mesh in meshes:
		if mesh is ArrayMesh:
			for surface in range((mesh as ArrayMesh).get_surface_count()):
				var arrays: Array = (mesh as ArrayMesh).surface_get_arrays(surface)
				var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
				triangle_total += int(indices.size() / 3.0)
	assert_gt(float(triangle_total), 500.0, "в чанке сотни треугольников (не пустое поле)")
	var colliders: Array = result.get("colliders", [])
	assert_gt(float(colliders.size()), 0.0, "у чанка есть коллайдеры")
	assert_gt(float(result.get("buildings", 0)), 0.0, "в центре города есть здания")
	assert_ge(float(result.get("generation_ms", 0.0)), 0.0, "чанк сообщает время генерации")


func test_geometry_is_generated_in_world_coordinates() -> void:
	# the terrain mesh of a city chunk must be centred on that chunk, not on
	# the origin, otherwise chunks would overlap
	var cell := Vector2i(10, 10)
	var origin := config.chunk_origin(cell)
	var result := generator.generate_chunk(cell, WorldGenerator.TIER_MID)
	var arrays: Array = (result["meshes"][0] as ArrayMesh).surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	var box := AABB(vertices[0], Vector3.ZERO)
	for vertex in vertices:
		box = box.expand(vertex)
	var chunk_center := Vector3(origin.x + config.chunk_size_m * 0.5, 0.0, origin.z + config.chunk_size_m * 0.5)
	assert_lt(Vector2(box.get_center().x - chunk_center.x, box.get_center().z - chunk_center.z).length(), 40.0, "чанк строится на своём месте")
	assert_lt(box.size.x, config.chunk_size_m * 1.6, "чанк не вылезает далеко за свои границы")


func test_chunk_lod_reduces_triangles_at_distance() -> void:
	var cell := Vector2i(6, 6)
	var near := generator.generate_chunk(cell, WorldGenerator.TIER_NEAR)
	var far := generator.generate_chunk(cell, WorldGenerator.TIER_FAR)
	var near_vertices := 0
	var far_vertices := 0
	for mesh in near["meshes"]:
		if mesh is ArrayMesh:
			near_vertices += (mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
	for mesh in far["meshes"]:
		if mesh is ArrayMesh:
			far_vertices += (mesh as ArrayMesh).surface_get_arrays(0)[Mesh.ARRAY_VERTEX].size()
	assert_lt(float(far_vertices), float(near_vertices), "дальний LOD использует меньше геометрии")


func test_neighbouring_chunks_do_not_seam() -> void:
	# heights along the shared edge must match: sample the terrain field on both
	# sides of the boundary - the generator answers from one global grid
	var boundary_x := config.chunk_origin(Vector2i(8, 8)).x + config.chunk_size_m
	var mismatches := 0
	for i in range(30):
		var z := config.chunk_origin(Vector2i(8, 8)).z + config.chunk_size_m * 0.5 + float(i) * 3.0
		var left := generator.terrain.height_at(boundary_x - 0.001, z)
		var right := generator.terrain.height_at(boundary_x + 0.001, z)
		if absf(left - right) > 0.25:
			mismatches += 1
	assert_eq(mismatches, 0, "на границе чанков нет разрывов высоты")


func test_triangle_budget_per_chunk_is_mobile_friendly() -> void:
	var worst := 0
	for cell in [Vector2i(10, 10), Vector2i(9, 9), Vector2i(11, 10), Vector2i(5, 5)]:
		var result := generator.generate_chunk(cell, WorldGenerator.TIER_NEAR)
		var triangles := 0
		for mesh in result["meshes"]:
			if mesh is ArrayMesh:
				for surface in range((mesh as ArrayMesh).get_surface_count()):
					var indices: PackedInt32Array = (mesh as ArrayMesh).surface_get_arrays(surface)[Mesh.ARRAY_INDEX]
					triangles += int(indices.size() / 3.0)
		worst = maxi(worst, triangles)
	assert_lt(float(worst), 60000.0, "чанк near-LOD укладывается в мобильный бюджет треугольников")
	print("       (самый тяжёлый чанк near-LOD: %d треугольников)" % worst)


func test_water_mesh_is_generated_once_for_the_whole_world() -> void:
	var water := generator.build_water_mesh()
	assert_ne(water, null, "меш воды создаётся")
	var arrays: Array = (water as ArrayMesh).surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	assert_gt(float(vertices.size()), 100.0, "поверхность воды покрывает мир")
	var worst_offset := 0.0
	for vertex in vertices:
		worst_offset = maxf(worst_offset, absf(vertex.y - generator.terrain.config.water_level))
	assert_lt(worst_offset, 1.0, "плоскость воды горизонтальна и лежит на уровне воды")
	var span_x := 0.0
	for vertex in vertices:
		span_x = maxf(span_x, absf(vertex.x))
	assert_gt(span_x * 2.0, config.world_size_m * 0.95, "вода покрывает весь мир")
