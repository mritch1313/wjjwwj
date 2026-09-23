class_name SurfaceConfig
extends Resource

## Tunable grip / roughness per surface type.  Defaults come from Surface, this
## resource only exists so a designer can re-balance handling without touching
## code (data/resources/surface_default.tres).

@export var friction: Dictionary = {
	Surface.Type.ASPHALT: 1.0,
	Surface.Type.CONCRETE: 0.97,
	Surface.Type.PAVEMENT: 0.95,
	Surface.Type.GRAVEL: 0.72,
	Surface.Type.DIRT: 0.64,
	Surface.Type.GRASS: 0.58,
	Surface.Type.SAND: 0.45,
	Surface.Type.MUD: 0.34,
	Surface.Type.WATER: 0.4,
	Surface.Type.METAL: 0.85,
	Surface.Type.WOOD: 0.82,
}

@export var roughness: Dictionary = {}


func friction_of(type: int) -> float:
	if friction.has(type):
		return float(friction[type])
	return Surface.default_friction(type)


func roughness_of(type: int) -> float:
	if roughness.has(type):
		return float(roughness[type])
	return Surface.default_roughness(type)


func ensure_complete() -> void:
	for type in Surface.ALL_TYPES:
		if not friction.has(type):
			friction[type] = Surface.default_friction(type)
		if not roughness.has(type):
			roughness[type] = Surface.default_roughness(type)
