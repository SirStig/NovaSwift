# Headless check of the game-data importer + Data Setup wizard + no-data gate.
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/data_import_selfcheck.gd
#
# Builds a fake Windows-CE-style install in a scratch dir from SYMLINKS to data/base (read-only: the real
# data is never written; the scratch dir is removed with `rm -rf`, which unlinks symlinks without following
# them). Needs the rebuilt bridge for the data_import_* parts (SKIP lines otherwise) and a POSIX shell for
# the symlinks (the import parts SKIP on Windows).
extends SceneTree

const Prefs = preload("res://Prefs.gd")
const Controls = preload("res://Controls.gd")
const Importer = preload("res://DataImporter.gd")
const Scanner = preload("res://DataScanner.gd")
const Browser = preload("res://ui/novaswift/DataFileBrowser.gd")
const Shell = preload("res://screens/Shell.gd")
const GameAudio = preload("res://audio/GameAudio.gd")

var _fails := 0
var _tmp := ""


func _ok(cond: bool, what: String) -> void:
	print(("PASS " if cond else "FAIL ") + what)
	if not cond:
		_fails += 1


func _write(path: String, text: String) -> void:
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_string(text)
	f.close()


func _base() -> String:
	var env := OS.get_environment("NOVA_DATA_DIR")
	if env != "" and DirAccess.dir_exists_absolute(env.path_join("Nova Files")):
		return env.path_join("Nova Files")
	var repo := ProjectSettings.globalize_path("res://") + "../data/base/Nova Files"
	return repo.simplify_path()


## Poll `fn` (returns Dictionary with "done") until done or timeout.
func _wait(status_fn: Callable, seconds: float) -> Dictionary:
	var t0 := Time.get_ticks_msec()
	var st: Dictionary = {}
	while (Time.get_ticks_msec() - t0) < int(seconds * 1000.0):
		st = Importer.parse(status_fn.call())
		if bool(st.get("done", false)):
			break
		await process_frame
		OS.delay_msec(10)
	return st


func _init() -> void:
	Prefs.path = OS.get_user_data_dir() + "/data_import_check_settings.cfg"
	DirAccess.remove_absolute(Prefs.path)
	Prefs.load_all()
	Controls.register()
	_tmp = OS.get_user_data_dir() + "/di_check_%d" % Time.get_ticks_msec()
	DirAccess.make_dir_recursive_absolute(_tmp)

	# --- managed location ----------------------------------------------------------------------
	OS.set_environment("NOVA_DATA_IMPORT_DIR", "")
	var managed := Prefs.managed_data_dir()
	_ok(managed.ends_with("NovaSwift/data") or managed.ends_with("/data"), "managed dir default: " + managed)
	OS.set_environment("NOVA_DATA_IMPORT_DIR", _tmp + "/managed")
	_ok(Prefs.managed_data_dir() == _tmp + "/managed", "NOVA_DATA_IMPORT_DIR overrides the managed dir")
	_ok(Prefs.data_candidates().has(_tmp + "/managed"), "the managed dir is a data candidate")
	Prefs.add_recent_source("/a")
	Prefs.add_recent_source("/b")
	Prefs.add_recent_source("/a")
	_ok(Prefs.recent_sources()[0] == "/a" and Prefs.recent_sources().size() == 2, "recent sources: newest first, de-duplicated")

	# --- browser path maths ----------------------------------------------------------------------
	_ok(Browser.parent_of("/a/b/c") == "/a/b" and Browser.parent_of("/a") == "/" and Browser.parent_of("/") == "/", "browser parent_of (posix)")
	_ok(Browser.parent_of("C:/Games/EV Nova") == "C:/Games" and Browser.parent_of("C:/Games") == "C:/" and Browser.parent_of("C:/") == "C:/", "browser parent_of (windows drive)")

	# --- fake install layout ---------------------------------------------------------------------
	var base_files := _base()
	var have_base := DirAccess.dir_exists_absolute(base_files)
	var fake := _tmp + "/Downloads/EV Nova Windows"
	var posix := OS.get_name() != "Windows"
	if have_base and posix:
		_write(fake + "/EV Nova.exe", "MZ")
		_write(fake + "/EVNova.ini", "[x]")
		_write(fake + "/Nova Plug-ins/Test Plug/Test.rez", "not a real container")
		DirAccess.make_dir_recursive_absolute(fake + "/Nova Files")
		var d := DirAccess.open(base_files)
		d.list_dir_begin()
		var n := d.get_next()
		while n != "":
			if not d.current_is_dir():
				OS.execute("ln", ["-s", base_files.path_join(n), (fake + "/Nova Files").path_join(n)])
			n = d.get_next()
		d.list_dir_end()
		_write(fake + "/Charcoal.ttf", "font")

	# --- scanner ---------------------------------------------------------------------------------
	if have_base and posix:
		var sc := Scanner.new([{"path": _tmp, "depth": 4}])
		var guard := 0
		while sc.step(8) and guard < 500:
			guard += 1
		var hit := false
		for f in sc.found:
			if str(f["path"]) == fake:
				hit = true
		_ok(hit, "scanner finds the fake install (%d visited, %d found)" % [sc.visited, sc.found.size()])
		_ok(Importer.looks_like_install(fake) == "install", "looks_like_install: a folder holding Nova Files")
		_ok(Importer.looks_like_install(fake + "/Nova Files") == "files", "looks_like_install: a folder holding Nova Data files")

	# --- bridge: inspect / import ----------------------------------------------------------------
	var nova = ClassDB.instantiate("NovaWorld") if ClassDB.class_exists("NovaWorld") else null
	if nova == null or not nova.has_method("data_import_inspect") or not have_base or not posix:
		print("SKIP bridge import checks (rebuilt bridge, data/base and a POSIX shell needed)")
		_cleanup()
		print("RESULT: ", "ALL PASS" if _fails == 0 else "%d FAIL" % _fails)
		quit(_fails)
		return
	root.add_child(nova)

	var ins: Dictionary = Importer.parse(nova.data_import_inspect(fake, false))
	_ok(str(ins.get("layout", "")) == "windows-ce", "quick inspect: Windows CE layout (%s)" % str(ins.get("layout_label", "")))
	_ok((ins.get("base_files", []) as Array).size() >= 20, "quick inspect: %d data files" % (ins.get("base_files", []) as Array).size())
	_ok((ins.get("audio_files", []) as Array).has("Nova Music.mp3"), "quick inspect: music found")
	_ok((ins.get("font_files", []) as Array).has("Charcoal.ttf") and bool(ins.get("has_ini", false)), "quick inspect: font + EVNova.ini")
	_ok((ins.get("plugin_folders", []) as Array).size() == 1, "quick inspect: the Nova Plug-ins folder is kept apart from base data")
	_ok(not (ins.get("base_files", []) as Array).has("Test.rez"), "quick inspect: plug-in files are not base files")
	var nonexist: Dictionary = Importer.parse(nova.data_import_inspect(_tmp + "/nope", false))
	_ok(str(nonexist.get("error", "")) != "", "inspecting a missing path reports an error")

	# Deep inspect on the worker thread.
	_ok(nova.data_import_inspect_start(fake), "deep inspect starts")
	var ist: Dictionary = await _wait(func(): return nova.data_import_inspect_status(), 120.0)
	var res: Dictionary = ist.get("result", {})
	_ok(bool(res.get("valid", false)), "deep inspect: valid (%s)" % str(res.get("version", "")))
	_ok(int(res.get("resource_count", 0)) > 1000, "deep inspect: %d resources parsed" % int(res.get("resource_count", 0)))

	# An incomplete set (a single .rez) must not validate.
	var lone: Dictionary = Importer.parse(nova.data_import_inspect(base_files.path_join("Nova Data 1.rez"), true))
	_ok(str(lone.get("layout", "")) == "file" and not bool(lone.get("valid", true)), "a single data file inspects as incomplete, not valid")

	# --- import into a managed dir, atomically ---------------------------------------------------
	var dest := _tmp + "/managed"
	_ok(nova.data_import_start(fake, dest, true), "import starts")
	var st: Dictionary = await _wait(func(): return nova.data_import_status(), 300.0)
	_ok(bool(st.get("ok", false)), "import finished ok (%s)" % str(st.get("error", "")))
	_ok(FileAccess.file_exists(dest + "/Nova Data 1.rez") and FileAccess.file_exists(dest + "/Nova Music.mp3"), "data + music copied flat into the managed dir")
	_ok(FileAccess.file_exists(dest + "/Nova Plug-ins/Test Plug/Test.rez"), "plug-in folder copied under Nova Plug-ins/")
	_ok(FileAccess.file_exists(dest + "/Charcoal.ttf") and FileAccess.file_exists(dest + "/EVNova.ini"), "font and EVNova.ini copied")
	var leftovers := 0
	var hidden := DirAccess.open(_tmp)
	hidden.include_hidden = true
	for e in hidden.get_directories():
		if e.begins_with(".managed."):
			leftovers += 1
	_ok(leftovers == 0, "no temp/old directories left beside the managed dir")
	_ok(nova.load_game(dest), "the imported copy loads in the engine")

	# --- failed re-import keeps the previous data --------------------------------------------------
	_write(dest + "/MARKER.txt", "keep me")
	_ok(nova.data_import_start(base_files.path_join("Nova Data 1.rez"), dest, true), "re-import of an incomplete set starts")
	var bad: Dictionary = await _wait(func(): return nova.data_import_status(), 120.0)
	_ok(not bool(bad.get("ok", true)) and str(bad.get("error", "")) != "", "incomplete re-import is refused (%s)" % str(bad.get("error", "")).left(70))
	_ok(FileAccess.file_exists(dest + "/MARKER.txt") and FileAccess.file_exists(dest + "/Nova Data 1.rez"), "...and the previous data is untouched")

	# --- cancel ----------------------------------------------------------------------------------
	var dest2 := _tmp + "/managed2"
	_ok(nova.data_import_start(fake, dest2, true), "second import starts")
	nova.data_import_cancel()
	var cst: Dictionary = await _wait(func(): return nova.data_import_status(), 300.0)
	_ok(bool(cst.get("done", false)) and (bool(cst.get("cancelled", false)) or bool(cst.get("ok", false))), "cancel ends the job (cancelled=%s ok=%s)" % [str(cst.get("cancelled")), str(cst.get("ok"))])
	if bool(cst.get("cancelled", false)):
		_ok(not DirAccess.dir_exists_absolute(dest2), "a cancelled import leaves no destination folder")

	# --- the no-data gate --------------------------------------------------------------------------
	var audio = GameAudio.new()
	root.add_child(audio)
	audio.setup(nova)
	var shell = Shell.new()
	root.add_child(shell)
	shell.setup(nova, audio)
	shell.data_dir = ""
	shell._after_data_search()
	await process_frame
	await process_frame
	_ok(shell.data_setup != null and shell.main_menu == null and not shell.has_data, "no data: only the Data Setup wizard is shown (no main menu)")
	_ok(shell.data_setup.gated and shell.data_setup.step == "welcome", "...gated, on the welcome page")
	_ok(shell.pilot_menu == null and shell.story_map == null, "...no pilot menu / story map")
	shell.data_setup._go("ownership")
	shell.data_setup._back()
	_ok(shell.data_setup.step == "welcome", "wizard Back returns to the previous page")
	shell.data_setup._back()
	_ok(shell.data_setup != null, "Back at the first page does nothing while gated")
	_ok(shell.data_setup.dialog.buttons.has("Quit"), "welcome offers Quit")

	_cleanup()
	print("RESULT: ", "ALL PASS" if _fails == 0 else "%d FAIL" % _fails)
	quit(_fails)


func _cleanup() -> void:
	OS.set_environment("NOVA_DATA_IMPORT_DIR", "")
	if _tmp.contains("di_check_") and OS.get_name() != "Windows":
		OS.execute("rm", ["-rf", _tmp])   # unlinks the symlinks, never follows them
