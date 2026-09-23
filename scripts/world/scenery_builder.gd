class_name SceneryBuilder
extends RefCounted

## Everything natural: forests, bushes, grass, rocks, fields with crop rows,
## fences along field borders, fallen logs, lake reeds, desert rock formations.
##
## Density rules combine
##   * WorldConfig densities (design time),
##   * the streaming tier (near / mid / far),
##   * Perf.prop_density_scale (runtime, reacts to the measured frame time),
##   * region masks (urban / forest / desert / lake),
## so the same code produces a dense forest, sparse dunes or empty city ground.

var config: WorldConfig
var terrain: TerrainField


func _init(world_config: WorldConfig, world_terrain: TerrainField) -> void:
	config = world_config
	terrain = world_terrain


func build_chunk(
	builder: MeshBuilder,
	rect: Rect2,
	tier: int,
	rng: RandomNumberGenerator,
	colliders: Array
) -> void:
	if tier >= 2:
		return
	var center := rect.get_center()
	var urban := terrain.urban_at(center.x, center.y)
	var forest := terrain.forest_at(center.x, center.y)
	var desert := terrain.desert_at(center.x, center.y)
	var lake := terrain.lake_at(center.x, center.y)
	var density := Perf.prop_density_scale * (1.0 if tier == 0 else 0.55)

	# --- trees
	var tree_budget := float(config.trees_per_chunk_country) * (1.0 + forest * 2.2) * density
	tree_budget *= (1.0 - urban * 0.85) * (1.0 - desert * 0.55)
	var trees := int(tree_budget)
	for i in range(trees):
		var point := _random_point(rect, rng)
		var x := point.x
		var z := point.y
		if _blocked(x, z, 4.0):
			continue
		var slope := terrain.slope_at(x, z)
		if slope > 0.55:
			continue
		var ground := terrain.height_at(x, z)
		if ground < config.water_level + 0.2:
			continue
		var tree_lod := 0 if tier == 0 else 1
		var kind := rng.randf()
		if desert > 0.5:
			if kind < 0.35:
				PropMeshes.tree_palm(builder, Transform3D(Basis(Vector3.UP, rng.randf() * TAU), Vector3(x, ground, z)), rng.randf_range(7.0, 12.0), rng, tree_lod)
		elif forest > 0.35 and kind < 0.7:
			colliders.append_array(PropMeshes.tree_conifer(builder, Transform3D(Basis(Vector3.UP, rng.randf() * TAU), Vector3(x, ground, z)), rng.randf_range(9.0, 17.0), rng, tree_lod))
		elif kind < 0.62:
			colliders.append_array(PropMeshes.tree_broadleaf(builder, Transform3D(Basis(Vector3.UP, rng.randf() * TAU), Vector3(x, ground, z)), rng.randf_range(8.0, 16.0), rng, tree_lod))
		else:
			colliders.append_array(PropMeshes.tree_conifer(builder, Transform3D(Basis(Vector3.UP, rng.randf() * TAU), Vector3(x, ground, z)), rng.randf_range(8.0, 15.0), rng, tree_lod))

	# --- bushes and grass tufts
	var bushes := int(float(config.bushes_per_chunk) * density * (1.0 - urban * 0.6) * (1.0 + forest))
	for i in range(bushes):
		var point := _random_point(rect, rng)
		if _blocked(point.x, point.y, 3.0):
			continue
		var ground := terrain.height_at(point.x, point.y)
		if ground < config.water_level - 0.4:
			continue
		PropMeshes.bush(
			builder, Transform3D(Basis(Vector3.UP, rng.randf() * TAU), Vector3(point.x, ground, point.y)),
			rng.randf_range(0.7, 1.8), rng
		)

	if tier == 0:
		var tufts := int(float(config.grass_tufts_per_chunk) * density * (1.0 - urban * 0.9))
		for i in range(tufts):
			var point := _random_point(rect, rng)
			if _blocked(point.x, point.y, 1.6):
				continue
			var ground := terrain.height_at(point.x, point.y)
			if ground < config.water_level:
				continue
			PropMeshes.grass_tuft(
				builder, Transform3D(Basis(Vector3.UP, rng.randf() * TAU), Vector3(point.x, ground, point.y)),
				rng.randf_range(0.5, 1.0), rng
			)

	# --- rocks
	var rock_budget := float(config.rocks_per_chunk) * density * (1.0 - urban * 0.5) + float(config.desert_rocks_per_chunk) * desert * density
	for i in range(int(rock_budget)):
		var point := _random_point(rect, rng)
		if _blocked(point.x, point.y, 2.5):
			continue
		var ground := terrain.height_at(point.x, point.y)
		var scale := rng.randf_range(0.5, 2.2)
		var material := "sandstone" if desert > 0.45 else "rock_granite"
		if rng.randf() < 0.25 and desert > 0.4:
			colliders.append_array(PropMeshes.rock_cluster(builder, Transform3D(Basis(Vector3.UP, rng.randf() * TAU), Vector3(point.x, ground, point.y)), scale * 2.2, rng, material))
		else:
			colliders.append_array(PropMeshes.rock(builder, Transform3D(Basis(Vector3.UP, rng.randf() * TAU), Vector3(point.x, ground + scale * 0.22, point.y)), scale, rng, material))

	# --- lake reeds and a small pier
	if lake > 0.25:
		for i in range(int(26 * density)):
			var point := _random_point(rect, rng)
			var ground := terrain.height_at(point.x, point.y)
			if ground > config.water_level + 0.6 or ground < config.water_level - 0.8:
				continue
			PropMeshes.bush(builder, Transform3D(Basis(Vector3.UP, rng.randf() * TAU), Vector3(point.x, ground, point.y)), rng.randf_range(0.6, 1.3), rng)

	if tier == 0 and (forest > 0.4 or desert < 0.2):
		_add_fences_and_fields(builder, rect, rng, urban, colliders)


## Field fences aligned to a 160 m grid, plus crop rows inside the fields.
func _add_fences_and_fields(
	builder: MeshBuilder,
	rect: Rect2,
	rng: RandomNumberGenerator,
	urban: float,
	colliders: Array
) -> void:
	if urban > 0.3:
		return
	var cell := 160.0
	var start_x := floorf(rect.position.x / cell) * cell
	while start_x < rect.end.x:
		var start_z := floorf(rect.position.y / cell) * cell
		while start_z < rect.end.y:
			var field := Rect2(Vector2(start_x, start_z), Vector2(cell, cell))
			var field_rng := MathUtils.rng_for(Vector2i(int(start_x / cell), int(start_z / cell)), 4242)
			if field_rng.randf() < 0.35:
				start_z += cell
				continue
			# fence along the two sides that fall inside this chunk
			if rect.position.x <= start_x and start_x < rect.end.x:
				var fence_points := PackedVector2Array()
				var z := start_z
				while z < start_z + cell:
					fence_points.append(Vector2(start_x, z))
					z += 24.0
				# skip fence pieces that would cross a road
				for i in range(fence_points.size() - 1):
					var a := fence_points[i]
					var b := fence_points[i + 1]
					if _blocked(a.x, a.y, 6.0) or _blocked(b.x, b.y, 6.0):
						continue
					var from := Vector3(a.x, terrain.height_at(a.x, a.y), a.y)
					var direction := Vector3(b.x - a.x, 0.0, b.y - a.y).normalized()
					var yaw_ok := absf(direction.dot(Vector3.UP)) < 0.9
					if not yaw_ok:
						continue
					PropMeshes.fence_line(builder, from, direction, a.distance_to(b), "fence_picket", 1.3)
					colliders.append({
						"shape": "box",
						"transform": Transform3D(Basis(), Vector3((a.x + b.x) * 0.5, terrain.height_at((a.x + b.x) * 0.5, (a.y + b.y) * 0.5) + 0.65, (a.y + b.y) * 0.5)),
						"size": Vector3(maxf(absf(b.x - a.x), 0.3), 1.3, maxf(absf(b.y - a.y), 0.3)),
					})
			# crop rows
			if field_rng.randf() < 0.6:
				var rows := 6
				for row in range(rows):
					var z_row := start_z + 14.0 + float(row) * (cell / float(rows + 2))
					var x := start_x + 10.0 + field_rng.randf() * 10.0
					while x < start_x + cell - 10.0:
						if rect.has_point(Vector2(x, z_row)) and not _blocked(x, z_row, 3.0):
							var ground := terrain.height_at(x, z_row)
							PropMeshes.grass_tuft(
								builder,
								Transform3D(Basis(Vector3.UP, field_rng.randf() * TAU), Vector3(x, ground, z_row)),
								0.85, field_rng
							)
						x += 2.6
			start_z += cell
		start_x += cell


func _random_point(rect: Rect2, rng: RandomNumberGenerator) -> Vector2:
	return Vector2(
		rng.randf_range(rect.position.x + 2.0, rect.end.x - 2.0),
		rng.randf_range(rect.position.y + 2.0, rect.end.y - 2.0)
	)


## True when a position is too close to a road or too steep for scenery.
func _blocked(x: float, z: float, margin: float) -> bool:
	var position := Vector3(x, terrain.height_at(x, z), z)
	if terrain.road_network() != null:
		var road := terrain.road_network().nearest_road(position, 20.0)
		if not road.is_empty():
			var segment: RoadNetwork.Segment = terrain.road_network().segments[int(road["segment"])]
			if not segment.elevated and float(road["distance"]) < segment.width * 0.5 + margin:
				return true
	return false
