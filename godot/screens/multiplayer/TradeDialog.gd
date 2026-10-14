# NOVA Swift -- player-to-player trade window (Godot form of the Apple TradeView).
#
# A modal card over flight: "YOU GIVE" (amber, editable from what you carry: credits, cargo, outfits - streamed live
# to the partner) next to "YOU RECEIVE" (green, a live mirror of the partner's offer), and a confirm bar. Changing
# either offer clears both confirmations; when both sides confirm, each applies the swap to its OWN pilot save
# (shared TradeRules in Swift). The state machine lives in the bridge (net_trade_* / TradeCoordinator); this node
# only draws net_trade_state() and calls net_trade_offer / net_trade_accept / net_trade_cancel.
#
# Owned by NetService (created on the first `trade` bridge event, freed when the trade ends). Esc / pad B cancels.
#
# Loaded with preload() (no class_name), like Controls.gd.
extends CanvasLayer

const Proto = preload("res://net/NetProto.gd")
const T = preload("res://ui/novaswift/NovaTheme.gd")
const NC = preload("res://ui/novaswift/NovaControls.gd")

signal closed

var nova: Object = null
var state: Dictionary = {}
var inventory: Dictionary = {}
var my_offer: Dictionary = {"credits": 0, "cargo": {}, "outfits": {}}   # cargo/outfits: id(int) -> amount
var last_error: String = ""

var _scale: float = 1.0
var _root: Control
var _card: PanelContainer
var _body: VBoxContainer
var _built_for: String = ""


func _init() -> void:
	layer = 95
	name = "TradeDialog"


func setup(nova_obj: Object) -> void:
	nova = nova_obj
	_scale = clampf(DisplayServer.screen_get_scale(), 1.0, 3.0)
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.theme = T.theme()
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.62)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	dim.mouse_filter = Control.MOUSE_FILTER_STOP
	_root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(center)
	_card = PanelContainer.new()
	_card.custom_minimum_size = Vector2(700, 0)
	_card.add_theme_stylebox_override("panel", T.box(Color(0.05, 0.06, 0.10, 0.98), 18, Color(1, 1, 1, 0.14), 1, Vector2(18, 16)))
	center.add_child(_card)
	_body = VBoxContainer.new()
	_body.add_theme_constant_override("separation", 12)
	_card.add_child(_body)
	refresh(true)


func _text(parent: Control, text: String, size: int, weight: String, color: Color, wrap: bool = false) -> Label:
	var l: Label = NC.label(parent, text, "body", weight, color)
	l.add_theme_font_size_override("font_size", size)
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


func _unhandled_input(e: InputEvent) -> void:
	if e.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_cancel()


func _cancel() -> void:
	if nova != null and nova.has_method("net_trade_cancel"):
		nova.net_trade_cancel()
	closed.emit()


## Re-read the bridge state and redraw. `force` rebuilds the editable side even if the partner is unchanged.
func refresh(force: bool = false) -> void:
	if nova == null or not nova.has_method("net_trade_state"):
		return
	var v: Variant = JSON.parse_string(str(nova.net_trade_state()))
	state = v if v is Dictionary else {}
	if not bool(state.get("open", false)):
		closed.emit()
		return
	if inventory.is_empty() or force:
		var iv: Variant = JSON.parse_string(str(nova.net_trade_inventory()))
		inventory = iv if iv is Dictionary else {}
	# Our own offer, as the bridge holds it (it also resets when the deal changes).
	var mo: Dictionary = state.get("my_offer", {}) as Dictionary
	my_offer = {"credits": Proto.num_int(mo.get("credits", 0), 0, 1000000000000), "cargo": _to_map(mo.get("cargo", []), "tons"), "outfits": _to_map(mo.get("outfits", []), "count")}
	_build()


static func _to_map(rows: Variant, key: String) -> Dictionary:
	var m: Dictionary = {}
	if rows is Array:
		for r in rows:
			if m.size() >= 64 or not (r is Dictionary):
				continue
			m[Proto.num_int((r as Dictionary).get("id", -1), -1, 2147483647, -1)] = Proto.num_int((r as Dictionary).get(key, 0), 0, 1000000000)
	return m


func _build() -> void:
	for c in _body.get_children():
		_body.remove_child(c)
		c.queue_free()
	var partner: String = Proto.clean_player_name(state.get("partner_name", ""), "Player")
	var joined: bool = bool(state.get("joined", false))
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	_body.add_child(head)
	NC.icon_rect(head, "arrow.left.arrow.right.circle.fill", 26, T.AMBER)
	var tc := VBoxContainer.new()
	tc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(tc)
	_text(tc, "Trade", 20, "semibold", T.WHITE)
	_text(tc, ("with %s" % partner) if joined else ("Waiting for %s to answer..." % partner), 12, "regular", T.SECONDARY)
	head.add_child(NC.icon_button("xmark", _cancel, T.SECONDARY, 30, 14))
	var sep := HSeparator.new()
	_body.add_child(sep)

	var cols := HBoxContainer.new()
	cols.add_theme_constant_override("separation", 18)
	_body.add_child(cols)
	_build_mine(cols)
	_build_theirs(cols, partner, joined)

	if last_error != "":
		_text(_body, last_error, 13, "medium", T.RED, true)
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 10)
	_body.add_child(bar)
	var my_ok: bool = bool(state.get("my_accepted", false))
	var their_ok: bool = bool(state.get("their_accepted", false))
	var status: String = ""
	if not joined:
		status = "Waiting for %s..." % partner
	elif my_ok and their_ok:
		status = "Completing the trade..."
	elif my_ok:
		status = "You accepted. Waiting for %s." % partner
	elif their_ok:
		status = "%s accepted. Review the deal and accept." % partner
	else:
		status = "Both of you must accept. Changing an offer clears both."
	var sl: Label = _text(bar, status, 13, "regular", T.SECONDARY, true)
	sl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	bar.add_child(NC.button("Cancel trade", "bordered", _cancel))
	var acc: Button = NC.button("Withdraw acceptance" if my_ok else "Accept", "bordered" if my_ok else "primary", func() -> void: _accept(not my_ok))
	acc.disabled = not joined
	bar.add_child(acc)


func _section(parent: Control, title: String, color: Color, glyph: String) -> VBoxContainer:
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.custom_minimum_size.x = 310
	col.add_theme_constant_override("separation", 8)
	parent.add_child(col)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	col.add_child(h)
	NC.icon_rect(h, glyph, 16, color)
	_text(h, title, 13, "bold", color)
	return col


func _build_mine(parent: Control) -> void:
	var col: VBoxContainer = _section(parent, "YOU GIVE", T.AMBER, "arrow.up.circle.fill")
	var held: int = int(inventory.get("credits", 0))
	var crow := HBoxContainer.new()
	crow.add_theme_constant_override("separation", 6)
	col.add_child(crow)
	_text(crow, "Credits", 14, "medium", T.WHITE).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text(crow, "of %s" % _fmt(held), 12, "regular", T.SECONDARY)
	var cr_row := HBoxContainer.new()
	cr_row.add_theme_constant_override("separation", 6)
	col.add_child(cr_row)
	var field: LineEdit = NC.text_field("0", str(int(my_offer["credits"])))
	field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	field.text_submitted.connect(func(t: String) -> void: _set_credits(t.to_int(), held))
	field.focus_exited.connect(func() -> void: _set_credits(field.text.to_int(), held))
	cr_row.add_child(field)
	cr_row.add_child(NC.button("-1k", "bordered", func() -> void: _set_credits(int(my_offer["credits"]) - 1000, held)))
	cr_row.add_child(NC.button("+1k", "bordered", func() -> void: _set_credits(int(my_offer["credits"]) + 1000, held)))

	var cargo: Array = inventory.get("cargo", [])
	if not cargo.is_empty():
		_text(col, "Cargo", 12, "semibold", T.SECONDARY)
		for item in cargo:
			var d: Dictionary = item
			_item_row(col, str(d["name"]), int(d["tons"]), "t", int((my_offer["cargo"] as Dictionary).get(int(d["id"]), 0)),
				func(v: int) -> void: _set_item("cargo", int(d["id"]), v))
	var outfits: Array = inventory.get("outfits", [])
	if not outfits.is_empty():
		_text(col, "Outfits", 12, "semibold", T.SECONDARY)
		for item in outfits:
			var d2: Dictionary = item
			_item_row(col, str(d2["name"]), int(d2["count"]), "", int((my_offer["outfits"] as Dictionary).get(int(d2["id"]), 0)),
				func(v: int) -> void: _set_item("outfits", int(d2["id"]), v))
	if cargo.is_empty() and outfits.is_empty():
		_text(col, "You have no cargo or outfits to trade.", 12, "regular", T.SECONDARY, true)


func _item_row(parent: Control, nm: String, held: int, unit: String, value: int, cb: Callable) -> void:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	parent.add_child(h)
	var l: Label = _text(h, nm, 13, "regular", T.WHITE)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.clip_text = true
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_text(h, "have %d%s" % [held, unit], 11, "regular", T.TERTIARY)
	h.add_child(NC.stepper(null, value, 0, held, cb))


func _build_theirs(parent: Control, partner: String, joined: bool) -> void:
	var col: VBoxContainer = _section(parent, "YOU RECEIVE", T.GREEN, "arrow.down.circle.fill")
	var o: Dictionary = state.get("their_offer", {}) as Dictionary
	var credits: int = Proto.num_int(o.get("credits", 0), 0, 1000000000000)
	var cargo: Array = (o.get("cargo", []) as Array).slice(0, 64) if o.get("cargo", []) is Array else []
	var outfits: Array = (o.get("outfits", []) as Array).slice(0, 64) if o.get("outfits", []) is Array else []
	if credits <= 0 and cargo.is_empty() and outfits.is_empty():
		_text(col, ("%s hasn't offered anything yet." % partner) if joined else ("Waiting for %s to join..." % partner), 12, "regular", T.SECONDARY, true)
		return
	if credits > 0:
		_recv_row(col, "Credits", "%s cr" % _fmt(credits))
	for c in cargo:
		if c is Dictionary:
			_recv_row(col, Proto.clean_text((c as Dictionary).get("name", "Cargo"), 48), "%d t" % Proto.num_int((c as Dictionary).get("tons", 0), 0, 1000000000))
	for x in outfits:
		if x is Dictionary:
			_recv_row(col, Proto.clean_text((x as Dictionary).get("name", "Outfit"), 48), "x%d" % Proto.num_int((x as Dictionary).get("count", 0), 0, 1000000000))


func _recv_row(parent: Control, nm: String, val: String) -> void:
	var h := HBoxContainer.new()
	parent.add_child(h)
	_text(h, nm, 13, "regular", T.WHITE).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text(h, val, 13, "medium", T.GREEN)


static func _fmt(n: int) -> String:
	var s: String = str(absi(n))
	var out: String = ""
	while s.length() > 3:
		out = "," + s.substr(s.length() - 3) + out
		s = s.substr(0, s.length() - 3)
	return ("-" if n < 0 else "") + s + out


# --- edits -> bridge ----------------------------------------------------------------------------------

func _set_credits(v: int, held: int) -> void:
	var c: int = clampi(v, 0, held)
	if c == int(my_offer["credits"]):
		return
	my_offer["credits"] = c
	_push_offer()


func _set_item(kind: String, id: int, v: int) -> void:
	var m: Dictionary = my_offer[kind]
	if v <= 0:
		m.erase(id)
	else:
		m[id] = v
	_push_offer()


func _push_offer() -> void:
	var cargo: Array = []
	for id in (my_offer["cargo"] as Dictionary):
		cargo.append({"id": id, "tons": (my_offer["cargo"] as Dictionary)[id]})
	var outfits: Array = []
	for id in (my_offer["outfits"] as Dictionary):
		outfits.append({"id": id, "count": (my_offer["outfits"] as Dictionary)[id]})
	last_error = str(nova.net_trade_offer(JSON.stringify({"credits": my_offer["credits"], "cargo": cargo, "outfits": outfits})))
	refresh()


func _accept(on: bool) -> void:
	last_error = str(nova.net_trade_accept(on))
	refresh()
