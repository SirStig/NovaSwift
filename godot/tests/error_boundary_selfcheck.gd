# Headless check of the error boundary (Boot guard, ErrorScreen, CrashLogger storm detector, report URL).
#   godot --headless --path godot -s res://tests/error_boundary_selfcheck.gd
# Uses only the standalone ui/Error*.gd + CrashLogger.gd + Boot.gd -- no game scripts are loaded for the
# ErrorScreen part, which is the point.
extends SceneTree

const CrashLogger = preload("res://ui/CrashLogger.gd")
const ErrorReport = preload("res://ui/ErrorReport.gd")
const ErrorScreen = preload("res://ui/ErrorScreen.gd")
const BootScript = preload("res://Boot.gd")

var _fails: int = 0


func _ok(cond: bool, what: String) -> void:
	print(("PASS " if cond else "FAIL ") + what)
	if not cond:
		_fails += 1


func _init() -> void:
	_check_boot()
	_check_screen()
	_check_storm()
	_check_url()
	print("error_boundary_selfcheck: %s" % ("FAILED (%d)" % _fails if _fails > 0 else "ok"))
	quit(1 if _fails > 0 else 0)


func _boot() -> Control:
	var b: Control = BootScript.new() as Control
	b.set("auto_start", false)
	return b


func _check_boot() -> void:
	var b: Control = _boot()
	b.set("bridge_class", "NoSuchBridgeClass")
	var r: Dictionary = b.call("diagnose") as Dictionary
	_ok(not bool(r.get("ok", true)) and str(r.get("kind")) == "bridge", "Boot: missing GDExtension class is detected")
	_ok((r.get("hints", []) as Array).size() >= 3, "Boot: bridge failure carries packaged-build hints")
	b.free()

	b = _boot()
	b.set("main_scene_path", "res://does/not/exist.tscn")
	b.set("bridge_class", "Node")
	r = b.call("diagnose") as Dictionary
	_ok(not bool(r.get("ok", true)) and str(r.get("kind")) == "scene", "Boot: unloadable scene path is detected")
	b.free()

	# A scene that loads but whose root has no script (what a non-compiling Main.gd produces).
	var n: Node2D = Node2D.new()
	var packed: PackedScene = PackedScene.new()
	packed.pack(n)
	n.free()
	var path: String = "user://_boot_noscript.tscn"
	ResourceSaver.save(packed, path)
	b = _boot()
	b.set("main_scene_path", path)
	b.set("bridge_class", "Node")
	r = b.call("diagnose") as Dictionary
	_ok(not bool(r.get("ok", true)) and str(r.get("detail")).contains("no working script"), "Boot: scene without a compiled script is detected")
	b.free()
	DirAccess.remove_absolute(ProjectSettings.globalize_path(path))

	if ClassDB.class_exists("NovaWorld"):
		b = _boot()
		r = b.call("diagnose") as Dictionary
		_ok(bool(r.get("ok", false)), "Boot: the real Main.tscn passes the guard")
		if r.has("node"):
			(r["node"] as Node).free()
		b.free()
	else:
		print("SKIP Boot: real Main.tscn (NovaWorld not built)")


func _check_screen() -> void:
	var s: Control = ErrorScreen.new()
	s.setup({"title": "T", "message": "M", "hints": ["a", "b"], "detail": "detail /Users/someone/x", "location": "Main.gd:347", "retry": true, "menu": true, "continue": true})
	root.add_child(s)
	var btns: Dictionary = s.get("buttons") as Dictionary
	_ok(btns.size() >= 8, "ErrorScreen: builds headless with all buttons (%d)" % btns.size())
	for id in ["report", "copy", "logs", "bundle", "quit", "retry", "menu", "continue"]:
		_ok(btns.has(id), "ErrorScreen: has button " + id)
	var dt: TextEdit = s.get("details_text") as TextEdit
	_ok(dt != null and not dt.visible and not dt.text.contains("someone"), "ErrorScreen: details collapsed and home path stripped")
	s.call("_toggle_details")
	_ok(dt.visible, "ErrorScreen: details toggle opens")
	s.free()


func _check_storm() -> void:
	CrashLogger.clear_all_state()
	CrashLogger.clock_override = 1000
	var tripped: bool = false
	for i in range(CrashLogger.STORM_COUNT - 1):
		tripped = tripped or CrashLogger.note_error("res://x.gd", 10, "foo", "boom", true, false)
	_ok(not tripped and not CrashLogger.peek_storm(), "Storm: %d identical errors in 1s do not trip" % (CrashLogger.STORM_COUNT - 1))
	var t2: bool = CrashLogger.note_error("res://x.gd", 10, "foo", "boom", true, false)
	_ok(t2 and CrashLogger.take_storm().get("text") == "boom", "Storm: the %dth trips" % CrashLogger.STORM_COUNT)
	CrashLogger.clear_all_state()
	for i in range(CrashLogger.STORM_COUNT - 1):
		CrashLogger.clock_override = 1000 + i * 400   # spread across windows
		CrashLogger.note_error("res://x.gd", 11, "bar", "slow", true, false)
	CrashLogger.clock_override = 1000 + 20 * 400
	_ok(not CrashLogger.note_error("res://x.gd", 11, "bar", "slow", true, false), "Storm: a slow trickle does not trip")
	CrashLogger.clear_all_state()
	CrashLogger.clock_override = 5000
	var f1: bool = CrashLogger.note_error("res://Main.gd", 347, "_process", "Invalid call", true, false)
	var f2: bool = CrashLogger.note_error("res://Main.gd", 347, "_process", "Invalid call", true, false)
	_ok(not f1 and not f2, "Storm: a per-frame script error below %d does not trip" % CrashLogger.FRAME_STORM_COUNT)
	_ok(CrashLogger.note_error("res://Main.gd", 347, "_process", "Invalid call", true, false), "Storm: per-frame script error trips at %d" % CrashLogger.FRAME_STORM_COUNT)
	CrashLogger.take_storm()
	CrashLogger.clear_all_state()
	var w: bool = false
	for i in range(30):
		w = w or CrashLogger.note_error("res://x.gd", 12, "baz", "warn", false, true)
	var evs: Array = CrashLogger.take_events()
	_ok(not w and evs.is_empty(), "Storm: warnings never trip and never raise toast events")
	CrashLogger.note_error("res://x.gd", 13, "one", "single", false, false)
	_ok(CrashLogger.take_events().size() == 1, "Toast: a single error yields exactly one event")
	CrashLogger.ignore_key(CrashLogger.error_key("res://x.gd", 14, "ign", "t"))
	_ok(not CrashLogger.note_error("res://x.gd", 14, "ign", "t", true, false) and CrashLogger.take_events().is_empty(), "Storm: ignored (Continue anyway) errors stay quiet")
	CrashLogger.clock_override = -1
	CrashLogger.clear_all_state()


func _check_url() -> void:
	var home: String = OS.get_environment("HOME")
	var lines: PackedStringArray = PackedStringArray()
	for i in range(400):
		lines.append("[ %d.00] E something failed at %s/Projects/x/%d.gd:%d with a rather long explanation text" % [i, home, i, i])
	var url: String = ErrorReport.build_issue_url("Crash in /Users/bob/Library/thing", "oops C:\\Users\\Alice\\file.gd", lines)
	_ok(url.begins_with(ErrorReport.ISSUES_URL + "?title="), "URL: targets the NovaSwift issue form")
	_ok(url.length() <= ErrorReport.MAX_URL_LENGTH, "URL: capped at %d (got %d)" % [ErrorReport.MAX_URL_LENGTH, url.length()])
	var decoded: String = url.uri_decode()
	_ok(not decoded.contains("bob") and not decoded.contains("Alice") and (home.length() < 3 or not decoded.contains(home)), "URL: home dirs / account names stripped")
	_ok(decoded.contains("~"), "URL: home paths become ~")
	var small: String = ErrorReport.build_issue_url("t", "s", PackedStringArray(["only line"]))
	_ok(small.uri_decode().contains("only line"), "URL: short logs are included whole")
