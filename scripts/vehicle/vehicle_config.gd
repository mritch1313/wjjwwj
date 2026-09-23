class_name VehicleConfig
extends Resource

## Complete setup of one car: mass, engine, gearbox, suspension, tyres,
## steering, brakes, aerodynamics and nitro.
##
## The visual model is NOT referenced here on purpose - see VehicleModelFactory.
## Any mesh can be plugged into the same physics.

enum Drivetrain { RWD, FWD, AWD }

@export_group("Body")
@export var display_name: String = "Sedan"
@export var mass_kg: float = 1430.0
## Centre of mass relative to the body origin (negative Y = lower).
@export var center_of_mass_offset: Vector3 = Vector3(0.0, -0.45, 0.05)
@export var body_size: Vector3 = Vector3(1.86, 1.02, 4.48)
@export var linear_damping: float = 0.02
@export var angular_damping: float = 0.35

@export_group("Paint")
## Body colour used when no palette entry is selected.
@export var paint_color: Color = Color(0.72, 0.13, 0.15)
## Selectable colours on the main menu (empty = only paint_color).
@export var paint_palette: PackedColorArray = PackedColorArray([
	Color(0.72, 0.13, 0.15),
	Color(0.10, 0.20, 0.52),
	Color(0.92, 0.92, 0.94),
	Color(0.13, 0.13, 0.15),
	Color(0.85, 0.62, 0.10),
	Color(0.10, 0.42, 0.28),
])
## Localisation keys matching paint_palette (same order).
@export var paint_names: PackedStringArray = PackedStringArray([
	"paint_red", "paint_blue", "paint_white", "paint_black", "paint_gold", "paint_green",
])

@export_group("Engine and drivetrain")
@export var max_torque_nm: float = 330.0
## Normalised torque over the rpm range (index 0 = idle, last = redline).
@export var torque_curve: PackedFloat32Array = PackedFloat32Array(
	[0.45, 0.74, 0.91, 1.0, 0.96, 0.84, 0.63, 0.3]
)
@export var idle_rpm: float = 820.0
@export var redline_rpm: float = 6600.0
@export var engine_braking_torque_nm: float = 58.0
@export var drivetrain: Drivetrain = Drivetrain.RWD
@export var gear_ratios: PackedFloat32Array = PackedFloat32Array([3.44, 2.11, 1.44, 1.0, 0.79, 0.62])
@export var final_drive: float = 3.55
@export var shift_up_fraction: float = 0.93
@export var shift_down_fraction: float = 0.45
@export var shift_time_s: float = 0.3
## 0 = open differential, 1 = fully locked.
@export var differential_lock: float = 0.35

@export_group("Wheels and suspension")
@export var wheel_radius_m: float = 0.335
@export var wheel_width_m: float = 0.235
@export var wheelbase_m: float = 2.72
@export var track_width_m: float = 1.58
@export var suspension_rest_length_m: float = 0.36
@export var suspension_max_travel_m: float = 0.24
@export var suspension_spring_n_per_m: float = 44000.0
@export var suspension_compression_damping: float = 4600.0
@export var suspension_rebound_damping: float = 5600.0
@export var suspension_max_force_n: float = 34000.0
@export var anti_roll_stiffness: float = 9800.0

@export_group("Tyres")
@export var lateral_grip: float = 1.6
@export var longitudinal_grip: float = 1.4
@export var lateral_slip_peak: float = 0.16
@export var longitudinal_slip_peak: float = 0.13
## Reduces grip as the vertical load grows (N^-1).
@export var load_sensitivity: float = 0.00018
@export var handbrake_lateral_factor: float = 0.42
@export var rolling_resistance: float = 0.016
@export var abs_enabled: bool = true
@export var tcs_enabled: bool = true

@export_group("Steering")
@export var max_steer_angle_deg: float = 34.0
@export var steer_speed_deg_per_s: float = 135.0
@export var steer_return_speed_deg_per_s: float = 190.0
## Steering authority falls off above this speed (km/h) - keeps the car stable.
@export var steer_falloff_kmh: float = 92.0
@export var counter_steer_assist: float = 0.32

@export_group("Brakes")
@export var brake_torque_nm: float = 2700.0
@export var handbrake_torque_nm: float = 5400.0

@export_group("Aerodynamics")
@export var drag_area: float = 0.79
@export var downforce_coefficient: float = 1.1
@export var air_density: float = 1.225
## Free-flow top speed used by AI speed limits and by the balance tests.
@export var top_speed_kmh: float = 158.0
@export var reverse_top_speed_kmh: float = 52.0

@export_group("Nitro")
@export var nitro_thrust_n: float = 5400.0
@export var nitro_capacity_s: float = 4.0
@export var nitro_recharge_s: float = 12.0
@export var nitro_min_charge_s: float = 0.55
@export var nitro_cooldown_s: float = 1.2
@export var nitro_fov_boost: float = 6.0
## Nitro top speed relative to the police top speed (1.25 per design brief).
@export var nitro_speed_factor_vs_police: float = 1.25


func top_speed_ms() -> float:
	return top_speed_kmh / 3.6


## ------------------------------------------------------------------ paint --
## The player car can be repainted without touching the model: the factory
## duplicates only the body material (see VehicleController._build_body_mesh).
func paint_color_for(index: int) -> Color:
	if paint_palette.is_empty():
		return paint_color
	return paint_palette[posmod(index, paint_palette.size())]


func paint_color_name(index: int) -> String:
	if paint_names.is_empty():
		return "paint_%d" % index
	return L10n.t(paint_names[posmod(index, paint_names.size())])


func paint_count() -> int:
	return maxi(paint_palette.size(), 1)


func reverse_top_speed_ms() -> float:
	return reverse_top_speed_kmh / 3.6


func wheel_positions() -> Array:
	## x = left/right, y = suspension anchor height, z = front/back (+Z is rear)
	var half_track := track_width_m * 0.5
	var half_base := wheelbase_m * 0.5
	var anchor_y := -body_size.y * 0.5 + suspension_rest_length_m + wheel_radius_m
	return [
		Vector3(-half_track, anchor_y, -half_base),  # front left
		Vector3(half_track, anchor_y, -half_base),   # front right
		Vector3(-half_track, anchor_y, half_base),   # rear left
		Vector3(half_track, anchor_y, half_base),    # rear right
	]


func is_wheel_driven(index: int) -> bool:
	match drivetrain:
		Drivetrain.FWD:
			return index < 2
		Drivetrain.AWD:
			return true
		_:
			return index >= 2


func is_wheel_steered(index: int) -> bool:
	return index < 2
