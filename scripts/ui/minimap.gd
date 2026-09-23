class_name Minimap
extends Control

## Code drawn minimap (no textures, no extra nodes).
##
## The road geometry is cached and refreshed a few times per second instead of
## every frame, because the map is drawn with `draw_polyline` and would otherwise
## cost more than the world itself.  The view is rotated so that the car's heading
## always points up, which is what players expect from a chase game.

const REFRESH_INTERVAL_S := 0.5

var player: Node3D = null
var police_manager: PoliceManager = null
var network: RoadNetwork = null

## How much of the world fits on the map (metres from the centre to the edge).
var range_m: float = 320.0
var background_color: Color = Color(0.05, 0.06, 0.08, 0.72)
var road_color: Color = Color(0.85, 0.86, 0.9, 0.55)
var highway_color: Color = Color(0.95, 0.85, 0.45, 0.8)
var player_color: Color = Color(1.0, 1.0, 1.0)
var police_color: Color = Color(0.95, 0.25, 0.2)
var water_color: Color = Color(0.2, 0.38, 0.62, 0.5)
var border_color: Color = Color(0.7, 0.78, 0.9, 0.5)

var _cache: Array[PackedVector2Array] = []
var _cache_types: PackedInt32Array = PackedInt32Array()
var _refresh_timer: float = 0.0
var _cache_center: Vector3 = Vector3(1e9, 0.0, 1e9)
var _font: Font = null
var _water_polygon: PackedVector2Array = PackedVector2Array()


func _ready() -> void:
	_font = ThemeDB.fallback_font
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	set_process(true)


func set_world(roads: RoadNetwork) -> void:
	network = roads
	_cache.clear()
	_cache_types = PackedInt32Array()
	_refresh_timer = 0.0


func _process(delta: float) -> void:
	_refresh_timer -= delta
	if _refresh_timer <= 0.0:
		_refresh_timer = REFRESH_INTERVAL_S
		_rebuild_cache()
	queue_redraw()


func _rebuild_cache() -> void:
	_cache.clear()
	_cache_types = PackedInt32Array()
	if network == null or player == null or not is_instance_valid(player):
		return
	var center := player.global_position
	_cache_center = center
	var ids := network.segments_in_area(center, range_m * 1.2)
	for id in ids:
		var segment: RoadNetwork.Segment = network.segments[id]
		if segment.points.size() < 2:
			continue
		var polyline := PackedVector2Array()
		for point in segment.points:
			polyline.append(Vector2(point.x, point.z))
		_cache.append(polyline)
		_cache_types.append(segment.type)


## World (x, z) -> local map coordinates (car heading up).
func world_to_map(x: float, z: float, center: Vector3, yaw: float) -> Vector2:
	var scale := minf(size.x, size.y) * 0.5 / maxf(range_m, 0.001)
	var local := Vector2(x - center.x, z - center.z) * scale
	var rotated := local.rotated(-yaw + PI)
	return size * 0.5 + Vector2(rotated.x, -rotated.y)


func _draw() -> void:
	var rect := Rect2(Vector2.ZERO, size)
	draw_rect(rect, background_color, true)
	draw_rect(rect, border_color, false, 2.0)
	if player == null or not is_instance_valid(player):
		return
	var center := player.global_position
	var forward: Vector3 = player.call("forward_direction") if player.has_method("forward_direction") else Vector3.FORWARD
	var yaw := atan2(forward.x, forward.z)
	# clip everything to the map square
	for i in range(_cache.size()):
		var polyline := _cache[i]
		var mapped := PackedVector2Array()
		for point in polyline:
			mapped.append(world_to_map(point.x, point.y, center, yaw))
		var road_type := _cache_types[i]
		var color := highway_color if road_type == RoadNetwork.RoadType.HIGHWAY or road_type == RoadNetwork.RoadType.RAMP else road_color
		var width := 4.0 if color == highway_color else 2.4
		draw_polyline(mapped, color, width, true)
	# police cars
	if police_manager != null and is_instance_valid(police_manager):
		for car in police_manager.cars:
			if not is_instance_valid(car):
				continue
			var point := world_to_map(car.global_position.x, car.global_position.z, center, yaw)
			draw_circle(point, 4.0, police_color)
	# player arrow at the centre (always pointing up)
	var center_point := size * 0.5
	var arrow := PackedVector2Array([
		center_point + Vector2(0.0, -8.0),
		center_point + Vector2(6.0, 7.0),
		center_point + Vector2(0.0, 4.0),
		center_point + Vector2(-6.0, 7.0),
	])
	draw_colored_polygon(arrow, player_color)
	if _font != null:
		draw_string(_font, Vector2(6.0, size.y - 6.0), "%d м" % int(range_m), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, Color(0.85, 0.9, 1.0, 0.7))


## Metres represented by one pixel - used by tests and by the debug overlay.
func metres_per_pixel() -> float:
	return maxf(range_m, 1.0) / maxf(minf(size.x, size.y) * 0.5, 1.0)


func stats() -> Dictionary:
	return {
		"segments": _cache.size(),
		"range_m": range_m,
		"scale": metres_per_pixel(),
		"center": _cache_center,
	}
