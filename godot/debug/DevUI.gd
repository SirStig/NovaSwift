# NOVA Swift — shared look + builders for the developer tools (godot/debug/).
#
# The tools are developer UI, so they borrow Apple's dev-console style (dark panels, green
# monospace accents -- `devConsoleGreen`/`devConsoleRed` in app/NovaSwift/Debug/DevConsoleView.swift)
# instead of the Classic kit. Everything is plain Control nodes with focus enabled, so keyboard
# and gamepad navigate by Godot focus alone (ShellUI.theme() draws the focus ring).
#
# Loaded with preload() (no class_name), like the rest of the frontend.
extends RefCounted

const ShellUI = preload("res://screens/ShellUI.gd")

const GREEN := Color(0.35, 0.95, 0.5)
const RED := Color(0.95, 0.35, 0.3)
const AMBER := Color(1.0, 0.75, 0.3)
const BLUE := Color(0.45, 0.7, 1.0)
const DIM := Color(1, 1, 1, 0.55)
const TEXT := Color(0.9, 0.93, 0.97)
const PANEL_BG := Color(0.03, 0.04, 0.05, 0.96)

static var _mono: Font


static func mono() -> Font:
	if _mono == null:
		var f := SystemFont.new()
		f.font_names = PackedStringArray(["Menlo", "Consolas", "DejaVu Sans Mono", "Liberation Mono", "Courier New", "monospace"])
		_mono = f
	return _mono


static func theme() -> Theme:
	var t: Theme = ShellUI.theme().duplicate()
	t.default_font = mono()
	t.default_font_size = 13
	for cls in ["Button", "CheckButton"]:
		t.set_font_size("font_size", cls, 12)
		# denser than the shell's chunky buttons
		for state in ["normal", "hover", "pressed", "disabled"]:
			var sb = t.get_stylebox(state, cls)
			if sb is StyleBoxFlat:
				var d: StyleBoxFlat = sb.duplicate()
				d.content_margin_left = 9
				d.content_margin_right = 9
				d.content_margin_top = 3
				d.content_margin_bottom = 3
				t.set_stylebox(state, cls, d)
	t.set_font_size("font_size", "Label", 12)
	t.set_font_size("font_size", "LineEdit", 13)
	t.set_font_size("normal_font_size", "RichTextLabel", 12)
	t.set_font_size("mono_font_size", "RichTextLabel", 12)
	t.set_font("normal_font", "RichTextLabel", mono())
	t.set_font("bold_font", "RichTextLabel", mono())
	t.set_font("mono_font", "RichTextLabel", mono())
	return t


static func label(parent: Node, text := "", size := 12, color := TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	if parent != null:
		parent.add_child(l)
	return l


static func wrap_label(parent: Node, text := "", size := 11, color := DIM) -> Label:
	var l := label(parent, text, size, color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.custom_minimum_size = Vector2(60, 0)
	return l


## A flat chip-style button. `tint` colours the text; `cb` is called on press.
static func button(parent: Node, text: String, cb: Callable, tint := GREEN, toggle := false) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = toggle
	b.focus_mode = Control.FOCUS_ALL
	b.add_theme_color_override("font_color", tint)
	b.add_theme_color_override("font_hover_color", tint.lightened(0.3))
	b.add_theme_color_override("font_pressed_color", tint)
	b.add_theme_color_override("font_focus_color", tint.lightened(0.3))
	b.add_theme_font_size_override("font_size", 12)
	if toggle:
		b.toggled.connect(func(on: bool): cb.call(on))
	else:
		b.pressed.connect(cb)
	if parent != null:
		parent.add_child(b)
	return b


static func hbox(parent: Node, sep := 6) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	if parent != null:
		parent.add_child(h)
	return h


static func vbox(parent: Node, sep := 4) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	if parent != null:
		parent.add_child(v)
	return v


static func flow(parent: Node, sep := 6) -> HFlowContainer:
	var f := HFlowContainer.new()
	f.add_theme_constant_override("h_separation", sep)
	f.add_theme_constant_override("v_separation", 4)
	if parent != null:
		parent.add_child(f)
	return f


static func scroll(parent: Node) -> ScrollContainer:
	var s := ScrollContainer.new()
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.follow_focus = true
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	if parent != null:
		parent.add_child(s)
	return s


static func panel_style(bg := Color(1, 1, 1, 0.045), border := Color(1, 1, 1, 0.07), radius := 6) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(1)
	s.set_corner_radius_all(radius)
	s.content_margin_left = 9
	s.content_margin_right = 9
	s.content_margin_top = 7
	s.content_margin_bottom = 7
	return s


static func card(parent: Node, highlight := false) -> VBoxContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", panel_style(
		GREEN * Color(1, 1, 1, 0.1) if highlight else Color(1, 1, 1, 0.045),
		GREEN * Color(1, 1, 1, 0.4) if highlight else Color(1, 1, 1, 0.07)))
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if parent != null:
		parent.add_child(p)
	var v := vbox(p, 5)
	return v


static func search_field(parent: Node, placeholder: String, on_change: Callable) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.clear_button_enabled = true
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	e.text_changed.connect(func(t: String): on_change.call(t))
	if parent != null:
		parent.add_child(e)
	return e


static func clear_children(node: Node) -> void:
	for c in node.get_children():
		node.remove_child(c)
		c.queue_free()


static func status_color(status: String) -> Color:
	match status:
		"PASS":
			return GREEN
		"WARN":
			return AMBER
		_:
			return RED


## Escape BBCode brackets in plain text.
static func bb_escape(text: String) -> String:
	return text.replace("[", "[lb]")


static func fmt_int(n: int) -> String:
	var s := str(abs(n))
	var out := ""
	var i := s.length()
	while i > 3:
		out = "," + s.substr(i - 3, 3) + out
		i -= 3
	out = s.substr(0, i) + out
	return ("-" if n < 0 else "") + out
