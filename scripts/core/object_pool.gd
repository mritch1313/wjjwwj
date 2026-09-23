class_name ObjectPool
extends RefCounted

## Lightweight node pool.  Used for police cars, impact particles and debris
## where creating/freeing nodes every event would cause frame spikes on mobile.

var _factory: Callable
var _reset: Callable
var _free_list: Array[Node] = []
var _created_count: int = 0
var _active_count: int = 0


## factory: Callable() -> Node, reset: Callable(node) -> void
func _init(factory: Callable, reset: Callable = Callable()) -> void:
	_factory = factory
	_reset = reset


func acquire(parent: Node = null) -> Node:
	var node: Node
	if _free_list.is_empty():
		node = _factory.call()
		_created_count += 1
	else:
		node = _free_list.pop_back()
	if parent != null and node.get_parent() == null:
		parent.add_child(node)
	if node is Node3D:
		(node as Node3D).visible = true
	if node is CollisionObject3D:
		(node as CollisionObject3D).set_physics_process(true)
	_active_count += 1
	return node


func release(node: Node) -> void:
	if node == null:
		return
	if _reset.is_valid():
		_reset.call(node)
	if node is Node3D:
		(node as Node3D).visible = false
	if node is CollisionObject3D:
		(node as CollisionObject3D).set_physics_process(false)
	_active_count = maxi(_active_count - 1, 0)
	if not _free_list.has(node):
		_free_list.push_back(node)


func release_all(nodes: Array[Node]) -> void:
	for node in nodes:
		release(node)


func active_count() -> int:
	return _active_count


func created_count() -> int:
	return _created_count


func free_count() -> int:
	return _free_list.size()
