class_name GameState
extends Node

## Top level game flow (autoload "Game"): free roam <-> pursuit <-> result.
## It owns no gameplay logic itself; it coordinates the systems that do
## (WorldStreamer, VehicleController, PoliceManager, HUD).

signal state_changed(new_state: int)
signal pursuit_started(police_count: int, ai_level: int)
signal pursuit_ended(reason: String, duration_s: float)
signal setup_changed(police_count: int, ai_level: int)
signal toast(message: String)

enum State { BOOT, FREE_ROAM, PURSUIT, ARRESTED, ESCAPED }

var state: int = State.BOOT
var pursuit_time_s: float = 0.0
var last_pursuit_duration_s: float = 0.0
var total_distance_m: float = 0.0
var last_save_distance_m: float = 0.0

var world: Node = null
var player: Node = null
var chase_camera: Node = null
var police_manager: Node = null
var hud: Node = null

## Free-form shared state (small values only - counters, flags, last event
## positions).  Used by the HUD, the AI and the progression layer so they do not
## have to know about each other.
var registry: Dictionary = {}

var _report_timer: float = 0.0
var _surface_flush_timer: float = 0.0
var _surface_distance_accum_m: float = 0.0
var _police_report_timer: float = 0.0
var _last_impact_time_s: float = -100.0


func _ready() -> void:
	set_process(true)


func _process(delta: float) -> void:
	if state == State.PURSUIT:
		pursuit_time_s += delta
	_report_timer += delta
	if _report_timer > 30.0:
		_report_timer = 0.0
		var travelled_km := (total_distance_m - last_save_distance_m) / 1000.0
		if travelled_km > 0.25:
			last_save_distance_m = total_distance_m
			Save.record_distance(travelled_km)


func _physics_process(delta: float) -> void:
	if player != null and is_instance_valid(player):
		var speed: float = player.call("forward_speed_ms") if player.has_method("forward_speed_ms") else 0.0
		total_distance_m += absf(speed) * delta
		var position: Vector3 = player.global_position
		if position.y < Config.gameplay.fall_out_of_world_height:
			player.call("recover_to_road")
			toast.emit(L10n.t("world_recovered"))
		# surface distance profile (flushed every 20 s, not every frame)
		_surface_distance_accum_m += absf(speed) * delta
		_surface_flush_timer += delta
		if _surface_flush_timer >= 20.0:
			_surface_flush_timer = 0.0
			if _surface_distance_accum_m > 1.0:
				Save.record_surface_distance(int(registry.get("player_surface", Surface.Type.ASPHALT)), _surface_distance_accum_m)
				_surface_distance_accum_m = 0.0


## ---------------------------------------------------------------- registry --
func register_world(node: Node) -> void:
	world = node


func register_player(node: Node) -> void:
	player = node


func register_camera(node: Node) -> void:
	chase_camera = node


func register_police_manager(node: Node) -> void:
	police_manager = node
	if node != null:
		if node.has_signal("player_caught") and not node.player_caught.is_connected(_on_police_caught):
			node.player_caught.connect(_on_police_caught)
		if node.has_signal("player_escaped") and not node.player_escaped.is_connected(_on_police_escaped):
			node.player_escaped.connect(_on_police_escaped)


func _on_police_caught() -> void:
	if state == State.PURSUIT:
		stop_pursuit("arrested")


func _on_police_escaped() -> void:
	if state == State.PURSUIT:
		stop_pursuit("escaped")


func register_hud(node: Node) -> void:
	hud = node


## ------------------------------------------------------------- game flow --
func begin_free_roam() -> void:
	_set_state(State.FREE_ROAM)


func start_pursuit(police_count: int = -1, ai_level: int = -1) -> void:
	var gameplay := Config.gameplay
	# A negative value means "use what the player picked in the menu"; anything else
	# is clamped to the allowed range, so start_pursuit(0) really means one car.
	var count := police_count if police_count >= 0 else Settings.police_count
	var level := ai_level if ai_level >= 0 else Settings.ai_level
	count = clampi(count, gameplay.min_police_count, gameplay.max_police_count)
	level = clampi(level, 1, Config.police.level_count())
	Settings.police_count = count
	Settings.ai_level = level
	Save.last_police_count = count
	Save.last_ai_level = level
	Save.save_data()
	setup_changed.emit(count, level)
	if police_manager != null and police_manager.has_method("start_pursuit"):
		police_manager.start_pursuit(count, level)
	pursuit_time_s = 0.0
	_set_state(State.PURSUIT)
	pursuit_started.emit(count, level)
	toast.emit(L10n.t("pursuit_started") % count)


func stop_pursuit(reason: String) -> void:
	if police_manager != null and police_manager.has_method("stop_pursuit"):
		police_manager.stop_pursuit()
	var duration := pursuit_time_s
	last_pursuit_duration_s = duration
	pursuit_time_s = 0.0
	if reason == "arrested":
		Save.record_arrest(duration)
		_set_state(State.ARRESTED)
	else:
		Save.record_escape(duration)
		_set_state(State.ESCAPED)
	pursuit_ended.emit(reason, duration)


func back_to_free_roam() -> void:
	if police_manager != null and police_manager.has_method("clear_police"):
		police_manager.clear_police()
	_set_state(State.FREE_ROAM)
	toast.emit(L10n.t("back_to_free_roam"))


func set_ai_level(level: int) -> void:
	var clamped := clampi(level, 1, Config.police.level_count())
	Settings.ai_level = clamped
	if police_manager != null and police_manager.has_method("set_ai_level"):
		police_manager.set_ai_level(clamped)
	setup_changed.emit(Settings.police_count, clamped)
	Settings.save_now()


func set_police_count(count: int) -> void:
	var clamped := clampi(count, Config.gameplay.min_police_count, Config.gameplay.max_police_count)
	Settings.police_count = clamped
	if police_manager != null and police_manager.has_method("set_police_count"):
		police_manager.set_police_count(clamped)
	setup_changed.emit(clamped, Settings.ai_level)
	Settings.save_now()


func is_pursuit_active() -> bool:
	return state == State.PURSUIT


func active_police_count() -> int:
	if police_manager != null and police_manager.has_method("active_count"):
		return police_manager.active_count()
	return 0


func pursuit_status() -> Dictionary:
	if police_manager != null and police_manager.has_method("status"):
		return police_manager.status()
	return {}


func _set_state(new_state: int) -> void:
	if state == new_state:
		return
	state = new_state
	state_changed.emit(new_state)


## --------------------------------------------------------- event reporting --
## The player car reports what it is doing; the progression layer / HUD read it
## from the registry so the vehicle code stays free of UI and save logic.
func registry_set(key: String, value: Variant) -> void:
	registry[key] = value


func registry_get(key: String, default_value: Variant = null) -> Variant:
	return registry.get(key, default_value)


func on_player_surface(surface_type: int) -> void:
	registry["player_surface"] = surface_type


func on_player_drift(delta_s: float) -> void:
	Save.record_drift(delta_s)


func on_player_impact(strength: float, surface_type: int) -> void:
	if strength < 3.0:
		return
	registry["last_impact_strength"] = strength
	registry["last_impact_surface"] = surface_type
	var now := Time.get_ticks_msec() / 1000.0
	if now - _last_impact_time_s > 1.0:
		_last_impact_time_s = now
		Save.record_impact(strength)


func on_nitro_used() -> void:
	registry["nitro_used_at"] = Time.get_ticks_msec() / 1000.0
	Save.record_nitro_used()


func on_police_contact(index: int) -> void:
	registry["last_police_contact"] = index


## Called by the police manager through the signal, but also usable directly.
func arrest_player() -> void:
	stop_pursuit("arrested")


func maybe_report_pursuit_toast() -> void:
	# keeps at most one "police is close" message per 12 seconds
	var now := Time.get_ticks_msec() / 1000.0
	if now - _police_report_timer < 12.0:
		return
	_police_report_timer = now
	toast.emit(L10n.t("police_nearby"))
