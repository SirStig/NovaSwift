# NOVA Swift -- in-game multiplayer overlay: chat feed, chat entry, player list, toasts, trade-offer stub.
#
# Owned by the NetService autoload (created when a session starts, freed when it ends). Layer 90: above
# flight and the HUD, below the pause menu (60 is the pause menu, but its scrim must still dim the feed, so
# the feed is mouse-transparent) and below alerts (200).
#
#   * chat feed  - the last 6 lines, bottom-left above the status line; lines fade 10 s after arriving;
#                  everything stays visible while the entry is open
#   * chat entry - T (modern key layout: /) opens it, Enter sends, Esc closes; gamepad: Menu > Multiplayer > Chat
#   * player list- opens beside the chat entry: name, ping, system, "authority" star
#   * toasts     - joined / left / kicked / rules changed, top centre, 4 s
#   * trade stub - the bridge surfaces trade invites as events but has no trade send API yet (invites are
#                  auto-declined), so the dialog only tells the player who asked and that trading is not
#                  available in this build
#
# Loaded with preload() (no class_name), like Controls.gd.
extends CanvasLayer

const T = preload("res://ui/novaswift/NovaTheme.gd")
const NC = preload("res://ui/novaswift/NovaControls.gd")
const Alert = preload("res://ui/novaswift/NovaAlert.gd")

signal chat_submitted(text: String)
signal chat_opened
signal chat_closed

const FEED_LINES := 6
const LINE_LIFE := 10.0
const TOAST_LIFE := 4.0

var chat_open: bool = false
var _root: Control
var _feed: VBoxContainer
var _entry_box: PanelContainer
var _entry: LineEdit
var _toasts: VBoxContainer
var _players_card: PanelContainer
var _players_box: VBoxContainer
var _lines: Array = []    # {label, age}
var _toast_nodes: Array = []   # {node, age}
var _unread: int = 0


func _init() -> void:
	layer = 90
	name = "NetOverlay"


func _ready() -> void:
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
	left.offset_right = 520
	left.mouse_filter = Control.MOUSE_FILTER_IGNORE
	left.add_theme_constant_override("separation", 4)
	_root.add_child(left)
	_feed = VBoxContainer.new()
	_feed.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_feed.add_theme_constant_override("separation", 2)
	left.add_child(_feed)

	_entry_box = PanelContainer.new()
	_entry_box.add_theme_stylebox_override("panel", T.box(Color(0.05, 0.05, 0.05, 0.92), 8, Color(1, 1, 1, 0.12), 1, Vector2(8, 6)))
	_entry_box.visible = false
	left.add_child(_entry_box)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	_entry_box.add_child(row)
	NC.label(row, "Chat", "caption", "semibold", T.AMBER)
	_entry = NC.text_field("Say something (Enter sends, Esc closes)", "")
	_entry.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_entry.max_length = 240
	_entry.text_submitted.connect(_on_submit)
	_entry.gui_input.connect(_on_entry_input)
	row.add_child(_entry)
	row.add_child(NC.button("Send", "primary", func(): _on_submit(_entry.text)))
	row.add_child(NC.button("Close", "bordered", close_chat))

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
	_players_card.add_theme_stylebox_override("panel", T.box(Color(0.05, 0.05, 0.05, 0.9), 10, Color(1, 1, 1, 0.1), 1, Vector2(12, 10)))
	_players_card.visible = false
	_players_card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_players_card)
	_players_box = VBoxContainer.new()
	_players_box.add_theme_constant_override("separation", 3)
	_players_card.add_child(_players_box)


func _process(delta: float) -> void:
	for l in _lines:
		l["age"] = float(l["age"]) + delta
		var lab: Label = l["label"]
		lab.modulate.a = 1.0 if chat_open else clampf((LINE_LIFE - float(l["age"])) / 1.5, 0.0, 1.0)
	for t in _toast_nodes.duplicate():
		t["age"] = float(t["age"]) + delta
		var n: Control = t["node"]
		if float(t["age"]) > TOAST_LIFE:
			n.queue_free()
			_toast_nodes.erase(t)
		elif float(t["age"]) > TOAST_LIFE - 0.6:
			n.modulate.a = (TOAST_LIFE - float(t["age"])) / 0.6


func add_chat(from_name: String, text: String, system: bool = false) -> void:
	var lab := Label.new()
	lab.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	lab.custom_minimum_size = Vector2(440, 0)
	lab.mouse_filter = Control.MOUSE_FILTER_IGNORE
	T.style_text(lab, "body", "regular", T.SECONDARY if system else T.WHITE, 14)
	lab.add_theme_color_override("font_outline_color", Color(0, 0, 0, 0.9))
	lab.add_theme_constant_override("outline_size", 4)
	lab.text = text if system else "%s: %s" % [from_name, text]
	_feed.add_child(lab)
	_lines.append({"label": lab, "age": 0.0})
	while _lines.size() > FEED_LINES:
		var old: Dictionary = _lines.pop_front()
		(old["label"] as Label).queue_free()
	if not chat_open and not system:
		_unread += 1


func toast(text: String, kind: String = "info") -> void:
	var p := PanelContainer.new()
	var col: Color = T.AMBER if kind == "info" else (T.RED if kind == "error" else T.GREEN)
	p.add_theme_stylebox_override("panel", T.box(Color(0.06, 0.06, 0.06, 0.94), 12, Color(col.r, col.g, col.b, 0.6), 1, Vector2(14, 8)))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	NC.label(p, text, "body", "medium", T.WHITE)
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


## Rows from net_state / the transport roster: [{id, name, system_id?, ship?, is_authority?, rtt?, in_my_system?}].
func set_players(players: Array, local_id: int) -> void:
	for c in _players_box.get_children():
		c.queue_free()
	NC.label(_players_box, "%d online" % players.size(), "caption", "semibold", T.AMBER)
	for item in players:
		var p: Dictionary = item
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 10)
		var nm: String = str(p.get("name", "?")) + ("  (you)" if int(p.get("id", -1)) == local_id else "")
		if bool(p.get("is_authority", false)):
			nm += "  *"
		NC.label(h, nm, "body", "regular", T.WHITE if bool(p.get("in_my_system", false)) or int(p.get("id", -1)) == local_id else T.SECONDARY)
		NC.hspacer(h)
		var sys: String = ("system %d" % int(p["system_id"])) if p.has("system_id") and int(p["system_id"]) >= 0 else ""
		if sys != "":
			NC.label(h, sys, "caption", "regular", T.SECONDARY)
		if p.has("rtt") and int(p["rtt"]) >= 0:
			NC.label(h, "%d ms" % int(p["rtt"]), "caption", "regular", T.SECONDARY)
		_players_box.add_child(h)


## Trade invites arrive from the bridge as events; there is no send API yet, so this is a notice only.
func show_trade_offer(from_name: String) -> void:
	Alert.show(self, {"title": "Trade request", "message": "%s wants to trade with you.\n\nPlayer-to-player trading isn't available in the Godot build yet; the request was declined for you." % from_name,
		"buttons": [{"title": "OK", "role": "cancel"}]})
