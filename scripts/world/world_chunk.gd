class_name WorldChunk
extends Node3D

## One streamed chunk of the world: the generated geometry plus its collision.
##
## A chunk never generates data itself (WorldGenerator does that, so the world is
## described in exactly one place); the node only owns the resources and can be
## *retiered* - the same chunk may come back at a lower LOD when the player drives
## away, without being freed and regenerated.
##
## Geometry arrives as four layers (terrain, roads, structures, foliage), each in
## its own MeshInstance3D: the layers have different render flags (foliage uses
## alpha scissor and casts no shadow, structures cast shadows) and different LOD
## lifetimes, which one merged mesh could not express.

## Layer order of WorldGenerator.generate_chunk()["meshes"].
enum Layer { TERRAIN, ROADS, STRUCTURES, FOLIAGE }

const TIER_NEAR := 0
const TIER_MID := 1
const TIER_FAR := 2

const LAYER_NAMES := ["Terrain", "Roads", "Structures", "Foliage"]

var cell: Vector2i = Vector2i.ZERO
var tier: int = TIER_NEAR
var triangle_count: int = 0
var building_count: int = 0
var generated_ms: float = 0.0
var surface_count: int = 0

var _layers: Array[MeshInstance3D] = []
var _static_body: StaticBody3D = null
var _collider_shapes: Array = []


## Applies freshly generated content (a chunk may be rebuilt on a tier change).
func apply_content(
	chunk_cell: Vector2i,
	chunk_tier: int,
	meshes: Array,
	colliders: Array,
	buildings: int,
	generation_ms: float
) -> void:
	cell = chunk_cell
	tier = chunk_tier
	name = "Chunk_%d_%d_T%d" % [cell.x, cell.y, tier]
	building_count = buildings
	generated_ms = generation_ms
	_ensure_nodes()
	triangle_count = 0
	surface_count = 0
	for index in range(_layers.size()):
		var instance := _layers[index]
		var mesh: Mesh = meshes[index] if index < meshes.size() else null
		instance.mesh = mesh
		if mesh == null:
			instance.visible = false
			continue
		instance.visible = true
		surface_count += mesh.get_surface_count()
		triangle_count += _count_triangles(mesh)
	_apply_collision(colliders)
	_apply_tier_flags()


func _ensure_nodes() -> void:
	if not _layers.is_empty():
		return
	for index in range(LAYER_NAMES.size()):
		var instance := MeshInstance3D.new()
		instance.name = LAYER_NAMES[index]
		if index == Layer.FOLIAGE:
			# Foliage is alpha-scissored: no shadows (mobile fill rate) and it is
			# allowed to disappear at distance before the opaque geometry does.
			instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(instance)
		_layers.append(instance)
	_static_body = StaticBody3D.new()
	_static_body.name = "Collision"
	_static_body.collision_layer = 1  # layer 1 = world
	_static_body.collision_mask = 0
	add_child(_static_body)


## Collision arrives as plain descriptions ({"shape": "box", ...}) so the world
## generator stays free of engine node types; the chunk turns them into shapes.
func _apply_collision(colliders: Array) -> void:
	for shape in _collider_shapes:
		if is_instance_valid(shape):
			shape.queue_free()
	_collider_shapes.clear()
	if colliders == null:
		return
	for entry in colliders:
		var shape := _make_shape(entry)
		if shape == null:
			continue
		var node := CollisionShape3D.new()
		node.shape = shape
		node.transform = entry.get("transform", Transform3D.IDENTITY)
		_static_body.add_child(node)
		_collider_shapes.append(node)


func _make_shape(entry: Dictionary) -> Shape3D:
	var kind: String = String(entry.get("shape", ""))
	match kind:
		"box":
			var box := BoxShape3D.new()
			box.size = entry.get("size", Vector3.ONE)
			return box
		"cylinder":
			var cylinder := CylinderShape3D.new()
			cylinder.radius = float(entry.get("radius", 0.5))
			cylinder.height = float(entry.get("height", 1.0))
			return cylinder
		"trimesh":
			var trimesh := ConcavePolygonShape3D.new()
			trimesh.set_faces(entry.get("faces", PackedVector3Array()))
			# Тонкая коллизия земли: машина на скорости проваливается сквозь неё,
			# если у машины выключено непрерывное обнаружение столкновений (оно
			# включено) или если скорость выше, чем допускает форма.  Флаг ниже
			# помечает форму как "тонкую" для физического движка.
			trimesh.backface_collision = true
			return trimesh
		"heightmap":
			var heightmap := HeightMapShape3D.new()
			heightmap.map_width = int(entry.get("width", 0))
			heightmap.map_depth = int(entry.get("depth", 0))
			heightmap.map_data = entry.get("heights", PackedFloat32Array())
			return heightmap
		_:
			return null


func _apply_tier_flags() -> void:
	# Far chunks keep the silhouette but drop the small stuff: foliage gone and
	# no shadow casting at all (the LOD3 budget of the design brief).
	if _layers.is_empty():
		return
	if tier == TIER_FAR:
		_layers[Layer.FOLIAGE].visible = false
	# Тени бросают только ближние чанки.  Карта теней на телефоне 512-1024 px,
	# она физически не покрывает сотни метров: тень от дома в 250 м всё равно не
	# видна, а её отрисовка стоит прохода по всей геометрии среднего кольца.
	for index in range(_layers.size()):
		var instance := _layers[index]
		if instance.mesh == null or index == Layer.FOLIAGE:
			continue
		instance.cast_shadow = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_ON if tier == TIER_NEAR
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		)


## Distance culling на стороне движка: слой перестаёт рисоваться за своей
## дальностью (visibility_range_*), ещё до того, как стример успел выгрузить
## чанк.  Растительность убирается раньше остальных слоёв: она мелкая и
## заполняет экран, а её вклад в силуэт города нулевой.
func set_cull_distances(structure_end_m: float, foliage_end_m: float) -> void:
	if _layers.is_empty():
		return
	for index in range(_layers.size()):
		var instance := _layers[index]
		var end := foliage_end_m if index == Layer.FOLIAGE else structure_end_m
		instance.visibility_range_end = end
		# мягкое затухание, чтобы удалённый слой не исчезал рывком
		instance.visibility_range_end_margin = maxf(end * 0.08, 4.0)
		instance.visibility_range_fade_mode = GeometryInstance3D.VISIBILITY_RANGE_FADE_SELF


## Дальность отрисовки слоя (для теста и для отладки HUD).
func cull_distance_of(layer: int) -> float:
	if layer < 0 or layer >= _layers.size():
		return 0.0
	return _layers[layer].visibility_range_end


func _count_triangles(mesh: Mesh) -> int:
	if not (mesh is ArrayMesh):
		return 0
	var total := 0
	var array_mesh := mesh as ArrayMesh
	for surface in range(array_mesh.get_surface_count()):
		var arrays: Array = array_mesh.surface_get_arrays(surface)
		var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
		total += vertices.size() / 3  # the builder emits non-indexed triangles
	return total


## Global (world space) AABB of the chunk content - used for culling debug.
func world_aabb() -> AABB:
	if _layers.is_empty() or _layers[Layer.TERRAIN].mesh == null:
		return AABB(global_position, Vector3.ZERO)
	return _layers[Layer.TERRAIN].get_aabb()


func has_collision() -> bool:
	return _collider_shapes.size() > 0


func collision_shape_count() -> int:
	return _collider_shapes.size()


func debug_info() -> Dictionary:
	return {
		"cell": cell,
		"tier": tier,
		"triangles": triangle_count,
		"surfaces": surface_count,
		"buildings": building_count,
		"colliders": _collider_shapes.size(),
		"generated_ms": snappedf(generated_ms, 0.01),
	}
