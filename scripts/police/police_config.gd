class_name PoliceConfig
extends Resource

## Pursuit balance, perception ranges and recovery behaviour of the police.
##
## Fairness contract (checked by tests/unit/test_pursuit_balance.gd):
##   * max_speed_factor_vs_player is 1.01 - the police is only marginally faster,
##   * no level may exceed that factor (PoliceLevelParams.speed_factor()),
##   * grip is never modified for the AI.

@export_group("Balance")
@export var max_speed_factor_vs_player: float = PursuitBalance.POLICE_SPEED_FACTOR
@export var levels: Array[PoliceLevelParams] = []

@export_group("Perception")
## Distance at which police keeps tracking the player.
@export var detection_radius_m: float = 380.0
## How far ahead (along roads) an intercept may be planned.
@export var intercept_radius_m: float = 640.0
## Time without a visual/road contact before a car switches to REGROUP.
@export var lose_sight_time_s: float = 6.0
@export var last_known_memory_s: float = 8.0

@export_group("Coordination")
@export var min_spacing_m: float = 15.0
@export var avoidance_lookahead_m: float = 26.0
@export var friendly_collision_slowdown: float = 0.55
@export var max_cars_on_same_route: int = 2

@export_group("Driving")
@export var road_follow_lookahead_m: float = 16.0
@export var throttle_smoothing: float = 4.0
@export var steering_smoothing: float = 7.0
@export var stuck_speed_ms: float = 1.3
@export var stuck_time_s: float = 2.2
@export var stuck_reverse_time_s: float = 1.5
@export var recovery_cooldown_s: float = 4.0
@export var offroad_max_speed_factor: float = 0.7
@export var curb_slowdown_ms: float = 9.0

@export_group("Appearance")
@export var livery_color: Color = Color(0.09, 0.11, 0.15)
@export var stripe_color: Color = Color(0.95, 0.95, 0.97)
@export var lightbar_color_a: Color = Color(0.95, 0.12, 0.12)
@export var lightbar_color_b: Color = Color(0.15, 0.35, 1.0)
@export var police_vehicle: VehicleConfig = null


func _init() -> void:
	levels.clear()
	for level in range(1, 5):
		levels.append(PoliceLevelParams.make(level))


func level_count() -> int:
	return levels.size()


func params_for_level(level: int) -> PoliceLevelParams:
	if levels.is_empty():
		return PoliceLevelParams.make(1)
	var index := clampi(level, 1, levels.size()) - 1
	return levels[index]


func ensure_levels() -> void:
## Rebuilds the level table if a designer cleared it in the editor.
	if levels.is_empty():
		_init()
