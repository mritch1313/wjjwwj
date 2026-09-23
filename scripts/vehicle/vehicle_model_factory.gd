class_name VehicleModelFactory
extends RefCounted

## Procedural car bodies.  This is the *visual* half of a vehicle: the physics
## (VehicleController / VehiclePhysics / WheelSystem) never references a mesh,
## it only reads VehicleConfig.  Swapping the art therefore means pointing the
## model factory at another mesh - see VehicleController.visual_model_name.
##
## Shapes are built from plan-view footprints extruded upwards (`add_prism`),
## which gives cars with tapered noses/tails instead of plain cuboids, plus a
## separate cabin volume, glass, bumpers, lights, mirrors, wheels and - for the
## police - a light bar, livery stripes and a push bar.
##
## LOD0 = full detail, LOD1 = no mirrors/glass/lights details, LOD2 = silhouette.

enum Role { CIVILIAN, POLICE, TRAFFIC, PARKED }


static func _t(position: Vector3, yaw: float = 0.0, scale: float = 1.0) -> Transform3D:
	return Transform3D(Basis(Vector3.UP, yaw).scaled(Vector3(scale, scale, scale)), position)


## Footprint of a car in plan view (-Z is the front).
static func _footprint(length: float, width: float, nose_taper: float, tail_taper: float, bevel: float) -> PackedVector2Array:
	var half_length := length * 0.5
	var half_width := width * 0.5
	var nose_width := half_width * nose_taper
	var tail_width := half_width * tail_taper
	var points := PackedVector2Array()
	points.append(Vector2(-nose_width, -half_length))                       # nose left
	points.append(Vector2(-half_width * 0.99, -half_length + bevel))        # front left corner
	points.append(Vector2(-half_width, -half_length * 0.32))                # left front
	points.append(Vector2(-half_width, half_length * 0.34))                 # left rear
	points.append(Vector2(-half_width * 0.98, half_length - bevel))         # rear left corner
	points.append(Vector2(-tail_width, half_length))                        # tail left
	points.append(Vector2(tail_width, half_length))                         # tail right
	points.append(Vector2(half_width * 0.98, half_length - bevel))          # rear right corner
	points.append(Vector2(half_width, half_length * 0.34))                  # right rear
	points.append(Vector2(half_width, -half_length * 0.32))                 # right front
	points.append(Vector2(half_width * 0.99, -half_length + bevel))         # front right corner
	points.append(Vector2(nose_width, -half_length))                        # nose right
	return points


static func paint_material_for(role: int) -> String:
	match role:
		Role.POLICE: return "car_body_police"
		Role.TRAFFIC: return "car_body_traffic"
		Role.PARKED: return "car_body_traffic"
		_: return "car_body_player"


## Builds one car.  Returns details the vehicle system needs:
##   { "wheel_centres": Array[Vector3], "wheel_radius": float, "size": Vector3,
##     "material": String }
static func build_car(
	builder: MeshBuilder,
	origin: Transform3D,
	config: VehicleConfig,
	role: int,
	lod: int,
	rng: RandomNumberGenerator,
	paint_material: String = "",
	include_wheels: bool = true
) -> Dictionary:
	var size := config.body_size
	var wheel_radius := config.wheel_radius_m
	var wheel_width := config.wheel_width_m
	var half_track := config.track_width_m * 0.5
	var half_base := config.wheelbase_m * 0.5
	var wheel_centres := [
		Vector3(-half_track, wheel_radius, -half_base),
		Vector3(half_track, wheel_radius, -half_base),
		Vector3(-half_track, wheel_radius, half_base),
		Vector3(half_track, wheel_radius, half_base),
	]
	var material := paint_material if not paint_material.is_empty() else paint_material_for(role)
	# Same number the collision box uses, so what is seen and what can be hit agree.
	var body_bottom := config.ground_clearance_m
	var body_height := size.y * 0.62
	var roof_height := size.y - body_height * 0.55
	var paint_tint := Color(1, 1, 1)
	if role != Role.POLICE:
		paint_tint = Color(
			rng.randf_range(0.82, 1.08),
			rng.randf_range(0.82, 1.08),
			rng.randf_range(0.82, 1.08)
		)
	else:
		paint_tint = Color(0.98, 0.98, 1.0)

	# --- LOD2: силуэт для дальних машин.  Полный набор деталей (стёкла, фары,
	# зеркала, решётки, полосы, мигалка) стоит сотни треугольников и с 300 м
	# неразличим, поэтому остаётся узнаваемый профиль: корпус, кабина и колёса.
	if lod >= 2:
		var lower_height := size.y * 0.55
		var upper_height := maxf(size.y - body_bottom - lower_height, 0.05)
		builder.add_box(
			material,
			origin * _t(Vector3(0.0, body_bottom + lower_height * 0.5, 0.0)),
			Vector3(size.x, lower_height, size.z), paint_tint
		)
		builder.add_box(
			material,
			origin * _t(Vector3(0.0, body_bottom + lower_height + upper_height * 0.5, size.z * 0.02)),
			Vector3(size.x * 0.86, upper_height, size.z * 0.46), paint_tint
		)
		if include_wheels:
			for center in wheel_centres:
				builder.add_cylinder(
					"car_tire",
					origin * _t(center, 0.0, 1.0) * Transform3D(Basis(Vector3.FORWARD, PI * 0.5), Vector3.ZERO),
					wheel_radius, wheel_radius, wheel_width, 6, Color(0.9, 0.9, 0.9)
				)
		return {
			"wheel_centres": wheel_centres,
			"wheel_radius": wheel_radius,
			"size": size,
			"material": material,
		}
	var footprint := _footprint(size.z, size.x, 0.86, 0.92, 0.34)
	# --- main body (slightly tapered prism reads as a real car silhouette)
	builder.add_prism(
		material,
		origin * _t(Vector3(0.0, body_bottom + body_height * 0.5, 0.0)),
		footprint,
		body_height,
		paint_tint,
		Vector2(0.35, 0.35),
		material
	)
	# --- hood and boot lids (a little lower than the belt line for shape variety)
	builder.add_box(
		material,
		origin * _t(Vector3(0.0, body_bottom + body_height * 0.98, -size.z * 0.31)),
		Vector3(size.x * 0.82, 0.06, size.z * 0.28), paint_tint
	)
	# --- cabin: trapezoid footprint, narrower at the roof
	var cabin_length := size.z * 0.46
	var cabin_width := size.x * 0.86
	var cabin_bottom := body_bottom + body_height * 0.92
	var cabin_height := roof_height - body_bottom
	var cabin_points := PackedVector2Array([
		Vector2(-cabin_width * 0.42, -cabin_length * 0.5),
		Vector2(-cabin_width * 0.5, -cabin_length * 0.28),
		Vector2(-cabin_width * 0.5, cabin_length * 0.36),
		Vector2(-cabin_width * 0.44, cabin_length * 0.5),
		Vector2(cabin_width * 0.44, cabin_length * 0.5),
		Vector2(cabin_width * 0.5, cabin_length * 0.36),
		Vector2(cabin_width * 0.5, -cabin_length * 0.28),
		Vector2(cabin_width * 0.42, -cabin_length * 0.5),
	])
	builder.add_prism(
		material,
		origin * _t(Vector3(0.0, cabin_bottom + cabin_height * 0.5, size.z * 0.02)),
		cabin_points,
		cabin_height,
		paint_tint,
		Vector2(0.4, 0.4),
		material
	)
	if lod <= 1:
		# --- glazing: windscreen, rear window and side windows as inset quads
		var glass_bottom := cabin_bottom + cabin_height * 0.28
		var glass_height := cabin_height * 0.62
		var glass_tint := Color(0.85, 0.9, 0.95)
		var windscreen_front := origin * _t(Vector3(0.0, glass_bottom, size.z * 0.02 - cabin_length * 0.5 - 0.02))
		builder.add_quad(
			"car_glass",
			windscreen_front * Vector3(-cabin_width * 0.4, 0.0, 0.0),
			windscreen_front * Vector3(cabin_width * 0.4, 0.0, 0.0),
			windscreen_front * Vector3(cabin_width * 0.36, glass_height, 0.16),
			windscreen_front * Vector3(-cabin_width * 0.36, glass_height, 0.16),
			glass_tint, Vector2(0, 1), Vector2(1, 1), Vector2(1, 0), Vector2(0, 0), Vector3.FORWARD
		)
		var windscreen_rear := origin * _t(Vector3(0.0, glass_bottom, size.z * 0.02 + cabin_length * 0.5 + 0.02))
		builder.add_quad(
			"car_glass",
			windscreen_rear * Vector3(cabin_width * 0.36, glass_height, -0.16),
			windscreen_rear * Vector3(-cabin_width * 0.36, glass_height, -0.16),
			windscreen_rear * Vector3(-cabin_width * 0.4, 0.0, 0.0),
			windscreen_rear * Vector3(cabin_width * 0.4, 0.0, 0.0),
			glass_tint, Vector2(1, 0), Vector2(0, 0), Vector2(0, 1), Vector2(1, 1), Vector3.BACK
		)
		for side in [1.0, -1.0]:
			var sign := float(side)
			var side_plane := origin * _t(Vector3(sign * (cabin_width * 0.5 + 0.01), glass_bottom, size.z * 0.02))
			var normal := (origin.basis * Vector3(sign, 0.0, 0.0)).normalized()
			builder.add_quad(
				"car_glass",
				side_plane * Vector3(0.0, 0.0, -cabin_length * 0.34),
				side_plane * Vector3(0.0, glass_height, -cabin_length * 0.28),
				side_plane * Vector3(0.0, glass_height, cabin_length * 0.34),
				side_plane * Vector3(0.0, 0.0, cabin_length * 0.4),
				glass_tint, Vector2(0, 1), Vector2(0.2, 0), Vector2(1, 0), Vector2(1, 1), normal
			)
	# --- bumpers, sills and grille
	var bumper_height := body_height * 0.34
	for front in [-1.0, 1.0]:
		builder.add_box(
			"car_trim",
			origin * _t(Vector3(0.0, body_bottom + bumper_height * 0.5, front * (size.z * 0.5 - 0.04))),
			Vector3(size.x * 0.98, bumper_height, 0.28), Color(0.9, 0.9, 0.92)
		)
	builder.add_box(
		"car_trim", origin * _t(Vector3(0.0, body_bottom + 0.06, 0.0)),
		Vector3(size.x * 1.0, 0.12, size.z * 0.94), Color(0.85, 0.85, 0.88)
	)
	# --- lights
	if lod == 0:
		var light_height := body_bottom + body_height * 0.62
		for side in [-1.0, 1.0]:
			var sign := float(side)
			builder.add_box(
				"car_light_front",
				origin * _t(Vector3(sign * size.x * 0.33, light_height, -size.z * 0.5 + 0.02)),
				Vector3(size.x * 0.26, 0.17, 0.1), Color(1, 1, 1)
			)
			builder.add_box(
				"car_light_rear",
				origin * _t(Vector3(sign * size.x * 0.33, light_height, size.z * 0.5 - 0.02)),
				Vector3(size.x * 0.26, 0.16, 0.1), Color(1, 1, 1)
			)
		builder.add_box(
			"metal_dark",
			origin * _t(Vector3(0.0, body_bottom + body_height * 0.42, -size.z * 0.5 + 0.01)),
			Vector3(size.x * 0.55, 0.2, 0.06), Color(0.9, 0.9, 0.9)
		)
		# mirrors
		for side in [-1.0, 1.0]:
			var sign := float(side)
			builder.add_box(
				material,
				origin * _t(Vector3(sign * (size.x * 0.5 + 0.11), cabin_bottom + cabin_height * 0.62, -cabin_length * 0.42)),
				Vector3(0.22, 0.12, 0.1), paint_tint
			)
		# number plates
		builder.add_billboard(
			"car_plate",
			origin * _t(Vector3(0.0, body_bottom + bumper_height * 0.62, -size.z * 0.5 - 0.01)),
			Vector2(0.52, 0.13), Color(1, 1, 1)
		)
		builder.add_billboard(
			"car_plate",
			origin * _t(Vector3(0.0, body_bottom + bumper_height * 0.62, size.z * 0.5 + 0.01), PI),
			Vector2(0.52, 0.13), Color(1, 1, 1)
		)
	# --- police extras
	if role == Role.POLICE:
		var lightbar_height := cabin_bottom + cabin_height + 0.09
		builder.add_box(
			"car_trim", origin * _t(Vector3(0.0, lightbar_height, 0.0)),
			Vector3(size.x * 0.68, 0.13, 0.42), Color(0.85, 0.85, 0.9)
		)
		for side in [-1.0, 1.0]:
			var sign := float(side)
			var lamp_material := "police_lightbar_red" if sign < 0.0 else "police_lightbar_blue"
			builder.add_box(
				lamp_material,
				origin * _t(Vector3(sign * size.x * 0.19, lightbar_height + 0.09, 0.0)),
				Vector3(size.x * 0.28, 0.1, 0.36), Color(1, 1, 1)
			)
			# livery stripes on the doors
			builder.add_box(
				"police_stripe",
				origin * _t(Vector3(sign * (size.x * 0.5 + 0.005), body_bottom + body_height * 0.55, 0.1)),
				Vector3(0.02, 0.26, size.z * 0.55), Color(1, 1, 1)
			)
			builder.add_billboard(
				"police_stripe",
				origin * _t(Vector3(sign * (size.x * 0.5 + 0.02), body_bottom + body_height * 0.6, 0.0), sign * PI * 0.5),
				Vector2(size.z * 0.4, 0.42), Color(1, 1, 1)
			)
		# push bar
		builder.add_box(
			"metal_dark", origin * _t(Vector3(0.0, body_bottom + body_height * 0.55, -size.z * 0.5 - 0.16)),
			Vector3(size.x * 0.86, 0.7, 0.1), Color(0.9, 0.9, 0.9)
		)
		for side in [-1.0, 1.0]:
			builder.add_box(
				"metal_dark",
				origin * _t(Vector3(float(side) * size.x * 0.36, body_bottom + body_height * 0.5, -size.z * 0.5 - 0.08)),
				Vector3(0.1, 0.5, 0.2), Color(0.9, 0.9, 0.9)
			)
		# roof-mounted antenna
		builder.add_cylinder(
			"metal_dark",
			origin * _t(Vector3(size.x * 0.3, cabin_bottom + cabin_height + 0.3, size.z * 0.22)),
			0.02, 0.015, 0.6, 5, Color(0.9, 0.9, 0.9)
		)
	# --- wheels (skipped when they are separate animated nodes)
	if not include_wheels:
		return {
			"wheel_centres": wheel_centres,
			"wheel_radius": wheel_radius,
			"size": size,
			"material": material,
		}
	for wheel_index in range(wheel_centres.size()):
		var center: Vector3 = wheel_centres[wheel_index]
		if lod == 0:
			builder.add_cylinder(
				"car_tire",
				origin * _t(center, 0.0, 1.0) * Transform3D(Basis(Vector3.FORWARD, PI * 0.5), Vector3.ZERO),
				wheel_radius, wheel_radius, wheel_width, 14, Color(0.95, 0.95, 0.95)
			)
			var rim_sign := 1.0 if center.x > 0.0 else -1.0
			builder.add_cylinder(
				"car_rim",
				origin * _t(center + Vector3(rim_sign * wheel_width * 0.52, 0.0, 0.0), 0.0, 1.0) * Transform3D(Basis(Vector3.FORWARD, PI * 0.5), Vector3.ZERO),
				wheel_radius * 0.66, wheel_radius * 0.66, 0.05, 12, Color(1, 1, 1)
			)
			# wheel arch shadow (dark trim around the wheel)
			builder.add_box(
				"car_trim",
				origin * _t(center + Vector3(0.0, wheel_radius * 0.35, 0.0)),
				Vector3(wheel_width * 1.5, wheel_radius * 0.5, wheel_radius * 2.0), Color(0.8, 0.8, 0.85)
			)
		else:
			builder.add_cylinder(
				"car_tire",
				origin * _t(center, 0.0, 1.0) * Transform3D(Basis(Vector3.FORWARD, PI * 0.5), Vector3.ZERO),
				wheel_radius, wheel_radius, wheel_width, 8, Color(0.9, 0.9, 0.9)
			)
	return {
		"wheel_centres": wheel_centres,
		"wheel_radius": wheel_radius,
		"size": size,
		"material": material,
	}


## A single wheel (tyre + rim), built around the origin so it can be used for
## four animated wheel nodes.  Axis is local X, matching the car's right vector.
static func build_wheel(builder: MeshBuilder, config: VehicleConfig, lod: int = 0) -> void:
	var radius := config.wheel_radius_m
	var width := config.wheel_width_m
	builder.add_cylinder(
		"car_tire",
		Transform3D(Basis(Vector3.FORWARD, PI * 0.5), Vector3.ZERO),
		radius, radius, width, 14 if lod == 0 else 8, Color(0.95, 0.95, 0.95)
	)
	for side in [-1.0, 1.0]:
		builder.add_cylinder(
			"car_rim",
			Transform3D(Basis(Vector3.FORWARD, PI * 0.5), Vector3(float(side) * width * 0.51, 0.0, 0.0)),
			radius * 0.64, radius * 0.64, 0.05, 12, Color(1, 1, 1)
		)
		# brake disc behind the rim is lost at this size; a hub cap reads better
		builder.add_cylinder(
			"metal_dark",
			Transform3D(Basis(Vector3.FORWARD, PI * 0.5), Vector3(float(side) * width * 0.36, 0.0, 0.0)),
			radius * 0.34, radius * 0.34, 0.12, 10, Color(0.9, 0.9, 0.9)
		)


## Parked / traffic car: a cheap static variant used to fill parking lots and
## roadside parking spots - adds a lot of life for very few triangles.
static func build_parked_car(builder: MeshBuilder, origin: Transform3D, config: VehicleConfig, rng: RandomNumberGenerator) -> void:
	build_car(builder, origin, config, Role.PARKED, 1, rng, "")
