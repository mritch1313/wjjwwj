class_name SaveManager
extends Node

## Stores player progress in user://chase_save.cfg (autoload "Save").
## Deliberately tiny: best escape time, arrest count, driven distance, last
## chosen pursuit setup.

const SAVE_PATH := "user://chase_save.cfg"

var escapes: int = 0
var arrests: int = 0
var best_escape_time_s: float = 0.0
var longest_pursuit_s: float = 0.0
var total_distance_km: float = 0.0
var last_police_count: int = 3
var last_ai_level: int = 2

## Driving profile: how much distance the player has covered on each surface,
## how hard they crash and how often the nitro is used.  The values are cheap
## counters so they can be written every few seconds without hurting the frame
## budget on a phone.
var surface_distance_m: Dictionary = {}
var impacts_total: int = 0
var worst_impact_ms: float = 0.0
var nitro_uses_total: int = 0
var drift_time_total_s: float = 0.0


func _ready() -> void:
	load_data()


func load_data() -> void:
	var cfg := ConfigFile.new()
	if cfg.load(SAVE_PATH) != OK:
		return
	escapes = int(cfg.get_value("stats", "escapes", 0))
	arrests = int(cfg.get_value("stats", "arrests", 0))
	best_escape_time_s = float(cfg.get_value("stats", "best_escape_time_s", 0.0))
	longest_pursuit_s = float(cfg.get_value("stats", "longest_pursuit_s", 0.0))
	total_distance_km = float(cfg.get_value("stats", "total_distance_km", 0.0))
	last_police_count = int(cfg.get_value("setup", "police_count", 3))
	last_ai_level = int(cfg.get_value("setup", "ai_level", 2))
	surface_distance_m = cfg.get_value("profile", "surface_distance_m", {})
	if typeof(surface_distance_m) != TYPE_DICTIONARY:
		surface_distance_m = {}
	impacts_total = int(cfg.get_value("profile", "impacts_total", 0))
	worst_impact_ms = float(cfg.get_value("profile", "worst_impact_ms", 0.0))
	nitro_uses_total = int(cfg.get_value("profile", "nitro_uses_total", 0))
	drift_time_total_s = float(cfg.get_value("profile", "drift_time_total_s", 0.0))


func save_data() -> Error:
	var cfg := ConfigFile.new()
	cfg.set_value("stats", "escapes", escapes)
	cfg.set_value("stats", "arrests", arrests)
	cfg.set_value("stats", "best_escape_time_s", best_escape_time_s)
	cfg.set_value("stats", "longest_pursuit_s", longest_pursuit_s)
	cfg.set_value("stats", "total_distance_km", total_distance_km)
	cfg.set_value("setup", "police_count", last_police_count)
	cfg.set_value("setup", "ai_level", last_ai_level)
	cfg.set_value("profile", "surface_distance_m", surface_distance_m)
	cfg.set_value("profile", "impacts_total", impacts_total)
	cfg.set_value("profile", "worst_impact_ms", worst_impact_ms)
	cfg.set_value("profile", "nitro_uses_total", nitro_uses_total)
	cfg.set_value("profile", "drift_time_total_s", drift_time_total_s)
	return cfg.save(SAVE_PATH)


func record_escape(duration_s: float) -> void:
	escapes += 1
	if best_escape_time_s <= 0.0 or duration_s < best_escape_time_s:
		best_escape_time_s = duration_s
	longest_pursuit_s = maxf(longest_pursuit_s, duration_s)
	save_data()


func record_arrest(duration_s: float) -> void:
	arrests += 1
	longest_pursuit_s = maxf(longest_pursuit_s, duration_s)
	save_data()


func record_distance(km: float) -> void:
	total_distance_km += km
	save_data()


## Distance driven on a surface (accrued by GameState every second).
func record_surface_distance(surface_type: int, meters: float = 1.0) -> void:
	var key := str(surface_type)
	surface_distance_m[key] = float(surface_distance_m.get(key, 0.0)) + meters


## Crash strength in m/s plus how many crashes happened.
func record_impact(strength_ms: float) -> void:
	impacts_total += 1
	worst_impact_ms = maxf(worst_impact_ms, strength_ms)


func record_nitro_used() -> void:
	nitro_uses_total += 1


func record_drift(delta_s: float) -> void:
	drift_time_total_s += delta_s


## Share of the total distance driven on each surface - handy for the README
## screenshot / the profile panel on the main menu.
func surface_share() -> Dictionary:
	var total := 0.0
	for value in surface_distance_m.values():
		total += float(value)
	var shares := {}
	if total <= 0.0:
		return shares
	for key in surface_distance_m.keys():
		shares[key] = float(surface_distance_m[key]) / total
	return shares


func reset() -> void:
	escapes = 0
	arrests = 0
	best_escape_time_s = 0.0
	longest_pursuit_s = 0.0
	total_distance_km = 0.0
	surface_distance_m = {}
	impacts_total = 0
	worst_impact_ms = 0.0
	nitro_uses_total = 0
	drift_time_total_s = 0.0
	save_data()
