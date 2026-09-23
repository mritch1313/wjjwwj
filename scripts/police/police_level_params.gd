class_name PoliceLevelParams
extends Resource

## Parameters of one police AI difficulty level (1..4).
##
## The brief is explicit: difficulty must come from *decisions*, never from
## unfair physics bonuses.  Therefore every speed factor is capped at the fair
## police advantage (1.01) and grip is never modified - see grip_factor, which
## always stays 1.0.

@export var level: int = 1
@export var display_name: String = "Level 1"
@export var description: String = ""

@export_group("Perception and planning")
## How many seconds ahead the AI extrapolates the player trajectory.
@export var prediction_horizon_s: float = 0.0
## How often the intercept route is recomputed.
@export var reroute_interval_s: float = 3.0
## How often the strategic role is re-evaluated by the manager.
@export var strategic_interval_s: float = 3.5
## Artificial reaction delay before the AI reacts to a player manoeuvre.
@export var reaction_delay_s: float = 0.7
@export var mistake_chance: float = 0.4
@export var steering_noise: float = 0.22
@export var uses_road_graph: bool = false
@export var reads_maneuvers: bool = false
@export var escape_route_prediction: bool = false

@export_group("Driving skill")
@export var corner_discipline: float = 0.5
@export var throttle_discipline: float = 0.55
## <= 1.01 : the police never get more than the agreed advantage.
@export var max_speed_factor: float = 0.9
## 1.0 = brakes at the physically correct point, <1 brakes too late.
@export var brake_lookahead_factor: float = 0.55
@export var head_on_risk: float = 0.5
@export var spacing_m: float = 26.0
@export var stuck_recovery: bool = false
@export var grip_factor: float = 1.0

@export_group("Roles")
@export var intercept_skill: float = 0.0
@export var interception_lead_s: float = 0.0
@export var block_enabled: bool = false
@export var pin_enabled: bool = false
@export var support_enabled: bool = false
@export var road_bias: float = 1.0
@export var offroad_speed_factor: float = 0.6


static func make(level: int) -> PoliceLevelParams:
	var p := PoliceLevelParams.new()
	p.level = level
	match level:
		1:
			p.display_name = "Level 1 - Rookie"
			p.description = "Tails the player, makes mistakes, brakes late, poor routes."
			p.prediction_horizon_s = 0.0
			p.reroute_interval_s = 3.0
			p.strategic_interval_s = 3.5
			p.reaction_delay_s = 0.7
			p.mistake_chance = 0.4
			p.steering_noise = 0.22
			p.uses_road_graph = false
			p.reads_maneuvers = false
			p.escape_route_prediction = false
			p.corner_discipline = 0.5
			p.throttle_discipline = 0.55
			p.max_speed_factor = 0.9
			p.brake_lookahead_factor = 0.55
			p.head_on_risk = 0.5
			p.spacing_m = 28.0
			p.stuck_recovery = false
			p.intercept_skill = 0.0
			p.interception_lead_s = 0.0
			p.block_enabled = false
			p.pin_enabled = false
			p.support_enabled = false
			p.offroad_speed_factor = 0.55
		2:
			p.display_name = "Level 2 - Officer"
			p.description = "Reads the player's heading and speed, tries to cut corners."
			p.prediction_horizon_s = 1.2
			p.reroute_interval_s = 1.8
			p.strategic_interval_s = 2.2
			p.reaction_delay_s = 0.4
			p.mistake_chance = 0.18
			p.steering_noise = 0.12
			p.uses_road_graph = true
			p.reads_maneuvers = false
			p.escape_route_prediction = false
			p.corner_discipline = 0.7
			p.throttle_discipline = 0.75
			p.max_speed_factor = 0.97
			p.brake_lookahead_factor = 0.8
			p.head_on_risk = 0.25
			p.spacing_m = 22.0
			p.stuck_recovery = true
			p.intercept_skill = 0.4
			p.interception_lead_s = 1.6
			p.block_enabled = false
			p.pin_enabled = false
			p.support_enabled = false
			p.offroad_speed_factor = 0.65
		3:
			p.display_name = "Level 3 - Detective"
			p.description = "Predicts the trajectory, takes intersections, boxes the player in."
			p.prediction_horizon_s = 2.2
			p.reroute_interval_s = 1.2
			p.strategic_interval_s = 1.3
			p.reaction_delay_s = 0.22
			p.mistake_chance = 0.08
			p.steering_noise = 0.06
			p.uses_road_graph = true
			p.reads_maneuvers = true
			p.escape_route_prediction = false
			p.corner_discipline = 0.86
			p.throttle_discipline = 0.9
			p.max_speed_factor = 1.0
			p.brake_lookahead_factor = 1.0
			p.head_on_risk = 0.1
			p.spacing_m = 18.0
			p.stuck_recovery = true
			p.intercept_skill = 0.75
			p.interception_lead_s = 2.6
			p.block_enabled = true
			p.pin_enabled = false
			p.support_enabled = true
			p.offroad_speed_factor = 0.72
		4:
			p.display_name = "Level 4 - Interceptor"
			p.description = "Human-like pursuit: reads manoeuvres, blocks escape routes, pins the car."
			p.prediction_horizon_s = 3.4
			p.reroute_interval_s = 0.8
			p.strategic_interval_s = 0.9
			p.reaction_delay_s = 0.14
			p.mistake_chance = 0.02
			p.steering_noise = 0.02
			p.uses_road_graph = true
			p.reads_maneuvers = true
			p.escape_route_prediction = true
			p.corner_discipline = 0.95
			p.throttle_discipline = 0.98
			p.max_speed_factor = 1.01
			p.brake_lookahead_factor = 1.15
			p.head_on_risk = 0.05
			p.spacing_m = 14.0
			p.stuck_recovery = true
			p.intercept_skill = 1.0
			p.interception_lead_s = 3.4
			p.block_enabled = true
			p.pin_enabled = true
			p.support_enabled = true
			p.offroad_speed_factor = 0.8
		_:
			return make(clampi(level, 1, 4))
	p.grip_factor = 1.0
	return p


## Does this level use the given role?  (Level 1 only chases, level 4 uses all.)
func can_role(role: int) -> bool:
	return role_set().has(role)


func speed_factor() -> float:
	return minf(max_speed_factor, PursuitBalance.POLICE_SPEED_FACTOR)


func can_intercept() -> bool:
	return intercept_skill > 0.0


func can_block() -> bool:
	return block_enabled


func role_set() -> Array[int]:
	var roles: Array[int] = [PoliceRole.Type.CHASE]
	if can_intercept():
		roles.append(PoliceRole.Type.INTERCEPT)
	if can_block():
		roles.append(PoliceRole.Type.BLOCK)
	if support_enabled:
		roles.append(PoliceRole.Type.SUPPORT)
	if pin_enabled:
		roles.append(PoliceRole.Type.PIN)
	return roles
