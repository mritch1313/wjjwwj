class_name VehicleInput
extends RefCounted

## Input state of one car (player or AI).  Keeping it in a tiny value object
## means the same controller code runs a human-driven and an AI-driven car, and
## the AI can be unit tested by feeding inputs.

var throttle: float = 0.0     ## 0..1
var brake: float = 0.0        ## 0..1 (also engages reverse when stopped)
var steer: float = -1.0       ## -1 (left) .. 1 (right)
var handbrake: float = 0.0    ## 0..1
var nitro: bool = false
var gear_hint: int = 0        ## -1 = reverse, 0 = automatic, 1..n = force gear
var use_abs: bool = true
var use_tcs: bool = true


func reset() -> void:
	throttle = 0.0
	brake = 0.0
	steer = 0.0
	handbrake = 0.0
	nitro = false
	gear_hint = 0


func copy_from(other: VehicleInput) -> void:
	if other == null:
		return
	throttle = other.throttle
	brake = other.brake
	steer = other.steer
	handbrake = other.handbrake
	nitro = other.nitro
	gear_hint = other.gear_hint
	use_abs = other.use_abs
	use_tcs = other.use_tcs


func clamped() -> VehicleInput:
	var result := VehicleInput.new()
	result.throttle = clampf(throttle, 0.0, 1.0)
	result.brake = clampf(brake, 0.0, 1.0)
	result.steer = clampf(steer, -1.0, 1.0)
	result.handbrake = clampf(handbrake, 0.0, 1.0)
	result.nitro = nitro
	result.gear_hint = gear_hint
	result.use_abs = use_abs
	result.use_tcs = use_tcs
	return result


func to_dictionary() -> Dictionary:
	return {
		"throttle": snappedf(throttle, 0.01),
		"brake": snappedf(brake, 0.01),
		"steer": snappedf(steer, 0.01),
		"handbrake": snappedf(handbrake, 0.01),
		"nitro": nitro,
		"gear_hint": gear_hint,
	}
