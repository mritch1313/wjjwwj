class_name PerformanceManager
extends Node

## Watches the frame time and keeps the game inside the mobile budget
## (autoload "Perf").
##
## Two independent layers of quality control exist:
##   1. the *user* preset (Settings → GraphicsQuality) which is explicit, and
##   2. these runtime scalers, which react to the measured frame time.
## The scalers never touch the user preset - they only shrink work
## (view distance, prop density, AI update rate, particles).

signal scalers_changed(scale: float)

const SAMPLE_COUNT := 90

var target_frame_ms: float = 22.0
var adaptive_enabled: bool = true

## Runtime scalers applied on top of the user preset.
var view_scale: float = 1.0
var prop_density_scale: float = 1.0
var lod_scale: float = 1.0
var particles_allowed: bool = true
var shadows_allowed: bool = true
## Множитель разрешения рендера (1.0 - как в пресете).  Снижается первым: на
## мобильном GPU цена кадра почти линейна по числу пикселей.
var resolution_scale: float = 1.0
var ai_update_stride: int = 1

@export_group("AI budgets (seconds between updates)")
var chase_ai_interval: float = 0.05
var strategic_ai_interval: float = 1.0
var streamer_interval: float = 0.25
## Пауза после понижения качества: без неё автоадаптация «понизил - через
## секунду повысил» заставляла стример пересобирать чанки по кругу, и вместо
## кадров телефон получал бесконечную генерацию.
var upgrade_lock_s: float = 0.0
var lod_interval: float = 0.35

var average_frame_ms: float = 0.0
var worst_frame_ms: float = 0.0
var _samples: PackedFloat32Array = PackedFloat32Array()
var _slow_seconds: float = 0.0
var _fast_seconds: float = 0.0


func _ready() -> void:
	process_priority = -100
	if OS.has_feature("mobile"):
		Engine.max_fps = 60
		Engine.physics_ticks_per_second = 60
	Engine.physics_jitter_fix = 0.0


func set_quality_scale(preset: GraphicsQuality) -> void:
	view_scale = 1.0
	prop_density_scale = 1.0
	lod_scale = 1.0
	particles_allowed = preset.particles_enabled
	shadows_allowed = preset.shadows_enabled
	resolution_scale = 1.0
	ai_update_stride = 1
	# Целевой кадр: 33 мс (30 к/с) на телефоне вместо 22-24 - иначе автоадаптация
	# считает нормальный телефонный кадр "медленным" и бесконечно снижает качество.
	target_frame_ms = 33.0 if OS.has_feature("mobile") else (22.0 if not preset.shadows_enabled else 24.0)


func chase_interval(level: int) -> float:
	return chase_ai_interval * float(ai_update_stride) * (1.0 + 0.15 * float(3 - clampi(level, 1, 3)))


func _process(delta: float) -> void:
	var frame_ms := delta * 1000.0
	if _samples.size() >= SAMPLE_COUNT:
		_samples.remove_at(0)
	_samples.append(frame_ms)
	if not adaptive_enabled:
		return
	var sum := 0.0
	worst_frame_ms = 0.0
	for sample in _samples:
		sum += sample
		worst_frame_ms = maxf(worst_frame_ms, sample)
	average_frame_ms = sum / float(maxi(_samples.size(), 1))
	if _samples.size() < SAMPLE_COUNT:
		return
	if average_frame_ms > target_frame_ms * 1.2 or worst_frame_ms > target_frame_ms * 3.0:
		_slow_seconds += delta
		_fast_seconds = 0.0
	else:
		_fast_seconds += delta
		_slow_seconds = 0.0
	upgrade_lock_s = maxf(upgrade_lock_s - delta, 0.0)
	if _slow_seconds > 2.5:
		_slow_seconds = 0.0
		_degrade()
		upgrade_lock_s = 25.0
	elif _fast_seconds > 12.0:
		_fast_seconds = 0.0
		if upgrade_lock_s <= 0.0:
			_upgrade()


func _degrade() -> void:
	# Порядок важен: сначала тени (самое дорогое на мобильном GPU), затем
	# разрешение, и только потом плотность мира - чтобы игра оставалась похожей
	# на себя, а не превращалась в пустое поле.
	if shadows_allowed:
		shadows_allowed = false
	elif resolution_scale > 0.6:
		resolution_scale = maxf(resolution_scale - 0.15, 0.6)
	elif prop_density_scale > 0.45:
		prop_density_scale = maxf(prop_density_scale - 0.15, 0.45)
	elif lod_scale > 0.65:
		lod_scale = maxf(lod_scale - 0.1, 0.65)
	elif view_scale > 0.65:
		view_scale = maxf(view_scale - 0.1, 0.65)
	elif particles_allowed:
		particles_allowed = false
	elif ai_update_stride < 3:
		ai_update_stride += 1
	else:
		return
	scalers_changed.emit(minf(view_scale, minf(prop_density_scale, lod_scale)))


func _upgrade() -> void:
	# Обратный порядок: сначала возвращаем разрешение и мир, тени - в последнюю
	# очередь (они и стоят дороже всего).
	if ai_update_stride > 1:
		ai_update_stride -= 1
	elif not particles_allowed:
		particles_allowed = true
	elif view_scale < 1.0:
		view_scale = minf(view_scale + 0.1, 1.0)
	elif lod_scale < 1.0:
		lod_scale = minf(lod_scale + 0.1, 1.0)
	elif prop_density_scale < 1.0:
		prop_density_scale = minf(prop_density_scale + 0.1, 1.0)
	elif resolution_scale < 1.0:
		resolution_scale = minf(resolution_scale + 0.15, 1.0)
	elif not shadows_allowed:
		shadows_allowed = Settings.preset().shadows_enabled
		if not shadows_allowed:
			return
	else:
		return
	scalers_changed.emit(minf(view_scale, minf(prop_density_scale, lod_scale)))


func stats() -> Dictionary:
	return {
		"fps": Engine.get_frames_per_second(),
		"frame_ms": snappedf(average_frame_ms, 0.01),
		"worst_ms": snappedf(worst_frame_ms, 0.01),
		"view_scale": snappedf(view_scale, 0.01),
		"resolution_scale": snappedf(resolution_scale, 0.01),
		"shadows": shadows_allowed,
		"prop_scale": snappedf(prop_density_scale, 0.01),
		"lod_scale": snappedf(lod_scale, 0.01),
		"ai_stride": ai_update_stride,
		"particles": particles_allowed,
	}
