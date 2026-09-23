class_name WorldFixture
extends RefCounted

## One generated world shared by all tests: WorldGenerator data (regions, roads,
## city, terrain field) is deterministic for a fixed seed, so building it once
## keeps the head-less test run fast while every test still works on the *real*
## world instead of a mock.

static var _config: WorldConfig = null
static var _generator: WorldGenerator = null


static func config() -> WorldConfig:
	if _config == null:
		_config = WorldConfig.new()
	return _config


static func generator() -> WorldGenerator:
	if _generator == null:
		_generator = WorldGenerator.new(config())
	return _generator


static func terrain() -> TerrainField:
	return generator().terrain


static func network() -> RoadNetwork:
	return generator().network


static func regions() -> RegionMap:
	return generator().region_map


static func reset() -> void:
	_config = null
	_generator = null
