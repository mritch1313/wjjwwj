class_name MathUtils
extends RefCounted

## Pure math helpers shared by terrain generation, road building, vehicle
## physics, camera and police AI.  Nothing in here touches the scene tree, so
## every function is unit-testable in a headless Godot run
## (see tests/unit/test_math_utils.gd).


static func wrap_angle(a: float) -> float:
	return fposmod(a + PI, TAU) - PI


static func angle_difference(from_angle: float, to_angle: float) -> float:
	return wrap_angle(to_angle - from_angle)


## Frame-rate independent exponential smoothing.
static func damp(current: float, target: float, smoothing: float, delta: float) -> float:
	if smoothing <= 0.0:
		return target
	return lerpf(current, target, 1.0 - exp(-smoothing * delta))


static func damp_vector(current: Vector3, target: Vector3, smoothing: float, delta: float) -> Vector3:
	if smoothing <= 0.0:
		return target
	return current.lerp(target, 1.0 - exp(-smoothing * delta))


## Samples an evenly spaced lookup table (torque curves, friction curves...).
## x is normalised to [0, 1] across the table.
static func curve_lookup(table: PackedFloat32Array, x: float) -> float:
	if table.is_empty():
		return 0.0
	if table.size() == 1:
		return table[0]
	var t := clampf(x, 0.0, 1.0) * float(table.size() - 1)
	var index := int(floor(t))
	var frac := t - float(index)
	if index >= table.size() - 1:
		return table[table.size() - 1]
	return lerpf(table[index], table[index + 1], frac)


static func _catmull(p0: Vector3, p1: Vector3, p2: Vector3, p3: Vector3, t: float) -> Vector3:
	var t2 := t * t
	var t3 := t2 * t
	return 0.5 * (
		(2.0 * p1)
		+ (-p0 + p2) * t
		+ (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
		+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3
	)


## Smooth spline through the given control points, t in [0, 1] over the whole
## polyline.  Used for road centre lines and AI paths.
static func catmull_rom(points: PackedVector3Array, t: float) -> Vector3:
	var count := points.size()
	if count == 0:
		return Vector3.ZERO
	if count == 1:
		return points[0]
	var segment_count := count - 1
	var scaled := clampf(t, 0.0, 1.0) * float(segment_count)
	var index := int(floor(scaled))
	var frac := scaled - float(index)
	if index >= segment_count:
		index = segment_count - 1
		frac = 1.0
	var p0 := points[maxi(index - 1, 0)]
	var p1 := points[index]
	var p2 := points[mini(index + 1, count - 1)]
	var p3 := points[mini(index + 2, count - 1)]
	return _catmull(p0, p1, p2, p3, frac)


static func polyline_length(points: PackedVector3Array) -> float:
	var total := 0.0
	for i in range(1, points.size()):
		total += points[i - 1].distance_to(points[i])
	return total


## Returns a point located `distance` metres along the polyline.
static func polyline_point_at(points: PackedVector3Array, distance: float) -> Vector3:
	if points.is_empty():
		return Vector3.ZERO
	if points.size() == 1 or distance <= 0.0:
		return points[0]
	var travelled := 0.0
	for i in range(1, points.size()):
		var segment := points[i - 1].distance_to(points[i])
		if travelled + segment >= distance:
			var f := 0.0 if segment <= 0.0001 else (distance - travelled) / segment
			return points[i - 1].lerp(points[i], clampf(f, 0.0, 1.0))
		travelled += segment
	return points[points.size() - 1]


static func polyline_tangent_at(points: PackedVector3Array, distance: float) -> Vector3:
	if points.size() < 2:
		return Vector3.FORWARD
	var travelled := 0.0
	for i in range(1, points.size()):
		var segment_vec := points[i] - points[i - 1]
		var segment := segment_vec.length()
		if travelled + segment >= distance:
			if segment <= 0.0001:
				return Vector3.FORWARD
			return segment_vec / segment
		travelled += segment
	var last := points[points.size() - 1] - points[points.size() - 2]
	return last.normalized() if last.length() > 0.0001 else Vector3.FORWARD


static func xz(v: Vector3) -> Vector2:
	return Vector2(v.x, v.z)


static func from_xz(v: Vector2, y: float = 0.0) -> Vector3:
	return Vector3(v.x, y, v.y)


static func closest_point_on_segment_xz(point: Vector3, a: Vector3, b: Vector3) -> Vector3:
	var ab := b - a
	var denominator := ab.x * ab.x + ab.z * ab.z
	if denominator <= 0.0001:
		return a
	var t := clampf(((point.x - a.x) * ab.x + (point.z - a.z) * ab.z) / denominator, 0.0, 1.0)
	return Vector3(a.x + ab.x * t, a.y + ab.y * t, a.z + ab.z * t)


static func distance_to_segment_xz(point: Vector3, a: Vector3, b: Vector3) -> float:
	var closest := closest_point_on_segment_xz(point, a, b)
	return Vector2(point.x - closest.x, point.z - closest.z).length()


## Deterministic hash based random generator for a world cell.
static func rng_for(cell: Vector2i, salt: int) -> RandomNumberGenerator:
	var rng := RandomNumberGenerator.new()
	rng.seed = hash(Vector3i(cell.x, cell.y, salt))
	return rng


static func hash01(a: int, b: int, salt: int = 0) -> float:
	var h := hash(Vector3i(a, b, salt))
	return float(h & 0xFFFFFF) / float(0x1000000)


## Cheap deterministic value noise in [0, 1] (bilinear interpolation of hashed
## lattice values).  Used for surface detail and scatter jitter.
static func value_noise_2d(x: float, z: float, salt: int = 0) -> float:
	var x0 := floori(x)
	var z0 := floori(z)
	var fx := x - float(x0)
	var fz := z - float(z0)
	var sx := fx * fx * (3.0 - 2.0 * fx)
	var sz := fz * fz * (3.0 - 2.0 * fz)
	var n00 := hash01(x0, z0, salt)
	var n10 := hash01(x0 + 1, z0, salt)
	var n01 := hash01(x0, z0 + 1, salt)
	var n11 := hash01(x0 + 1, z0 + 1, salt)
	return lerpf(lerpf(n00, n10, sx), lerpf(n01, n11, sx), sz)


static func fbm_2d(x: float, z: float, octaves: int, salt: int = 0) -> float:
	var total := 0.0
	var amplitude := 0.5
	var frequency := 1.0
	var norm := 0.0
	for i in range(octaves):
		total += value_noise_2d(x * frequency, z * frequency, salt + i * 17) * amplitude
		norm += amplitude
		amplitude *= 0.5
		frequency *= 2.0
	return 0.0 if norm <= 0.0 else total / norm


static func ms_to_kmh(speed_ms: float) -> float:
	return absf(speed_ms) * 3.6


static func kmh_to_ms(speed_kmh: float) -> float:
	return speed_kmh / 3.6
