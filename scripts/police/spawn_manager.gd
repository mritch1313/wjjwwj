class_name SpawnManager
extends RefCounted

## Finds *valid* spawn points for police cars.  A point is only accepted when it
## passes every check the design brief demands:
##
##   1. it is on a road (so the car is not spawned in a field),
##   2. the ground there is dry, flat enough and not inside a building,
##   3. there is free space for a car-sized box (physics query),
##   4. the distance to the player is inside the configured window,
##   5. the point is not inside the camera frustum (no pop-in in front of the
##      player's eyes).
##
## The manager only *suggests* points; the caller spawns the car, which keeps the
## "no teleporting" rule intact: police cars are created, never moved.

const BOX_HALF_EXTENTS := Vector3(1.0, 0.7, 2.2)

var config: GameplayConfig
var terrain: TerrainField
var network: RoadNetwork

var last_rejection: String = ""
var attempts_total: int = 0
var last_candidate_count: int = 0

var _rng := RandomNumberGenerator.new()


func _init(gameplay_config: GameplayConfig, world_terrain: TerrainField, roads: RoadNetwork) -> void:
	config = gameplay_config
	terrain = world_terrain
	network = roads
	_rng.randomize()


func set_seed(value: int) -> void:
	_rng.seed = value


## occupied: Array[Vector3] positions of the cars that already exist.
## camera: may be null (head-less tests) - the frustum check is skipped then.
func find_spawn_position(
	player_position: Vector3,
	player_forward: Vector3,
	camera: Camera3D,
	occupied: Array,
	space: PhysicsDirectSpaceState3D = null
) -> Dictionary:
	last_rejection = ""
	if network == null or network.segment_count() == 0:
		last_rejection = "no_road_network"
		return {}
	var candidates := _candidate_points(player_position, player_forward)
	last_candidate_count = candidates.size()
	if candidates.is_empty():
		# Nothing to test: the distance window (or the world) produced no candidate
		# road points at all, which is a different failure from "all were rejected".
		last_rejection = "no_candidates"
		return {}
	for candidate in candidates:
		var position: Vector3 = candidate["point"]
		attempts_total += 1
		var distance := Vector2(position.x - player_position.x, position.z - player_position.z).length()
		if distance < config.spawn_min_distance_m:
			last_rejection = "too_close"
			continue
		if distance > config.spawn_max_distance_m:
			last_rejection = "too_far"
			continue
		if _in_camera_view(position, camera, player_position, distance):
			last_rejection = "in_view"
			continue
		if _is_occupied(position, occupied):
			last_rejection = "occupied"
			continue
		if not _ground_is_suitable(position):
			last_rejection = "bad_ground"
			continue
		if not _has_free_space(position, space):
			last_rejection = "blocked"
			continue
		# face along the road tangent so the police car starts driving properly
		var tangent: Vector3 = candidate["tangent"]
		return {
			"point": position,
			"tangent": tangent,
			"segment": int(candidate["segment"]),
			"distance": distance,
		}
	return {}


func _candidate_points(player_position: Vector3, player_forward: Vector3) -> Array[Dictionary]:
	var result: Array[Dictionary] = []
	var forward := Vector2(player_forward.x, player_forward.z).normalized()
	if forward.length_squared() < 0.01:
		forward = Vector2(0.0, 1.0)
	# 1) road points in the search area (the road graph knows what is drivable)
	var road_points := network.random_road_point(
		player_position, config.spawn_min_distance_m, config.spawn_max_distance_m, _rng, 26
	)
	if not road_points.is_empty():
		result.append(road_points)
	# 2) points biased *ahead* of the player: they allow a real interception
	for i in range(6):
		var angle := _rng.randf_range(-PI * 0.7, PI * 0.7)
		var direction := forward.rotated(angle)
		var distance := _rng.randf_range(config.spawn_min_distance_m * 1.15, config.spawn_max_distance_m * 0.95)
		var probe := player_position + Vector3(direction.x, 0.0, direction.y) * distance
		var road := network.nearest_road(probe, 90.0)
		if road.is_empty():
			continue
		var width := float(road.get("width", 10.0))
		if width < 7.0:
			continue
		result.append({
			"point": Vector3(road["point"].x, terrain.height_at(road["point"].x, road["point"].z), road["point"].z),
			"tangent": road.get("tangent", Vector3.FORWARD),
			"segment": int(road.get("segment", -1)),
		})
	# 3) fallback: junctions of the road graph around the player
	var ids := network.segments_in_area(player_position, config.spawn_max_distance_m)
	for id in ids:
		if _rng.randf() > 0.25:
			continue
		var point := network.other_end_of(id, _rng.randf() < 0.5)
		if point.distance_to(player_position) < config.spawn_min_distance_m:
			continue
		var segment: RoadNetwork.Segment = network.segments[id]
		result.append({
			"point": Vector3(point.x, terrain.height_at(point.x, point.z), point.z),
			"tangent": segment.tangent_at(segment.length * 0.5),
			"segment": id,
		})
	return result


func _in_camera_view(position: Vector3, camera: Camera3D, player_position: Vector3, distance: float) -> bool:
	if camera == null:
		return false
	if distance > config.spawn_min_screen_distance_m:
		return false
	var viewport := camera.get_viewport()
	if viewport == null:
		return false
	var screen_position := camera.unproject_position(position + Vector3.UP)
	var screen_size := viewport.get_visible_rect().size
	var margin := screen_size * 0.12
	var on_screen := screen_position.x > -margin.x and screen_position.y > -margin.y \
		and screen_position.x < screen_size.x + margin.x and screen_position.y < screen_size.y + margin.y
	# only points in front of the camera can pop in
	if camera.is_position_behind(position):
		return false
	return on_screen


func _is_occupied(position: Vector3, occupied: Array) -> bool:
	for entry in occupied:
		if entry is Vector3:
			if (entry as Vector3).distance_to(position) < config.spawn_min_separation_m:
				return true
		elif entry is Node3D and is_instance_valid(entry):
			if (entry as Node3D).global_position.distance_to(position) < config.spawn_min_separation_m:
				return true
	return false


func _ground_is_suitable(position: Vector3) -> bool:
	if terrain == null:
		return true
	var height := terrain.height_at(position.x, position.z)
	if height <= terrain.config.water_level + 0.4:
		return false
	if terrain.slope_at(position.x, position.z, 6.0) > 0.35:
		return false
	return true


func _has_free_space(position: Vector3, space: PhysicsDirectSpaceState3D) -> bool:
	if space == null:
		return true
	var shape := BoxShape3D.new()
	shape.size = BOX_HALF_EXTENTS * 2.0
	var query := PhysicsShapeQueryParameters3D.new()
	query.shape = shape
	query.transform = Transform3D(Basis(), position + Vector3.UP * BOX_HALF_EXTENTS.y)
	query.collision_mask = 1 | (1 << 1)  # world + props
	query.collide_with_bodies = true
	var hits := space.intersect_shape(query, 1)
	return hits.is_empty()


## A free patch of road to start the player on: the city centre by preference,
## otherwise the closest road to the requested position.
func find_player_start(preferred_position: Vector3) -> Dictionary:
	var road := network.nearest_road(preferred_position, 320.0) if network != null else {}
	if not road.is_empty():
		var width := float(road.get("width", 10.0))
		if width >= 9.0:
			var point: Vector3 = road["point"]
			var tangent: Vector3 = road.get("tangent", Vector3.FORWARD)
			return {
				"point": Vector3(point.x, terrain.height_at(point.x, point.z) + 0.05, point.z),
				"tangent": tangent,
				"segment": int(road.get("segment", -1)),
			}
	# fallback: the flat spot closest to the requested position
	var best := Vector3(preferred_position.x, terrain.height_at(preferred_position.x, preferred_position.z), preferred_position.z)
	return {"point": best, "tangent": Vector3.FORWARD, "segment": -1}


func stats() -> Dictionary:
	return {
		"attempts": attempts_total,
		"last_rejection": last_rejection,
		"candidates": last_candidate_count,
	}
