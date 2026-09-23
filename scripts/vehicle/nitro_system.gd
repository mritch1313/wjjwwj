class_name NitroSystem
extends RefCounted

## Nitro is physical thrust and nothing else: the boost adds force at the driven
## wheels and raises the speed cap by `nitro_speed_factor`, it never teleports or
## scales the position.  Charge, depletion and the "empty tank" cooldown make it
## a resource the player has to time.

signal activated()
signal depleted()
signal charge_changed(ratio: float)

## How much nitro raises the car's own speed cap.  The brief measures the boost
## against the *police* top speed (1.25x), so relative to the player's own cap it
## is police_factor * 1.25 = 1.2625 - the same number PursuitBalance reports.
const SPEED_FACTOR := 1.2625

var config: VehicleConfig
var charge_s: float = 0.0
var active: bool = false
var cooldown_s: float = 0.0
var inactive_time_s: float = 0.0
var total_used_s: float = 0.0
var boosts_used: int = 0
var speed_cap_ms: float = 0.0


func _init(vehicle_config: VehicleConfig) -> void:
	config = vehicle_config
	charge_s = vehicle_config.nitro_capacity_s
	speed_cap_ms = vehicle_config.top_speed_ms()


func capacity() -> float:
	return maxf(config.nitro_capacity_s, 0.001)


func charge_ratio() -> float:
	return clampf(charge_s / capacity(), 0.0, 1.0)


func can_activate() -> bool:
	if config.nitro_capacity_s <= 0.0 or config.nitro_thrust_n <= 0.0:
		return false
	return charge_s > 0.0 and cooldown_s <= 0.0


## delta in seconds; returns the thrust to apply this frame (N).
func update(delta: float, wanted: bool) -> float:
	var thrust := 0.0
	if active and not wanted:
		# the button was released: the thrust must stop on this very frame
		active = false
		cooldown_s = 0.0
		charge_changed.emit(charge_ratio())
	if active:
		charge_s = maxf(charge_s - delta, 0.0)
		total_used_s += delta
		thrust = config.nitro_thrust_n
		if charge_s <= 0.0:
			active = false
			depleted.emit()
			cooldown_s = config.nitro_cooldown_s
		charge_changed.emit(charge_ratio())
	elif wanted and can_activate():
		active = true
		boosts_used += 1
		activated.emit()
		thrust = config.nitro_thrust_n
		charge_s = maxf(charge_s - delta, 0.0)
		total_used_s += delta
		charge_changed.emit(charge_ratio())
	else:
		# recharge: fast when idle, slow while the car is moving (drag on the tank)
		if cooldown_s > 0.0:
			cooldown_s = maxf(cooldown_s - delta, 0.0)
		inactive_time_s += delta
		var rate := capacity() / maxf(config.nitro_recharge_s, 0.001)
		var previous := charge_s
		charge_s = minf(charge_s + rate * delta, capacity())
		if not is_equal_approx(previous, charge_s):
			charge_changed.emit(charge_ratio())
	return thrust


func refill() -> void:
	charge_s = capacity()
	active = false
	cooldown_s = 0.0
	inactive_time_s = 0.0
	charge_changed.emit(charge_ratio())


## Maximum speed the car may reach while the boost is active.
func top_speed_with_boost_ms() -> float:
	return maxf(speed_cap_ms * SPEED_FACTOR, speed_cap_ms)


func status() -> Dictionary:
	return {
		"active": active,
		"charge": charge_ratio(),
		"cooldown": cooldown_s,
		"used_s": total_used_s,
		"boosts": boosts_used,
	}
