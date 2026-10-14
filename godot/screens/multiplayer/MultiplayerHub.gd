# NOVA Swift -- the Multiplayer hub (NovaSwift UI kit; mouse, keyboard and gamepad via Godot focus + PadCursor).
# The Godot counterpart of the Apple MultiplayerHubView / MultiplayerLobbyViews, for the ENet transport
# (net/NetService.gd): LAN, direct IP:port and player-run dedicated servers. No Game Center here.
#
# Built like the Plug-ins hub: gradient backdrop, a header (icon tile, title, connection pill, Done), an icon
# segmented tab bar (LB / RB on a pad), a centred content column (max ~940 px so large windows stay readable),
# server rows as kit cards (status tile, name + badges, address, players, ping pill, Join / star), empty states
# with art + an action, a grouped Host form with rules preset cards, and a footer hint bar when a pad is attached.
#
# Tabs:  Browse   (default) ONE list of every server you can reach: Saved (pinned on top, filled star), LAN games and the
#                 public directory, merged by address, each row tagged with its sources. Search + chips (All / Saved / LAN /
#                 Public, Compatible only, Has players, No password, region). Quick Connect (header button, X on a pad) is
#                 a small dialog: address, password, "Save this server".
#        Host     name - port - max players - rules (Safe / Full stakes / Custom toggles) - password - LAN visible - Encrypt;
#                 a pointer to the standalone Dedicated Server for always-on hosting
#        Session  (only while in a game: status, players with Trade / Kick / Ban, rules, chat, Leave)
# Errors (refused, wrong password, full, version / plug-in mismatch, timeout, kicked) show in a banner on top;
# a connect in flight shows a progress banner with Cancel.
#
# Controls: B / Esc = close, LB / RB = previous / next tab, Y = refresh (Browse), X = the page's main
# action (Quick Connect / Start hosting). The live lists rebuild only when their content changes and put focus back on the
# same Join button, so a pad is never thrown off a row by the one-second refresh.
#
# Reach it with MultiplayerHub.new() + add_child + setup(nova); it emits `closed`. Main menu, Classic main menu
# and the pause menu open it through Shell._open_multiplayer.
#
# Loaded with preload() (no class_name), like Controls.gd.
extends CanvasLayer

const T = preload("res://ui/novaswift/NovaTheme.gd")
const NC = preload("res://ui/novaswift/NovaControls.gd")
const Alert = preload("res://ui/novaswift/NovaAlert.gd")
const SVG = preload("res://ui/novaswift/NovaSVG.gd")
const Proto = preload("res://net/NetProto.gd")
const NetPlugins = preload("res://net/NetPlugins.gd")
const NetPrefs = preload("res://net/NetPrefs.gd")
const Directory = preload("res://net/ServerDirectory.gd")
const PluginsScreen = preload("res://screens/Plugins.gd")

signal closed

const TABS := ["Session", "Browse", "Host"]
const TAB_ICONS := {"Session": "person.2.fill", "Browse": "magnifyingglass", "Host": "plus.circle"}
const MAX_W := 940.0
const INK := Color(0.06, 0.05, 0.03)   # text on an amber fill

## Glyphs this screen needs on top of the kit set (registered once into NovaSVG; 24 x 24 grid, stroke "C").
const GLYPHS := {
	"wifi": "<path d='M2.5 9a15 15 0 0119 0'/><path d='M5.8 12.6a10 10 0 0112.4 0'/><path d='M9 16a5 5 0 016 0'/><circle cx='12' cy='19.3' r='1.3' fill='C' stroke='none'/>",
	"server.rack": "<rect x='3.5' y='4' width='17' height='6.5' rx='2'/><rect x='3.5' y='13.5' width='17' height='6.5' rx='2'/><circle cx='7.5' cy='7.25' r='.9' fill='C' stroke='none'/><circle cx='7.5' cy='16.75' r='.9' fill='C' stroke='none'/><path d='M12 7.25h5M12 16.75h5'/>",
	"arrow.right.circle": "<circle cx='12' cy='12' r='9.5'/><path d='M7.5 12h9M13 8.5l3.5 3.5-3.5 3.5'/>",
	"plus.circle": "<circle cx='12' cy='12' r='9.5'/><path d='M12 7.5v9M7.5 12h9'/>",
	"bubble.left.fill": "<path fill='C' stroke='none' d='M6 4h12a3 3 0 013 3v7a3 3 0 01-3 3h-6l-5 4v-4H6a3 3 0 01-3-3V7a3 3 0 013-3z'/>",
	"shield.lefthalf.filled": "<path d='M12 3l7.5 2.8v5.7c0 4.6-3.2 8.2-7.5 9.5-4.3-1.3-7.5-4.9-7.5-9.5V5.8z'/><path fill='C' stroke='none' d='M12 3v18c-4.3-1.3-7.5-4.9-7.5-9.5V5.8z'/>",
	"network": "<circle cx='12' cy='5.5' r='2.4'/><circle cx='5.5' cy='18' r='2.4'/><circle cx='18.5' cy='18' r='2.4'/><path d='M12 8v4.5M12 12.5l-5 3.4M12 12.5l5 3.4'/>",
	"wifi.slash": "<path d='M2.5 9a15 15 0 019-4M21.5 9a15 15 0 00-3.6-2.7M5.8 12.6a10 10 0 014-2.4M18.2 12.6a10 10 0 00-2.5-1.9M9 16a5 5 0 013.2-1.2'/><path d='M3.5 3.5l17 17' stroke-width='2'/>",
}
static var _glyphs_ready: bool = false

var tab: String = "Browse"
var first_control: Control = null

var _nova: Object = null
var _svc: Node = null
var _scale: float = 1.0
var _root: Control
var _tabs_host: MarginContainer
var _tab_wrap: PanelContainer = null
var _tab_buttons: Dictionary = {}
var _tab_key: String = ""
var _banner_box: VBoxContainer
var _status_box: HBoxContainer
var _scroll: ScrollContainer
var _page: VBoxContainer
var _hint_bar: HBoxContainer
var _gutters: Array = []
var _dyns: Dictionary = {}       # name -> VBoxContainer rebuilt by _refresh_dynamic
var _dyn_sigs: Dictionary = {}   # name -> content signature of what is on screen
var _form: Dictionary = {}
var _join_pw: String = ""
## Browse filters: source (All | Saved | LAN | Public), search text, the three toggles and a region ("" = any).
var _br: Dictionary = {"search": "", "source": "All", "compat": false, "players": false, "nopw": false, "region": ""}
var _quick_btn: Button = null
var _name_edit: LineEdit
var _chat_edit: LineEdit
var _chat_scroll: ScrollContainer = null
var _refresh: Timer
var _last_query: float = -100.0
var _dir: Node = null
var _pub_query_at: float = -100.0
var _pub_last: Dictionary = {}   # "host:port" -> last answered live record, so rows don't flicker between pings
var _pub_status: Label = null
var _pad_seen: bool = false


func setup(nova: Object, start_tab: String = "") -> void:
	layer = 74
	_nova = nova
	_ensure_glyphs()
	_scale = clampf(DisplayServer.screen_get_scale(), 1.0, 3.0)
	_svc = get_node_or_null("/root/NetService")
	if _svc != null:
		_svc.bind(nova)
		_svc.hub_open = true
		_svc.ui_event.connect(_on_net_event)
		_svc.session_changed.connect(_on_session_changed)
	_form = NetPrefs.host_form()
	if str(_form.get("name", "")) == "":
		_form["name"] = NetPrefs.display_name() + "'s game"
	tab = start_tab if TABS.has(start_tab) else ("Session" if _svc != null and _svc.is_active() else "Browse")
	_build_frame()
	_render()
	_refresh = Timer.new()
	_refresh.wait_time = 1.0
	_refresh.timeout.connect(_tick)
	add_child(_refresh)
	_refresh.start()


func _exit_tree() -> void:
	if _svc != null and is_instance_valid(_svc):
		_svc.hub_open = false
		_svc.stop_lan_browser()


static func _ensure_glyphs() -> void:
	if _glyphs_ready:
		return
	_glyphs_ready = true
	for k in GLYPHS:
		if not SVG.has(k):
			SVG.register(str(k), str(GLYPHS[k]))


func _unhandled_input(e: InputEvent) -> void:
	if e.is_action_pressed("ui_cancel") and not _has_alert():
		get_viewport().set_input_as_handled()
		_close()
	elif e is InputEventJoypadButton and e.pressed and not _has_alert():
		var jb: InputEventJoypadButton = e
		match jb.button_index:
			JOY_BUTTON_LEFT_SHOULDER, JOY_BUTTON_RIGHT_SHOULDER:
				var list: Array = _tab_list()
				var i: int = clampi(list.find(tab) + (-1 if jb.button_index == JOY_BUTTON_LEFT_SHOULDER else 1), 0, list.size() - 1)
				if str(list[i]) != tab:
					get_viewport().set_input_as_handled()
					_set_tab(str(list[i]))
			JOY_BUTTON_Y:
				if _refresh_action():
					get_viewport().set_input_as_handled()
			JOY_BUTTON_X:
				if _main_action():
					get_viewport().set_input_as_handled()


func _input(e: InputEvent) -> void:
	if (e is InputEventJoypadButton or e is InputEventJoypadMotion) and not _pad_seen:
		_pad_seen = true
		_update_hint_bar()


func _has_alert() -> bool:
	return get_tree().root.find_child("NovaAlert", true, false) != null


func _close() -> void:
	closed.emit()


func _set_tab(t: String) -> void:
	if t == tab:
		return
	tab = t
	_render()
	if _scroll != null:
		_scroll.scroll_vertical = 0


## Y: re-query the server list. Returns true when the tab has something to refresh.
func _refresh_action() -> bool:
	if _svc == null or tab != "Browse":
		return false
	_directory().refresh(true)
	_query_public(true)
	_query_saved(true)
	_refresh_dynamic()
	return true


## X: the page's main action (Browse: Quick Connect; Host: Start hosting). Returns true when it did something.
func _main_action() -> bool:
	if _svc == null or _svc.is_active():
		return false
	var fo: Control = get_viewport().gui_get_focus_owner()
	if fo is LineEdit:
		return false
	match tab:
		"Host":
			_start_host()
			return true
		"Browse":
			_quick_connect()
			return true
	return false


# --- small builders ------------------------------------------------------------------------------------------------

## A label in the system font (same helper shape as the Plug-ins hub).
func _t(parent: Control, text: String, size: int = 14, weight: String = "regular", color: Color = T.WHITE, wrap: bool = false) -> Label:
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


func _hbox(parent: Control, sep: int = 8) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", sep)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if parent != null:
		parent.add_child(h)
	return h


func _vbox(parent: Control, sep: int = 6) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if parent != null:
		parent.add_child(v)
	return v


func _flow(parent: Control, h_sep: int = 6, v_sep: int = 4) -> HFlowContainer:
	var f := HFlowContainer.new()
	f.add_theme_constant_override("h_separation", h_sep)
	f.add_theme_constant_override("v_separation", v_sep)
	f.mouse_filter = Control.MOUSE_FILTER_IGNORE
	f.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if parent != null:
		parent.add_child(f)
	return f


## A kit glyph as a crisp TextureRect drawn at `px`.
func _svg(parent: Control, glyph: String, px: int = 16, color: Color = T.WHITE) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = T.icon(glyph, int(ceil(px * _scale)), color)
	tr.custom_minimum_size = Vector2(px, px)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if parent != null:
		parent.add_child(tr)
	return tr


## A glyph on a Button's icon slot at `px`.
func _hi_icon(b: Button, glyph: String, px: int = 16, color: Color = T.WHITE) -> void:
	b.icon = T.icon(glyph, int(ceil(px * _scale)), color)
	b.expand_icon = false
	b.add_theme_constant_override("icon_max_width", px)


func _btn(parent: Control, text: String, cb: Callable, kind: String = "bordered", glyph: String = "", fkey: String = "") -> Button:
	var b: Button = NC.button(text, kind, cb)
	if glyph != "":
		var fg: Color = T.WHITE
		if kind == "primary":
			fg = INK
		elif kind == "destructive":
			fg = T.RED
		_hi_icon(b, glyph, 16, fg)
		b.add_theme_constant_override("h_separation", 7)
		if kind == "primary":
			for s in ["icon_normal_color", "icon_hover_color", "icon_focus_color", "icon_pressed_color"]:
				b.add_theme_color_override(s, INK)
	b.custom_minimum_size.y = 34
	if fkey != "":
		b.set_meta("fkey", fkey)
	if parent != null:
		parent.add_child(b)
	return b


func _icon_btn(parent: Control, glyph: String, tip: String, cb: Callable, fkey: String = "", color: Color = T.WHITE) -> Button:
	var b: Button = NC.bordered_icon_button(glyph, cb, tip)
	_hi_icon(b, glyph, 16, color)
	b.custom_minimum_size = Vector2(38, 34)
	if fkey != "":
		b.set_meta("fkey", fkey)
	if parent != null:
		parent.add_child(b)
	return b


func _badge(parent: Control, text: String, color: Color = T.SECONDARY, glyph: String = "") -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", T.box(Color(color.r, color.g, color.b, 0.16), 20, Color(0, 0, 0, 0), 0, Vector2(8, 3)))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h := _hbox(p, 4)
	if glyph != "":
		_svg(h, glyph, 11, color)
	_t(h, text, 11, "semibold", color)
	if parent != null:
		parent.add_child(p)
	return p


## Latency pill: a coloured dot + "42 ms" (green under 80, amber under 160, red above); "no ping" when unknown.
func _ping_pill(parent: Control, ms: int) -> PanelContainer:
	var col: Color = T.SECONDARY
	var txt: String = "no ping"
	if ms >= 0:
		txt = "%d ms" % ms
		col = T.GREEN if ms < 80 else (T.ORANGE if ms < 160 else T.RED)
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", T.box(Color(col.r, col.g, col.b, 0.14), 20, Color(0, 0, 0, 0), 0, Vector2(9, 4)))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var h := _hbox(p, 5)
	_svg(h, "circle.fill", 7, col)
	_t(h, txt, 12, "semibold", col)
	if parent != null:
		parent.add_child(p)
	return p


## A rounded tinted square with a glyph (header, server rows, empty cards).
func _icon_tile(parent: Control, size: int, tint: Color, glyph: String, bg_alpha: float = 0.18) -> Control:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(size, size)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", T.box(Color(tint.r, tint.g, tint.b, bg_alpha), int(size * 0.28)))
	var c := CenterContainer.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(c)
	_svg(c, glyph, int(size * 0.5), tint)
	if parent != null:
		parent.add_child(p)
	return p


func _section_title(parent: Control, title: String, glyph: String, right_text: String = "") -> HBoxContainer:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 4)
	m.add_theme_constant_override("margin_top", 8)
	parent.add_child(m)
	var h := _hbox(m, 8)
	if glyph != "":
		_svg(h, glyph, 16, T.AMBER)
	_t(h, title, 15, "semibold", T.AMBER)
	if right_text != "":
		NC.hspacer(h)
		_t(h, right_text, 12, "regular", T.SECONDARY)
	return h


func _note(parent: Control, text: String, size: int = 13) -> Label:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_left", 4)
	m.add_theme_constant_override("margin_right", 4)
	parent.add_child(m)
	return _t(m, text, size, "regular", T.SECONDARY, true)


## Remove children right away (queue_free alone leaves them in the tree for a frame, which confuses focus lookups).
func _clear(n: Node) -> void:
	for c in n.get_children():
		n.remove_child(c)
		c.queue_free()


# --- frame ---------------------------------------------------------------------------------------------------------

func _gutter(m: MarginContainer, top: int = 0, bottom: int = 0) -> MarginContainer:
	m.add_theme_constant_override("margin_left", 20)
	m.add_theme_constant_override("margin_right", 20)
	if top > 0:
		m.add_theme_constant_override("margin_top", top)
	if bottom > 0:
		m.add_theme_constant_override("margin_bottom", bottom)
	_gutters.append(m)
	return m


## Centre the content column: side margins grow once the window is wider than MAX_W (+ 40 px gutters).
func _fit_gutters() -> void:
	if _root == null:
		return
	var side: int = maxi(20, int((_root.size.x - MAX_W) * 0.5))
	for m in _gutters:
		if is_instance_valid(m):
			(m as MarginContainer).add_theme_constant_override("margin_left", side)
			(m as MarginContainer).add_theme_constant_override("margin_right", side)


func _build_frame() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.theme = T.theme()
	add_child(_root)
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

	# Header: [icon tile] Multiplayer / subtitle ........ [connection pill] Done
	var top := _gutter(MarginContainer.new(), 14, 12)
	box.add_child(top)
	var head := _hbox(top, 12)
	_icon_tile(head, 38, T.AMBER, "person.2.fill", 0.16)
	var titles := _vbox(head, 0)
	titles.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_t(titles, "Multiplayer", 24, "bold")
	_t(titles, "Find a game, connect by address, or host your own", 12, "regular", T.SECONDARY)
	NC.hspacer(head)
	_status_box = _hbox(head, 8)
	_status_box.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_quick_btn = _btn(head, "Quick Connect", _quick_connect, "bordered", "arrow.right.circle", "quick")
	_quick_btn.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var done: Button = _btn(head, "Done", _close, "primary")
	done.custom_minimum_size.x = 76
	first_control = done

	# Tab bar
	_tabs_host = _gutter(MarginContainer.new(), 0, 10)
	box.add_child(_tabs_host)

	# Banner slot (errors, connecting)
	var bw := _gutter(MarginContainer.new(), 0, 6)
	_banner_box = VBoxContainer.new()
	_banner_box.add_theme_constant_override("separation", 8)
	bw.add_child(_banner_box)
	box.add_child(bw)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.follow_focus = true
	box.add_child(_scroll)
	var m := _gutter(MarginContainer.new(), 4, 24)
	m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.add_child(m)
	_page = VBoxContainer.new()
	_page.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page.add_theme_constant_override("separation", 8)
	m.add_child(_page)

	# Pad hint bar (shown once a pad is attached / touched)
	var hb := _gutter(MarginContainer.new(), 4, 10)
	box.add_child(hb)
	_hint_bar = _hbox(hb, 18)
	_hint_bar.alignment = BoxContainer.ALIGNMENT_CENTER
	_update_hint_bar()

	_root.resized.connect(_fit_gutters)
	_fit_gutters.call_deferred()


func _update_hint_bar() -> void:
	if _hint_bar == null:
		return
	_clear(_hint_bar)
	var shown: bool = _pad_seen or not Input.get_connected_joypads().is_empty()
	_hint_bar.get_parent().visible = shown
	if not shown:
		return
	var items: Array = [["LB RB", "Tabs"], ["Y", "Refresh"], ["X", "Quick connect / Host"], ["B", "Back"]]
	for it in items:
		var h := _hbox(_hint_bar, 6)
		var chip := PanelContainer.new()
		chip.add_theme_stylebox_override("panel", T.box(Color(1, 1, 1, 0.10), 5, Color(0, 0, 0, 0), 0, Vector2(6, 2)))
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(chip)
		_t(chip, str(it[0]), 11, "bold", T.AMBER)
		_t(h, str(it[1]), 12, "regular", T.SECONDARY)


func _tab_list() -> Array:
	var out: Array = []
	for t in TABS:
		if t == "Session" and not (_svc != null and _svc.is_active()):
			continue
		out.append(t)
	return out


## The icon segmented picker (same pill as the Plug-ins hub). Rebuilt only when the tab set changes.
func _build_tabs(list: Array) -> void:
	if _tab_wrap != null:
		_tabs_host.remove_child(_tab_wrap)
		_tab_wrap.queue_free()
	_tab_buttons.clear()
	_tab_wrap = PanelContainer.new()
	_tab_wrap.add_theme_stylebox_override("panel", T.box(Color(1, 1, 1, 0.07), 13, Color(1, 1, 1, 0.07), 1, Vector2(3, 3)))
	_tab_wrap.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_tabs_host.add_child(_tab_wrap)
	var h := _hbox(_tab_wrap, 2)
	for tname in list:
		var tn: String = str(tname)
		var b := Button.new()
		b.text = tn
		b.toggle_mode = true
		b.button_pressed = tn == tab
		b.focus_mode = Control.FOCUS_ALL
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var pad := Vector2(15, 7)
		b.add_theme_stylebox_override("normal", T.box(Color(0, 0, 0, 0), 10, Color(0, 0, 0, 0), 0, pad))
		b.add_theme_stylebox_override("hover", T.box(Color(1, 1, 1, 0.09), 10, Color(0, 0, 0, 0), 0, pad))
		b.add_theme_stylebox_override("pressed", T.box(T.AMBER, 10, Color(0, 0, 0, 0), 0, pad))
		b.add_theme_stylebox_override("hover_pressed", T.box(T.AMBER.lightened(0.08), 10, Color(0, 0, 0, 0), 0, pad))
		b.add_theme_stylebox_override("disabled", T.empty())
		T.style_text(b, "body", "semibold", T.WHITE, 14)
		b.add_theme_font_override("font", T.system("semibold"))
		b.add_theme_color_override("font_hover_color", T.WHITE)
		b.add_theme_color_override("font_focus_color", T.WHITE)
		b.add_theme_color_override("font_pressed_color", INK)
		b.add_theme_color_override("font_hover_pressed_color", INK)
		_hi_icon(b, str(TAB_ICONS.get(tn, "circle")), 16, Color.WHITE)
		b.add_theme_constant_override("h_separation", 7)
		b.add_theme_color_override("icon_normal_color", Color(1, 1, 1, 0.8))
		b.add_theme_color_override("icon_hover_color", Color.WHITE)
		b.add_theme_color_override("icon_focus_color", Color.WHITE)
		b.add_theme_color_override("icon_pressed_color", INK)
		b.add_theme_color_override("icon_hover_pressed_color", INK)
		b.set_meta("fkey", "tab:" + tn)
		b.pressed.connect(func() -> void:
			_set_tab(tn)
			if _tab_buttons.has(tn):
				(_tab_buttons[tn] as Button).set_pressed_no_signal(true))
		NC.grow_on_focus(b, 1.03)
		h.add_child(b)
		_tab_buttons[tn] = b


func _sync_tabs() -> void:
	for k in _tab_buttons:
		(_tab_buttons[k] as Button).set_pressed_no_signal(str(k) == tab)


# --- render --------------------------------------------------------------------------------------------------------

func _focus_key(c: Control) -> String:
	if c == null:
		return ""
	if c.has_meta("fkey"):
		return str(c.get_meta("fkey"))
	if c is Button:
		return (c as Button).text
	return ""


func _find_focus(under: Node, key: String) -> Control:
	if key == "":
		return null
	for b in under.find_children("*", "Button", true, false):
		if _focus_key(b as Control) == key and (b as Control).is_visible_in_tree():
			return b as Control
	return null


func _render() -> void:
	var fo: Control = get_viewport().gui_get_focus_owner() if is_inside_tree() else null
	var keep: String = ""
	if fo != null and not (fo is LineEdit) and (self.is_ancestor_of(fo)):
		keep = _focus_key(fo)
	var list: Array = _tab_list()
	if not list.has(tab):
		tab = "Browse"
	var key: String = ",".join(PackedStringArray(list))
	if key != _tab_key or _tab_wrap == null:
		_tab_key = key
		_build_tabs(list)
	_sync_tabs()
	_update_header()
	_render_banner()
	_clear(_page)
	_dyns.clear()
	_dyn_sigs.clear()
	_name_edit = null
	_chat_edit = null
	_chat_scroll = null
	_pub_status = null
	if _svc == null:
		_empty(_page, "wifi.slash", T.RED, "Multiplayer isn't available", "The networking service didn't load, so there is nothing to host or join.", [])
		return
	match tab:
		"Session": _page_session()
		"Browse": _page_browse()
		"Host": _page_host()
	_refresh_dynamic()
	var restore := func() -> void:
		if not is_inside_tree():
			return
		var target: Control = _find_focus(self, keep)
		if target == null and keep == "":
			target = _first_page_focus()
		if target != null:
			target.grab_focus()
	restore.call_deferred()


## Where focus lands after a render when nothing on the page had it: the current tab (never a text field, which would
## pop a pad's on-screen keyboard open, and never a button far down the page, which would scroll it).
func _first_page_focus() -> Control:
	var fo: Control = get_viewport().gui_get_focus_owner()
	if fo != null and self.is_ancestor_of(fo):
		return null   # focus is already somewhere on this screen
	return _tab_buttons.get(tab, first_control) as Control


func _update_header() -> void:
	if _quick_btn != null:
		_quick_btn.visible = _svc != null and not _svc.is_active()
	_clear(_status_box)
	if _svc == null or not _svc.is_active():
		return
	if _svc.is_connected_to_session():
		_badge(_status_box, "Hosting" if _svc.is_hosting() else "Connected", T.GREEN, "circle.fill")
	else:
		_badge(_status_box, "Connecting", T.AMBER, "circle.fill")


func _render_banner() -> void:
	_clear(_banner_box)
	if _svc == null:
		return
	if _svc.is_active() and not _svc.is_connected_to_session():
		var p := PanelContainer.new()
		p.add_theme_stylebox_override("panel", T.box(Color(T.AMBER.r, T.AMBER.g, T.AMBER.b, 0.10), 12, Color(T.AMBER.r, T.AMBER.g, T.AMBER.b, 0.40), 1, Vector2(14, 10)))
		_banner_box.add_child(p)
		var v := _vbox(p, 8)
		var h := _hbox(v, 10)
		_svg(h, "wifi", 18, T.AMBER)
		var col := _vbox(h, 1)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_t(col, _svc.status_text(), 15, "semibold", T.AMBER)
		_t(col, "Checking the address, version and plug-ins with the host...", 12, "regular", T.SECONDARY)
		var cancel: Button = _btn(h, "Cancel", func() -> void: _svc.leave(), "bordered", "", "banner:cancel")
		cancel.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var bar: ProgressBar = NC.progress(v, 0.0, 60.0)
		bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var tw: Tween = bar.create_tween().set_loops()
		tw.tween_property(bar, "value", 1.0, 1.1)
		tw.tween_property(bar, "value", 0.0, 0.0)
	elif _svc.last_error != "":
		var p2 := PanelContainer.new()
		p2.add_theme_stylebox_override("panel", T.box(Color(T.RED.r, T.RED.g, T.RED.b, 0.11), 12, Color(T.RED.r, T.RED.g, T.RED.b, 0.50), 1, Vector2(14, 10)))
		_banner_box.add_child(p2)
		var h2 := _hbox(p2, 10)
		var ic: TextureRect = _svg(h2, "exclamationmark.triangle.fill", 20, T.RED)
		ic.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		var col2 := _vbox(h2, 2)
		col2.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_t(col2, _error_title(_svc.last_error_code), 15, "semibold", T.RED)
		_t(col2, _svc.last_error, 14, "regular", T.WHITE, true)
		var hint: String = _error_hint(_svc.last_error_code)
		if hint != "":
			_t(col2, hint, 12, "regular", T.SECONDARY, true)
		if _svc.last_error_code == "key_changed":
			var kd: Dictionary = _svc.last_error_detail
			var trust: Button = _btn(h2, "Trust new key and join", func() -> void:
				var j: Dictionary = _svc._pending_join
				_svc.last_error = ""
				_svc.last_error_code = ""
				_svc.join_game(str(kd.get("host", j.get("host", ""))), int(kd.get("port", j.get("port", Proto.DEFAULT_PORT))),
					str(j.get("pw", "")), str(j.get("name", "")), {"accept_new_key": true})
				_render_banner(), "destructive", "", "banner:trust")
			trust.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		var dis: Button = _btn(h2, "Dismiss", func() -> void:
			_svc.last_error = ""
			_svc.last_error_code = ""
			_render_banner(), "bordered", "", "banner:dismiss")
		dis.size_flags_vertical = Control.SIZE_SHRINK_BEGIN


static func _error_title(code: String) -> String:
	match code:
		"version": return "Game version mismatch"
		"proto": return "Incompatible multiplayer protocol"
		"password": return "Password required"
		"full": return "Server full"
		"plugins": return "Plug-ins don't match"
		"banned": return "Banned"
		"timeout": return "Couldn't connect"
		"kicked": return "Removed from the game"
		"disconnected": return "Disconnected"
		"bad_request": return "Refused"
		"key_changed": return "Server key changed"
	return "Multiplayer problem"


static func _error_hint(code: String) -> String:
	match code:
		"key_changed": return "If you didn't expect this, don't continue and ask the server's owner whether they regenerated the key."
		"timeout": return "Check the address, that the server is running, and that its UDP port (default 53735) is allowed through the firewall / forwarded on the router."
		"plugins": return "Change plug-ins from the main menu's Plug-ins screen so your enabled set matches the host's, then rejoin."
		"version": return "Everyone must run the same NovaSwift version."
		"password": return "Enter the server's password in the Password field and try again."
	return ""


func _on_net_event(ev: Dictionary) -> void:
	if str(ev.get("type", "")) == "rejected" and str(ev.get("code", "")) == "plugins" and (ev.get("detail", {}) as Dictionary).has("server_manifest"):
		_open_plugin_gate(ev)
		return
	match str(ev.get("type", "")):
		"connected":
			tab = "Session"
			_render()
		"rejected", "timeout", "error", "kicked", "disconnected":
			_render()
		_:
			if tab == "Session" or tab == "Browse":
				_refresh_dynamic()


## The join was refused over GAMEPLAY plug-ins: offer to install / enable them (cosmetic plug-ins never get here).
func _open_plugin_gate(ev: Dictionary) -> void:
	_svc.last_error = ""
	_svc.last_error_code = ""
	_render_banner()
	var gate: Node = (load("res://screens/multiplayer/PluginGate.gd") as GDScript).new()
	gate.run(self, _nova, _svc, ev.get("detail", {}) as Dictionary, _svc._pending_join, _join_meta)


var _join_meta: Dictionary = {}


func _on_session_changed() -> void:
	if is_inside_tree():
		_render.call_deferred()


func _tick() -> void:
	if tab == "Browse" or tab == "Session":
		if tab == "Browse":
			_query_saved(false)
			_query_public(false)
		_refresh_dynamic()


# --- empty states ----------------------------------------------------------------------------------------------------

## Illustration + title + body + action buttons ([{text, kind, glyph, cb}]), centred in a soft card.
func _empty(parent: Control, glyph: String, tint: Color, title: String, body: String, actions: Array) -> Control:
	var card: PanelContainer = NC.card(parent, 16, 18, true)
	var v := _vbox(card, 6)
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	var c := CenterContainer.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(c)
	var art := TextureRect.new()
	var gbody: String = str(SVG._extra.get(glyph, SVG.GLYPHS.get(glyph, "<rect x='6' y='6' width='12' height='12' rx='2'/>")))
	art.texture = SVG.render(PluginsScreen._empty_svg(gbody, tint), Vector2i(540, 285), Vector2i(360, 190), "mp.empty/%s/%s" % [glyph, tint.to_html(false)])
	art.custom_minimum_size = Vector2(240, 126)
	art.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	art.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	art.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.add_child(art)
	var tl: Label = _t(v, title, 19, "semibold")
	tl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var bl: Label = _t(v, body, 14, "regular", T.SECONDARY, true)
	bl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	if not actions.is_empty():
		var ac := CenterContainer.new()
		ac.mouse_filter = Control.MOUSE_FILTER_IGNORE
		v.add_child(ac)
		var m := MarginContainer.new()
		m.add_theme_constant_override("margin_top", 8)
		ac.add_child(m)
		var row := _hbox(m, 10)
		for a in actions:
			var d: Dictionary = a
			_btn(row, str(d["text"]), d["cb"], str(d.get("kind", "bordered")), str(d.get("glyph", "")), "empty:" + str(d["text"]))
	return card


# --- form helpers ------------------------------------------------------------------------------------------------------

func _row(g: NC.Group, title: String, c: Control, min_h: float = 44.0, expand: bool = true) -> void:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	var l := _t(h, title, 15, "regular", T.WHITE)
	l.custom_minimum_size = Vector2(160, 0)
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL if expand else Control.SIZE_SHRINK_BEGIN
	h.add_child(c)
	g.add_row(h, min_h)


func _field(g: NC.Group, title: String, value: String, placeholder: String, cb: Callable, secret: bool = false, expand: bool = true) -> LineEdit:
	var e: LineEdit = NC.text_field(placeholder, value)
	e.secret = secret
	e.text_changed.connect(cb)
	e.set_meta("fkey", "field:" + title)
	if not expand:
		e.custom_minimum_size.x = 140
	_row(g, title, e, 44.0, expand)
	return e


func _name_row(g: NC.Group) -> void:
	_name_edit = _field(g, "Your name", NetPrefs.display_name(), "Pilot name", func(_t2: String) -> void: pass)


func _my_name() -> String:
	var n: String = _name_edit.text if _name_edit != null else NetPrefs.display_name()
	var clean: String = Proto.clean_name(n, "Pilot")
	if _name_edit != null:
		NetPrefs.set_display_name(clean)
	return clean


func _local_addresses() -> String:
	var out: PackedStringArray = PackedStringArray()
	for a in IP.get_local_addresses():
		if a.count(".") == 3 and not a.begins_with("127.") and not a.begins_with("169.254."):
			out.append(a)
	return ", ".join(out) if not out.is_empty() else "unknown"


func _first_local_address() -> String:
	var all: String = _local_addresses()
	return all.split(",")[0].strip_edges() if all != "unknown" else ""


# --- Host --------------------------------------------------------------------------------------------------------------

func _rules_from_form() -> Dictionary:
	match str(_form.get("preset", "safe")):
		"safe": return Proto.rules_for_preset("safe")
		"full": return Proto.rules_for_preset("full")
	var r: Dictionary = Proto.rules_for_preset("safe")
	for k in ["allow_pvp", "pvp_damage_real", "friendly_fire", "death_real", "allow_trade"]:
		r[k] = bool(_form.get(k, r[k]))
	return r


func _preset_card(parent: Control, key: String, glyph: String, tint: Color, title: String, desc: String) -> void:
	var sel: bool = str(_form["preset"]) == key
	var b: Button = NC.card_button(parent, Color(tint.r, tint.g, tint.b, 0.14) if sel else T.CARD_BG, T.AMBER if sel else T.CARD_BORDER, 14, 14)
	b.custom_minimum_size = Vector2(0, 112)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.set_meta("fkey", "preset:" + key)
	b.pressed.connect(func() -> void:
		_form["preset"] = key
		_render())
	var v := _vbox(b.get_meta("content"), 6)
	var top := _hbox(v, 8)
	_svg(top, glyph, 18, tint)
	_t(top, title, 16, "semibold")
	NC.hspacer(top)
	if sel:
		_svg(top, "checkmark.circle.fill", 17, T.AMBER)
	_t(v, desc, 12, "regular", T.SECONDARY, true)


func _page_host() -> void:
	if _svc.is_active():
		_empty(_page, "person.2.fill", T.GREEN, "You're already in a game", "Leave it from the Session tab before hosting another.",
			[{"text": "Open Session", "kind": "primary", "glyph": "person.2.fill", "cb": func() -> void: _set_tab("Session")}])
		return
	var g: NC.Group = NC.section(_page, "Host a game", "person.2.fill",
		"Your own galaxy and pilot stay yours; players in the same star system as you play it together.")
	_name_row(g)
	_field(g, "Game name", str(_form["name"]), "Name shown to others", func(t: String) -> void: _form["name"] = t)
	var port_e: LineEdit = _field(g, "Port (UDP)", str(int(_form["port"])), str(Proto.DEFAULT_PORT),
		func(t: String) -> void: _form["port"] = t.to_int() if t.is_valid_int() else Proto.DEFAULT_PORT, false, false)
	port_e.max_length = 5
	var step: HBoxContainer = NC.stepper(null, int(_form["max"]), 2, 16, func(v: int) -> void: _form["max"] = v)
	_row(g, "Max players", step, 44.0, false)
	_field(g, "Password", str(_form.get("password", "")), "Optional", func(t: String) -> void: _form["password"] = t, true)

	var vg: NC.Group = NC.section(_page, "Visibility", "wifi",
		"UPnP asks your router to forward the port automatically; if that fails, forward UDP %d yourself." % int(_form["port"]))
	NC.toggle(vg, "Visible on the local network (LAN)", bool(_form["lan"]), func(v: bool) -> void: _form["lan"] = v)
	NC.toggle(vg, "Open the port on my router (UPnP)", bool(_form.get("upnp", false)), func(v: bool) -> void: _form["upnp"] = v)
	var eg: NC.Group = NC.section(_page, "Security", "lock.fill",
		"Encrypts traffic with DTLS (a self-signed key made on first use; players pin it when they first join). Plain clients, such as the Apple app's current direct-connect, can't join an encrypted game.")
	NC.toggle(eg, "Encrypt connection", bool(_form.get("encrypt", false)), func(v: bool) -> void: _form["encrypt"] = v)

	NC.spacer(_page, 10)
	_section_title(_page, "Rules", "shield.lefthalf.filled")
	var cards := _hbox(_page, 10)
	cards.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_preset_card(cards, "safe", "shield.fill", T.GREEN, "Safe", "Sparring. PvP damage and death aren't real for visitors.")
	_preset_card(cards, "full", "bolt.fill", T.ORANGE, "Full stakes", "Your ship is your real ship: damage and death count.")
	_preset_card(cards, "custom", "slider.horizontal.3", T.TEAL, "Custom", "Choose exactly which rules apply.")
	if str(_form["preset"]) == "custom":
		var rg: NC.Group = NC.section(_page, "", "", "")
		for item in [["allow_pvp", "Allow PvP - players can attack each other"], ["pvp_damage_real", "Real PvP damage"],
				["friendly_fire", "Splash damage hits allies (friendly fire)"], ["death_real", "Permadeath - destroyed ships are really lost"],
				["allow_trade", "Allow trading between players"]]:
			var key: String = str(item[0])
			NC.toggle(rg, str(item[1]), bool(_form.get(key, false)), func(v: bool) -> void: _form[key] = v)

	NC.spacer(_page, 10)
	var ready_card: PanelContainer = NC.card(_page, 14, 14, true)
	var rh := _hbox(ready_card, 14)
	_icon_tile(rh, 44, T.GREEN, "network", 0.16)
	var rc := _vbox(rh, 2)
	rc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	rc.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_t(rc, "Ready to host", 16, "semibold")
	var addr: String = _first_local_address()
	_t(rc, "Friends on your network join with  %s  (port %d). Over the internet, forward UDP port %d and share your public IP." % [
		addr if addr != "" else _local_addresses(), int(_form["port"]), int(_form["port"])], 12, "regular", T.SECONDARY, true)
	if addr != "":
		_icon_btn(rh, "doc.on.doc", "Copy %s:%d" % [addr, int(_form["port"])], func() -> void:
			DisplayServer.clipboard_set("%s:%d" % [addr, int(_form["port"])]), "copy")
	var start: Button = _btn(rh, "Start hosting", _start_host, "primary", "play.fill", "start")
	start.custom_minimum_size = Vector2(150, 40)
	start.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if not _svc.has_bridge_api():
		_note(_page, "Note: this build's engine bridge has no multiplayer support yet, so a hosted game can chat but not share a star system.")
	var gh := _hbox(null, 8)
	_note(gh, "Running a server on a PC that's always on? Dedicated servers and public listing are covered in the hosting guide.")
	_btn(gh, "Hosting guide", func() -> void: OS.shell_open(Proto.HOSTING_URL), "bordered", "arrow.up.right.square", "guide")
	_page.add_child(gh)


func _start_host() -> void:
	var port: int = clampi(int(_form["port"]), 1, 65535)
	var opts: Dictionary = {"name": str(_form["name"]), "max": int(_form["max"]), "port": port, "password": str(_form.get("password", "")),
		"lan": bool(_form["lan"]), "upnp": bool(_form.get("upnp", false)), "encrypt": bool(_form.get("encrypt", false)), "rules": _rules_from_form(), "display_name": _my_name()}
	NetPrefs.save_host_form(_form)
	_svc.last_error = ""
	var err: int = _svc.host_game(opts)
	if err != OK:
		_svc.last_error = "Couldn't start hosting on UDP port %d (%s). Another game or server may be using it." % [port, error_string(err)]
		_svc.last_error_code = "error"
		_render_banner()
	else:
		tab = "Session"
		_render()


# --- Join ----------------------------------------------------------------------------------------------------------------

func _begin_join(host: String, port: int, pw: String) -> void:
	var nm: String = _my_name() if _name_edit != null else NetPrefs.display_name()
	_svc.last_error = ""
	_svc.last_error_code = ""
	var err: int = _svc.join_game(host, port, pw, nm)
	if err != OK:
		_svc.last_error = "Couldn't start connecting to %s (%s)." % [Proto.format_address(host, port), error_string(err)]
		_svc.last_error_code = "error"
	_render_banner()


# --- server cards --------------------------------------------------------------------------------------------------------

## One server as a kit card. `d`: name, host, port, kind ("lan" | "public" | "saved"), state ("online" | "checking" | "offline"),
## pw, dedicated, rules, region, ver, mismatch (version differs), players (-1 unknown), max, ping (-1 unknown),
## description, plugins [names], saved_pw, joinable (default true).
func _server_card(parent: Control, d: Dictionary) -> void:
	var host: String = str(d["host"])
	var port: int = int(d["port"])
	var state: String = str(d.get("state", "online"))
	var srcs: Array = d.get("sources", [])
	var kind: String = "saved" if srcs.has("Saved") else ("public" if srcs.has("Public") else "lan")
	var mismatch: bool = bool(d.get("mismatch", false))
	var tint: Color = T.SECONDARY
	var glyph: String = "wifi"
	if bool(d.get("dedicated", false)):
		glyph = "server.rack"
	elif kind == "public":
		glyph = "globe"
	elif kind == "saved":
		glyph = "star.fill"
	match state:
		"online": tint = T.TEAL if bool(d.get("dedicated", false)) else T.GREEN
		"offline": tint = T.RED
	if mismatch:
		tint = T.ORANGE
	var card: PanelContainer = NC.card(parent, 14, 14, true)
	var row := _hbox(card, 14)
	_icon_tile(row, 46, tint, glyph, 0.16)

	var col := _vbox(row, 4)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	# The name gets its own full-width line: inside the badge flow it was squeezed to its minimum width.
	var nl: Label = _t(col, str(d["name"]), 16, "semibold")
	nl.clip_text = true
	nl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var line := _flow(col, 8, 4)
	for src in (d.get("sources", []) as Array):
		_badge(line, str(src), SOURCE_TINT.get(str(src), T.SECONDARY))
	if bool(d.get("dedicated", false)):
		_badge(line, "Dedicated", T.TEAL, "server.rack")
	if state == "checking":
		_badge(line, "Checking...", T.SECONDARY)
	elif state == "offline":
		_badge(line, "Offline", T.RED)
	if bool(d.get("pw", false)):
		_badge(line, "Password", T.ORANGE, "lock.fill")
	if bool(d.get("dtls", false)):
		_badge(line, "Encrypted", T.TEAL, "lock.shield.fill")
	if str(d.get("region", "")) != "":
		_badge(line, str(d["region"]), T.SECONDARY, "globe")
	if str(d.get("rules", "")) != "":
		_badge(line, str(d["rules"]).capitalize(), T.INDIGO.lightened(0.35), "shield.fill")
	if mismatch:
		_badge(line, "Incompatible protocol", T.RED, "exclamationmark.triangle.fill")
	elif state == "online" and str(d.get("ver", "")) != "":
		if str(d.get("ver", "")) != Proto.game_version():
			_badge(line, "Different version (v%s)" % str(d.get("ver", "?")), T.SECONDARY, "info.circle")
		else:
			_badge(line, "Compatible", T.GREEN, "checkmark.circle.fill")
	var info := _flow(col, 14, 2)
	_t(info, Proto.format_address(host, port), 13, "regular", T.SECONDARY)
	if int(d.get("players", -1)) >= 0:
		var ph := _hbox(info, 5)
		_svg(ph, "person.2.fill", 12, T.SECONDARY)
		var mx: int = int(d.get("max", 0))
		_t(ph, "%d/%d players" % [int(d["players"]), mx] if mx > 0 else "%d players" % int(d["players"]), 13, "medium", T.WHITE)
	elif int(d.get("max", 0)) > 0:
		_t(info, "max %d" % int(d["max"]), 13, "regular", T.SECONDARY)
	if str(d.get("description", "")) != "":
		var dl: Label = _t(col, str(d["description"]), 12, "regular", T.SECONDARY, true)
		dl.max_lines_visible = 2
		dl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_plugin_requirements(col, line, d)

	var right := _hbox(row, 8)
	right.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if (state != "offline" and state != "checking") or int(d.get("ping", -1)) >= 0:
		_ping_pill(right, int(d.get("ping", -1)))
	var needs_pw: bool = bool(d.get("pw", false))
	var saved_pw: String = str(d.get("saved_pw", ""))
	var join_btn: Button = _btn(right, "Join", func() -> void:
		_join_meta = {"website": str(d.get("website", "")), "contact": str(d.get("contact", ""))}
		_join_row(host, port, needs_pw, saved_pw), "primary", "", "join:%s:%d" % [host, port])
	join_btn.custom_minimum_size.x = 68
	join_btn.disabled = mismatch or not bool(d.get("joinable", true))
	var is_saved: bool = NetPrefs.is_saved(host, port)
	var nm: String = str(d["name"])
	var star: Button = _icon_btn(right, "star.fill" if is_saved else "star", "Remove from Saved" if is_saved else "Save to favourites", func() -> void:
		if is_saved:
			NetPrefs.remove_saved(host, port)
		else:
			NetPrefs.save_server(nm, host, port)
			_svc.lan.query(host, port)
		_refresh_dynamic(), "star:%s:%d" % [host, port], T.AMBER if is_saved else T.WHITE)
	star.size_flags_vertical = Control.SIZE_SHRINK_CENTER


func _plugin_requirements(col: Control, line: Control, d: Dictionary) -> void:
	var local: Dictionary = NetPlugins.local_info(_nova)
	var plugs: Array = d.get("plugins", []) if d.get("plugins", []) is Array else []
	var dict_rows: Array = []
	for p in plugs:
		if p is Dictionary:
			dict_rows.append(p)
		else:
			dict_rows.append({"id": str(p), "name": str(p)})
	if dict_rows.is_empty():
		var sig: String = str(d.get("sig", ""))
		if sig != "" and str(local.get("sig", "")) != "" and str(d.get("state", "online")) == "online":
			if sig == str(local["sig"]):
				_badge(line, "Plug-ins match", T.GREEN, "checkmark.circle.fill")
			else:
				_badge(line, "Plug-ins differ", T.ORANGE, "puzzlepiece.extension.fill")
		return
	var cmp: Dictionary = NetPlugins.compare(dict_rows, str(d.get("tc", "")), local)
	if str(d.get("state", "online")) == "online" or true:
		if bool(cmp["ok"]):
			_badge(line, "Plug-ins match", T.GREEN, "checkmark.circle.fill")
		else:
			_badge(line, "Plug-ins differ", T.ORANGE, "puzzlepiece.extension.fill")
	var pf := _flow(col, 6, 4)
	_svg(pf, "puzzlepiece.extension.fill", 12, T.SECONDARY)
	_t(pf, "Requires:", 12, "regular", T.SECONDARY)
	for r in (cmp["rows"] as Array):
		var rr: Dictionary = r
		match str(rr["state"]):
			"ok": _badge(pf, str(rr["name"]), T.GREEN, "checkmark.circle.fill")
			"wrong": _badge(pf, "%s (other version)" % str(rr["name"]), T.ORANGE, "exclamationmark.triangle.fill")
			_: _badge(pf, "%s (missing)" % str(rr["name"]), T.RED, "xmark.circle.fill")
	if bool(cmp["tc_mismatch"]) and str(cmp["tc_server"]) != "":
		_badge(pf, "Total conversion: %s" % str(cmp["tc_server"]), T.ORANGE, "exclamationmark.triangle.fill")
	var extra: Array = cmp["extra"]
	if not extra.is_empty():
		var names: PackedStringArray = PackedStringArray()
		for x in extra:
			names.append(str((x as Dictionary)["name"]))
		_t(col, "You also have: %s (switched off for this game when you join)" % ", ".join(names), 12, "regular", T.SECONDARY, true)


func _join_row(host: String, port: int, needs_pw: bool, saved_pw: String) -> void:
	if _svc.is_active():
		return
	if needs_pw and saved_pw == "":
		Alert.show(self, {"title": "Password", "message": "%s needs a password." % Proto.format_address(host, port), "text": "", "placeholder": "Password",
			"buttons": [{"title": "Cancel", "role": "cancel"}, {"title": "Join", "cb": func(text: String) -> void: _begin_join(host, port, text)}]})
	else:
		_begin_join(host, port, saved_pw)


# --- LAN ---------------------------------------------------------------------------------------------------------------

# --- Public --------------------------------------------------------------------------------------------------------------

func _directory() -> Node:
	if _dir == null:
		_dir = (load("res://net/ServerDirectory.gd") as GDScript).new()
		add_child(_dir)
		_dir.updated.connect(_on_directory_updated)
	return _dir


func _on_directory_updated() -> void:
	if tab == "Browse" and is_inside_tree():
		_query_public(true)
		_refresh_dynamic()


func _pub_status_text() -> String:
	var d: Node = _directory()
	match str(d.status):
		"loading": return "Loading the server directory..."
		"error", "offline": return str(d.message)
	var age: String = ""
	if int(d.fetched_at) > 0:
		var mins: int = maxi(0, (int(Time.get_unix_time_from_system()) - int(d.fetched_at)) / 60)
		age = "  Updated %s." % ("just now" if mins < 1 else ("%d min ago" % mins if mins < 120 else "%d h ago" % (mins / 60)))
	return "%d listed.%s" % [d.entries.size(), age]


func _query_public(force: bool) -> void:
	var now: float = Time.get_ticks_msec() / 1000.0
	if not force and now - _pub_query_at < 8.0:
		return
	_pub_query_at = now
	var n: int = 0
	for item in _directory().entries:
		if n >= 60:
			break   # a query may resolve a hostname synchronously: keep a huge list from stalling the frame
		n += 1
		var e: Dictionary = item
		_svc.lan.query(str(e["host"]), int(e["port"]))


# --- Saved ---------------------------------------------------------------------------------------------------------------

func _query_saved(force: bool) -> void:
	var now: float = Time.get_ticks_msec() / 1000.0
	if not force and now - _last_query < 5.0:
		return
	_last_query = now
	for item in NetPrefs.saved():
		var e: Dictionary = item
		_svc.lan.query(str(e["host"]), int(e["port"]))


# --- Browse --------------------------------------------------------------------------------------------------------------

const SOURCE_TINT := {"Saved": Color(1.0, 0.78, 0.30), "LAN": Color(0.35, 0.85, 0.75), "Public": Color(0.55, 0.65, 1.0)}


func _page_browse() -> void:
	var d: Node = _directory()
	var h := _section_title(_page, "Servers", "magnifyingglass")
	NC.hspacer(h)
	_pub_status = _t(h, _pub_status_text(), 12, "regular", T.SECONDARY)
	_btn(h, "Refresh", func() -> void: _refresh_action(), "bordered", "arrow.clockwise", "refresh")
	# search + chips
	var fcard: PanelContainer = NC.card(_page, 12, 10, true)
	var fv := _vbox(fcard, 8)
	var se: LineEdit = NC.search_field(fv, "Search name, address or description", str(_br["search"]), func(t: String) -> void:
		_br["search"] = t
		_refresh_dynamic())
	se.set_meta("fkey", "browse:search")
	var fh := _flow(fv, 8, 8)
	fh.alignment = FlowContainer.ALIGNMENT_BEGIN
	for src in ["All", "Saved", "LAN", "Public"]:
		var sname: String = str(src)
		var c: Button = NC.chip(fh, sname, str(_br["source"]) == sname, func() -> void:
			_br["source"] = sname
			_render())
		c.set_meta("fkey", "src:" + sname)
	for item in [["compat", "Compatible only"], ["players", "Has players"], ["nopw", "No password"]]:
		var key: String = str(item[0])
		var c2: Button = NC.chip(fh, str(item[1]), bool(_br[key]), func() -> void:
			_br[key] = not bool(_br[key])
			_render())
		c2.set_meta("fkey", "chip:" + key)
	var regions: Array = [""] + Directory.REGIONS
	var labels: Array = ["Any region"]
	for r in Directory.REGIONS:
		labels.append(str(r))
	fh.add_child(NC.option_chip(labels, maxi(0, regions.find(str(_br["region"]))), func(i: int) -> void:
		_br["region"] = regions[i]
		_refresh_dynamic()))
	_svc.start_lan_browser()
	_make_dyn("main", 10)
	_note(_page, "Saved servers, games on your network and the community list are merged by address. Players, ping and plug-ins come from a live status query to each server's game port + 1 (53736 for the default port).", 12)
	NC.spacer(_page, 6)
	_dedicated_card(_page)
	d.refresh(false)
	_query_public(true)
	_query_saved(true)


## "Run your own": the standalone Dedicated Server for always-on hosting, and how to list it.
func _dedicated_card(parent: Control) -> void:
	var own: PanelContainer = NC.card(parent, 14, 14, true)
	var oh := _hbox(own, 14)
	_icon_tile(oh, 44, T.INDIGO.lightened(0.3), "server.rack", 0.16)
	var oc := _vbox(oh, 2)
	oc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	oc.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_t(oc, "Run a server that's always on", 16, "semibold")
	_t(oc, "The standalone NovaSwift Dedicated Server (a separate download, coming soon) runs without a window on any always-on PC. Until then the game itself can run headless with --server. The hosting guide covers both, port forwarding and listing your server here.", 12, "regular", T.SECONDARY, true)
	_btn(oh, "Hosting guide", func() -> void: OS.shell_open(Proto.HOSTING_URL), "bordered", "arrow.up.right.square", "guide")
	_btn(oh, "List a server", func() -> void: OS.shell_open(Directory.PR_URL), "bordered", "arrow.up.right.square", "howto")


func _saved_rows() -> Array:
	var out: Array = []
	for item in NetPrefs.saved():
		var e: Dictionary = item
		var host: String = str(e["host"])
		var port: int = int(e["port"])
		var pr: Dictionary = _svc.lan.pings.get("%s:%d" % [host, port], {})
		var info: Dictionary = pr.get("info", {}) if pr.get("info", {}) is Dictionary else {}
		var ok: bool = bool(pr.get("ok", false))
		out.append({"sources": ["Saved"], "name": str(e.get("name", host)), "host": host, "port": port,
			"state": "online" if ok else "checking", "pw": bool(info.get("pw", str(e.get("pw", "")) != "")),
			"dedicated": bool(info.get("dedicated", false)), "rules": str(info.get("rules", "")), "ver": str(info.get("ver", "")),
			"mismatch": int(info.get("proto", Proto.PROTO)) != Proto.PROTO, "players": int(info["players"]) if info.has("players") else -1,
			"max": int(info.get("max", 0)), "ping": int(pr.get("rtt_ms", -1)) if ok else -1, "saved_pw": str(e.get("pw", "")),
			"sig": str(info.get("sig", "")), "tc": str(info.get("tc", "")), "plugins": info.get("plugins", []), "dtls": bool(info.get("dtls", false))})
	return out


func _lan_rows() -> Array:
	var out: Array = []
	for item in _svc.lan.lan_list():
		var s: Dictionary = item
		out.append({"sources": ["LAN"], "name": str(s["name"]), "host": str(s["ip"]), "port": int(s["port"]), "state": "online",
			"pw": bool(s.get("pw", false)), "dedicated": bool(s.get("dedicated", false)), "rules": str(s.get("rules", "")), "ver": str(s.get("ver", "")),
			"mismatch": int(s.get("proto", Proto.PROTO)) != Proto.PROTO, "players": int(s["players"]) if s.has("players") else -1,
			"max": int(s.get("max", 0)), "ping": -1, "sig": str(s.get("sig", "")), "tc": str(s.get("tc", "")), "dtls": bool(s.get("dtls", false))})
	return out


func _public_rows() -> Array:
	var now: float = Time.get_ticks_msec() / 1000.0
	var checking: bool = now - _pub_query_at < 3.5
	var out: Array = []
	for item in _directory().entries:
		var e: Dictionary = item
		var key: String = "%s:%d" % [str(e["host"]), int(e["port"])]
		var live: Dictionary = _svc.lan.pings.get(key, {})
		if bool(live.get("ok", false)):
			_pub_last[key] = live
		elif _pub_last.has(key) and checking:
			live = _pub_last[key]
		var row: Dictionary = Directory.row_for(e, live, checking)
		var state: String = str(row["state"])
		out.append({"sources": ["Public"], "tc": str(row.get("tc", "")), "sig": str(row.get("sig", "")), "dtls": bool(row.get("dtls", false)),
			"contact": str(row.get("contact", "")), "website": str(row.get("website", "")), "name": str(row["name"]), "host": str(row["host"]),
			"port": int(row["port"]), "state": state, "pw": bool(row["pw"]), "dedicated": bool(row.get("dedicated", false)),
			"rules": str(row["rules"]), "region": str(row["region"]), "ver": str(row["ver"]),
			"mismatch": state == "online" and not bool(row["compatible"]),
			"players": int(row["players"]) if state == "online" else -1, "max": int(row["live_max"]) if state == "online" else int(row["max"]),
			"ping": int(row["ping"]), "description": str(row["description"]), "plugins": row["plugins"]})
	return out


static func _empty_val(v: Variant) -> bool:
	return v == null or (v is String and (v as String) == "") or (v is Array and (v as Array).is_empty()) or (v is int and (v as int) == -1)


## Fold row `r` into `m` (same host:port): union the sources, fill what `m` lacks, OR the flags, prefer a live state.
static func _merge_row(m: Dictionary, r: Dictionary) -> void:
	for src in (r["sources"] as Array):
		if not (m["sources"] as Array).has(src):
			(m["sources"] as Array).append(src)
	for k in r:
		if k == "sources":
			continue
		if k in ["pw", "dedicated", "mismatch", "dtls"]:
			m[k] = bool(m.get(k, false)) or bool(r[k])
		elif k == "state":
			if str(r[k]) == "online" or (str(r[k]) == "checking" and str(m.get(k, "")) == "offline"):
				m[k] = r[k]
		elif k == "name":
			continue   # the first row's name wins (Saved, then LAN, then the directory)
		elif not m.has(k) or _empty_val(m[k]):
			m[k] = r[k]


func _browse_rows() -> Array:
	var merged: Dictionary = {}
	var order: Array = []
	for rows in [_saved_rows(), _lan_rows(), _public_rows()]:
		for item in rows:
			var r: Dictionary = item
			var key: String = "%s:%d" % [str(r["host"]).to_lower(), int(r["port"])]
			if merged.has(key):
				_merge_row(merged[key], r)
			else:
				merged[key] = r
				order.append(key)
	var out: Array = []
	for k in order:
		out.append(merged[k])
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var sa: bool = (a["sources"] as Array).has("Saved")
		var sb: bool = (b["sources"] as Array).has("Saved")
		if sa != sb:
			return sa
		var oa: int = 0 if str(a.get("state", "")) == "online" else (1 if str(a.get("state", "")) == "checking" else 2)
		var ob: int = 0 if str(b.get("state", "")) == "online" else (1 if str(b.get("state", "")) == "checking" else 2)
		if oa != ob:
			return oa < ob
		var pa: int = int(a.get("ping", -1))
		var pb: int = int(b.get("ping", -1))
		if pa >= 0 and pb >= 0 and pa != pb:
			return pa < pb
		return str(a["name"]).naturalnocasecmp_to(str(b["name"])) < 0)
	return out


func _browse_pass(r: Dictionary) -> bool:
	var src: String = str(_br["source"])
	if src != "All" and not (r["sources"] as Array).has(src):
		return false
	if bool(_br["compat"]) and (bool(r.get("mismatch", false)) or str(r.get("state", "")) == "offline"):
		return false
	if bool(_br["players"]) and int(r.get("players", -1)) < 1:
		return false
	if bool(_br["nopw"]) and bool(r.get("pw", false)):
		return false
	if str(_br["region"]) != "" and str(r.get("region", "")) != str(_br["region"]):
		return false
	var q: String = str(_br["search"]).strip_edges().to_lower()
	if q != "":
		var hay: String = ("%s %s:%d %s" % [str(r["name"]), str(r["host"]), int(r["port"]), str(r.get("description", ""))]).to_lower()
		if not hay.contains(q):
			return false
	return true


func _dyn_browse(into: Control) -> void:
	var all_rows: Array = _browse_rows()
	var rows: Array = all_rows.filter(_browse_pass)
	if rows.is_empty():
		if all_rows.is_empty():
			var loading: bool = str(_directory().status) == "loading"
			_empty(into, "globe", T.AMBER, "Loading the server list" if loading else "No servers found",
				"Fetching the community list..." if loading else "Nothing saved, nothing on your network and nothing listed yet. Connect to a friend's address, or host a game yourself.",
				[] if loading else [{"text": "Quick Connect", "kind": "primary", "glyph": "arrow.right.circle", "cb": func() -> void: _quick_connect()},
					{"text": "Host a game", "kind": "bordered", "glyph": "plus.circle", "cb": func() -> void: _set_tab("Host")}])
		else:
			_empty(into, "magnifyingglass", T.AMBER, "No servers match", "Loosen the search or a filter to see more.",
				[{"text": "Clear filters", "kind": "primary", "glyph": "xmark", "cb": func() -> void:
					_br = {"search": "", "source": "All", "compat": false, "players": false, "nopw": false, "region": ""}
					_render()},
				{"text": "Quick Connect", "kind": "bordered", "glyph": "arrow.right.circle", "cb": func() -> void: _quick_connect()}])
		return
	for r in rows:
		_server_card(into, r)


# --- Quick Connect -------------------------------------------------------------------------------------------------------

## A small kit dialog: address (host or host:port), optional password, "Save this server" (+ a name), recent addresses as chips.
func _quick_connect() -> void:
	if _svc == null or _svc.is_active() or _has_alert():
		return
	var st: Dictionary = {"addr": "", "pw": "", "save": false, "name": ""}
	var layer := CanvasLayer.new()
	layer.layer = 200
	layer.name = "NovaAlert"   # the hub's alert test (B / LB / RB stand down) treats it like any alert
	add_child(layer)
	var Chrome: GDScript = load("res://ui/novaswift/NovaChrome.gd") as GDScript
	var go: Callable = func() -> void:
		var a: Dictionary = Proto.parse_address(str(st["addr"]))
		if not bool(a["ok"]):
			_svc.last_error = str(a["error"])
			_svc.last_error_code = "bad_request"
			_render_banner()
			return
		if bool(st["save"]):
			NetPrefs.save_server(str(st["name"]) if str(st["name"]) != "" else Proto.format_address(str(a["host"]), int(a["port"])), str(a["host"]), int(a["port"]), str(st["pw"]))
		layer.queue_free()
		_join_meta = {}
		_begin_join(str(a["host"]), int(a["port"]), str(st["pw"]))
	var dlg: Dictionary = Chrome.dialog(layer, {"title": "Quick Connect", "width": 460.0, "buttons": [
		{"text": "Cancel", "cancel": true, "cb": func() -> void: layer.queue_free()},
		{"text": "Connect", "default": true, "cb": go}]})
	var body: VBoxContainer = dlg.body
	var ae: LineEdit = NC.text_field("192.168.1.20 or play.example.com:53735", "")
	ae.text_changed.connect(func(t: String) -> void: st["addr"] = t)
	ae.text_submitted.connect(func(_t2: String) -> void: go.call())
	NC.label(body, "Address", "caption", "semibold", T.SECONDARY)
	body.add_child(ae)
	var pe: LineEdit = NC.text_field("Password (if the server has one)", "")
	pe.secret = true
	pe.text_changed.connect(func(t: String) -> void: st["pw"] = t)
	body.add_child(pe)
	var rec: Array = NetPrefs.recent()
	if not rec.is_empty():
		NC.label(body, "Recent", "caption", "semibold", T.SECONDARY)
		var fl := _flow(body, 6, 6)
		for item in rec.slice(0, 5):
			var h: String = str((item as Dictionary).get("host", ""))
			var pt: int = int((item as Dictionary).get("port", Proto.DEFAULT_PORT))
			NC.chip(fl, Proto.format_address(h, pt), false, func() -> void:
				ae.text = Proto.format_address(h, pt)
				st["addr"] = ae.text)
	var name_edit: LineEdit = NC.text_field("Name (optional)", "")
	name_edit.visible = false
	name_edit.text_changed.connect(func(t: String) -> void: st["name"] = t)
	NC.toggle(body, "Save this server", false, func(v: bool) -> void:
		st["save"] = v
		name_edit.visible = v)
	body.add_child(name_edit)
	ae.grab_focus.call_deferred()


# --- Session ---------------------------------------------------------------------------------------------------------------

func _page_session() -> void:
	var hosting: bool = _svc.is_hosting()
	var card: PanelContainer = NC.card(_page, 16, 16, true)
	var ch := _hbox(card, 14)
	_icon_tile(ch, 52, T.GREEN if _svc.is_connected_to_session() else T.AMBER, "person.2.fill", 0.16)
	var cc := _vbox(ch, 5)
	cc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cc.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_t(cc, _svc.status_text(), 17, "semibold", T.WHITE, true)
	var chips := _flow(cc, 8, 4)
	var info: Dictionary = _svc.net_info
	if info.has("rules") and info["rules"] is Dictionary:
		var r: Dictionary = info["rules"]
		var pn: String = Proto.preset_of({"pvp_damage_real": r.get("pvp_damage_real", r.get("pvpDamageReal", false)),
			"death_real": r.get("death_real", r.get("deathReal", false)), "friendly_fire": r.get("friendly_fire", r.get("friendlyFire", false)),
			"allow_pvp": r.get("allow_pvp", r.get("allowPvP", true)), "allow_trade": r.get("allow_trade", r.get("allowTrade", true)),
			"carry_encounter": r.get("carry_encounter", r.get("carryEncounter", false))})
		_badge(chips, "%s rules" % pn.capitalize(), T.INDIGO.lightened(0.35), "shield.fill")
	if _svc.transport != null and _svc.transport.mode == "client" and _svc.transport.rtt_ms >= 0:
		_ping_pill(chips, int(_svc.transport.rtt_ms))
	var leave: Button = _btn(ch, "Stop hosting" if hosting else "Leave game", func() -> void:
		_svc.leave()
		tab = "Browse"
		_render(), "destructive", "door.exit", "leave")
	leave.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	if hosting:
		var presets: Array = ["safe", "full"]
		var cur: int = presets.find(Proto.preset_of(_rules_dict()))
		NC.spacer(_page, 6)
		_section_title(_page, "Rules", "shield.lefthalf.filled")
		var seg: HBoxContainer = NC.segmented(null, ["Safe rules", "Full stakes"], cur, func(i: int) -> void: _svc.set_rules(Proto.rules_for_preset(presets[i])))
		seg.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		_page.add_child(seg)

	NC.spacer(_page, 6)
	_section_title(_page, "Players", "person.2.fill")
	_make_dyn("players", 6)

	NC.spacer(_page, 6)
	_section_title(_page, "Chat", "bubble.left.fill")
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", T.box(T.GROUP_BG, 14, Color(1, 1, 1, 0.07), 1, Vector2(0, 0)))
	_page.add_child(panel)
	var pv := _vbox(panel, 0)
	_chat_scroll = ScrollContainer.new()
	_chat_scroll.custom_minimum_size = Vector2(0, 240)
	_chat_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	pv.add_child(_chat_scroll)
	var cm := MarginContainer.new()
	cm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for s in ["left", "right"]:
		cm.add_theme_constant_override("margin_" + s, 14)
	cm.add_theme_constant_override("margin_top", 10)
	cm.add_theme_constant_override("margin_bottom", 10)
	_chat_scroll.add_child(cm)
	var chat_list := VBoxContainer.new()
	chat_list.add_theme_constant_override("separation", 6)
	chat_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cm.add_child(chat_list)
	_dyns["chat"] = chat_list
	var sep := ColorRect.new()
	sep.color = T.GROUP_LINE
	sep.custom_minimum_size = Vector2(0, 1)
	pv.add_child(sep)
	var im := MarginContainer.new()
	for s in ["left", "right"]:
		im.add_theme_constant_override("margin_" + s, 10)
	im.add_theme_constant_override("margin_top", 8)
	im.add_theme_constant_override("margin_bottom", 8)
	pv.add_child(im)
	var ih := _hbox(im, 8)
	_chat_edit = NC.text_field("Say something", "")
	_chat_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_chat_edit.max_length = 200
	_chat_edit.text_submitted.connect(func(_t2: String) -> void: _send_chat())
	ih.add_child(_chat_edit)
	var send: Button = _btn(ih, "Send", _send_chat, "primary", "paperplane.fill", "send")
	send.custom_minimum_size.y = 36
	_note(_page, "In flight press %s to chat. Gamepad: Menu > Multiplayer." % ("/" if _svc.chat_key() == KEY_SLASH else "T"), 12)


func _rules_dict() -> Dictionary:
	if _svc.transport != null and _svc.transport.rules_json != "":
		var v: Variant = JSON.parse_string(_svc.transport.rules_json)
		if v is Dictionary:
			return v
	return Proto.rules_for_preset("safe")


func _send_chat() -> void:
	if _chat_edit == null:
		return
	var t: String = _chat_edit.text.strip_edges()
	_chat_edit.text = ""
	if t != "":
		_svc.send_chat(t)
		_refresh_dynamic()


## A coloured circle with the player's initial.
func _avatar(parent: Control, nm: String, size: int, tint: Color) -> Control:
	var p := PanelContainer.new()
	p.custom_minimum_size = Vector2(size, size)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override("panel", T.box(Color(tint.r, tint.g, tint.b, 0.22), size / 2, Color(tint.r, tint.g, tint.b, 0.5), 1))
	var c := CenterContainer.new()
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(c)
	_t(c, nm.substr(0, 1).to_upper() if nm != "" else "?", int(size * 0.46), "bold", tint)
	parent.add_child(p)
	return p


static func _name_tint(nm: String) -> Color:
	var pal: Array = [T.AMBER, T.TEAL, T.GREEN, Color(0.62, 0.55, 1.0), Color(1.0, 0.5, 0.6), T.ORANGE]
	return pal[absi(nm.hash()) % pal.size()]


func _dyn_players(into: Control) -> void:
	var rows: Array = _svc.players if not _svc.players.is_empty() else (_svc.transport.roster() if _svc.transport != null else [])
	if rows.is_empty():
		_t(into, "No one else is here yet.", 13, "regular", T.SECONDARY)
		return
	for item in rows:
		var p: Dictionary = item
		var id: int = int(p.get("id", -1))
		var mine: bool = id == _svc.local_id()
		var nm: String = str(p.get("name", "?"))
		var card: PanelContainer = NC.card(into, 12, 10, true)
		var h := _hbox(card, 12)
		_avatar(h, nm, 34, T.TEAL if mine else _name_tint(nm))
		var col := _vbox(h, 3)
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var line := _flow(col, 7, 3)
		_t(line, nm, 15, "semibold")
		if mine:
			_t(line, "(you)", 13, "regular", T.SECONDARY)
		if id == 1:
			_badge(line, "Host", T.AMBER, "crown.fill")
		if bool(p.get("is_authority", false)):
			_badge(line, "Authority", T.GREEN, "bolt.fill")
		if bool(p.get("in_my_system", false)) and not mine:
			_badge(line, "Your system", T.TEAL, "location.fill")
		if p.has("system_id") and int(p["system_id"]) >= 0:
			_t(col, "System %d" % int(p["system_id"]), 12, "regular", T.SECONDARY)
		if int(p.get("rtt", -1)) >= 0 and not mine:
			_ping_pill(h, int(p["rtt"]))
		if not mine and bool(((_svc.net_info.get("rules", {}) as Dictionary) if _svc.net_info.get("rules", {}) is Dictionary else {}).get("allow_trade", true)) \
				and not (id == 1 and _svc.transport != null and not _svc.transport.has_local_player):
			_btn(h, "Trade", func() -> void:
				var why: String = _svc.trade_invite(id)
				if why != "":
					_svc.last_error = why
					_svc.last_error_code = "bad_request"
					_render_banner(), "bordered", "arrow.left.arrow.right", "trade:%d" % id)
		if not mine:
			var muted: bool = _svc.is_player_blocked(id)
			_btn(h, "Unblock" if muted else "Block", func() -> void:
				if muted:
					_svc.unblock_name(nm)
				else:
					_svc.block_player(id)
				_refresh_dynamic(), "bordered", "", "block:%d" % id)
			if not _svc.is_hosting():
				_btn(h, "Report", func() -> void:
					_svc.report_player(id, "abuse"), "bordered", "", "report:%d" % id)
		if _svc.is_hosting() and not mine and id != 1:
			_btn(h, "Kick", func() -> void: _svc.kick(id, false), "bordered", "", "kick:%d" % id)
			_btn(h, "Ban", func() -> void: _svc.kick(id, true), "destructive", "", "ban:%d" % id)


static func _clock(t: float) -> String:
	if t <= 0.0:
		return ""
	var d: Dictionary = Time.get_datetime_dict_from_unix_time(int(t) + int(Time.get_time_zone_from_system().get("bias", 0)) * 60)
	return "%02d:%02d" % [int(d["hour"]), int(d["minute"])]


func _dyn_chat(into: Control) -> void:
	var entries: Array = _svc.chat_log
	if entries.is_empty():
		var l: Label = _t(into, "No messages yet. Say hello.", 13, "regular", T.SECONDARY)
		l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		return
	var me: String = ""
	for item in _svc.players:
		if int((item as Dictionary).get("id", -1)) == _svc.local_id():
			me = str((item as Dictionary).get("name", ""))
	for i in range(maxi(0, entries.size() - 40), entries.size()):
		var c: Dictionary = entries[i]
		var stamp: String = _clock(float(c.get("t", 0.0)))
		if bool(c["system"]):
			var sh := _hbox(into, 8)
			_svg(sh, "info.circle", 12, T.SECONDARY)
			_t(sh, str(c["text"]), 13, "regular", T.SECONDARY, true)
			if stamp != "":
				_t(sh, stamp, 11, "regular", T.TERTIARY)
			continue
		var sender: String = str(c["name"])
		var col: Color = T.TEAL if (me != "" and sender == me) else T.AMBER
		var v := _vbox(into, 1)
		var top := _hbox(v, 8)
		_t(top, sender, 12, "bold", col)
		if stamp != "":
			_t(top, stamp, 11, "regular", T.TERTIARY)
		_t(v, str(c["text"]), 14, "regular", T.WHITE, true)


# --- live (rebuilt-when-changed) lists ------------------------------------------------------------------------------

func _make_dyn(dyn_name: String, sep: int) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", sep)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page.add_child(v)
	_dyns[dyn_name] = v
	return v


## A cheap fingerprint of a built (off-tree) subtree: its texts, disabled flags and tooltips.
static func _signature(n: Node, out: PackedStringArray) -> void:
	if n is Label:
		out.append((n as Label).text)
	elif n is Button:
		out.append("%s|%s|%s" % [(n as Button).text, str((n as Button).disabled), (n as Control).tooltip_text])
	elif n is Control and (n as Control).tooltip_text != "":
		out.append((n as Control).tooltip_text)
	if n is TextureRect:
		out.append("t%d" % ((n as TextureRect).texture.get_instance_id() if (n as TextureRect).texture != null else 0))
	for c in n.get_children():
		_signature(c, out)


func _refresh_dynamic() -> void:
	for k in _dyns.keys():
		var dyn: VBoxContainer = _dyns[k] as VBoxContainer
		if dyn == null or not is_instance_valid(dyn):
			continue
		var fresh := VBoxContainer.new()
		fresh.add_theme_constant_override("separation", int(dyn.get_theme_constant("separation")))
		match str(k):
			"main":
				match tab:
					"Browse": _dyn_browse(fresh)
			"players": _dyn_players(fresh)
			"chat": _dyn_chat(fresh)
		var sig := PackedStringArray()
		_signature(fresh, sig)
		var sig_s: String = "\n".join(sig)
		if _dyn_sigs.get(k, "") == sig_s and dyn.get_child_count() > 0:
			fresh.free()
			continue
		_dyn_sigs[k] = sig_s
		var fo: Control = get_viewport().gui_get_focus_owner()
		var keep: String = _focus_key(fo) if (fo != null and dyn.is_ancestor_of(fo)) else ""
		_clear(dyn)
		for c in fresh.get_children():
			fresh.remove_child(c)
			dyn.add_child(c)
		fresh.free()
		if keep != "":
			var target: Control = _find_focus(dyn, keep)
			if target != null:
				target.grab_focus()
		if str(k) == "chat" and _chat_scroll != null:
			var sc: ScrollContainer = _chat_scroll
			(func() -> void:
				if is_instance_valid(sc):
					sc.scroll_vertical = int(sc.get_v_scroll_bar().max_value)).call_deferred()
