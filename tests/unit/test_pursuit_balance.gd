extends TestCase

## The single most important balance rule of the brief:
##   police without nitro  ~= player max * 1.01
##   player with nitro     ~= police max * 1.25
## These numbers are asserted on the *estimated top speeds*, not on the raw
## config factors, so a change to the car setup cannot quietly break the rule.

var player: VehicleConfig
var police: VehicleConfig
var police_config: PoliceConfig


func before_all() -> void:
	player = Config.vehicle_player
	police = Config.vehicle_police
	police_config = Config.police


func test_player_and_police_are_different_cars() -> void:
	assert_ne(player.display_name, police.display_name, "машина игрока и полиция - разные конфиги")
	assert_gt(player.top_speed_ms(), 0.0, "у игрока есть максимальная скорость")


func test_police_without_nitro_is_one_percent_faster_on_paper() -> void:
	var ratio := PursuitBalance.speed_ratios(player, police_config)
	assert_almost_eq(float(ratio["police_over_player"]), 1.01, 0.02, "полиция быстрее на 1% (по конфигу)")
	var player_top := VehicleController.estimate_top_speed_ms(player)
	var police_top := VehicleController.estimate_top_speed_ms(police)
	var real_ratio := police_top / maxf(player_top, 0.1)
	assert_almost_eq(real_ratio, 1.01, 0.06, "и по расчёту реальной физики разница ~1%")


func test_player_with_nitro_gets_about_twenty_five_percent_advantage() -> void:
	var ratio := PursuitBalance.speed_ratios(player, police_config)
	assert_almost_eq(float(ratio["nitro_over_police"]), 1.25, 0.03, "нитро даёт игроку ~+25% над полицией")
	var nitro := NitroSystem.new(player)
	var police_top := VehicleController.estimate_top_speed_ms(police)
	var boosted_ratio := nitro.top_speed_with_boost_ms() / maxf(police_top, 0.1)
	assert_between(boosted_ratio, 1.12, 1.30, "буст по физике превышает полицию, но не кардинально")


func test_police_never_gets_grip_bonus() -> void:
	for level in range(1, police_config.level_count() + 1):
		var params: PoliceLevelParams = police_config.params_for_level(level)
		assert_almost_eq(params.grip_factor, 1.0, 0.001, "уровень %d не получает читерского сцепления" % level)


func test_level_speed_factors_are_monotonic_and_capped() -> void:
	var previous := 0.0
	for level in range(1, police_config.level_count() + 1):
		var params: PoliceLevelParams = police_config.params_for_level(level)
		assert_ge(params.max_speed_factor, previous, "уровень %d не медленнее предыдущего" % level)
		assert_le(params.max_speed_factor, 1.02, "уровень %d не превышает честный предел" % level)
		previous = params.max_speed_factor


func test_higher_levels_only_change_decisions_not_physics() -> void:
	var easy: PoliceLevelParams = police_config.params_for_level(1)
	var hard: PoliceLevelParams = police_config.params_for_level(4)
	assert_gt(hard.prediction_horizon_s, easy.prediction_horizon_s, "высокий уровень предсказывает дальше")
	assert_lt(hard.mistake_chance, easy.mistake_chance, "высокий уровень ошибается реже")
	assert_lt(hard.reaction_delay_s, easy.reaction_delay_s, "высокий уровень реагирует быстрее")
	assert_almost_eq(hard.grip_factor, easy.grip_factor, 0.001, "сцепление одинаковое на всех уровнях")


func test_role_sets_widen_with_level() -> void:
	var easy_roles: Array = police_config.params_for_level(1).role_set()
	var hard_roles: Array = police_config.params_for_level(4).role_set()
	assert_true(easy_roles.has(PoliceRole.Type.CHASE), "преследование доступно всем")
	assert_gt(float(hard_roles.size()), float(easy_roles.size()), "высокий уровень использует больше ролей")
	assert_true(hard_roles.has(PoliceRole.Type.SUPPORT), "поддержка появляется на высоком уровне")
