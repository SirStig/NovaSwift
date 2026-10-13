# NOVA Swift — controller-friendly in-app file browser (the Data Setup wizard's "Browse…").
#
# Godot's FileDialog is poor on a Steam Deck in Game Mode (tiny hit targets, no pad focus order), so this
# is plain focusable rows inside a NovaDialog. Pad: D-pad / stick moves focus, A opens a folder (or picks
# a file), B goes up one folder (and cancels at the top), Y uses the folder being shown. Mouse and keyboard
# work too (Enter opens, Backspace goes up). Shortcut chips along the top jump to Home, Downloads, an SD
# card, the scanner's finds and recently used sources.
#
#   var b = Browser.new(); parent.add_child(b); b.open(start_dir, shortcuts, "Choose your EV Nova folder")
#   b.chosen.connect(func(path): ...)    # a folder (Y / "Use This Folder") or a .zip/.rez/.ndat file (A)
#   b.cancelled.connect(...)
extends CanvasLayer

const T = preload("res://ui/novaswift/NovaTheme.gd")
const NC = preload("res://ui/novaswift/NovaControls.gd")
const Chrome = preload("res://ui/novaswift/NovaChrome.gd")

signal chosen(path: String)
signal cancelled

## Files shown as pickable (everything else is hidden so the list stays short).
const FILE_EXTS := ["zip", "rez", "ndat"]
const MAX_ROWS := 500

var current := ""
var dialog: Dictionary
var shortcuts: Array = []
var title := "Choose a folder"
var list_box: VBoxContainer
var path_label: Label
var _scroll: ScrollContainer
var _first_row: Control
var _rebuilding := false


func open(start_dir: String, shortcut_list: Array, window_title := "Choose a folder") -> void:
	layer = 60
	shortcuts = shortcut_list
	title = window_title
	dialog = Chrome.dialog(self, {"title": title, "width": 760.0, "buttons": [
		{"text": "Cancel", "cancel": true, "cb": _on_back},
		{"text": "Up", "cb": go_up},
		{"text": "Use This Folder", "default": true, "cb": _use_current},
	]})
	var box: VBoxContainer = dialog.body
	path_label = NC.label(box, "", "caption", "semibold", T.AMBER, true)
	if not shortcuts.is_empty():
		var flow := HFlowContainer.new()
		flow.add_theme_constant_override("h_separation", 6)
		flow.add_theme_constant_override("v_separation", 6)
		box.add_child(flow)
		for s in shortcuts:
			var path: String = s["path"]
			var chip := NC.button(str(s["label"]), "bordered", func(): navigate(path), "folder")
			chip.custom_minimum_size.y = 30
			flow.add_child(chip)
	_scroll = ScrollContainer.new()
	_scroll.custom_minimum_size = Vector2(0, 300)
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.follow_focus = true
	box.add_child(_scroll)
	list_box = VBoxContainer.new()
	list_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_box.add_theme_constant_override("separation", 3)
	_scroll.add_child(list_box)
	NC.label(box, "A open  ·  B up  ·  Y use this folder  ·  X cancel  ·  pick a .zip / .rez / .ndat file directly", "caption", "regular", T.TERTIARY, true)
	navigate(start_dir)


## Show `dir` (falls back to Home, then "/"). Rebuilds the row list and focuses its first row.
func navigate(dir: String) -> void:
	dir = dir.simplify_path() if dir != "" else dir
	if dir == "" or not DirAccess.dir_exists_absolute(dir):
		dir = _fallback()
	current = dir
	path_label.text = dir
	for c in list_box.get_children():
		c.queue_free()
	_first_row = null
	var d := DirAccess.open(dir)
	var dirs: Array = []
	var files: Array = []
	if d != null:
		d.list_dir_begin()
		var n := d.get_next()
		while n != "":
			if not n.begins_with("."):
				if d.current_is_dir():
					dirs.append(n)
				elif n.get_extension().to_lower() in FILE_EXTS:
					files.append(n)
			n = d.get_next()
		d.list_dir_end()
	dirs.sort_custom(func(a: String, b: String) -> bool: return a.naturalnocasecmp_to(b) < 0)
	files.sort_custom(func(a: String, b: String) -> bool: return a.naturalnocasecmp_to(b) < 0)
	if d == null:
		NC.label(list_box, "Can't read this folder.", "body", "regular", T.RED, true)
	if parent_of(dir) != dir:
		_row("..  (up one folder)", "arrow.uturn.backward.circle", func(): go_up())
	var shown := 0
	for n in dirs:
		if shown >= MAX_ROWS:
			break
		var p: String = dir.path_join(n)
		_row(n, "folder", func(): navigate(p))
		shown += 1
	for n in files:
		if shown >= MAX_ROWS:
			break
		var p2: String = dir.path_join(n)
		_row(n, "doc.on.doc", func(): chosen.emit(p2))
		shown += 1
	if dirs.size() + files.size() > MAX_ROWS:
		NC.label(list_box, "…and %d more (use the shortcuts or type a path)" % (dirs.size() + files.size() - MAX_ROWS), "caption", "regular", T.TERTIARY, true)
	elif dirs.is_empty() and files.is_empty() and d != null:
		NC.label(list_box, "No folders here. Press Y to use this folder, or B to go up.", "caption", "regular", T.SECONDARY, true)
	_scroll.scroll_vertical = 0
	if _first_row != null:
		Chrome.T_focus(_first_row)


func _row(text: String, icon_name: String, cb: Callable) -> void:
	var b := NC.select_row(list_box, text, icon_name, false, func():
		cb.call())
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.toggled.connect(func(_on): b.set_pressed_no_signal(false))
	if _first_row == null:
		_first_row = b


## Parent folder of `dir` ("/" and drive roots return themselves).
static func parent_of(dir: String) -> String:
	var d := dir.simplify_path()
	if d.length() > 1 and d.ends_with("/"):
		d = d.substr(0, d.length() - 1)
	if d.length() == 2 and d.ends_with(":"):
		return d + "/"   # a drive root
	if d == "/" or d == "":
		return "/" if d == "/" else d
	var i := d.rfind("/")
	if i < 0:
		return d
	if i == 0:
		return "/"
	var parent := d.substr(0, i)
	if parent.length() == 2 and parent.ends_with(":"):
		return parent + "/"
	return parent


func go_up() -> void:
	var p := parent_of(current)
	if p != current:
		navigate(p)


## B / Esc: up a folder, and cancel from the top.
func _on_back() -> void:
	if parent_of(current) != current:
		go_up()
	else:
		cancelled.emit()


func _use_current() -> void:
	chosen.emit(current)


func _fallback() -> String:
	for s in shortcuts:
		if DirAccess.dir_exists_absolute(str(s["path"])):
			return str(s["path"])
	return "/" if OS.get_name() != "Windows" else "C:/"


func _unhandled_input(event: InputEvent) -> void:
	if event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_Y:
		get_viewport().set_input_as_handled()
		_use_current()
	elif event is InputEventKey and event.pressed and not event.echo and event.keycode == KEY_BACKSPACE:
		get_viewport().set_input_as_handled()
		go_up()
	elif event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_X:
		get_viewport().set_input_as_handled()
		cancelled.emit()
