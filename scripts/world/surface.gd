class_name Surface
extends RefCounted

## Surface taxonomy.  Every piece of generated world geometry knows which
## surface it represents, and the vehicle physics uses it for grip, rolling
## resistance and dust amount.
##
## The friction values themselves are tunable data - see
## data/resources/surface_config.tres (SurfaceConfig) - while the enum and the
## pure helper functions live here so they can be unit tested.

enum Type {
	ASPHALT,     ## city streets, highways, parking lots
	CONCRETE,    ## concrete roads, slabs, bridges
	PAVEMENT,    ## sidewalks, plazas
	GRAVEL,      ## gravel rural roads, shoulders
	DIRT,        ## dirt tracks, construction ground
	GRASS,       ## fields, lawns, verge
	SAND,        ## desert, dunes, beaches
	MUD,         ## wet lowland near the lake
	WATER,       ## shallow water (driveable with heavy penalty)
	METAL,       ## metal plates, grates, ramps
	WOOD,        ## wooden bridges, planks
}

const ALL_TYPES: Array[int] = [
	Type.ASPHALT, Type.CONCRETE, Type.PAVEMENT, Type.GRAVEL,
	Type.DIRT, Type.GRASS, Type.SAND, Type.MUD, Type.WATER, Type.METAL, Type.WOOD,
]


static func name_of(type: int) -> String:
	match type:
		Type.ASPHALT: return "asphalt"
		Type.CONCRETE: return "concrete"
		Type.PAVEMENT: return "pavement"
		Type.GRAVEL: return "gravel"
		Type.DIRT: return "dirt"
		Type.GRASS: return "grass"
		Type.SAND: return "sand"
		Type.MUD: return "mud"
		Type.WATER: return "water"
		Type.METAL: return "metal"
		Type.WOOD: return "wood"
	return "unknown"


static func from_name(text: String) -> int:
	for type in ALL_TYPES:
		if name_of(type) == text:
			return type
	return Type.ASPHALT


## Default grip coefficients (1.0 = reference asphalt).  These are the fallback
## values; SurfaceConfig may override them.
static func default_friction(type: int) -> float:
	match type:
		Type.ASPHALT: return 1.0
		Type.CONCRETE: return 0.97
		Type.PAVEMENT: return 0.95
		Type.GRAVEL: return 0.72
		Type.DIRT: return 0.64
		Type.GRASS: return 0.58
		Type.SAND: return 0.45
		Type.MUD: return 0.34
		Type.WATER: return 0.4
		Type.METAL: return 0.85
		Type.WOOD: return 0.82
	return 1.0


static func default_roughness(type: int) -> float:
	match type:
		Type.ASPHALT: return 0.15
		Type.CONCRETE: return 0.25
		Type.PAVEMENT: return 0.3
		Type.GRAVEL: return 0.75
		Type.DIRT: return 0.7
		Type.GRASS: return 0.65
		Type.SAND: return 0.55
		Type.MUD: return 0.8
		Type.WATER: return 0.5
		Type.METAL: return 0.4
		Type.WOOD: return 0.45
	return 0.3


static func is_paved(type: int) -> bool:
	return type == Type.ASPHALT or type == Type.CONCRETE or type == Type.PAVEMENT


## Dust / dirt particles when driving on this surface (0 = none, 1 = heavy).
static func dust_amount(type: int) -> float:
	match type:
		Type.SAND: return 1.0
		Type.DIRT: return 0.8
		Type.GRAVEL: return 0.6
		Type.MUD: return 0.7
		Type.GRASS: return 0.25
		Type.WOOD: return 0.15
	return 0.0


## Tyre screech intensity multiplier.
static func screech_amount(type: int) -> float:
	match type:
		Type.ASPHALT: return 1.0
		Type.CONCRETE: return 0.95
		Type.PAVEMENT: return 0.9
		Type.METAL: return 0.85
		Type.WOOD: return 0.5
	return 0.1
