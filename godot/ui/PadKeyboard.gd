# NOVA Swift — gamepad on-screen keyboard (autoload "PadKeyboard").
#
# Port of the Apple app's `Input/PadKeyboard.swift` (the controller-drivable key grid with suggestion
# chips) for the Godot frontend, which has no OS keyboard on a Steam Deck game-mode session or a
# couch setup. It is a catch-all: this node watches the viewport's focus, and the moment ANY LineEdit
# takes focus while the last input was a gamepad it opens over the screen, pre-filled with the field's
# text. Done writes the text back and emits the field's `text_changed` + `text_submitted`; Cancel (B /
# Esc) leaves the field untouched. Pilot name entry, the debug console, the plug-in search and the map's
# Find field all work with no screen edits.
#
#   PadKeyboard.attach(line_edit, {title, suggestions, style})   optional per-field configuration
#   PadKeyboard.open_for(line_edit)                              open explicitly (any input device)
#   PadKeyboard.close(commit := false)
#   PadKeyboard.is_open()
#   PadKeyboard.pad_active()    # Controls.pad_connected() and the last input was a gamepad
#
# `attach` opts (all optional): `title` (heading; default the field's placeholder, else "Enter text"),
# `suggestions` (a Callable returning an Array of strings -- chips above the keys, like the Apple random
# pilot names; "More" rerolls), `style` ("auto" | "classic" | "novaswift"; auto follows the
# presentation: the original's greys when dialogs are Classic, the port's dark/amber otherwise), and
# `auto` (false = never auto-open for this field). A field named like "pilot" gets random pilot names
# from the bridge with no attach at all (placeholder "Pilot name"). Prefs `ui/pad_keyboard` = "off" disables the auto-open (the
# explicit API still works).
#
# Pad controls while it is open: d-pad / left stick move between keys, A presses, B cancels, Y deletes,
# X adds a space, Start is Done. A hardware keyboard also types into it.
extends Node

const Prefs = preload("res://Prefs.gd")
const Controls = preload("res://Controls.gd")
const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")

const META_OPTS := "pad_keyboard"
const AMBER := Color(1.0, 0.78, 0.35)

const DIGITS := ["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"]
const LETTER_ROWS := [
	["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
	["a", "s", "d", "f", "g", "h", "j", "k", "l"],
	["z", "x", "c", "v", "b", "n", "m"],
]

signal opened(line_edit: LineEdit)
signal closed(committed: bool)

## The last input event came from a gamepad (any button, or a stick past half throw).
var last_was_pad := false
## Treat a pad as connected even when the OS reports none (tests, Steam Input / remote play oddities).
var assume_pad := false

var _layer: CanvasLayer
var _root: Control
var _target: LineEdit
var _text := ""
var _shifted := true
var _style := "novaswift"
var _entry: Label
var _chips: HBoxContainer
var _suggest: Callable
var _suppress: LineEdit      # the field focus returned to after a close: do not reopen at once
var _nova: Object


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	get_viewport().gui_focus_changed.connect(_on_focus_changed)
	get_tree().node_added.connect(func(n: Node):
		if n.get_class() == "NovaWorld":
			_nova = n)


# --- public API ------------------------------------------------------------------------------------------

## Configure one field (title, suggestions, style, auto). The global focus hook reads it.
static func attach(line_edit: LineEdit, opts := {}) -> void:
	line_edit.set_meta(META_OPTS, opts)


func is_open() -> bool:
	return _layer != null


## A gamepad is plugged in AND the last input was a gamepad (a keyboard / mouse touch flips it back).
func pad_active() -> bool:
	return last_was_pad and (assume_pad or Controls.pad_connected())


func open_for(line_edit: LineEdit) -> void:
	if line_edit == null or not is_instance_valid(line_edit) or _layer != null:
		return
	var opts: Dictionary = line_edit.get_meta(META_OPTS, {})
	_target = line_edit
	_text = line_edit.text
	_shifted = _text.is_empty()
	_style = _resolve_style(str(opts.get("style", "auto")))
	_suggest = opts.get("suggestions", Callable())
	if not _suggest.is_valid() and _wants_names(line_edit) and _nova != null and is_instance_valid(_nova) \
			and _nova.has_method("pilot_random_name"):
		_suggest = func() -> Array: return [_nova.pilot_random_name(), _nova.pilot_random_name(), _nova.pilot_random_name()]
	var title := str(opts.get("title", ""))
	if title == "":
		title = line_edit.placeholder_text if line_edit.placeholder_text != "" else "Enter text"
	_build(title)
	opened.emit(line_edit)


## Close it; `commit` writes the text into the field and submits it.
func close(commit := false) -> void:
	if _layer == null:
		return
	var field := _target
	var text := _text
	_layer.queue_free()
	_layer = null
	_root = null
	_target = null
	if commit and field != null and is_instance_valid(field):
		var changed := field.text != text
		field.text = text
		field.caret_column = text.length()
		if changed:
			field.text_changed.emit(text)
		field.text_submitted.emit(text)
	if field != null and is_instance_valid(field) and field.is_inside_tree():
		_suppress = field
		field.grab_focus()
	closed.emit(commit)


## Type into the open keyboard (also what its keys call).
func type_text(s: String) -> void:
	if _layer == null:
		return
	var max_len: int = _target.max_length if _target != null and is_instance_valid(_target) else 0
	if max_len > 0 and _text.length() + s.length() > max_len:
		s = s.substr(0, maxi(0, max_len - _text.length()))
	_text += s
	# Auto-downshift after a letter, shift back up after a space (new word), like a name field expects.
	if s == " ":
		_shifted = true
	elif s.length() > 0 and s.to_lower() != s.to_upper():
		_shifted = false
	_refresh()


func backspace() -> void:
	if _text.length() > 0:
		_text = _text.left(_text.length() - 1)
		_refresh()


## The text currently in the keyboard's entry line.
func text() -> String:
	return _text


# --- focus hook -----------------------------------------------------------------------------------------------

func _on_focus_changed(node: Control) -> void:
	if not (node is LineEdit) or _layer != null:
		return
	if _suppress == node:
		_suppress = null
		return
	_suppress = null
	if str(Prefs.get_value("ui", "pad_keyboard")) == "off" or not pad_active():
		return
	var le := node as LineEdit
	var opts: Dictionary = le.get_meta(META_OPTS, {})
	if not le.editable or not bool(opts.get("auto", true)):
		return
	# Deferred: focus often lands mid-way through building a screen.
	(func():
		if is_instance_valid(le) and le.has_focus() and _layer == null and pad_active():
			open_for(le)).call_deferred()


func _input(event: InputEvent) -> void:
	var cursor: Node = get_node_or_null("/root/PadCursor")
	var synth: bool = cursor != null and cursor.is_synthetic(event)   # the pad cursor's own mouse events are not a mouse
	if synth:
		pass
	elif event is InputEventJoypadButton and event.pressed:
		last_was_pad = true
	elif event is InputEventJoypadMotion and absf(event.axis_value) > 0.5:
		last_was_pad = true
	elif event is InputEventKey or event is InputEventMouseButton or event is InputEventScreenTouch:
		last_was_pad = false
	elif event is InputEventMouseMotion and event.relative.length() > 2.0:
		last_was_pad = false
	if _layer == null:
		# A (ui_accept) on a focused field re-opens it after a cancel.
		if _pad_accept(event):
			var fo := get_viewport().gui_get_focus_owner()
			if fo is LineEdit and str(Prefs.get_value("ui", "pad_keyboard")) != "off" \
					and bool((fo.get_meta(META_OPTS, {}) as Dictionary).get("auto", true)) and fo.editable:
				get_viewport().set_input_as_handled()
				open_for(fo)
		return
	# Open: it owns the input.
	if event.is_action_pressed("ui_cancel") or (event is InputEventKey and event.pressed and event.keycode == KEY_ESCAPE) \
			or (event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_B):
		get_viewport().set_input_as_handled()
		close(false)
	elif _pad_accept(event):
		# A presses the focused key. (Some Godot builds map no pad button to ui_accept until a pad is
		# plugged in, so do not depend on the action.)
		get_viewport().set_input_as_handled()
		var fo := get_viewport().gui_get_focus_owner()
		if fo is Button:
			(fo as Button).pressed.emit()
	elif event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_START:
		get_viewport().set_input_as_handled()
		close(true)
	elif event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_Y:
		get_viewport().set_input_as_handled()
		backspace()
	elif event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_X:
		get_viewport().set_input_as_handled()
		type_text(" ")
	elif event is InputEventKey and event.pressed and not event.echo:
		# A hardware keyboard types straight in (Backspace / Enter handled; focused buttons keep ui_accept).
		if event.keycode == KEY_BACKSPACE:
			get_viewport().set_input_as_handled()
			backspace()
		elif event.unicode >= 32 and event.unicode != 127 and not event.is_action_pressed("ui_accept"):
			get_viewport().set_input_as_handled()
			type_text(char(event.unicode))


# --- building the keyboard --------------------------------------------------------------------------------------

## Pad A, whether or not the engine mapped it to ui_accept.
func _pad_accept(event: InputEvent) -> bool:
	return event is InputEventJoypadButton and event.pressed and event.button_index == JOY_BUTTON_A


func _wants_names(le: LineEdit) -> bool:
	return "pilot" in (le.placeholder_text + " " + str(le.name)).to_lower()


func _resolve_style(want: String) -> String:
	if want == "classic" or want == "novaswift":
		return want
	return "classic" if ClassicTheme.classic("dialogs") else "novaswift"


func _box(bg: Color, border: Color, bw := 1, radius := 7) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg
	sb.border_color = border
	sb.set_border_width_all(bw)
	sb.set_corner_radius_all(radius)
	sb.content_margin_left = 8
	sb.content_margin_right = 8
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb


func _theme() -> Theme:
	var t := Theme.new()
	var classic := _style == "classic"
	var ink := Color.BLACK if classic else Color.WHITE
	var r := 0 if classic else 7
	t.set_stylebox("normal", "Button", _box(ClassicTheme.NATIVE_LIGHT if classic else Color(1, 1, 1, 0.08),
		ClassicTheme.NATIVE_DARK if classic else Color(1, 1, 1, 0.14), 1, r))
	t.set_stylebox("hover", "Button", _box(ClassicTheme.NATIVE_LIGHT if classic else Color(1, 1, 1, 0.14),
		ClassicTheme.NATIVE_DARK if classic else Color(1, 1, 1, 0.3), 1, r))
	t.set_stylebox("pressed", "Button", _box(ClassicTheme.NATIVE_PRESSED if classic else Color(1, 0.78, 0.35, 0.35),
		Color.BLACK if classic else AMBER, 1, r))
	t.set_stylebox("focus", "Button", _box(ClassicTheme.NATIVE_LIGHT if classic else Color(1, 1, 1, 0.18), AMBER, 3, r))
	for c in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		t.set_color(c, "Button", ink)
	t.set_font_size("font_size", "Button", 16)
	t.set_font_size("font_size", "Label", 16)
	t.set_color("font_color", "Label", ink)
	if classic:
		t.set_font("font", "Button", ClassicTheme.ARIMO)
		t.set_font("font", "Label", ClassicTheme.ARIMO)
	return t


func _key(parent: Control, label: String, cb: Callable, wide := false) -> Button:
	var b := Button.new()
	b.text = label
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = Vector2(96 if wide else 44, 44)
	if cb.is_valid():
		b.pressed.connect(cb)
	parent.add_child(b)
	return b


func _row(parent: Control) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	h.add_theme_constant_override("separation", 6)
	parent.add_child(h)
	return h


func _build(title: String) -> void:
	var classic := _style == "classic"
	_layer = CanvasLayer.new()
	_layer.layer = 200
	_layer.name = "PadKeyboard"
	_root = Control.new()
	_root.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.theme = _theme()
	_layer.add_child(_root)
	var scrim := ColorRect.new()   # swallows the mouse; the keys are all that is live
	scrim.color = Color(0, 0, 0, 0.6)
	scrim.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_root.add_child(scrim)
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _box(ClassicTheme.NATIVE_FILL if classic else Color(0.07, 0.07, 0.10),
		Color.BLACK if classic else Color(1, 0.78, 0.35, 0.4), 2 if classic else 1, 0 if classic else 16))
	center.add_child(panel)
	var margin := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	panel.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	margin.add_child(box)

	var heading := Label.new()
	heading.text = title
	heading.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	heading.add_theme_font_size_override("font_size", 20)
	if not classic:
		heading.add_theme_color_override("font_color", AMBER)
	box.add_child(heading)

	var line := PanelContainer.new()
	line.add_theme_stylebox_override("panel", _box(Color.WHITE if classic else Color(0.04, 0.04, 0.04),
		ClassicTheme.NATIVE_DARK if classic else Color(0.3, 0.3, 0.3), 1, 0 if classic else 8))
	box.add_child(line)
	_entry = Label.new()
	_entry.name = "Entry"
	_entry.clip_text = true
	_entry.add_theme_font_size_override("font_size", 20)
	_entry.custom_minimum_size = Vector2(500, 26)
	line.add_child(_entry)

	_chips = _row(box)
	_chips.name = "Suggestions"
	var first := _fill_chips()

	var digits := _row(box)
	for d in DIGITS:
		_key(digits, d, type_text.bind(d))
	var letters: Array[Button] = []
	for row in LETTER_ROWS:
		var h := _row(box)
		for c in row:
			var b := _key(h, c.to_upper() if _shifted else c, Callable())
			b.pressed.connect(func(): type_text(b.text))
			b.set_meta("letter", c)
			letters.append(b)
		if row[0] == "z":
			_key(h, "Del", backspace, true)
	var bottom := _row(box)
	_key(bottom, "Shift", func():
		_shifted = not _shifted
		_refresh(), true)
	_key(bottom, "Space", type_text.bind(" "), true)
	_key(bottom, "-", type_text.bind("-"))
	_key(bottom, "'", type_text.bind("'"))
	_key(bottom, ".", type_text.bind("."))
	_key(bottom, "Clear", func():
		_text = ""
		_shifted = true
		_refresh(), true)
	var foot := _row(box)
	foot.add_theme_constant_override("separation", 12)
	var cancel := _key(foot, "Cancel", close.bind(false), true)
	cancel.name = "Cancel"
	var done := _key(foot, "Done", close.bind(true), true)
	done.name = "Done"

	add_child(_layer)
	_refresh()
	var start: Control = first if first != null else (letters[0] if not letters.is_empty() else done)
	start.grab_focus()


## (Re)build the suggestion chips; returns the first chip (or null).
func _fill_chips() -> Button:
	for c in _chips.get_children():
		c.queue_free()
	if not _suggest.is_valid():
		_chips.visible = false
		return null
	var names = _suggest.call()
	var first: Button = null
	if names is Array:
		for n in names:
			var b := _key(_chips, str(n), _use_suggestion.bind(str(n)), true)
			if first == null:
				first = b
		var more := _key(_chips, "More", func(): _fill_chips(), true)
		more.name = "More"
	_chips.visible = _chips.get_child_count() > 0
	return first


func _use_suggestion(s: String) -> void:
	_text = s
	_shifted = false
	_refresh()


func _refresh() -> void:
	if _entry == null:
		return
	_entry.text = (_text if _text != "" else " ") + "_"
	if _root == null:
		return
	for b in _root.find_children("*", "Button", true, false):
		if b.has_meta("letter"):
			var c: String = b.get_meta("letter")
			b.text = c.to_upper() if _shifted else c
