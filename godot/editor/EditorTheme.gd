# Plugin Editor chrome. Pane colours are the Apple editor's (PluginEditorView: 0.10 / 0.13 / 0.09).
# Type, fields, sliders, menus and the amber accent come from the NovaSwift kit, which is the
# Godot mirror of the SwiftUI theme (NovaTheme / NovaControls). SwiftUI itself does not run here.
extends RefCounted

const T = preload("res://ui/novaswift/NovaTheme.gd")

const BG := Color(0.10, 0.10, 0.10)
const SIDE := Color(0.09, 0.09, 0.09)
const BAR := Color(0.13, 0.13, 0.13)
const WELL := Color(0.12, 0.12, 0.12)
const AMBER := T.AMBER
const TEXT := Color(0.92, 0.92, 0.92)
const SECONDARY := Color(1, 1, 1, 0.62)
const TERTIARY := Color(1, 1, 1, 0.42)
const NEW_C := T.GREEN
const LINE := T.GROUP_LINE
const ROW := T.CARD_BG
const BAD := T.RED
const INK := Color(0.12, 0.08, 0.02)


static func fill(color: Color, radius := 0) -> StyleBoxFlat:
	return T.box(color, radius)


## Put the shared SwiftUI-matched theme on a screen. Item lists get the editor's amber selection
## on a copy, so Settings and Plug-ins keep their own list styling.
static func install(root: Control) -> void:
	var theme := T.theme().duplicate()
	theme.set_font("font", "ItemList", T.font("body"))
	theme.set_font_size("font_size", "ItemList", 14)
	theme.set_color("font_color", "ItemList", TEXT)
	theme.set_color("font_hovered_color", "ItemList", TEXT)
	theme.set_color("font_selected_color", "ItemList", INK)
	theme.set_stylebox("selected", "ItemList", T.box(AMBER, 6))
	theme.set_stylebox("selected_focus", "ItemList", T.box(AMBER, 6))
	theme.set_stylebox("hovered", "ItemList", T.box(Color(1, 1, 1, 0.06), 6))
	theme.set_stylebox("focus", "ItemList", T.empty())
	theme.set_color("guide_color", "ItemList", Color(0, 0, 0, 0))
	root.theme = theme


static func button(text: String, cb: Callable, accent := false) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_ALL
	var ink := INK if accent else TEXT
	T.style_text(b, "caption", "medium", ink, 13)
	b.add_theme_color_override("font_hover_color", INK if accent else AMBER)
	b.add_theme_color_override("font_pressed_color", AMBER)
	var bg := AMBER if accent else T.BORDERED_BG
	b.add_theme_stylebox_override("normal", T.box(bg, 7, Color(0, 0, 0, 0), 0, Vector2(10, 4)))
	b.add_theme_stylebox_override("hover", T.box(AMBER.lightened(0.08) if accent else Color(1, 1, 1, 0.2), 7, Color(0, 0, 0, 0), 0, Vector2(10, 4)))
	b.add_theme_stylebox_override("pressed", T.box(AMBER.darkened(0.08) if accent else Color(1, 1, 1, 0.28), 7, Color(0, 0, 0, 0), 0, Vector2(10, 4)))
	b.add_theme_stylebox_override("focus", T.empty())
	b.pressed.connect(cb)
	return b


static func label(text: String, size := 13, color: Color = TEXT) -> Label:
	var l := Label.new()
	l.text = text
	var role := "caption" if size <= 12 else "body"
	var weight := "medium" if size <= 11 else "regular"
	T.style_text(l, role, weight, color, size)
	return l


static func field(placeholder := "") -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	T.style_text(e, "body", "regular", TEXT, 15)
	e.add_theme_color_override("font_placeholder_color", Color(1, 1, 1, 0.35))
	e.add_theme_color_override("caret_color", AMBER)
	e.add_theme_stylebox_override("normal", T.box(T.FIELD_BG, 5, T.FIELD_BORDER, 1, Vector2(10, 6)))
	e.add_theme_stylebox_override("focus", T.box(T.FIELD_BG, 5, AMBER, 1, Vector2(10, 6)))
	return e


static func spin(value: int, lo := -32768, hi := 32767) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.rounded = true
	s.value = value
	s.custom_minimum_size = Vector2(92, 0)
	T.style_text(s, "body", "regular", TEXT, 14)
	return s
