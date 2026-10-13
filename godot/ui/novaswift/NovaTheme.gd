# NOVA Swift — NovaSwift UI kit: theme tokens (the Godot mirror of the Apple app's
# UI/NovaUITheme.swift, NovaFont.swift, NovaFormControls.swift and the SwiftUI system colours the
# port's own screens use). Every NovaSwift-styled screen (Settings, Plug-ins, pause sidebar,
# pilot roster, alerts, tutorial cards) takes its colours, sizes and fonts from here.
#
#   const AMBER      novaAmber (1.0, 0.7, 0.28): headings, selected rows, primary actions
#   fonts            role(): title / heading (Rubik = Charcoal stand-in), body / caption / button /
#                    hud (Arimo = Geneva stand-in) at NovaFontRole's base sizes; `system()` is the
#                    SwiftUI system-font stand-in the Plug-ins hub uses (Arimo)
#   box()            a StyleBoxFlat from a few arguments (the Godot form of SwiftUI's
#                    RoundedRectangle().fill().overlay(strokeBorder))
#   theme()          the shared Theme: label colours, form-control styles (check box, slider, option
#                    picker, line edit, scroll bar, popup menu) in Apple's look
#
# Loaded with preload() (no class_name), like Controls.gd. State is static.
extends RefCounted

const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")
const Icons = preload("res://ui/novaswift/NovaIcons.gd")

# --- colours (NovaUITheme.fallback + SwiftUI dark-mode system colours) -----------------------
const AMBER := Color(1.0, 0.7, 0.28)            # novaAmber
const ACCENT := Color(1.0, 0.68, 0.25)          # AccentColor.colorset (the tint of bordered-prominent)
const WHITE := Color(1, 1, 1)
const SECONDARY := Color(1, 1, 1, 0.55)         # .secondary on a dark background
const TERTIARY := Color(1, 1, 1, 0.30)          # .tertiary
const RED := Color(1.0, 0.27, 0.23)             # Color.red (dark)
const GREEN := Color(0.19, 0.82, 0.35)
const ORANGE := Color(1.0, 0.62, 0.04)
const INDIGO := Color(0.37, 0.36, 0.90)
const TEAL := Color(0.25, 0.78, 0.88)
const DEBUG_GREEN := Color(0.35, 0.95, 0.5)     # GameMenuView's Debug Suite row
const CHIP_BG := Color(0.14, 0.14, 0.14)        # NovaSegmentedPicker unselected / NovaSelectRow
const FIELD_BG := Color(0.04, 0.04, 0.04)       # NovaTextField fill
const FIELD_BORDER := Color(0.30, 0.30, 0.30)
const MENU_CHIP_BG := Color(0.10, 0.10, 0.10)   # NovaMenuPicker chip
const MENU_CHIP_BORDER := Color(0.35, 0.35, 0.35)
const GROUP_BG := Color(0.04, 0.04, 0.04)       # a grouped Form section over the black dialog
const GROUP_LINE := Color(1, 1, 1, 0.09)        # the row separator inside a group
const SCRIM := Color(0, 0, 0, 0.55)             # NovaDialog / DialogChrome scrim
const CARD_BG := Color(1, 1, 1, 0.07)           # Color.primary.opacity(0.07): plug-in cards, rows
const CARD_BORDER := Color(1, 1, 1, 0.08)
const FIELD_BG_SOFT := Color(1, 1, 1, 0.08)     # the Plug-ins search field fill
const BORDERED_BG := Color(1, 1, 1, 0.14)       # stock .bordered button on dark
const PLUGINS_BG_TOP := Color(0.06, 0.06, 0.06) # PluginsView backdrop gradient
const PLUGINS_BG_BOTTOM := Color(0.11, 0.11, 0.11)

# --- NovaFontRole sizes -----------------------------------------------------------------------
const SIZE := {"title": 28, "heading": 20, "body": 15, "caption": 13, "button": 15, "hud": 14}
const WEIGHT := {"regular": 400, "medium": 500, "semibold": 600, "bold": 700}
const _WGHT_TAG := 2003265652   # TextServer.name_to_tag("wght"): the weight axis of both bundled fonts

static var _fonts := {}
static var _theme: Theme
static var _icon_cache := {}


## The font for a role at a weight ("regular" / "medium" / "semibold" / "bold").
## title + heading are Charcoal's stand-in (Rubik); everything else Geneva's (Arimo).
static func font(role: String = "body", weight: String = "regular") -> Font:
	var key := role + "/" + weight
	if _fonts.has(key):
		return _fonts[key]
	var base: Font = ClassicTheme.chrome_font() if role == "title" or role == "heading" else ClassicTheme.body_font()
	var v := FontVariation.new()
	v.base_font = base
	v.variation_opentype = {_WGHT_TAG: int(WEIGHT.get(weight, 400))}
	_fonts[key] = v
	return v


## The SwiftUI system font the Plug-ins hub draws in (no novaFont there): Arimo, a Helvetica redraw.
static func system(weight: String = "regular") -> Font:
	return font("body", weight)


static func size_of(role: String) -> int:
	return int(SIZE.get(role, 15))


## Apply a role to a Label / Button / LineEdit-like control: font, size, colour.
static func style_text(c: Control, role: String = "body", weight := "regular", color: Variant = null,
		size := -1) -> void:
	c.add_theme_font_override("font", font(role, weight))
	c.add_theme_font_size_override("font_size", size if size > 0 else size_of(role))
	if color != null:
		c.add_theme_color_override("font_color", color)


# --- style boxes ---------------------------------------------------------------------------------

## SwiftUI's RoundedRectangle().fill(bg).overlay(strokeBorder(border, bw)): `pad` is the content
## padding (h, v).
static func box(bg: Color, radius := 5, border := Color(0, 0, 0, 0), bw := 0, pad := Vector2(0, 0)) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.set_corner_radius_all(radius)
	if bw > 0:
		s.border_color = border
		s.set_border_width_all(bw)
	s.content_margin_left = pad.x
	s.content_margin_right = pad.x
	s.content_margin_top = pad.y
	s.content_margin_bottom = pad.y
	s.anti_aliasing = true
	return s


static func empty() -> StyleBoxEmpty:
	return StyleBoxEmpty.new()


## An icon texture from the kit's vector glyph set (see NovaIcons.gd), cached.
static func icon(name: String, px := 16, color := Color(1, 1, 1)) -> Texture2D:
	var key := "%s/%d/%s" % [name, px, color.to_html()]
	if not _icon_cache.has(key):
		_icon_cache[key] = Icons.texture(name, px, color)
	return _icon_cache[key]


# --- the shared Theme ----------------------------------------------------------------------------

static func theme() -> Theme:
	if _theme != null:
		return _theme
	var t := Theme.new()
	t.default_font = font("body")
	t.default_font_size = 15
	t.set_color("font_color", "Label", WHITE)
	t.set_font("font", "Label", font("body"))
	t.set_font_size("font_size", "Label", 15)
	for cls in ["Button", "CheckBox", "CheckButton", "OptionButton", "MenuButton"]:
		t.set_font("font", cls, font("body"))
		t.set_font_size("font_size", cls, 15)
		t.set_color("font_color", cls, WHITE)
		t.set_color("font_hover_color", cls, WHITE)
		t.set_color("font_pressed_color", cls, WHITE)
		t.set_color("font_focus_color", cls, WHITE)
		t.set_color("font_disabled_color", cls, Color(1, 1, 1, 0.4))
		t.set_color("icon_normal_color", cls, WHITE)
		t.set_color("icon_hover_color", cls, WHITE)
		t.set_color("icon_pressed_color", cls, WHITE)
		t.set_color("icon_focus_color", cls, WHITE)
		t.set_color("icon_disabled_color", cls, Color(1, 1, 1, 0.4))
		# No stock focus box: the kit draws its own (nav-only) ring, see NovaControls.attach_focus.
		t.set_stylebox("focus", cls, empty())
	# Bare Buttons default to the stock bordered look; the kit's builders override per kind.
	t.set_stylebox("normal", "Button", box(BORDERED_BG, 7, Color(0, 0, 0, 0), 0, Vector2(12, 6)))
	t.set_stylebox("hover", "Button", box(Color(1, 1, 1, 0.2), 7, Color(0, 0, 0, 0), 0, Vector2(12, 6)))
	t.set_stylebox("pressed", "Button", box(Color(1, 1, 1, 0.28), 7, Color(0, 0, 0, 0), 0, Vector2(12, 6)))
	t.set_stylebox("disabled", "Button", box(Color(1, 1, 1, 0.06), 7, Color(0, 0, 0, 0), 0, Vector2(12, 6)))
	# Check box (NovaToggleStyle): amber 16 px box.
	for cls in ["CheckBox", "CheckButton"]:
		t.set_icon("checked", cls, box_icon(true, false))
		t.set_icon("unchecked", cls, box_icon(false, false))
		t.set_icon("checked_disabled", cls, box_icon(true, true))
		t.set_icon("unchecked_disabled", cls, box_icon(false, true))
		t.set_constant("h_separation", cls, 10)
		for st in ["normal", "hover", "pressed", "disabled", "hover_pressed"]:
			t.set_stylebox(st, cls, empty())
	# Slider (NovaSlider): 4 px capsule track, amber fill, 16 px amber thumb with a white rim.
	var track := StyleBoxFlat.new()
	track.bg_color = Color(0.22, 0.22, 0.22)
	track.set_corner_radius_all(2)
	track.content_margin_top = 2
	track.content_margin_bottom = 2
	var fill := StyleBoxFlat.new()
	fill.bg_color = AMBER
	fill.set_corner_radius_all(2)
	fill.content_margin_top = 2
	fill.content_margin_bottom = 2
	t.set_stylebox("slider", "HSlider", track)
	t.set_stylebox("grabber_area", "HSlider", fill)
	t.set_stylebox("grabber_area_highlight", "HSlider", fill)
	var knob := knob_icon()
	t.set_icon("grabber", "HSlider", knob)
	t.set_icon("grabber_highlight", "HSlider", knob)
	t.set_icon("grabber_disabled", "HSlider", knob)
	t.set_constant("center_grabber", "HSlider", 1)
	# Menu picker chip (NovaMenuPicker): dark pill with a hairline, value + up/down chevron.
	t.set_stylebox("normal", "OptionButton", box(MENU_CHIP_BG, 5, MENU_CHIP_BORDER, 1, Vector2(10, 5)))
	t.set_stylebox("hover", "OptionButton", box(Color(0.14, 0.14, 0.14), 5, MENU_CHIP_BORDER, 1, Vector2(10, 5)))
	t.set_stylebox("pressed", "OptionButton", box(Color(0.14, 0.14, 0.14), 5, AMBER, 1, Vector2(10, 5)))
	t.set_stylebox("disabled", "OptionButton", box(MENU_CHIP_BG, 5, Color(0.2, 0.2, 0.2), 1, Vector2(10, 5)))
	t.set_icon("arrow", "OptionButton", icon("chevron.up.chevron.down", 12, AMBER))
	t.set_constant("arrow_margin", "OptionButton", 6)
	t.set_constant("h_separation", "OptionButton", 6)
	# Text field (NovaTextField).
	t.set_stylebox("normal", "LineEdit", box(FIELD_BG, 5, FIELD_BORDER, 1, Vector2(10, 8)))
	t.set_stylebox("read_only", "LineEdit", box(FIELD_BG, 5, FIELD_BORDER, 1, Vector2(10, 8)))
	t.set_stylebox("focus", "LineEdit", box(FIELD_BG, 5, AMBER, 1, Vector2(10, 8)))
	t.set_color("font_color", "LineEdit", WHITE)
	t.set_color("font_placeholder_color", "LineEdit", Color(1, 1, 1, 0.35))
	t.set_color("caret_color", "LineEdit", AMBER)
	t.set_color("selection_color", "LineEdit", Color(AMBER.r, AMBER.g, AMBER.b, 0.4))
	t.set_font("font", "LineEdit", font("body"))
	t.set_font_size("font_size", "LineEdit", 15)
	# Popup menus (the menu picker's list, FileDialog).
	var pm := box(Color(0.11, 0.11, 0.11), 8, Color(1, 1, 1, 0.16), 1, Vector2(4, 4))
	t.set_stylebox("panel", "PopupMenu", pm)
	t.set_stylebox("hover", "PopupMenu", box(AMBER, 5))
	t.set_color("font_color", "PopupMenu", WHITE)
	t.set_color("font_hover_color", "PopupMenu", Color.BLACK)
	t.set_font("font", "PopupMenu", font("body"))
	t.set_font_size("font_size", "PopupMenu", 15)
	t.set_constant("v_separation", "PopupMenu", 8)
	# Scroll bars: thin, translucent, rounded.
	var sb := box(Color(1, 1, 1, 0.07), 4)
	var grab := box(Color(1, 1, 1, 0.35), 4)
	var grab_hi := box(Color(1, 1, 1, 0.5), 4)
	for cls in ["VScrollBar", "HScrollBar"]:
		t.set_stylebox("scroll", cls, sb)
		t.set_stylebox("scroll_focus", cls, sb)
		t.set_stylebox("grabber", cls, grab)
		t.set_stylebox("grabber_highlight", cls, grab_hi)
		t.set_stylebox("grabber_pressed", cls, grab_hi)
	t.set_stylebox("panel", "PanelContainer", box(Color(0, 0, 0, 0)))
	_theme = t
	ClassicTheme.track(null)
	ClassicTheme.on_nav_changed(_apply_nav)
	_apply_nav(ClassicTheme.nav_active)
	return t


## Keyboard / pad focus ring (the controller cursor's affordance): an amber 2 px outline drawn only
## while the last input was keyboard or pad, never after mouse input.
static func _apply_nav(on: bool) -> void:
	if _theme == null:
		return
	for cls in ["Button", "OptionButton", "MenuButton"]:
		_theme.set_stylebox("focus", cls, box(Color(0, 0, 0, 0), 8, AMBER, 2) if on else empty())
	for cls in ["CheckBox", "CheckButton"]:
		_theme.set_stylebox("focus", cls, box(Color(AMBER.r, AMBER.g, AMBER.b, 0.10), 6, AMBER, 2, Vector2(4, 2)) if on else empty())
	_theme.set_stylebox("focus", "HSlider", box(Color(0, 0, 0, 0), 6, AMBER, 2) if on else empty())


## The 16 px check box (NovaToggleStyle): amber fill + black check when on, near-black with a grey
## rim when off.
static func box_icon(checked: bool, disabled: bool) -> Texture2D:
	var key := "box/%s/%s" % [checked, disabled]
	if _icon_cache.has(key):
		return _icon_cache[key]
	var n := 16
	var ss := 4
	var img := Image.create(n * ss, n * ss, false, Image.FORMAT_RGBA8)
	var a := 0.5 if disabled else 1.0
	var edge := Color(AMBER.r, AMBER.g, AMBER.b, a) if checked else Color(0.4, 0.4, 0.4, a)
	var body := edge if checked else Color(0.08, 0.08, 0.08, a)
	var rad := 3.0 * ss
	for y in n * ss:
		for x in n * ss:
			var d := _round_rect_dist(Vector2(x + 0.5, y + 0.5), Vector2(n * ss, n * ss), rad)
			if d > 0.0:
				continue
			img.set_pixel(x, y, edge if d > -float(ss) else body)
	img.resize(n, n, Image.INTERPOLATE_LANCZOS)
	var tex := ImageTexture.create_from_image(img)
	if checked:
		# the black check, composited from the vector set
		var chk := Icons.image("checkmark.bold", n, Color(0, 0, 0, a))
		img.blend_rect(chk, Rect2i(0, 0, n, n), Vector2i.ZERO)
		tex = ImageTexture.create_from_image(img)
	_icon_cache[key] = tex
	return tex


static func _round_rect_dist(p: Vector2, size: Vector2, r: float) -> float:
	var q := (p - size * 0.5).abs() - (size * 0.5 - Vector2(r, r))
	return Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0) - r


static func knob_icon() -> Texture2D:
	if _icon_cache.has("knob"):
		return _icon_cache["knob"]
	var n := 16
	var ss := 4
	var img := Image.create(n * ss, n * ss, false, Image.FORMAT_RGBA8)
	var c := Vector2(n * ss * 0.5, n * ss * 0.5)
	for y in n * ss:
		for x in n * ss:
			var d := Vector2(x + 0.5, y + 0.5).distance_to(c)
			if d <= n * ss * 0.5:
				img.set_pixel(x, y, Color(1, 1, 1, 0.55) if d > n * ss * 0.5 - ss else AMBER)
	img.resize(n, n, Image.INTERPOLATE_LANCZOS)
	var tex := ImageTexture.create_from_image(img)
	_icon_cache["knob"] = tex
	return tex
