extends Node

## Head-less test runner: `godot --headless --path . res://tests/test_runner.tscn`.
##
## It loads every tests/unit/test_*.gd, instantiates it, runs all `test_*`
## methods and prints a per-test summary.  The process exits with a non-zero
## code when anything failed, which is what the GitHub Actions "headless tests"
## job checks.  No test framework addon is required (there is no network access
## in the build environment).

const TEST_DIRS := ["res://tests/unit/", "res://tests/integration/"]

var total_tests: int = 0
var total_checks: int = 0
var failed_tests: int = 0
var failed_files: Dictionary = {}
var elapsed_per_file: Dictionary = {}


func _ready() -> void:
	print("=== Chase tests (Godot %s) ===" % Engine.get_version_info()["string"])
	var files := _test_files()
	if files.is_empty():
		print("НЕ НАЙДЕНО ни одного теста в %s" % str(TEST_DIRS))
		get_tree().quit(2)
		return
	for file in files:
		_run_file(file)
	_report()
	get_tree().quit(1 if failed_tests > 0 else 0)


func _test_files() -> PackedStringArray:
	var result := PackedStringArray()
	for directory in TEST_DIRS:
		var dir := DirAccess.open(directory)
		if dir == null:
			continue
		dir.list_dir_begin()
		var name := dir.get_next()
		while name != "":
			if not dir.current_is_dir() and name.begins_with("test_") and name.ends_with(".gd"):
				result.append(directory + name)
			name = dir.get_next()
		dir.list_dir_end()
	result.sort()
	return result


func _run_file(path: String) -> void:
	var script: GDScript = load(path)
	if script == null:
		_fail_file(path, "скрипт не загружается", 0)
		return
	var instance: Object = script.new()
	if instance == null:
		_fail_file(path, "не удалось создать экземпляр теста", 0)
		return
	if instance.has_method("before_all"):
		instance.call("before_all")
	var method_names: PackedStringArray = PackedStringArray()
	for method in instance.get_method_list():
		var method_name: String = method["name"]
		if method_name.begins_with("test_") and not method_names.has(method_name):
			method_names.append(method_name)
	method_names.sort()
	if method_names.is_empty():
		_fail_file(path, "нет методов test_*", 0)
		if instance.has_method("after_all"):
			instance.call("after_all")
		return
	var started := Time.get_ticks_msec()
	var file_failures: PackedStringArray = PackedStringArray()
	var file_checks := 0
	var has_before_each: bool = instance.has_method("before_each")
	var has_after_each: bool = instance.has_method("after_each")
	for method_name in method_names:
		instance.set("current_test", method_name)
		instance.set("failures", PackedStringArray())
		if has_before_each:
			instance.call("before_each")
		var before := int(instance.get("checks"))
		instance.call(method_name)
		if has_after_each:
			instance.call("after_each")
		var checks_done := int(instance.get("checks")) - before
		file_checks += checks_done
		total_tests += 1
		total_checks += checks_done
		var failures: PackedStringArray = instance.get("failures")
		if failures.is_empty():
			print("  ok   %s::%s (%d проверок)" % [path.get_file(), method_name, checks_done])
		else:
			for failure in failures:
				file_failures.append(failure)
			print("  FAIL %s::%s" % [path.get_file(), method_name])
	if instance.has_method("after_all"):
		instance.call("after_all")
	elapsed_per_file[path] = Time.get_ticks_msec() - started
	if not file_failures.is_empty():
		failed_tests += 1
		failed_files[path] = file_failures
		for failure in file_failures:
			print("       -> %s" % failure)


func _fail_file(path: String, reason: String, checks: int) -> void:
	failed_tests += 1
	failed_files[path] = PackedStringArray([reason])
	print("  FAIL %s: %s" % [path.get_file(), reason])
	total_checks += checks


func _report() -> void:
	print("---")
	for path in elapsed_per_file.keys():
		print("  %s: %d мс" % [String(path).get_file(), int(elapsed_per_file[path])])
	print("Файлов тестов: %d   проверок: %d   неудачных тестов: %d" % [elapsed_per_file.size(), total_checks, failed_tests])
	if failed_tests == 0:
		print("TESTS PASSED")
	else:
		print("TESTS FAILED")
