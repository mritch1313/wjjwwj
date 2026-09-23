class_name TerrainField
extends RefCounted

## The single source of truth for terrain shape and surface type.
##
## Performance design (mobile first):
##   * The expensive low frequency part of the terrain (hills, the world rim,
##     the lake basin, the flattening around the city, desert dunes) is baked
##     once into a coarse 32 m grid - 129 x 129 samples for the default 4 km
##     world - and read back with bicubic interpolation.
##   * Only two cheap value-noise octaves are evaluated per sample, plus the
##     road flattening lookup, which uses the road network's spatial hash.
##   * Everything is deterministic: the same (x, z) always gives the same height,
##     which is what allows the visual mesh and the physics height field to be
##     generated independently and still match.

const GRID_STEP := 32.0
## Радиус поиска дороги, достаточный для выравнивания рельефа и типа покрытия
## (максимум half_width + shoulder = 22 м на шоссе).
const ROAD_QUERY_RADIUS_M := 24.0
const GRID_MARGIN := 64.0

var config: WorldConfig
var region_map: RegionMap

var grid_build_time_ms: float = 0.0
var _grid: PackedFloat32Array = PackedFloat32Array()
## Кэш последнего поиска дороги (см. _nearest_road_cached).  Лежит в одном
## словаре и читается одной ссылкой: генерация чанков идёт в фоновом потоке, а
## физика в главном, и разрозненные поля могли бы дать "сшитое" значение из
## разных записей.
var _road_cache_entry: Dictionary = {}
var _urban_mask: PackedFloat32Array = PackedFloat32Array()
var _desert_mask: PackedFloat32Array = PackedFloat32Array()
var _forest_mask: PackedFloat32Array = PackedFloat32Array()
var _lake_mask: PackedFloat32Array = PackedFloat32Array()
var _grid_size: int = 0
var _grid_origin: float = 0.0
var _road_network: RoadNetwork = null


func _init(world_config: WorldConfig, world_region_map: RegionMap = null) -> void:
	config = world_config
	region_map = world_region_map if world_region_map != null else RegionMap.new(world_config)
	_build_grid()


## Roads are attached after the road network was generated from this field's
## *base* heights (a two step process, otherwise the two would depend on each
## other in a circle).
func attach_road_network(network: RoadNetwork) -> void:
	_road_network = network


func road_network() -> RoadNetwork:
	return _road_network


## ---------------------------------------------------------------- grid build
func _grid_index(ix: int, iz: int) -> int:
	return iz * _grid_size + ix


func _build_grid() -> void:
	var started := Time.get_ticks_msec()
	_grid_size = int(ceil((config.world_size_m + GRID_MARGIN * 2.0) / GRID_STEP)) + 1
	_grid_origin = -(config.world_size_m * 0.5 + GRID_MARGIN)
	var count := _grid_size * _grid_size
	_grid.resize(count)
	_urban_mask.resize(count)
	_desert_mask.resize(count)
	_forest_mask.resize(count)
	_lake_mask.resize(count)
	var half := config.world_half_extent()
	for iz in range(_grid_size):
		var z := _grid_origin + float(iz) * GRID_STEP
		for ix in range(_grid_size):
			var x := _grid_origin + float(ix) * GRID_STEP
			var index := _grid_index(ix, iz)
			var weights := region_map.weights_at(Vector3(x, 0.0, z))
			var urban := float(weights[RegionMap.Region.CITY_CORE]) + float(weights[RegionMap.Region.CITY]) + float(weights[RegionMap.Region.SUBURB]) * 0.6
			var desert := float(weights[RegionMap.Region.DESERT])
			var forest := float(weights[RegionMap.Region.FOREST])
			var lake := float(weights[RegionMap.Region.LAKE])
			_urban_mask[index] = urban
			_desert_mask[index] = desert
			_forest_mask[index] = forest
			_lake_mask[index] = lake
			_grid[index] = _grid_value(x, z, urban, desert, forest, lake, half)
	grid_build_time_ms = float(Time.get_ticks_msec() - started)


## Low frequency terrain: hills, rim, dunes, city plateau and the lake basin.
func _grid_value(x: float, z: float, urban: float, desert: float, forest: float, lake: float, half: float) -> float:
	var frequency := config.terrain_base_frequency
	var big := MathUtils.fbm_2d(x * frequency, z * frequency, 4, 11)
	var ridge := 1.0 - absf(big * 2.0 - 1.0)
	ridge = ridge * ridge
	var height := (big - 0.5) * config.terrain_height_scale
	height += (ridge - 0.45) * config.terrain_height_scale * 0.85

	# rolling countryside is calmer than the hills
	height *= lerpf(1.0, 0.55, forest)

	# city sits on a gently undulating plateau so blocks stay buildable
	var city_datum := 2.0 + (MathUtils.value_noise_2d(x * 0.0016, z * 0.0016, 31) - 0.5) * 2.4
	height = lerpf(height, city_datum, clampf(urban, 0.0, 1.0) * 0.93)

	# desert dunes - long, low ridges
	if desert > 0.01:
		var dune := sin(x * 0.019 + MathUtils.value_noise_2d(x * 0.002, z * 0.002, 41) * 3.0) * 0.5
		dune += sin((x * 0.6 + z * 0.8) * 0.011) * 0.5
		height += dune * 7.5 * desert

	# lake basin (a bowl that reaches below the water level)
	if lake > 0.001:
		var depth := config.water_level - 7.0 - MathUtils.value_noise_2d(x * 0.004, z * 0.004, 51) * 3.0
		height = lerpf(height, depth, clampf(lake, 0.0, 1.0))

	# rim hills: the map folds upwards towards its border
	var distance := Vector2(x, z).length()
	var rim := smoothstep(half * config.border_hill_start, half * 1.02, distance)
	if rim > 0.0:
		var rim_hill := (0.35 + 0.65 * ridge) * (0.55 + 0.45 * MathUtils.value_noise_2d(x * 0.008, z * 0.008, 61))
		height += rim * config.border_hill_height * rim_hill
	return height


func _grid_at(ix: int, iz: int) -> float:
	var cx := clampi(ix, 0, _grid_size - 1)
	var cz := clampi(iz, 0, _grid_size - 1)
	return _grid[_grid_index(cx, cz)]


func _mask_at(mask: PackedFloat32Array, ix: int, iz: int) -> float:
	var cx := clampi(ix, 0, _grid_size - 1)
	var cz := clampi(iz, 0, _grid_size - 1)
	return mask[_grid_index(cx, cz)]


func _catmull(p0: float, p1: float, p2: float, p3: float, t: float) -> float:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * (
		(2.0 * p1)
		+ (-p0 + p2) * t
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
	)


## Bicubic sample of one grid channel.
func _sample_grid(channel: PackedFloat32Array, x: float, z: float) -> float:
	var gx := (x - _grid_origin) / GRID_STEP
	var gz := (z - _grid_origin) / GRID_STEP
	var ix := int(floor(gx))
	var iz := int(floor(gz))
	var fx := gx - float(ix)
	var fz := gz - float(iz)
	var rows := PackedFloat32Array()
	rows.resize(4)
	for row in range(4):
		rows[row] = _catmull(
			_mask_at(channel, ix - 1, iz + row - 1),
			_mask_at(channel, ix, iz + row - 1),
			_mask_at(channel, ix + 1, iz + row - 1),
			_mask_at(channel, ix + 2, iz + row - 1),
			fx
		)
	return _catmull(rows[0], rows[1], rows[2], rows[3], fz)


func grid_height(x: float, z: float) -> float:
	return _sample_grid(_grid, x, z)


func urban_at(x: float, z: float) -> float:
	return clampf(_sample_grid(_urban_mask, x, z), 0.0, 1.0)


func desert_at(x: float, z: float) -> float:
	return clampf(_sample_grid(_desert_mask, x, z), 0.0, 1.0)


func forest_at(x: float, z: float) -> float:
	return clampf(_sample_grid(_forest_mask, x, z), 0.0, 1.0)


func lake_at(x: float, z: float) -> float:
	return clampf(_sample_grid(_lake_mask, x, z), 0.0, 1.0)


## ---------------------------------------------------------------- height api
## Terrain height *without* road flattening (used while building roads).
func base_height(x: float, z: float) -> float:
	var height := grid_height(x, z)
	height += (MathUtils.value_noise_2d(x * 0.0042, z * 0.0042, 71) - 0.5) * config.terrain_detail_strength * 3.4
	height += (MathUtils.value_noise_2d(x * 0.021, z * 0.021, 72) - 0.5) * config.terrain_detail_strength * 0.8
	return height


func base_height_at(position: Vector3) -> float:
	return base_height(position.x, position.z)


## Final height: base terrain flattened towards the road surface.

## Ближайшая дорога с кэшем на одну точку.  Генерация чанка спрашивает высоту и
## тип покрытия для одного и того же (x, z) подряд, а сам поиск - самая дорогая
## операция в сэмплировании рельефа: без кэша он выполнялся на каждый сэмпл
## дважды.
func _nearest_road_cached(x: float, z: float, position: Vector3, radius: float) -> Dictionary:
	var entry := _road_cache_entry
	if not entry.is_empty():
		if float(entry.get("x", INF)) == x and float(entry.get("z", INF)) == z \
				and radius <= float(entry.get("radius", 0.0)):
			var cached: Dictionary = entry.get("road", {})
			if cached.is_empty():
				return cached
			if float(cached.get("distance", 0.0)) <= radius:
				return cached
			return {}
	var road := _road_network.nearest_road(position, radius)
	_road_cache_entry = {"x": x, "z": z, "radius": radius, "road": road}
	return road


func height_at(x: float, z: float) -> float:
	var height := base_height(x, z)
	if _road_network == null:
		return height
	var position := Vector3(x, height, z)
	# 24 м: выравнивание рельефа действует в пределах half_width + shoulder, а
	# самый широкий случай (шоссе) даёт 8 + 14 = 22 м.  Этот вызов идёт на каждый
	# сэмпл высоты, поэтому кэшируется и ищется по узким ячейкам индекса.
	var road := _nearest_road_cached(x, z, position, ROAD_QUERY_RADIUS_M)
	if road.is_empty():
		return height
	var segment: RoadNetwork.Segment = _road_network.segments[int(road["segment"])]
	if segment.elevated:
		return height
	var distance: float = road["distance"]
	var half_width := segment.width * 0.5
	var shoulder := _shoulder_for(segment.type)
	if distance > half_width + shoulder:
		return height
	var road_point: Vector3 = road["point"]
	var weight := 1.0 - smoothstep(half_width + shoulder * 0.3, half_width + shoulder, distance)
	return lerpf(height, road_point.y, clampf(weight, 0.0, 1.0))


func height_3d(x: float, z: float) -> Vector3:
	return Vector3(x, height_at(x, z), z)


func _shoulder_for(road_type: int) -> float:
	match road_type:
		RoadNetwork.RoadType.HIGHWAY: return 14.0
		RoadNetwork.RoadType.RAMP: return 9.0
		RoadNetwork.RoadType.AVENUE: return 6.0
		RoadNetwork.RoadType.STREET: return 4.0
		RoadNetwork.RoadType.SERVICE: return 5.0
		RoadNetwork.RoadType.DIRT: return 6.0
		RoadNetwork.RoadType.BRIDGE: return 8.0
		_: return 7.0


## Slope in [0, 1] (0 = flat, 1 = vertical-ish).  Uses the coarse grid only,
## which is enough for prop placement and vegetation rules.
func slope_at(x: float, z: float, sample_step: float = 8.0) -> float:
	var hx := _sample_grid(_grid, x + sample_step, z) - _sample_grid(_grid, x - sample_step, z)
	var hz := _sample_grid(_grid, x, z + sample_step) - _sample_grid(_grid, x, z - sample_step)
	var gradient := Vector2(hx, hz) / (2.0 * sample_step)
	return clampf(gradient.length(), 0.0, 1.0)


func normal_at(x: float, z: float, sample_step: float = 4.0) -> Vector3:
	var hx := height_at(x + sample_step, z) - height_at(x - sample_step, z)
	var hz := height_at(x, z + sample_step) - height_at(x, z - sample_step)
	return Vector3(-hx / (2.0 * sample_step), 1.0, -hz / (2.0 * sample_step)).normalized()


func altitude_at(position: Vector3) -> float:
	return height_at(position.x, position.z)


func underwater(x: float, z: float) -> bool:
	return height_at(x, z) < config.water_level


## -------------------------------------------------------------- surface api
## Surface type at a world position.  Road surfaces always win, then the water
## and region rules.
func surface_at(x: float, z: float, height: float = INF) -> int:
	var h := height_at(x, z) if is_inf(height) else height
	if _road_network != null:
		var position := Vector3(x, h, z)
		# см. комментарий в height_at: шире ROAD_QUERY_RADIUS_M дорога уже не влияет
		var road := _nearest_road_cached(x, z, position, ROAD_QUERY_RADIUS_M)
		if not road.is_empty():
			var distance: float = road["distance"]
			var segment: RoadNetwork.Segment = _road_network.segments[int(road["segment"])]
			if not segment.elevated or absf(segment.points[0].y - h) < 6.0:
				if distance <= segment.width * 0.5:
					return segment.surface
				if distance <= segment.width * 0.5 + 3.4 and _is_city_road(segment):
					return Surface.Type.PAVEMENT
				if distance <= segment.width * 0.5 + 5.0:
					return Surface.Type.GRAVEL
	if h < config.water_level:
		return Surface.Type.WATER
	var desert := desert_at(x, z)
	var lake := lake_at(x, z)
	var slope := slope_at(x, z)
	var patch := MathUtils.value_noise_2d(x * 0.012, z * 0.012, 81)
	if lake > 0.35:
		return Surface.Type.SAND
	if desert > 0.4:
		if patch > 0.72 and slope > 0.25:
			return Surface.Type.GRAVEL
		return Surface.Type.SAND
	if slope > 0.66:
		return Surface.Type.GRAVEL
	if patch > 0.86:
		return Surface.Type.DIRT
	return Surface.Type.GRASS


func _is_city_road(segment: RoadNetwork.Segment) -> bool:
	if segment.type == RoadNetwork.RoadType.STREET or segment.type == RoadNetwork.RoadType.AVENUE:
		return true
	return segment.type == RoadNetwork.RoadType.SERVICE and urban_at(segment.points[0].x, segment.points[0].z) > 0.35


## Material name for the terrain mesh under a given region.
func terrain_material_at(x: float, z: float, surface: int) -> String:
	match surface:
		Surface.Type.SAND:
			return "sand"
		Surface.Type.GRAVEL:
			return "ground_gravel"
		Surface.Type.DIRT:
			return "ground_dirt"
		Surface.Type.GRASS:
			var wet := forest_at(x, z)
			var dry := desert_at(x, z)
			if wet > 0.5:
				return "grass"
			if dry > 0.35:
				return "grass_dry"
			return "grass" if MathUtils.value_noise_2d(x * 0.006, z * 0.006, 91) < 0.62 else "grass_dry"
		Surface.Type.WATER:
			return "ground_dirt"
		_:
			return "grass"


## Vertex colour tint for the terrain mesh (dry/urban variation).
func terrain_tint_at(x: float, z: float) -> Color:
	var patch := MathUtils.value_noise_2d(x * 0.05, z * 0.05, 101)
	var urban := urban_at(x, z)
	var desert := desert_at(x, z)
	var shade := 0.86 + 0.28 * patch
	shade *= lerpf(1.0, 0.94, urban)
	var tint := Color(shade, shade * (1.0 - desert * 0.05), shade * (0.94 - desert * 0.06), 1.0)
	return tint


## Ground level for entity placement (keeps cars/props slightly above the mesh).
func ground_position(x: float, z: float, lift: float = 0.0) -> Vector3:
	return Vector3(x, height_at(x, z) + lift, z)
