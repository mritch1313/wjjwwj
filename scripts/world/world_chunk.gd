class_name WorldChunk
extends Node3D

## One streamed chunk of the world: the generated geometry plus its collision.
##
## A chunk never generates data itself (WorldGenerator does that, so the world
## is described in exactly one place); the node only owns the resources and can
## be *retiered* - the same chunk may come back at a lower LOD when the player
## drives away, without being freed and regenerated.

const TIER_NEAR := 0
const TIER_MID := 1
const TIER_FAR := 2

var cell: Vector2i = Vector2i.ZERO
var tier: int = TIER_NEAR
var triangle_count: int = 0
var generated_ms: float = 0.0
var visible_layer_count: int = 0

var _mesh_instance: MeshInstance3D = null
var _foliage_instance: MeshInstance3D = null
var _static_body: StaticBody3D = null
var _collider_shapes: Array = []


func setup(chunk_cell: Vector2i, chunk_tier: int, mesh: ArrayMesh, foliage: ArrayMesh, collision: Dictionary) -> void:
	cell = chunk_cell
	tier = chunk_tier
	name = "Chunk_%d_%d_T%d" % [cell.x, cell.y, tier]
	_ensure_nodes()
	_mesh_instance.mesh = mesh
	visible_layer_count = 0
	if mesh != null:
		visible_layer_count = mesh.get_surface_count()
	triangle_count = _count_triangles(mesh)
	if foliage != null:
		_foliage_instance.mesh = foliage
		_foliage_instance.visible = true
		triangle_count += _count_triangles(foliage)
	else:
		_foliage_instance.mesh = null
		_foliage_instance.visible = false
	_apply_collision(collision)
	_apply_tier_flags()


func _ensure_nodes() -> void:
	if _mesh_instance == null:
		_mesh_instance = MeshInstance3D.new()
		_mesh_instance.name = "Geometry"
		add_child(_mesh_instance)
	if _foliage_instance == null:
		_foliage_instance = MeshInstance3D.new()
		_foliage_instance.name = "Foliage"
		# Foliage uses alpha scissor: no shadows (mobile fill rate) and it is
		# allowed to disappear at distance before the opaque geometry does.
		_foliage_instance.cast_shadow = GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		add_child(_foliage_instance)
	if _static_body == null:
		_static_body = StaticBody3D.new()
		_static_body.name = "Collision"
		_static_body.collision_layer = 1  # layer 1 = world
		_static_body.collision_mask = 0
		add_child(_static_body)


func _apply_collision(collision: Dictionary) -> void:
	for shape in _collider_shapes:
		if is_instance_valid(shape):
			shape.queue_free()
	_collider_shapes.clear()
	if collision == null or collision.is_empty():
		return
	var shapes: Array = collision.get("shapes", [])
	for entry in shapes:
		var shape_node := CollisionShape3D.new()
		shape_node.shape = entry["shape"]
		shape_node.transform = entry["transform"]
		_static_body.add_child(shape_node)
		_collider_shapes.append(shape_node)


func _apply_tier_flags() -> void:
	# Far chunks keep the silhouette but drop the small stuff.
	if _foliage_instance != null and tier == TIER_FAR:
		_foliage_instance.visible = false
	var cast_shadows := tier != TIER_FAR
	if _mesh_instance != null:
		_mesh_instance.cast_shadow = (
			GeometryInstance3D.SHADOW_CASTING_SETTING_ON if cast_shadows
			else GeometryInstance3D.SHADOW_CASTING_SETTING_OFF
		)


func _count_triangles(mesh: Mesh) -> int:
	if not (mesh is ArrayMesh):
		return 0
	var total := 0
	var array_mesh := mesh as ArrayMesh
	for surface in range(array_mesh.get_surface_count()):
		var arrays: Array = array_mesh.surface_get_arrays(surface)
		var indices: PackedInt32Array = arrays[Mesh.ARRAY_INDEX]
		total += indices.size() / 3
	return total


## Global (world space) AABB of the chunk content - used for culling debug.
func world_aabb() -> AABB:
	if _mesh_instance == null or _mesh_instance.mesh == null:
		return AABB(global_position, Vector3.ZERO)
	return _mesh_instance.get_aabb()


func has_collision() -> bool:
	return _collider_shapes.size() > 0


func collision_shape_count() -> int:
	return _collider_shapes.size()


func debug_info() -> Dictionary:
	return {
		"cell": cell,
		"tier": tier,
		"triangles": triangle_count,
		"surfaces": visible_layer_count,
		"colliders": _collider_shapes.size(),
		"generated_ms": snappedf(generated_ms, 0.01),
	}
