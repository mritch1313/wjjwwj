extends TestCase

## Tyre/physics checks.  WheelSystem.compute_tyre_force only needs a load and a
## set of axes, so the model can be exercised without a physics world - which is
## exactly why the code was written that way.

var config: VehicleConfig
var wheel: WheelSystem


func before_all() -> void:
	config = VehicleConfig.new()
	wheel = WheelSystem.new()
	wheel.setup(config, 0, Vector3(-0.79, 0.0, -1.36), config.wheel_radius_m)


func _force(lateral_speed: float, forward_speed: float, load: float, handbrake: float = 0.0) -> Dictionary:
	wheel.load = load
	wheel.on_ground = true
	wheel.handbrake = handbrake
	wheel.angular_velocity = forward_speed / config.wheel_radius_m
	wheel.drive_torque = 0.0
	wheel.brake_torque = 0.0
	wheel.set_surface(Surface.Type.ASPHALT, Config.surfaces.friction_of(Surface.Type.ASPHALT))
	var velocity := Vector3(0.0, 0.0, forward_speed) + Vector3(1.0, 0.0, 0.0) * lateral_speed
	return wheel.compute_tyre_force(velocity, Vector3.FORWARD, Vector3.RIGHT, 1.0 / 60.0, true, true)


func test_zero_slip_gives_no_force() -> void:
	var result := _force(0.0, 0.0, 4000.0)
	assert_almost_eq(absf(float(result["lateral_force"])), 0.0, 1.0, "нет бокового скольжения - нет боковой силы")


func test_lateral_force_grows_with_slip_then_saturates() -> void:
	var f1 := absf(float(_force(0.5, 20.0, 4000.0)["lateral_force"]))
	var f2 := absf(float(_force(2.0, 20.0, 4000.0)["lateral_force"]))
	var f3 := absf(float(_force(25.0, 20.0, 4000.0)["lateral_force"]))
	assert_gt(f2, f1, "сила растёт со скольжением")
	assert_le(f3, f2 * 1.25, "на больших углах сила выходит на плато (Pacejka)")


func test_force_scales_with_wheel_load() -> void:
	var light := absf(float(_force(1.0, 20.0, 2500.0)["lateral_force"]))
	var heavy := absf(float(_force(1.0, 20.0, 5000.0)["lateral_force"]))
	assert_gt(heavy, light, "нагруженное колесо держит больше")
	var ratio := heavy / maxf(light, 0.001)
	assert_lt(ratio, 2.0, "коэффициент меньше отношения нагрузок (load sensitivity)")


func test_friction_ellipse_limits_combined_force() -> void:
	# ask for maximum lateral and maximum longitudinal at once
	wheel.load = 4000.0
	wheel.on_ground = true
	wheel.drive_torque = 3000.0
	wheel.angular_velocity = 90.0
	wheel.set_surface(Surface.Type.ASPHALT, 1.0)
	var result := wheel.compute_tyre_force(Vector3(0, 0, 12), Vector3.FORWARD, Vector3.RIGHT, 1.0 / 60.0, true, false)
	var magnitude := Vector2(float(result["forward_force"]), float(result["lateral_force"])).length()
	var budget := maxf(config.longitudinal_grip, config.lateral_grip) * 4000.0
	assert_lt(magnitude, budget * 1.02, "эллипс трения не превышается")


func test_handbrake_reduces_lateral_grip() -> void:
	var normal := absf(float(_force(3.0, 20.0, 4000.0, 0.0)["lateral_force"]))
	var pulled := absf(float(_force(3.0, 20.0, 4000.0, 1.0)["lateral_force"]))
	assert_lt(pulled, normal, "ручник срывает заднюю ось в занос")


func test_surface_grip_changes_lateral_force() -> void:
	wheel.set_surface(Surface.Type.GRASS, Config.surfaces.friction_of(Surface.Type.GRASS))
	wheel.load = 4000.0
	wheel.on_ground = true
	wheel.handbrake = 0.0
	wheel.angular_velocity = 20.0 / config.wheel_radius_m
	var grass := absf(float(wheel.compute_tyre_force(Vector3(0, 0, 20) + Vector3(2, 0, 0), Vector3.FORWARD, Vector3.RIGHT, 1.0 / 60.0, true, true)["lateral_force"]))
	var asphalt := absf(float(_force(2.0, 20.0, 4000.0)["lateral_force"]))
	assert_lt(grass, asphalt, "на траве сцепление ниже, чем на асфальте")


func test_locked_wheel_loses_force() -> void:
	wheel.load = 3000.0
	wheel.on_ground = true
	wheel.handbrake = 0.0
	wheel.drive_torque = 0.0
	wheel.brake_torque = 4000.0
	wheel.angular_velocity = 60.0
	wheel.set_surface(Surface.Type.ASPHALT, 1.0)
	wheel.compute_tyre_force(Vector3(0, 0, 0.5), Vector3.FORWARD, Vector3.RIGHT, 0.2, true, true)
	wheel.compute_tyre_force(Vector3(0, 0, 0.5), Vector3.FORWARD, Vector3.RIGHT, 0.2, true, true)
	assert_true(wheel.is_locked, "колесо блокируется тормозом на низкой скорости")


func test_engine_torque_curve_shape() -> void:
	var low := VehicleController.engine_torque_at(config.idle_rpm, config, 1.0)
	var mid := VehicleController.engine_torque_at(config.redline_rpm * 0.55, config, 1.0)
	var high := VehicleController.engine_torque_at(config.redline_rpm, config, 1.0)
	assert_gt(mid, low, "момент растёт от холостых к середине")
	assert_gt(mid, high, "к отсечке момент падает")
	assert_almost_eq(VehicleController.engine_torque_at(config.redline_rpm * 0.5, config, 0.0), 0.0, 0.001, "без газа момента нет")


func test_top_speed_estimate_is_plausible() -> void:
	var top := VehicleController.estimate_top_speed_ms(config)
	assert_between(top * 3.6, 120.0, 220.0, "расчётная максималка в разумном коридоре")
	var nitro := NitroSystem.new(config)
	assert_lt(top, nitro.top_speed_with_boost_ms(), "нитро поднимает максималку")


func test_drag_grows_quadratically() -> void:
	var slow := VehicleController.drag_force_at(10.0, config)
	var fast := VehicleController.drag_force_at(40.0, config)
	assert_almost_eq(fast / maxf(slow, 0.0001), 16.0, 2.0, "сопротивление растёт как v^2")
