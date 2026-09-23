extends TestCase

## MathUtils holds every piece of shared maths; if it breaks, terrain, roads and
## the AI all break in subtle ways, so the properties are checked explicitly.

func test_noise_is_deterministic_and_bounded() -> void:
	var a := MathUtils.value_noise_2d(12.34, -5.67, 20260923)
	var b := MathUtils.value_noise_2d(12.34, -5.67, 20260923)
	assert_almost_eq(a, b, 0.0, "шум должен быть детерминированным для одного seed")
	assert_between(a, 0.0, 1.0, "шум лежит в 0..1")
	var far := MathUtils.value_noise_2d(400.0, 900.0, 20260923)
	assert_ne(snappedf(a, 0.001), snappedf(far, 0.001), "разные точки дают разный шум")


func test_fbm_stays_in_range_for_random_samples() -> void:
	var rng := test_rng(7)
	var minimum := 1.0
	var maximum := 0.0
	for i in range(300):
		var value := MathUtils.fbm_2d(rng.randf_range(-2048.0, 2048.0), rng.randf_range(-2048.0, 2048.0), 4, 20260923)
		minimum = minf(minimum, value)
		maximum = maxf(maximum, value)
	assert_between(minimum, 0.0, 1.0, "fbm не выходит снизу из 0..1")
	assert_between(maximum, 0.0, 1.0, "fbm не выходит сверху из 0..1")
	assert_gt(maximum - minimum, 0.05, "fbm реально меняется от точки к точке")


func test_angle_difference_wraps_correctly() -> void:
	# Same convention as Godot's own angle_difference(): the shortest rotation from
	# `from_angle` to `to_angle`, positive when it has to turn counter-clockwise.
	assert_almost_eq(MathUtils.angle_difference(0.1, TAU - 0.1), -0.2, 0.0001, "переход через 2π")
	assert_almost_eq(MathUtils.angle_difference(PI - 0.1, -PI + 0.1), 0.2, 0.0001, "переход через -π")
	assert_almost_eq(absf(MathUtils.angle_difference(3.0, -3.0)), absf(TAU - 6.0), 0.0001, "короткая дуга")
	for pair in [Vector2(0.0, 0.0), Vector2(0.3, -0.4), Vector2(-2.5, 2.9), Vector2(6.0, 1.0)]:
		assert_almost_eq(
			MathUtils.angle_difference(pair.x, pair.y), angle_difference(pair.x, pair.y), 0.0001,
			"совпадает со встроенной функцией Godot для %s" % str(pair)
		)


func test_polyline_length_and_point_at() -> void:
	var points := PackedVector3Array([Vector3.ZERO, Vector3(10, 0, 0), Vector3(10, 0, 10)])
	var length := MathUtils.polyline_length(points)
	assert_almost_eq(length, 20.0, 0.001, "длина ломаной 10 + 10")
	var middle := MathUtils.polyline_point_at(points, 5.0)
	assert_vector_almost_eq(middle, Vector3(5, 0, 0), 0.001, "точка на половине первого сегмента")
	var after_corner := MathUtils.polyline_point_at(points, 15.0)
	assert_vector_almost_eq(after_corner, Vector3(10, 0, 5), 0.001, "точка после поворота")


func test_polyline_tangent_follows_segments() -> void:
	var points := PackedVector3Array([Vector3.ZERO, Vector3(0, 0, 20), Vector3(20, 0, 20)])
	var tangent := MathUtils.polyline_tangent_at(points, 5.0)
	assert_almost_eq(tangent.z, 1.0, 0.001, "на первом сегменте касательная по +Z")
	var second := MathUtils.polyline_tangent_at(points, 25.0)
	assert_almost_eq(second.x, 1.0, 0.001, "на втором сегменте касательная по +X")


func test_closest_point_on_segment_xz() -> void:
	var found := MathUtils.closest_point_on_segment_xz(Vector3(5, 0, 5), Vector3(0, 0, 0), Vector3(10, 0, 0))
	assert_almost_eq(found.distance_to(Vector3(5, 0, 0)), 0.0, 0.001, "проекция в середину отрезка")
	var clamped := MathUtils.closest_point_on_segment_xz(Vector3(-20, 0, 3), Vector3(0, 0, 0), Vector3(10, 0, 0))
	assert_almost_eq(clamped.distance_to(Vector3(0, 0, 0)), 0.0, 0.001, "проекция за пределами отрезка ограничена")


func test_kmh_conversion() -> void:
	assert_almost_eq(MathUtils.ms_to_kmh(27.7778), 100.0, 0.01, "27.78 м/с = 100 км/ч")
	assert_almost_eq(MathUtils.kmh_to_ms(100.0), 27.7778, 0.001, "обратное преобразование")
	assert_almost_eq(MathUtils.ms_to_kmh(-10.0), 36.0, 0.001, "скорость по модулю (задний ход)")


func test_catmull_rom_hits_endpoints_and_stays_near_control_points() -> void:
	var points := PackedVector3Array([
		Vector3(0, 0, 0), Vector3(10, 4, 0), Vector3(20, 0, 6), Vector3(30, 2, 6),
	])
	var start := MathUtils.catmull_rom(points, 0.0)
	assert_vector_almost_eq(start, points[0], 0.01, "начало кривой = первая точка")
	var finish := MathUtils.catmull_rom(points, 1.0)
	assert_vector_almost_eq(finish, points[points.size() - 1], 0.01, "конец кривой = последняя точка")
	var max_deviation := 0.0
	for i in range(41):
		var t := float(i) / 40.0
		var point := MathUtils.catmull_rom(points, t)
		var nearest := INF
		for control in points:
			nearest = minf(nearest, point.distance_to(control))
		max_deviation = maxf(max_deviation, nearest)
	assert_lt(max_deviation, 9.0, "кривая не улетает далеко от контрольных точек")


func test_damp_moves_towards_target() -> void:
	var value := 0.0
	for i in range(60):
		value = MathUtils.damp(value, 10.0, 6.0, 1.0 / 60.0)
	assert_between(value, 9.0, 10.0, "damp сходится к цели за секунду")


func test_rng_for_is_stable_per_seed() -> void:
	var first := MathUtils.rng_for(Vector2i(5, 6), 123)
	var second := MathUtils.rng_for(Vector2i(5, 6), 123)
	var other := MathUtils.rng_for(Vector2i(5, 7), 123)
	assert_eq(first.randi(), second.randi(), "rng_for детерминирован по координатам чанка")
	assert_ne(first.randi(), other.randi(), "соседний чанк получает другую последовательность")
