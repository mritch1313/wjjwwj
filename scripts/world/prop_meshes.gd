class_name PropMeshes
extends RefCounted

## Library of procedural prop / vegetation meshes.
##
## Every function writes geometry into a shared MeshBuilder (so a whole chunk
## becomes a few surfaces) and returns the collision shapes that belong to the
## prop.  Collision dictionaries look like:
##     {"shape": "box", "transform": Transform3D, "size": Vector3}
##     {"shape": "cylinder", "transform": Transform3D, "radius": float, "height": float}
##
## Materials are referenced by name through Assets.material(), which keeps art
## and gameplay separated: exchanging a texture or a shape never requires a
## change in WorldGenerator / ChunkContent.

static func _t(position: Vector3, yaw: float = 0.0, scale: float = 1.0) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(scale, scale, scale)), position)


## ------------------------------------------------------------------ street --
static func street_lamp(builder: MeshBuilder, base: Transform3D, height: float, rng: RandomNumberGenerator) -> Array:
	var colliders := []
	var pole_height := height
	# foundation + pole with a slight taper
	builder.add_box("concrete", base * _t(Vector3(0.0, 0.1, 0.0)), Vector3(0.62, 0.2, 0.62), Color(0.9, 0.9, 0.9))
	builder.add_cylinder("metal_grey", base * _t(Vector3(0.0, pole_height * 0.5, 0.0)), 0.09, 0.07, pole_height, 8, Color(0.86, 0.88, 0.9))
	# arm + head
	var arm_direction := -1.0 if rng.randf() < 0.5 else 1.0
	var arm_length := 1.9 + rng.randf() * 0.7
	builder.add_box(
		"metal_grey",
		base * _t(Vector3(arm_direction * arm_length * 0.5, pole_height - 0.12, 0.0)),
		Vector3(arm_length, 0.11, 0.11), Color(0.82, 0.84, 0.86)
	)
	builder.add_box(
		"metal_grey",
		base * _t(Vector3(arm_direction * arm_length, pole_height - 0.22, 0.0), 0.0, 1.0),
		Vector3(0.5, 0.14, 0.26), Color(0.7, 0.72, 0.74)
	)
	builder.add_box(
		"lamp_glass_off",
		base * _t(Vector3(arm_direction * arm_length, pole_height - 0.31, 0.0)),
		Vector3(0.44, 0.06, 0.2), Color(1.0, 0.98, 0.9)
	)
	colliders.append({
		"shape": "cylinder", "transform": base * _t(Vector3(0.0, pole_height * 0.5, 0.0)),
		"radius": 0.16, "height": pole_height,
	})
	return colliders


static func traffic_light(builder: MeshBuilder, base: Transform3D, rng: RandomNumberGenerator) -> Array:
	var pole_height := 5.6
	builder.add_box("concrete", base * _t(Vector3(0.0, 0.12, 0.0)), Vector3(0.8, 0.24, 0.8))
	builder.add_cylinder("metal_dark", base * _t(Vector3(0.0, pole_height * 0.5, 0.0)), 0.11, 0.09, pole_height, 8, Color(0.9, 0.9, 0.92))
	var reach := 3.4
	builder.add_box("metal_dark", base * _t(Vector3(reach * 0.5, pole_height - 0.2, 0.0)), Vector3(reach, 0.14, 0.14))
	var head_transform := base * _t(Vector3(reach, pole_height - 0.85, 0.0))
	builder.add_box("metal_dark", head_transform, Vector3(0.42, 1.15, 0.4))
	var lamps := [["traffic_light_red", 0.36], ["traffic_light_off", 0.0], ["traffic_light_green", -0.36]]
	for lamp in lamps:
		builder.add_cylinder(
			String(lamp[0]),
			head_transform * _t(Vector3(0.0, float(lamp[1]), -0.21), 0.0, 1.0) * Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3.ZERO),
			0.13, 0.13, 0.08, 10, Color.WHITE
		)
	return [{
		"shape": "cylinder", "transform": base * _t(Vector3(0.0, pole_height * 0.5, 0.0)),
		"radius": 0.2, "height": pole_height,
	}]


static func sign_post(builder: MeshBuilder, base: Transform3D, sign_index: int, height: float, rng: RandomNumberGenerator, double_sided: bool = false) -> Array:
	builder.add_cylinder("metal_grey", base * _t(Vector3(0.0, height * 0.5, 0.0)), 0.055, 0.05, height, 6, Color(0.85, 0.87, 0.9))
	var cell := Vector2(float(sign_index % 4), float(sign_index / 4)) * 0.25
	var size := 0.72
	builder.add_billboard(
		"sign_face",
		base * _t(Vector3(0.0, height - size * 0.5, 0.0)),
		Vector2(size, size),
		Color(1, 1, 1),
		double_sided,
		cell,
		Vector2(0.25, 0.25)
	)
	return [{
		"shape": "cylinder", "transform": base * _t(Vector3(0.0, height * 0.5, 0.0)),
		"radius": 0.1, "height": height,
	}]


static func bench(builder: MeshBuilder, base: Transform3D, rng: RandomNumberGenerator) -> Array:
	var wood := "wood_planks"
	var metal := "metal_dark"
	for i in range(3):
		builder.add_box(wood, base * _t(Vector3(0.0, 0.46, -0.12 + float(i) * 0.12)), Vector3(1.8, 0.05, 0.11), Color(0.95, 0.95, 0.95))
	for i in range(2):
		builder.add_box(wood, base * _t(Vector3(0.0, 0.62 + float(i) * 0.14, 0.24), 0.0, 1.0), Vector3(1.8, 0.05, 0.11), Color(0.95, 0.95, 0.95))
	builder.add_box(metal, base * _t(Vector3(-0.75, 0.23, 0.0)), Vector3(0.08, 0.46, 0.6), Color(0.9, 0.9, 0.9))
	builder.add_box(metal, base * _t(Vector3(0.75, 0.23, 0.0)), Vector3(0.08, 0.46, 0.6), Color(0.9, 0.9, 0.9))
	return [{"shape": "box", "transform": base * _t(Vector3(0.0, 0.4, 0.05)), "size": Vector3(1.85, 0.85, 0.75)}]


static func trash_bin(builder: MeshBuilder, base: Transform3D, rng: RandomNumberGenerator) -> Array:
	var color := Color(0.75, 0.78, 0.8)
	builder.add_cylinder("metal_grey", base * _t(Vector3(0.0, 0.44, 0.0)), 0.3, 0.28, 0.88, 10, color)
	builder.add_cylinder("metal_dark", base * _t(Vector3(0.0, 0.9, 0.0)), 0.32, 0.32, 0.08, 10, color)
	return [{"shape": "cylinder", "transform": base * _t(Vector3(0.0, 0.45, 0.0)), "radius": 0.32, "height": 0.9}]


static func hydrant(builder: MeshBuilder, base: Transform3D, rng: RandomNumberGenerator) -> Array:
	builder.add_cylinder("metal_painted_red", base * _t(Vector3(0.0, 0.35, 0.0)), 0.14, 0.12, 0.7, 8)
	builder.add_cylinder("metal_painted_red", base * _t(Vector3(0.0, 0.72, 0.0)), 0.18, 0.16, 0.12, 8)
	builder.add_box("metal_painted_red", base * _t(Vector3(0.0, 0.5, 0.0)), Vector3(0.42, 0.12, 0.14))
	return [{"shape": "cylinder", "transform": base * _t(Vector3(0.0, 0.4, 0.0)), "radius": 0.2, "height": 0.8}]


static func mailbox(builder: MeshBuilder, base: Transform3D, rng: RandomNumberGenerator) -> Array:
	builder.add_box("metal_grey", base * _t(Vector3(0.0, 0.55, 0.0)), Vector3(0.42, 0.34, 0.3), Color(0.5, 0.6, 0.75))
	builder.add_cylinder("metal_grey", base * _t(Vector3(0.0, 0.19, 0.0)), 0.05, 0.05, 0.38, 6)
	return []


static func bollard(builder: MeshBuilder, base: Transform3D, rng: RandomNumberGenerator) -> Array:
	builder.add_cylinder("metal_grey", base * _t(Vector3(0.0, 0.45, 0.0)), 0.09, 0.08, 0.9, 8)
	builder.add_cylinder("marking_white", base * _t(Vector3(0.0, 0.72, 0.0)), 0.095, 0.095, 0.12, 8)
	return [{"shape": "cylinder", "transform": base * _t(Vector3(0.0, 0.45, 0.0)), "radius": 0.14, "height": 0.9}]


static func traffic_cone(builder: MeshBuilder, base: Transform3D, rng: RandomNumberGenerator) -> Array:
	builder.add_box("plastic_orange", base * _t(Vector3(0.0, 0.02, 0.0)), Vector3(0.4, 0.05, 0.4))
	builder.add_cylinder("plastic_orange", base * _t(Vector3(0.0, 0.25, 0.0)), 0.17, 0.03, 0.5, 8, Color.WHITE)
	builder.add_cylinder("marking_white", base * _t(Vector3(0.0, 0.3, 0.0)), 0.12, 0.1, 0.1, 8, Color.WHITE)
	return []


static func jersey_barrier(builder: MeshBuilder, base: Transform3D, length: float, rng: RandomNumberGenerator) -> Array:
	builder.add_box("concrete", base * _t(Vector3(0.0, 0.42, 0.0)), Vector3(length, 0.84, 0.52), Color(0.94, 0.94, 0.92))
	builder.add_box("concrete", base * _t(Vector3(0.0, 0.9, 0.0)), Vector3(length, 0.12, 0.28), Color(1.0, 1.0, 0.98))
	return [{"shape": "box", "transform": base * _t(Vector3(0.0, 0.5, 0.0)), "size": Vector3(length, 1.0, 0.55)}]


static func guardrail(builder: MeshBuilder, from: Vector3, direction: Vector3, length: float, rng: RandomNumberGenerator) -> void:
	var yaw := atan2(direction.x, direction.z)
	var base := Transform3D(Basis(Vector3.UP, yaw), from)
	builder.add_box("metal_grey", base * _t(Vector3(0.0, 0.62, length * 0.5)), Vector3(0.1, 0.34, length), Color(0.88, 0.9, 0.92))
	builder.add_box("metal_grey", base * _t(Vector3(0.0, 0.3, length * 0.5)), Vector3(0.08, 0.32, length), Color(0.8, 0.82, 0.84))
	var posts := int(maxf(length / 4.0, 1.0))
	for i in range(posts + 1):
		var offset := length * float(i) / float(posts)
		builder.add_box("metal_dark", base * _t(Vector3(0.0, 0.35, offset)), Vector3(0.12, 0.7, 0.12), Color(0.85, 0.85, 0.88))


static func fence_line(
	builder: MeshBuilder,
	from: Vector3,
	direction: Vector3,
	length: float,
	material: String,
	height: float,
	segment_length: float = 2.4
) -> void:
	var yaw := atan2(direction.x, direction.z)
	var base := Transform3D(Basis(Vector3.UP, yaw), from)
	var count := maxi(int(round(length / segment_length)), 1)
	var actual := length / float(count)
	for i in range(count):
		var offset := (float(i) + 0.5) * actual
		builder.add_foliage_planes(
			material,
			base * _t(Vector3(0.0, 0.0, offset)),
			Vector2(actual, height),
			1,
			Color(0.95, 0.95, 0.95),
			Vector2.ZERO,
			Vector2(1, 1)
		)


## ----------------------------------------------------------- big city props --
static func bus_shelter(builder: MeshBuilder, base: Transform3D, rng: RandomNumberGenerator) -> Array:
	var w := 3.6
	var d := 1.5
	builder.add_box("concrete", base * _t(Vector3(0.0, 0.06, 0.0)), Vector3(w + 0.6, 0.12, d + 0.6))
	for i in range(4):
		var x := -w * 0.5 + float(i) * (w / 3.0)
		builder.add_box("metal_grey", base * _t(Vector3(x, 1.3, -d * 0.5)), Vector3(0.1, 2.5, 0.1), Color(0.9, 0.9, 0.92))
	builder.add_box("metal_grey", base * _t(Vector3(0.0, 2.62, 0.0)), Vector3(w + 0.3, 0.12, d + 0.2), Color(0.8, 0.82, 0.84))
	builder.add_box("car_glass", base * _t(Vector3(0.0, 1.45, -d * 0.5 + 0.06)), Vector3(w, 2.1, 0.06), Color(0.8, 0.85, 0.9))
	builder.add_box("wood_planks", base * _t(Vector3(0.0, 0.48, 0.35)), Vector3(w * 0.85, 0.09, 0.45), Color(0.95, 0.95, 0.95))
	builder.add_billboard("billboard_ad_a", base * _t(Vector3(0.0, 1.9, -d * 0.5 - 0.05)), Vector2(w * 0.8, 1.2), Color(1, 1, 1), true)
	return [
		{"shape": "box", "transform": base * _t(Vector3(0.0, 1.3, -d * 0.5)), "size": Vector3(w, 2.6, 0.15)},
		{"shape": "box", "transform": base * _t(Vector3(0.0, 1.3, 0.3)), "size": Vector3(w * 0.9, 0.5, 0.4)},
	]


static func container(builder: MeshBuilder, base: Transform3D, yaw: float, rng: RandomNumberGenerator) -> Array:
	var length := 6.06
	var width := 2.44
	var height := 2.59
	var color := Color(0.9 + rng.randf() * 0.1, 0.85 + rng.randf() * 0.15, 0.9 + rng.randf() * 0.1)
	var body := base * _t(Vector3.ZERO, yaw, 1.0)
	builder.add_box("container_side", body * _t(Vector3(0.0, height * 0.5, 0.0)), Vector3(width, height, length), color)
	builder.add_box("metal_corrugated", body * _t(Vector3(0.0, height + 0.04, 0.0)), Vector3(width, 0.08, length), color * 0.9)
	return [{
		"shape": "box", "transform": body * _t(Vector3(0.0, height * 0.5, 0.0)),
		"size": Vector3(width, height, length),
	}]


static func dumpster(builder: MeshBuilder, base: Transform3D, yaw: float, rng: RandomNumberGenerator) -> Array:
	var body := base * _t(Vector3.ZERO, yaw, 1.0)
	builder.add_box("dumpster", body * _t(Vector3(0.0, 0.62, 0.0)), Vector3(1.5, 1.1, 2.9), Color(0.85 + rng.randf() * 0.3, 0.9, 0.9))
	builder.add_box("dumpster", body * _t(Vector3(0.0, 1.22, -0.05)), Vector3(1.55, 0.12, 2.7), Color(0.8, 0.85, 0.85))
	for sx in [-0.6, 0.6]:
		for sz in [-1.2, 1.2]:
			builder.add_cylinder("rubber_black", body * _t(Vector3(sx, 0.08, sz), 0.0, 1.0) * Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3.ZERO), 0.09, 0.09, 0.08, 6, Color.WHITE)
	return [{"shape": "box", "transform": body * _t(Vector3(0.0, 0.62, 0.0)), "size": Vector3(1.6, 1.3, 3.0)}]


static func crate(builder: MeshBuilder, base: Transform3D, yaw: float, size: float, rng: RandomNumberGenerator) -> Array:
	var body := base * _t(Vector3.ZERO, yaw, 1.0)
	builder.add_box("crate_wood", body * _t(Vector3(0.0, size * 0.5, 0.0)), Vector3(size, size, size), Color(0.9 + rng.randf() * 0.2, 0.9, 0.9))
	return [{"shape": "box", "transform": body * _t(Vector3(0.0, size * 0.5, 0.0)), "size": Vector3(size, size, size)}]


static func pallet(builder: MeshBuilder, base: Transform3D, yaw: float, rng: RandomNumberGenerator) -> Array:
	var body := base * _t(Vector3.ZERO, yaw, 1.0)
	for i in range(4):
		builder.add_box("wood_planks", body * _t(Vector3(0.0, 0.14, -0.45 + float(i) * 0.3)), Vector3(1.15, 0.05, 0.16), Color(0.9, 0.9, 0.9))
	builder.add_box("wood_planks", body * _t(Vector3(0.0, 0.05, 0.0)), Vector3(1.15, 0.1, 1.1), Color(0.8, 0.8, 0.8))
	return [{"shape": "box", "transform": body * _t(Vector3(0.0, 0.14, 0.0)), "size": Vector3(1.2, 0.3, 1.2)}]


static func power_pole(builder: MeshBuilder, base: Transform3D, height: float, rng: RandomNumberGenerator) -> Array:
	builder.add_cylinder("wood_dark", base * _t(Vector3(0.0, height * 0.5, 0.0)), 0.19, 0.14, height, 7, Color(0.9, 0.9, 0.9))
	var cross_length := 2.2
	for i in range(2):
		var y := height - 0.6 - float(i) * 0.85
		builder.add_box("wood_dark", base * _t(Vector3(0.0, y, 0.0)), Vector3(cross_length, 0.12, 0.14), Color(0.85, 0.85, 0.85))
		for sx in [-1.0, 1.0]:
			builder.add_cylinder(
				"lamp_glass_off",
				base * _t(Vector3(sx * cross_length * 0.45, y + 0.18, 0.0)),
				0.07, 0.07, 0.16, 6, Color(0.85, 0.9, 0.95)
			)
	return [{"shape": "cylinder", "transform": base * _t(Vector3(0.0, height * 0.5, 0.0)), "radius": 0.25, "height": height}]


static func water_tower(builder: MeshBuilder, base: Transform3D, rng: RandomNumberGenerator) -> Array:
	var leg_height := 14.0
	var radius := 3.4
	for i in range(4):
		var angle := TAU * float(i) / 4.0 + PI * 0.25
		var offset := Vector3(cos(angle), 0.0, sin(angle)) * (radius * 0.72)
		builder.add_cylinder("metal_grey", base * _t(offset * 0.5 + Vector3(0.0, leg_height * 0.5, 0.0)), 0.22, 0.16, leg_height, 6)
	builder.add_cylinder("metal_grey", base * _t(Vector3(0.0, leg_height + radius * 0.9, 0.0)), radius, radius, radius * 1.8, 12, Color(0.9, 0.92, 0.94))
	builder.add_cylinder("metal_corrugated", base * _t(Vector3(0.0, leg_height + radius * 1.85, 0.0)), radius * 0.35, 0.1, 1.4, 8, Color(0.9, 0.9, 0.9))
	builder.add_billboard("shop_sign_b", base * _t(Vector3(0.0, leg_height + radius * 0.9, radius + 0.05)), Vector2(3.4, 1.6), Color(1, 1, 1))
	return [
		{"shape": "box", "transform": base * _t(Vector3(0.0, leg_height * 0.5, 0.0)), "size": Vector3(radius * 1.1, leg_height, radius * 1.1)},
	]


static func radio_mast(builder: MeshBuilder, base: Transform3D, height: float, rng: RandomNumberGenerator) -> Array:
	builder.add_box("concrete", base * _t(Vector3(0.0, 0.3, 0.0)), Vector3(4.0, 0.6, 4.0), Color(0.92, 0.92, 0.9))
	var legs := 0.85
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			builder.add_cylinder(
				"metal_grey",
				base * _t(Vector3(sx * legs, height * 0.5, sz * legs)),
				0.14, 0.07, height, 6, Color(0.9, 0.9, 0.92)
			)
	var levels := 7
	for i in range(levels):
		var y := height * (0.14 + 0.12 * float(i))
		var spread := legs * (1.0 - 0.1 * float(i))
		builder.add_box("metal_grey", base * _t(Vector3(0.0, y, -spread)), Vector3(spread * 2.0, 0.1, 0.1), Color(0.85, 0.85, 0.9))
		builder.add_box("metal_grey", base * _t(Vector3(0.0, y, spread)), Vector3(spread * 2.0, 0.1, 0.1), Color(0.85, 0.85, 0.9))
		builder.add_box("metal_grey", base * _t(Vector3(-spread, y, 0.0)), Vector3(0.1, 0.1, spread * 2.0), Color(0.85, 0.85, 0.9))
		builder.add_box("metal_grey", base * _t(Vector3(spread, y, 0.0)), Vector3(0.1, 0.1, spread * 2.0), Color(0.85, 0.85, 0.9))
	# dishes / antennas
	for i in range(3):
		var angle := TAU * float(i) / 3.0
		builder.add_cylinder(
			"metal_grey",
			base * _t(Vector3(cos(angle) * 0.7, height * 0.72 + float(i) * 1.7, sin(angle) * 0.7), 0.0, 1.0)
				* Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3.ZERO),
			1.0, 1.0, 0.2, 10, Color(0.92, 0.93, 0.95)
		)
	builder.add_cylinder("lamp_glass", base * _t(Vector3(0.0, height + 0.6, 0.0)), 0.14, 0.1, 1.2, 6, Color(1.0, 0.35, 0.3))
	return [{"shape": "box", "transform": base * _t(Vector3(0.0, height * 0.4, 0.0)), "size": Vector3(2.0, height * 0.8, 2.0)}]


static func fuel_station(builder: MeshBuilder, base: Transform3D, yaw: float, rng: RandomNumberGenerator) -> Array:
	var colliders := []
	var root := base * _t(Vector3.ZERO, yaw, 1.0)
	# canopy
	var canopy_w := 13.0
	var canopy_d := 9.0
	var canopy_h := 5.4
	for sx in [-1.0, 1.0]:
		for sz in [-1.0, 1.0]:
			builder.add_cylinder(
				"metal_grey",
				root * _t(Vector3(sx * (canopy_w * 0.35), canopy_h * 0.5, sz * (canopy_d * 0.32))),
				0.22, 0.2, canopy_h, 8, Color(0.9, 0.9, 0.92)
			)
			colliders.append({
				"shape": "cylinder",
				"transform": root * _t(Vector3(sx * (canopy_w * 0.35), canopy_h * 0.5, sz * (canopy_d * 0.32))),
				"radius": 0.3, "height": canopy_h,
			})
	builder.add_box("metal_corrugated", root * _t(Vector3(0.0, canopy_h + 0.35, 0.0)), Vector3(canopy_w, 0.7, canopy_d), Color(0.95, 0.95, 0.98))
	builder.add_box("marking_white", root * _t(Vector3(0.0, canopy_h - 0.02, 0.0)), Vector3(canopy_w - 0.6, 0.06, canopy_d - 0.6), Color(0.98, 0.98, 0.96))
	builder.add_box("shop_sign_c", root * _t(Vector3(0.0, canopy_h + 0.45, -canopy_d * 0.5 - 0.1)), Vector3(6.0, 0.9, 0.12), Color(1, 1, 1))
	# pumps
	for i in range(3):
		var x := (float(i) - 1.0) * 3.4
		builder.add_box("concrete", root * _t(Vector3(x, 0.09, 0.0)), Vector3(1.7, 0.18, 1.7), Color(0.92, 0.92, 0.9))
		builder.add_box("metal_grey", root * _t(Vector3(x, 0.85, 0.0)), Vector3(0.85, 1.4, 0.55), Color(0.95, 0.95, 0.97))
		builder.add_box("metal_dark", root * _t(Vector3(x, 1.35, -0.3)), Vector3(0.7, 0.6, 0.12), Color(0.9, 0.9, 0.9))
		builder.add_box("traffic_light_green", root * _t(Vector3(x, 1.0, 0.32)), Vector3(0.5, 0.3, 0.08), Color(1, 1, 1))
		colliders.append({"shape": "box", "transform": root * _t(Vector3(x, 0.85, 0.0)), "size": Vector3(1.0, 1.7, 0.7)})
	# shop box
	builder.add_box("facade_storefront", root * _t(Vector3(0.0, 2.4, canopy_d * 0.5 + 4.5), PI, 1.0), Vector3(14.0, 4.8, 6.0), Color(0.98, 0.98, 0.98))
	builder.add_box("roof_flat", root * _t(Vector3(0.0, 4.9, canopy_d * 0.5 + 4.5)), Vector3(14.4, 0.4, 6.4), Color(0.95, 0.95, 0.95))
	colliders.append({
		"shape": "box", "transform": root * _t(Vector3(0.0, 2.4, canopy_d * 0.5 + 4.5), PI, 1.0),
		"size": Vector3(14.0, 4.8, 6.0),
	})
	return colliders


static func hay_bale(builder: MeshBuilder, base: Transform3D, yaw: float, rng: RandomNumberGenerator) -> Array:
	builder.add_cylinder(
		"wood_planks",
		base * _t(Vector3(0.0, 0.6, 0.0), yaw, 1.0) * Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3.ZERO),
		0.6, 0.6, 1.25, 10, Color(0.98, 0.94, 0.8)
	)
	return []


static func silo(builder: MeshBuilder, base: Transform3D, rng: RandomNumberGenerator) -> Array:
	var height := 11.0
	var radius := 2.6
	builder.add_cylinder("metal_corrugated", base * _t(Vector3(0.0, height * 0.5, 0.0)), radius, radius, height, 14, Color(0.92, 0.94, 0.96))
	builder.add_cylinder("metal_grey", base * _t(Vector3(0.0, height + 1.2, 0.0)), radius * 0.55, 0.15, 2.6, 12, Color(0.9, 0.9, 0.92))
	return [{"shape": "cylinder", "transform": base * _t(Vector3(0.0, height * 0.5, 0.0)), "radius": radius, "height": height}]


static func windmill(builder: MeshBuilder, base: Transform3D, rng: RandomNumberGenerator) -> Array:
	var height := 13.0
	var radius := 2.2
	builder.add_cylinder("concrete", base * _t(Vector3(0.0, height * 0.5, 0.0)), radius * 1.15, radius * 0.7, height, 12, Color(0.92, 0.92, 0.9))
	builder.add_cylinder("roof_metal", base * _t(Vector3(0.0, height + 1.3, 0.0)), radius * 0.75, 0.3, 2.6, 12, Color(0.9, 0.9, 0.92))
	# blades
	for i in range(4):
		var angle := TAU * float(i) / 4.0
		var hub := base * _t(Vector3(0.0, height + 0.4, -radius * 0.85))
		var blade_transform := hub * Transform3D(Basis(Vector3.FORWARD, angle), Vector3.ZERO)
		builder.add_box("wood_planks", blade_transform * _t(Vector3(0.0, 4.2, 0.0)), Vector3(0.4, 8.4, 0.16), Color(0.95, 0.92, 0.86))
	builder.add_cylinder("metal_dark", base * _t(Vector3(0.0, height + 0.4, -radius * 0.9), 0.0, 1.0) * Transform3D(Basis(Vector3.RIGHT, PI * 0.5), Vector3.ZERO), 0.3, 0.3, 0.3, 8, Color(0.9, 0.9, 0.9))
	return [{"shape": "cylinder", "transform": base * _t(Vector3(0.0, height * 0.5, 0.0)), "radius": radius, "height": height}]


static func billboard_sign(builder: MeshBuilder, base: Transform3D, yaw: float, variant: int, rng: RandomNumberGenerator) -> Array:
	var root := base * _t(Vector3.ZERO, yaw, 1.0)
	var width := 7.0
	var height := 3.6
	var post_height := 5.0
	for sx in [-1.0, 1.0]:
		builder.add_cylinder("metal_dark", root * _t(Vector3(sx * (width * 0.3), post_height * 0.5, 0.0)), 0.19, 0.16, post_height, 8, Color(0.9, 0.9, 0.92))
	builder.add_box("metal_dark", root * _t(Vector3(0.0, post_height + height * 0.5, 0.0)), Vector3(width, height, 0.22), Color(0.85, 0.88, 0.9))
	builder.add_billboard(
		"billboard_ad_a" if variant % 2 == 0 else "billboard_ad_b",
		root * _t(Vector3(0.0, post_height + height * 0.5, 0.14)),
		Vector2(width - 0.2, height - 0.2),
		Color(1, 1, 1)
	)
	return [{"shape": "box", "transform": root * _t(Vector3(0.0, post_height * 0.5, 0.0)), "size": Vector3(width * 0.75, post_height, 0.5)}]


## ------------------------------------------------------------- vegetation --
static func tree_broadleaf(builder: MeshBuilder, base: Transform3D, height: float, rng: RandomNumberGenerator, lod: int = 0) -> Array:
	var trunk_height := height * 0.42
	var radius := 0.13 + height * 0.028
	builder.add_cylinder("tree_bark", base * _t(Vector3(0.0, trunk_height * 0.5, 0.0)), radius * 1.25, radius * 0.8, trunk_height, 6, Color(0.9, 0.9, 0.9))
	var crown_radius := height * 0.42
	if lod == 0:
		# three overlapping foliage clusters - cheap and reads as a real crown
		for i in range(3):
			var angle := TAU * float(i) / 3.0 + rng.randf() * 0.6
			var offset := Vector3(cos(angle), 0.0, sin(angle)) * crown_radius * 0.42
			var size := crown_radius * (1.5 + rng.randf() * 0.4) * (0.85 if i > 0 else 1.0)
			builder.add_foliage_planes(
				"foliage_a" if i != 1 else "foliage_b",
				base * _t(Vector3(offset.x, trunk_height + height * 0.32 + float(i) * height * 0.07, offset.z), rng.randf() * TAU, 1.0),
				Vector2(size, size * 0.95),
				2,
				Color(0.85 + rng.randf() * 0.3, 1.0, 0.9 + rng.randf() * 0.2)
			)
	else:
		builder.add_foliage_planes(
			"foliage_b",
			base * _t(Vector3(0.0, trunk_height * 0.6, 0.0), rng.randf() * TAU, 1.0),
			Vector2(crown_radius * 2.6, height * 0.82),
			2,
			Color(0.9, 1.0, 0.9)
		)
	return [{"shape": "cylinder", "transform": base * _t(Vector3(0.0, trunk_height * 0.5, 0.0)), "radius": radius * 1.6, "height": trunk_height}]


static func tree_conifer(builder: MeshBuilder, base: Transform3D, height: float, rng: RandomNumberGenerator, lod: int = 0) -> Array:
	var trunk_height := height * 0.22
	builder.add_cylinder("tree_bark", base * _t(Vector3(0.0, trunk_height * 0.5, 0.0)), 0.22, 0.16, trunk_height, 6, Color(0.9, 0.9, 0.9))
	if lod == 0:
		var levels := 3
		for i in range(levels):
			var t := float(i) / float(levels)
			var level_height := height * 0.3
			var level_radius := height * 0.24 * (1.0 - t * 0.45)
			builder.add_cylinder(
				"foliage_pine",
				base * _t(Vector3(0.0, trunk_height + level_height * (float(i) + 0.5) * 0.95, 0.0), rng.randf() * TAU, 1.0),
				level_radius, 0.05, level_height * 1.5, 9,
				Color(0.85 + rng.randf() * 0.3, 1.0, 0.9)
			)
	else:
		builder.add_cylinder(
			"foliage_pine",
			base * _t(Vector3(0.0, trunk_height + height * 0.35, 0.0), 0.0, 1.0),
			height * 0.22, 0.05, height * 0.75, 7, Color(0.9, 1.0, 0.9)
		)
	return [{"shape": "cylinder", "transform": base * _t(Vector3(0.0, height * 0.2, 0.0)), "radius": 0.35, "height": height * 0.4}]


static func tree_palm(builder: MeshBuilder, base: Transform3D, height: float, rng: RandomNumberGenerator, lod: int = 0) -> Array:
	var curve := rng.randf_range(-0.16, 0.16)
	var trunk_height := height * 0.78
	var segments := 5 if lod == 0 else 2
	var previous := Vector3.ZERO
	for i in range(segments):
		var t0 := float(i) / float(segments)
		var t1 := float(i + 1) / float(segments)
		var p0 := Vector3(curve * trunk_height * t0 * t0 * 3.0, trunk_height * t0, 0.0)
		var p1 := Vector3(curve * trunk_height * t1 * t1 * 3.0, trunk_height * t1, 0.0)
		var middle := (p0 + p1) * 0.5
		var length := p0.distance_to(p1)
		builder.add_cylinder("tree_bark", base * _t(middle), 0.2 - 0.02 * float(i), 0.18 - 0.02 * float(i), length, 7, Color(0.95, 0.92, 0.88))
		previous = p1
	var crown_base := base * _t(previous)
	builder.add_foliage_planes(
		"foliage_palm",
		crown_base,
		Vector2(height * 0.62, height * 0.42),
		3 if lod == 0 else 2,
		Color(0.9 + rng.randf() * 0.2, 1.0, 0.9)
	)
	return [{"shape": "cylinder", "transform": base * _t(Vector3(0.0, trunk_height * 0.5, 0.0)), "radius": 0.3, "height": trunk_height}]


static func bush(builder: MeshBuilder, base: Transform3D, scale: float, rng: RandomNumberGenerator) -> Array:
	builder.add_foliage_planes(
		"bush",
		base * _t(Vector3.ZERO, rng.randf() * TAU, 1.0),
		Vector2(scale * 1.1, scale),
		2,
		Color(0.85 + rng.randf() * 0.3, 1.0, 0.9 + rng.randf() * 0.2)
	)
	return []


static func grass_tuft(builder: MeshBuilder, base: Transform3D, scale: float, rng: RandomNumberGenerator) -> Array:
	builder.add_foliage_planes(
		"grass_tuft",
		base * _t(Vector3.ZERO, rng.randf() * TAU, 1.0),
		Vector2(scale * 0.9, scale),
		2,
		Color(0.8 + rng.randf() * 0.4, 1.0, 0.8 + rng.randf() * 0.3)
	)
	return []


static func rock(builder: MeshBuilder, base: Transform3D, radius: float, rng: RandomNumberGenerator, material: String = "rock_granite") -> Array:
	builder.add_rock(material, base, radius, rng, Color(0.85 + rng.randf() * 0.3, 0.9, 0.9))
	return [{"shape": "box", "transform": base * _t(Vector3(0.0, radius * 0.35, 0.0)), "size": Vector3(radius * 1.7, radius * 0.7, radius * 1.7)}]


static func rock_cluster(builder: MeshBuilder, base: Transform3D, scale: float, rng: RandomNumberGenerator, material: String = "rock_granite") -> Array:
	var colliders := []
	var count := rng.randi_range(2, 4)
	for i in range(count):
		var angle := rng.randf() * TAU
		var distance := rng.randf() * scale * 0.9
		var offset := Vector3(cos(angle), 0.0, sin(angle)) * distance
		var size := scale * rng.randf_range(0.55, 1.1)
		colliders.append_array(rock(builder, base * _t(offset + Vector3(0.0, size * 0.25, 0.0), rng.randf() * TAU, 1.0), size * 0.5, rng, material))
	return colliders
