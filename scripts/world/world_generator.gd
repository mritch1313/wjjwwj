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
## Сетка высот последнего построенного рельефа (см. _build_terrain) - из неё
## строится коллизия земли, чтобы не опрашивать рельеф дважды.
var _ground_grid_base_x: float = 0.0
var _ground_grid_base_z: float = 0.0
var _ground_grid_step: float = 1.0
var _ground_grid_rows: int = 0
var _ground_grid_heights: PackedFloat32Array = PackedFloat32Array()


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
func generate_chunk(cell: Vector2i, tier: int) -> Dictionary:
	var started := Time.get_ticks_msec()
	var origin := config.chunk_origin(cell)
	var rect := Rect2(Vector2(origin.x, origin.z), Vector2(config.chunk_size_m, config.chunk_size_m))
	var rng := MathUtils.rng_for(cell, config.seed)
	var colliders: Array = []

	var terrain_builder := MeshBuilder.new()
	_build_terrain(terrain_builder, rect, tier, rng)
	var ground_collision := _build_ground_collision(rect, tier, origin)

	var road_builder_local := MeshBuilder.new()
	road_builder.build_chunk(road_builder_local, rect, rng, tier)

	# Structures (opaque, casts shadows) and foliage (alpha scissor, no shadows)
	# live in separate mesh instances so their render flags can differ.
	var structures := MeshBuilder.new()
	var foliage := MeshBuilder.new()
	var buildings := 0
	var urban := terrain.urban_at(rect.get_center().x, rect.get_center().y)
	if tier <= TIER_MID:
		buildings = city_builder.build_chunk(structures, rect, tier, rng, colliders)
		city_builder.build_street_furniture(structures, rect, tier, rng, colliders)
		landmark_builder.build_chunk(structures, rect, tier, rng, colliders)
		if urban < 0.65:
			scenery_builder.build_chunk(foliage, rect, tier, rng, colliders)

	generated_chunks += 1
	var meshes: Array = [
		terrain_builder.commit(),
		road_builder_local.commit(),
		structures.commit(),
		foliage.commit(),
	]
	var shapes: Array = []
	if ground_collision != null:
		shapes.append(ground_collision)
	shapes.append_array(colliders)
	var elapsed := float(Time.get_ticks_msec() - started)
	return {
		"meshes": meshes,
		"colliders": shapes,
		"buildings": buildings,
		"generation_ms": elapsed,
	}


## --------------------------------------------------------------- terrain ---
func _build_terrain(builder: MeshBuilder, rect: Rect2, tier: int, rng: RandomNumberGenerator) -> void:
	var step := terrain_quad_step(tier)
	var count := int(ceil(config.chunk_size_m / step))
	var actual_step := config.chunk_size_m / float(count)
	# Global sampling grid: identical vertices in the overlap between chunks.
	var base_x := floorf(rect.position.x / actual_step) * actual_step
	var base_z := floorf(rect.position.y / actual_step) * actual_step
	var rows := count + 1
	var heights := PackedFloat32Array()
	var materials: PackedStringArray = PackedStringArray()
	var tints := PackedColorArray()
	heights.resize(rows * rows)
	# Сетку сэмплов запоминаем: коллизия земли строится из неё же, а не опрашивает
	# рельеф заново (это была самая дорогая часть генерации городского чанка).
	_ground_grid_base_x = base_x
	_ground_grid_base_z = base_z
	_ground_grid_step = actual_step
	_ground_grid_rows = rows
	materials.resize(rows * rows)
	tints.resize(rows * rows)
	for iz in range(rows):
		for ix in range(rows):
			var x := base_x + float(ix) * actual_step
			var z := base_z + float(iz) * actual_step
			var index := iz * rows + ix
			var height := terrain.height_at(x, z)
			heights[index] = height
			# Наклон для раскраски считается из уже посчитанных высот (см. ниже),
			# отдельный сэмпл рельефа на вершину был чистой тратой времени.
			var surface := terrain.surface_at(x, z, height)
			materials[index] = terrain.terrain_material_at(x, z, surface)
			tints[index] = terrain.terrain_tint_at(x, z)
	_ground_grid_heights = heights
	for iz in range(count):
		for ix in range(count):
			var i0 := iz * rows + ix
			var i1 := i0 + 1
			var i2 := i0 + rows + 1
			var i3 := i0 + rows
			if terrain.lake_at(base_x + (float(ix) + 0.5) * actual_step, base_z + (float(iz) + 0.5) * actual_step) > 0.45:
				continue  # the water plane covers it, skip the geometry
			var p0 := Vector3(base_x + float(ix) * actual_step, heights[i0], base_z + float(iz) * actual_step)
			var p1 := Vector3(base_x + float(ix + 1) * actual_step, heights[i1], base_z + float(iz) * actual_step)
			var p2 := Vector3(base_x + float(ix + 1) * actual_step, heights[i2], base_z + float(iz + 1) * actual_step)
			var p3 := Vector3(base_x + float(ix) * actual_step, heights[i3], base_z + float(iz + 1) * actual_step)
			# split the quad along the shorter diagonal to avoid stretching
			var split_forward := (p1 - p3).length_squared() < (p0 - p2).length_squared()
			var uv_scale := 1.0 / 8.0
			var uv0 := Vector2(p0.x, p0.z) * uv_scale
			var uv1 := Vector2(p1.x, p1.z) * uv_scale
			var uv2 := Vector2(p2.x, p2.z) * uv_scale
			var uv3 := Vector2(p3.x, p3.z) * uv_scale
			var material := materials[i0]
			# rock faces where the slope is high, otherwise follow the surface:
			# центральная разность по готовой сетке высот вместо ещё одного запроса
			var gradient_x := (heights[i1] - heights[i0]) / actual_step
			var gradient_z := (heights[i3] - heights[i0]) / actual_step
			var slope := clampf(sqrt(gradient_x * gradient_x + gradient_z * gradient_z), 0.0, 1.0)
			if slope > 0.7:
				material = "ground_rock"
			if split_forward:
				builder.add_triangle(material, p0, p1, p2, tints[i1], uv0, uv1, uv2)
				builder.add_triangle(material, p0, p2, p3, tints[i3], uv0, uv2, uv3)
			else:
				builder.add_triangle(material, p0, p1, p3, tints[i1], uv0, uv1, uv3)
				builder.add_triangle(material, p1, p2, p3, tints[i2], uv1, uv2, uv3)


## Physics collision for the ground of the chunks the player can actually reach.
##
## A tri-mesh built from the *same* sampling grid as the visible terrain is used
## instead of a HeightMapShape3D, because Godot's height-map shape always uses a
## one-metre cell: a 192 m chunk needs a 193x193 height map (37k floats) and, if
## the grid is stored at a coarser step, the shape silently covers only ~49 m of
## the chunk and the car drives straight through the ground.
##
## Only the near/mid chunks get ground collision (the far ones are never driven
## on), and the faces are emitted in world space, exactly like the terrain mesh.
func _build_ground_collision(rect: Rect2, tier: int, origin: Vector3) -> Dictionary:
	# Коллизия земли нужна на ВСЕХ уровнях: дальний чанк тоже находится внутри
	# радиуса обзора, и машина на скорости успевает туда доехать раньше, чем
	# стример повысит его уровень.  Раньше у дальних чанков коллизии не было
	# вовсе - машина проваливалась сквозь землю "в пустоте" между чанками.
	var step := terrain_quad_step(tier) if tier == TIER_NEAR else maxf(terrain_quad_step(tier), 8.0)
	if tier > TIER_MID:
		# Дальний уровень: грубая сетка (~24 м). Машина на ней едет по крупному
		# рельефу, а точную геометрию даёт ближний чанк, который подгружается
		# быстрее, чем игрок успевает доехать.
		step = maxf(config.terrain_quad_far, 16.0)
	# Быстрый путь: рельеф этого же чанка только что сэмплирован для меша
	# (та же сетка), значит коллизия просто повторяет его вершины.  Раньше
	# коллизия опрашивала рельеф заново - 4-5 тысяч запросов по ~1.9 мс каждый,
	# то есть почти десять секунд на один городской чанк.
	if _ground_grid_rows > 0 and absf(_ground_grid_step - step) < 0.001:
		return _ground_collision_from_grid(rect, origin)
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
			var h00 := heights[iz * (count + 1) + ix]
			var h10 := heights[iz * (count + 1) + ix + 1]
			var h01 := heights[(iz + 1) * (count + 1) + ix]
			var h11 := heights[(iz + 1) * (count + 1) + ix + 1]
			# Same diagonal split as the mesh (shorter diagonal wins), so what the
			# wheels feel is what the player sees.
			if absf(h00 + h11 - h10 - h01) < 0.0001 or 					Vector2(x1 - x0, z1 - z0).length() > 0.0:
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


## Коллизия земли из уже готовой сетки рельефа: вершины совпадают с видимым
## мешем (то же разбиение по короткой диагонали), поэтому колёса чувствуют ровно
## то, что видит игрок.
func _ground_collision_from_grid(rect: Rect2, origin: Vector3) -> Dictionary:
	var rows := _ground_grid_rows
	var step := _ground_grid_step
	# Сетка глобальная, поэтому её начало может лежать левее/выше чанка: ищем
	# индекс первой вершины внутри чанка.
	var first_x := maxi(int(floorf((origin.x - _ground_grid_base_x) / step)), 0)
	var first_z := maxi(int(floorf((origin.z - _ground_grid_base_z) / step)), 0)
	var last_x := mini(int(ceilf((origin.x + config.chunk_size_m - _ground_grid_base_x) / step)), rows - 2)
	var last_z := mini(int(ceilf((origin.z + config.chunk_size_m - _ground_grid_base_z) / step)), rows - 2)
	if last_x <= first_x or last_z <= first_z:
		return {}
	var faces := PackedVector3Array()
	faces.resize((last_z - first_z) * (last_x - first_x) * 6)
	var write := 0
	for iz in range(first_z, last_z):
		for ix in range(first_x, last_x):
			var x0 := _ground_grid_base_x + float(ix) * step
			var x1 := x0 + step
			var z0 := _ground_grid_base_z + float(iz) * step
			var z1 := z0 + step
			var h00 := _ground_grid_heights[iz * rows + ix]
			var h10 := _ground_grid_heights[iz * rows + ix + 1]
			var h01 := _ground_grid_heights[(iz + 1) * rows + ix]
			var h11 := _ground_grid_heights[(iz + 1) * rows + ix + 1]
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
