class_name WorldStreamer
extends Node3D

## Streams world chunks around the camera.
##
## * Chunks are generated in distance order, at most `max_generations_per_frame`
##   per frame and inside a per-frame time budget, so a chunk never causes a
##   frame spike on the phone.
## * Every chunk has a tier: near (full detail + physics), mid (simplified
##   buildings, reduced scenery, coarse physics) and far (terrain + roads only).
##   When the player moves, chunks are promoted / demoted instead of being
##   rebuilt from scratch, and chunks outside the view distance are freed.
## * The streamer also owns the world wide objects: the water plane and the
##   background terrain that gives the horizon its shape.

signal chunk_ready(cell: Vector2i, tier: int)
signal stream_complete()
signal world_ready()

const TIER_DISTANCE_FACTOR_NEAR := 0.42
const TIER_DISTANCE_FACTOR_MID := 0.78
## Гистерезис уровней: повышение детализации идёт по своей границе, понижение -
## только если чанк ушёл заметно дальше.  Без него чанк на границе радиуса
## перестраивался на каждом шаге стримера: игрок стоит на месте, а генератор
## мешей работает без остановки (это и давало провалы до единиц кадров).
const TIER_HYSTERESIS_M := 40.0

var config: WorldConfig
var generator: WorldGenerator
var camera_target: Node3D = null

var chunks: Dictionary = {}
var water: MeshInstance3D = null
var background: MeshInstance3D = null
## Дальний силуэт города одним MultiMesh (см. _build_skyline_instance).
var skyline: MultiMeshInstance3D = null
## Diagnostics of the far background ring (filled by _ensure_world_wide_meshes).
var background_triangles: int = 0
var skyline_buildings: int = 0
var chunks_generated_total: int = 0

var near_radius: float = 224.0
var mid_radius: float = 384.0
var view_radius: float = 448.0

var _pending: Array[Dictionary] = []
## Активный джоб пошаговой генерации: чанк собирается порциями (см.
## WorldGenerator.step_chunk), и за кадр на него тратится не больше
## `_generation_budget_ms`.  Раньше чанк строился целиком, одним куском на
## ~0.65 с, и кадр замирал.
var _job: WorldGenerator.ChunkJob = null
var _job_cell: Vector2i = Vector2i(-9999, -9999)
var _job_tier: int = WorldGenerator.TIER_FAR
var _generation_budget_ms: float = 6.0
var _last_center: Vector3 = Vector3(1e9, 0.0, 1e9)
var _last_update: float = 0.0
var _last_player_cell: Vector2i = Vector2i(-9999, -9999)
var _warmup_done: bool = false
var _stream_complete_sent: bool = false
var _chunks_freed_total: int = 0



func _ready() -> void:
	set_process(true)
	apply_quality(Settings.preset())


func setup(world_config: WorldConfig) -> void:
	config = world_config
	generator = WorldGenerator.new(config)
	_apply_radii()
	_ensure_world_wide_meshes()


func _apply_radii() -> void:
	var quality := Settings.preset()
	var scale := maxf(Perf.view_scale, 0.6)
	view_radius = quality.view_distance_m * scale
	# Нижняя граница радиуса ближнего уровня держит собственный чанк игрока
	# "ближним".  На слабом пресете она ниже: ближний чанк самый дорогой
	# (полная застройка, бордюры, мебель), и девять таких чанков вокруг игрока
	# слабый GPU не тянет.  0.8 длины чанка всё равно накрывает чанк игрока.
	var near_floor := config.chunk_size_m * (0.8 if quality.view_distance_m <= 360.0 else 1.05)
	near_radius = maxf(view_radius * TIER_DISTANCE_FACTOR_NEAR, near_floor)
	mid_radius = maxf(view_radius * TIER_DISTANCE_FACTOR_MID, config.chunk_size_m * 1.6)
	# Бюджет генерации на кадр из пресета качества (5-8 мс).  Второй поток
	# использовать нельзя: те же объекты (рельеф, дороги, RNG) вызывает физика
	# игрока каждый кадр, а одновременный вызов одних GDScript-объектов из двух
	# потоков роняет движок (проверено: смоук падал в signal 11).


func apply_quality(quality: GraphicsQuality) -> void:
	if config == null:
		return
	_apply_radii()
	if not is_inside_tree():
		return
	_last_player_cell = Vector2i(-9999, -9999)  # force a refresh of all tiers


func _ensure_world_wide_meshes() -> void:
	if water == null:
		water = MeshInstance3D.new()
		water.name = "Water"
		water.mesh = generator.build_water_mesh()
		water.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		water.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		add_child(water)
	if background == null:
		background = MeshInstance3D.new()
		background.name = "BackgroundTerrain"
		var builder := BackgroundBuilder.new(generator.terrain, generator.region_map)
		var built := builder.build()
		background.mesh = built.get("mesh") as Mesh
		background_triangles = int(built.get("triangles", 0))
		skyline_buildings = int(built.get("skyline_buildings", 0))
		background.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		background.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
		add_child(background)
		_build_skyline_instance(built)


## Дальний силуэт города - один MultiMesh на все высотки вместо тридцати
## четырёх отдельных коробок: одна геометрия в памяти и один вызов отрисовки.
func _build_skyline_instance(built: Dictionary) -> void:
	var transforms: Array = built.get("skyline_transforms", [])
	var mesh: Mesh = built.get("skyline_mesh") as Mesh
	if transforms.is_empty() or mesh == null:
		return
	var multimesh := MultiMesh.new()
	multimesh.transform_format = MultiMesh.TRANSFORM_3D
	multimesh.mesh = mesh
	multimesh.instance_count = transforms.size()
	for index in range(transforms.size()):
		multimesh.set_instance_transform(index, transforms[index])
	skyline = MultiMeshInstance3D.new()
	skyline.name = "DistantSkyline"
	skyline.multimesh = multimesh
	skyline.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
	skyline.gi_mode = GeometryInstance3D.GI_MODE_DISABLED
	add_child(skyline)


## ------------------------------------------------------------- streaming ---
func set_camera_target(target: Node3D) -> void:
	camera_target = target


func _process(delta: float) -> void:
	if generator == null or camera_target == null:
		return
	# Порция генерации - каждый кадр, с бюджетом времени: подгрузка идёт
	# маленькими шагами и не роняет кадры.
	_step_active_job()
	_last_update += delta
	if _last_update < Perf.streamer_interval:
		return
	_last_update = 0.0
	_update_stream()


func _update_stream() -> void:
	var center := camera_target.global_position
	var cell := config.cell_of_position(center)
	if cell == _last_player_cell and center.distance_to(_last_center) < config.chunk_size_m * 0.25:
		_announce_stream_state()
		return
	_last_player_cell = cell
	_last_center = center
	_apply_radii()
	_rebuild_plan(center)
	_announce_stream_state()


func _rebuild_plan(center: Vector3) -> void:
	var chunk_size := config.chunk_size_m
	var half_cells := int(ceil(view_radius / chunk_size))
	var center_cell := config.cell_of_position(center)
	var wanted: Dictionary = {}
	for dz in range(-half_cells, half_cells + 1):
		for dx in range(-half_cells, half_cells + 1):
			var cell := center_cell + Vector2i(dx, dz)
			if cell.x < 0 or cell.y < 0:
				continue
			if cell.x >= config.chunk_count_per_axis() or cell.y >= config.chunk_count_per_axis():
				continue
			var origin := config.chunk_origin(cell)
			var cell_center := Vector3(origin.x + chunk_size * 0.5, 0.0, origin.z + chunk_size * 0.5)
			var distance := Vector3(cell_center.x - center.x, 0.0, cell_center.z - center.z).length()
			if distance > view_radius + chunk_size * 0.6:
				continue
			var tier := _tier_for_distance(distance)
			wanted[cell] = {"tier": tier, "distance": distance}

	# unload chunks that are no longer wanted
	var to_free: Array = []
	for cell in chunks.keys():
		if not wanted.has(cell):
			to_free.append(cell)
	for cell in to_free:
		var chunk: WorldChunk = chunks[cell]
		chunks.erase(cell)
		chunk.queue_free()
		_chunks_freed_total += 1

	# queue generation / re-tiering
	_pending.clear()
	for cell in wanted.keys():
		var entry: Dictionary = wanted[cell]
		var tier := int(entry["tier"])
		if cell == _job_cell:
			continue  # этот чанк уже собирается пошагово
		if chunks.has(cell):
			var chunk: WorldChunk = chunks[cell]
			if chunk.tier != tier:
				_pending.append({"cell": cell, "tier": tier, "distance": entry["distance"], "retier": true})
			continue
		_pending.append({"cell": cell, "tier": tier, "distance": entry["distance"], "retier": false})
	_sort_pending()


func _tier_for_distance(distance: float) -> int:
	if distance <= near_radius:
		return WorldGenerator.TIER_NEAR
	if distance <= near_radius + TIER_HYSTERESIS_M and _current_tier_at(distance) == WorldGenerator.TIER_NEAR:
		return WorldGenerator.TIER_NEAR
	if distance <= mid_radius:
		return WorldGenerator.TIER_MID
	if distance <= mid_radius + TIER_HYSTERESIS_M and _current_tier_at(distance) == WorldGenerator.TIER_MID:
		return WorldGenerator.TIER_MID
	return WorldGenerator.TIER_FAR


## Уровень, который был бы выбран без гистерезиса (используется только для
## проверки "не понижаем ли мы уровень слишком рано").
func _current_tier_at(distance: float) -> int:
	if distance <= near_radius:
		return WorldGenerator.TIER_NEAR
	if distance <= mid_radius:
		return WorldGenerator.TIER_MID
	return WorldGenerator.TIER_FAR


func _sort_pending() -> void:
	# Front-to-back by priority: the closest chunks generate first, near tiers
	# before far ones.
	_pending.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var priority_a := float(a["distance"]) + float(a["tier"]) * 90.0
		var priority_b := float(b["distance"]) + float(b["tier"]) * 90.0
		return priority_a < priority_b
	)


## Одна порция работы над активным чанком за кадр.  Когда чанк готов, из его
## данных собираются меши (главный поток) и узел попадает в мир.
func _step_active_job() -> void:
	if _job == null:
		_start_next_job()
		return
	var budget := maxf(_generation_budget_ms, 1.0)
	var started := Time.get_ticks_msec()
	while not generator.step_chunk(_job):
		if Time.get_ticks_msec() - started >= budget:
			return
	_apply_chunk_data(_job.cell, _job_tier, generator.result_from_job(_job))
	_job = null
	_job_cell = Vector2i(-9999, -9999)


func _start_next_job() -> void:
	if _pending.is_empty():
		return
	var entry: Dictionary = _pending.pop_front()
	var cell: Vector2i = entry["cell"]
	_job = generator.begin_chunk(cell, int(entry["tier"]))
	_job_cell = cell
	_job_tier = int(entry["tier"])


## Сообщает миру, что вокруг игрока всё построено (заставка и тесты ждут этот
## сигнал).
func _announce_stream_state() -> void:
	if _pending.is_empty() and _job == null:
		if not _stream_complete_sent and _warmup_done:
			_stream_complete_sent = true
			stream_complete.emit()
		return
	_stream_complete_sent = false


## Создаёт меши из данных чанка (главный поток) и наполняет узел чанка.
func _apply_chunk_data(cell: Vector2i, tier: int, data: Dictionary) -> void:
	var meshes: Array = []
	for mesh_data in (data["mesh_data"] as Array):
		meshes.append(MeshBuilder.mesh_from_data(mesh_data as Dictionary))
	var chunk: WorldChunk = chunks.get(cell, null)
	if chunk == null:
		chunk = WorldChunk.new()
		chunks[cell] = chunk
		add_child(chunk)
		chunks_generated_total += 1
		generator.generated_chunks += 1
	# The builders emit world-space geometry (a shared global vertex grid is what
	# keeps chunk seams from cracking), so the chunk node itself stays at the scene
	# origin: moving it by the chunk origin would offset the geometry twice and the
	# wheels would find no ground under the car.
	chunk.position = Vector3.ZERO
	chunk.apply_content(
		cell, tier, meshes, data["colliders"], int(data["buildings"]), float(data["generation_ms"])
	)
	# Distance culling: слой построек виден чуть дальше радиуса стриминга (чтобы
	# не мигал на границе), растительность убирается заметно раньше.
	chunk.set_cull_distances(view_radius + config.chunk_size_m, view_radius * 0.75)
	chunk_ready.emit(cell, tier)


## Синхронная генерация чанка: нужна заставке (там кадры не важны) и тестам.
func _build_chunk(cell: Vector2i, tier: int) -> void:
	_apply_chunk_data(cell, tier, generator.generate_chunk_data(cell, tier))


## Generates everything that is needed around a position before the player sees
## the world (called once by the loading screen).  Заставка строит мир порциями
## (несколько чанков за вызов), потому что она всё равно не показывает игровой
## процесс.
func warmup(center: Vector3, max_chunks: int = 12) -> int:
	_last_center = center
	var cell := config.cell_of_position(center)
	_last_player_cell = cell
	_apply_radii()
	_rebuild_plan(center)
	var generated := 0
	while not _pending.is_empty() and generated < max_chunks:
		var entry: Dictionary = _pending.pop_front()
		_build_chunk(entry["cell"], int(entry["tier"]))
		generated += 1
	_warmup_done = true
	if _pending.is_empty():
		_stream_complete_sent = true
		world_ready.emit()
	return generated


func is_ready_around(position: Vector3, radius: float) -> bool:
	var chunk_size := config.chunk_size_m
	var half_cells := int(ceil(radius / chunk_size))
	var center_cell := config.cell_of_position(position)
	for dz in range(-half_cells, half_cells + 1):
		for dx in range(-half_cells, half_cells + 1):
			var cell := center_cell + Vector2i(dx, dz)
			var origin := config.chunk_origin(cell)
			var cell_center := Vector3(origin.x + chunk_size * 0.5, 0.0, origin.z + chunk_size * 0.5)
			if cell_center.distance_to(position) > radius:
				continue
			if not chunks.has(cell):
				return false
	return true


func loaded_chunk_count() -> int:
	return chunks.size()


func loaded_triangle_estimate() -> int:
	var total := 0
	for chunk in chunks.values():
		total += (chunk as WorldChunk).triangle_estimate
	return total


func stats() -> Dictionary:
	return {
		"chunks": chunks.size(),
		"pending": _pending.size(),
		"triangles": loaded_triangle_estimate(),
		"generated": chunks_generated_total,
		"freed": _chunks_freed_total,
		"near_radius": near_radius,
		"view_radius": view_radius,
	}


## ------------------------------------------------------------ world queries
func road_network() -> RoadNetwork:
	return generator.network if generator != null else null


func terrain() -> TerrainField:
	return generator.terrain if generator != null else null


func region_map() -> RegionMap:
	return generator.region_map if generator != null else null


func height_at(x: float, z: float) -> float:
	return generator.terrain.height_at(x, z)


func ground_position(x: float, z: float, lift: float = 0.0) -> Vector3:
	return generator.terrain.ground_position(x, z, lift)
