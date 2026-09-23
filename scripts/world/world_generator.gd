class_name WorldGenerator
extends RefCounted

## Builds the world content of one chunk and returns the meshes and collision
## data WorldChunk needs.
##
## Pipeline
##   1. TerrainField (heights, regions, surfaces) - shared, built once.
##   2. RoadNetworkBuilder -> RoadNetwork - shared, built once from the seed.
##   3. TerrainField.attach_road_network() so the terrain is flattened under
##      roads (two step process, no circular dependency).
##   4. Per chunk: terrain mesh (+ height field collision for close chunks),
##      road ribbons, city blocks, scenery, landmarks.
##
## All generation is deterministic for a given WorldConfig.seed, which the
## tests rely on (tests/unit/test_world_generator.gd).

const TIER_NEAR := 0
const TIER_MID := 1
const TIER_FAR := 2

## The water surface is one mesh for the whole world, built as a grid instead of a
## single quad: the extra vertices cost nothing to render (they are static and
## share one material) but they give the water shader something to move, keep the
## huge triangles from breaking depth precision on mobile GPUs and let the shore
## line be refined later without rebuilding the mesh type.
const WATER_GRID_STEPS := 24

## ---------------------------------------------------------- chunk jobs ------
## Пошаговая сборка чанка.
##
## Чанк целиком стоит около 0.65 с (рельеф, дороги, застройка, растительность),
## и один такой вызов замораживал кадр.  Джоб хранит всё состояние между
## шагами: мелкие порции рельефа, дорог и кварталов, между которыми кадр
## успевает отрисоваться.  Стример выполняет порции по бюджету времени
## (см. WorldStreamer), поэтому подгрузка не видна глазу.
const STAGE_SAMPLE := 0
const STAGE_QUADS := 1
const STAGE_GROUND := 2
const STAGE_ROADS := 3
const STAGE_JUNCTIONS := 4
const STAGE_BLOCKS := 5
const STAGE_FURNITURE := 6
const STAGE_LANDMARKS := 7
const STAGE_SCENERY := 8
const STAGE_FINISH := 9
const STAGE_DONE := 10

## Сколько работы делается за один шаг.  Порции подобраны так, чтобы шаг занимал
## единицы миллисекунд даже на слабом телефоне.
const SAMPLE_ROWS_PER_STEP := 6
const QUAD_ROWS_PER_STEP := 8
const ROAD_SEGMENTS_PER_STEP := 3
const JUNCTIONS_PER_STEP := 2

var config: WorldConfig
var terrain: TerrainField
var network: RoadNetwork
var region_map: RegionMap
var road_builder: RoadBuilder
var city_builder: CityBuilder
var scenery_builder: SceneryBuilder
var landmark_builder: LandmarkBuilder

var world_build_time_ms: float = 0.0

var generated_chunks: int = 0
var generated_triangles: int = 0


func _init(world_config: WorldConfig) -> void:
	config = world_config
	_generate_world_data()


## ------------------------------------------------------- world data build --
func _generate_world_data() -> void:
	var started := Time.get_ticks_msec()
	region_map = RegionMap.new(config)
	terrain = TerrainField.new(config, region_map)
	# Roads are laid out on the *base* terrain, then the terrain is flattened
	# towards them, which is what makes the roads smooth and the shoulders exact.
	var builder := RoadNetworkBuilder.new(config, Callable(terrain, "base_height"))
	network = builder.build()
	network.set_meta("poi_slots", builder.poi_slots)
	network.set_meta("interchange_centers", builder.interchange_centers)
	terrain.attach_road_network(network)
	road_builder = RoadBuilder.new(config, terrain)
	city_builder = CityBuilder.new(config, terrain)
	city_builder.parked_car_config = Config.vehicle_player
	scenery_builder = SceneryBuilder.new(config, terrain)
	landmark_builder = LandmarkBuilder.new(config, terrain)
	world_build_time_ms = float(Time.get_ticks_msec() - started)


func terrain_quad_step(tier: int) -> float:
	var base := config.terrain_quad_near
	if tier == TIER_MID:
		base = config.terrain_quad_mid
	elif tier >= TIER_FAR:
		base = config.terrain_quad_far
	# Runtime LOD scaler: a value below 1 means the device is struggling, so the
	# chunk is sampled more coarsely.
	return base / clampf(Perf.lod_scale, 0.6, 1.0)


## ------------------------------------------------------------- chunk build --
## Полная сборка чанка: данные + меши-ресурсы.  Удобно для тестов и заставки.
## Игровой стриминг использует generate_chunk_data() в фоновом потоке, а меши
## собирает в главном (см. WorldStreamer).
func generate_chunk(cell: Vector2i, tier: int) -> Dictionary:
	var data := generate_chunk_data(cell, tier)
	var meshes: Array = []
	for mesh_data in (data["mesh_data"] as Array):
		meshes.append(MeshBuilder.mesh_from_data(mesh_data as Dictionary))
	data["meshes"] = meshes
	return data


## Содержимое чанка без единого обращения к ресурсам/материалам: только данные
## геометрии, коллайдеров и статистика.  Именно эту функцию можно безопасно
## вызывать из WorkerThreadPool.
## Содержимое чанка без единого обращения к ресурсам: только данные геометрии,
## коллайдеров и статистика.  Это синхронный путь - он собирает чанк целиком,
## шаг за шагом, и нужен тестам и заставке.
func generate_chunk_data(cell: Vector2i, tier: int) -> Dictionary:
	var job := begin_chunk(cell, tier)
	var guard := 0
	while not step_chunk(job) and guard < 4096:
		guard += 1
	return result_from_job(job)


## Готовит джоб: всё, что можно посчитать дёшево, считается сразу.
func begin_chunk(cell: Vector2i, tier: int) -> ChunkJob:
	var job := ChunkJob.new()
	job.cell = cell
	job.tier = tier
	job.origin = config.chunk_origin(cell)
	job.rect = Rect2(Vector2(job.origin.x, job.origin.z), Vector2(config.chunk_size_m, config.chunk_size_m))
	job.rng = MathUtils.rng_for(cell, config.seed)
	job.started_ms = Time.get_ticks_msec()
	job.terrain_builder = MeshBuilder.new()
	job.road_builder = MeshBuilder.new()
	job.structures = MeshBuilder.new()
	job.props = MeshBuilder.new()
	job.foliage = MeshBuilder.new()
	var params := _terrain_params(tier, job.rect)
	job.terrain_step = float(params["step"])
	job.terrain_count = int(params["count"])
	job.terrain_rows = int(params["rows"])
	job.base_x = float(params["base_x"])
	job.base_z = float(params["base_z"])
	var sample_count := job.terrain_rows * job.terrain_rows
	job.heights.resize(sample_count)
	job.materials.resize(sample_count)
	job.tints.resize(sample_count)
	job.road_detailed = tier <= TIER_NEAR
	job.road_segments = road_builder.collect_segments(job.rect)
	if job.road_detailed:
		job.junctions = road_builder.collect_junctions(job.rect)
	job.city_enabled = tier <= TIER_MID
	# Мелкий уличный декор - только в ближнем чанке: это десяток материалов
	# (скамейки, урны, столбы, вывески), то есть десяток вызовов отрисовки, а на
	# двухсот метрах их всё равно не видно.
	job.furniture_enabled = tier <= TIER_NEAR
	job.scenery_enabled = tier <= TIER_MID and terrain.urban_at(job.rect.get_center().x, job.rect.get_center().y) < 0.65
	job.block_rows = city_builder.block_row_range(job.rect)
	job.block_columns = city_builder.block_column_range(job.rect)
	return job


## Выполняет одну порцию работы.  Возвращает true, когда чанк полностью собран.
func step_chunk(job: ChunkJob) -> bool:
	if job == null:
		return true
	match job.stage:
		STAGE_SAMPLE:
			var last_row := mini(job.cursor + SAMPLE_ROWS_PER_STEP, job.terrain_rows)
			_sample_terrain_rows(job, job.cursor, last_row)
			job.cursor = last_row
			if job.cursor >= job.terrain_rows:
				job.stage = STAGE_QUADS
				job.cursor = 0
		STAGE_QUADS:
			var last_quad := mini(job.cursor + QUAD_ROWS_PER_STEP, job.terrain_count)
			_build_terrain_quads(job, job.cursor, last_quad)
			job.cursor = last_quad
			if job.cursor >= job.terrain_count:
				job.stage = STAGE_GROUND
				job.cursor = 0
		STAGE_GROUND:
			job.ground_collision = _ground_collision_for_job(job)
			job.stage = STAGE_ROADS
			job.cursor = 0
		STAGE_ROADS:
			var last_segment := mini(job.cursor + ROAD_SEGMENTS_PER_STEP, job.road_segments.size())
			road_builder.build_segment_slice(
				job.road_builder, job.road_segments, job.cursor, last_segment,
				job.rect, job.rng, job.colliders, job.road_detailed
			)
			job.cursor = last_segment
			if job.cursor >= job.road_segments.size():
				job.stage = STAGE_JUNCTIONS
				job.cursor = 0
		STAGE_JUNCTIONS:
			var last_junction := mini(job.cursor + JUNCTIONS_PER_STEP, job.junctions.size())
			road_builder.build_junction_slice(job.road_builder, job.junctions, job.cursor, last_junction, job.rng)
			job.cursor = last_junction
			if job.cursor >= job.junctions.size():
				job.stage = STAGE_BLOCKS
				job.cursor = job.block_rows.x
		STAGE_BLOCKS:
			var last_block_row := mini(job.cursor + 1, job.block_rows.y)
			if job.city_enabled and job.block_rows.x <= job.block_rows.y:
				job.buildings += city_builder.build_block_slice(
					job.structures, job.rect, job.tier, job.rng, job.colliders,
					job.cursor, last_block_row, job.block_columns.x, job.block_columns.y
				)
			job.cursor = last_block_row + 1
			if job.cursor > job.block_rows.y:
				job.stage = STAGE_FURNITURE
		STAGE_FURNITURE:
			if job.furniture_enabled:
				city_builder.build_street_furniture(job.props, job.rect, job.tier, job.rng, job.colliders)
			job.stage = STAGE_LANDMARKS
		STAGE_LANDMARKS:
			if job.city_enabled:
				landmark_builder.build_chunk(job.structures, job.rect, job.tier, job.rng, job.colliders)
			job.stage = STAGE_SCENERY
		STAGE_SCENERY:
			if job.scenery_enabled:
				scenery_builder.build_chunk(job.foliage, job.rect, job.tier, job.rng, job.colliders)
			job.stage = STAGE_FINISH
		STAGE_FINISH:
			job.mesh_data = [
				job.terrain_builder.commit_data(),
				job.road_builder.commit_data(),
				job.structures.commit_data(),
				job.props.commit_data(),
				job.foliage.commit_data(),
			]
			job.stage = STAGE_DONE
		_:
			return true
	return job.stage == STAGE_DONE


## Собирает итоговый словарь чанка из готового джоба.
func result_from_job(job: ChunkJob) -> Dictionary:
	var shapes: Array = []
	if not job.ground_collision.is_empty():
		shapes.append(job.ground_collision)
	shapes.append_array(job.colliders)
	return {
		"mesh_data": job.mesh_data,
		"colliders": shapes,
		"buildings": job.buildings,
		"generation_ms": float(Time.get_ticks_msec() - job.started_ms),
	}


## --------------------------------------------------------------- terrain ---
func _terrain_params(tier: int, rect: Rect2) -> Dictionary:
	var step := terrain_quad_step(tier)
	var count := int(ceil(config.chunk_size_m / step))
	var actual_step := config.chunk_size_m / float(count)
	return {
		# Global sampling grid: identical vertices in the overlap between chunks.
		"step": actual_step,
		"count": count,
		"rows": count + 1,
		"base_x": floorf(rect.position.x / actual_step) * actual_step,
		"base_z": floorf(rect.position.y / actual_step) * actual_step,
	}


func _sample_terrain_rows(job: ChunkJob, from_row: int, to_row: int) -> void:
	var rows := job.terrain_rows
	for iz in range(from_row, to_row):
		for ix in range(rows):
			var x := job.base_x + float(ix) * job.terrain_step
			var z := job.base_z + float(iz) * job.terrain_step
			var index := iz * rows + ix
			var height := terrain.height_at(x, z)
			job.heights[index] = height
			# Наклон для раскраски считается из уже посчитанных высот (см. ниже),
			# отдельный сэмпл рельефа на вершину был чистой тратой времени.
			var surface := terrain.surface_at(x, z, height)
			job.materials[index] = terrain.terrain_material_at(x, z, surface)
			job.tints[index] = terrain.terrain_tint_at(x, z)


func _build_terrain_quads(job: ChunkJob, from_row: int, to_row: int) -> void:
	var rows := job.terrain_rows
	var count := job.terrain_count
	var step := job.terrain_step
	var base_x := job.base_x
	var base_z := job.base_z
	var heights := job.heights
	var builder := job.terrain_builder
	for iz in range(from_row, to_row):
		for ix in range(count):
			var i0 := iz * rows + ix
			var i1 := i0 + 1
			var i2 := i0 + rows + 1
			var i3 := i0 + rows
			if terrain.lake_at(base_x + (float(ix) + 0.5) * step, base_z + (float(iz) + 0.5) * step) > 0.45:
				continue  # the water plane covers it, skip the geometry
			var p0 := Vector3(base_x + float(ix) * step, heights[i0], base_z + float(iz) * step)
			var p1 := Vector3(base_x + float(ix + 1) * step, heights[i1], base_z + float(iz) * step)
			var p2 := Vector3(base_x + float(ix + 1) * step, heights[i2], base_z + float(iz + 1) * step)
			var p3 := Vector3(base_x + float(ix) * step, heights[i3], base_z + float(iz + 1) * step)
			# split the quad along the shorter diagonal to avoid stretching
			var split_forward := (p1 - p3).length_squared() < (p0 - p2).length_squared()
			var uv_scale := 1.0 / 8.0
			var uv0 := Vector2(p0.x, p0.z) * uv_scale
			var uv1 := Vector2(p1.x, p1.z) * uv_scale
			var uv2 := Vector2(p2.x, p2.z) * uv_scale
			var uv3 := Vector2(p3.x, p3.z) * uv_scale
			var material: String = job.materials[i0]
			# rock faces where the slope is high, otherwise follow the surface:
			# центральная разность по готовой сетке высот вместо ещё одного запроса
			var gradient_x: float = (heights[i1] - heights[i0]) / step
			var gradient_z: float = (heights[i3] - heights[i0]) / step
			var slope := clampf(sqrt(gradient_x * gradient_x + gradient_z * gradient_z), 0.0, 1.0)
			if slope > 0.7:
				material = "ground_rock"
			if split_forward:
				builder.add_triangle(material, p0, p1, p2, job.tints[i1], uv0, uv1, uv2)
				builder.add_triangle(material, p0, p2, p3, job.tints[i3], uv0, uv2, uv3)
			else:
				builder.add_triangle(material, p0, p1, p3, job.tints[i1], uv0, uv1, uv3)
				builder.add_triangle(material, p1, p2, p3, job.tints[i2], uv1, uv2, uv3)


## Physics collision for the ground.  A tri-mesh built from the *same* sampling
## grid as the visible terrain is used instead of a HeightMapShape3D, because
## Godot's height-map shape always uses a one-metre cell: a 192 m chunk needs a
## 193x193 height map (37k floats) and, if the grid is stored at a coarser step,
## the shape silently covers only ~49 m of the chunk and the car drives straight
## through the ground.  Коллизия есть у всех уровней: машина успевает доехать до
## дальнего чанка раньше, чем стример повысит его уровень.
func _ground_collision_for_job(job: ChunkJob) -> Dictionary:
	var step := terrain_quad_step(job.tier) if job.tier == TIER_NEAR else maxf(terrain_quad_step(job.tier), 8.0)
	if job.tier > TIER_MID:
		step = maxf(config.terrain_quad_far, 16.0)
	if absf(job.terrain_step - step) < 0.001:
		# Быстрый путь: сетка рельефа уже посчитана для меша (раньше коллизия
		# опрашивала рельеф заново - почти десять секунд на городской чанк).
		return _ground_collision_from_grid(
			job.rect, job.origin, job.terrain_rows, job.terrain_step, job.base_x, job.base_z, job.heights
		)
	return _ground_collision_sampled(job.rect, job.tier, job.origin)


func _ground_collision_sampled(rect: Rect2, tier: int, origin: Vector3) -> Dictionary:
	var step := terrain_quad_step(tier) if tier == TIER_NEAR else maxf(terrain_quad_step(tier), 8.0)
	if tier > TIER_MID:
		step = maxf(config.terrain_quad_far, 16.0)
	var count := maxi(int(ceil(config.chunk_size_m / step)), 1)
	var cell := config.chunk_size_m / float(count)
	var heights := PackedFloat32Array()
	heights.resize((count + 1) * (count + 1))
	for iz in range(count + 1):
		for ix in range(count + 1):
			heights[iz * (count + 1) + ix] = terrain.height_at(
				origin.x + float(ix) * cell, origin.z + float(iz) * cell
			)
	var faces := PackedVector3Array()
	faces.resize(count * count * 6)
	var write := 0
	for iz in range(count):
		for ix in range(count):
			var x0 := origin.x + float(ix) * cell
			var x1 := x0 + cell
			var z0 := origin.z + float(iz) * cell
			var z1 := z0 + cell
			var h00: float = heights[iz * (count + 1) + ix]
			var h10: float = heights[iz * (count + 1) + ix + 1]
			var h01: float = heights[(iz + 1) * (count + 1) + ix]
			var h11: float = heights[(iz + 1) * (count + 1) + ix + 1]
			# Same diagonal split as the mesh (shorter diagonal wins), so what the
			# wheels feel is what the player sees.
			var diagonal_p3 := Vector3(x0, h00, z0).distance_squared_to(Vector3(x1, h11, z1))
			var diagonal_p2 := Vector3(x1, h10, z0).distance_squared_to(Vector3(x0, h01, z1))
			if diagonal_p2 <= diagonal_p3:
				faces[write] = Vector3(x0, h00, z0)
				faces[write + 1] = Vector3(x1, h10, z0)
				faces[write + 2] = Vector3(x0, h01, z1)
				faces[write + 3] = Vector3(x1, h10, z0)
				faces[write + 4] = Vector3(x1, h11, z1)
				faces[write + 5] = Vector3(x0, h01, z1)
			else:
				faces[write] = Vector3(x0, h00, z0)
				faces[write + 1] = Vector3(x1, h10, z0)
				faces[write + 2] = Vector3(x1, h11, z1)
				faces[write + 3] = Vector3(x0, h00, z0)
				faces[write + 4] = Vector3(x1, h11, z1)
				faces[write + 5] = Vector3(x0, h01, z1)
			write += 6
	faces.resize(write)
	return {"shape": "trimesh", "faces": faces, "transform": Transform3D.IDENTITY}


## Коллизия земли из уже готовой сетки рельефа: вершины совпадают с видимым
## мешем (то же разбиение по короткой диагонали), поэтому колёса чувствуют ровно
## то, что видит игрок.
func _ground_collision_from_grid(
	rect: Rect2, origin: Vector3, rows: int, step: float, base_x: float, base_z: float,
	heights: PackedFloat32Array
) -> Dictionary:
	# Сетка глобальная, поэтому её начало может лежать левее/выше чанка: ищем
	# индекс первой вершины внутри чанка.
	var first_x := maxi(int(floorf((origin.x - base_x) / step)), 0)
	var first_z := maxi(int(floorf((origin.z - base_z) / step)), 0)
	var last_x := mini(int(ceilf((origin.x + config.chunk_size_m - base_x) / step)), rows - 2)
	var last_z := mini(int(ceilf((origin.z + config.chunk_size_m - base_z) / step)), rows - 2)
	if last_x <= first_x or last_z <= first_z:
		return {}
	var faces := PackedVector3Array()
	faces.resize((last_z - first_z) * (last_x - first_x) * 6)
	var write := 0
	for iz in range(first_z, last_z):
		for ix in range(first_x, last_x):
			var x0 := base_x + float(ix) * step
			var x1 := x0 + step
			var z0 := base_z + float(iz) * step
			var z1 := z0 + step
			var h00: float = heights[iz * rows + ix]
			var h10: float = heights[iz * rows + ix + 1]
			var h01: float = heights[(iz + 1) * rows + ix]
			var h11: float = heights[(iz + 1) * rows + ix + 1]
			# То же разбиение по короткой диагонали, что у меша
			var diagonal_p3 := Vector3(x0, h00, z0).distance_squared_to(Vector3(x1, h11, z1))
			var diagonal_p2 := Vector3(x1, h10, z0).distance_squared_to(Vector3(x0, h01, z1))
			if diagonal_p2 <= diagonal_p3:
				faces[write] = Vector3(x0, h00, z0)
				faces[write + 1] = Vector3(x1, h10, z0)
				faces[write + 2] = Vector3(x0, h01, z1)
				faces[write + 3] = Vector3(x1, h10, z0)
				faces[write + 4] = Vector3(x1, h11, z1)
				faces[write + 5] = Vector3(x0, h01, z1)
			else:
				faces[write] = Vector3(x0, h00, z0)
				faces[write + 1] = Vector3(x1, h10, z0)
				faces[write + 2] = Vector3(x1, h11, z1)
				faces[write + 3] = Vector3(x0, h00, z0)
				faces[write + 4] = Vector3(x1, h11, z1)
				faces[write + 5] = Vector3(x0, h01, z1)
			write += 6
	faces.resize(write)
	return {
		"shape": "trimesh",
		"faces": faces,
		"transform": Transform3D.IDENTITY,
	}


## ----------------------------------------------------------- world extras --
## Water plane for the lake, drawn once for the whole world.
func build_water_mesh() -> Mesh:
	var builder := MeshBuilder.new()
	var half := config.world_half_extent()
	var y := config.water_level
	var uv_scale := 1.0 / 40.0
	var steps := maxi(WATER_GRID_STEPS, 1)
	var cell := (half * 2.0) / float(steps)
	for ix in range(steps):
		for iz in range(steps):
			var x0 := -half + float(ix) * cell
			var x1 := x0 + cell
			var z0 := -half + float(iz) * cell
			var z1 := z0 + cell
			builder.add_quad(
				"water",
				Vector3(x0, y, z0), Vector3(x1, y, z0), Vector3(x1, y, z1), Vector3(x0, y, z1),
				Color(0.85, 0.95, 1.0),
				Vector2(x0, z0) * uv_scale, Vector2(x1, z0) * uv_scale,
				Vector2(x1, z1) * uv_scale, Vector2(x0, z1) * uv_scale,
				Vector3.UP
			)
	return builder.commit()


class ChunkJob:
	extends RefCounted

	var cell: Vector2i = Vector2i.ZERO
	var tier: int = 0
	var rect: Rect2 = Rect2()
	var origin: Vector3 = Vector3.ZERO
	var rng: RandomNumberGenerator = null
	var started_ms: int = 0
	var stage: int = 0
	var cursor: int = 0
	var colliders: Array = []
	var buildings: int = 0
	var city_enabled: bool = false
	var furniture_enabled: bool = false
	var scenery_enabled: bool = false
	# рельеф
	var terrain_step: float = 1.0
	var terrain_count: int = 0
	var terrain_rows: int = 0
	var base_x: float = 0.0
	var base_z: float = 0.0
	# Типизированные Packed-массивы: чтение высоты из них не разворачивает
	# Variant (замер показал, что обычный Array на этой части только медленнее).
	var heights: PackedFloat32Array = PackedFloat32Array()
	var materials: PackedStringArray = PackedStringArray()
	var tints: PackedColorArray = PackedColorArray()
	# дороги
	var road_segments: PackedInt32Array = PackedInt32Array()
	var junctions: PackedInt32Array = PackedInt32Array()
	var road_detailed: bool = false
	# кварталы
	var block_rows: Vector2i = Vector2i.ZERO
	var block_columns: Vector2i = Vector2i.ZERO
	# результат
	var terrain_builder: MeshBuilder = null
	var road_builder: MeshBuilder = null
	var structures: MeshBuilder = null
	var props: MeshBuilder = null
	var foliage: MeshBuilder = null
	var ground_collision: Dictionary = {}
	var mesh_data: Array = []
