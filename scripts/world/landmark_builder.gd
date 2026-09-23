class_name LandmarkBuilder
extends RefCounted

## Landmarks make the world readable: they are the objects the player
## navigates by.  Two sources feed them:
##   * POI slots created by the road builder (gas stations, depots, farms,
##     warehouses - each already has an access road), and
##   * hand-placed types picked deterministically from the world seed
##     (water tower, radio mast, big billboards, viewpoints, highway gantries,
##     bridge details).
##
## Cost is kept low: one landmark is a few dozen boxes plus procedural textures,
## and far away only the silhouette box is generated.

var config: WorldConfig
var terrain: TerrainField
var network: RoadNetwork
var _poi_cache: Dictionary = {}

## Transform3D for a prop placed at `offset` inside a landmark (optionally turned
## by `yaw`).  The prop helpers expect a full transform, so this keeps the
## call sites readable: `_at(base, Vector3(4, 0, 2), PI * 0.5)`.
static func _at(base: Transform3D, offset: Vector3, yaw: float = 0.0) -> Transform3D:
	return base * Transform3D(Basis(Vector3.UP, yaw), offset)


static func _t(position: Vector3, yaw: float = 0.0, scale: float = 1.0) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(scale, scale, scale)), position)


func _init(world_config: WorldConfig, world_terrain: TerrainField) -> void:
	config = world_config
	terrain = world_terrain
	network = world_terrain.road_network()


func _poi_in_rect(rect: Rect2) -> Array:
	var key := "%d_%d" % [int(rect.position.x / config.chunk_size_m), int(rect.position.y / config.chunk_size_m)]
	if _poi_cache.has(key):
		return _poi_cache[key]
	var found := []
	var slots: Array = []
	if terrain.road_network() != null and terrain.road_network().has_meta("poi_slots"):
		slots = terrain.road_network().get_meta("poi_slots")
	for slot in slots:
		var center: Vector3 = slot["center"]
		if rect.grow(70.0).has_point(Vector2(center.x, center.z)):
			found.append(slot)
	_poi_cache[key] = found
	return found


func build_chunk(
	builder: MeshBuilder,
	rect: Rect2,
	tier: int,
	rng: RandomNumberGenerator,
	colliders: Array
) -> void:
	for slot in _poi_in_rect(rect):
		var center: Vector3 = slot["center"]
		if not rect.grow(48.0).has_point(Vector2(center.x, center.z)):
			continue
		_build_poi(builder, slot, tier, rng, colliders)
	_build_highway_details(builder, rect, tier, rng, colliders)
	_build_viewpoint(builder, rect, tier, rng, colliders)


func _build_poi(builder: MeshBuilder, slot: Dictionary, tier: int, rng: RandomNumberGenerator, colliders: Array) -> void:
	var center: Vector3 = slot["center"]
	var facing: Vector3 = slot["facing"]
	var kind := String(slot["kind"])
	var yaw := atan2(facing.x, facing.z)
	var ground := terrain.height_at(center.x, center.z)
	var base := Transform3D(Basis(Vector3.UP, yaw), Vector3(center.x, ground, center.z))
	var local_rng := MathUtils.rng_for(Vector2i(int(center.x), int(center.z)), 777)
	match kind:
		"gas_station":
			colliders.append_array(PropMeshes.fuel_station(builder, base, 0.0, local_rng))
		"depot":
			_build_depot(builder, base, tier, local_rng, colliders)
		"farm":
			_build_farm(builder, base, tier, local_rng, colliders)
		"warehouse":
			_build_warehouse_yard(builder, base, tier, local_rng, colliders)
		_:
			pass


func _build_depot(builder: MeshBuilder, base: Transform3D, tier: int, rng: RandomNumberGenerator, colliders: Array) -> void:
	# gravel yard + fence + containers + warehouse
	builder.add_box("ground_gravel", base * _t(Vector3(0.0, 0.08, 0.0)), Vector3(46.0, 0.16, 34.0), Color(0.95, 0.95, 0.9), Vector2(0.25, 0.25))
	PropMeshes.fence_line(builder, base * Vector3(-23.0, 0.0, -17.0), Vector3.FORWARD, 34.0, "fence_chain", 2.2)
	PropMeshes.fence_line(builder, base * Vector3(23.0, 0.0, -17.0), Vector3.FORWARD, 34.0, "fence_chain", 2.2)
	if tier >= 2:
		return
	var result := BuildingFactory.build_warehouse(builder, base * Vector3(0.0, 0.0, -12.0), 0.0, 26.0, 14.0, 9.0, rng)
	colliders.append_array(result["colliders"])
	for i in range(rng.randi_range(3, 6)):
		var offset := Vector3(rng.randf_range(-18.0, 18.0), 0.0, rng.randf_range(-2.0, 14.0))
		var yaw := 0.0 if rng.randf() < 0.5 else PI * 0.5
		if rng.randf() < 0.6:
			colliders.append_array(PropMeshes.container(builder, _at(base, offset), yaw, rng))
		else:
			colliders.append_array(PropMeshes.crate(builder, _at(base, offset), yaw, rng.randf_range(0.9, 1.4), rng))
	for i in range(rng.randi_range(2, 4)):
		PropMeshes.street_lamp(builder, _at(base, Vector3(rng.randf_range(-20.0, 20.0), 0.0, rng.randf_range(-14.0, 16.0))), 9.0, rng)


func _build_farm(builder: MeshBuilder, base: Transform3D, tier: int, rng: RandomNumberGenerator, colliders: Array) -> void:
	# house + barn + silo + fenced paddock + hay bales
	var house := BuildingFactory.build_house(builder, base * Vector3(-14.0, 0.0, 6.0), PI * 0.35, 10.0, 9.0, 1, rng, 0)
	colliders.append_array(house["colliders"])
	if tier >= 2:
		return
	builder.add_box("facade_industrial", base * _t(Vector3(10.0, 3.6, -4.0), PI * 0.5), Vector3(18.0, 7.2, 12.0), Color(0.9, 0.88, 0.84), BuildingFactory.FACADE_UV, "roof_flat")
	builder.add_gable_roof("roof_metal", base * _t(Vector3(10.0, 7.2, -4.0), PI * 0.5), Vector3(18.6, 4.4, 12.6), Color(0.92, 0.94, 0.96), Vector2(0.14, 0.14))
	colliders.append({
		"shape": "box",
		"transform": base * _t(Vector3(10.0, 3.6, -4.0), PI * 0.5),
		"size": Vector3(18.0, 7.2, 12.0),
	})
	builder.add_box("facade_roller_door", base * _t(Vector3(10.0, 2.1, 2.05), PI * 0.5), Vector3(3.4, 4.2, 0.2), Color(0.95, 0.95, 0.95))
	colliders.append_array(PropMeshes.silo(builder, _at(base, Vector3(22.0, 0.0, 6.0)), rng))
	colliders.append_array(PropMeshes.silo(builder, _at(base, Vector3(26.5, 0.0, 8.5)), rng))
	for i in range(rng.randi_range(3, 6)):
		PropMeshes.hay_bale(builder, _at(base, Vector3(rng.randf_range(-4.0, 20.0), 0.0, rng.randf_range(10.0, 18.0))), rng.randf() * TAU, rng)
	# paddock fence
	PropMeshes.fence_line(builder, base * Vector3(-6.0, 0.0, 14.0), Vector3.RIGHT, 24.0, "fence_picket", 1.25)
	PropMeshes.fence_line(builder, base * Vector3(-6.0, 0.0, 14.0), Vector3.FORWARD, 18.0, "fence_picket", 1.25)
	PropMeshes.fence_line(builder, base * Vector3(18.0, 0.0, 14.0), Vector3.FORWARD, 18.0, "fence_picket", 1.25)
	var windmill := PropMeshes.windmill(builder, _at(base, Vector3(-24.0, 0.0, -8.0)), rng)
	colliders.append_array(windmill)


func _build_warehouse_yard(builder: MeshBuilder, base: Transform3D, tier: int, rng: RandomNumberGenerator, colliders: Array) -> void:
	builder.add_box("parking", base * _t(Vector3(0.0, 0.08, 0.0)), Vector3(44.0, 0.16, 30.0), Color(0.95, 0.95, 0.94), Vector2(0.1, 0.1))
	if tier >= 2:
		return
	var result := BuildingFactory.build_factory_hall(builder, base * Vector3(0.0, 0.0, -10.0), 0.0, 34.0, 18.0, 11.0, rng)
	colliders.append_array(result["colliders"])
	for i in range(rng.randi_range(4, 8)):
		colliders.append_array(PropMeshes.pallet(builder, _at(base, Vector3(rng.randf_range(-18.0, 18.0), 0.0, rng.randf_range(2.0, 14.0))), rng.randf() * TAU, rng))
	for i in range(rng.randi_range(2, 3)):
		colliders.append_array(PropMeshes.dumpster(builder, _at(base, Vector3(rng.randf_range(-20.0, 20.0), 0.0, 12.0)), rng.randf() * TAU, rng))


## Highway equipment: overhead sign gantries, emergency phones, kilometre posts.
func _build_highway_details(builder: MeshBuilder, rect: Rect2, tier: int, rng: RandomNumberGenerator, colliders: Array) -> void:
	if network == null or tier >= 2:
		return
	var center := Vector3(rect.get_center().x, 0.0, rect.get_center().y)
	for segment_id in network.segments_in_area(center, rect.size.length() * 0.5 + 10.0):
		var segment := network.segments[segment_id]
		if segment.type != RoadNetwork.RoadType.HIGHWAY:
			continue
		var spacing := 190.0
		var along := rng.randf_range(0.0, spacing)
		while along < segment.length:
			var point := segment.point_at(along)
			if absf(point.x - rect.get_center().x) < rect.size.x * 0.5 and absf(point.z - rect.get_center().y) < rect.size.y * 0.5:
				var tangent := segment.tangent_at(along)
				var lateral := Vector3(-tangent.z, 0.0, tangent.x).normalized()
				var yaw := atan2(lateral.x, lateral.z)
				var base := Transform3D(Basis(Vector3.UP, yaw), Vector3(point.x, point.y, point.z))
				# sign gantry over the carriageway
				var span := segment.width + 3.0
				for side in [-1.0, 1.0]:
					builder.add_cylinder("metal_grey", base * _t(Vector3(side * span * 0.5, 3.4, 0.0)), 0.2, 0.16, 6.8, 8, Color(0.9, 0.9, 0.92))
					colliders.append({
						"shape": "cylinder",
						"transform": base * _t(Vector3(side * span * 0.5, 3.4, 0.0)),
						"radius": 0.3, "height": 6.8,
					})
				builder.add_box("metal_grey", base * _t(Vector3(0.0, 6.6, 0.0)), Vector3(span + 1.2, 0.35, 0.35), Color(0.9, 0.9, 0.92))
				builder.add_billboard("sign_face", base * _t(Vector3(0.0, 5.6, 0.1)), Vector2(4.4, 2.0), Color(1, 1, 1), true, Vector2(0.5, 0.5), Vector2(0.25, 0.25))
				# kilometre post on the shoulder
				builder.add_box("marking_white", base * _t(Vector3(span * 0.55, 0.5, 0.0)), Vector3(0.16, 1.0, 0.1), Color(1, 1, 1))
			along += spacing


## A viewpoint / picnic spot on a high spot: bench, sign and a fence.
func _build_viewpoint(builder: MeshBuilder, rect: Rect2, tier: int, rng: RandomNumberGenerator, colliders: Array) -> void:
	if tier >= 2:
		return
	var cell := config.chunk_size_m * 3.0
	var key := MathUtils.rng_for(Vector2i(int(rect.position.x / cell), int(rect.position.y / cell)), 31337)
	if key.randf() > 0.22:
		return
	var x := rect.position.x + key.randf_range(20.0, rect.size.x - 20.0)
	var z := rect.position.y + key.randf_range(20.0, rect.size.y - 20.0)
	var ground := terrain.height_at(x, z)
	var slope := terrain.slope_at(x, z)
	var urban := terrain.urban_at(x, z)
	if slope > 0.3 or urban > 0.3 or ground < config.water_level + 1.5:
		return
	var road := network.nearest_road(Vector3(x, ground, z), 90.0) if network != null else {}
	if road.is_empty():
		return
	var base := Transform3D(Basis(Vector3.UP, key.randf() * TAU), Vector3(x, ground, z))
	PropMeshes.bench(builder, base, key)
	PropMeshes.sign_post(builder, _at(base, Vector3(0.0, 0.0, 2.4)), 15, 3.0, key)
	PropMeshes.trash_bin(builder, _at(base, Vector3(2.2, 0.0, 0.0)), key)
	PropMeshes.tree_broadleaf(builder, _at(base, Vector3(-3.0, 0.0, 1.5)), key.randf_range(9.0, 12.0), key, 0)


## Big "world landmarks": used by WorldGenerator for the whole-world pass.
static func build_landmark(builder: MeshBuilder, kind: String, base: Transform3D, rng: RandomNumberGenerator, colliders: Array) -> void:
	match kind:
		"water_tower":
			colliders.append_array(PropMeshes.water_tower(builder, base, rng))
		"radio_mast":
			colliders.append_array(PropMeshes.radio_mast(builder, base, rng.randf_range(28.0, 42.0), rng))
		"billboard":
			colliders.append_array(PropMeshes.billboard_sign(builder, base, rng.randf() * TAU, rng.randi_range(0, 1), rng))
		"watchtower":
			PropMeshes.radio_mast(builder, base, rng.randf_range(14.0, 20.0), rng)
		"silo_group":
			for i in range(3):
				colliders.append_array(PropMeshes.silo(builder, base * _t(Vector3(float(i) * 6.0 - 6.0, 0.0, float(i) * 2.0)), rng))
		_:
			pass
