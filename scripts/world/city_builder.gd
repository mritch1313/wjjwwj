class_name CityBuilder
extends RefCounted

## Fills city blocks with buildings, parking lots, plazas, small parks and
## street furniture.
##
## Layout rules
##   * The city is a jittered grid (see RoadNetworkBuilder); every cell between
##     four grid lines is one block.  Buildings are placed along the block
##     perimeter facing the street, with the interior used as a courtyard,
##     parking lot or inner yard - exactly how a real block works.
##   * Block and lot content is derived from a deterministic RNG seeded with the
##     block coordinates, so a chunk regenerates identically after streaming.
##   * Detail level follows the streaming tier: near = full detail, mid = main
##     volume + windows only, far = a single facade box per building.

var config: WorldConfig
var terrain: TerrainField
var network: RoadNetwork
var parked_car_config: VehicleConfig


func _init(world_config: WorldConfig, world_terrain: TerrainField) -> void:
	config = world_config
	terrain = world_terrain
	network = world_terrain.road_network()


## Returns how many buildings were generated (for the debug overlay / tests).
func build_chunk(
	builder: MeshBuilder,
	rect: Rect2,
	tier: int,
	rng: RandomNumberGenerator,
	colliders: Array
) -> int:
	if network == null or network.city_grid_x.size() < 2:
		return 0
	var grid_x := network.city_grid_x
	var grid_z := network.city_grid_z
	var buildings := 0
	var first_i := _index_for(grid_x, rect.position.x) - 1
	var last_i := _index_for(grid_x, rect.end.x) + 1
	var first_j := _index_for(grid_z, rect.position.y) - 1
	var last_j := _index_for(grid_z, rect.end.y) + 1
	for i in range(maxi(first_i, 0), mini(last_i, grid_x.size() - 2) + 1):
		for j in range(maxi(first_j, 0), mini(last_j, grid_z.size() - 2) + 1):
			var block := _block_rect(i, j)
			if not rect.intersects(block, true):
				continue
			buildings += _build_block(builder, block, i, j, tier, colliders)
	return buildings


func _index_for(lines: PackedFloat32Array, value: float) -> int:
	var low := 0
	var high := lines.size() - 1
	while low < high:
		var mid := (low + high + 1) / 2
		if lines[mid] <= value:
			low = mid
		else:
			high = mid - 1
	return low


func _block_rect(i: int, j: int) -> Rect2:
	var grid_x := network.city_grid_x
	var grid_z := network.city_grid_z
	var avenue_x := i % config.avenue_every == 0 or (i + 1) % config.avenue_every == 0
	var avenue_z := j % config.avenue_every == 0 or (j + 1) % config.avenue_every == 0
	var inset_x := (config.road_width_avenue if avenue_x else config.road_width_street) * 0.5 + config.sidewalk_width
	var inset_z := (config.road_width_avenue if avenue_z else config.road_width_street) * 0.5 + config.sidewalk_width
	var x0 := grid_x[i] + inset_x
	var z0 := grid_z[j] + inset_z
	var x1 := grid_x[i + 1] - inset_x
	var z1 := grid_z[j + 1] - inset_z
	return Rect2(Vector2(x0, z0), Vector2(maxf(x1 - x0, 4.0), maxf(z1 - z0, 4.0)))


## Distance based "downtown-ness": 0 at the city edge, 1 at the very centre.
func _downtown_factor(center: Vector2) -> float:
	var distance := center.length()
	return clampf(1.0 - distance / maxf(network.city_half_extent, 1.0), 0.0, 1.0)


func _build_block(
	builder: MeshBuilder,
	block: Rect2,
	i: int,
	j: int,
	tier: int,
	colliders: Array
) -> int:
	var rng := MathUtils.rng_for(Vector2i(i * 73856093, j * 19349663), 991)
	var center := block.get_center()
	var height_reference := terrain.height_at(center.x, center.y)
	var downtown := _downtown_factor(center)
	var urban := terrain.urban_at(center.x, center.y)
	var style := "downtown" if downtown > 0.62 else ("city" if downtown > 0.22 else "suburb")
	var buildings := 0

	# --- what kind of lot is this?
	var roll := rng.randf()
	var lot := "blocks"
	if urban > 0.55:
		if roll < config.parking_lot_chance:
			lot = "parking"
		elif roll < config.parking_lot_chance + config.plaza_chance:
			lot = "plaza"
		elif roll < config.parking_lot_chance + config.plaza_chance + config.vacant_lot_chance:
			lot = "vacant"
		elif roll > 0.93:
			lot = "park"
	else:
		if roll < 0.18:
			lot = "parking"
		elif roll < 0.3:
			lot = "vacant"
		elif roll > 0.88:
			lot = "park"

	# --- block surface (the ground floor of every lot)
	_add_lot_surface(builder, block, lot, tier, rng, height_reference)

	if lot == "parking":
		_add_parking_lot(builder, block, tier, rng, colliders)
		return 0
	if lot == "park":
		_add_park(builder, block, tier, rng, colliders)
		return 0
	if lot == "plaza":
		_add_plaza(builder, block, tier, rng, colliders)
		return 0

	# --- perimeter buildings with a courtyard inside
	var min_height := 8.0
	var max_height := 12.0
	match style:
		"downtown":
			min_height = lerpf(26.0, config.downtown_height_max * 0.55, downtown)
			max_height = lerpf(config.downtown_height_max * 0.6, config.downtown_height_max, downtown)
		"city":
			min_height = 12.0
			max_height = config.city_height_max * lerpf(0.6, 1.0, downtown)
		_:
			min_height = 6.5
			max_height = config.suburb_height_max
	if lot == "vacant":
		min_height *= 0.7
		max_height *= 0.8

	var edges := [
		{"start": Vector2(block.position.x, block.position.y), "direction": Vector2.RIGHT, "normal": Vector2(0, -1), "length": block.size.x},
		{"start": Vector2(block.end.x, block.position.y), "direction": Vector2(0, 1), "normal": Vector2(1, 0), "length": block.size.y},
		{"start": Vector2(block.end.x, block.end.y), "direction": Vector2.LEFT, "normal": Vector2(0, 1), "length": block.size.x},
		{"start": Vector2(block.position.x, block.end.y), "direction": Vector2(0, -1), "normal": Vector2(-1, 0), "length": block.size.y},
	]
	for edge in edges:
		var direction: Vector2 = edge["direction"]
		var normal: Vector2 = edge["normal"]
		var edge_start: Vector2 = edge["start"]
		var edge_length: float = edge["length"]
		if edge_length < 10.0:
			continue
		var depth := clampf(edge_length * 0.34, 9.0, 19.0)
		var along := 1.0
		while along < edge_length - 6.0:
			var lot_width := rng.randf_range(11.0, 22.0)
			if along + lot_width > edge_length - 2.0:
				lot_width = edge_length - along - 1.0
			if lot_width < 7.0:
				break
			if rng.randf() < 0.12:
				along += lot_width + 1.5
				continue
			var front_center := edge_start + direction * (along + lot_width * 0.5)
			var inward := -normal
			var building_center := front_center + inward * (depth * 0.5 + 1.2)
			var yaw := atan2(normal.x, normal.y)
			var height := rng.randf_range(min_height, max_height)
			if rng.randf() < 0.12:
				height *= 1.35
			var context := {
				"origin": Vector3(building_center.x, terrain.height_at(building_center.x, building_center.y), building_center.y),
				"yaw": yaw,
				"width": lot_width - 1.4,
				"depth": depth,
				"height": height,
				"rng": rng,
				"tier": tier,
				"style": style,
			}
			buildings += _place_building(builder, context, colliders)
			along += lot_width + rng.randf_range(0.6, 2.4)

	# --- courtyard content
	if lot == "blocks" and urban > 0.4:
		_add_courtyard(builder, block, tier, rng, colliders)
	return buildings


func _place_building(builder: MeshBuilder, context: Dictionary, colliders: Array) -> int:
	var origin: Vector3 = context["origin"]
	var yaw: float = context["yaw"]
	var width: float = context["width"]
	var depth: float = context["depth"]
	var height: float = context["height"]
	var rng: RandomNumberGenerator = context["rng"]
	var tier: int = context["tier"]
	var style: String = context["style"]
	if tier >= 2:
		# far LOD: single facade box
		builder.add_box(
			BuildingFactory.FACADE_MATERIALS_CITY[rng.randi_range(0, BuildingFactory.FACADE_MATERIALS_CITY.size() - 1)],
			BuildingFactory._t(origin + Vector3(0.0, height * 0.5, 0.0), yaw),
			Vector3(width, height, depth),
			Color(0.92, 0.94, 0.92),
			BuildingFactory.FACADE_UV,
			"roof_flat"
		)
		return 1
	if tier == 1:
		BuildingFactory.build_block(builder, origin, yaw, width, depth, height, rng, style)
		colliders.append({
			"shape": "box",
			"transform": BuildingFactory._t(origin + Vector3(0.0, height * 0.5, 0.0), yaw),
			"size": Vector3(width, height, depth),
		})
		return 1

	# --- near tier: the full variety
	var roll := rng.randf()
	if style == "downtown" and height > 28.0:
		var result := BuildingFactory.build_tower(builder, origin, yaw, width, depth, height, rng)
		colliders.append_array(result["colliders"])
	elif roll < 0.22 and height > 11.0:
		var result := BuildingFactory.build_shop_row(builder, origin, yaw, width, depth, height, rng)
		colliders.append_array(result["colliders"])
	elif roll < 0.34:
		var result := BuildingFactory.build_warehouse(builder, origin, yaw, width + 3.0, depth + 2.0, maxf(height, 9.0), rng)
		colliders.append_array(result["colliders"])
	elif style == "suburb" and height < 18.0:
		var result := BuildingFactory.build_house(builder, origin, yaw, width, depth, maxi(int(round(height / 3.2)), 1), rng, rng.randi_range(0, 1))
		colliders.append_array(result["colliders"])
	else:
		var result := BuildingFactory.build_block(builder, origin, yaw, width, depth, height, rng, style)
		colliders.append_array(result["colliders"])
	return 1


## --------------------------------------------------------------- lot types --
func _add_lot_surface(
	builder: MeshBuilder,
	block: Rect2,
	lot: String,
	tier: int,
	rng: RandomNumberGenerator,
	height_reference: float
) -> void:
	var material := "sidewalk"
	match lot:
		"parking":
			material = "parking"
		"plaza":
			material = "pavement"
		"vacant":
			material = "ground_gravel"
		"park":
			return  # grass from the terrain itself
	# The slab follows the terrain height at its corners so it never floats.
	var corners := [
		block.position,
		Vector2(block.end.x, block.position.y),
		block.end,
		Vector2(block.position.x, block.end.y),
	]
	for a in range(4):
		var b := (a + 1) % 4
		var p0: Vector2 = corners[a]
		var p1: Vector2 = corners[b]
		var h0 := terrain.height_at(p0.x, p0.y) + 0.08
		var h1 := terrain.height_at(p1.x, p1.y) + 0.08
		var yaw := atan2(p1.x - p0.x, p1.y - p0.y)
		var length := p0.distance_to(p1)
		var thickness := 0.16
		builder.add_box(
			material,
			Transform3D(Basis(Vector3.UP, yaw), Vector3((p0.x + p1.x) * 0.5, (h0 + h1) * 0.5 - thickness * 0.5, (p0.y + p1.y) * 0.5)),
			Vector3(length, thickness, minf(block.size.x, block.size.y) * 0.5),
			Color(0.94 + rng.randf() * 0.1, 0.94, 0.93),
			Vector2(0.25, 0.25)
		)
	# interior fill
	var centre := block.get_center()
	var size := block.size * 0.42
	builder.add_box(
		material,
		Transform3D(Basis(), Vector3(centre.x, terrain.height_at(centre.x, centre.y) + 0.06, centre.y)),
		Vector3(size.x, 0.14, size.y),
		Color(0.93, 0.93, 0.92),
		Vector2(0.25, 0.25)
	)


func _add_parking_lot(builder: MeshBuilder, block: Rect2, tier: int, rng: RandomNumberGenerator, colliders: Array) -> void:
	var slab_height := terrain.height_at(block.get_center().x, block.get_center().y) + 0.09
	builder.add_box(
		"parking",
		Transform3D(Basis(), Vector3(block.get_center().x, slab_height, block.get_center().y)),
		Vector3(block.size.x, 0.18, block.size.y),
		Color(0.96, 0.96, 0.95),
		Vector2(0.1, 0.1)
	)
	if tier >= 2:
		return
	# parked cars in rows, facing the bays drawn in the parking texture
	var rows := int(maxf(block.size.y / 9.0, 1.0))
	var bays_per_row := int(maxf(block.size.x / 2.6, 1.0))
	var car_config := parked_car_config if parked_car_config != null else ConfigDB.new().vehicle_player
	for row in range(rows):
		var z := block.position.y + 4.5 + float(row) * 9.0
		if z > block.end.y - 3.0:
			break
		for bay in range(bays_per_row):
			if rng.randf() < 0.42:
				continue
			var x := block.position.x + 1.6 + float(bay) * 2.6
			if x > block.end.x - 2.0:
				break
			var position := Vector3(x, terrain.height_at(x, z) + 0.02, z)
			VehicleModelFactory.build_parked_car(builder, Transform3D(Basis(Vector3.UP, 0.0), position), car_config, rng)
	# lamps + a small shop kiosk at the edge
	for corner in range(2):
		var lamp_x := block.position.x + (4.0 + float(corner) * (block.size.x - 8.0))
		var lamp_z := block.position.y + 2.2
		PropMeshes.street_lamp(builder, Transform3D(Basis(Vector3.UP, PI), Vector3(lamp_x, terrain.height_at(lamp_x, lamp_z), lamp_z)), 7.0, rng)


func _add_plaza(builder: MeshBuilder, block: Rect2, tier: int, rng: RandomNumberGenerator, colliders: Array) -> void:
	if tier >= 2:
		return
	var centre := block.get_center()
	var fountain_radius := minf(block.size.x, block.size.y) * 0.18
	var y := terrain.height_at(centre.x, centre.y)
	builder.add_cylinder("concrete", Transform3D(Basis(), Vector3(centre.x, y + 0.45, centre.y)), fountain_radius, fountain_radius, 0.9, 16, Color(0.95, 0.95, 0.93))
	builder.add_cylinder("water", Transform3D(Basis(), Vector3(centre.x, y + 0.82, centre.y)), fountain_radius * 0.86, fountain_radius * 0.86, 0.2, 16, Color(0.6, 0.85, 0.95))
	builder.add_cylinder("concrete", Transform3D(Basis(), Vector3(centre.x, y + 1.3, centre.y)), 0.35, 0.25, 1.8, 10, Color(0.95, 0.95, 0.93))
	colliders.append({
		"shape": "cylinder", "transform": Transform3D(Basis(), Vector3(centre.x, y + 0.45, centre.y)),
		"radius": fountain_radius, "height": 0.9,
	})
	# benches and trees around the fountain
	var count := 8
	for i in range(count):
		var angle := TAU * float(i) / float(count) + rng.randf_range(-0.2, 0.2)
		var distance := minf(block.size.x, block.size.y) * 0.36
		var x := centre.x + cos(angle) * distance
		var z := centre.y + sin(angle) * distance
		var ground := terrain.height_at(x, z)
		if i % 2 == 0:
			PropMeshes.bench(builder, Transform3D(Basis(Vector3.UP, angle + PI), Vector3(x, ground, z)), rng)
		else:
			PropMeshes.tree_broadleaf(
				builder, Transform3D(Basis(Vector3.UP, rng.randf() * TAU), Vector3(x, ground, z)),
				rng.randf_range(9.0, 13.0), rng, 0
			)


func _add_park(builder: MeshBuilder, block: Rect2, tier: int, rng: RandomNumberGenerator, colliders: Array) -> void:
	var centre := block.get_center()
	if tier >= 2:
		return
	# paths
	var path_width := 2.4
	for axis in range(2):
		var length := block.size.x if axis == 0 else block.size.y
		var y := terrain.height_at(centre.x, centre.y)
		builder.add_box(
			"sidewalk",
			Transform3D(Basis(), Vector3(centre.x, y + 0.07, centre.y)) if axis == 0 else Transform3D(Basis(Vector3.UP, PI * 0.5), Vector3(centre.x, y + 0.07, centre.y)),
			Vector3(path_width, 0.14, length * 0.9),
			Color(0.94, 0.94, 0.92),
			Vector2(0.25, 0.25)
		)
	# trees
	var tree_count := int(clampf(block.size.x * block.size.y / 380.0, 3.0, 14.0))
	for i in range(tree_count):
		var x := rng.randf_range(block.position.x + 2.0, block.end.x - 2.0)
		var z := rng.randf_range(block.position.y + 2.0, block.end.y - 2.0)
		if absf(x - centre.x) < path_width and absf(z - centre.y) < path_width:
			continue
		var ground := terrain.height_at(x, z)
		var kind := rng.randf()
		if kind < 0.65:
			var colliders_tree := PropMeshes.tree_broadleaf(
				builder, Transform3D(Basis(Vector3.UP, rng.randf() * TAU), Vector3(x, ground, z)),
				rng.randf_range(9.0, 15.0), rng, 0
			)
			colliders.append_array(colliders_tree)
		else:
			PropMeshes.tree_conifer(
				builder, Transform3D(Basis(Vector3.UP, rng.randf() * TAU), Vector3(x, ground, z)),
				rng.randf_range(8.0, 13.0), rng, 0
			)
	# benches + bins along the paths
	for i in range(3):
		var angle := TAU * rng.randf()
		var distance := minf(block.size.x, block.size.y) * 0.3
		var x := centre.x + cos(angle) * distance
		var z := centre.y + sin(angle) * distance
		var ground := terrain.height_at(x, z)
		PropMeshes.bench(builder, Transform3D(Basis(Vector3.UP, angle), Vector3(x, ground, z)), rng)
		PropMeshes.trash_bin(builder, Transform3D(Basis(Vector3.UP, 0.0), Vector3(x + 1.8, ground, z)), rng)


func _add_courtyard(builder: MeshBuilder, block: Rect2, tier: int, rng: RandomNumberGenerator, colliders: Array) -> void:
	if tier >= 2:
		return
	var centre := block.get_center()
	var inner_size := block.size * 0.34
	var ground := terrain.height_at(centre.x, centre.y)
	builder.add_box(
		"concrete",
		Transform3D(Basis(), Vector3(centre.x, ground + 0.05, centre.y)),
		Vector3(inner_size.x, 0.12, inner_size.y),
		Color(0.9, 0.9, 0.88),
		Vector2(0.25, 0.25)
	)
	var props := rng.randi_range(1, 3)
	for i in range(props):
		var x := centre.x + rng.randf_range(-inner_size.x * 0.35, inner_size.x * 0.35)
		var z := centre.y + rng.randf_range(-inner_size.y * 0.35, inner_size.y * 0.35)
		var y := terrain.height_at(x, z)
		var yaw := rng.randf() * TAU
		match rng.randi_range(0, 3):
			0:
				colliders.append_array(PropMeshes.dumpster(builder, Transform3D(Basis(Vector3.UP, yaw), Vector3(x, y, z)), 0.0, rng))
			1:
				colliders.append_array(PropMeshes.container(builder, Transform3D(Basis(Vector3.UP, yaw), Vector3(x, y, z)), 0.0, rng))
			2:
				colliders.append_array(PropMeshes.crate(builder, Transform3D(Basis(Vector3.UP, yaw), Vector3(x, y, z)), 0.0, rng.randf_range(0.8, 1.2), rng))
			_:
				PropMeshes.bush(builder, Transform3D(Basis(Vector3.UP, yaw), Vector3(x, y, z)), rng.randf_range(0.9, 1.6), rng)


## ---------------------------------------------------- street furniture pass --
## Called by the world generator with the roads that cross this chunk: lamps,
## signs, bins and sidewalk trees along the kerb.
func build_street_furniture(
	builder: MeshBuilder,
	rect: Rect2,
	tier: int,
	rng: RandomNumberGenerator,
	colliders: Array
) -> void:
	if network == null or tier >= 2:
		return
	var center := Vector3(rect.get_center().x, 0.0, rect.get_center().y)
	var radius := rect.size.length() * 0.5 + 16.0
	for segment_id in network.segments_in_area(center, radius):
		var segment := network.segments[segment_id]
		if segment.elevated:
			continue
		var is_street := segment.type == RoadNetwork.RoadType.STREET or segment.type == RoadNetwork.RoadType.AVENUE
		var is_rural := segment.type == RoadNetwork.RoadType.RURAL or segment.type == RoadNetwork.RoadType.HIGHWAY
		if not is_street and not is_rural:
			continue
		var spacing := 34.0 if is_street else 78.0
		var along := rng.randf_range(0.0, spacing)
		while along < segment.length:
			var point := segment.point_at(along)
			if not rect.has_point(Vector2(point.x, point.z)):
				along += spacing
				continue
			var tangent := segment.tangent_at(along)
			var lateral := Vector3(-tangent.z, 0.0, tangent.x).normalized()
			var side := 1.0 if rng.randf() < 0.5 else -1.0
			var offset := segment.width * 0.5 + (config.sidewalk_width + 0.8 if is_street else 2.6)
			var position := Vector3(point.x, 0.0, point.z) + lateral * side * offset
			var ground := terrain.height_at(position.x, position.z)
			var yaw := atan2(-tangent.x, -tangent.z)
			var placement := Transform3D(Basis(Vector3.UP, yaw + (0.0 if side > 0.0 else PI)), Vector3(position.x, ground, position.z))
			var roll := rng.randf()
			if is_street:
				if roll < 0.45:
					colliders.append_array(PropMeshes.street_lamp(builder, placement, 7.4, rng))
				elif roll < 0.6:
					colliders.append_array(PropMeshes.sign_post(builder, placement, rng.randi_range(0, 15), 2.6, rng))
				elif roll < 0.7:
					PropMeshes.trash_bin(builder, placement, rng)
				elif roll < 0.78:
					PropMeshes.bench(builder, placement, rng)
				elif roll < 0.85:
					PropMeshes.hydrant(builder, placement, rng)
				elif roll < 0.95:
					PropMeshes.tree_broadleaf(builder, placement, rng.randf_range(7.0, 11.0), rng, 0)
				else:
					PropMeshes.bollard(builder, placement, rng)
			else:
				if roll < 0.3:
					colliders.append_array(PropMeshes.street_lamp(builder, placement, 8.0, rng))
				elif roll < 0.55:
					colliders.append_array(PropMeshes.sign_post(builder, placement, rng.randi_range(2, 15), 2.8, rng))
				elif roll < 0.7:
					PropMeshes.power_pole(builder, placement, rng.randf_range(8.0, 10.5), rng)
				else:
					PropMeshes.guardrail(builder, Vector3(point.x, terrain.height_at(point.x, point.z), point.z) + lateral * side * (segment.width * 0.5 + 1.1), tangent, 18.0, rng)
			along += spacing
