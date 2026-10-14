# NOVA Swift -- in-game multiplayer overlay: chat feed, chat entry, player list, toasts.
# Drawn with the NovaSwift UI kit (translucent rounded panels, kit fonts, coloured senders, faded timestamps), the
# Godot counterpart of the Apple ChatOverlayView.
#
# Owned by the NetService autoload (created when a session starts, freed when it ends). Layer 90: above
# flight and the HUD, below the pause menu (60 is the pause menu, but its scrim must still dim the feed, so
# the feed is mouse-transparent) and below alerts (200).
#
#   * chat feed  - the last 6 lines as small translucent pills, bottom-left above the status line; lines fade 10 s
#                  after arriving; while the entry is open the last 12 stay visible
#   * chat entry - T (modern key layout: /) opens it, Enter sends, Esc / pad B closes; gamepad: Menu > Multiplayer > Chat
#   * player list- opens beside the chat entry: avatar, name, host / authority badges, ping pill, system
#   * toasts     - joined / left / kicked / rules changed, top centre, 4 s, tinted pill with a glyph
#   * trading    - the Trade button on a player row (chat open) starts a trade; the window itself is TradeDialog.gd
#
# Loaded with preload() (no class_name), like Controls.gd.
extends CanvasLayer

const T = preload("res://ui/novaswift/NovaTheme.gd")
const NC = preload("res://ui/novaswift/NovaControls.gd")
const Alert = preload("res://ui/novaswift/NovaAlert.gd")
const Hub = preload("res://screens/multiplayer/MultiplayerHub.gd")

signal chat_submitted(text: String)
signal trade_requested(peer_id: int)
signal chat_opened
signal chat_closed

const FEED_LINES := 6
const OPEN_LINES := 12
const KEEP_LINES := 30
const LINE_LIFE := 10.0
const TOAST_LIFE := 4.0
const PANEL_BG := Color(0.05, 0.05, 0.07, 0.78)
const PANEL_EDGE := Color(1, 1, 1, 0.12)
const INK := Color(0.06, 0.05, 0.03)

var chat_open: bool = false
var _scale: float = 1.0
var _root: Control
var _feed: VBoxContainer
var _entry_box: PanelContainer
var _entry: LineEdit
var _online: Label
var _toasts: VBoxContainer
var _players_card: PanelContainer
var _players_box: VBoxContainer
var _lines: Array = []    # {node, age}
var _toast_nodes: Array = []   # {node, age}
var _unread: int = 0
var _local_name: String = ""


func _init() -> void:
	layer = 90
	name = "NetOverlay"


func _ready() -> void:
	Hub._ensure_glyphs()
	_scale = clampf(DisplayServer.screen_get_scale(), 1.0, 3.0)
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = T.theme()
	add_child(_root)

	var left := VBoxContainer.new()
	left.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	left.grow_vertical = Control.GROW_DIRECTION_BEGIN
	left.offset_left = 16
	left.offset_bottom = -44
	left.offset_right = 440
	left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left.add_theme_constant_override("separation", 6)
	_root.add_child(left)
	_feed = VBoxContainer.new()
	_feed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_feed.add_theme_constant_override("separation", 4)
	left.add_child(_feed)

	# Chat entry: header (glyph, title, online count, close) + field + send.
	_entry_box = PanelContainer.new()
	_entry_box.add_theme_stylebox_override("panel", T.box(Color(0.05, 0.05, 0.07, 0.92), 14, PANEL_EDGE, 1, Vector2(12, 10)))
	_entry_box.visible = false
	left.add_child(_entry_box)
	var ev := VBoxContainer.new()
	ev.add_theme_constant_override("separation", 8)
	_entry_box.add_child(ev)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	ev.add_child(head)
	_glyph(head, "bubble.left.fill", 15, T.AMBER)
	_text(head, "Session Chat", 14, "semibold", T.WHITE)
	_online = _text(head, "", 12, "regular", T.SECONDARY)
	NC.hspacer(head)
	var close_b: Button = NC.icon_button("xmark", close_chat, T.SECONDARY, 26, 12)
	close_b.tooltip_text = "Close chat"
	head.add_child(close_b)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	ev.add_child(row)
	_entry = NC.text_field("Message...", "")
	_entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_entry.max_length = 240
	_entry.text_submitted.connect(_on_submit)
	_entry.gui_input.connect(_on_entry_input)
	row.add_child(_entry)
	var send: Button = NC.button("Send", "primary", func() -> void: _on_submit(_entry.text))
	send.icon = T.icon("paperplane.fill", int(ceil(15 * _scale)), INK)
	send.expand_icon = false
	send.add_theme_constant_override("icon_max_width", 15)
	send.custom_minimum_size.y = 36
	row.add_child(send)
	_text(ev, "Enter sends  -  Esc / B closes", 11, "regular", T.TERTIARY)

	_toasts = VBoxContainer.new()
	_toasts.set_anchors_preset(Control.PRESET_CENTER_TOP)
	_toasts.grow_horizontal = Control.GROW_DIRECTION_BOTH
	_toasts.offset_top = 14
	_toasts.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toasts.add_theme_constant_override("separation", 6)
	_root.add_child(_toasts)

	_players_card = PanelContainer.new()
	_players_card.set_anchors_preset(Control.PRESET_TOP_LEFT)
	_players_card.offset_left = 16
	_players_card.offset_top = 16
	_players_card.add_theme_stylebox_override("panel", T.box(Color(0.05, 0.05, 0.07, 0.86), 14, PANEL_EDGE, 1, Vector2(12, 10)))
	_players_card.visible = false
	_players_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_players_card)
	_players_box = VBoxContainer.new()
	_players_box.add_theme_constant_override("separation", 6)
	_players_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_players_card.add_child(_players_box)


func _text(parent: Control, text: String, size: int, weight: String, color: Color, wrap: bool = false) -> Label:
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


func _glyph(parent: Control, glyph: String, px: int, color: Color) -> TextureRect:
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


func _process(delta: float) -> void:
	var n: int = _lines.size()
	for i in n:
		var l: Dictionary = _lines[i]
		l["age"] = float(l["age"]) + delta
		var node: Control = l["node"]
		var from_end: int = n - 1 - i
		if chat_open:
			node.visible = from_end < OPEN_LINES
			node.modulate.a = 1.0
		else:
			var a: float = clampf((LINE_LIFE - float(l["age"])) / 1.5, 0.0, 1.0)
			node.visible = from_end < FEED_LINES and a > 0.0
			node.modulate.a = a
	for t in _toast_nodes.duplicate():
		t["age"] = float(t["age"]) + delta
		var tn: Control = t["node"]
		if float(t["age"]) > TOAST_LIFE:
			tn.queue_free()
			_toast_nodes.erase(t)
		elif float(t["age"]) > TOAST_LIFE - 0.6:
			tn.modulate.a = (TOAST_LIFE - float(t["age"])) / 0.6


static func _stamp() -> String:
	var d: Dictionary = Time.get_time_dict_from_system()
	return "%02d:%02d" % [int(d["hour"]), int(d["minute"])]


func add_chat(from_name: String, text: String, system: bool = false) -> void:
	var pill := PanelContainer.new()
	pill.add_theme_stylebox_override("panel", T.box(PANEL_BG, 10, Color(1, 1, 1, 0.08), 1, Vector2(10, 5)))
	pill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pill.custom_minimum_size = Vector2(0, 0)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pill.add_child(h)
	if system:
		_glyph(h, "info.circle", 13, T.SECONDARY)
		_text(h, text, 13, "regular", T.SECONDARY, true)
	else:
		var mine: bool = _local_name != "" and from_name == _local_name
		var who: Label = _text(h, from_name, 13, "bold", T.TEAL if mine else T.AMBER)
		who.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		_text(h, text, 14, "regular", T.WHITE, true)
	var ts: Label = _text(h, _stamp(), 11, "regular", T.TERTIARY)
	ts.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	_feed.add_child(pill)
	_lines.append({"node": pill, "age": 0.0})
	while _lines.size() > KEEP_LINES:
		var old: Dictionary = _lines.pop_front()
		(old["node"] as Control).queue_free()
	if not chat_open and not system:
		_unread += 1


func toast(text: String, kind: String = "info") -> void:
	var col: Color = T.AMBER if kind == "info" else (T.RED if kind == "error" else T.GREEN)
	var glyph: String = "info.circle.fill" if kind == "info" else ("exclamationmark.triangle.fill" if kind == "error" else "checkmark.circle.fill")
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", T.box(Color(0.06, 0.06, 0.08, 0.94), 22, Color(col.r, col.g, col.b, 0.55), 1, Vector2(14, 8)))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_child(h)
	_glyph(h, glyph, 16, col)
	_text(h, text, 14, "medium", T.WHITE)
	_toasts.add_child(p)
	_toast_nodes.append({"node": p, "age": 0.0})
	while _toast_nodes.size() > 4:
		var o: Dictionary = _toast_nodes.pop_front()
		(o["node"] as Control).queue_free()


func open_chat() -> void:
	if chat_open:
		return
	chat_open = true
	_unread = 0
	_entry_box.visible = true
	_entry.text = ""
	_entry.grab_focus.call_deferred()
	_players_card.visible = true
	chat_opened.emit()


func close_chat() -> void:
	if not chat_open:
		return
	chat_open = false
	_entry.release_focus()
	_entry_box.visible = false
	_players_card.visible = false
	chat_closed.emit()


func unread() -> int:
	return _unread


func _on_submit(text: String) -> void:
	var t: String = text.strip_edges()
	_entry.text = ""
	if t != "":
		chat_submitted.emit(t)
	close_chat()


func _on_entry_input(e: InputEvent) -> void:
	if e is InputEventKey and e.pressed and e.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		close_chat()


## Pad B (ui_cancel) closes the entry too; a key Esc is already handled by the field itself.
func _unhandled_input(e: InputEvent) -> void:
	if chat_open and e.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		close_chat()


static func _tint(nm: String) -> Color:
	var pal: Array = [T.AMBER, T.TEAL, T.GREEN, Color(0.62, 0.55, 1.0), Color(1.0, 0.5, 0.6), T.ORANGE]
	return pal[absi(nm.hash()) % pal.size()]


## Rows from net_state / the transport roster: [{id, name, system_id?, ship?, is_authority?, rtt?, in_my_system?}].
func set_players(players: Array, local_id: int) -> void:
	for c in _players_box.get_children():
		_players_box.remove_child(c)
		c.queue_free()
	_online.text = "%d online" % players.size()
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_players_box.add_child(head)
	_glyph(head, "person.2.fill", 14, T.AMBER)
	_text(head, "Players", 13, "semibold", T.AMBER)
	_text(head, "%d" % players.size(), 12, "regular", T.SECONDARY)
	for item in players:
		var p: Dictionary = item
		var id: int = int(p.get("id", -1))
		var nm: String = str(p.get("name", "?"))
		var mine: bool = id == local_id
		if mine:
			_local_name = nm
		var near: bool = bool(p.get("in_my_system", false)) or mine
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 9)
		h.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var tint: Color = T.TEAL if mine else _tint(nm)
		var av := PanelContainer.new()
		av.custom_minimum_size = Vector2(24, 24)
		av.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		av.mouse_filter = Control.MOUSE_FILTER_IGNORE
		av.add_theme_stylebox_override("panel", T.box(Color(tint.r, tint.g, tint.b, 0.22), 12, Color(tint.r, tint.g, tint.b, 0.5), 1))
		var cc := CenterContainer.new()
		cc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		av.add_child(cc)
		_text(cc, nm.substr(0, 1).to_upper() if nm != "" else "?", 12, "bold", tint)
		h.add_child(av)
		var lbl: Label = _text(h, nm + ("  (you)" if mine else ""), 14, "medium", T.WHITE if near else T.SECONDARY)
		lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		if id == 1:
			_glyph(h, "crown.fill", 12, T.AMBER).tooltip_text = "Host"
		if bool(p.get("is_authority", false)):
			_glyph(h, "bolt.fill", 12, T.GREEN).tooltip_text = "Simulating this system"
		NC.hspacer(h)
		if p.has("system_id") and int(p["system_id"]) >= 0:
			_text(h, "system %d" % int(p["system_id"]), 11, "regular", T.SECONDARY)
		if p.has("rtt") and int(p["rtt"]) >= 0 and not mine:
			var ms: int = int(p["rtt"])
			var pc: Color = T.GREEN if ms < 80 else (T.ORANGE if ms < 160 else T.RED)
			_text(h, "%d ms" % ms, 11, "semibold", pc)
		if not mine:
			var tb: Button = NC.button("Trade", "bordered", func() -> void: trade_requested.emit(id), "arrow.left.arrow.right")
			tb.custom_minimum_size.y = 26
			tb.focus_mode = Control.FOCUS_NONE
			h.add_child(tb)
		h.custom_minimum_size.x = 280
		_players_box.add_child(h)
