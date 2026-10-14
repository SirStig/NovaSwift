# NOVA Swift -- the boot guard (run/main_scene). docs/GODOT_LAYER.md "Errors and crash reporting".
#
# Godot happily opens Main.tscn even when Main.gd (or a script it preloads) failed to compile -- the scene then has
# no script and the console floods with "Nonexistent function ... in base 'Nil'". Booting through this tiny scene
# instead means a broken install lands on a readable error screen:
#   1. the capture Logger + ErrorWatch are installed first (CrashLogger.gd / ErrorWatch.gd);
#   2. updater mode (`-- --updater ...`) is handled here, so the updater never depends on Main compiling;
#   3. the GDExtension must have loaded (ClassDB.class_exists("NovaWorld"));
#   4. Main.tscn is loaded at RUNTIME (never preload'ed here), instantiated, and must actually carry a compiled Main
#      script with the known method `recover_to_menu`;
#   5. only then is it swapped in as the current scene.
# Any failure shows ui/ErrorScreen.gd with a plain-language message, hints and the technical detail.
# No game script is referenced from this file (only the standalone ui/Error*.gd + CrashLogger.gd helpers).
extends Control

const CrashLogger = preload("res://ui/CrashLogger.gd")
const ErrorReport = preload("res://ui/ErrorReport.gd")
const ErrorScreen = preload("res://ui/ErrorScreen.gd")
const ErrorWatch = preload("res://ui/ErrorWatch.gd")

## Test hooks (tests/error_boundary_selfcheck.gd points these at bogus targets).
var main_scene_path: String = "res://Main.tscn"
var bridge_class: String = "NovaWorld"
var required_method: String = "recover_to_menu"
var auto_start: bool = true
## `main_script_path` must be a compiled script attached to the instantiated root.
var main_script_path: String = "res://Main.gd"

var screen: Control = null


func _ready() -> void:
	CrashLogger.install()
	_install_watch()
	if not auto_start:
		return
	if _run_updater_if_requested():
		return
	if _run_server_if_requested():
		return
	start()


func _install_watch() -> void:
	var root: Window = get_tree().root
	if root.get_node_or_null("ErrorWatch") == null:
		var w: Node = ErrorWatch.new()
		root.add_child.call_deferred(w)


## Updater mode: show only the progress window, never touch NovaWorld / Main. Loaded at runtime so a broken
## updater script reports instead of taking Boot down.
func _run_updater_if_requested() -> bool:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if not args.has("--updater") and not OS.get_cmdline_args().has("--updater"):
		return false
	var mode: Script = load("res://updater/UpdaterMode.gd") as Script
	var scene_script: Script = load("res://updater/UpdaterScene.gd") as Script
	if mode == null or scene_script == null:
		show_failure(_fail("updater", "NovaSwift couldn't start the updater", "A game file failed to load.", "updater scripts did not load"))
		return true
	var opts: Dictionary = mode.call("requested") as Dictionary
	if opts.is_empty():
		return false
	var layer: CanvasLayer = CanvasLayer.new()
	add_child(layer)
	var up: Control = scene_script.new() as Control
	layer.add_child(up)
	up.call("setup", opts)
	return true


## Dedicated server mode (`-- --server ...`, net/ServerMain.gd): headless host, no menus, no Main scene.
## Loaded at runtime so a broken net script reports instead of taking Boot down.
func _run_server_if_requested() -> bool:
	if not OS.get_cmdline_user_args().has("--server") and not OS.get_cmdline_args().has("--server"):
		return false
	var sm: Script = load("res://net/ServerMain.gd") as Script
	if sm == null or not sm.can_instantiate():
		show_failure(_fail("server", "NovaSwift couldn't start the dedicated server", "A game file failed to load.", "res://net/ServerMain.gd did not compile"))
		return true
	var node: Node = sm.new() as Node
	add_child(node)
	node.call("start")
	return true


## Build a failure record.
func _fail(kind: String, title: String, message: String, detail: String) -> Dictionary:
	var hints: Array = []
	if kind == "bridge":
		hints = [
			"The engine bridge (the NovaSwift GDExtension library) is missing or was built for another platform.",
			"Packaged builds: the bin/ folder next to the game must contain the .so (Linux), .dll (Windows) or .dylib (macOS) library; re-extract or re-install the whole download rather than copying single files.",
			"Linux: the library needs a recent glibc; running on a much older distribution fails to load it.",
			"macOS: if you downloaded the app, run  xattr -dr com.apple.quarantine <NovaSwift.app>  in Terminal, or right-click > Open once.",
			"Windows: install the latest Microsoft Visual C++ Redistributable and keep every .dll beside the .exe.",
		]
	elif kind == "scene":
		hints = [
			"A game script failed to compile, so the main game scene could not be built.",
			"If you edited or added files (mods, plugins or scripts), undo that change and retry.",
			"Otherwise reinstall or update the game: a partly-copied or mismatched install causes this.",
			"Send us the report; the technical details name the exact file and line.",
		]
	return {"ok": false, "kind": kind, "title": title, "message": message, "detail": detail, "hints": hints}


## The recent error lines logged since boot, for the "why" of a scene that won't load.
func _error_context() -> String:
	var lines: PackedStringArray = CrashLogger.recent_errors(10)
	return "\n".join(lines)


## Check everything; returns {ok: true, node: Node} or a failure record ({ok:false, kind, title, message, detail, hints}).
func diagnose() -> Dictionary:
	if not ClassDB.class_exists(bridge_class):
		return _fail("bridge", "NovaSwift couldn't start", "The engine bridge is missing or is for the wrong platform, so the game can't run.",
			"ClassDB has no class '%s'. The GDExtension (see NovaSwift.gdextension) did not load." % bridge_class)
	if not ResourceLoader.exists(main_scene_path):
		return _fail("scene", "NovaSwift couldn't start", "A game file is missing: the main game scene could not be found.", "Missing resource: " + main_scene_path)
	var res: Resource = ResourceLoader.load(main_scene_path, "PackedScene", ResourceLoader.CACHE_MODE_IGNORE)
	var packed: PackedScene = res as PackedScene
	if packed == null or not packed.can_instantiate():
		return _fail("scene", "NovaSwift couldn't start", "A game file failed to load, so the game can't start.",
			"Could not load %s as a scene.\n%s" % [main_scene_path, _error_context()])
	var inst: Node = packed.instantiate()
	if inst == null:
		return _fail("scene", "NovaSwift couldn't start", "A game file failed to load, so the game can't start.",
			"%s instantiated to nothing.\n%s" % [main_scene_path, _error_context()])
	var script: Script = inst.get_script() as Script
	if script == null or not script.can_instantiate():
		inst.free()
		return _fail("scene", "NovaSwift couldn't start", "A game file failed to load: the main game script did not compile.",
			"%s has no working script (expected %s).\n%s" % [main_scene_path, main_script_path, _error_context()])
	if not inst.has_method(required_method):
		inst.free()
		return _fail("scene", "NovaSwift couldn't start", "A game file is out of date or damaged: the main game script is missing a required part.",
			"%s's script has no method '%s'.\n%s" % [main_scene_path, required_method, _error_context()])
	return {"ok": true, "node": inst}


func start() -> void:
	var r: Dictionary = diagnose()
	if not bool(r.get("ok", false)):
		show_failure(r)
		return
	_swap_in.call_deferred(r["node"] as Node)


func _swap_in(main: Node) -> void:
	var tree: SceneTree = get_tree()
	tree.root.add_child(main)
	tree.current_scene = main
	queue_free()


func show_failure(r: Dictionary) -> void:
	var watch: Node = get_tree().root.get_node_or_null("ErrorWatch") if is_inside_tree() else null
	if watch != null:
		watch.set("suppressed", true)
	if screen != null:
		screen.queue_free()
	var s: Control = ErrorScreen.new()
	var detail: String = str(r.get("detail", ""))
	s.setup({
		"title": str(r.get("title", "NovaSwift couldn't start")),
		"message": str(r.get("message", "")),
		"hints": r.get("hints", []),
		"detail": detail,
		"retry": true,
		"issue_title": "[Godot %s] Startup failure: %s" % [ErrorReport.version(), str(r.get("kind", ""))],
	})
	s.retry_pressed.connect(_retry)
	screen = s
	add_child(s)


func _retry() -> void:
	CrashLogger.clear_all_state()
	get_tree().reload_current_scene()
