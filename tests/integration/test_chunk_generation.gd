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
	print("       генерация городского чанка: %.1f мс" % float(result.get("generation_ms", 0.0)))
	assert_true(result.has("meshes"), "чанк возвращает меши по слоям")
	var meshes: Array = result["meshes"]
	assert_eq(meshes.size(), 5, "пять слоёв: рельеф, дороги, строения, мелкий декор, растительность")
	var terrain_mesh: Mesh = meshes[0]
	assert_ne(terrain_mesh, null, "рельефный слой не пуст")
	var triangle_total := 0
	for mesh in meshes:
		if mesh is ArrayMesh:
			triangle_total += _triangle_count(mesh as ArrayMesh)
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


## Бюджет треугольников на чанк.  Ближний уровень видит игрок вплотную (он же
## несёт физику), и цена чанка здесь ограничена сверху: раньше одни и те же
## здания попадали сразу в 2-4 соседних чанка (блок 115 м при шаге сетки 145 м
## и чанке 192 м), и чанк стоил больше ста тысяч треугольников.
func test_triangle_budget_per_chunk_is_mobile_friendly() -> void:
	var worst := 0
	for cell in [Vector2i(10, 10), Vector2i(9, 9), Vector2i(11, 10), Vector2i(5, 5)]:
		var result := generator.generate_chunk(cell, WorldGenerator.TIER_NEAR)
		var triangles := 0
		var layer_counts: Array[int] = []
		for mesh in result["meshes"]:
			var layer_triangles := 0
			if mesh is ArrayMesh:
				layer_triangles = _triangle_count(mesh as ArrayMesh)
			layer_counts.append(layer_triangles)
			triangles += layer_triangles
		worst = maxi(worst, triangles)
		if triangles > 0:
			print("       чанк %s: всего %d треугольников, по слоям %s" % [
				str(cell), triangles, str(layer_counts)])
	assert_lt(float(worst), 60000.0, "чанк near-LOD укладывается в мобильный бюджет треугольников")
	print("       (самый тяжёлый чанк near-LOD: %d треугольников)" % worst)


## Настоящая лестница LOD: средний уровень должен быть заметно дешевле ближнего,
## дальний - среднего.  До этой проверки средний уровень строил почти полную
## детализацию зданий и обходился дороже ближнего, то есть LOD не экономил.
func test_lod_levels_actually_reduce_the_geometry() -> void:
	var cell := Vector2i(10, 10)  # плотная городская застройка
	var near := _chunk_triangles(cell, WorldGenerator.TIER_NEAR)
	var mid := _chunk_triangles(cell, WorldGenerator.TIER_MID)
	var far := _chunk_triangles(cell, WorldGenerator.TIER_FAR)
	print("       лестница LOD чанка %s: near %d, mid %d, far %d треугольников" % [
		str(cell), near, mid, far])
	assert_lt(float(mid), 25000.0, "средний LOD укладывается в бюджет (упрощённые дома, полотно без бордюров)")
	assert_lt(float(far), 8000.0, "дальний LOD укладывается в бюджет (одна коробка на дом)")
	assert_lt(float(mid), float(near) * 0.6, "средний LOD дешевле ближнего минимум на 40%")
	# Дальний уровень состоит из рельефа и полотна дорог: дороги стример строит
	# на всех уровнях (иначе вдали рвётся сеть), поэтому разрыв между средним и
	# дальним уровнем меньше, чем между ближним и средним, но дальний обязан
	# оставаться самым дешёвым.
	assert_lt(float(far), float(mid) * 0.8, "дальний LOD дешевле среднего")


func _chunk_triangles(cell: Vector2i, tier: int) -> int:
	var result := generator.generate_chunk(cell, tier)
	var total := 0
	for mesh in result["meshes"]:
		if mesh is ArrayMesh:
			total += _triangle_count(mesh as ArrayMesh)
	return total


## MultiMesh и distance culling: ТЗ требует не рисовать то, что игроку не
## видно, и использовать MultiMesh для массовых повторяющихся объектов там, где
## это действительно выгодно (дальний силуэт города - десятки одинаковых коробок
## одного материала).
func test_distant_skyline_uses_a_multimesh_and_distance_culling() -> void:
	var builder := BackgroundBuilder.new(generator.terrain, generator.region_map)
	var built := builder.build()
	var transforms: Array = built.get("skyline_transforms", [])
	var mesh: Mesh = built.get("skyline_mesh") as Mesh
	assert_gt(float(transforms.size()), 10.0, "высоток дальнего силуэта десятки")
	assert_ne(mesh, null, "для MultiMesh есть единичный меш высотки")
	var arrays: Array = (mesh as ArrayMesh).surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	assert_eq(vertices.size(), 36, "меш высотки - единичный куб (12 треугольников)")
	# размеры запечены в трансформациях, а не в геометрии
	var sizes: Array[float] = []
	for transform in transforms:
		var basis: Basis = (transform as Transform3D).basis
		sizes.append(basis.get_scale().y)
		assert_gt(basis.get_scale().y, 5.0, "высотка выше пяти метров")
	assert_gt(sizes.max() - sizes.min(), 5.0, "высотки разной высоты, а не одинаковые коробки")
	# distance culling слоёв чанка
	var chunk := WorldChunk.new()
	chunk.apply_content(Vector2i(0, 0), WorldGenerator.TIER_NEAR, [null, null, null, null, null], [], 0, 0.0)
	chunk.set_cull_distances(440.0, 120.0, 300.0)
	assert_almost_eq(chunk.cull_distance_of(WorldChunk.Layer.STRUCTURES), 440.0, 0.01,
		"у слоя построек своя дальность отрисовки")
	assert_lt(chunk.cull_distance_of(WorldChunk.Layer.PROPS), 440.0,
		"мелкий декор отсекается раньше застройки")
	assert_lt(chunk.cull_distance_of(WorldChunk.Layer.FOLIAGE), 440.0,
		"растительность убирается раньше построек")
	chunk.free()


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


## MeshBuilder собирает меши без индексации, поэтому треугольники считаются по
## вершинам (шесть вершин на квад).  Раньше здесь безусловно читался массив
## ARRAY_INDEX: у неиндексированного меша он равен null, счётчик молча оставался
## нулевым, и тест "проходил", ничего не проверив.
func _triangle_count(mesh: ArrayMesh) -> int:
	var total := 0
	for surface in range(mesh.get_surface_count()):
		var arrays: Array = mesh.surface_get_arrays(surface)
		var indices: Variant = arrays[Mesh.ARRAY_INDEX]
		if indices != null and (indices as PackedInt32Array).size() > 0:
			total += int((indices as PackedInt32Array).size() / 3)
		else:
			var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
			total += int(vertices.size() / 3)
	return total
