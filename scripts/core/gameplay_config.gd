class_name GameplayConfig
extends Resource

## Rules of the pursuit game: how many police cars are allowed, how far away
## they may spawn, and what actually counts as "the player is caught".

@export_group("Pursuit")
@export var min_police_count: int = 1
@export var max_police_count: int = 6
@export var default_police_count: int = 3
@export var default_ai_level: int = 2
## Seconds the player must stay out of sight to escape the pursuit.
@export var escape_time_s: float = 18.0
@export var escape_distance_m: float = 420.0
## The pursuit escalates: after this long the next police car joins.
@export var escalate_interval_s: float = 35.0
## Maximum number of police cars at the highest escalation step.
@export var escalate_max_count: int = 5

@export_group("Spawning")
@export var spawn_min_distance_m: float = 165.0
@export var spawn_max_distance_m: float = 520.0
## Police never spawn inside the camera frustum closer than this.
@export var spawn_min_screen_distance_m: float = 110.0
@export var respawn_delay_s: float = 6.0
@export var max_spawn_attempts: int = 24
## Two police cars never spawn closer than this to each other.
@export var spawn_min_separation_m: float = 16.0
## After a successful arrest the next pursuit waits this long to spawn cars.
@export var respawn_grace_s: float = 2.0

@export_group("Arrest / blocking")
## Below this speed the player counts as "stopped" for the block detector.
@export var stopped_speed_ms: float = 1.6
## The player has to be pinned for this long before the arrest triggers.
@export var arrest_hold_time_s: float = 3.0
## Police cars required within arrest_radius_m of the player.
@export var arrest_min_police_near: int = 2
@export var arrest_radius_m: float = 7.5
## Share of the surrounding directions that must be blocked (ray tests).
@export var arrest_blocked_ratio: float = 0.72
@export var arrest_probe_distance_m: float = 9.0
## Number of rays of the "am I boxed in?" fan around the player car.
@export var arrest_probe_rays: int = 16
## Above this speed the arrest progress decays (player is driving away).
@export var arrest_release_speed_ms: float = 6.0
## How fast the arrest timer decays when the conditions are not met.
@export var arrest_decay_rate: float = 2.0
@export var arrest_max_tilt_deg: float = 62.0

@export_group("Player")
## Where the player car is placed at the start of a session.  The point is
## snapped to the nearest road by SpawnManager, so an approximate value is fine;
## the default sits on a street in the city centre (the city grid is centred on
## world origin with a 145 m pitch).
@export var player_start_position: Vector3 = Vector3(118.0, 0.0, 74.0)
@export var player_start_search_radius_m: float = 420.0
## Насколько высоко над землёй появляется машина (начало координат машины -
## плоскость контакта, поэтому 1.2 м означали бы падение с высоты больше метра).
@export var reset_height_offset: float = 0.45
@export var fall_out_of_world_height: float = -60.0
