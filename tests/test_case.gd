class_name TestCase
extends RefCounted

## Minimal assertion helper for the head-less test runner.
##
## The brief explicitly forbids "assert true" style tests, so every test method
## checks a concrete, computed property of the game code (a balance rule, a
## route, a physics quantity) and the runner prints the measured values.

var failures: PackedStringArray = PackedStringArray()
var checks: int = 0
var current_test: String = ""


func before_all() -> void:
	pass


func after_all() -> void:
	pass


## Optional per-test hooks.  The runner calls them around every `test_*` method,
## which keeps tests that touch the autoload singletons independent of each other
## (test methods run in alphabetical order, so shared state would leak otherwise).
func before_each() -> void:
	pass


func after_each() -> void:
	pass


func fail(message: String) -> void:
	failures.append("%s: %s" % [current_test, message])


func check(condition: bool, message: String) -> bool:
	checks += 1
	if not condition:
		fail(message)
		return false
	return true


func assert_true(condition: bool, message: String = "expected true") -> bool:
	return check(condition, message)


func assert_false(condition: bool, message: String = "expected false") -> bool:
	return check(not condition, message)


func assert_eq(actual: Variant, expected: Variant, message: String = "") -> bool:
	var ok: bool = actual == expected
	if not ok:
		return check(false, "%s (получено %s, ожидалось %s)" % [message, str(actual), str(expected)])
	return check(true, message)


func assert_ne(actual: Variant, unexpected: Variant, message: String = "") -> bool:
	var ok: bool = actual != unexpected
	if not ok:
		return check(false, "%s (значение %s не должно было совпасть)" % [message, str(actual)])
	return check(true, message)


func assert_almost_eq(actual: float, expected: float, tolerance: float, message: String = "") -> bool:
	var ok: bool = absf(actual - expected) <= tolerance
	if not ok:
		return check(false, "%s (получено %.5f, ожидалось %.5f ±%.5f)" % [message, actual, expected, tolerance])
	return check(true, message)


func assert_gt(actual: float, threshold: float, message: String = "") -> bool:
	if not actual > threshold:
		return check(false, "%s (%.5f не больше %.5f)" % [message, actual, threshold])
	return check(true, message)


func assert_ge(actual: float, threshold: float, message: String = "") -> bool:
	if not actual >= threshold:
		return check(false, "%s (%.5f меньше %.5f)" % [message, actual, threshold])
	return check(true, message)


func assert_lt(actual: float, threshold: float, message: String = "") -> bool:
	if not actual < threshold:
		return check(false, "%s (%.5f не меньше %.5f)" % [message, actual, threshold])
	return check(true, message)


func assert_le(actual: float, threshold: float, message: String = "") -> bool:
	if not actual <= threshold:
		return check(false, "%s (%.5f больше %.5f)" % [message, actual, threshold])
	return check(true, message)


func assert_between(actual: float, low: float, high: float, message: String = "") -> bool:
	if actual < low or actual > high:
		return check(false, "%s (%.5f вне диапазона %.3f..%.3f)" % [message, actual, low, high])
	return check(true, message)


func assert_vector_almost_eq(actual: Vector3, expected: Vector3, tolerance: float, message: String = "") -> bool:
	var ok: bool = actual.distance_to(expected) <= tolerance
	if not ok:
		return check(false, "%s (получено %s, ожидалось %s)" % [message, str(actual), str(expected)])
	return check(true, message)


## Deterministic RNG for tests that need randomness.
func test_rng(seed_value: int = 1234) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = seed_value
	return rng
