# NOVA Swift -- runtime error watcher (docs/GODOT_LAYER.md "Errors and crash reporting").
#
# Boot.gd adds one of these to the scene-tree root (it survives scene changes). Each frame, on the main thread,
# it asks CrashLogger (which collects from any thread) for:
#   * a STORM (same error repeating, or a per-frame script error): pause the tree and show the ErrorScreen as an
#     overlay with Back to main menu / Continue anyway / Report. "Continue anyway" ignores that error from then on.
#   * ordinary single errors: a small non-blocking toast "Something went wrong -- Report" (rate limited; never
#     for warnings -- CrashLogger doesn't queue those).
# Depends only on ErrorScreen / ErrorReport / CrashLogger (no game scripts). Loaded with preload() (no class_name).
extends Node

const CrashLogger = preload("res://ui/CrashLogger.gd")
const ErrorReport = preload("res://ui/ErrorReport.gd")
const ErrorScreen = preload("res://ui/ErrorScreen.gd")

const TOAST_MIN_INTERVAL_MS := 8000
const TOAST_SHOW_MS := 6000

var _layer: CanvasLayer = null
var _screen: Control = null
var _storm: Dictionary = {}
var _was_paused: bool = false
var _toast: PanelContainer = null
var _toast_until: int = 0
var _last_toast: int = -100000
var _last_event: Dictionary = {}
## Set false by tests so a headless run doesn't pause the whole tree.
var pause_on_storm: bool = true
## Boot's own failure screen is up: no toasts / storm overlays on top of it.
var suppressed: bool = false


func _init() -> void:
	name = "ErrorWatch"
	process_mode = Node.PROCESS_MODE_ALWAYS


func _process(_delta: float) -> void:
	if _toast != null and Time.get_ticks_msec() > _toast_until:
		_hide_toast()
	if _screen != null or suppressed:
		CrashLogger.take_events()
		CrashLogger.take_storm()
		return
	var storm: Dictionary = CrashLogger.take_storm()
	if not storm.is_empty():
		show_storm(storm)
		return
	var events: Array = CrashLogger.take_events()
	if events.is_empty():
		return
	_last_event = events[events.size() - 1] as Dictionary
	var now: int = Time.get_ticks_msec()
	if now - _last_toast >= TOAST_MIN_INTERVAL_MS:
		_last_toast = now
		_show_toast()


func is_showing() -> bool:
	return _screen != null


func _ensure_layer() -> CanvasLayer:
	if _layer == null:
		_layer = CanvasLayer.new()
		_layer.layer = 200
		_layer.process_mode = Node.PROCESS_MODE_ALWAYS
		add_child(_layer)
	return _layer


func show_storm(storm: Dictionary) -> void:
	_storm = storm
	_hide_toast()
	_was_paused = get_tree().paused
	if pause_on_storm:
		get_tree().paused = true
	var game_running: bool = _game_running()
	var where: String = "%s:%d" % [str(storm.get("file", "")).get_file(), int(storm.get("line", 0))]
	var fn: String = str(storm.get("function", ""))
	if fn != "":
		where += " (in " + fn + ")"
	var detail: String = str(storm.get("text", ""))
	var bt: String = str(storm.get("backtrace", ""))
	if bt != "":
		detail += "\n" + bt
	_present({
		"title": "NovaSwift hit a repeating error",
		"message": "The same error fired %d times in a second, so the game was paused to stop it flooding. You can go back to the main menu, or continue and hope it was harmless. Please report it so it can be fixed." % int(storm.get("count", 0)),
		"hints": ["Saved games are not touched by this screen.", "“Save report bundle” includes the log, your settings and your most recent pilot file."],
		"detail": detail,
		"location": where,
		"menu": game_running,
		"continue": true,
		"retry": not game_running,
		"issue_title": "[Godot %s] Repeating error: %s" % [ErrorReport.version(), str(storm.get("text", "")).left(70)],
	})


## A non-recoverable failure (Main.gd's _ready didn't finish): pause and show the screen with Retry / Quit / Report.
## opts as ErrorScreen.setup; `errors: true` appends the recent error lines as the technical detail.
func show_fatal(opts: Dictionary) -> void:
	_storm = {}
	_hide_toast()
	_was_paused = get_tree().paused
	if pause_on_storm:
		get_tree().paused = true
	var o: Dictionary = opts.duplicate()
	if bool(o.get("errors", false)):
		o["detail"] = str(o.get("detail", "")) + "\n" + "\n".join(CrashLogger.recent_errors(12))
	_present(o)


func _present(opts: Dictionary) -> void:
	if _screen != null:
		_screen.queue_free()
	var s: Control = ErrorScreen.new()
	s.setup(opts)
	s.continue_pressed.connect(_on_continue)
	s.menu_pressed.connect(_on_menu)
	s.retry_pressed.connect(_on_retry)
	_screen = s
	_ensure_layer().add_child(s)


func _game_running() -> bool:
	var scene: Node = get_tree().current_scene
	return scene != null and scene.has_method("recover_to_menu")


func _close() -> void:
	if _screen != null:
		_screen.queue_free()
		_screen = null
	if pause_on_storm:
		get_tree().paused = _was_paused


func _on_continue() -> void:
	CrashLogger.ignore_key(str(_storm.get("key", "")))
	_close()


func _on_menu() -> void:
	CrashLogger.ignore_key(str(_storm.get("key", "")))
	var scene: Node = get_tree().current_scene
	_close()
	if scene != null and scene.has_method("recover_to_menu"):
		scene.call("recover_to_menu")


func _on_retry() -> void:
	CrashLogger.clear_all_state()
	_close()
	get_tree().change_scene_to_file("res://Boot.tscn")


# --- toast -----------------------------------------------------------------------------

func _show_toast() -> void:
	_hide_toast()
	var t: PanelContainer = PanelContainer.new()
	t.process_mode = Node.PROCESS_MODE_ALWAYS
	var row: HBoxContainer = HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	t.add_child(row)
	var l: Label = Label.new()
	l.text = "Something went wrong"
	row.add_child(l)
	var b: Button = Button.new()
	b.text = "Report"
	b.pressed.connect(_on_toast_report)
	row.add_child(b)
	var x: Button = Button.new()
	x.text = "×"
	x.pressed.connect(_hide_toast)
	row.add_child(x)
	t.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	t.position = Vector2(16, get_viewport().get_visible_rect().size.y - 64)
	_ensure_layer().add_child(t)
	_toast = t
	_toast_until = Time.get_ticks_msec() + TOAST_SHOW_MS


func _hide_toast() -> void:
	if _toast != null:
		_toast.queue_free()
		_toast = null


func _on_toast_report() -> void:
	var text: String = str(_last_event.get("text", "Runtime error"))
	var where: String = "%s:%d" % [str(_last_event.get("file", "")), int(_last_event.get("line", 0))]
	_hide_toast()
	ErrorReport.open_issue("[Godot %s] Runtime error: %s" % [ErrorReport.version(), text.left(70)], "%s\nat %s\n%s" % [text, where, str(_last_event.get("backtrace", ""))])
