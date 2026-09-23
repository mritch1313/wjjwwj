class_name PursuitBalance
extends RefCounted

## Single source of truth for the speed balance requested by the design brief:
##
##   * the player car is slightly *slower* than the police,
##   * the police top speed is player_top_speed * 1.01,
##   * the player with nitro active is able to reach police_top_speed * 1.25,
##   * and no AI level ever exceeds the fair police factor (no cheating AI).
##
## Pure functions -> unit tested in tests/unit/test_pursuit_balance.gd.

const POLICE_SPEED_FACTOR := 1.01


static func player_top_speed_ms(player: VehicleConfig) -> float:
	return player.top_speed_ms()


static func police_top_speed_ms(player: VehicleConfig, police: PoliceConfig) -> float:
	return player.top_speed_ms() * police.max_speed_factor_vs_player


static func nitro_top_speed_ms(player: VehicleConfig, police: PoliceConfig) -> float:
	return police_top_speed_ms(player, police) * player.nitro_speed_factor_vs_police


## Speed cap the AI is allowed to use for its level (level factor <=1.01).
static func level_top_speed_ms(player: VehicleConfig, police: PoliceConfig, level: int) -> float:
	var params := police.params_for_level(level)
	return police_top_speed_ms(player, police) * params.max_speed_factor


static func speed_ratios(player: VehicleConfig, police: PoliceConfig) -> Dictionary:
	var police_ms := police_top_speed_ms(player, police)
	var nitro_ms := nitro_top_speed_ms(player, police)
	return {
		"player_kmh": player.top_speed_kmh,
		"police_kmh": police_ms * 3.6,
		"nitro_kmh": nitro_ms * 3.6,
		"police_over_player": police_ms / player.top_speed_ms(),
		"nitro_over_police": nitro_ms / police_ms,
	}
