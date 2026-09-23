class_name BuildingFactory
extends RefCounted

## Procedural buildings.  Nothing here is a plain cube: every style combines a
## main volume with setbacks, a plinth, floor bands, window modules, roof
## details (parapet, AC units, stair box, water tank), entrances and - for
## shops and houses - awnings, signs, balconies or a porch.
##
## UV convention: facade textures cover 4 m x 3 m, so uv_scale = (1/4, 1/3) maps
## a wall of `height` metres onto exactly `height / 3` texture rows = floors.
##
## Each build_* function returns:
##   { "colliders": [...], "height": float, "footprint": Vector2, "style": String,
##     "frontage": Vector3 }   # frontage = outward direction of the shop front

const FACADE_UV := Vector2(0.25, 1.0 / 3.0)

const FACADE_MATERIALS_CITY := [
	"facade_brick_a", "facade_brick_b", "facade_plaster_a", "facade_plaster_b",
	"facade_concrete_a", "facade_concrete_b",
]
const FACADE_MATERIALS_DOWNTOWN := [
	"facade_office", "facade_glass", "facade_concrete_b", "facade_concrete_a",
]
const ROOF_MATERIALS := ["roof_flat", "roof_flat", "roof_gravel"]


static func _t(position: Vector3, yaw: float = 0.0, scale: float = 1.0) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(scale, scale, scale)), position)


static func pick_facade(style: String, rng: RandomNumberGenerator) -> String:
	if style == "downtown":
		return FACADE_MATERIALS_DOWNTOWN[rng.randi_range(0, FACADE_MATERIALS_DOWNTOWN.size() - 1)]
	return FACADE_MATERIALS_CITY[rng.randi_range(0, FACADE_MATERIALS_CITY.size() - 1)]


static func _roof_details(
	builder: MeshBuilder,
	center: Vector3,
	yaw: float,
	size: Vector2,
	height: float,
	rng: RandomNumberGenerator,
	large: bool
) -> void:
	var base := _t(center + Vector3(0.0, height, 0.0), yaw)
	# parapet
	var parapet_height := 0.7 + rng.randf() * 0.35
	for side in range(4):
		var angle := PI * 0.5 * float(side)
		var half := (size.x if side % 2 == 0 else size.y) * 0.5
		var lateral := (size.y if side % 2 == 0 else size.x) * 0.5
		var offset := Vector3(sin(angle) * lateral, 0.0, cos(angle) * lateral)
		var rail := _t(offset, angle + PI * 0.5)
		builder.add_box(
			"concrete_wall",
			base * rail * _t(Vector3(0.0, parapet_height * 0.5, 0.0)),
			Vector3(half * 2.0, parapet_height, 0.22),
			Color(0.94, 0.94, 0.92)
		)
	# stair box
	var stair_size := Vector3(minf(size.x, 4.5) * 0.4, 2.6 + rng.randf(), minf(size.y, 4.5) * 0.4)
	builder.add_box(
		"concrete_wall",
		base * _t(Vector3(size.x * rng.randf_range(-0.22, 0.22), stair_size.y * 0.5, size.y * rng.randf_range(-0.22, 0.22))),
		stair_size, Color(0.9, 0.9, 0.88)
	)
	# Колпак лестничной будки и вентиляторные патрубки - только у крупных
	# зданий: с земли и с третьего лица эти детали на крыше неразличимы, а
	# каждая из них стоит десятки треугольников в каждом чанке города.
	if large:
		builder.add_box(
			"roof_metal",
			base * _t(Vector3(size.x * rng.randf_range(-0.22, 0.22), stair_size.y + 0.08, size.y * rng.randf_range(-0.22, 0.22))),
			Vector3(stair_size.x + 0.3, 0.16, stair_size.z + 0.3), Color(0.9, 0.9, 0.92)
		)
	# AC / ventilation units
	var units := rng.randi_range(2, 5) if large else 1
	for i in range(units):
		var unit_size := Vector3(rng.randf_range(0.9, 1.9), rng.randf_range(0.7, 1.3), rng.randf_range(0.9, 1.7))
		var offset := Vector3(
			rng.randf_range(-size.x * 0.3, size.x * 0.3),
			unit_size.y * 0.5,
			rng.randf_range(-size.y * 0.3, size.y * 0.3)
		)
		builder.add_box("metal_grey", base * _t(offset, rng.randf() * TAU), unit_size, Color(0.88, 0.9, 0.92))
		if large:
			builder.add_cylinder(
				"metal_dark",
				base * _t(offset + Vector3(0.0, unit_size.y * 0.5 + 0.05, 0.0)),
				unit_size.x * 0.28, unit_size.x * 0.28, 0.1, 8, Color(0.8, 0.82, 0.84)
			)
	# water tank / antenna on taller buildings
	if height > 22.0 and rng.randf() < 0.6:
		var tank_height := 2.4
		builder.add_cylinder(
			"metal_corrugated",
			base * _t(Vector3(size.x * 0.28, tank_height * 0.5, -size.y * 0.28)),
			1.25, 1.25, tank_height, 10, Color(0.9, 0.92, 0.94)
		)
	if height > 30.0 and rng.randf() < 0.7:
		var mast_height := rng.randf_range(4.0, 9.0)
		builder.add_cylinder(
			"metal_grey",
			base * _t(Vector3(-size.x * 0.25, mast_height * 0.5, size.y * 0.25)),
			0.12, 0.06, mast_height, 6, Color(0.9, 0.9, 0.92)
		)
		builder.add_cylinder(
			"lamp_glass",
			base * _t(Vector3(-size.x * 0.25, mast_height + 0.25, size.y * 0.25)),
			0.12, 0.08, 0.5, 6, Color(1.0, 0.3, 0.2)
		)


static func _entrance(builder: MeshBuilder, base: Transform3D, width: float, facade_material: String, covered: bool) -> void:
	var door_width := 1.6
	var door_height := 2.35
	builder.add_box("metal_dark", base * _t(Vector3(0.0, door_height * 0.5, 0.06)), Vector3(door_width, door_height, 0.12), Color(0.9, 0.9, 0.92))
	builder.add_box("car_glass", base * _t(Vector3(0.0, door_height * 0.62, 0.0)), Vector3(door_width * 0.75, door_height * 0.5, 0.1), Color(0.85, 0.9, 0.95))
	builder.add_box("concrete", base * _t(Vector3(0.0, 0.09, 0.5)), Vector3(door_width + 1.6, 0.18, 1.2), Color(0.95, 0.95, 0.93))
	if covered:
		for sx in [-1.0, 1.0]:
			builder.add_box("metal_grey", base * _t(Vector3(sx * door_width * 0.75, 1.35, 0.6)), Vector3(0.14, 2.7, 0.14), Color(0.9, 0.9, 0.92))
		builder.add_box("concrete_wall", base * _t(Vector3(0.0, 2.75, 0.6)), Vector3(door_width * 1.9, 0.22, 1.5), Color(0.92, 0.92, 0.9))


## ---------------------------------------------------------------- downtown --
## Tall office / glass tower with setbacks and a detailed crown.
static func build_tower(
	builder: MeshBuilder,
	origin: Vector3,
	yaw: float,
	width: float,
	depth: float,
	height: float,
	rng: RandomNumberGenerator
) -> Dictionary:
	var facade := pick_facade("downtown", rng)
	var colliders := []
	var plinth_height := 1.2
	builder.add_box("plinth", _t(origin + Vector3(0.0, plinth_height * 0.5, 0.0), yaw), Vector3(width + 0.5, plinth_height, depth + 0.5), Color(0.92, 0.92, 0.9))

	# Two or three stacked volumes with setbacks - reads as a real tower.
	var remaining := height
	var level_count := 2 if height < 45.0 else 3
	var level_height := height / float(level_count)
	var level_width := width
	var level_depth := depth
	var y := plinth_height
	for level in range(level_count):
		var taper := 1.0 - 0.14 * float(level)
		var is_last := level == level_count - 1
		var segment_height := level_height * (0.78 if is_last else 1.0)
		builder.add_box(
			facade,
			_t(origin + Vector3(0.0, y + segment_height * 0.5, 0.0), yaw),
			Vector3(level_width * taper, segment_height, level_depth * taper),
			Color(0.88 + rng.randf() * 0.24, 0.9 + rng.randf() * 0.2, 0.92 + rng.randf() * 0.18),
			FACADE_UV,
			"roof_flat"
		)
		colliders.append({
			"shape": "box",
			"transform": _t(origin + Vector3(0.0, y + segment_height * 0.5, 0.0), yaw),
			"size": Vector3(level_width * taper, segment_height, level_depth * taper),
		})
		# floor band at the top of each volume
		builder.add_box(
			"concrete_wall",
			_t(origin + Vector3(0.0, y + segment_height - 0.25, 0.0), yaw),
			Vector3(level_width * taper + 0.45, 0.5, level_depth * taper + 0.45),
			Color(0.95, 0.95, 0.94)
		)
		y += segment_height
		level_width *= taper
		level_depth *= taper
	remaining = height - (y - plinth_height)

	# vertical mullions on the ground volume
	var columns := int(maxf(width / 4.6, 2.0))
	for i in range(columns + 1):
		var x := -width * 0.5 + width * float(i) / float(columns)
		builder.add_box(
			"concrete_wall",
			_t(origin + Vector3(0.0, plinth_height + level_height * 0.5, 0.0), yaw) * _t(Vector3(x, 0.0, depth * 0.5 + 0.12)),
			Vector3(0.32, level_height, 0.3), Color(0.9, 0.9, 0.88)
		)
		builder.add_box(
			"concrete_wall",
			_t(origin + Vector3(0.0, plinth_height + level_height * 0.5, 0.0), yaw) * _t(Vector3(x, 0.0, -depth * 0.5 - 0.12)),
			Vector3(0.32, level_height, 0.3), Color(0.9, 0.9, 0.88)
		)

	# crown
	builder.add_box(
		"metal_corrugated",
		_t(origin + Vector3(0.0, y + 0.4, 0.0), yaw),
		Vector3(level_width * 0.55, 0.8, level_depth * 0.55), Color(0.92, 0.94, 0.96)
	)
	_roof_details(builder, origin + Vector3(0.0, 0.0, 0.0), yaw, Vector2(width, depth), y - 0.0, rng, true)
	_entrance(builder, _t(origin + Vector3(0.0, 0.0, depth * 0.5 + 0.02), yaw), width, facade, true)
	return {
		"colliders": colliders,
		"height": height,
		"footprint": Vector2(width, depth),
		"style": "tower",
		"frontage": Vector3(sin(yaw), 0.0, cos(yaw)),
	}


## ------------------------------------------------------------- city block --
## Mid rise residential / commercial block with floor bands and balconies.
static func build_block(
	builder: MeshBuilder,
	origin: Vector3,
	yaw: float,
	width: float,
	depth: float,
	height: float,
	rng: RandomNumberGenerator,
	style: String = "city"
) -> Dictionary:
	var facade := pick_facade(style, rng)
	var roof: String = ROOF_MATERIALS[rng.randi_range(0, ROOF_MATERIALS.size() - 1)]
	var colliders := []
	var floors := maxi(int(round(height / 3.2)), 1)
	var plinth_height := 0.9
	builder.add_box("plinth", _t(origin + Vector3(0.0, plinth_height * 0.5, 0.0), yaw), Vector3(width + 0.4, plinth_height, depth + 0.4), Color(0.9, 0.9, 0.88))
	builder.add_box(
		facade,
		_t(origin + Vector3(0.0, plinth_height + (height - plinth_height) * 0.5, 0.0), yaw),
		Vector3(width, height - plinth_height, depth),
		Color(0.9 + rng.randf() * 0.2, 0.92 + rng.randf() * 0.16, 0.9 + rng.randf() * 0.2),
		FACADE_UV,
		roof
	)
	colliders.append({
		"shape": "box",
		"transform": _t(origin + Vector3(0.0, height * 0.5, 0.0), yaw),
		"size": Vector3(width, height, depth),
	})
	# floor bands: every third floor is enough for the eye at 720p and cuts the
	# number of boxes in a district by two thirds
	for floor in range(1, floors, 3):
		var y := plinth_height + float(floor) * ((height - plinth_height) / float(floors))
		builder.add_box(
			"concrete_wall",
			_t(origin + Vector3(0.0, y, 0.0), yaw),
			Vector3(width + 0.32, 0.24, depth + 0.32),
			Color(0.94, 0.94, 0.92)
		)
	# balconies on the street side
	if rng.randf() < 0.75 and floors >= 2:
		var balcony_count := maxi(int(width / 4.2), 1)
		for floor in range(1, floors, 3):
			if rng.randf() < 0.25:
				continue
			var y := plinth_height + float(floor) * ((height - plinth_height) / float(floors)) - 1.5
			for b in range(balcony_count):
				if rng.randf() < 0.25:
					continue
				var x := -width * 0.5 + width * (float(b) + 0.5) / float(balcony_count)
				var balcony := _t(origin + Vector3(0.0, y, 0.0), yaw) * _t(Vector3(x, 0.0, depth * 0.5))
				builder.add_box("concrete_wall", balcony * _t(Vector3(0.0, 0.06, 0.55)), Vector3(2.4, 0.16, 1.3), Color(0.95, 0.95, 0.93))
				builder.add_foliage_planes("fence_bars", balcony * _t(Vector3(0.0, 0.2, 1.18)), Vector2(2.4, 1.0), 1, Color(0.9, 0.9, 0.9))
				builder.add_foliage_planes("fence_bars", balcony * _t(Vector3(-1.2, 0.2, 0.55), PI * 0.5), Vector2(1.2, 1.0), 1, Color(0.9, 0.9, 0.9))
				builder.add_foliage_planes("fence_bars", balcony * _t(Vector3(1.2, 0.2, 0.55), PI * 0.5), Vector2(1.2, 1.0), 1, Color(0.9, 0.9, 0.9))
	_roof_details(builder, origin, yaw, Vector2(width, depth), height, rng, height > 18.0)
	if width >= 9.0:
		_entrance(builder, _t(origin + Vector3(0.0, 0.0, depth * 0.5 + 0.02), yaw), width, facade, rng.randf() < 0.5)
	return {
		"colliders": colliders,
		"height": height,
		"footprint": Vector2(width, depth),
		"style": "block",
		"frontage": Vector3(sin(yaw), 0.0, cos(yaw)),
	}


## ------------------------------------------------------------- shop front --
## 2-3 storey building with a glazed shop front, sign band and awning.
static func build_shop_row(
	builder: MeshBuilder,
	origin: Vector3,
	yaw: float,
	width: float,
	depth: float,
	height: float,
	rng: RandomNumberGenerator
) -> Dictionary:
	var facade := pick_facade("city", rng)
	var colliders := []
	var ground_height := 3.4
	var upper_height := maxf(height - ground_height, 0.0)
	builder.add_box("plinth", _t(origin + Vector3(0.0, 0.35, 0.0), yaw), Vector3(width + 0.3, 0.7, depth + 0.3), Color(0.9, 0.9, 0.88))
	if upper_height > 0.4:
		builder.add_box(
			facade,
			_t(origin + Vector3(0.0, ground_height + upper_height * 0.5, 0.0), yaw),
			Vector3(width, upper_height, depth),
			Color(0.9 + rng.randf() * 0.2, 0.9 + rng.randf() * 0.18, 0.9 + rng.randf() * 0.2),
			FACADE_UV,
			"roof_flat"
		)
	colliders.append({
		"shape": "box", "transform": _t(origin + Vector3(0.0, height * 0.5, 0.0), yaw),
		"size": Vector3(width, height, depth),
	})
	# glazed ground floor with columns between bays
	builder.add_box(
		"facade_storefront",
		_t(origin + Vector3(0.0, ground_height * 0.5, 0.0), yaw),
		Vector3(width, ground_height, depth),
		Color(0.95, 0.95, 0.96),
		FACADE_UV,
		"roof_flat"
	)
	var bays := maxi(int(width / 3.6), 1)
	for i in range(bays + 1):
		var x := -width * 0.5 + width * float(i) / float(bays)
		builder.add_box(
			"concrete_wall",
			_t(origin, yaw) * _t(Vector3(x, ground_height * 0.5, depth * 0.5 + 0.16)),
			Vector3(0.42, ground_height, 0.36), Color(0.92, 0.92, 0.9)
		)
	# sign band
	var sign_material := "shop_sign_%s" % ["a", "b", "c", "d"][rng.randi_range(0, 3)]
	builder.add_billboard(
		sign_material,
		_t(origin + Vector3(0.0, ground_height - 0.55, 0.0), yaw) * _t(Vector3(0.0, 0.0, depth * 0.5 + 0.18)),
		Vector2(width * 0.9, 0.9), Color(1, 1, 1)
	)
	# awning
	if rng.randf() < 0.6:
		var awning_material := "awning_%s" % ["a", "b", "c"][rng.randi_range(0, 2)]
		var awning := _t(origin + Vector3(0.0, ground_height - 1.35, depth * 0.5 + 0.9), yaw)
		builder.add_quad(
			awning_material,
			awning * Vector3(-width * 0.42, 0.35, -0.9),
			awning * Vector3(width * 0.42, 0.35, -0.9),
			awning * Vector3(width * 0.42, -0.1, 0.5),
			awning * Vector3(-width * 0.42, -0.1, 0.5),
			Color(1, 1, 1),
			Vector2(0, 0), Vector2(1, 0), Vector2(1, 1), Vector2(0, 1),
			Vector3(0.0, 1.0, 0.25).normalized()
		)
	_roof_details(builder, origin, yaw, Vector2(width, depth), height, rng, false)
	return {
		"colliders": colliders,
		"height": height,
		"footprint": Vector2(width, depth),
		"style": "shop",
		"frontage": Vector3(sin(yaw), 0.0, cos(yaw)),
	}


## Упрощённый дом для среднего LOD (tier 1): три коробки вместо полноценной
## застройки.  Средние чанки видны с 200-400 м, где балконы и крышные детали
## уже не различимы, а платить за них треугольниками приходится всем чанкам
## кольца вокруг игрока (раньше средний уровень строил почти полную детализацию
## и обходился дороже ближнего).
static func build_simple_block(
	builder: MeshBuilder,
	origin: Vector3,
	yaw: float,
	width: float,
	depth: float,
	height: float,
	rng: RandomNumberGenerator,
	style: String = "city"
) -> void:
	var facade := pick_facade(style, rng)
	var plinth_height := 0.8
	builder.add_box("plinth", _t(origin + Vector3(0.0, plinth_height * 0.5, 0.0), yaw),
		Vector3(width + 0.4, plinth_height, depth + 0.4), Color(0.9, 0.9, 0.88))
	builder.add_box(
		facade,
		_t(origin + Vector3(0.0, plinth_height + (height - plinth_height) * 0.5, 0.0), yaw),
		Vector3(width, height - plinth_height, depth),
		Color(0.9 + rng.randf() * 0.18, 0.92 + rng.randf() * 0.14, 0.92 + rng.randf() * 0.16),
		FACADE_UV,
		"roof_flat"
	)
	# thin cornice under the roof: без него силуэт снова читается как голая коробка
	builder.add_box("concrete_wall", _t(origin + Vector3(0.0, height - 0.12, 0.0), yaw),
		Vector3(width + 0.32, 0.24, depth + 0.32), Color(0.94, 0.94, 0.92))


## -------------------------------------------------------------- warehouse --
static func build_warehouse(
	builder: MeshBuilder,
	origin: Vector3,
	yaw: float,
	width: float,
	depth: float,
	height: float,
	rng: RandomNumberGenerator
) -> Dictionary:
	var colliders := []
	builder.add_box("plinth", _t(origin + Vector3(0.0, 0.3, 0.0), yaw), Vector3(width + 0.4, 0.6, depth + 0.4), Color(0.9, 0.9, 0.9))
	builder.add_box(
		"facade_industrial",
		_t(origin + Vector3(0.0, height * 0.5, 0.0), yaw),
		Vector3(width, height, depth),
		Color(0.9 + rng.randf() * 0.18, 0.92 + rng.randf() * 0.14, 0.94),
		FACADE_UV,
		"roof_flat"
	)
	colliders.append({
		"shape": "box", "transform": _t(origin + Vector3(0.0, height * 0.5, 0.0), yaw),
		"size": Vector3(width, height, depth),
	})
	# pitched metal roof
	builder.add_gable_roof(
		"roof_metal",
		_t(origin + Vector3(0.0, height, 0.0), yaw),
		Vector3(width + 0.6, height * 0.22, depth + 0.6),
		Color(0.92, 0.94, 0.96),
		Vector2(0.12, 0.12)
	)
	# roller doors + loading dock
	var doors := maxi(int(width / 9.0), 1)
	for i in range(doors):
		var x := -width * 0.5 + width * (float(i) + 0.5) / float(doors)
		builder.add_box(
			"facade_roller_door",
			_t(origin, yaw) * _t(Vector3(x, 2.2, depth * 0.5 + 0.08)),
			Vector3(3.8, 4.4, 0.16), Color(0.95, 0.95, 0.95)
		)
		builder.add_box(
			"marking_white",
			_t(origin, yaw) * _t(Vector3(x, 4.45, depth * 0.5 + 0.1)),
			Vector3(4.2, 0.16, 0.3), Color(1, 1, 1)
		)
	# roof vents
	for i in range(rng.randi_range(2, 5)):
		var vent := _t(origin + Vector3(rng.randf_range(-width * 0.35, width * 0.35), height, rng.randf_range(-depth * 0.35, depth * 0.35)), yaw)
		builder.add_cylinder("metal_grey", vent * _t(Vector3(0.0, 0.5, 0.0)), 0.35, 0.3, 1.0, 8, Color(0.9, 0.9, 0.92))
	return {
		"colliders": colliders,
		"height": height,
		"footprint": Vector2(width, depth),
		"style": "warehouse",
		"frontage": Vector3(sin(yaw), 0.0, cos(yaw)),
	}


## ------------------------------------------------------------------ house --
static func build_house(
	builder: MeshBuilder,
	origin: Vector3,
	yaw: float,
	width: float,
	depth: float,
	floors: int,
	rng: RandomNumberGenerator,
	roof_style: int = 0
) -> Dictionary:
	var facade: String = FACADE_MATERIALS_CITY[rng.randi_range(0, FACADE_MATERIALS_CITY.size() - 1)]
	var height := float(floors) * 3.0 + 0.5
	var colliders := []
	builder.add_box("plinth", _t(origin + Vector3(0.0, 0.28, 0.0), yaw), Vector3(width + 0.3, 0.56, depth + 0.3), Color(0.9, 0.9, 0.88))
	builder.add_box(
		facade,
		_t(origin + Vector3(0.0, 0.5 + height * 0.5, 0.0), yaw),
		Vector3(width, height, depth),
		Color(0.9 + rng.randf() * 0.2, 0.92 + rng.randf() * 0.16, 0.9 + rng.randf() * 0.2),
		FACADE_UV,
		"roof_flat"
	)
	colliders.append({
		"shape": "box", "transform": _t(origin + Vector3(0.0, height * 0.5, 0.0), yaw),
		"size": Vector3(width, height + 0.6, depth),
	})
	var roof_y := 0.5 + height
	if roof_style == 0:
		builder.add_gable_roof(
			"roof_tiles",
			_t(origin + Vector3(0.0, roof_y, 0.0), yaw),
			Vector3(width + 0.7, height * 0.42, depth + 0.7),
			Color(0.9 + rng.randf() * 0.2, 0.9, 0.9),
			Vector2(0.22, 0.22)
		)
		builder.add_box(
			"roof_tiles",
			_t(origin + Vector3(0.0, roof_y + height * 0.42 * 0.5, 0.0), yaw),
			Vector3(width + 0.8, 0.16, depth + 0.8), Color(0.9, 0.9, 0.9),
			Vector2(0.22, 0.22)
		)
	else:
		builder.add_hip_roof(
			"roof_metal",
			_t(origin + Vector3(0.0, roof_y, 0.0), yaw),
			Vector3(width + 0.7, height * 0.36, depth + 0.7),
			0.45,
			Color(0.92, 0.94, 0.96),
			Vector2(0.16, 0.16)
		)
	# chimney
	if rng.randf() < 0.8:
		var chimney := _t(origin, yaw) * _t(Vector3(width * rng.randf_range(-0.3, 0.3), roof_y + height * 0.45, depth * rng.randf_range(-0.25, 0.25)))
		builder.add_box("facade_brick_a", chimney * _t(Vector3(0.0, 0.9, 0.0)), Vector3(0.85, 1.8, 0.85), Color(0.9, 0.9, 0.9), Vector2(0.5, 0.5))
		builder.add_box("concrete", chimney * _t(Vector3(0.0, 1.85, 0.0)), Vector3(1.05, 0.18, 1.05), Color(0.9, 0.9, 0.9))
	# porch
	if rng.randf() < 0.7:
		var porch := _t(origin, yaw) * _t(Vector3(0.0, 0.0, depth * 0.5 + 1.1))
		builder.add_box("concrete", porch * _t(Vector3(0.0, 0.08, 0.0)), Vector3(3.0, 0.16, 2.2), Color(0.94, 0.94, 0.92))
		for sx in [-1.3, 1.3]:
			builder.add_cylinder("wood_dark", porch * _t(Vector3(sx, 1.2, 0.9)), 0.12, 0.12, 2.4, 6, Color(0.9, 0.9, 0.9))
		builder.add_box("roof_tiles", porch * _t(Vector3(0.0, 2.5, 0.5)), Vector3(3.4, 0.18, 2.6), Color(0.9, 0.9, 0.9), Vector2(0.2, 0.2))
	_entrance(builder, _t(origin + Vector3(0.0, 0.5, depth * 0.5 + 0.02), yaw), width, facade, false)
	return {
		"colliders": colliders,
		"height": height + height * 0.45,
		"footprint": Vector2(width, depth),
		"style": "house",
		"frontage": Vector3(sin(yaw), 0.0, cos(yaw)),
	}


## -------------------------------------------------------------- industrial --
static func build_factory_hall(
	builder: MeshBuilder,
	origin: Vector3,
	yaw: float,
	width: float,
	depth: float,
	height: float,
	rng: RandomNumberGenerator
) -> Dictionary:
	var colliders := []
	builder.add_box(
		"facade_industrial",
		_t(origin + Vector3(0.0, height * 0.5, 0.0), yaw),
		Vector3(width, height, depth),
		Color(0.88 + rng.randf() * 0.2, 0.9 + rng.randf() * 0.16, 0.92),
		FACADE_UV,
		"roof_flat"
	)
	colliders.append({
		"shape": "box", "transform": _t(origin + Vector3(0.0, height * 0.5, 0.0), yaw),
		"size": Vector3(width, height, depth),
	})
	# sawtooth roof
	var teeth := maxi(int(width / 6.0), 2)
	var tooth_width := width / float(teeth)
	for i in range(teeth):
		var x := -width * 0.5 + (float(i) + 0.5) * tooth_width
		var tooth := _t(origin, yaw) * _t(Vector3(x, height, 0.0))
		builder.add_quad(
			"roof_metal",
			tooth * Vector3(-tooth_width * 0.5, 0.0, -depth * 0.5),
			tooth * Vector3(-tooth_width * 0.5, height * 0.28, -depth * 0.5),
			tooth * Vector3(tooth_width * 0.5, height * 0.28, -depth * 0.5),
			tooth * Vector3(tooth_width * 0.5, 0.0, -depth * 0.5),
			Color(0.92, 0.94, 0.96),
			Vector2.ZERO, Vector2(0, 1), Vector2(1, 1), Vector2(1, 0),
			Vector3(0, 1, -0.4).normalized()
		)
		# glazing strip of the saw tooth
		builder.add_box(
			"facade_office",
			tooth * _t(Vector3(0.0, height * 0.16, -depth * 0.5 + 0.1)),
			Vector3(tooth_width * 0.92, height * 0.26, 0.12), Color(0.92, 0.96, 1.0), Vector2(0.3, 0.3)
		)
	# roof structure + chimneys
	builder.add_box("roof_flat", _t(origin + Vector3(0.0, height + 0.12, 0.0), yaw), Vector3(width + 0.4, 0.24, depth + 0.4), Color(0.9, 0.9, 0.92))
	for i in range(rng.randi_range(1, 3)):
		builder.add_cylinder(
			"metal_corrugated",
			_t(origin, yaw) * _t(Vector3(rng.randf_range(-width * 0.35, width * 0.35), height + rng.randf_range(1.2, 3.4), rng.randf_range(-depth * 0.3, depth * 0.3))),
			0.55, 0.45, rng.randf_range(2.4, 6.0), 10, Color(0.9, 0.92, 0.94)
		)
	return {
		"colliders": colliders,
		"height": height + 5.0,
		"footprint": Vector2(width, depth),
		"style": "factory",
		"frontage": Vector3(sin(yaw), 0.0, cos(yaw)),
	}
