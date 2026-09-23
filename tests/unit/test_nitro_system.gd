extends TestCase

## Nitro is a *physical* thrust with a charge, a depletion cooldown and a
## recharge - all of it is checked here so a future tuning pass cannot silently
## turn it into a magic speed multiplier.

var config: VehicleConfig
var nitro: NitroSystem


func before_all() -> void:
	config = VehicleConfig.new()
	nitro = NitroSystem.new(config)


func test_starts_full_and_ready() -> void:
	nitro.refill()
	assert_almost_eq(nitro.charge_ratio(), 1.0, 0.001, "бак полный после refill")
	assert_true(nitro.can_activate(), "нитро готово к использованию")


func test_boost_drains_charge_and_produces_thrust() -> void:
	nitro.refill()
	var thrust := 0.0
	var steps := int(config.nitro_capacity_s * 60.0)
	for i in range(steps):
		thrust = nitro.update(1.0 / 60.0, true)
	assert_gt(thrust, 0.0, "во время буста есть тяга")
	assert_lt(nitro.charge_ratio(), 0.1, "заряд почти исчерпан за полное время работы")
	assert_gt(nitro.total_used_s, config.nitro_capacity_s * 0.9, "учтено израсходованное время")


func test_depleted_nitro_enters_cooldown_then_recharges() -> void:
	nitro.refill()
	for i in range(int(config.nitro_capacity_s * 60.0) + 6):
		nitro.update(1.0 / 60.0, true)
	assert_false(nitro.active, "после опустошения буст выключается")
	assert_gt(nitro.cooldown_s, 0.0, "включается перезарядка-кулдаун")
	# immediately asking again must not work
	assert_false(nitro.can_activate(), "во время кулдауна нитро недоступно")
	# wait out the recharge
	for i in range(int((config.nitro_cooldown_s + config.nitro_recharge_s) * 60.0) + 60):
		nitro.update(1.0 / 60.0, false)
	assert_almost_eq(nitro.charge_ratio(), 1.0, 0.02, "бак полностью восстанавливается")
	assert_true(nitro.can_activate(), "после перезарядки нитро снова доступно")


func test_boost_raises_speed_cap_only_by_the_agreed_factor() -> void:
	nitro.refill()
	var base := config.top_speed_ms()
	var boosted := nitro.top_speed_with_boost_ms()
	# The design rule is stated against the *police* top speed (+25%), and the police
	# are 1.01 faster than the player, so the player's own limiter rises by 1.01*1.25.
	var expected := PursuitBalance.POLICE_SPEED_FACTOR * 1.25
	assert_almost_eq(boosted / base, expected, 0.01, "буст поднимает ограничение на %.1f%%" % ((expected - 1.0) * 100.0))
	assert_almost_eq(NitroSystem.SPEED_FACTOR, expected, 0.0001, "константа совпадает с правилом баланса")


func test_activate_and_deplete_signals_fire_once_per_use() -> void:
	nitro.refill()
	var activations := [0]
	var depletions := [0]
	nitro.activated.connect(func() -> void: activations[0] += 1)
	nitro.depleted.connect(func() -> void: depletions[0] += 1)
	for i in range(int((config.nitro_capacity_s + 0.2) * 60.0)):
		nitro.update(1.0 / 60.0, true)
	assert_eq(activations[0], 1, "сигнал активации один раз за использование")
	assert_eq(depletions[0], 1, "сигнал опустошения один раз")


func test_releasing_the_button_stops_thrust_immediately() -> void:
	nitro.refill()
	nitro.update(1.0 / 60.0, true)
	var thrust := nitro.update(1.0 / 60.0, false)
	assert_almost_eq(thrust, 0.0, 0.001, "без удержания кнопки тяги нет")
	assert_false(nitro.active, "буст выключен")
