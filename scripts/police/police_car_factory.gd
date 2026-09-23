class_name PoliceCarFactory
extends RefCounted

## Builds a police car: the same VehicleController as the player, but with the
## police config, the police livery and the police collision layer.  Keeping the
## factory in one place is what guarantees "police cars use the same physics".

const POLICE_LAYER := 1 << 3  # layer 4 ("police_car")


static func create(position: Vector3, yaw: float, index: int, ai_level: int = 2) -> VehicleController:
	var car := VehicleController.new()
	car.name = "PoliceCar%d" % index
	car.config = Config.vehicle_police
	car.collision_layer = POLICE_LAYER
	car.collision_mask = 1 | (1 << 1) | (1 << 2) | POLICE_LAYER
	car.rotation = Vector3(0.0, yaw, 0.0)
	car.position = position
	car.vehicle_role = VehicleModelFactory.Role.POLICE
	car.is_player_vehicle = false
	car.set_meta("police", true)
	car.set_meta("ai_level", ai_level)
	return car


## The whole fleet spawns with the police livery, which is defined by the model
## factory: this helper only exists so the manager does not have to know how a
## police car is painted.
static func livery_color() -> Color:
	return Config.police.livery_color


static func stripe_color() -> Color:
	return Config.police.stripe_color
