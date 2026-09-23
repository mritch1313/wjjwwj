extends TestCase

## Support systems that the rest of the game leans on: the code-built mesh
## builder (there is no SurfaceTool in the pipeline), the object pool, the string
## table, settings persistence and the vehicle model factory.

func test_mesh_builder_creates_surfaces_per_material() -> void:
	var builder := MeshBuilder.new()
	builder.add_quad("grass", Vector3(0, 0, 0), Vector3(4, 0, 0), Vector3(4, 0, 4), Vector3(0, 0, 4))
	builder.add_box("concrete_wall", Transform3D(Basis(), Vector3.ZERO), Vector3(1, 1, 1))
	var mesh := builder.commit()
	assert_ne(mesh, null, "меш собран")
	assert_gt(float((mesh as ArrayMesh).get_surface_count()), 0.0, "есть хотя бы одна поверхность")


func test_mesh_builder_falls_back_on_an_unknown_material() -> void:
	# Неизвестное имя материала не должно ломать сборку меша: библиотека
	# подставляет бетон и предупреждает (имя ниже намеренно ненастоящее).
	var builder := MeshBuilder.new()
	builder.add_box("__material_that_does_not_exist__", Transform3D(Basis(), Vector3.ZERO), Vector3.ONE)
	var mesh := builder.commit()
	assert_ne(mesh, null, "меш с неизвестным материалом всё равно собирается")
	assert_eq((mesh as ArrayMesh).get_surface_count(), 1, "поверхность создана с запасным материалом")


func test_mesh_builder_vertex_and_index_counts_match_the_shapes() -> void:
	var builder := MeshBuilder.new()
	builder.add_quad("grass", Vector3.ZERO, Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1))
	var mesh := builder.commit()
	var arrays: Array = (mesh as ArrayMesh).surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	assert_eq(vertices.size(), 6, "квад - это два треугольника (6 вершин без индексации)")
	assert_eq(builder.triangle_count, 2, "счётчик треугольников честный")
	# the quad must span exactly the requested square
	var box := AABB(vertices[0], Vector3.ZERO)
	for vertex in vertices:
		box = box.expand(vertex)
	assert_almost_eq(box.size.x, 1.0, 0.001, "ширина квада соблюдена")
	assert_almost_eq(box.size.z, 1.0, 0.001, "длина квада соблюдена")


func test_mesh_builder_box_is_closed() -> void:
	var builder := MeshBuilder.new()
	builder.add_box("facade_brick_a", Transform3D(Basis(), Vector3(0, 1.5, 0)), Vector3(2, 3, 4))
	var mesh := builder.commit()
	var arrays: Array = (mesh as ArrayMesh).surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	assert_ge(float(builder.triangle_count), 12.0, "коробка состоит минимум из 12 треугольников")
	var box := AABB(vertices[0], Vector3.ZERO)
	for vertex in vertices:
		box = box.expand(vertex)
	assert_almost_eq(box.size.y, 3.0, 0.01, "высота коробки соблюдена")


func test_append_builder_merges_geometry() -> void:
	var a := MeshBuilder.new()
	a.add_quad("grass", Vector3.ZERO, Vector3(1, 0, 0), Vector3(1, 0, 1), Vector3(0, 0, 1))
	var b := MeshBuilder.new()
	b.add_quad("grass", Vector3(2, 0, 0), Vector3(3, 0, 0), Vector3(3, 0, 1), Vector3(2, 0, 1))
	a.append_builder(b)
	var mesh := a.commit()
	var arrays: Array = (mesh as ArrayMesh).surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	assert_eq(vertices.size(), 12, "после слияния два квада (12 вершин)")
	var box := AABB(vertices[0], Vector3.ZERO)
	for vertex in vertices:
		box = box.expand(vertex)
	assert_almost_eq(box.size.x, 3.0, 0.01, "слияние сохранило обе части")


func test_vehicle_model_factory_builds_a_car_body() -> void:
	var builder := MeshBuilder.new()
	VehicleModelFactory.build_car(builder, Transform3D(), Config.vehicle_player, VehicleModelFactory.Role.POLICE, 0, test_rng(1), "car_body_police", true)
	var mesh := builder.commit()
	assert_ne(mesh, null, "модель машины собирается")
	var arrays: Array = (mesh as ArrayMesh).surface_get_arrays(0)
	var vertices: PackedVector3Array = arrays[Mesh.ARRAY_VERTEX]
	assert_gt(float(vertices.size()), 200.0, "машина состоит из многих деталей, а не из куба")
	var box := AABB(vertices[0], Vector3.ZERO)
	for vertex in vertices:
		box = box.expand(vertex)
	assert_between(box.size.x, 1.4, 2.6, "ширина машины реалистична")
	assert_between(box.size.z, 3.4, 5.6, "длина машины реалистична")
	assert_between(box.size.y, 0.9, 2.2, "высота машины реалистична")


## LOD машины должен реально снижать нагрузку, а не быть галочкой: каждый
## следующий уровень обязан быть дешевле предыдущего на измеримую величину.
func test_vehicle_visual_lod_reduces_the_model() -> void:
	var counts: Array[int] = []
	for lod in [0, 1, 2]:
		var builder := MeshBuilder.new()
		VehicleModelFactory.build_car(builder, Transform3D(), Config.vehicle_police,
			VehicleModelFactory.Role.POLICE, lod, test_rng(7), "car_body_police", true)
		builder.commit()
		counts.append(builder.triangle_count)
	print("       LOD машины: lod0 %d, lod1 %d, lod2 %d треугольников" % [counts[0], counts[1], counts[2]])
	assert_lt(float(counts[1]), float(counts[0]), "LOD1 легче LOD0")
	assert_lt(float(counts[2]), float(counts[1]) * 0.7, "LOD2 (силуэт) заметно легче LOD1")
	assert_lt(float(counts[2]), float(counts[0]) * 0.35, "LOD2 дешевле LOD0 минимум втрое")
	# колесо тоже упрощается (14 сегментов против 6)
	var rich := MeshBuilder.new()
	VehicleModelFactory.build_wheel(rich, Config.vehicle_police, 0)
	rich.commit()
	var cheap := MeshBuilder.new()
	VehicleModelFactory.build_wheel(cheap, Config.vehicle_police, 2)
	cheap.commit()
	assert_lt(float(cheap.triangle_count), float(rich.triangle_count), "колесо дальнего LOD дешевле")


func test_police_visual_lod_follows_the_distance() -> void:
	assert_eq(PoliceManager.visual_lod_for_distance(10.0), 0, "рядом с игроком - полная модель")
	assert_eq(PoliceManager.visual_lod_for_distance(PoliceManager.LOD_MID_DISTANCE_M), 0,
		"на границе среднего уровня модель ещё полная")
	assert_eq(PoliceManager.visual_lod_for_distance(PoliceManager.LOD_MID_DISTANCE_M + 1.0), 1,
		"за границей - средний уровень")
	assert_eq(PoliceManager.visual_lod_for_distance(PoliceManager.LOD_FAR_DISTANCE_M + 1.0), 2,
		"далеко - силуэт")


func test_object_pool_reuses_nodes() -> void:
	var created := [0]
	var pool := ObjectPool.new(func() -> Node:
		created[0] += 1
		return Node3D.new()
	)
	var first := pool.acquire()
	pool.release(first)
	var second := pool.acquire()
	assert_eq(first, second, "пул переиспользует узел, а не создаёт новый")
	assert_eq(created[0], 1, "фабрика вызвана один раз")
	assert_eq(pool.created_count(), 1, "счётчик созданных узлов честный")
	# Nodes are not reference counted: the test owns the pooled node and has to
	# release it, otherwise the head-less run reports it as a leaked instance.
	second.free()


func test_localisation_tables_are_complete_and_fall_back() -> void:
	var ru_keys: Array = L10n.STRINGS["ru"].keys()
	var en_keys: Array = L10n.STRINGS["en"].keys()
	for key in ru_keys:
		assert_true(en_keys.has(key), "английский перевод есть для ключа %s" % key)
	for key in en_keys:
		assert_true(ru_keys.has(key), "русский перевод есть для ключа %s" % key)
	assert_eq(L10n.t("start_pursuit"), "НАЧАТЬ ПОГОНЮ", "русский - язык по умолчанию")
	assert_eq(L10n.t_for("start_pursuit", "en"), "START PURSUIT", "английский доступен")
	assert_eq(L10n.t("нет_такого_ключа"), "нет_такого_ключа", "отсутствующий ключ не ломает UI")
	assert_eq(L10n.t("pursuit_started") % 3, "ПОГОНЯ НАЧАЛАСЬ: 3 машин", "подстановка числа машин работает")


func test_graphics_quality_presets_are_ordered() -> void:
	var low := GraphicsQuality.low()
	var medium := GraphicsQuality.medium()
	var high := GraphicsQuality.high()
	assert_lt(low.view_distance_m, medium.view_distance_m, "LOW видит ближе MEDIUM")
	assert_lt(medium.view_distance_m, high.view_distance_m, "MEDIUM видит ближе HIGH")
	assert_lt(low.max_chunks_loaded, high.max_chunks_loaded, "HIGH держит больше чанков")
	assert_false(low.glow, "LOW без тяжёлых эффектов")
	assert_le(low.shadow_map_size, high.shadow_map_size, "тени на LOW дешевле")
	assert_eq(GraphicsQuality.count(), 3, "ровно три предустановки графики")


func test_settings_persist_between_loads() -> void:
	Settings.hud_scale = 1.15
	Settings.auto_accelerate = true
	Settings.steering_mode = SettingsManager.SteeringMode.WHEEL
	Settings.police_count = 4
	Settings.ai_level = 3
	Settings.save_now()
	Settings.hud_scale = 1.0
	Settings.auto_accelerate = false
	Settings.steering_mode = SettingsManager.SteeringMode.BUTTONS
	Settings.police_count = 1
	Settings.ai_level = 1
	Settings._load()
	assert_almost_eq(Settings.hud_scale, 1.15, 0.001, "масштаб HUD сохраняется")
	assert_true(Settings.auto_accelerate, "автогаз сохраняется")
	assert_eq(Settings.steering_mode, SettingsManager.SteeringMode.WHEEL, "режим руля сохраняется")
	assert_eq(Settings.police_count, 4, "число машин полиции сохраняется")
	assert_eq(Settings.ai_level, 3, "уровень ИИ сохраняется")
	# restore sensible defaults for the rest of the run
	Settings.hud_scale = 1.0
	Settings.auto_accelerate = false
	Settings.steering_mode = SettingsManager.SteeringMode.BUTTONS
	Settings.police_count = 3
	Settings.ai_level = 2
	Settings.save_now()


## ТЗ требует вертикальный экран: режим по умолчанию обязан жёстко включать
## портрет, а не «как повернётся» (сенсор), иначе игра снова открывается боком.
func test_screen_orientation_defaults_to_portrait() -> void:
	var saved := Settings.orientation_mode
	Settings.orientation_mode = 0
	assert_eq(Settings.orientation_constant(), DisplayServer.SCREEN_PORTRAIT,
		"по умолчанию экран вертикальный")
	Settings.orientation_mode = 1
	assert_eq(Settings.orientation_constant(), DisplayServer.SCREEN_LANDSCAPE,
		"второй режим кнопки - горизонтальный")
	Settings.orientation_mode = 2
	assert_eq(Settings.orientation_constant(), DisplayServer.SCREEN_SENSOR,
		"третий режим кнопки - автоповорот")
	Settings.orientation_mode = saved


func test_save_manager_records_the_driving_profile() -> void:
	var before_km := Save.total_distance_km
	Save.record_distance(1.5)
	assert_almost_eq(Save.total_distance_km, before_km + 1.5, 0.001, "пройденные километры копятся")
	Save.record_surface_distance(Surface.Type.GRAVEL, 250.0)
	assert_gt(float(Save.surface_distance_m.get(str(Surface.Type.GRAVEL), 0.0)), 249.0, "дистанция по поверхности учтена")
	Save.record_impact(12.0)
	assert_gt(float(Save.impacts_total), 0.0, "удары считаются")
	Save.save_data()
	var loaded := SaveManager.new()
	loaded.load_data()
	assert_almost_eq(loaded.total_distance_km, Save.total_distance_km, 0.001, "профиль читается обратно с диска")
	assert_eq(loaded.impacts_total, Save.impacts_total, "счётчик ударов сохраняется")
	loaded.free()


func test_surface_types_have_friction_and_names() -> void:
	for surface in Surface.ALL_TYPES:
		assert_gt(Surface.name_of(surface).length(), 0, "у типа поверхности %d есть имя" % surface)
		assert_between(Surface.default_friction(surface), 0.3, 1.6, "коэффициент сцепления %s в разумных пределах" % Surface.name_of(surface))
	assert_gt(Surface.default_friction(Surface.Type.ASPHALT), Surface.default_friction(Surface.Type.MUD), "асфальт держит лучше грязи")
	assert_true(Surface.is_paved(Surface.Type.ASPHALT), "асфальт - покрытие")
	assert_false(Surface.is_paved(Surface.Type.SAND), "песок - не покрытие")
