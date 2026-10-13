# Plugin Editor chrome. Pane colours are the Apple editor's (PluginEditorView: 0.10 / 0.13 / 0.09).
# Type, fields, sliders, menus and the amber accent come from the NovaSwift kit, which is the
# Godot mirror of the SwiftUI theme (NovaTheme / NovaControls). Icons are the kit's SVG glyphs
# (NovaSVG) plus the editor-only glyphs registered below.
extends RefCounted

const T = preload("res://ui/novaswift/NovaTheme.gd")
const SVG = preload("res://ui/novaswift/NovaSVG.gd")

const BG := Color(0.10, 0.10, 0.10)
const SIDE := Color(0.075, 0.075, 0.075)
const BAR := Color(0.13, 0.13, 0.13)
const WELL := Color(0.12, 0.12, 0.12)
const CARD := Color(0.135, 0.135, 0.135)
const CARD_LINE := Color(1, 1, 1, 0.07)
const CANVAS := Color(0.045, 0.05, 0.065)
const AMBER := T.AMBER
const TEXT := Color(0.92, 0.92, 0.92)
const SECONDARY := Color(1, 1, 1, 0.62)
const TERTIARY := Color(1, 1, 1, 0.40)
const NEW_C := T.GREEN
const MOD_C := T.AMBER
const PLUGIN_C := T.TEAL
const LINE := T.GROUP_LINE
const ROW := T.CARD_BG
const BAD := T.RED
const WARN := T.ORANGE
const INFO := Color(0.45, 0.65, 1.0)
const INK := Color(0.12, 0.08, 0.02)
const HOVER := Color(1, 1, 1, 0.06)
const SELECT := Color(1.0, 0.7, 0.28, 0.16)

## type code -> [icon, category]. Unlisted types fall back on their editor kind.
const TYPE_INFO := {
	"shïp": ["rocket", "Ships & Combat"], "shän": ["film", "Ships & Combat"],
	"wëap": ["bolt.fill", "Ships & Combat"], "oütf": ["cpu", "Ships & Combat"],
	"bööm": ["burst", "Ships & Combat"],
	"sÿst": ["sun.max", "Universe"], "spöb": ["planet", "Universe"], "nëbu": ["cloud", "Universe"],
	"röid": ["rock", "Universe"], "gövt": ["flag.fill", "Universe"], "flët": ["fleet", "Universe"],
	"düde": ["person.2.fill", "Universe"], "përs": ["person.crop.circle", "Universe"],
	"mïsn": ["scroll", "Story & Economy"], "crön": ["clock", "Story & Economy"],
	"chär": ["id.card", "Story & Economy"], "ränk": ["crown.fill", "Story & Economy"],
	"jünk": ["shippingbox.fill", "Story & Economy"], "öops": ["chart.downtrend", "Story & Economy"],
	"dësc": ["doc.text", "Text"], "STR#": ["text.quote", "Text"], "STR ": ["text.quote", "Text"],
	"TEXT": ["doc.text", "Text"], "NSgx": ["sparkles", "Graphics"], "NSbl": ["sparkles", "Graphics"],
	"spïn": ["film", "Graphics"], "rlëD": ["film", "Graphics"], "rlë8": ["film", "Graphics"],
	"PICT": ["photo", "Graphics"], "snd ": ["speaker.wave.2", "Sound"],
	"ïntf": ["layout", "Interface"], "cölr": ["paintpalette", "Interface"],
	"DITL": ["macwindow", "Interface"], "DLOG": ["macwindow", "Interface"], "ALRT": ["macwindow", "Interface"],
	"CNTL": ["switch.2", "Interface"], "MENU": ["list.bullet", "Interface"],
	"CURS": ["cursorarrow", "Interface"], "crsr": ["cursorarrow", "Interface"],
}
const CATEGORIES := ["Ships & Combat", "Universe", "Story & Economy", "Text", "Graphics", "Sound", "Interface", "Other"]

## Editor-only glyphs (24 x 24 bodies, `C` = colour), registered into the kit's SVG set once.
const GLYPHS := {
	"undo": "<path d='M9 14L4 9l5-5'/><path d='M4 9h10.5a5.5 5.5 0 010 11H11'/>",
	"redo": "<path d='M15 14l5-5-5-5'/><path d='M20 9H9.5a5.5 5.5 0 000 11H13'/>",
	"link.slash": "<path d='M9 17H7A5 5 0 017 7h2'/><path d='M15 7h2a5 5 0 013.5 8.5'/><path d='M8 12h2.5'/><path d='M3 3l18 18'/>",
	"zoom.in": "<circle cx='10.5' cy='10.5' r='6.5'/><path d='M15.5 15.5l5 5M8 10.5h5M10.5 8v5'/>",
	"zoom.out": "<circle cx='10.5' cy='10.5' r='6.5'/><path d='M15.5 15.5l5 5M8 10.5h5'/>",
	"hand": "<path d='M18 11V6a2 2 0 00-4 0v5'/><path d='M14 10V4a2 2 0 00-4 0v6'/><path d='M10 10.5V6a2 2 0 00-4 0v8'/><path d='M18 8a2 2 0 014 0v6a8 8 0 01-8 8h-2c-2.8 0-4.5-.9-6-2.3l-3.6-3.6a2 2 0 012.8-2.8L7 15'/>",
	"cursorarrow": "<path fill='C' d='M5 3.5l13.5 6.6-5.8 1.9-2.1 5.9z'/>",
	"speaker.wave.2": "<path fill='C' d='M4 9.5h3.5L12 5.5v13l-4.5-4H4z'/><path d='M15.5 9a4 4 0 010 6M18.5 6.5a7.5 7.5 0 010 11'/>",
	"code": "<path d='M8 7l-5 5 5 5M16 7l5 5-5 5M14 4l-4 16'/>",
	"cylinder": "<ellipse cx='12' cy='5.5' rx='8' ry='3'/><path d='M4 5.5v13c0 1.7 3.6 3 8 3s8-1.3 8-3v-13'/><path d='M4 12c0 1.7 3.6 3 8 3s8-1.3 8-3'/>",
	"files": "<path d='M14 3H8a2 2 0 00-2 2v11a2 2 0 002 2h9a2 2 0 002-2V8z'/><path d='M14 3v5h5'/><path d='M3 8v11a2 2 0 002 2h9'/>",
	"orbit": "<circle cx='12' cy='12' r='3' fill='C' stroke='none'/><ellipse cx='12' cy='12' rx='10' ry='4.5' transform='rotate(-25 12 12)'/><circle cx='19.6' cy='8.4' r='1.6' fill='C' stroke='none'/>",
	"planet": "<circle cx='12' cy='12' r='6'/><path d='M7 15.6c-3.2 2.2-4.8 4.1-4.1 4.8 1.1 1.1 6.6-1.8 11.4-6.6s7.7-10.3 6.6-11.4c-.7-.7-2.6.9-4.8 4.1'/>",
	"sun.max": "<circle cx='12' cy='12' r='4' fill='C' stroke='none'/><path d='M12 2.5V5M12 19v2.5M2.5 12H5M19 12h2.5M5.3 5.3l1.8 1.8M16.9 16.9l1.8 1.8M5.3 18.7l1.8-1.8M16.9 7.1l1.8-1.8'/>",
	"id.card": "<rect x='2.5' y='5' width='19' height='14' rx='2.5'/><circle cx='8.5' cy='10.8' r='2.2'/><path d='M5.3 16c.6-1.5 1.7-2.3 3.2-2.3s2.6.8 3.2 2.3M14 10h4.5M14 13.5h3'/>",
	"burst": "<path d='M12 2.5l1.8 5 4.9-2.4-2.4 4.9 5 1.8-5 1.8 2.4 4.9-4.9-2.4-1.8 5-1.8-5-4.9 2.4 2.4-4.9-5-1.8 5-1.8-2.4-4.9 4.9 2.4z'/>",
	"film": "<rect x='3' y='3' width='18' height='18' rx='2.5'/><path d='M7.5 3v18M16.5 3v18M3 7.5h4.5M3 12h18M3 16.5h4.5M16.5 7.5H21M16.5 16.5H21'/>",
	"chart.downtrend": "<path d='M3 6l6.5 6.5 4-4L21 16'/><path d='M15 16h6v-6'/>",
	"cloud": "<path d='M7 18.5h10.5a4 4 0 00.6-7.95A6 6 0 006.4 9.1 4.75 4.75 0 007 18.5z'/>",
	"rock": "<path d='M7 4.5l7-1.5 5.5 4 1.5 6.5-3.5 6-7.5 1.5L4 17l-1-6.5z'/><path d='M9 9.5l2.5 1M14 14.5l1.5-1.5'/>",
	"layout": "<rect x='3' y='3' width='18' height='18' rx='2.5'/><path d='M3 9h18M9 9v12'/>",
	"paintpalette": "<path d='M12 3a9 9 0 000 18c1.4 0 2-1 2-2 0-1.5-1.5-1.5-1.5-3s1.1-2 2.5-2h2a4 4 0 004-4c0-3.9-4-7-9-7z'/><circle cx='7.5' cy='11' r='1.3' fill='C' stroke='none'/><circle cx='10' cy='7' r='1.3' fill='C' stroke='none'/><circle cx='15' cy='7.5' r='1.3' fill='C' stroke='none'/>",
	"text.quote": "<path d='M4 5h16a1.5 1.5 0 011.5 1.5v9A1.5 1.5 0 0120 17h-8l-5 4v-4H4a1.5 1.5 0 01-1.5-1.5v-9A1.5 1.5 0 014 5z'/><path d='M8 9.5h8M8 12.5h5'/>",
	"binary": "<rect x='4' y='3.5' width='5' height='7' rx='2.5'/><path d='M15 3.5h2v7M15 10.5h4M5 13.5h2v7M5 20.5h4'/><rect x='15' y='13.5' width='5' height='7' rx='2.5'/>",
	"macwindow": "<rect x='3' y='4.5' width='18' height='15' rx='2.5'/><path d='M3 9h18'/><circle cx='6.3' cy='6.8' r='.7' fill='C' stroke='none'/><circle cx='8.8' cy='6.8' r='.7' fill='C' stroke='none'/>",
	"rocket": "<path d='M12 2.5c3 2.2 4.5 5.4 4.5 9.5v4.5h-9V12c0-4.1 1.5-7.3 4.5-9.5z'/><circle cx='12' cy='10' r='1.7'/><path d='M7.5 13.5L5 16.5v3l2.5-1.5M16.5 13.5l2.5 3v3L16.5 18M10 19.5l2 2.2 2-2.2'/>",
	"fleet": "<path fill='C' d='M12 3l2.6 5.2H9.4zM6 12l2.6 5.2H3.4zM18 12l2.6 5.2h-5.2z'/>",
	"fit": "<path d='M4 9V4h5M20 15v5h-5M15 4h5v5M9 20H4v-5'/>",
	"sidebar": "<rect x='3' y='4' width='18' height='16' rx='2.5'/><path d='M9 4v16'/>",
	"square.dashed": "<path d='M8 3.5H6A2.5 2.5 0 003.5 6v2M3.5 11v2M3.5 16v2A2.5 2.5 0 006 20.5h2M11 3.5h2M11 20.5h2M16 3.5h2A2.5 2.5 0 0120.5 6v2M20.5 11v2M20.5 16v2a2.5 2.5 0 01-2.5 2.5h-2'/>",
	"keyboard": "<rect x='2' y='6' width='20' height='12' rx='2.5'/><path d='M6 10h.01M10 10h.01M14 10h.01M18 10h.01M8 14h8' stroke-width='2'/>",
	"arrow.up.forward.app": "<path d='M14 4h6v6M20 4l-9 9'/><path d='M18 14v4.5A1.5 1.5 0 0116.5 20h-11A1.5 1.5 0 014 18.5v-11A1.5 1.5 0 015.5 6H10'/>",
	"plus.circle": "<circle cx='12' cy='12' r='9.5'/><path d='M12 8v8M8 12h8'/>",
	"switch.2": "<rect x='3' y='5' width='18' height='6' rx='3'/><circle cx='18' cy='8' r='1.6' fill='C' stroke='none'/><rect x='3' y='13' width='18' height='6' rx='3'/><circle cx='6' cy='16' r='1.6' fill='C' stroke='none'/>",
	"list.bullet": "<path d='M9 6h11M9 12h11M9 18h11'/><circle cx='4.5' cy='6' r='1.2' fill='C' stroke='none'/><circle cx='4.5' cy='12' r='1.2' fill='C' stroke='none'/><circle cx='4.5' cy='18' r='1.2' fill='C' stroke='none'/>",
}

static var _registered := false
static var _icons := {}


static func _register() -> void:
	if _registered:
		return
	_registered = true
	for name in GLYPHS:
		if not SVG.has(str(name)):
			SVG.register(str(name), str(GLYPHS[name]))


## Backing scale of the screen (2 on Retina), so icons rasterise at physical resolution.
static func screen_scale() -> float:
	if DisplayServer.get_name() == "headless":
		return 1.0
	return maxf(1.0, DisplayServer.screen_get_scale())


## An icon texture rasterised at `px` logical pixels times the backing scale. Display it at `px`
## (button `icon_max_width`, or `icon_rect`).
static func icon(name: String, px := 16, color: Color = TEXT) -> Texture2D:
	_register()
	var key := "%s/%d/%s" % [name, px, color.to_html()]
	if not _icons.has(key):
		var phys := int(round(px * screen_scale()))
		_icons[key] = SVG.texture(name, phys, color) if SVG.has(name) else T.icon(name, phys, color)
	return _icons[key]


static func icon_rect(name: String, px := 16, color: Color = TEXT) -> TextureRect:
	var r := TextureRect.new()
	r.texture = icon(name, px, color)
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.custom_minimum_size = Vector2(px, px)
	r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


static func type_icon(code: String, kind := "") -> String:
	if TYPE_INFO.has(code):
		return str(TYPE_INFO[code][0])
	match kind:
		"graphic": return "photo"
		"sound": return "speaker.wave.2"
		"text": return "doc.text"
		"form": return "slider.horizontal.3"
	return "binary"


static func type_category(code: String, kind := "") -> String:
	if TYPE_INFO.has(code):
		return str(TYPE_INFO[code][1])
	match kind:
		"graphic": return "Graphics"
		"sound": return "Sound"
		"text": return "Text"
	return "Other"


static func prov_color(prov: String) -> Color:
	match prov:
		"new": return NEW_C
		"override": return MOD_C
		"plugin": return PLUGIN_C
	return TERTIARY


static func prov_label(prov: String) -> String:
	match prov:
		"new": return "New"
		"override": return "Modified"
		"plugin": return "From plug-in"
		"base": return "Base game"
	return prov.capitalize()


static func fill(color: Color, radius := 0) -> StyleBoxFlat:
	return T.box(color, radius)


## Put the shared SwiftUI-matched theme on a screen, plus the editor's list, text, split, tooltip
## and dialog styling on a copy so Settings and Plug-ins keep their own.
static func install(root: Control) -> void:
	var theme: Theme = T.theme().duplicate()
	theme.set_font("font", "ItemList", T.font("body"))
	theme.set_font_size("font_size", "ItemList", 13)
	theme.set_color("font_color", "ItemList", TEXT)
	theme.set_color("font_hovered_color", "ItemList", TEXT)
	theme.set_color("font_selected_color", "ItemList", TEXT)
	theme.set_stylebox("panel", "ItemList", T.empty())
	theme.set_stylebox("focus", "ItemList", T.empty())
	theme.set_stylebox("selected", "ItemList", T.box(SELECT, 6, AMBER, 0))
	theme.set_stylebox("selected_focus", "ItemList", T.box(SELECT, 6, AMBER, 0))
	theme.set_stylebox("hovered", "ItemList", T.box(HOVER, 6))
	theme.set_stylebox("hovered_selected", "ItemList", T.box(SELECT, 6))
	theme.set_stylebox("hovered_selected_focus", "ItemList", T.box(SELECT, 6))
	theme.set_color("guide_color", "ItemList", Color(0, 0, 0, 0))
	theme.set_constant("v_separation", "ItemList", 6)
	theme.set_constant("h_separation", "ItemList", 8)
	theme.set_constant("icon_margin", "ItemList", 8)

	for cls in ["TextEdit", "CodeEdit"]:
		theme.set_stylebox("normal", cls, T.box(T.FIELD_BG, 6, T.FIELD_BORDER, 1, Vector2(10, 8)))
		theme.set_stylebox("focus", cls, T.box(T.FIELD_BG, 6, AMBER, 1, Vector2(10, 8)))
		theme.set_stylebox("read_only", cls, T.box(Color(0, 0, 0, 0.25), 6, T.FIELD_BORDER, 1, Vector2(10, 8)))
		theme.set_color("font_color", cls, TEXT)
		theme.set_color("font_readonly_color", cls, SECONDARY)
		theme.set_color("caret_color", cls, AMBER)
		theme.set_color("selection_color", cls, Color(AMBER.r, AMBER.g, AMBER.b, 0.35))
		theme.set_color("current_line_color", cls, Color(1, 1, 1, 0.03))
		theme.set_font("font", cls, T.font("body"))
		theme.set_font_size("font_size", cls, 14)

	for cls in ["HSplitContainer", "VSplitContainer"]:
		theme.set_constant("separation", cls, 1)
		theme.set_constant("minimum_grab_thickness", cls, 8)
		theme.set_icon("grabber", cls, ImageTexture.new())
		theme.set_stylebox("split_bar_background", cls, T.box(Color(1, 1, 1, 0.06)))

	theme.set_stylebox("panel", "TooltipPanel", T.box(Color(0.16, 0.16, 0.17), 6, Color(1, 1, 1, 0.14), 1, Vector2(9, 6)))
	theme.set_color("font_color", "TooltipLabel", TEXT)
	theme.set_font("font", "TooltipLabel", T.font("body"))
	theme.set_font_size("font_size", "TooltipLabel", 12)

	theme.set_stylebox("panel", "PopupPanel", T.box(Color(0.11, 0.11, 0.12), 10, Color(1, 1, 1, 0.16), 1, Vector2(8, 8)))
	theme.set_stylebox("panel", "AcceptDialog", T.box(Color(0.12, 0.12, 0.13), 0, Color(0, 0, 0, 0), 0, Vector2(14, 12)))
	theme.set_stylebox("embedded_border", "Window", T.box(Color(0.12, 0.12, 0.13), 10, Color(1, 1, 1, 0.16), 1))
	theme.set_stylebox("embedded_unfocused_border", "Window", T.box(Color(0.12, 0.12, 0.13), 10, Color(1, 1, 1, 0.1), 1))
	theme.set_color("title_color", "Window", TEXT)
	theme.set_font("title_font", "Window", T.font("body", "semibold"))
	theme.set_font_size("title_font_size", "Window", 14)
	theme.set_constant("title_height", "Window", 32)

	theme.set_stylebox("normal", "LineEdit", T.box(T.FIELD_BG, 6, T.FIELD_BORDER, 1, Vector2(9, 5)))
	theme.set_stylebox("focus", "LineEdit", T.box(T.FIELD_BG, 6, AMBER, 1, Vector2(9, 5)))
	theme.set_stylebox("read_only", "LineEdit", T.box(Color(0, 0, 0, 0.25), 6, T.FIELD_BORDER, 1, Vector2(9, 5)))
	theme.set_font_size("font_size", "LineEdit", 13)
	theme.set_font_size("font_size", "OptionButton", 13)
	theme.set_font_size("font_size", "CheckBox", 13)
	theme.set_font_size("font_size", "PopupMenu", 13)
	theme.set_constant("v_separation", "PopupMenu", 6)
	theme.set_color("font_color", "CheckBox", TEXT)
	theme.set_stylebox("normal", "OptionButton", T.box(T.MENU_CHIP_BG, 6, T.MENU_CHIP_BORDER, 1, Vector2(9, 4)))
	theme.set_stylebox("hover", "OptionButton", T.box(Color(0.15, 0.15, 0.15), 6, T.MENU_CHIP_BORDER, 1, Vector2(9, 4)))
	theme.set_stylebox("pressed", "OptionButton", T.box(Color(0.15, 0.15, 0.15), 6, AMBER, 1, Vector2(9, 4)))
	theme.set_stylebox("separator", "HSeparator", T.box(LINE))
	theme.set_constant("separation", "HSeparator", 1)
	root.theme = theme


# --- builders -----------------------------------------------------------------------------------

## kind: "plain" (bordered grey), "accent" (amber fill), "ghost" (no fill until hover),
## "danger" (red text), "nav" (sidebar row).
static func button(text: String, cb: Callable, kind := "plain", icon_name := "") -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_ALL
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var ink := TEXT
	var bg := T.BORDERED_BG
	var hover_bg := Color(1, 1, 1, 0.2)
	match kind:
		"accent":
			ink = INK
			bg = AMBER
			hover_bg = AMBER.lightened(0.1)
		"ghost", "nav":
			bg = Color(0, 0, 0, 0)
			hover_bg = HOVER
		"danger":
			ink = BAD
			bg = Color(BAD.r, BAD.g, BAD.b, 0.12)
			hover_bg = Color(BAD.r, BAD.g, BAD.b, 0.22)
	var pad := Vector2(10, 5) if text != "" else Vector2(6, 5)
	if kind == "nav":
		pad = Vector2(10, 7)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	T.style_text(b, "caption", "medium", ink, 13)
	for st in ["font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(st, ink)
	b.add_theme_color_override("font_disabled_color", Color(ink.r, ink.g, ink.b, 0.35))
	b.add_theme_stylebox_override("normal", T.box(bg, 7, Color(0, 0, 0, 0), 0, pad))
	b.add_theme_stylebox_override("hover", T.box(hover_bg, 7, Color(0, 0, 0, 0), 0, pad))
	b.add_theme_stylebox_override("pressed", T.box(hover_bg.darkened(0.1) if kind == "accent" else Color(1, 1, 1, 0.24), 7, Color(0, 0, 0, 0), 0, pad))
	b.add_theme_stylebox_override("disabled", T.box(Color(bg.r, bg.g, bg.b, bg.a * 0.4), 7, Color(0, 0, 0, 0), 0, pad))
	b.add_theme_stylebox_override("focus", T.empty())
	b.add_theme_constant_override("h_separation", 7)
	if icon_name != "":
		set_icon(b, icon_name, ink)
	if cb.is_valid():
		b.pressed.connect(cb)
	return b


static func set_icon(b: Button, icon_name: String, color: Color = TEXT, px := 15) -> void:
	b.icon = icon(icon_name, px, color)
	b.add_theme_constant_override("icon_max_width", px)
	b.add_theme_color_override("icon_normal_color", Color.WHITE)
	b.add_theme_color_override("icon_hover_color", Color.WHITE)
	b.add_theme_color_override("icon_pressed_color", Color.WHITE)
	b.add_theme_color_override("icon_focus_color", Color.WHITE)
	b.add_theme_color_override("icon_disabled_color", Color(1, 1, 1, 0.35))


## Square icon-only button with a tooltip.
static func icon_button(icon_name: String, tip: String, cb: Callable, color: Color = TEXT, kind := "ghost") -> Button:
	var b := button("", cb, kind, "")
	set_icon(b, icon_name, color, 16)
	b.tooltip_text = tip
	b.custom_minimum_size = Vector2(30, 28)
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return b


static func label(text: String, size := 13, color: Color = TEXT, weight := "") -> Label:
	var l := Label.new()
	l.text = text
	var role := "caption" if size <= 12 else "body"
	var w := weight if weight != "" else ("medium" if size <= 11 else "regular")
	T.style_text(l, role, w, color, size)
	return l


static func heading(text: String, size := 18) -> Label:
	var l := Label.new()
	l.text = text
	T.style_text(l, "body", "semibold", TEXT, size)
	return l


## Small caps section label ("PERFORMANCE").
static func caps(text: String, color: Color = TERTIARY) -> Label:
	var l := label(text.to_upper(), 10, color, "semibold")
	return l


static func wrap_label(text: String, size := 12, color: Color = SECONDARY) -> Label:
	var l := label(text, size, color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


static func field(placeholder := "", icon_name := "") -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	T.style_text(e, "body", "regular", TEXT, 13)
	e.add_theme_color_override("font_placeholder_color", Color(1, 1, 1, 0.32))
	e.add_theme_color_override("caret_color", AMBER)
	if icon_name != "":
		e.right_icon = icon(icon_name, 14, TERTIARY)
	e.select_all_on_focus = false
	return e


static func spin(value: int, lo := -32768, hi := 32767) -> SpinBox:
	var s := SpinBox.new()
	s.min_value = lo
	s.max_value = hi
	s.rounded = true
	s.allow_greater = false
	s.allow_lesser = false
	s.value = value
	s.custom_minimum_size = Vector2(104, 0)
	s.select_all_on_focus = true
	var le := s.get_line_edit()
	T.style_text(le, "body", "regular", TEXT, 13)
	return s


## A rounded card panel; `pad` is the inner margin. Returns the PanelContainer, children go in
## the VBox at `card.get_child(0)` — use `card_body(card)`.
static func card(pad := 14, bg: Color = CARD, border: Color = CARD_LINE) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", T.box(bg, 10, border, 1, Vector2(pad, pad)))
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	p.add_child(v)
	return p


static func card_body(c: PanelContainer) -> VBoxContainer:
	return c.get_child(0) as VBoxContainer


## Rounded pill with text, tinted by `color`.
static func chip(text: String, color: Color = SECONDARY, icon_name := "") -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", T.box(Color(color.r, color.g, color.b, 0.14), 9, Color(color.r, color.g, color.b, 0.28), 1, Vector2(7, 1)))
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 4)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(h)
	if icon_name != "":
		h.add_child(icon_rect(icon_name, 11, color))
	var l := label(text, 11, color, "semibold")
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(l)
	return p


static func hbox(sep := 8) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	return h


static func vbox(sep := 8) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	return v


static func spacer() -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return c


static func margin(child: Control, l := 16, t := 16, r := 16, b := 16) -> MarginContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", l)
	m.add_theme_constant_override("margin_top", t)
	m.add_theme_constant_override("margin_right", r)
	m.add_theme_constant_override("margin_bottom", b)
	m.add_child(child)
	return m


static func hline() -> ColorRect:
	var r := ColorRect.new()
	r.color = LINE
	r.custom_minimum_size = Vector2(0, 1)
	r.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return r


## Centered illustration + title + body + optional buttons, for empty panes.
static func empty_state(icon_name: String, title: String, body: String, actions: Array = []) -> CenterContainer:
	var c := CenterContainer.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var v := vbox(10)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.custom_minimum_size = Vector2(340, 0)
	c.add_child(v)
	var disc := PanelContainer.new()
	disc.add_theme_stylebox_override("panel", T.box(Color(1, 1, 1, 0.05), 32, Color(1, 1, 1, 0.08), 1, Vector2(16, 16)))
	disc.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	disc.add_child(icon_rect(icon_name, 32, TERTIARY))
	v.add_child(disc)
	var t := heading(title, 16)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(t)
	var b := wrap_label(body, 13, SECONDARY)
	b.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.add_child(b)
	if not actions.is_empty():
		var row := hbox(8)
		row.alignment = BoxContainer.ALIGNMENT_CENTER
		for a in actions:
			row.add_child(a)
		v.add_child(row)
	return c


## A full-width clickable row: Button with an HBox of children laid over it.
static func row_button(cb: Callable, selected := false) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_ALL
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var bg := SELECT if selected else Color(0, 0, 0, 0)
	b.add_theme_stylebox_override("normal", T.box(bg, 7))
	b.add_theme_stylebox_override("hover", T.box(SELECT if selected else HOVER, 7))
	b.add_theme_stylebox_override("pressed", T.box(Color(1, 1, 1, 0.1), 7))
	b.add_theme_stylebox_override("focus", T.empty())
	if cb.is_valid():
		b.pressed.connect(cb)
	return b


## Lay `content` over `b` with padding; children ignore the mouse so the button gets clicks.
static func fill_row(b: Button, content: Control, pad_h := 10, pad_v := 6) -> void:
	var m := margin(content, pad_h, pad_v, pad_h, pad_v)
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ignore_mouse(content)
	b.add_child(m)
	b.custom_minimum_size.y = maxf(b.custom_minimum_size.y, content.get_combined_minimum_size().y + pad_v * 2)
	m.minimum_size_changed.connect(func() -> void:
		b.custom_minimum_size.y = m.get_combined_minimum_size().y)


static func _ignore_mouse(n: Node) -> void:
	if n is Control:
		(n as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE
	for c in n.get_children():
		_ignore_mouse(c)


static func scroll(child: Control) -> ScrollContainer:
	var s := ScrollContainer.new()
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	child.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.add_child(child)
	return s


static func mono() -> Font:
	var f := SystemFont.new()
	f.font_names = PackedStringArray(["SF Mono", "Menlo", "Consolas", "DejaVu Sans Mono", "monospace"])
	return f
