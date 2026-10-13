# Plugin Editor chrome. Matches the Apple editor: near-black panes and the nova amber accent
# (app/NovaSwift/UI/NovaDialog.swift `novaAmber`, PluginEditorView's white 0.10 / 0.13 / 0.09).
extends RefCounted

const BG := Color(0.10, 0.10, 0.10)
const SIDE := Color(0.09, 0.09, 0.09)
const BAR := Color(0.13, 0.13, 0.13)
const WELL := Color(0.12, 0.12, 0.12)
const AMBER := Color(1.0, 0.70, 0.28)
const TEXT := Color(0.92, 0.92, 0.92)
const SECONDARY := Color(0.62, 0.62, 0.62)
const TERTIARY := Color(0.42, 0.42, 0.42)
const NEW_C := Color(0.45, 0.82, 0.48)
const LINE := Color(1, 1, 1, 0.08)
const ROW := Color(1, 1, 1, 0.045)
const BAD := Color(0.95, 0.38, 0.32)


static func fill(color: Color, radius := 0) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.corner_radius_top_left = radius
	s.corner_radius_top_right = radius
	s.corner_radius_bottom_left = radius
	s.corner_radius_bottom_right = radius
	return s


static func button(text: String, cb: Callable, accent := false) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_ALL
	b.add_theme_color_override("font_color", Color(0.12, 0.08, 0.02) if accent else TEXT)
	b.add_theme_color_override("font_hover_color", Color(0.12, 0.08, 0.02) if accent else AMBER)
	b.add_theme_color_override("font_pressed_color", AMBER)
	var bg := AMBER if accent else Color(1, 1, 1, 0.06)
	for state in ["normal", "hover", "pressed"]:
		var box := fill(bg if state == "normal" else (AMBER.lightened(0.08) if accent else Color(1, 1, 1, 0.12)), 5)
		box.content_margin_left = 10
		box.content_margin_right = 10
		box.content_margin_top = 4
		box.content_margin_bottom = 4
		b.add_theme_stylebox_override(state, box)
	b.add_theme_stylebox_override("focus", fill(Color(0, 0, 0, 0), 5))
	b.pressed.connect(cb)
	return b


static func label(text: String, size := 13, color: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	return l


static func field(placeholder := "") -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.add_theme_color_override("font_color", TEXT)
	e.add_theme_color_override("font_placeholder_color", TERTIARY)
	e.add_theme_stylebox_override("normal", fill(Color(1, 1, 1, 0.05), 4))
	return e


static func spin(value: int, lo := -32768, hi := 32767) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.rounded = true
	s.value = value
	s.custom_minimum_size = Vector2(92, 0)
	return s
