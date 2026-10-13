# NOVA Swift — shared look + builders for the developer tools (godot/debug/).
#
# The tools are developer UI, so they borrow Apple's dev-console style (a dark drop-down with
# green accents -- `devConsoleGreen`/`devConsoleRed` in app/NovaSwift/Debug/DevConsoleView.swift)
# but draw it with the NovaSwift kit's fonts (NovaTheme), SVG icons (NovaSVG) and rounded,
# bordered surfaces. Monospace (DevUI.mono()) is kept for log lines, values and code. Everything
# is plain Control nodes with focus enabled, so keyboard and gamepad navigate by Godot focus
# alone (every interactive control draws a green focus ring).
#
# Loaded with preload() (no class_name), like the rest of the frontend.
extends RefCounted

const ShellUI = preload("res://screens/ShellUI.gd")
const T = preload("res://ui/novaswift/NovaTheme.gd")
const SVG = preload("res://ui/novaswift/NovaSVG.gd")
const DevSwitch = preload("res://debug/DevSwitch.gd")

const GREEN := Color(0.35, 0.95, 0.5)
const RED := Color(0.95, 0.4, 0.35)
const AMBER := Color(1.0, 0.72, 0.3)
const BLUE := Color(0.45, 0.72, 1.0)
const DIM := Color(1, 1, 1, 0.55)
const FAINT := Color(1, 1, 1, 0.32)
const TEXT := Color(0.92, 0.94, 0.97)
const PANEL_BG := Color(0.045, 0.05, 0.06, 0.98)
const SURFACE := Color(1, 1, 1, 0.04)
const LINE := Color(1, 1, 1, 0.075)
const FOCUS := Color(0.55, 1.0, 0.7)

static var _mono: Font
static var _registered := false


static func mono() -> Font:
	if _mono == null:
		var f := SystemFont.new()
		f.font_names = PackedStringArray(["Menlo", "Consolas", "DejaVu Sans Mono", "Liberation Mono", "Courier New", "monospace"])
		_mono = f
	return _mono


static func sans(weight := "regular") -> Font:
	return T.font("body", weight)


static func head_font() -> Font:
	return T.font("heading", "semibold")


# --- icons -----------------------------------------------------------------------------------------

## Glyphs the debug suite needs that NovaSVG does not ship (registered once, from here).
static func register_glyphs() -> void:
	if _registered:
		return
	_registered = true
	SVG.register("doc.zipper", "<path d='M6 2.8h8l4.5 4.5v13.9H6z'/><path d='M14 2.8v4.5h4.5'/><path d='M10.5 8.5h2M10.5 11h2M10.5 13.5h2' stroke-width='1.6'/><rect x='9.6' y='15' width='3.8' height='4' rx='1' fill='C' stroke='none'/>")
	SVG.register("return", "<path d='M19 5v7a3 3 0 01-3 3H5M9 10.5L4.5 15 9 19.5'/>")
	SVG.register("dev.prompt", "<path d='M6 6l6 6-6 6M13.5 18h5'/>")
	SVG.register("rectangle.stack", "<rect x='4' y='9' width='16' height='11' rx='2.5'/><path d='M7 5.5h10M9.5 2.5h5'/>")
	SVG.register("person.text.rectangle", "<rect x='2.5' y='5' width='19' height='14' rx='2.5'/><circle cx='8.2' cy='10.5' r='2'/><path d='M5 16c.6-1.6 1.9-2.4 3.2-2.4s2.6.8 3.2 2.4M14 9.5h4.5M14 13h4.5'/>")
	SVG.register("tray", "<path d='M3 13l2.6-7.2a2 2 0 011.9-1.3h9a2 2 0 011.9 1.3L21 13v5a2 2 0 01-2 2H5a2 2 0 01-2-2z'/><path d='M3 13h5.5a3.5 3.5 0 007 0H21'/>")
	SVG.register("pin.circle", "<circle cx='12' cy='12' r='9'/><circle cx='12' cy='12' r='3' fill='C' stroke='none'/>")


static func px_scale() -> float:
	var tree := Engine.get_main_loop() as SceneTree
	if tree == null or tree.root == null:
		return 1.0
	var s: float = tree.root.get_final_transform().x.x
	return clampf(s, 1.0, 4.0)


## A white-or-`color` glyph rasterised at `size` logical px (so it stays crisp on HiDPI windows).
## Display it at `size` with TextureRect.expand_mode = IGNORE_SIZE (icon_rect) or Button
## icon_max_width (set_icon).
static func icon(glyph: String, size := 14, color := Color.WHITE) -> Texture2D:
	register_glyphs()
	var px: int = maxi(1, int(round(float(size) * px_scale())))
	return SVG.texture(glyph, px, color)


static func icon_rect(parent: Node, glyph: String, size := 14, color := Color.WHITE) -> TextureRect:
	var r := TextureRect.new()
	r.texture = icon(glyph, size, color)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.custom_minimum_size = Vector2(size, size)
	r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if parent != null:
		parent.add_child(r)
	return r


## Put a (white) icon on a Button; its tint follows the button's states via `colors`
## [normal, hover, pressed].
static func set_icon(b: Button, glyph: String, size: int, normal: Color, hover := Color(0, 0, 0, 0), pressed := Color(0, 0, 0, 0)) -> void:
	b.icon = icon(glyph, size, Color.WHITE)
	b.add_theme_constant_override("icon_max_width", size)
	b.add_theme_constant_override("h_separation", 6)
	var hv: Color = hover if hover.a > 0.0 else normal.lightened(0.25)
	var pr: Color = pressed if pressed.a > 0.0 else normal
	b.add_theme_color_override("icon_normal_color", normal)
	b.add_theme_color_override("icon_focus_color", hv)
	b.add_theme_color_override("icon_hover_color", hv)
	b.add_theme_color_override("icon_pressed_color", pr)
	b.add_theme_color_override("icon_hover_pressed_color", pr)
	b.add_theme_color_override("icon_disabled_color", Color(normal.r, normal.g, normal.b, 0.35))


## Decorative empty-state art (SVG), rendered crisp for the window's scale. kind: reports | log |
## search | list.
static func illustration(kind: String, w := 150, h := 112) -> Texture2D:
	var accent := "#59f280"
	var body := ""
	match kind:
		"reports":
			body = "<ellipse cx='80' cy='100' rx='46' ry='6' fill='#fff' fill-opacity='0.05'/>" \
				+ "<g transform='rotate(-8 60 54)'><rect x='30' y='20' width='62' height='74' rx='9' fill='#fff' fill-opacity='0.05' stroke='#fff' stroke-opacity='0.16' stroke-width='1.5'/></g>" \
				+ "<rect x='52' y='14' width='66' height='78' rx='9' fill='#101418' stroke='%s' stroke-opacity='0.55' stroke-width='1.8'/>" % accent \
				+ "<path d='M64 34h42M64 46h42M64 58h26' stroke='#fff' stroke-opacity='0.22' stroke-width='3.5' stroke-linecap='round'/>" \
				+ "<circle cx='104' cy='76' r='15' fill='%s' fill-opacity='0.16' stroke='%s' stroke-width='1.8'/>" % [accent, accent] \
				+ "<path d='M97.500 76.500l4.500 4.500 8.500-9' fill='none' stroke='%s' stroke-width='3' stroke-linecap='round' stroke-linejoin='round'/>" % accent
		"log":
			body = "<rect x='20' y='18' width='110' height='74' rx='10' fill='#101418' stroke='#fff' stroke-opacity='0.16' stroke-width='1.5'/>" \
				+ "<path d='M20 34h110' stroke='#fff' stroke-opacity='0.1'/><circle cx='32' cy='26' r='2.5' fill='#f26' fill-opacity='0.7'/><circle cx='41' cy='26' r='2.5' fill='#fb3' fill-opacity='0.7'/><circle cx='50' cy='26' r='2.5' fill='%s' fill-opacity='0.8'/>" % accent \
				+ "<path d='M32 48l8 6-8 6' fill='none' stroke='%s' stroke-width='3' stroke-linecap='round' stroke-linejoin='round'/>" % accent \
				+ "<path d='M48 68h44' stroke='#fff' stroke-opacity='0.25' stroke-width='3.5' stroke-linecap='round'/><rect x='48' y='51' width='8' height='14' rx='2' fill='%s' fill-opacity='0.8'/>" % accent
		"search":
			body = "<circle cx='68' cy='50' r='28' fill='#fff' fill-opacity='0.04' stroke='#fff' stroke-opacity='0.22' stroke-width='5'/>" \
				+ "<path d='M90 72l24 24' stroke='%s' stroke-opacity='0.8' stroke-width='8' stroke-linecap='round'/>" % accent \
				+ "<path d='M56 50h24' stroke='#fff' stroke-opacity='0.25' stroke-width='4' stroke-linecap='round'/>"
		_:
			body = "<rect x='28' y='22' width='94' height='16' rx='6' fill='#fff' fill-opacity='0.07'/><rect x='28' y='46' width='94' height='16' rx='6' fill='#fff' fill-opacity='0.05'/><rect x='28' y='70' width='94' height='16' rx='6' fill='#fff' fill-opacity='0.035'/>"
	var doc := "<svg xmlns='http://www.w3.org/2000/svg' width='150' height='112' viewBox='0 0 150 112'>" + body + "</svg>"
	var s: float = px_scale()
	return SVG.render(doc, Vector2i(int(w * s), int(h * s)), Vector2i(150, 112), "dev.ill.%s/%d/%d" % [kind, int(w * s), int(h * s)])


# --- theme -------------------------------------------------------------------------------------------

static func field_style(focused := false, radius := 8) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0, 0, 0, 0.38)
	s.border_color = Color(GREEN.r, GREEN.g, GREEN.b, 0.85) if focused else Color(1, 1, 1, 0.11)
	s.set_border_width_all(1)
	s.set_corner_radius_all(radius)
	s.content_margin_left = 10
	s.content_margin_right = 10
	s.content_margin_top = 6
	s.content_margin_bottom = 6
	s.anti_aliasing = true
	return s


static func theme() -> Theme:
	register_glyphs()
	var t: Theme = ShellUI.theme().duplicate()
	t.default_font = sans()
	t.default_font_size = 13
	for cls in ["Button", "CheckButton"]:
		t.set_font("font", cls, sans("semibold"))
		t.set_font_size("font_size", cls, 12)
		for state in ["normal", "hover", "pressed", "disabled"]:
			var sb = t.get_stylebox(state, cls)
			if sb is StyleBoxFlat:
				var d: StyleBoxFlat = sb.duplicate()
				d.set_corner_radius_all(8)
				d.content_margin_left = 11
				d.content_margin_right = 11
				d.content_margin_top = 5
				d.content_margin_bottom = 5
				t.set_stylebox(state, cls, d)
	t.set_font("font", "Label", sans())
	t.set_font_size("font_size", "Label", 12)
	t.set_font("font", "LineEdit", mono())
	t.set_font_size("font_size", "LineEdit", 13)
	t.set_stylebox("normal", "LineEdit", field_style(false))
	t.set_stylebox("focus", "LineEdit", field_style(true))
	t.set_stylebox("read_only", "LineEdit", field_style(false))
	t.set_color("font_placeholder_color", "LineEdit", Color(1, 1, 1, 0.3))
	t.set_color("caret_color", "LineEdit", GREEN)
	t.set_color("selection_color", "LineEdit", Color(GREEN.r, GREEN.g, GREEN.b, 0.3))
	t.set_font("font", "TextEdit", sans())
	t.set_font_size("font_size", "TextEdit", 14)
	t.set_stylebox("normal", "TextEdit", field_style(false, 10))
	t.set_stylebox("focus", "TextEdit", field_style(true, 10))
	t.set_stylebox("read_only", "TextEdit", field_style(false, 10))
	t.set_color("font_placeholder_color", "TextEdit", Color(1, 1, 1, 0.3))
	t.set_color("caret_color", "TextEdit", GREEN)
	t.set_color("selection_color", "TextEdit", Color(GREEN.r, GREEN.g, GREEN.b, 0.3))
	t.set_font_size("normal_font_size", "RichTextLabel", 12)
	t.set_font_size("mono_font_size", "RichTextLabel", 12)
	t.set_font("normal_font", "RichTextLabel", mono())
	t.set_font("bold_font", "RichTextLabel", mono())
	t.set_font("mono_font", "RichTextLabel", mono())
	# Green slider: thin rounded track, glowing fill, round grabber.
	var track := StyleBoxFlat.new()
	track.bg_color = Color(1, 1, 1, 0.12)
	track.set_corner_radius_all(3)
	track.content_margin_top = 3
	track.content_margin_bottom = 3
	var fill := StyleBoxFlat.new()
	fill.bg_color = Color(GREEN.r, GREEN.g, GREEN.b, 0.75)
	fill.set_corner_radius_all(3)
	fill.content_margin_top = 3
	fill.content_margin_bottom = 3
	t.set_stylebox("slider", "HSlider", track)
	t.set_stylebox("grabber_area", "HSlider", fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", fill)
	var knob_doc := "<svg xmlns='http://www.w3.org/2000/svg' width='20' height='20' viewBox='0 0 20 20'><circle cx='10' cy='10' r='8' fill='#59f280' stroke='#0b1a10' stroke-width='2'/><circle cx='10' cy='10' r='3' fill='#0b1a10' fill-opacity='0.35'/></svg>"
	var knob: Texture2D = SVG.render(knob_doc, Vector2i(20, 20), Vector2i(20, 20), "dev.knob")
	for g in ["grabber", "grabber_highlight", "grabber_disabled"]:
		t.set_icon(g, "HSlider", knob)
	# Thin scrollbars.
	for cls in ["VScrollBar", "HScrollBar"]:
		var g := StyleBoxFlat.new()
		g.bg_color = Color(1, 1, 1, 0.2)
		g.set_corner_radius_all(3)
		var gh := g.duplicate() as StyleBoxFlat
		gh.bg_color = Color(1, 1, 1, 0.38)
		var sc := StyleBoxFlat.new()
		sc.bg_color = Color(1, 1, 1, 0.03)
		sc.set_corner_radius_all(3)
		t.set_stylebox("grabber", cls, g)
		t.set_stylebox("grabber_highlight", cls, gh)
		t.set_stylebox("grabber_pressed", cls, gh)
		t.set_stylebox("scroll", cls, sc)
	return t


# --- text --------------------------------------------------------------------------------------------

static func label(parent: Node, text := "", size := 12, color := TEXT, use_mono := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.add_theme_font_override("font", mono() if use_mono else sans())
	l.autowrap_mode = TextServer.AUTOWRAP_OFF
	if parent != null:
		parent.add_child(l)
	return l


static func heading(parent: Node, text := "", size := 14, color := TEXT) -> Label:
	var l := label(parent, text, size, color)
	l.add_theme_font_override("font", sans("bold"))
	return l


static func caps(parent: Node, text: String, color := DIM, size := 10) -> Label:
	var l := label(parent, text.to_upper(), size, color)
	l.add_theme_font_override("font", sans("bold"))
	l.add_theme_constant_override("outline_size", 0)
	return l


static func wrap_label(parent: Node, text := "", size := 11, color := DIM, use_mono := false) -> Label:
	var l := label(parent, text, size, color, use_mono)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.custom_minimum_size = Vector2(60, 0)
	return l


# --- buttons -----------------------------------------------------------------------------------------

static func _box(bg: Color, border: Color, radius := 8, pad := Vector2(11, 5), bw := 1) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = border
	s.set_border_width_all(bw)
	s.set_corner_radius_all(radius)
	s.content_margin_left = pad.x
	s.content_margin_right = pad.x
	s.content_margin_top = pad.y
	s.content_margin_bottom = pad.y
	s.anti_aliasing = true
	return s


static func focus_ring(radius := 8) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = Color(0, 0, 0, 0)
	s.border_color = FOCUS
	s.set_border_width_all(2)
	s.set_corner_radius_all(radius)
	s.draw_center = false
	s.anti_aliasing = true
	return s


## Style a Button as a tinted chip (`tint` colours text + icon; fill is a low-alpha tint).
static func style_chip(b: Button, tint: Color, radius := 8, pad := Vector2(11, 5), filled := false) -> void:
	var fg: Color = Color(0.04, 0.06, 0.05) if filled else tint
	var nb: StyleBoxFlat
	var hb: StyleBoxFlat
	var pb: StyleBoxFlat
	if filled:
		nb = _box(tint, tint.lightened(0.2), radius, pad)
		hb = _box(tint.lightened(0.14), tint.lightened(0.3), radius, pad)
		pb = _box(tint.darkened(0.12), tint, radius, pad)
	else:
		nb = _box(Color(tint.r, tint.g, tint.b, 0.10), Color(tint.r, tint.g, tint.b, 0.24), radius, pad)
		hb = _box(Color(tint.r, tint.g, tint.b, 0.20), Color(tint.r, tint.g, tint.b, 0.45), radius, pad)
		pb = _box(Color(tint.r, tint.g, tint.b, 0.26), Color(tint.r, tint.g, tint.b, 0.75), radius, pad)
	b.add_theme_stylebox_override("normal", nb)
	b.add_theme_stylebox_override("hover", hb)
	b.add_theme_stylebox_override("pressed", pb)
	b.add_theme_stylebox_override("hover_pressed", pb)
	b.add_theme_stylebox_override("disabled", _box(Color(1, 1, 1, 0.04), Color(1, 1, 1, 0.06), radius, pad))
	b.add_theme_stylebox_override("focus", focus_ring(radius))
	b.add_theme_font_override("font", sans("semibold"))
	b.add_theme_font_size_override("font_size", 12)
	var hv: Color = fg if filled else tint.lightened(0.3)
	b.add_theme_color_override("font_color", fg)
	b.add_theme_color_override("font_hover_color", hv)
	b.add_theme_color_override("font_pressed_color", hv)
	b.add_theme_color_override("font_hover_pressed_color", hv)
	b.add_theme_color_override("font_focus_color", hv)
	b.add_theme_color_override("font_disabled_color", Color(1, 1, 1, 0.3))
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND


## A chip-style button. `tint` colours the text; `cb` is called on press (toggle: with the state).
static func button(parent: Node, text: String, cb: Callable, tint := GREEN, toggle := false, glyph := "") -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = toggle
	b.focus_mode = Control.FOCUS_ALL
	style_chip(b, tint)
	if glyph != "":
		set_icon(b, glyph, 13, tint, tint.lightened(0.3), tint)
	if toggle:
		b.toggled.connect(func(on: bool): cb.call(on))
	else:
		b.pressed.connect(cb)
	if parent != null:
		parent.add_child(b)
	return b


static func primary_button(parent: Node, text: String, glyph: String, cb: Callable, tint := GREEN) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_ALL
	style_chip(b, tint, 10, Vector2(18, 9), true)
	b.add_theme_font_override("font", sans("bold"))
	b.add_theme_font_size_override("font_size", 14)
	if glyph != "":
		set_icon(b, glyph, 16, Color(0.04, 0.06, 0.05), Color(0.04, 0.06, 0.05), Color(0.04, 0.06, 0.05))
	b.pressed.connect(cb)
	if parent != null:
		parent.add_child(b)
	return b


## A square-ish icon-only button with a tooltip.
static func icon_button(parent: Node, glyph: String, tip: String, cb: Callable, tint := DIM, size := 15) -> Button:
	var b := Button.new()
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_ALL
	style_chip(b, tint, 8, Vector2(7, 6))
	set_icon(b, glyph, size, tint, tint.lightened(0.4), tint.lightened(0.2))
	b.pressed.connect(cb)
	if parent != null:
		parent.add_child(b)
	return b


## A segmented-strip tab: transparent until selected, then a green-tinted pill.
static func tab_button(parent: Node, text: String, glyph: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_ALL
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var pad := Vector2(10, 6)
	b.add_theme_stylebox_override("normal", _box(Color(0, 0, 0, 0), Color(0, 0, 0, 0), 8, pad))
	b.add_theme_stylebox_override("hover", _box(Color(1, 1, 1, 0.07), Color(0, 0, 0, 0), 8, pad))
	var sel := _box(Color(GREEN.r, GREEN.g, GREEN.b, 0.17), Color(GREEN.r, GREEN.g, GREEN.b, 0.6), 8, pad)
	b.add_theme_stylebox_override("pressed", sel)
	b.add_theme_stylebox_override("hover_pressed", sel)
	b.add_theme_stylebox_override("focus", focus_ring(8))
	b.add_theme_font_override("font", sans("semibold"))
	b.add_theme_font_size_override("font_size", 12)
	b.add_theme_color_override("font_color", Color(1, 1, 1, 0.6))
	b.add_theme_color_override("font_hover_color", Color(1, 1, 1, 0.9))
	b.add_theme_color_override("font_focus_color", Color(1, 1, 1, 0.9))
	b.add_theme_color_override("font_pressed_color", GREEN)
	b.add_theme_color_override("font_hover_pressed_color", GREEN)
	set_icon(b, glyph, 14, Color(1, 1, 1, 0.6), Color(1, 1, 1, 0.9), GREEN)
	b.add_theme_constant_override("h_separation", 6)
	b.pressed.connect(cb)
	if parent != null:
		parent.add_child(b)
	return b


## A coloured status capsule ("SET", "PASS", "×3", ...). Returns the PanelContainer; its Label
## is meta "label".
static func pill(parent: Node, text: String, color := GREEN, glyph := "", solid := false) -> PanelContainer:
	var p := PanelContainer.new()
	var bg: Color = Color(color.r, color.g, color.b, 0.9) if solid else Color(color.r, color.g, color.b, 0.15)
	var bd: Color = Color(color.r, color.g, color.b, 0.0) if solid else Color(color.r, color.g, color.b, 0.3)
	p.add_theme_stylebox_override("panel", _box(bg, bd, 20, Vector2(8, 2)))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var h := hbox(p, 4)
	var fg: Color = Color(0.04, 0.06, 0.05) if solid else color
	if glyph != "":
		icon_rect(h, glyph, 11, fg)
	var l := label(h, text, 10, fg)
	l.add_theme_font_override("font", sans("bold"))
	p.set_meta("label", l)
	if parent != null:
		parent.add_child(p)
	return p


static func dot(parent: Node, color: Color, size := 8) -> Control:
	var p := Panel.new()
	var s := StyleBoxFlat.new()
	s.bg_color = color
	s.set_corner_radius_all(size)
	s.anti_aliasing = true
	p.add_theme_stylebox_override("panel", s)
	p.custom_minimum_size = Vector2(size, size)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if parent != null:
		parent.add_child(p)
	return p


# --- layout ------------------------------------------------------------------------------------------

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
	f.add_theme_constant_override("v_separation", 6)
	if parent != null:
		parent.add_child(f)
	return f


static func spacer(parent: Node, w := 0.0, h := 0.0, expand := false) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(w, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if expand:
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if parent != null:
		parent.add_child(c)
	return c


static func rule(parent: Node, color := LINE) -> ColorRect:
	var r := ColorRect.new()
	r.color = color
	r.custom_minimum_size = Vector2(0, 1)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if parent != null:
		parent.add_child(r)
	return r


static func scroll(parent: Node) -> ScrollContainer:
	var s := ScrollContainer.new()
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.follow_focus = true
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	if parent != null:
		parent.add_child(s)
	return s


## A padded margin wrapper so content never touches a scroll bar / panel edge.
static func margin(parent: Node, l := 12, t := 10, r := 12, b := 10) -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", l)
	m.add_theme_constant_override("margin_top", t)
	m.add_theme_constant_override("margin_right", r)
	m.add_theme_constant_override("margin_bottom", b)
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if parent != null:
		parent.add_child(m)
	return m


static func panel_style(bg := SURFACE, border := LINE, radius := 10) -> StyleBoxFlat:
	var s := _box(bg, border, radius, Vector2(12, 10))
	return s


static func card(parent: Node, highlight := false) -> VBoxContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", panel_style(
		Color(GREEN.r, GREEN.g, GREEN.b, 0.07) if highlight else SURFACE,
		Color(GREEN.r, GREEN.g, GREEN.b, 0.4) if highlight else LINE))
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if parent != null:
		parent.add_child(p)
	return vbox(p, 6)


## A titled card: icon tile + title in the header (extra header widgets go in body meta "head"),
## a hairline, then the body VBox (returned). `footer` is a small dim note under the body.
static func section_card(parent: Node, title: String, glyph := "", accent := GREEN, footer := "") -> VBoxContainer:
	var outer := card(parent)
	outer.add_theme_constant_override("separation", 8)
	var head := hbox(outer, 8)
	if glyph != "":
		var tile := PanelContainer.new()
		tile.add_theme_stylebox_override("panel", _box(Color(accent.r, accent.g, accent.b, 0.16), Color(0, 0, 0, 0), 7, Vector2(5, 5), 0))
		tile.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		icon_rect(tile, glyph, 14, accent)
		head.add_child(tile)
	var t := heading(head, title, 14)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rule(outer)
	var body := vbox(outer, 7)
	if footer != "":
		wrap_label(outer, footer, 11, FAINT)
	body.set_meta("head", head)
	body.set_meta("title", t)
	return body


## A "key  value" row: dim caption on the left, mono value (returned) on the right.
static func kv_row(parent: Node, title: String, value := "—", key_w := 130, color := TEXT) -> Label:
	var r := hbox(parent, 8)
	var k := label(r, title, 12, DIM)
	k.custom_minimum_size = Vector2(key_w, 0)
	var v := label(r, value, 12, color, true)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	v.clip_text = true
	return v


## "Title ........ [switch]" row; returns the switch (a toggle Button).
static func toggle_row(parent: Node, title: String, note := "") -> Button:
	var row := hbox(parent, 10)
	var col := vbox(row, 0)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	label(col, title, 13, TEXT)
	if note != "":
		label(col, note, 10, FAINT)
	var sw := DevSwitch.new()
	row.add_child(sw)
	return sw


static func search_field(parent: Node, placeholder: String, on_change: Callable) -> LineEdit:
	var p := PanelContainer.new()
	var n := _box(Color(0, 0, 0, 0.38), Color(1, 1, 1, 0.11), 9, Vector2(10, 3))
	var f := _box(Color(0, 0, 0, 0.38), Color(GREEN.r, GREEN.g, GREEN.b, 0.85), 9, Vector2(10, 3))
	p.add_theme_stylebox_override("panel", n)
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var h := hbox(p, 8)
	icon_rect(h, "magnifyingglass", 14, DIM)
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.clear_button_enabled = true
	e.flat = true
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	e.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	e.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	e.add_theme_font_override("font", sans())
	e.text_changed.connect(func(t: String): on_change.call(t))
	e.focus_entered.connect(func(): p.add_theme_stylebox_override("panel", f))
	e.focus_exited.connect(func(): p.add_theme_stylebox_override("panel", n))
	h.add_child(e)
	e.set_meta("panel", p)
	if parent != null:
		parent.add_child(p)
	return e


## Empty-state block: art + title + hint, centred.
static func empty_state(parent: Node, kind: String, title: String, hint := "") -> VBoxContainer:
	var v := vbox(parent, 4)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var tr := TextureRect.new()
	tr.texture = illustration(kind)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.custom_minimum_size = Vector2(150, 112)
	tr.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(tr)
	var t := heading(v, title, 14, Color(1, 1, 1, 0.8))
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if hint != "":
		var h := wrap_label(v, hint, 11, FAINT)
		h.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return v


## A GridContainer that switches between 1 and `cols` columns by its own width.
static func responsive_grid(parent: Node, cols := 2, min_cell := 440, hsep := 10, vsep := 10) -> GridContainer:
	var g := GridContainer.new()
	g.columns = cols
	g.add_theme_constant_override("h_separation", hsep)
	g.add_theme_constant_override("v_separation", vsep)
	g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	g.resized.connect(func():
		var want: int = clampi(int(g.size.x / float(min_cell)), 1, cols)
		if want != g.columns:
			g.columns = want)
	if parent != null:
		parent.add_child(g)
	return g


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


static func status_glyph(status: String) -> String:
	match status:
		"PASS":
			return "checkmark.circle.fill"
		"WARN":
			return "exclamationmark.triangle.fill"
		_:
			return "xmark.circle.fill"


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
