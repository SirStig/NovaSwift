# NOVA Swift — shared look for the app-shell screens (main menu, settings, pause
# menu, data setup): one Theme with a clearly visible focus ring on every
# control, plus a few builders. Gamepad and keyboard navigate by Godot focus
# alone, so the focus style is what tells the player where they are.
#
# Loaded with preload() (no class_name), like Controls.gd.
extends RefCounted

const Theme_ := preload("res://ui/classic/ClassicTheme.gd")

const BG := Color(0.02, 0.025, 0.05)
const PANEL := Color(0.09, 0.09, 0.12)
const BORDER := Color(0.45, 0.5, 0.6)
const ACCENT := Color(1.0, 0.72, 0.28)        # focus ring: the sunrise amber of the app icon
const TEXT := Color(0.88, 0.9, 0.95)
const MUTED := Color(0.62, 0.66, 0.74)

static var _theme: Theme
static var _ring: StyleBoxFlat
static var _t: Theme


## The focus ring is part of keyboard / pad navigation only (no outline for the mouse).
static func _apply_nav(on: bool) -> void:
	if _t == null:
		return
	var filled := _box(Color(0.24, 0.2, 0.12), ACCENT, 3)
	for cls in ["Button", "CheckButton"]:
		_t.set_stylebox("focus", cls, filled if on else StyleBoxEmpty.new())
	for cls in ["HSlider", "LineEdit", "ScrollContainer"]:
		_t.set_stylebox("focus", cls, _ring if on else StyleBoxEmpty.new())


static func _box(bg: Color, border: Color, width: int) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(width)
	s.set_corner_radius_all(3)
	s.content_margin_left = 14
	s.content_margin_right = 14
	s.content_margin_top = 6
	s.content_margin_bottom = 6
	return s


static func theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	var no_ring := StyleBoxEmpty.new()
	for cls in ["Button", "CheckButton"]:
		t.set_stylebox("normal", cls, _box(Color(0.14, 0.15, 0.2), Color(0.3, 0.33, 0.4), 1))
		t.set_stylebox("hover", cls, _box(Color(0.19, 0.21, 0.28), BORDER, 1))
		t.set_stylebox("pressed", cls, _box(Color(0.26, 0.22, 0.14), ACCENT, 2))
		t.set_stylebox("disabled", cls, _box(Color(0.1, 0.1, 0.13), Color(0.2, 0.2, 0.25), 1))
		# The focus ring replaces the default outline: thick, bright, filled.
		t.set_stylebox("focus", cls, no_ring)
		t.set_color("font_color", cls, TEXT)
		t.set_color("font_hover_color", cls, Color.WHITE)
		t.set_color("font_focus_color", cls, Color.WHITE)
	var ring := _box(Color(0, 0, 0, 0), ACCENT, 2)
	for cls in ["HSlider", "LineEdit", "ScrollContainer"]:
		t.set_stylebox("focus", cls, no_ring)
	_ring = ring
	_t = t
	Theme_.track(null)
	Theme_.on_nav_changed(_apply_nav)
	t.set_color("font_color", "Label", TEXT)
	_theme = t
	return t


## A full-screen Control carrying the shell theme, with a dark backdrop.
static func screen(layer: CanvasLayer, backdrop_alpha := 0.94) -> Control:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.theme = theme()
	layer.add_child(root)
	Theme_.track(root)
	root.tree_entered.connect(func(): Theme_.track(root))
	Theme_.on_nav_changed(_apply_nav)
	_apply_nav(Theme_.nav_active)
	var dim := ColorRect.new()
	dim.color = Color(BG.r, BG.g, BG.b, backdrop_alpha)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP   # nothing below the screen is clickable
	root.add_child(dim)
	return root


## A centred bordered panel inside `root`; returns the VBox to fill.
static func panel(root: Control, width: float, separation := 8) -> VBoxContainer:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var box := PanelContainer.new()
	box.custom_minimum_size = Vector2(width, 0)
	var style := _box(PANEL, BORDER, 2)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(22)
	box.add_theme_stylebox_override("panel", style)
	center.add_child(box)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", separation)
	box.add_child(v)
	return v


static func title(parent: Control, text: String, size := 26) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	parent.add_child(l)
	return l


static func label(parent: Control, text: String, size := 15, color := MUTED) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	parent.add_child(l)
	return l


## A menu button. `nova` (optional) gives the confirm beep (snd 150) on press;
## there is no hover sound — the original's menus have none.
static func button(parent: Control, text: String, cb: Callable, nova: Object = null) -> Button:
	var b := Button.new()
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size = Vector2(0, 40)
	if nova != null and nova.has_method("sound_beep"):
		b.pressed.connect(func(): nova.sound_beep(1))
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


## Grab focus once the control is in the tree (deferred, and guarded because a
## screen can be replaced before the call lands).
static func focus(c: Control) -> void:
	(func(): if is_instance_valid(c) and c.is_inside_tree(): c.grab_focus()).call_deferred()
