# NOVA Swift — Plug-ins screen: browse the online catalog (search, filter chips, a featured row, a
# card grid, detail pages, install / update), the installed list (enable / reveal / delete / import)
# and the load order. The Godot counterpart of the Apple app's Launcher/PluginsView.swift +
# Plugins/{InstalledPluginsView,PluginCard,PluginDetailView,TCAddOnsSection,RemoteImage}.swift,
# drawn with the NovaSwift UI kit (ui/novaswift/): a full-window dark gradient, a top bar (back
# chevron on a detail page, title, Import, refresh, Apply, Done), an icon segmented picker
# (Browse / Installed / Load order), a pinned search field + compact filter chips, a responsive
# grid of plug-in cards with SVG artwork, and SVG illustrations for the empty states.
# All rules live in the shared Swift core behind the bridge's `NovaPlugins` class (Plugins.swift):
# discovery, the original-vs-manual load order, the merge, the catalog, download + checksum +
# unpack. This file is presentation only.
#
# Reach it with `Plugins.new()` + `add_child` + `setup(nova)`; it emits `closed` when done.
# Wiring (main menu "Plug-ins" button, Settings button) is in docs/GODOT_LAYER.md.
#
# Behaviour copied from Apple:
#   * Without the "Manual plug-in order" enhancement every installed plug-in loads automatically
#     (the original rule); only a total conversion can be switched. Load order is the original's
#     alphabetical order. With it on, each plug-in has an enable switch and Up / Down (or drag).
#   * Changes take effect by reloading the game data (a loading overlay shows while it runs).
#     Apple reloads after every change; here changes are batched and applied when you press
#     Apply, leave the screen, or an install finishes.
#   * Only the player's own user plug-in folder is deletable; the game's own "Nova Plug-ins"
#     folder is read-only here.
#   * Downloads are HTTPS only, checksum-verified by NovaSwiftPluginStore, and never mirrored.
#
# Gamepad / keyboard: pure Godot focus navigation (d-pad / arrows move, A / Enter activate,
# LB / RB switch tab, B / Esc back out of a detail page first, then close).
extends CanvasLayer

const ShellUI = preload("res://screens/ShellUI.gd")
const T = preload("res://ui/novaswift/NovaTheme.gd")
const NC = preload("res://ui/novaswift/NovaControls.gd")
const Alert = preload("res://ui/novaswift/NovaAlert.gd")
const SVG = preload("res://ui/novaswift/NovaSVG.gd")

signal closed

const TABS := ["Browse", "Installed", "Load order"]
const TAB_ICONS := {"Browse": "icloud.and.arrow.down", "Installed": "externaldrive", "Load order": "list.bullet"}
const FILTERS := ["Popular", "Recent", "Total conversions", "Ships", "Story", "Graphics",
	"Gameplay", "Installed", "Updates"]
const FILTER_ICONS := {"Popular": "star.fill", "Recent": "clock", "Total conversions": "sparkles",
	"Ships": "airplane", "Story": "book", "Graphics": "photo", "Gameplay": "slider.horizontal.3",
	"Installed": "checkmark.circle.fill", "Updates": "pl.arrows.circlepath"}
const FILTER_TITLES := {"Popular": "Popular plug-ins", "Recent": "Recently updated",
	"Total conversions": "Total conversions", "Ships": "Ships", "Story": "Story plug-ins",
	"Graphics": "Graphics", "Gameplay": "Gameplay", "Installed": "Installed from the catalog",
	"Updates": "Updates available"}
const BUNDLED_CATALOG := "res://data/PluginCatalog.json"
const KIND_SYMBOL := {"totalConversion": "sparkles", "patch": "hammer", "gameplay": "slider.horizontal.3",
	"graphics": "photo", "unknown": "puzzlepiece.extension"}
const PRIMARY_GLYPH := {"arrow.down.circle.fill": "square.and.arrow.down", "checkmark.circle.fill": "checkmark"}
const CARD_MIN_W := 420.0
const PAGE_MAX_W := 1200.0

static var _glyphs_ready := false
static var _grads := {}

var tab := "Browse"
var filter := "Popular"
var query := ""
var detail_id := ""            # catalog entry shown on the detail page
var first_control: Control
var tab_buttons := {}

var _nova: Object
var _pl: Object
var _root: Control
var _content: VBoxContainer
var _scroll: ScrollContainer
var _pad: MarginContainer
var _status: Label
var _status_wrap: Control
var _overlay: Control
var _busy_apply := false
var _apply_btn: Button
var _title: Label
var _title_icon: Control
var _back_btn: Button
var _tabbar: Control
var _filterbar: Control
var _search: LineEdit
var _search_panel: Control
var _search_timer: Timer
var _chip_buttons := {}
var _refresh_label: Label
var _poll := 0.0
var _scale := 1.0
var _cols_built := 0
var _offline := false
var _icons := {}               # url -> Array[TextureRect] waiting for bytes
var _import_dialog: FileDialog
var _delete_confirm := ""      # plug-in id awaiting a second press of Delete
var _tc_add_open := false      # the "add plug-in to <conversion>" candidate list is expanded
var _tc_add_confirm := ""      # base-game-only candidate awaiting a second press ("Add anyway?")
var _tc_analysed := ""         # conversion whose record-overlap check was started this session
var _tc_was_analysing := false


static func _register_glyphs() -> void:
	if _glyphs_ready:
		return
	_glyphs_ready = true
	SVG.register("pl.grip", "<g fill='C' stroke='none'><circle cx='9' cy='5.5' r='1.6'/><circle cx='15' cy='5.5' r='1.6'/><circle cx='9' cy='12' r='1.6'/><circle cx='15' cy='12' r='1.6'/><circle cx='9' cy='18.5' r='1.6'/><circle cx='15' cy='18.5' r='1.6'/></g>")
	SVG.register("pl.minus.circle", "<circle cx='12' cy='12' r='9'/><path d='M7.5 12h9'/>")
	SVG.register("pl.plus.circle", "<circle cx='12' cy='12' r='9'/><path d='M12 7.5v9M7.5 12h9'/>")
	SVG.register("pl.wifi.slash", "<path d='M2.5 9a15 15 0 0119 0M5.5 12.5a10.5 10.5 0 0113 0M9 16a5.5 5.5 0 016 0'/><circle cx='12' cy='19.4' r='1.1' fill='C' stroke='none'/><path d='M3.5 3.5l17 17'/>")
	SVG.register("pl.arrows.circlepath", "<path d='M20 11a8 8 0 00-14-4.5L4 9M4 4v5h5M4 13a8 8 0 0014 4.5L20 15M20 20v-5h-5'/>")
	SVG.register("pl.compass", "<circle cx='12' cy='12' r='9'/><path d='M15.8 8.2l-2.2 5.4-5.4 2.2 2.2-5.4z'/>")
	SVG.register("pl.layers", "<path d='M12 3l9 4.5-9 4.5-9-4.5z' fill='C' fill-opacity='0.25'/><path d='M3 12l9 4.5 9-4.5M3 16.5l9 4.5 9-4.5'/>")
	SVG.register("pl.person.2", "<circle cx='9' cy='8' r='3.2'/><path d='M3 19c0-3 2.7-5 6-5s6 2 6 5'/><circle cx='17' cy='9' r='2.4'/><path d='M17 14c2.4 0 4.2 1.6 4.2 4'/>")


func setup(nova: Object, start_tab := "Browse") -> void:
	_register_glyphs()
	_scale = clampf(DisplayServer.screen_get_scale(), 1.0, 3.0)
	_nova = nova
	layer = 72
	_pl = ClassDB.instantiate("NovaPlugins")
	_pl.attach(nova)
	_pl.set_bundled_catalog(ProjectSettings.globalize_path(BUNDLED_CATALOG))
	_pl.rescan()
	_pl.catalog_offline()
	_pl.catalog_refresh()
	tab = start_tab if TABS.has(start_tab) else "Browse"
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.theme = T.theme()
	add_child(_root)
	# LinearGradient(white 0.06 -> 0.11, top to bottom)
	var g := Gradient.new()
	g.set_color(0, T.PLUGINS_BG_TOP)
	g.set_color(1, T.PLUGINS_BG_BOTTOM)
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill_from = Vector2(0.5, 0)
	gt.fill_to = Vector2(0.5, 1)
	gt.width = 8
	gt.height = 64
	var bg := TextureRect.new()
	bg.texture = gt
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP   # nothing below the screen is clickable
	_root.add_child(bg)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.add_theme_constant_override("separation", 0)
	_root.add_child(box)

	# Top bar: [Back] [icon] Title ........ [refreshing] Import  refresh  Apply  Done
	var top := MarginContainer.new()
	for s in ["left", "right"]:
		top.add_theme_constant_override("margin_" + s, 20)
	top.add_theme_constant_override("margin_top", 14)
	top.add_theme_constant_override("margin_bottom", 12)
	box.add_child(top)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	top.add_child(head)
	_back_btn = _btn(head, "Back", func(): detail_id = ""; _render(), 0, "bordered", "chevron.left")
	_back_btn.visible = false
	first_control = null
	_title_icon = _icon_tile(head, 34, T.AMBER, "puzzlepiece.extension.fill", 0.16)
	_title = _t(head, "Plug-ins", 24, "bold")
	_title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	NC.hspacer(head)
	_refresh_label = _t(head, "Updating catalog...", 12, "regular", T.SECONDARY)
	_refresh_label.visible = false
	var imp := _btn(head, "Import", _open_import, 0, "bordered", "square.and.arrow.down")
	imp.tooltip_text = "Import a .zip, .rez, .ndat or folder"
	var refresh := NC.bordered_icon_button("arrow.clockwise", func(): _pl.catalog_refresh(); _render(), "Refresh catalog")
	_hi_icon(refresh, "arrow.clockwise", 16, T.WHITE)
	head.add_child(refresh)
	_apply_btn = _btn(head, "Apply", func(): await _apply(); _render(), 0, "bordered", "checkmark.circle.fill")
	_apply_btn.visible = false
	var done := _btn(head, "Done", _done, 0, "primary")
	done.custom_minimum_size.x = 76
	first_control = null

	# Tab row: icon segmented picker (left) + the search field (right, Browse only)
	var tb := MarginContainer.new()
	for s in ["left", "right"]:
		tb.add_theme_constant_override("margin_" + s, 20)
	tb.add_theme_constant_override("margin_bottom", 10)
	box.add_child(tb)
	_tabbar = tb
	var seg_row := HBoxContainer.new()
	seg_row.add_theme_constant_override("separation", 16)
	tb.add_child(seg_row)
	var seg := _segmented()
	seg_row.add_child(seg)
	NC.hspacer(seg_row)
	_search = NC.search_field(seg_row, "Search plug-ins, authors, tags", query,
		func(t: String): query = t; _search_timer.start(),
		func(_t: String): _search_timer.stop(); _render(false))
	_search_panel = _search.get_meta("panel")
	_search_panel.size_flags_horizontal = Control.SIZE_SHRINK_END
	_search_panel.custom_minimum_size = Vector2(400, 40)
	_style_search(false)
	_search.focus_entered.connect(_style_search.bind(true))
	_search.focus_exited.connect(_style_search.bind(false))
	_search_timer = Timer.new()
	_search_timer.one_shot = true
	_search_timer.wait_time = 0.22
	_search_timer.timeout.connect(func(): _render(false))
	add_child(_search_timer)

	# Filter chips (Browse only), pinned under the tabs
	var fb := MarginContainer.new()
	for s in ["left", "right"]:
		fb.add_theme_constant_override("margin_" + s, 20)
	fb.add_theme_constant_override("margin_bottom", 10)
	box.add_child(fb)
	_filterbar = fb
	var chips := HFlowContainer.new()
	chips.add_theme_constant_override("h_separation", 6)
	chips.add_theme_constant_override("v_separation", 6)
	fb.add_child(chips)
	for f in FILTERS:
		_chip_buttons[f] = _chip(chips, f, str(FILTER_ICONS.get(f, "")), func(): filter = f; _render(false))

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.follow_focus = true
	box.add_child(_scroll)
	_pad = MarginContainer.new()
	_pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for s in ["left", "right"]:
		_pad.add_theme_constant_override("margin_" + s, 20)
	_pad.add_theme_constant_override("margin_top", 4)
	_pad.add_theme_constant_override("margin_bottom", 28)
	_scroll.add_child(_pad)
	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 14)
	_pad.add_child(_content)
	_scroll.resized.connect(_on_scroll_resized)

	# Status strip (transient results: imported, loaded N resources...)
	var sw := MarginContainer.new()
	sw.add_theme_constant_override("margin_left", 20)
	sw.add_theme_constant_override("margin_right", 20)
	sw.add_theme_constant_override("margin_bottom", 8)
	box.add_child(sw)
	_status_wrap = sw
	_status = _t(sw, "", 12, "regular", T.SECONDARY, true)
	sw.visible = false

	_import_dialog = FileDialog.new()
	_import_dialog.file_mode = FileDialog.FILE_MODE_OPEN_ANY
	_import_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_import_dialog.use_native_dialog = false
	_import_dialog.title = "Import a plug-in (.zip, .rez, .ndat or a folder)"
	_import_dialog.size = Vector2i(900, 560)
	_import_dialog.file_selected.connect(_import)
	_import_dialog.dir_selected.connect(_import)
	_import_dialog.theme = T.theme()
	add_child(_import_dialog)

	_render()


# ------------------------------------------------------------------ small UI helpers

func _set_status(text: String) -> void:
	_status.text = text
	_status_wrap.visible = text != ""


## A label in the Plug-ins hub's system font.
func _t(parent: Control, text: String, size := 14, weight := "regular", color: Color = T.WHITE, wrap := false) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_override("font", T.system(weight))
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if parent != null:
		parent.add_child(l)
	return l


func _note(parent: Control, text: String, size := 14, color: Color = T.SECONDARY) -> Label:
	return _t(parent, text, size, "regular", color, true)


func _hbox(parent: Control, sep := 8) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	if parent != null:
		parent.add_child(h)
	return h


func _vbox(parent: Control, sep := 6) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	if parent != null:
		parent.add_child(v)
	return v


## An SVG glyph as a crisp TextureRect (rasterised at the display scale, drawn at `px`).
func _svg(parent: Control, glyph: String, px := 16, color: Color = T.WHITE) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = SVG.texture(glyph, int(ceil(px * _scale)), color)
	tr.custom_minimum_size = Vector2(px, px)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if parent != null:
		parent.add_child(tr)
	return tr


## Put a hi-DPI SVG glyph on a button's icon slot (drawn at `px`).
func _hi_icon(b: Button, glyph: String, px := 16, color: Color = T.WHITE) -> void:
	b.icon = SVG.texture(glyph, int(ceil(px * _scale)), color)
	b.expand_icon = false
	b.add_theme_constant_override("icon_max_width", px)


func _btn(parent: Control, text: String, cb: Callable, width := 0, kind := "bordered", icon := "") -> Button:
	var b := NC.button(text, kind, cb, icon)
	if width > 0:
		b.custom_minimum_size.x = width
	if icon != "":
		var fg: Color = T.WHITE
		var glyph := icon
		if kind == "primary":
			fg = Color(0.05, 0.04, 0.02)
			glyph = str(PRIMARY_GLYPH.get(icon, icon))   # solid glyphs lose their cut-out on a light fill
		elif kind == "destructive":
			fg = T.RED
		_hi_icon(b, glyph, 16, fg)
	b.custom_minimum_size.y = 34
	parent.add_child(b)
	if first_control == null:
		first_control = b
	return b


func _icon_btn(parent: Control, glyph: String, tip: String, cb: Callable, color: Color = T.SECONDARY, size := 34, px := 17) -> Button:
	var b := NC.icon_button(glyph, cb, color, size, px)
	_hi_icon(b, glyph, px, color)
	b.tooltip_text = tip
	parent.add_child(b)
	return b


func _badge(parent: Control, text: String, color: Color = T.SECONDARY, icon := "") -> void:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", T.box(Color(color.r, color.g, color.b, 0.16), 20, Color(0, 0, 0, 0), 0, Vector2(8, 3)))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h := _hbox(p, 4)
	if icon != "":
		_svg(h, icon, 11, color)
	_t(h, text, 11, "semibold", color)
	parent.add_child(p)


## A rounded tinted square with an SVG glyph (title bar, section headers, fact tiles).
func _icon_tile(parent: Control, size: int, tint: Color, glyph: String, bg_alpha := 0.2) -> Control:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(size, size)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", T.box(Color(tint.r, tint.g, tint.b, bg_alpha), int(size * 0.28)))
	var c := CenterContainer.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(c)
	_svg(c, glyph, int(size * 0.56), tint)
	parent.add_child(p)
	return p


## Compact filter chip: capsule with a glyph; accent fill + dark text when selected.
func _chip(parent: Control, text: String, glyph: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.focus_mode = Control.FOCUS_ALL
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var pad := Vector2(11, 5)
	b.add_theme_stylebox_override("normal", T.box(Color(1, 1, 1, 0.08), 20, Color(1, 1, 1, 0.06), 1, pad))
	b.add_theme_stylebox_override("hover", T.box(Color(1, 1, 1, 0.15), 20, Color(1, 1, 1, 0.06), 1, pad))
	b.add_theme_stylebox_override("pressed", T.box(T.ACCENT, 20, T.ACCENT, 1, pad))
	b.add_theme_stylebox_override("hover_pressed", T.box(T.ACCENT.lightened(0.1), 20, T.ACCENT, 1, pad))
	T.style_text(b, "body", "medium", T.WHITE, 13)
	b.add_theme_font_override("font", T.system("medium"))
	b.add_theme_color_override("font_pressed_color", Color(0.06, 0.05, 0.03))
	b.add_theme_color_override("font_hover_pressed_color", Color(0.06, 0.05, 0.03))
	b.add_theme_color_override("font_focus_color", T.WHITE)
	if glyph != "":
		_hi_icon(b, glyph, 13, Color.WHITE)
		b.add_theme_constant_override("h_separation", 5)
		b.add_theme_color_override("icon_normal_color", Color(1, 1, 1, 0.75))
		b.add_theme_color_override("icon_hover_color", Color.WHITE)
		b.add_theme_color_override("icon_focus_color", Color.WHITE)
		b.add_theme_color_override("icon_pressed_color", Color(0.06, 0.05, 0.03))
		b.add_theme_color_override("icon_hover_pressed_color", Color(0.06, 0.05, 0.03))
	b.pressed.connect(cb)
	NC.grow_on_focus(b, 1.05)
	parent.add_child(b)
	return b


## The Browse / Installed / Load order picker: a dark pill holding icon + label segments.
func _segmented() -> Control:
	var wrap := PanelContainer.new()
	wrap.add_theme_stylebox_override("panel", T.box(Color(1, 1, 1, 0.07), 13, Color(1, 1, 1, 0.07), 1, Vector2(3, 3)))
	var h := _hbox(wrap, 2)
	var buttons: Array = []
	for i in TABS.size():
		var tname: String = TABS[i]
		var b := Button.new()
		b.text = tname
		b.toggle_mode = true
		b.button_pressed = tname == tab
		b.focus_mode = Control.FOCUS_ALL
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var pad := Vector2(18, 7)
		b.add_theme_stylebox_override("normal", T.box(Color(0, 0, 0, 0), 10, Color(0, 0, 0, 0), 0, pad))
		b.add_theme_stylebox_override("hover", T.box(Color(1, 1, 1, 0.09), 10, Color(0, 0, 0, 0), 0, pad))
		b.add_theme_stylebox_override("pressed", T.box(T.AMBER, 10, Color(0, 0, 0, 0), 0, pad))
		b.add_theme_stylebox_override("hover_pressed", T.box(T.AMBER.lightened(0.08), 10, Color(0, 0, 0, 0), 0, pad))
		b.add_theme_stylebox_override("disabled", T.empty())
		T.style_text(b, "body", "semibold", T.WHITE, 14)
		b.add_theme_font_override("font", T.system("semibold"))
		b.add_theme_color_override("font_hover_color", T.WHITE)
		b.add_theme_color_override("font_focus_color", T.WHITE)
		b.add_theme_color_override("font_pressed_color", Color(0.06, 0.05, 0.03))
		b.add_theme_color_override("font_hover_pressed_color", Color(0.06, 0.05, 0.03))
		_hi_icon(b, str(TAB_ICONS[tname]), 16, Color.WHITE)
		b.add_theme_constant_override("h_separation", 7)
		b.add_theme_color_override("icon_normal_color", Color(1, 1, 1, 0.8))
		b.add_theme_color_override("icon_hover_color", Color.WHITE)
		b.add_theme_color_override("icon_focus_color", Color.WHITE)
		b.add_theme_color_override("icon_pressed_color", Color(0.06, 0.05, 0.03))
		b.add_theme_color_override("icon_hover_pressed_color", Color(0.06, 0.05, 0.03))
		b.pressed.connect(func():
			for j in buttons.size():
				(buttons[j] as Button).set_pressed_no_signal(j == i)
			_set_tab(tname))
		NC.grow_on_focus(b, 1.03)
		h.add_child(b)
		buttons.append(b)
		tab_buttons[tname] = b
	wrap.set_meta("buttons", buttons)
	return wrap


func _style_search(focused: bool) -> void:
	var p: PanelContainer = _search_panel as PanelContainer
	if p == null:
		return
	var border: Color = T.AMBER if focused else Color(1, 1, 1, 0.10)
	p.add_theme_stylebox_override("panel", T.box(Color(1, 1, 1, 0.09 if focused else 0.07), 12, border, 2 if focused else 1, Vector2(12, 7)))


## A big titled section header with a tinted glyph, an optional caption and an optional right slot.
func _section_header(text: String, glyph: String, caption := "", tint: Color = T.AMBER) -> HBoxContainer:
	var h := _hbox(_content, 10)
	h.custom_minimum_size.y = 30
	_svg(h, glyph, 18, tint)
	_t(h, text, 18, "semibold")
	if caption != "":
		var c := _t(h, caption, 13, "regular", T.TERTIARY)
		c.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	NC.hspacer(h)
	return h


# ------------------------------------------------------------------ SVG artwork

## Procedural banner art for a plug-in: a nebula glow, a ringed planet and a star field in the
## kind's tint. Deterministic per (tint, variant); drawn as one SVG and cached.
static func _art_svg(tint: Color, variant: int, w: int, h: int) -> String:
	var hex: String = "#" + tint.to_html(false)
	var dark: String = "#" + tint.darkened(0.78).to_html(false)
	var rng := RandomNumberGenerator.new()
	rng.seed = 7919 * (variant + 3) + w
	var px: float = rng.randf_range(0.62, 0.86) * w
	var py: float = rng.randf_range(0.30, 0.62) * h
	var pr: float = h * rng.randf_range(0.34, 0.5)
	var s := "<svg xmlns='http://www.w3.org/2000/svg' width='%d' height='%d' viewBox='0 0 %d %d'>" % [w, h, w, h]
	s += "<defs><linearGradient id='bg' x1='0' y1='0' x2='1' y2='1'><stop offset='0' stop-color='#0b0d16'/><stop offset='1' stop-color='%s'/></linearGradient>" % dark
	s += "<radialGradient id='gl' cx='%.2f' cy='%.2f' r='0.75'><stop offset='0' stop-color='%s' stop-opacity='0.55'/><stop offset='1' stop-color='%s' stop-opacity='0'/></radialGradient>" % [px / w, py / h, hex, hex]
	s += "<radialGradient id='pl' cx='0.35' cy='0.3' r='0.9'><stop offset='0' stop-color='%s' stop-opacity='0.95'/><stop offset='1' stop-color='%s' stop-opacity='0.25'/></radialGradient></defs>" % [hex, dark]
	s += "<rect width='%d' height='%d' fill='url(#bg)'/><rect width='%d' height='%d' fill='url(#gl)'/>" % [w, h, w, h]
	for i in 34:
		var sx: float = rng.randf() * w
		var sy: float = rng.randf() * h
		var sr: float = rng.randf_range(0.5, 1.7)
		s += "<circle cx='%.1f' cy='%.1f' r='%.2f' fill='#fff' fill-opacity='%.2f'/>" % [sx, sy, sr, rng.randf_range(0.25, 0.8)]
	s += "<ellipse cx='%.1f' cy='%.1f' rx='%.1f' ry='%.1f' fill='none' stroke='%s' stroke-opacity='0.35' stroke-width='3' transform='rotate(-18 %.1f %.1f)'/>" % [px, py, pr * 1.9, pr * 0.46, hex, px, py]
	s += "<circle cx='%.1f' cy='%.1f' r='%.1f' fill='url(#pl)'/>" % [px, py, pr]
	s += "<path d='M %.1f %.1f A %.1f %.1f 0 0 0 %.1f %.1f' fill='none' stroke='%s' stroke-opacity='0.7' stroke-width='3' transform='rotate(-18 %.1f %.1f)'/>" % [px - pr * 1.9, py, pr * 1.9, pr * 0.46, px + pr * 1.9, py, hex, px, py]
	s += "<circle cx='%.1f' cy='%.1f' r='%.1f' fill='%s' fill-opacity='0.22'/>" % [rng.randf_range(0.1, 0.45) * w, rng.randf_range(0.55, 0.9) * h, h * 0.16, hex]
	s += "</svg>"
	return s


func _art_texture(e: Dictionary, w: int, h: int) -> Texture2D:
	var tint: Color = _entry_tint(e)
	var variant: int = absi(str(e.get("id", "")).hash()) % 5
	var key := "pl.art/%s/%d/%d/%d" % [tint.to_html(false), variant, w, h]
	return SVG.render(_art_svg(tint, variant, w, h), Vector2i(w, h), Vector2i(w, h), key)


## Empty-state illustration: orbits, a few stars and a glowing tile with a glyph.
static func _empty_svg(glyph_body: String, tint: Color) -> String:
	var hex: String = "#" + tint.to_html(false)
	var dark: String = "#" + tint.darkened(0.5).to_html(false)
	var body: String = glyph_body.replace("'C'", "'#ffffff'")
	var s := "<svg xmlns='http://www.w3.org/2000/svg' width='360' height='190' viewBox='0 0 360 190'>"
	s += "<defs><radialGradient id='g' cx='0.5' cy='0.5' r='0.5'><stop offset='0' stop-color='%s' stop-opacity='0.35'/><stop offset='1' stop-color='%s' stop-opacity='0'/></radialGradient>" % [hex, hex]
	s += "<linearGradient id='t' x1='0' y1='0' x2='1' y2='1'><stop offset='0' stop-color='%s'/><stop offset='1' stop-color='%s'/></linearGradient></defs>" % [hex, dark]
	s += "<circle cx='180' cy='95' r='95' fill='url(#g)'/>"
	s += "<ellipse cx='180' cy='95' rx='150' ry='46' fill='none' stroke='%s' stroke-opacity='0.28' stroke-width='1.6' transform='rotate(-14 180 95)'/>" % hex
	s += "<ellipse cx='180' cy='95' rx='108' ry='72' fill='none' stroke='#fff' stroke-opacity='0.10' stroke-width='1.4' transform='rotate(24 180 95)'/>"
	s += "<circle cx='318' cy='64' r='7' fill='%s' fill-opacity='0.85'/><circle cx='52' cy='122' r='5' fill='#fff' fill-opacity='0.5'/><circle cx='292' cy='150' r='3.2' fill='#fff' fill-opacity='0.6'/>" % hex
	for p in [[40, 40, 1.4], [92, 20, 1.0], [140, 168, 1.2], [250, 22, 1.2], [330, 120, 1.0], [30, 160, 1.0], [210, 176, 1.4], [120, 52, 0.9]]:
		s += "<circle cx='%d' cy='%d' r='%.1f' fill='#fff' fill-opacity='0.6'/>" % [p[0], p[1], p[2]]
	s += "<rect x='140' y='55' width='80' height='80' rx='22' fill='url(#t)'/><rect x='140.5' y='55.5' width='79' height='79' rx='21.5' fill='none' stroke='#fff' stroke-opacity='0.25'/>"
	s += "<g transform='translate(156 71) scale(1.92)' fill='none' stroke='#fff' stroke-width='1.8' stroke-linecap='round' stroke-linejoin='round'>%s</g>" % body
	s += "</svg>"
	return s


func _empty_texture(glyph: String, tint: Color) -> Texture2D:
	var body: String = str(SVG.GLYPHS.get(glyph, "<rect x='6' y='6' width='12' height='12' rx='2'/>"))
	var k := "pl.empty/%s/%s" % [glyph, tint.to_html(false)]
	return SVG.render(_empty_svg(body, tint), Vector2i(720, 380), Vector2i(360, 190), k)


## Load-order diagram: three stacked layers (game data, plug-in, plug-in) and an arrow that points
## at the layer that wins.
static func _layers_svg() -> String:
	var s := "<svg xmlns='http://www.w3.org/2000/svg' width='200' height='150' viewBox='0 0 200 150'>"
	var cols: Array = ["#8e8e93", "#4cc9e0", "#ffb347"]
	for i in 3:
		var y: float = 112.0 - i * 34.0
		s += "<path d='M 70 %.1f l 46 -22 l 46 22 l -46 22 z' fill='%s' fill-opacity='%.2f' stroke='%s' stroke-width='1.6' stroke-linejoin='round'/>" % [y, cols[i], 0.22 + i * 0.12, cols[i]]
	s += "<path d='M 30 128 L 30 22' stroke='#fff' stroke-opacity='0.5' stroke-width='2.4' stroke-linecap='round' fill='none'/><path d='M 21 32 L 30 21 L 39 32' stroke='#fff' stroke-opacity='0.5' stroke-width='2.4' stroke-linecap='round' stroke-linejoin='round' fill='none'/>"
	s += "</svg>"
	return s


func _layers_texture() -> Texture2D:
	return SVG.render(_layers_svg(), Vector2i(400, 300), Vector2i(200, 150), "pl.layers")


func _grad_tex(tint: Color, a0: float, a1: float) -> GradientTexture2D:
	var key := "%s/%.2f/%.2f" % [tint.to_html(false), a0, a1]
	if _grads.has(key):
		return _grads[key]
	var g := Gradient.new()
	g.set_color(0, Color(tint.r, tint.g, tint.b, a0))
	g.set_color(1, Color(tint.r, tint.g, tint.b, a1))
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill_from = Vector2(0.15, 0.0)
	gt.fill_to = Vector2(0.85, 1.0)
	gt.width = 32
	gt.height = 32
	_grads[key] = gt
	return gt


# ------------------------------------------------------------------ state helpers

func _installed() -> Array:
	return JSON.parse_string(_pl.list())


func _state() -> Dictionary:
	return JSON.parse_string(_pl.state())


func _catalog() -> Dictionary:
	return JSON.parse_string(_pl.catalog_state())


func _set_tab(t: String) -> void:
	tab = t
	detail_id = ""
	_delete_confirm = ""
	_render()


func _clear() -> void:
	_icons.clear()
	for c in _content.get_children():
		_content.remove_child(c)
		c.queue_free()
	first_control = null


func _grid_columns() -> int:
	var w: float = _scroll.size.x if _scroll != null and _scroll.size.x > 100.0 else (_root.get_viewport_rect().size.x if _root.is_inside_tree() else 1280.0)
	w -= 40.0
	return maxi(1, int((w + 14.0) / (CARD_MIN_W + 14.0)))


func _apply_page_width() -> void:
	var w: float = _scroll.size.x
	var m := 20
	if not (tab == "Browse" and detail_id == "") and w > PAGE_MAX_W + 40.0:
		m = int((w - PAGE_MAX_W) * 0.5)
	for s in ["left", "right"]:
		_pad.add_theme_constant_override("margin_" + s, m)


func _on_scroll_resized() -> void:
	if _pad == null or _busy_apply:
		return
	_apply_page_width()
	if tab == "Browse" and detail_id == "" and _grid_columns() != _cols_built:
		var pos: int = _scroll.scroll_vertical
		_render(false)
		_scroll.scroll_vertical = pos


func _render(refocus := true) -> void:
	var in_detail := detail_id != ""
	for t in tab_buttons:
		tab_buttons[t].set_pressed_no_signal(t == tab)
	_tabbar.visible = not in_detail
	_search_panel.visible = tab == "Browse"
	_filterbar.visible = tab == "Browse" and not in_detail
	_back_btn.visible = in_detail
	_title_icon.visible = not in_detail
	_title.text = "Plug-ins"
	var cat: Dictionary = _catalog()
	_offline = bool(cat.offline)
	for f in FILTERS:
		var b: Button = _chip_buttons[f]
		b.set_pressed_no_signal(f == filter)
		var count: int = (cat.updates as Array).size() if f == "Updates" else 0
		b.text = ("%s (%d)" % [f, count]) if count > 0 else f
	_apply_page_width()
	_clear()
	if in_detail:
		_render_detail()
	else:
		var st := _state()
		if bool(st.needsReload):
			_pending_banner()
		match tab:
			"Installed": _render_installed()
			"Browse": _render_browse()
			"Load order": _render_order()
	_apply_btn.visible = bool(_state().needsReload)
	_refresh_label.visible = bool(cat.refreshing)
	if refocus:
		_focus_first()
		_reset_scroll.call_deferred()


func _reset_scroll() -> void:
	if is_instance_valid(_scroll):
		_scroll.scroll_vertical = 0


func _focus_first() -> void:
	if first_control != null:
		ShellUI.focus(first_control)
	else:
		ShellUI.focus(tab_buttons[tab])


func _pending_banner() -> void:
	var c := _banner(T.AMBER, "pl.arrows.circlepath", "Plug-in changes pending",
		"They apply when you press Apply, leave this screen, or an install finishes.")
	var h: HBoxContainer = c.get_meta("row")
	_btn(h, "Apply now", func(): await _apply(); _render(), 0, "primary", "checkmark.circle.fill")


## A tinted notice card: glyph, bold title, secondary body. Returns the card; its `row` meta is the
## HBox so callers can append a button on the right.
func _banner(tint: Color, glyph: String, title: String, body: String, parent: Control = null) -> PanelContainer:
	var c := PanelContainer.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.add_theme_stylebox_override("panel", T.box(Color(tint.r, tint.g, tint.b, 0.10), 14, Color(tint.r, tint.g, tint.b, 0.28), 1, Vector2(14, 11)))
	(parent if parent != null else _content).add_child(c)
	var h := _hbox(c, 12)
	_icon_tile(h, 36, tint, glyph, 0.2)
	var col := _vbox(h, 1)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_t(col, title, 14, "semibold")
	if body != "":
		_note(col, body, 12)
	c.set_meta("row", h)
	return c


# ------------------------------------------------------------------ icon tiles and entry art

## PluginIconTile: the catalog icon over a tinted gradient tile carrying the plug-in kind's glyph.
func _icon(parent: Control, url: String, size := 44, tint: Color = T.SECONDARY, symbol := "puzzlepiece.extension") -> Control:
	var tile := PanelContainer.new()
	tile.custom_minimum_size = Vector2(size, size)
	tile.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	tile.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	tile.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_theme_stylebox_override("panel", T.box(Color(0, 0, 0, 0.3), int(size * 0.22), Color(1, 1, 1, 0.12), 1))
	tile.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	var gr := TextureRect.new()
	gr.texture = _grad_tex(tint, 0.95, 0.45)
	gr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	gr.stretch_mode = TextureRect.STRETCH_SCALE
	gr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(gr)
	var c := CenterContainer.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(c)
	_svg(c, symbol, int(size * 0.5), Color(1, 1, 1, 0.92))
	var tr := TextureRect.new()
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(tr)
	parent.add_child(tile)
	if url != "":
		if not _icons.has(url):
			_icons[url] = []
		_icons[url].append(tr)
		_try_icon(url)
	return tile


func _try_icon(url: String) -> void:
	var bytes: PackedByteArray = _pl.image(url)
	if bytes.is_empty():
		return
	var img := Image.new()
	var err := img.load_png_from_buffer(bytes)
	if err != OK:
		err = img.load_jpg_from_buffer(bytes)
	if err != OK:
		err = img.load_webp_from_buffer(bytes)
	var tex := ImageTexture.create_from_image(img) if err == OK else null
	for tr in _icons.get(url, []):
		if is_instance_valid(tr):
			tr.texture = tex
	_icons.erase(url)


static func _entry_tint(e: Dictionary) -> Color:
	if e.get("tc", false):
		return T.INDIGO
	var tags: Array = (e.get("tags", []) as Array).map(func(t): return str(t).to_lower())
	if tags.has("patch") or tags.has("graphics"):
		return T.TEAL
	if tags.has("gameplay"):
		return T.ORANGE
	return Color(0.56, 0.56, 0.58)


static func _kind_tint(kind: String) -> Color:
	match kind:
		"totalConversion": return T.INDIGO
		"patch", "graphics": return T.TEAL
		"gameplay": return T.ORANGE
	return Color(0.42, 0.5, 0.68)


static func _entry_symbol(e: Dictionary) -> String:
	if e.get("tc", false):
		return KIND_SYMBOL["totalConversion"]
	var tags: Array = (e.get("tags", []) as Array).map(func(t): return str(t).to_lower())
	if tags.has("patch") or tags.has("graphics"):
		return KIND_SYMBOL["patch"]
	if tags.has("gameplay"):
		return KIND_SYMBOL["gameplay"]
	return KIND_SYMBOL["unknown"]


static func _entry_kind(e: Dictionary) -> String:
	if e.get("tc", false):
		return "Total conversion"
	var tags: Array = (e.get("tags", []) as Array).map(func(t): return str(t).to_lower())
	if tags.has("patch"):
		return "Patch"
	if tags.has("graphics"):
		return "Graphics"
	if tags.has("gameplay"):
		return "Gameplay"
	if tags.has("ships") or tags.has("ship"):
		return "Ships"
	if tags.has("story"):
		return "Story"
	return "Plug-in"


# ------------------------------------------------------------------ empty state

func _empty_state(parent: Control, glyph: String, tint: Color, title: String, body: String) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 8)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var c := CenterContainer.new()
	v.add_child(c)
	var art := TextureRect.new()
	art.texture = _empty_texture(glyph, tint)
	art.custom_minimum_size = Vector2(300, 158)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(art)
	var t := _t(v, title, 20, "semibold")
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var b := _note(v, body, 14)
	b.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_top", 20)
	m.add_theme_constant_override("margin_bottom", 24)
	m.add_theme_constant_override("margin_left", 120)
	m.add_theme_constant_override("margin_right", 120)
	m.add_child(v)
	parent.add_child(m)
	return v


# ------------------------------------------------------------------ Installed

func _short_path(p: String) -> String:
	var home := OS.get_environment("HOME")
	if home == "":
		home = OS.get_environment("USERPROFILE")
	if home != "" and p.begins_with(home):
		p = "~" + p.substr(home.length())
	var parts: PackedStringArray = p.split("/", false)
	if parts.size() > 4:
		return ".../" + "/".join(parts.slice(parts.size() - 3))
	return p


func _render_installed() -> void:
	var st := _state()
	var list := _installed()
	var failures: Array = st.failures
	var enabled_n := 0
	for p in list:
		if bool(p.enabled):
			enabled_n += 1
	var hdr := _section_header("Installed plug-ins", "externaldrive",
		"%d installed  -  %d active" % [list.size(), enabled_n] if not list.is_empty() else "")
	if not failures.is_empty():
		var fc := _banner(T.ORANGE, "exclamationmark.triangle.fill", "Failed to load",
			"These files were skipped when the game data last loaded. The rest of the plug-ins are unaffected.")
		var fcol: Control = (fc.get_meta("row") as HBoxContainer).get_child(1)
		for f in failures:
			_note(fcol, "%s  (in %s)  -  %s" % [f.file, f.plugin, f.message], 11, T.ORANGE)
	_render_tc_addons()
	if list.is_empty():
		var es := _empty_state(_content, "puzzlepiece.extension", T.AMBER, "No plug-ins installed",
			"Browse the catalog to install one, or import your own .rez, .ndat or .zip files.\nPlug-ins in your game's \"Nova Plug-ins\" folder and in " + str(st.installDir) + " are found automatically.")
		var hb := _hbox(es, 10)
		hb.alignment = BoxContainer.ALIGNMENT_CENTER
		_btn(hb, "Import files...", _open_import, 0, "primary", "square.and.arrow.down")
		_btn(hb, "Browse catalog", func(): _set_tab("Browse"), 0, "bordered", "icloud.and.arrow.down")
		return
	var catalog := _catalog()
	var by_id := {}
	for e in catalog.entries:
		by_id[e.id] = e
	for optional in [false, true]:
		var group := list.filter(func(p): return p.optional == optional)
		if group.is_empty():
			continue
		if optional:
			_section_header("Optional extras inside plug-ins", "pl.layers", "", T.SECONDARY)
		for p in group:
			_installed_row(p, by_id.get(p.id))
	var sd := _hbox(_content, 8)
	_svg(sd, "folder", 13, T.TERTIARY)
	_t(sd, "Searched: " + ", ".join(PackedStringArray(st.dirs)), 12, "regular", T.TERTIARY, true)


func _installed_row(p: Dictionary, entry) -> void:
	var card := NC.card(_content, 14, 12, true)
	var h := _hbox(card, 14)
	if not bool(p.enabled) and not bool(p.canToggle):
		card.modulate.a = 0.85
	var tint: Color = _entry_tint(entry) if entry != null else _kind_tint(str(p.get("kind", "unknown")))
	var sym: String = _entry_symbol(entry) if entry != null else str(KIND_SYMBOL.get(str(p.get("kind", "unknown")), "puzzlepiece.extension"))
	_icon(h, str(entry.icon) if entry != null else "", 52, tint, sym)
	var col := _vbox(h, 4)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var nm := _t(col, str(entry.name) if entry != null else str(p.name), 16, "semibold")
	nm.clip_text = true
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var meta := _hbox(col, 6)
	_badge(meta, str(p.kindLabel), tint if p.total_conversion else T.SECONDARY, sym)
	if p.total_conversion:
		_badge(meta, "Total conversion", T.INDIGO, "sparkles")
	if entry != null and entry.status == "update":
		_badge(meta, "Update", T.ORANGE, "arrow.clockwise")
	if entry == null:
		_badge(meta, "Imported" if p.deletable else "Built in", T.TEAL if p.deletable else T.SECONDARY,
			"square.and.arrow.down" if p.deletable else "lock.fill")
	if p.optional:
		_badge(meta, "Optional")
	var src := _hbox(col, 5)
	_svg(src, "folder", 12, T.TERTIARY)
	var files: Array = p.get("files", [])
	var folder: String = str(p.get("folder", ""))
	var s := _t(src, "%s  -  %d file%s" % [_short_path(folder), files.size(), "" if files.size() == 1 else "s"], 12, "regular", T.TERTIARY)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.clip_text = true
	s.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	s.tooltip_text = folder
	s.mouse_filter = Control.MOUSE_FILTER_PASS
	# right: actions then the enable switch
	var acts := _hbox(h, 4)
	acts.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if entry != null and entry.status == "update" and entry.downloadable:
		_btn(acts, "Update", func(): _start_install(str(entry.id)), 0, "primary", "arrow.clockwise")
	if entry != null:
		var info := _icon_btn(acts, "info.circle", "Details", _open_detail.bind(str(entry.id)))
		if first_control == null:
			first_control = info
	if folder != "":
		_icon_btn(acts, "folder", "Show in file manager", _reveal.bind(folder))
	if p.deletable:
		if _delete_confirm == str(p.id):
			_btn(acts, "Really delete?", _delete.bind(str(p.id)), 0, "destructive", "trash")
		else:
			var d := _icon_btn(acts, "trash", "Delete", _delete.bind(str(p.id)), T.RED)
			if first_control == null:
				first_control = d
	if p.canToggle:
		var tg := NC.toggle(acts, "Enabled" if p.enabled else "Off", bool(p.enabled), func(on: bool): _toggle(str(p.id), on))
		tg.add_theme_font_override("font", T.system("medium"))
		tg.add_theme_font_size_override("font_size", 13)
		tg.custom_minimum_size = Vector2(92, 30)
		tg.size_flags_horizontal = Control.SIZE_SHRINK_END
		tg.tooltip_text = "Switch this plug-in on or off"
		if first_control == null:
			first_control = tg
	else:
		var auto_on: bool = bool(p.enabled) and _auto_label(p) == "Loads automatically"
		var chip := PanelContainer.new()
		chip.add_theme_stylebox_override("panel", T.box(Color(1, 1, 1, 0.06), 10, Color(0, 0, 0, 0), 0, Vector2(10, 5)))
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var ch := _hbox(chip, 5)
		_svg(ch, "checkmark.circle.fill" if auto_on else "circle.dashed", 13, T.GREEN if auto_on else T.SECONDARY)
		_t(ch, _auto_label(p), 12, "medium", T.SECONDARY)
		acts.add_child(chip)


func _reveal(folder: String) -> void:
	OS.shell_show_in_file_manager(folder)


## "Add-ons for <total conversion>": the selected conversion's own plug-in list (shared `TCAddOns`).
## The original runs a conversion with only its own Plug-Ins folder; this is "copy a plug-in into that
## folder" without copying: listed plug-ins load after the conversion's own, in this order (later wins).
func _render_tc_addons() -> void:
	if not _pl.has_method("tc_addons"):
		return
	var raw: Variant = JSON.parse_string(_pl.tc_addons())
	if not (raw is Dictionary) or (raw as Dictionary).is_empty():
		return
	var info: Dictionary = raw
	var tc_id: String = str(info.get("tc", ""))
	var tc_name: String = str(info.get("name", tc_id))
	if _tc_analysed != tc_id:
		_tc_analysed = tc_id
		_pl.tc_addons_analyze()
	var card := PanelContainer.new()
	card.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	card.add_theme_stylebox_override("panel", T.box(Color(T.INDIGO.r, T.INDIGO.g, T.INDIGO.b, 0.10), 16, Color(T.INDIGO.r, T.INDIGO.g, T.INDIGO.b, 0.30), 1, Vector2(16, 14)))
	_content.add_child(card)
	var v := _vbox(card, 10)
	var head := _hbox(v, 12)
	_icon_tile(head, 38, T.INDIGO, "puzzlepiece.extension.fill", 0.25)
	var hc := _vbox(head, 1)
	hc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_t(hc, "Add-ons for %s" % tc_name, 16, "semibold")
	_note(hc, "While %s is on, only its own plug-ins load, as in the original. Plug-ins you add here load after them, in this order (later wins): the same as copying them into the conversion's Plug-Ins folder, without moving any files." % tc_name, 12)
	var own: Array = info.get("own", [])
	if not own.is_empty():
		var names: PackedStringArray = []
		for f in own:
			names.append(str(f).get_basename())
		names.sort()
		var ob := _hbox(v, 6)
		_svg(ob, "lock.fill", 12, T.TERTIARY)
		_t(ob, "Built in: " + ", ".join(names), 12, "regular", T.TERTIARY, true)
	var list: Array = info.get("list", [])
	if not list.is_empty():
		var lp := PanelContainer.new()
		lp.add_theme_stylebox_override("panel", T.box(Color(0, 0, 0, 0.25), 12, Color(1, 1, 1, 0.06), 1, Vector2(10, 6)))
		v.add_child(lp)
		var lv := _vbox(lp, 4)
		for i in list.size():
			var e: Dictionary = list[i]
			var h := _hbox(lv, 10)
			h.custom_minimum_size.y = 38
			var nump := PanelContainer.new()
			nump.custom_minimum_size = Vector2(24, 24)
			nump.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			nump.add_theme_stylebox_override("panel", T.box(Color(1, 1, 1, 0.10), 12))
			var numc := CenterContainer.new()
			nump.add_child(numc)
			_t(numc, str(i + 1), 12, "semibold", T.SECONDARY)
			h.add_child(nump)
			var col := _vbox(h, 1)
			col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
			var nm := _t(col, str(e.get("name", e.get("id", ""))), 14, "semibold")
			nm.clip_text = true
			var meta := _hbox(col, 6)
			if not bool(e.get("installed", true)):
				_badge(meta, "Not installed", T.RED, "exclamationmark.circle.fill")
			_tc_compat_badge(meta, e)
			var id: String = str(e.get("id", ""))
			var up := _icon_btn(h, "chevron.up", "Move up", func(): _tc_move(tc_id, id, -1), T.WHITE, 30, 14)
			up.disabled = i == 0
			var dn := _icon_btn(h, "chevron.down", "Move down", func(): _tc_move(tc_id, id, 1), T.WHITE, 30, 14)
			dn.disabled = i == list.size() - 1
			_icon_btn(h, "pl.minus.circle", "Remove from %s" % tc_name, func(): _tc_remove(tc_id, id), T.RED, 30, 16)
			var tg := NC.toggle(h, "", bool(e.get("enabled", true)), func(on: bool): _tc_enable(tc_id, id, on))
			tg.text = ""
			tg.custom_minimum_size = Vector2(24, 28)
			tg.tooltip_text = "Enabled"
			if first_control == null:
				first_control = tg
	var cands: Array = info.get("candidates", [])
	var toggle_cb: Callable = _tc_toggle_candidates
	var addrow := _hbox(v, 8)
	_btn(addrow, "Hide installed plug-ins" if _tc_add_open else "Add plug-in to %s" % tc_name, toggle_cb, 0,
		"bordered", "chevron.up" if _tc_add_open else "pl.plus.circle")
	if _tc_add_open:
		if cands.is_empty():
			_note(v, "No other plug-ins installed.", 12)
		for c in cands:
			var cd: Dictionary = c
			var cp := PanelContainer.new()
			cp.add_theme_stylebox_override("panel", T.box(Color(1, 1, 1, 0.05), 10, Color(0, 0, 0, 0), 0, Vector2(10, 7)))
			v.add_child(cp)
			var ch := _hbox(cp, 8)
			var ccol := _vbox(ch, 2)
			ccol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			var cn := _t(ccol, str(cd.get("name", "")), 14, "semibold")
			cn.clip_text = true
			var cm := _hbox(ccol, 6)
			_tc_compat_badge(cm, cd)
			var cid: String = str(cd.get("id", ""))
			var unlikely: bool = str(cd.get("compat", "")) == "unlikely"
			if unlikely and _tc_add_confirm == cid:
				_note(ccol, "Made for the base game or another conversion: %s. Press again to add it anyway." % str(cd.get("reason", "")), 12, T.ORANGE)
				_btn(ch, "Add anyway", _tc_add.bind(tc_id, cid), 0, "destructive")
			else:
				_btn(ch, "Add", _tc_try_add.bind(tc_id, cid, unlikely), 0, "bordered", "pl.plus.circle")


func _tc_compat_badge(parent: Control, e: Dictionary) -> void:
	var k: String = str(e.get("compat", "neutral"))
	var reason: String = str(e.get("reason", ""))
	if k == "recommended":
		_badge(parent, "Made for this" if reason == "" else "Suggested", T.GREEN, "checkmark.seal.fill")
	elif k == "unlikely":
		_badge(parent, "Base game?", T.ORANGE, "exclamationmark.triangle.fill")
	if reason != "":
		_t(parent, reason, 11, "regular", T.TERTIARY)


func _tc_toggle_candidates() -> void:
	_tc_add_open = not _tc_add_open
	_render()


## A plug-in that looks made for the base game needs a second press ("warn, allow override").
func _tc_try_add(tc: String, id: String, unlikely: bool) -> void:
	if unlikely:
		_tc_add_confirm = id
		_render()
	else:
		_tc_add(tc, id)


func _tc_add(tc: String, id: String) -> void:
	_tc_add_confirm = ""
	_pl.tc_addon_add(tc, id)
	_render()


func _tc_remove(tc: String, id: String) -> void:
	_pl.tc_addon_remove(tc, id)
	_render()


func _tc_move(tc: String, id: String, offset: int) -> void:
	_pl.tc_addon_move(tc, id, offset)
	_render()


func _tc_enable(tc: String, id: String, on: bool) -> void:
	_pl.tc_addon_set_enabled(tc, id, on)
	_render()


## Under a total conversion the original ignores global plug-ins (add them to the conversion's list above).
func _auto_label(p: Dictionary) -> String:
	if not p.total_conversion and _pl.has_method("tc_addons"):
		var raw: Variant = JSON.parse_string(_pl.tc_addons())
		if raw is Dictionary and not (raw as Dictionary).is_empty():
			return "Not loaded under %s" % str((raw as Dictionary).get("name", "the conversion"))
	return "Loads automatically" if p.enabled else "Not loaded"


func _toggle(id: String, on: bool) -> void:
	_pl.set_enabled(id, on)
	_render()


func _delete(id: String) -> void:
	if _delete_confirm != id:
		_delete_confirm = id
		_render()
		return
	_delete_confirm = ""
	if _pl.delete(id):
		await _apply("Removing plug-in...")
	_render()


# ------------------------------------------------------------------ Browse

func _render_browse() -> void:
	var cat: Dictionary = _catalog()
	var src_kind: String = str(cat.source)
	if bool(cat.offline):
		var which := "the last catalog downloaded" if src_kind == "cache" else "the catalog that came with the app"
		var nb := _banner(T.ORANGE, "pl.wifi.slash", "You're offline",
			"Showing %s; downloads and updates are off until you reconnect." % which)
		if str(cat.error) != "":
			var col: Control = (nb.get_meta("row") as HBoxContainer).get_child(1)
			var el := _t(col, str(cat.error), 11, "regular", T.TERTIARY, true)
			el.max_lines_visible = 1
			el.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		var rb: Button = _btn(nb.get_meta("row"), "Retry", func(): _pl.catalog_refresh(); _render(), 0, "bordered", "arrow.clockwise")
		rb.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	elif src_kind == "cache" and bool(cat.refreshing):
		_banner(T.TEAL, "arrow.clockwise", "Saved catalog", "Refreshing from the network...")
	elif src_kind == "bundled" and bool(cat.refreshing):
		_banner(T.TEAL, "arrow.clockwise", "Built-in catalog", "Refreshing from the network...")
	var updates: Array = cat.updates
	if updates.size() > 0 and filter != "Updates" and not bool(cat.offline):
		var ub := _banner(T.ORANGE, "pl.arrows.circlepath", "%d update%s available" % [updates.size(), "" if updates.size() == 1 else "s"],
			"Installed plug-ins have newer versions in the catalog.")
		_btn(ub.get_meta("row"), "Update all (%d)" % updates.size(), _update_all, 0, "primary", "pl.arrows.circlepath")
	var rows: Array = _filtered(cat.entries)
	var cols := _grid_columns()
	_cols_built = cols
	var q := query.strip_edges()
	var featured: Array = []
	if filter == "Popular" and q == "":
		var nf := 3 if cols >= 4 else 2
		for e in rows:
			if bool(e.tc) and featured.size() < nf:
				featured.append(e)
		if featured.size() < 2 or rows.size() - featured.size() < 1:
			featured.clear()
	if rows.is_empty():
		var es := _empty_state(_content, "magnifyingglass", T.AMBER,
			"Everything is up to date" if filter == "Updates" else "Nothing here",
			"Try a different filter." if q == "" else "No plug-ins match \"%s\"." % q)
		if q != "" or filter != "Popular":
			var eb := _hbox(es, 8)
			eb.alignment = BoxContainer.ALIGNMENT_CENTER
			_btn(eb, "Clear search and filters", func():
				query = ""
				_search.text = ""
				filter = "Popular"
				_render(false), 0, "bordered", "xmark")
	else:
		if not featured.is_empty():
			_section_header("Featured total conversions", "sparkles", "Whole new games on the Nova engine", T.INDIGO)
			var fh := _hbox(_content, 14)
			for e in featured:
				_feature_card(fh, e)
		var grid_rows: Array = rows.filter(func(e): return not featured.has(e))
		if not grid_rows.is_empty():
			var title: String = str(FILTER_TITLES.get(filter, filter)) if q == "" else "Results for \"%s\"" % q
			if not featured.is_empty():
				title = "All plug-ins"
			_section_header(title, str(FILTER_ICONS.get(filter, "square.grid.2x2")) if q == "" and featured.is_empty() else "square.grid.2x2",
				"%d plug-in%s" % [grid_rows.size(), "" if grid_rows.size() == 1 else "s"])
			var grid := GridContainer.new()
			grid.columns = cols
			grid.add_theme_constant_override("h_separation", 14)
			grid.add_theme_constant_override("v_separation", 14)
			grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			_content.add_child(grid)
			for e in grid_rows:
				_card(grid, e)
	var foot := _hbox(_content, 8)
	foot.custom_minimum_size.y = 40
	var fi := _svg(foot, "info.circle", 14, T.TERTIARY)
	fi.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_note(foot, "Plug-in files download straight from each author's own site. NovaSwift doesn't host or change them, and you need your own copy of EV Nova to play any of them.", 12, T.TERTIARY)


func _filtered(entries: Array) -> Array:
	var out: Array = []
	var q := query.strip_edges().to_lower()
	for e in entries:
		var tags: Array = e.tags.map(func(t): return str(t).to_lower())
		var ok := true
		match filter:
			"Total conversions": ok = e.tc
			"Ships": ok = tags.has("ships") or tags.has("ship")
			"Story": ok = tags.has("story")
			"Graphics": ok = tags.has("graphics")
			"Gameplay": ok = tags.has("gameplay")
			"Installed": ok = e.status != "available"
			"Updates": ok = e.status == "update"
		if ok and q != "":
			var hay: String = (str(e.name) + " " + str(e.author) + " " + str(e.summary) + " " + " ".join(PackedStringArray(tags))).to_lower()
			ok = hay.contains(q)
		if ok:
			out.append(e)
	if filter == "Recent":
		out.sort_custom(func(a, b): return [str(a.recency), str(b.name)] > [str(b.recency), str(a.name)])
	else:
		out.sort_custom(func(a, b): return [int(a.popularity), str(b.name)] > [int(b.popularity), str(a.name)])
	return out


func _name_label(parent: Control, text: String, size: int) -> Label:
	var l := _t(parent, text, size, "semibold")
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	return l


## PluginCard: icon tile, name + "by author", a two-line summary, then badges and the state
## control. Pressing the card opens its details.
func _card(parent: Control, e: Dictionary) -> void:
	var b := NC.card_button(parent, T.CARD_BG, T.CARD_BORDER, 16, 14)
	b.custom_minimum_size = Vector2(0, 166)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(_open_detail.bind(str(e.id)))
	b.tooltip_text = "%s by %s" % [e.name, e.author]
	b.set_meta("fkey", "card:" + str(e.id))
	if first_control == null:
		first_control = b
	var v := _vbox(b.get_meta("content"), 8)
	var top := _hbox(v, 12)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon(top, str(e.icon), 52, _entry_tint(e), _entry_symbol(e))
	var col := _vbox(top, 1)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name_label(col, str(e.name), 16)
	var by := _t(col, "by " + str(e.author), 12, "regular", T.SECONDARY)
	by.clip_text = true
	by.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var sum := _note(v, str(e.summary), 13)
	sum.max_lines_visible = 2
	sum.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(fill)
	var foot := _hbox(v, 6)
	foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if e.tc:
		_badge(foot, "Total conversion", T.INDIGO, "sparkles")
	var tags: Array = e.tags
	for i in mini(tags.size(), 1 if e.tc else 2):
		_badge(foot, str(tags[i]).capitalize())
	NC.hspacer(foot)
	_action_button(foot, e, true)


## A featured total conversion: wide card over procedural SVG artwork.
func _feature_card(parent: Control, e: Dictionary) -> void:
	var tint: Color = _entry_tint(e)
	var b := NC.card_button(parent, Color(0.05, 0.05, 0.08, 0.9), Color(tint.r, tint.g, tint.b, 0.4), 18, 18)
	b.custom_minimum_size = Vector2(0, 176)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	b.pressed.connect(_open_detail.bind(str(e.id)))
	b.tooltip_text = "%s by %s" % [e.name, e.author]
	b.set_meta("fkey", "card:" + str(e.id))
	if first_control == null:
		first_control = b
	var art := TextureRect.new()
	art.texture = _art_texture(e, 640, 200)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.set_anchors_preset(Control.PRESET_FULL_RECT)
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(art)
	b.move_child(art, 0)
	var shade := TextureRect.new()
	var sg := Gradient.new()
	sg.set_color(0, Color(0, 0, 0, 0.10))
	sg.set_color(1, Color(0, 0, 0, 0.72))
	var sgt := GradientTexture2D.new()
	sgt.gradient = sg
	sgt.fill_from = Vector2(0.5, 0.0)
	sgt.fill_to = Vector2(0.5, 1.0)
	sgt.width = 8
	sgt.height = 64
	shade.texture = sgt
	shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(shade)
	b.move_child(shade, 1)
	var v := _vbox(b.get_meta("content"), 8)
	var top := _hbox(v, 14)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_icon(top, str(e.icon), 64, tint, _entry_symbol(e))
	var col := _vbox(top, 2)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_name_label(col, str(e.name), 20)
	var by := _t(col, "by " + str(e.author), 13, "regular", Color(1, 1, 1, 0.7))
	by.clip_text = true
	by.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var sum := _note(v, str(e.summary), 13, Color(1, 1, 1, 0.78))
	sum.max_lines_visible = 2
	sum.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(fill)
	var foot := _hbox(v, 6)
	foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_badge(foot, "Total conversion", Color(0.62, 0.62, 1.0), "sparkles")
	var tags: Array = e.tags
	for i in mini(tags.size(), 1):
		_badge(foot, str(tags[i]).capitalize(), Color(1, 1, 1, 0.7))
	NC.hspacer(foot)
	_action_button(foot, e, true)


## A capsule-shaped state label button (Get / Update / Installed / Failed).
func _pill(parent: Control, text: String, glyph: String, color: Color, cb: Callable, enabled := true) -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_ALL
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var pad := Vector2(12, 4)
	b.add_theme_stylebox_override("normal", T.box(Color(color.r, color.g, color.b, 0.16), 20, Color(color.r, color.g, color.b, 0.35), 1, pad))
	b.add_theme_stylebox_override("hover", T.box(Color(color.r, color.g, color.b, 0.30), 20, Color(color.r, color.g, color.b, 0.5), 1, pad))
	b.add_theme_stylebox_override("pressed", T.box(Color(color.r, color.g, color.b, 0.42), 20, Color(color.r, color.g, color.b, 0.5), 1, pad))
	b.add_theme_stylebox_override("disabled", T.box(Color(color.r, color.g, color.b, 0.10), 20, Color(color.r, color.g, color.b, 0.2), 1, pad))
	T.style_text(b, "button", "semibold", color, 13)
	b.add_theme_font_override("font", T.system("semibold"))
	for st in ["font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(st, color)
	b.add_theme_color_override("font_disabled_color", Color(color.r, color.g, color.b, 0.6))
	if glyph != "":
		_hi_icon(b, glyph, 14, color)
		b.add_theme_constant_override("h_separation", 5)
		for st in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_focus_color", "icon_hover_pressed_color", "icon_disabled_color"]:
			b.add_theme_color_override(st, Color.WHITE if st != "icon_disabled_color" else Color(1, 1, 1, 0.6))
	b.disabled = not enabled
	b.pressed.connect(cb)
	NC.grow_on_focus(b, 1.05)
	parent.add_child(b)
	return b


## Install / Update / Installed / progress for one catalog entry. `compact` = the card's state
## label look (Apple PluginStateLabel); otherwise full buttons with a progress bar + Cancel.
func _action_button(parent: Control, e: Dictionary, compact := false) -> void:
	var t: Dictionary = e.transfer
	var id: String = str(e.id)
	if not t.is_empty():
		var prog: float = float(t.progress)
		if bool(t.working):
			if compact:
				var h := _hbox(parent, 6)
				h.mouse_filter = Control.MOUSE_FILTER_IGNORE
				NC.progress(h, prog if prog >= 0.0 else 0.5, 64)
				_t(h, "" if prog < 0.0 else "%d%%" % int(prog * 100.0), 12, "semibold", T.AMBER)
			else:
				var pct := "" if prog < 0.0 else " %d%%" % int(prog * 100.0)
				var pb := NC.progress(parent, prog if prog >= 0.0 else 0.5, 220)
				pb.custom_minimum_size.y = 8
				_t(parent, "Downloading" + pct if prog >= 0.0 else "Working...", 13, "regular", T.SECONDARY)
				_btn(parent, "Cancel", func(): _pl.cancel_install(id); _render(), 0, "bordered", "xmark")
		else:
			if compact:
				var fb := _pill(parent, "Failed", "exclamationmark.triangle.fill", T.ORANGE, func(): _pl.dismiss_failure(id); _render())
				fb.tooltip_text = str(t.error)
			else:
				_btn(parent, "Try again", func(): _pl.dismiss_failure(id); _start_install(id), 0, "primary", "arrow.clockwise")
				_btn(parent, "Dismiss", func(): _pl.dismiss_failure(id); _render(), 0, "bordered", "xmark")
		return
	var label := ""
	var icon := ""
	var color: Color = T.AMBER
	var enabled := true
	match e.status:
		"installed":
			label = "Installed"
			icon = "checkmark.circle.fill"
			color = T.GREEN
			enabled = false
		"update":
			label = "Update"
			icon = "pl.arrows.circlepath"
			color = T.ORANGE
			enabled = bool(e.downloadable) and not _offline
		_:
			label = "Get"
			icon = "arrow.down.circle.fill"
			enabled = bool(e.downloadable) and not _offline
	if compact:
		var pb2 := _pill(parent, label, icon, color, func(): _start_install(id), enabled)
		pb2.set_meta("fkey", "act:" + id)
	else:
		if label == "Installed":
			var ib := _btn(parent, "Installed", func(): pass, 0, "bordered", "checkmark.circle.fill")
			ib.disabled = true
		else:
			var txt := label
			if label == "Update":
				txt = "Update to v" + str(e.version)
			elif label == "Get" and str(e.size) != "":
				txt = "Get  -  " + str(e.size)
			var b2 := _btn(parent, txt, func(): _start_install(id), 0, "primary", icon)
			b2.disabled = not enabled
			b2.custom_minimum_size.y = 38
			b2.set_meta("fkey", "act:" + id)


func _start_install(id: String) -> void:
	if not _pl.install(id):
		var cat := _catalog()
		for e in cat.entries:
			if e.id == id and e.transfer.is_empty():
				_set_status("Can't download right now (offline or no direct HTTPS link).")
	_render()


func _update_all() -> void:
	for id in _catalog().updates:
		_pl.install(str(id))
	_render()


# ------------------------------------------------------------------ Detail

func _open_detail(id: String) -> void:
	detail_id = id
	_render()


func _detail_h2(text: String, glyph: String) -> void:
	var h := _hbox(_content, 8)
	h.custom_minimum_size.y = 28
	_svg(h, glyph, 17, T.AMBER)
	_t(h, text, 18, "semibold")


func _fact_tile(parent: Control, glyph: String, label: String, value: String, tint: Color = T.AMBER) -> void:
	var c := NC.card(parent, 14, 12, true)
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var h := _hbox(c, 12)
	_icon_tile(h, 36, tint, glyph, 0.18)
	var col := _vbox(h, 1)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_t(col, label, 12, "regular", T.SECONDARY)
	var v := _t(col, value, 15, "semibold", T.WHITE, true)
	v.max_lines_visible = 2
	v.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS


func _render_detail() -> void:
	var cat: Dictionary = _catalog()
	var e: Dictionary = {}
	for x in cat.entries:
		if x.id == detail_id:
			e = x
	if e.is_empty():
		_empty_state(_content, "puzzlepiece.extension", T.AMBER, "Plug-in not found", "This plug-in is not in the catalog.")
		return
	_title.text = str(e.name)
	var tint: Color = _entry_tint(e)
	var by_id := {}
	for x in cat.entries:
		by_id[x.id] = x
	var inst: Dictionary = {}
	for p in _installed():
		if str(p.id) == str(e.id) or str(p.id).begins_with(str(e.id) + "/"):
			inst = p
			break

	# Hero: procedural SVG banner, big icon tile, title, author, badges
	var hero := PanelContainer.new()
	hero.custom_minimum_size = Vector2(0, 210)
	hero.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hero.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	hero.add_theme_stylebox_override("panel", T.box(Color(0.05, 0.05, 0.08), 20, Color(tint.r, tint.g, tint.b, 0.4), 1, Vector2(0, 0)))
	_content.add_child(hero)
	var art := TextureRect.new()
	art.texture = _art_texture(e, 1200, 240)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hero.add_child(art)
	var shade := TextureRect.new()
	var sg := Gradient.new()
	sg.set_color(0, Color(0, 0, 0, 0.78))
	sg.set_color(1, Color(0, 0, 0, 0.12))
	var sgt := GradientTexture2D.new()
	sgt.gradient = sg
	sgt.fill_from = Vector2(0.0, 0.5)
	sgt.fill_to = Vector2(1.0, 0.5)
	sgt.width = 64
	sgt.height = 8
	shade.texture = sgt
	shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shade.stretch_mode = TextureRect.STRETCH_SCALE
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hero.add_child(shade)
	var hm := MarginContainer.new()
	for s in ["left", "right", "top", "bottom"]:
		hm.add_theme_constant_override("margin_" + s, 26)
	hm.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hero.add_child(hm)
	var head := _hbox(hm, 22)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var tile := _icon(head, str(e.icon), 120, tint, _entry_symbol(e))
	tile.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var col := _vbox(head, 6)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var n := _t(col, str(e.name), 32, "bold", T.WHITE, true)
	n.max_lines_visible = 2
	_t(col, "by %s" % e.author, 17, "regular", Color(1, 1, 1, 0.75))
	var badges := _hbox(col, 6)
	_badge(badges, "v" + str(e.version), Color(1, 1, 1, 0.8), "tag")
	if e.tc:
		_badge(badges, "Total conversion", Color(0.62, 0.62, 1.0), "sparkles")
	else:
		_badge(badges, _entry_kind(e), tint, _entry_symbol(e))
	if e.status == "update":
		_badge(badges, ("Update from v" + str(e.installedVersion)) if str(e.installedVersion) != "" else "Update available", T.ORANGE, "arrow.clockwise")
	elif e.status != "available":
		_badge(badges, "Installed", T.GREEN, "checkmark.circle.fill")

	# Action bar: primary state control, delete / files, website
	var abar := NC.card(_content, 16, 14, true)
	var actions := _hbox(abar, 12)
	_action_button(actions, e)
	var tr: Dictionary = e.transfer
	if tr.is_empty():
		if e.status != "available":
			var del := _btn(actions, "Delete", func(): _confirm_delete_entry(e), 0, "destructive", "trash")
			del.custom_minimum_size.y = 38
			if not inst.is_empty() and str(inst.get("folder", "")) != "":
				var fb := _btn(actions, "Show files", _reveal.bind(str(inst.folder)), 0, "bordered", "folder")
				fb.custom_minimum_size.y = 38
		if bool(cat.offline) and e.status == "available":
			var oh := _hbox(actions, 6)
			_svg(oh, "pl.wifi.slash", 14, T.SECONDARY)
			_t(oh, "You're offline. Connect to download.", 13, "regular", T.SECONDARY)
	NC.hspacer(actions)
	if str(e.homepage) != "":
		var hp := _btn(actions, "Website", func(): OS.shell_open(str(e.homepage)), 0, "bordered", "pl.compass")
		hp.custom_minimum_size.y = 38
		hp.tooltip_text = str(e.homepage)
	if tr.has("error") and not bool(tr.get("working", true)):
		_banner(T.ORANGE, "exclamationmark.triangle.fill", "The download failed", str(tr.error))
	# Enable switch for an installed plug-in (Apple enableControl)
	if not inst.is_empty():
		var ec := NC.card(_content, 14, 12, true)
		var eh := _hbox(ec, 12)
		if bool(inst.canToggle):
			var tg := NC.toggle(eh, "Play this total conversion" if bool(inst.total_conversion) else "Enabled", bool(inst.enabled),
				func(on: bool): _toggle(str(inst.id), on))
			tg.add_theme_font_override("font", T.system("semibold"))
			tg.add_theme_font_size_override("font_size", 15)
			if first_control == null:
				first_control = tg
			if bool(inst.total_conversion):
				_note(eh, "Only one total conversion can be active. Turning this on turns the others off.", 12)
		else:
			_svg(eh, "checkmark.circle.fill", 18, T.GREEN)
			_note(eh, "This plug-in loads automatically with the others, in file-name order, as in the original game. Turn on Manual plug-in order (Load order tab) to pick which ones load.", 13)

	# Facts grid
	_detail_h2("Details", "info.circle")
	var fg := GridContainer.new()
	fg.columns = 3 if _scroll.size.x > 900.0 else 2
	fg.add_theme_constant_override("h_separation", 12)
	fg.add_theme_constant_override("v_separation", 12)
	fg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_child(fg)
	_fact_tile(fg, "tag", "Version", "v" + str(e.version))
	_fact_tile(fg, "person.crop.circle", "Author", str(e.author))
	_fact_tile(fg, _entry_symbol(e), "Kind", _entry_kind(e), tint)
	_fact_tile(fg, "square.and.arrow.down", "Download size", str(e.size) if str(e.size) != "" else "Unknown")
	if str(e.recency) != "":
		_fact_tile(fg, "calendar", "Updated", str(e.recency))
	_fact_tile(fg, "globe", "Downloads from", str(e.downloadHost) if str(e.downloadHost) != "" else "-")
	if not (e.tags as Array).is_empty():
		_fact_tile(fg, "pl.layers", "Tags", ", ".join(PackedStringArray((e.tags as Array).map(func(t): return str(t).capitalize()))))

	# About
	_detail_h2("About", "book")
	var ac := NC.card(_content, 16, 16, true)
	var long_text: String = str(e.description) if str(e.description) != "" else str(e.summary)
	var av := _vbox(ac, 10)
	_note(av, long_text, 15, Color(1, 1, 1, 0.88))
	if str(e.license) != "":
		var lh := _hbox(av, 8)
		var li := _svg(lh, "doc.text", 13, T.TERTIARY)
		li.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		_note(lh, str(e.license), 11, T.TERTIARY)

	# Compatibility
	_detail_h2("Compatibility", "checkmark.seal.fill")
	var cc := NC.card(_content, 16, 14, true)
	var cv := _vbox(cc, 10)
	_compat_line(cv, "externaldrive", "Needs your own copy of EV Nova's game data. NovaSwift doesn't include it.")
	if e.tc:
		_compat_line(cv, "sparkles", "A total conversion replaces the stock scenario. Only one can be played at a time.")
	var installed_ids: Array = _installed().map(func(p): return str(p.id))
	var missing: Array = e.get("missingDependencies", [])
	for dep in e.dependencies:
		var dn: String = str((by_id[dep] as Dictionary).name) if by_id.has(dep) else str(dep)
		var have: bool = installed_ids.has(str(dep)) or not missing.has(dep)
		_compat_line(cv, "checkmark.circle.fill" if have else "arrow.down.circle.fill",
			"Requires %s%s" % [dn, " (installed)" if have else " (installed automatically)"], T.GREEN if have else T.AMBER)


func _compat_line(parent: Control, glyph: String, text: String, tint: Color = T.SECONDARY) -> void:
	var h := _hbox(parent, 10)
	var ic := _svg(h, glyph, 16, tint)
	ic.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_note(h, text, 14)


func _confirm_delete_entry(e: Dictionary) -> void:
	Alert.show(self, {"title": "Delete %s?" % e.name,
		"message": "The plug-in's files are removed from this device. You can install it again later.",
		"buttons": [{"title": "Cancel", "role": "cancel"},
			{"title": "Delete", "role": "destructive", "cb": func(): _delete_entry(str(e.id))}]})


func _delete_entry(id: String) -> void:
	if _pl.delete(id):
		await _apply("Removing plug-in...")
	_render()


# ------------------------------------------------------------------ Load order

func _render_order() -> void:
	var manual: bool = _pl.manual_order()
	var list := _installed()
	_section_header("Load order", "list.bullet", "%d plug-in%s" % [list.size(), "" if list.size() == 1 else "s"])

	# Explanation card: layer diagram + the rule + the manual-order switch
	var ex := NC.card(_content, 16, 16, true)
	var eh := _hbox(ex, 20)
	var dia := TextureRect.new()
	dia.texture = _layers_texture()
	dia.custom_minimum_size = Vector2(124, 94)
	dia.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	dia.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	dia.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dia.mouse_filter = Control.MOUSE_FILTER_IGNORE
	eh.add_child(dia)
	var ev := _vbox(eh, 8)
	ev.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	ev.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_t(ev, "Manual order" if manual else "The original order", 17, "semibold")
	_note(ev, "You choose the order. When two plug-ins change the same thing, the one lower in this list wins. Changes apply next time you start a game." if manual else
		"This is the original game's order: every plug-in loads, sorted by file name, and when two change the same thing the later one wins. A total conversion replaces the stock scenario while it is switched on.", 13)
	var mrow := _hbox(ev, 10)
	var mb := NC.toggle(mrow, "Manual plug-in order", manual, func(on: bool):
		_pl.set_manual_order(on)
		_render())
	mb.add_theme_font_override("font", T.system("semibold"))
	mb.add_theme_font_size_override("font_size", 15)
	mb.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	if first_control == null:
		first_control = mb
	_badge(mrow, "Enhancement", T.TEAL, "sparkles")
	if manual:
		_note(ev, "Lets you reorder plug-ins and choose which ones load. This is an enhancement, not how the original worked.", 12, T.TERTIARY)

	if list.is_empty():
		var es := _empty_state(_content, "list.bullet", T.TEAL, "Nothing to order yet",
			"Plug-ins you install or import show up here, in the order they load.")
		var eb := _hbox(es, 10)
		eb.alignment = BoxContainer.ALIGNMENT_CENTER
		_btn(eb, "Browse catalog", func(): _set_tab("Browse"), 0, "primary", "icloud.and.arrow.down")
		_btn(eb, "Import files...", _open_import, 0, "bordered", "square.and.arrow.down")
		return

	# The stack: base game first (pinned), then the plug-ins
	var base := NC.card(_content, 12, 10, true)
	var bh := _hbox(base, 12)
	var bn := PanelContainer.new()
	bn.custom_minimum_size = Vector2(30, 30)
	bn.add_theme_stylebox_override("panel", T.box(Color(1, 1, 1, 0.08), 15))
	var bc := CenterContainer.new()
	bn.add_child(bc)
	_svg(bc, "lock.fill", 14, T.SECONDARY)
	bh.add_child(bn)
	var bcol := _vbox(bh, 0)
	bcol.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_t(bcol, "EV Nova game data", 15, "semibold", T.SECONDARY)
	_t(bcol, "Always loads first", 12, "regular", T.TERTIARY)
	_badge(bh, "Base", T.SECONDARY)

	for p in list:
		_order_row(p, manual, list.size())


func _order_row(p: Dictionary, manual: bool, count: int) -> void:
	var id: String = str(p.id)
	var idx: int = int(p.index)
	var rp := PanelContainer.new()
	rp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rp.add_theme_stylebox_override("panel", T.box(T.CARD_BG, 12, T.CARD_BORDER, 1, Vector2(12, 9)))
	_content.add_child(rp)
	var h := _hbox(rp, 12)
	if not bool(p.enabled):
		h.modulate.a = 0.55
	if manual:
		var grip := TextureRect.new()
		grip.texture = SVG.texture("pl.grip", int(ceil(18 * _scale)), T.TERTIARY)
		grip.custom_minimum_size = Vector2(22, 30)
		grip.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		grip.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		grip.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		grip.mouse_filter = Control.MOUSE_FILTER_STOP
		grip.mouse_default_cursor_shape = Control.CURSOR_DRAG
		grip.tooltip_text = "Drag to reorder"
		grip.set_drag_forwarding(func(_pos: Vector2) -> Variant:
			var prev := PanelContainer.new()
			prev.add_theme_stylebox_override("panel", T.box(Color(0.2, 0.2, 0.22, 0.95), 10, T.AMBER, 1, Vector2(12, 7)))
			_t(prev, str(p.name), 14, "semibold")
			grip.set_drag_preview(prev)
			return {"plugin_id": id, "from": idx},
			Callable(), Callable())
		h.add_child(grip)
		rp.set_drag_forwarding(Callable(),
			func(_pos: Vector2, data: Variant) -> bool:
				return data is Dictionary and (data as Dictionary).has("plugin_id") and str((data as Dictionary).plugin_id) != id,
			func(_pos: Vector2, data: Variant) -> void:
				var d: Dictionary = data
				_move.call_deferred(str(d.plugin_id), idx - int(d.from)))
	var np := PanelContainer.new()
	np.custom_minimum_size = Vector2(30, 30)
	np.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	np.add_theme_stylebox_override("panel", T.box(Color(T.AMBER.r, T.AMBER.g, T.AMBER.b, 0.16) if bool(p.enabled) else Color(1, 1, 1, 0.08), 15))
	np.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var nc := CenterContainer.new()
	nc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	np.add_child(nc)
	_t(nc, str(idx + 1), 14, "bold", T.AMBER if bool(p.enabled) else T.SECONDARY)
	h.add_child(np)
	var col := _vbox(h, 2)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_name_label(col, str(p.name), 16)
	var meta := _hbox(col, 6)
	var en: bool = bool(p.enabled)
	var sh := _hbox(meta, 4)
	_svg(sh, "circle.fill", 8, T.GREEN if en else T.SECONDARY)
	_t(sh, "Loads" if en else "Off", 12, "medium", T.GREEN if en else T.SECONDARY)
	_t(meta, str(p.kindLabel), 12, "regular", T.TERTIARY)
	if p.total_conversion:
		_badge(h, "Total conversion", T.INDIGO, "sparkles")
	if manual:
		var up := _icon_btn(h, "chevron.up", "Move up", _move.bind(id, -1), T.WHITE, 34, 15)
		up.disabled = idx == 0
		var dn := _icon_btn(h, "chevron.down", "Move down", _move.bind(id, 1), T.WHITE, 34, 15)
		dn.disabled = idx == count - 1
		if first_control == null and not up.disabled:
			first_control = up


func _move(id: String, offset: int) -> void:
	if offset != 0:
		_pl.move(id, offset)
	_render()


# ------------------------------------------------------------------ import / apply / close

func _open_import() -> void:
	var home := OS.get_environment("HOME")
	if home == "":
		home = OS.get_environment("USERPROFILE")
	if home != "":
		_import_dialog.current_dir = home
	_import_dialog.popup_centered()


func _import(path: String) -> void:
	var r: Dictionary = JSON.parse_string(_pl.import_from(path))
	if r.ok:
		_set_status("Imported \"%s\"." % r.id)
		await _apply("Loading plug-in...")
	else:
		_set_status("That didn't work: " + str(r.error))
	_render()


## Re-run the data load with the current plug-in set, behind a loading overlay (Apple shows its
## loading view while GameDataController.reload runs). The merge is synchronous, so give the
## overlay two frames to draw first.
func _apply(message := "Loading plug-ins...") -> bool:
	if _busy_apply:
		return false
	_busy_apply = true
	var base: String = _state().base
	var ok := false
	var shell := _find_shell()
	if shell != null and base != "":
		# Worker-thread load with the Shell's loading screen (real progress).
		ok = await shell.load_data_async(base, message)
	else:
		_show_overlay(message)
		await get_tree().process_frame
		await get_tree().process_frame
		ok = _pl.reload()
		_hide_overlay()
	_pl.rescan()
	_busy_apply = false
	_set_status(("Loaded %d resources." % _pl.loaded_resource_count()) if ok else "Couldn't reload the game data.")
	return ok


## The Shell (has `load_data_async`) among this node's ancestors, if any.
func _find_shell() -> Node:
	var n := get_parent()
	while n != null:
		if n.has_method("load_data_async"):
			return n
		n = n.get_parent()
	return null


func _show_overlay(message: String) -> void:
	_hide_overlay()
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.8)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.add_child(dim)
	var c := CenterContainer.new()
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.add_child(c)
	var card := PanelContainer.new()
	card.add_theme_stylebox_override("panel", T.box(Color(0.12, 0.12, 0.13), 18, Color(1, 1, 1, 0.12), 1, Vector2(34, 24)))
	c.add_child(card)
	var v := _vbox(card, 12)
	var ic := CenterContainer.new()
	v.add_child(ic)
	_svg(ic, "puzzlepiece.extension.fill", 40, T.AMBER)
	var l := _t(v, message, 22, "semibold")
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_root.add_child(_overlay)


func _hide_overlay() -> void:
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.queue_free()
	_overlay = null


func _done() -> void:
	if _pl.needs_reload():
		await _apply()
	closed.emit()


func _process(delta: float) -> void:
	if _root == null:
		return
	_poll += delta
	if _poll < 0.4:
		return
	_poll = 0.0
	for url in _icons.keys():
		_try_icon(url)
	if _busy_apply:
		return
	if tab == "Installed" and detail_id == "" and _tc_analysed != "" and _pl.has_method("tc_addons"):
		var ti: Variant = JSON.parse_string(_pl.tc_addons())
		var now_analysing: bool = ti is Dictionary and bool((ti as Dictionary).get("analysing", false))
		if _tc_was_analysing and not now_analysing and _tc_add_open:
			_render()   # record-overlap suggestions arrived
		_tc_was_analysing = now_analysing
	var cat := _catalog()
	var working := false
	for e in cat.entries:
		if not e.transfer.is_empty():
			working = true
	_refresh_label.visible = bool(cat.refreshing)
	if cat.busy or cat.refreshing or working:
		# Refresh progress / catalog arrival, unless the player is typing.
		if (tab == "Browse" or detail_id != "") and not (get_viewport().gui_get_focus_owner() is LineEdit):
			var pos := _scroll.scroll_vertical
			var f := get_viewport().gui_get_focus_owner()
			var focus_key := ""
			if f != null and f.has_meta("fkey"):
				focus_key = str(f.get_meta("fkey"))
			elif f is Button:
				focus_key = (f as Button).text
			_render(false)
			_scroll.scroll_vertical = pos
			_keep_scroll.call_deferred(pos)
			_restore_focus(focus_key)
	elif cat.needsReload and not cat.busy and _installed_changed_by_store(cat):
		await _apply("Installing...")
		_render()


func _keep_scroll(pos: int) -> void:
	if is_instance_valid(_scroll):
		_scroll.scroll_vertical = pos


## Only an install / update that just finished triggers the automatic reload (toggles and
## moves wait for Apply / Done).
var _was_working := false
func _installed_changed_by_store(cat: Dictionary) -> bool:
	var was := _was_working
	_was_working = cat.busy
	return was and not cat.busy


## Put focus back on the control that had it before a re-render: matched by its `fkey` meta
## (cards, state buttons), else by button text.
func _restore_focus(text: String) -> void:
	if text == "":
		return
	for b in _content.find_children("*", "Button", true, false):
		if (b.has_meta("fkey") and str(b.get_meta("fkey")) == text) or b.text == text:
			ShellUI.focus(b)
			return


func _unhandled_input(event: InputEvent) -> void:
	if _busy_apply or (_import_dialog != null and _import_dialog.visible):
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		if detail_id != "":
			detail_id = ""
			_render()
		else:
			_done()
	elif event is InputEventJoypadButton and event.pressed and detail_id == "" \
			and (event.button_index == JOY_BUTTON_LEFT_SHOULDER or event.button_index == JOY_BUTTON_RIGHT_SHOULDER):
		var step: int = -1 if event.button_index == JOY_BUTTON_LEFT_SHOULDER else 1
		var i: int = clampi(TABS.find(tab) + step, 0, TABS.size() - 1)
		if TABS[i] != tab:
			get_viewport().set_input_as_handled()
			_set_tab(TABS[i])
