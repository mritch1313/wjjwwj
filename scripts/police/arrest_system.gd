class_name ArrestSystem
extends RefCounted

## Decides when the player is *actually* caught.
##
## Touching a police car never ends the chase.  The player is only arrested when
## the car is genuinely immobilised: slow, surrounded by police cars that are
## close, with all the escape directions physically blocked, and that state has
## to hold for `arrest_hold_time_s`.  Every condition is measured with physics
## queries, so ramming a police car on the motorway does nothing.
##
## The ray fan (`probe_escape_directions`) is the interesting part: it casts a
## ring of rays from the car and counts how many of them hit something close by.

var config: GameplayConfig
var hold_timer_s: float = 0.0
var is_arrested: bool = false
var last_score: float = 0.0
var last_blocked_ratio: float = 0.0
var last_reason: String = "moving"
var first_arrest_frame: int = 0
var _frame_count: int = 0
var _probe_cache_timer: float = 0.0
var _cached_blocked_ratio: float = 0.0


func _init(gameplay_config: GameplayConfig) -> void:
	config = gameplay_config


func reset() -> void:
	hold_timer_s = 0.0
	is_arrested = false
	last_score = 0.0
	last_blocked_ratio = 0.0
	last_reason = "moving"
	_probe_cache_timer = 0.0
	_cached_blocked_ratio = 0.0


## Casts `probe_ray_count` rays in a circle and returns the share that hit
## something within `arrest_probe_distance_m` (the car is boxed in when this is
## high).  Results are cached for a fraction of a second - the ratio does not
## change fast enough to justify querying it every physics frame.
func blocked_ratio(
	space: PhysicsDirectSpaceState3D,
	position: Vector3,
	exclude: Array,
	delta: float,
	height: float = 0.8
) -> float:
	_probe_cache_timer -= delta
	if _probe_cache_timer > 0.0:
		return _cached_blocked_ratio
	_probe_cache_timer = 0.12
	if space == null:
		_cached_blocked_ratio = 0.0
		return 0.0
	var rays := maxi(config.arrest_probe_rays, 4)
	var blocked := 0
	var origin := position + Vector3.UP * height
	for i in range(rays):
		var angle := TAU * float(i) / float(rays)
		var direction := Vector3(cos(angle), 0.0, sin(angle))
		var query := PhysicsRayQueryParameters3D.create(origin, origin + direction * config.arrest_probe_distance_m)
		query.collision_mask = 1 | (1 << 1) | (1 << 3) | (1 << 4)
		query.exclude = exclude
		var hit := space.intersect_ray(query)
		if not hit.is_empty():
			blocked += 1
	_cached_blocked_ratio = float(blocked) / float(rays)
	return _cached_blocked_ratio


## Main evaluation, called every physics frame during a pursuit.
## police_positions: Array[Vector3]; returns true when the arrest just happened.
func update(
	delta: float,
	player_position: Vector3,
	player_speed_ms: float,
	player_wheels_on_ground: int,
	police_positions: Array,
	blocked: float
) -> bool:
	_frame_count += 1
	last_blocked_ratio = blocked
	if is_arrested:
		return false
	var speed_ok := absf(player_speed_ms) <= config.stopped_speed_ms
	var upright := player_wheels_on_ground >= 2
	var close_count := 0
	for entry in police_positions:
		var position: Vector3 = entry if entry is Vector3 else (entry as Node3D).global_position
		if position.distance_to(player_position) <= config.arrest_radius_m:
			close_count += 1
	var surrounded := close_count >= config.arrest_min_police_near
	var boxed_in := blocked >= config.arrest_blocked_ratio
	var conditions := speed_ok and upright and surrounded and boxed_in
	# score is kept for HUD/debug: 0..1 how close the situation is to an arrest
	var speed_score := clampf(1.0 - absf(player_speed_ms) / maxf(config.arrest_release_speed_ms, 0.1), 0.0, 1.0)
	var police_score := clampf(float(close_count) / float(maxi(config.arrest_min_police_near, 1)), 0.0, 1.0)
	last_score = speed_score * 0.4 + police_score * 0.3 + clampf(blocked, 0.0, 1.0) * 0.3
	if conditions:
		hold_timer_s += delta
		last_reason = "pinned"
		if hold_timer_s >= config.arrest_hold_time_s:
			is_arrested = true
			first_arrest_frame = _frame_count
			return true
	else:
		# decay instead of an instant reset: brief escapes of the trap do not
		# throw away the whole arrest progress, but sustained driving does
		hold_timer_s = maxf(hold_timer_s - delta * config.arrest_decay_rate, 0.0)
		if not speed_ok:
			last_reason = "still_moving"
		elif not surrounded:
			last_reason = "not_surrounded"
		elif not boxed_in:
			last_reason = "free_space"
		else:
			last_reason = "not_upright"
	return false


func progress() -> float:
	return clampf(hold_timer_s / maxf(config.arrest_hold_time_s, 0.001), 0.0, 1.0)


func status() -> Dictionary:
	return {
		"arrested": is_arrested,
		"progress": progress(),
		"blocked_ratio": last_blocked_ratio,
		"score": last_score,
		"reason": last_reason,
	}
