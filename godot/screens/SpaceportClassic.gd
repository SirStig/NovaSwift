# NOVA Swift — the Classic (original EV Nova) look of the docked spaceport.
#
# Mirrors the Apple app's SpaceportView / SpaceportScreens / ShipInfoView /
# TradeQuantityPrompt: every window is its frame PICT (8500 spaceport, 8510 trade,
# 8502 outfitter, 8501 shipyard, 8503 bar, 8505 mission BBS, 8507/8506 ship info)
# with items placed at the DITL rects (1000, 1001, 1002, 1004, 1013, 1006, 1019,
# 1005), three-state art buttons and the cölr list colours. Rules and state stay in
# Spaceport.gd (this class only draws and routes focus); the plain "Nova Swift"
# screens remain in Spaceport.gd behind Prefs presentation.modern_dialogs.
#
# Window stack: hub dialog (always) < one service window (scrim) < overlay (quantity
# prompt, ship info, holovid, hire escort, gamble). Only the top one is focusable.
extends RefCounted

const T = preload("res://ui/classic/ClassicTheme.gd")
const CD = preload("res://ui/classic/ClassicDialog.gd")
const CS = preload("res://ui/classic/ClassicScreen.gd")

var sp: Node
var nova: Object

var hub_dlg: Control
var win_dlg: Control
var win_host: Control
var shop := {}                    # the open shop window's nodes
var msg_label: Label
var _hub_key := ""
var _prev_focus: Control
var _want_key := ""
var grid                          # CS.ItemGrid of the open shop window
var _top_row := 0

# DITL #1000 slot items (left column, right column).
const SLOT := {"bar": 10, "missionBBS": 9, "tradeCenter": 6, "shipyard": 8, "outfitter": 7, "recharge": 3, "leave": 11}
const SLOT_STOCK := {10: Rect2i(3, 333, 145, 25), 9: Rect2i(3, 374, 145, 25), 6: Rect2i(3, 414, 145, 25),
	8: Rect2i(471, 333, 145, 25), 7: Rect2i(471, 375, 145, 25), 3: Rect2i(471, 416, 145, 25), 11: Rect2i(471, 456, 145, 25)}


func setup(spaceport: Node, world: Object) -> void:
	sp = spaceport
	nova = world


func active() -> bool:
	return sp._classic()


func label(key: String, fallback: String) -> String:
	return str(sp._info.get("labels", {}).get(key, fallback))


func str150(i: int, fallback: String) -> String:
	return T.string_at(150, i, fallback)


# --- window plumbing ---------------------------------------------------------------------

func clear_all() -> void:
	_free(win_host)
	win_host = null
	win_dlg = null
	_free(hub_dlg)
	hub_dlg = null
	shop = {}
	grid = null


func _free(n: Node) -> void:
	if n != null and is_instance_valid(n):
		if n.get_parent() != null:
			n.get_parent().remove_child(n)
		n.queue_free()


func top_dialog() -> Control:
	return win_dlg if (win_dlg != null and is_instance_valid(win_dlg)) else hub_dlg


func show_window(d: Control) -> void:
	var key := CS.focus_key(win_dlg)
	if win_host != null and is_instance_valid(win_host):
		_free(win_host)
	else:
		_hub_key = CS.focus_key(hub_dlg)
		CS.set_enabled(hub_dlg, false)
	win_dlg = d
	win_host = CD.modal(sp._root, d, 0.5)
	_want_key = key


func finish_focus(default_key: String) -> void:
	if win_dlg == null:
		return
	if _want_key == "" or not CS.focus_by_key(win_dlg, _want_key):
		if not CS.focus_by_key(win_dlg, default_key):
			win_dlg.focus_first.call_deferred()


func close_window(refocus := true) -> void:
	shop = {}
	grid = null
	msg_label = null
	if win_host != null and is_instance_valid(win_host):
		_free(win_host)
		win_host = null
		win_dlg = null
		if hub_dlg != null and refocus:
			CS.set_enabled(hub_dlg, true)
			if not CS.focus_by_key(hub_dlg, _hub_key):
				hub_dlg.focus_first.call_deferred()


func show_overlay(d: Control, dim := 0.6) -> void:
	var had: bool = sp._overlay != null
	var pf: Control = _prev_focus if had else sp.get_viewport().gui_get_focus_owner()
	sp._close_overlay()
	_prev_focus = pf
	CS.set_enabled(top_dialog(), false)
	sp._overlay = CD.modal(sp._root, d, dim)


## Called by Spaceport._close_overlay once an overlay is gone.
func overlay_closed() -> void:
	var top := top_dialog()
	if top == null or not is_instance_valid(top):
		return
	CS.set_enabled(top, true)
	var pf := _prev_focus
	_prev_focus = null
	(func():
		if pf != null and is_instance_valid(pf) and pf.is_inside_tree() and pf.focus_mode != Control.FOCUS_NONE:
			pf.grab_focus()
		elif is_instance_valid(top) and top.is_inside_tree():
			top.focus_first()).call_deferred()


func set_message(t: String) -> void:
	if msg_label != null and is_instance_valid(msg_label):
		msg_label.text = t


func _msg_label(d: Control, r: Rect2i, size := CS.BODY, align := HORIZONTAL_ALIGNMENT_LEFT) -> void:
	msg_label = CS.text(d, str(sp._message), r, size, CS.AMBER, align)


# --- landing screen (DLOG/DITL 1000, PICT 8500) ------------------------------------------------

func hub() -> void:
	close_window(false)
	_free(hub_dlg)
	var info: Dictionary = sp._info
	var d := CS.frame(nova, 1000, 8500)
	hub_dlg = d
	sp._root.add_child(d)
	var area := CS.rect(nova, 1000, 4, Rect2i(3, 3, 612, 285))
	var pid: int = nova.spaceport_picture_id(1, int(info.get("id", -1)))
	var land: Texture2D = T.pict(pid) if pid >= 0 else null
	if land != null:
		CS.picture(d, land, Rect2i(area.position, Vector2i(land.get_size())))
	else:
		var spr: Texture2D = sp._spob_sprite_tex(int(info.get("id", -1)))
		if spr != null:
			var sz := spr.get_size()
			var s := minf(1.5, minf(float(area.size.x - 52) / sz.x, float(area.size.y - 20) / sz.y))
			var w := int(sz.x * s)
			var h := int(sz.y * s)
			CS.picture(d, spr, Rect2i(area.position.x + (area.size.x - w) / 2, area.position.y + (area.size.y - h) / 2, w, h))
	var name_r := CS.rect(nova, 1000, 2, Rect2i(159, 297, 303, 18))
	CS.text(d, str(info.get("name", "")), name_r, 15, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER)
	var desc_r := CS.rect(nova, 1000, 5, Rect2i(160, 327, 301, 185))
	CS.scroll_text(d, str(info.get("description", "")), desc_r, CS.BODY, Color.WHITE)
	_msg_label(d, Rect2i(area.position.x + 6, area.end.y - 18, area.size.x - 12, 14))
	var first := ""
	var add := func(key: String, text: String, cb: Callable, fk: String) -> void:
		var idx: int = SLOT[key]
		CS.button(d, text, CS.rect(nova, 1000, idx, SLOT_STOCK[idx]), idx, cb, true, fk)
		if first == "":
			first = fk
	if info.get("bar", false):
		add.call("bar", label("bar", "Bar"), sp._show_bar, "hub_bar")
	if not info.get("uninhabited", false) and nova.has_game():
		add.call("missionBBS", str(sp._story_labels.get("missionBBS", "Mission BBS")), sp._open_bbs, "hub_bbs")
	if info.get("trade", false):
		add.call("tradeCenter", label("trade", "Trade Center"), sp._show_trade, "hub_trade")
	if info.get("shipyard", false):
		add.call("shipyard", label("shipyard", "Shipyard"), sp._show_shipyard, "hub_shipyard")
	if info.get("outfitter", false):
		add.call("outfitter", label("outfitter", "Outfitter"), sp._show_outfitter, "hub_outfitter")
	if info.get("needsRecharge", false):
		add.call("recharge", label("recharge", "Recharge"), sp._recharge, "hub_recharge")
	add.call("leave", label("leave", "Leave"), func(): sp.launch_requested.emit(), "hub_leave")
	var want := _hub_key if _hub_key != "" else first
	if not CS.focus_by_key(d, want):
		CS.focus_by_key(d, first)


# --- Trade Center (DLOG/DITL 1001, PICT 8510) -------------------------------------------------------

func trade() -> void:
	var data: Dictionary = sp._trade_data
	var rows: Array = data.get("rows", [])
	var d := CS.frame(nova, 1001, 8510)
	var hdr := CS.rect(nova, 1001, 2, Rect2i(38, 9, 352, 17))
	var grey := Color(0.6, 0.6, 0.6)
	var heads: Array = data.get("headers", ["Commodity", "Price", "Hold"])
	var hold := Control.new()
	hold.position = Vector2(hdr.position)
	hold.size = Vector2(hdr.size)
	hold.mouse_filter = Control.MOUSE_FILTER_IGNORE
	d.add_child(hold)
	CS.cell(hold, str(heads[0]), 0, 160, 17, grey)
	CS.cell(hold, str(heads[1]), 160, 62, 17, grey, HORIZONTAL_ALIGNMENT_CENTER)
	CS.cell(hold, str(heads[2]), 292, 60, 17, grey, HORIZONTAL_ALIGNMENT_RIGHT)
	var text_col := T.color("listText")
	var buttons := {}
	var row_nodes: Array = []
	for i in rows.size():
		var r: Dictionary = rows[i]
		var rr := CS.rect(nova, 1001, 3 + i, Rect2i(38, 25 + 12 * i, 352, 13))
		rr.size.y = 13
		var b := CS.row(d, rr, 30 + i)
		b.name = "row%d" % i
		b.set_meta("fkey", "row%d" % i)
		var lc := Color.WHITE
		match int(r.level):
			1: lc = Color(0.5, 0.9, 0.5)
			3: lc = Color(1, 0.5, 0.5)
		var held := int(r.held)
		CS.cell(b, str(r.name), 0, 160, 13, text_col)
		CS.cell(b, str(r.label), 160, 62, 13, lc, HORIZONTAL_ALIGNMENT_CENTER)
		CS.cell(b, str(int(r.price)), 222, 70, 13, text_col, HORIZONTAL_ALIGNMENT_CENTER)
		CS.cell(b, str(held) if held > 0 else "—", 292, 60, 13, text_col if held > 0 else grey, HORIZONTAL_ALIGNMENT_RIGHT)
		b.focus_entered.connect(func():
			sp._trade_sel = i
			_trade_sync(row_nodes, buttons))
		b.pressed.connect(func():
			sp._trade_sel = i
			_trade_sync(row_nodes, buttons)
			if not buttons.buy.disabled:
				buttons.buy.grab_focus())
		row_nodes.append(b)
	var st := CS.rect(nova, 1001, 14, Rect2i(41, 190, 346, 24))
	var line := ""
	var sc := CS.scroll_text(d, "", st, CS.BODY - 1, grey)
	buttons.status = sc
	buttons.credits = ""
	buttons.stat_text = str(data.get("status", ""))
	buttons.disaster = str(data.get("disaster", ""))
	var brect := CS.rect(nova, 1001, 12, Rect2i(60, 221, 99, 25))
	buttons.buy = CS.button(d, label("buy", "Buy"), brect, 12, func(): sp._trade_buy(-1, sp._trade_sel), true, "trade_buy")
	buttons.sell = CS.button(d, label("sell", "Sell"), CS.rect(nova, 1001, 13, Rect2i(166, 221, 99, 25)), 13,
		func(): sp._trade_sell(-1), true, "trade_sell")
	buttons.done = CS.button(d, label("done", "Done"), CS.rect(nova, 1001, 0, Rect2i(272, 221, 99, 25)), 0,
		sp._show_hub, true, "trade_done")
	for k in ["buy", "sell"]:
		var bb: TextureButton = buttons[k]
		bb.refused.connect(func(): nova.sound_beep(4))
		# Right-click / Alt-click = the type-an-amount prompt (the original's Alt-click).
		bb.gui_input.connect(func(e: InputEvent):
			if e is InputEventMouseButton and e.pressed and (e.button_index == MOUSE_BUTTON_RIGHT or e.alt_pressed) \
					and not bb.disabled:
				sp._trade_prompt(k == "buy")
				bb.accept_event())
	msg_label = null
	show_window(d)
	_trade_sync(row_nodes, buttons)
	var key := "row%d" % sp._trade_sel if not rows.is_empty() else "trade_done"
	finish_focus(key)


func _trade_sync(row_nodes: Array, b: Dictionary) -> void:
	var sel: int = sp._trade_sel
	for i in row_nodes.size():
		row_nodes[i].set_selected(i == sel)
	var can_buy := false
	var can_sell := false
	if sel >= 0 and sel < row_nodes.size():
		can_buy = nova.trade_quantity(sel, true, -1) > 0
		can_sell = nova.trade_quantity(sel, false, -1) > 0
	b.buy.disabled = not can_buy
	b.sell.disabled = not can_sell
	var head: String = sp._message if sp._message != "" else "%s cr" % CS.credits(int(nova.player_credits()))
	var sc: CS.PaneScroll = b.status
	var txt := head
	if b.stat_text != "":
		txt += "\n" + b.stat_text
	if b.disaster != "":
		txt += "\n" + b.disaster
	sc.label.text = txt
	sc.label.add_theme_color_override("font_color", Color(0.6, 0.6, 0.6))


# --- Outfitter / Shipyard (DITL 1002 on 8502, DITL 1004 on 8501) ----------------------------------

func shop_window(kind: String, fresh: bool) -> void:
	var outfit := kind == "outfit"
	var did := 1002 if outfit else 1004
	var d := CS.frame(nova, did, 8502 if outfit else 8501)
	var rect_grid := CS.rect(nova, did, 4, Rect2i(9, 8, 333, 271))
	var pane := CS.rect(nova, did, 5, Rect2i(354, 10, 192, 267))
	var pic_r := CS.rect(nova, did, 7, Rect2i(557, 8, 200, 200))
	var info_r := CS.rect(nova, did, 8, Rect2i(618, 214, 135, 100) if outfit else Rect2i(614, 214, 143, 100))
	var n := {"kind": kind}
	if fresh:
		_top_row = 0
	grid = CS.ItemGrid.new()
	grid.build(d, rect_grid, 100)
	n.pic = CS.picture(d, null, pic_r, TextureRect.STRETCH_KEEP_ASPECT_COVERED)
	var name_h := 0 if outfit else 16
	n.name = CS.text(d, "", Rect2i(pane.position, Vector2i(pane.size.x, 16)), 12, Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT, true) \
		if not outfit else null
	n.desc = CS.scroll_text(d, "", Rect2i(pane.position.x, pane.position.y + name_h, pane.size.x, pane.size.y - name_h), CS.BODY, Color.WHITE)
	n.rows = []
	var count := 5 if outfit else 3
	for i in count:
		var y := info_r.position.y + i * (19 if outfit else 22)
		var lab := CS.text(d, "", Rect2i(info_r.position.x, y, 70, 16), 10, Color(0.6, 0.6, 0.6))
		var val := CS.text(d, "", Rect2i(info_r.position.x + 66, y, info_r.size.x - 66, 16), 10, Color.WHITE)
		val.clip_text = true
		n.rows.append([lab, val])
	var br: Rect2i
	if outfit:
		br = CS.rect(nova, did, 6, Rect2i(288, 289, 99, 25))
		n.buy = CS.button(d, label("buy", "Buy"), br, 6, func(): sp._outfit_buy(1), true, "shop_buy")
		n.sell = CS.button(d, label("sell", "Sell"), CS.rect(nova, did, 3, Rect2i(394, 289, 99, 25)), 3,
			func(): sp._outfit_sell(1), true, "shop_sell")
		n.done = CS.button(d, label("done", "Done"), CS.rect(nova, did, 0, Rect2i(500, 289, 99, 25)), 0, sp._show_hub, true, "shop_done")
		for k in ["buy", "sell"]:
			var bb: TextureButton = n[k]
			bb.refused.connect(func(): nova.sound_beep(4))
			bb.gui_input.connect(func(e: InputEvent):
				if e is InputEventMouseButton and e.pressed and (e.button_index == MOUSE_BUTTON_RIGHT or e.alt_pressed) \
						and not bb.disabled:
					sp._outfit_prompt(k == "buy")
					bb.accept_event())
		n.up = CS.button(d, "^", CS.rect(nova, did, 9, Rect2i(148, 288, 25, 25)), 9, func(): grid.scroll(-1), true, "shop_up")
		n.down = CS.button(d, "&", CS.rect(nova, did, 10, Rect2i(178, 288, 25, 25)), 10, func(): grid.scroll(1), true, "shop_down")
	else:
		n.info = CS.button(d, label("info", "Info"), CS.rect(nova, did, 9, Rect2i(253, 289, 89, 25)), 9, sp._ship_info, true, "shop_info")
		n.buy = CS.button(d, label("buyShip", "Buy Ship"), CS.rect(nova, did, 0, Rect2i(365, 289, 109, 25)), 0, sp._ship_buy, true, "shop_buy")
		n.buy.refused.connect(func(): nova.sound_beep(4))
		n.done = CS.button(d, label("done", "Done"), CS.rect(nova, did, 6, Rect2i(480, 289, 109, 25)), 6, sp._show_hub, true, "shop_done")
		n.up = CS.button(d, "^", CS.rect(nova, did, 11, Rect2i(141, 288, 25, 25)), 11, func(): grid.scroll(-1), true, "shop_up")
		n.down = CS.button(d, "&", CS.rect(nova, did, 12, Rect2i(171, 288, 25, 25)), 12, func(): grid.scroll(1), true, "shop_down")
	# transaction message: the gap between the scroll arrows and the first button
	_msg_label(d, Rect2i(210, 289, 74 if outfit else 38, 25), 9)
	msg_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	shop = n
	var items: Array = []
	for it in sp._items:
		var id := int(it.id)
		var pid: int = nova.spaceport_picture_id(2 if outfit else 3, id)
		items.append({"id": id, "name": str(it.name), "tex": T.pict(pid) if pid >= 0 else null,
			"qty": int(it.owned) if outfit else 0, "locked": bool(it.get("locked", false))})
	grid.on_select = func(id: int): select(id)
	grid.on_activate = func(_id: int):
		if not n.buy.disabled:
			n.buy.grab_focus()
	grid.on_scroll = func():
		_top_row = grid.top_row
		n.up.disabled = grid.top_row <= 0
		n.down.disabled = grid.top_row >= grid.max_top()
	grid.set_items(items, sp._sel_id, _top_row)
	show_window(d)
	select(sp._sel_id)
	var si: int = grid.slot_of_selected()
	if _want_key.begins_with("tile"):
		_want_key = "tile%d" % si if si >= 0 else ""   # the grid's selection wins over the old focus
	finish_focus("tile%d" % si if si >= 0 else "shop_done")


func select(id: int) -> void:
	if shop.is_empty():
		return
	sp._sel_id = id
	var i: int = sp._find_item(id)
	var n := shop
	if i < 0:
		return
	var it: Dictionary = sp._items[i]
	var grey := Color(0.6, 0.6, 0.6)
	var cr := " cr"
	if n.kind == "outfit":
		var st = JSON.parse_string(nova.outfitter_state())
		var pid: int = nova.spaceport_picture_id(2, id)
		n.pic.texture = T.pict(pid) if pid >= 0 else null
		n.desc.label.text = nova.outfitter_description(id)
		var vals := [["Item Price:", CS.credits_abbr(int(it.price)) + cr], ["You Have:", CS.credits_abbr(int(st.credits)) + cr],
			["Item Mass:", "%d tons" % int(it.mass)], ["Free Mass:", "%d tons" % int(st.freeMass)],
			["Cargo:", "%d/%d tons" % [int(st.cargoUsed), int(st.cargoCapacity)]]]
		for r in vals.size():
			n.rows[r][0].text = vals[r][0]
			n.rows[r][1].text = vals[r][1]
		n.buy.disabled = not it.canBuy
		n.sell.disabled = not it.canSell
	else:
		var st2 = JSON.parse_string(nova.shipyard_state())
		var pid2: int = nova.spaceport_picture_id(3, id)
		n.pic.texture = T.pict(pid2) if pid2 >= 0 else null
		var info = JSON.parse_string(nova.shipyard_info(id))
		var s := {}
		for p in info.get("stats", []):
			s[str(p[0])] = str(p[1])
		n.name.text = str(it.name)
		n.desc.label.text = "Cargo: %s\nFree mass: %s\nShield / Armor: %s / %s\nGuns / Turrets: %s / %s\n\n%s" % [
			s.get("Cargo", "").replace(" t", " tons"), s.get("Free mass", "").replace(" t", " tons"),
			s.get("Shield", ""), s.get("Armor", ""), s.get("Guns", ""), s.get("Turrets", ""), str(info.get("description", ""))]
		var vals2 := [["Price:", CS.credits_abbr(int(it.price)) + cr], ["Trade-in:", CS.credits_abbr(int(st2.tradeIn)) + cr],
			["You Have:", CS.credits_abbr(int(st2.credits)) + cr]]
		for r in vals2.size():
			n.rows[r][0].text = vals2[r][0]
			n.rows[r][1].text = vals2[r][1]
		n.buy.disabled = not it.canBuy
	n.desc.scroll_vertical = 0


# --- quantity prompt (the original's native "how many?" box) -------------------------------------

func prompt(title: String, maxv: int, initial: int, on_ok: Callable, on_cancel := Callable()) -> void:
	var d: Control = CD._make(nova, Vector2i(172, 72), CD.Chrome.NATIVE)
	d._add_background(null)
	var lab: Label = d.add_label(title, Rect2i(6, 3, 104, 36), -1, 10)
	lab.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var edit: LineEdit = d.add_edit(str(clampi(initial, 1, maxv)), Rect2i(112, 8, 51, 16), 4)
	edit.name = "qty_edit"
	var ok := func():
		var q := int(edit.text)
		if q > maxv:
			nova.sound_beep(4)
			edit.text = str(maxv)
			return
		sp._close_overlay()
		if q > 0:
			on_ok.call(q)
	d.default_item = 1
	var okb: TextureButton = d.add_button("OK", Rect2i(92, 42, 70, 20), 1)
	d.actions[1] = ok
	okb.name = "qty_ok"
	var cb: TextureButton = d.add_button("Cancel", Rect2i(10, 42, 70, 20), 5)
	var cancel := func():
		sp._close_overlay()
		if on_cancel.is_valid():
			on_cancel.call()
	d.actions[5] = cancel
	cb.name = "qty_cancel"
	edit.text_changed.connect(func(t: String):
		var digits := ""
		for ch in t:
			if ch >= "0" and ch <= "9":
				digits += ch
		if digits != t:
			var c := edit.caret_column
			edit.text = digits
			edit.caret_column = mini(c, digits.length()))
	edit.gui_input.connect(func(e: InputEvent):
		var step := 0
		if e.is_action_pressed("ui_left"):
			step = -1
		elif e.is_action_pressed("ui_right"):
			step = 1
		elif e.is_action_pressed("ui_up"):
			step = 10
		elif e.is_action_pressed("ui_down"):
			step = -10
		if step != 0:
			edit.text = str(clampi(int(edit.text) + step, 1, maxv))
			edit.caret_column = edit.text.length()
			edit.accept_event())
	show_overlay(d)
	sp._overlay_back = cancel
	edit.grab_focus.call_deferred()


# --- Ship Info (DLOG/DITL 1019 on 8507 with photo, 1005 on 8506 text only) ------------------------

func ship_info(info: Dictionary, ship_id: int) -> void:
	var pid: int = nova.spaceport_picture_id(3, ship_id)
	var photo: Texture2D = T.pict(pid) if pid >= 0 else null
	var have_photo := photo != null and T.pict(8507) != null
	var s := {}
	for p in info.get("stats", []):
		s[str(p[0])] = str(p[1]).replace(" jumps", "").replace(" t", "")
	var weapons: Array = info.get("weapons", [])
	var wtxt := "None" if weapons.is_empty() else ", ".join(weapons)
	var left := [["Speed", s.get("Speed", "")], ["Accel", s.get("Accel", "")], ["Turn", s.get("Turn", "")],
		["Mass", s.get("Mass", "")], ["Cargo", s.get("Cargo", "")], ["Fuel", s.get("Fuel", "")]]
	var right := [["Shield", s.get("Shield", "")], ["Armor", s.get("Armor", "")], ["Guns", s.get("Guns", "")],
		["Turrets", s.get("Turrets", "")], ["Crew", s.get("Crew", "")], ["Cost", CS.credits_abbr(int(info.get("price", 0)))]]
	var d: Control
	var done_cb := func(): sp._close_overlay()
	if have_photo:
		d = CS.frame(nova, 1019, 8507)
		CS.picture(d, photo, CS.rect(nova, 1019, 6, Rect2i(7, 6, 600, 400)), TextureRect.STRETCH_KEEP_ASPECT_COVERED)
		CS.text(d, str(info.name), CS.rect(nova, 1019, 2, Rect2i(7, 413, 600, 24)), 15, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, true)
		var sr := CS.rect(nova, 1019, 4, Rect2i(11, 442, 256, 92))
		_stat_cols(d, sr, left, right, 11)
		var wr := CS.rect(nova, 1019, 7, Rect2i(266, 442, 342, 59))
		CS.text(d, "Standard Weapons", Rect2i(wr.position, Vector2i(wr.size.x, 14)), 11, Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT, true)
		CS.scroll_text(d, wtxt, Rect2i(wr.position.x, wr.position.y + 15, wr.size.x, wr.size.y - 15), 10, Color.WHITE)
		CS.button(d, label("done", "Done"), CS.rect(nova, 1019, 0, Rect2i(503, 507, 99, 25)), 0, done_cb, true, "info_done")
	else:
		d = CS.frame(nova, 1005, 8506)
		CS.text(d, str(info.name), CS.rect(nova, 1005, 2, Rect2i(3, 3, 240, 24)), 13, Color.WHITE, HORIZONTAL_ALIGNMENT_CENTER, true)
		var br := CS.rect(nova, 1005, 4, Rect2i(9, 32, 234, 214))
		var lines := ""
		for i in left.size():
			lines += "%s: %s     %s: %s\n" % [left[i][0], left[i][1], right[i][0], right[i][1]]
		lines += "\nStandard Weapons\n%s\n\n%s" % [wtxt, str(info.get("description", ""))]
		CS.scroll_text(d, lines, br, 10, Color.WHITE)
		CS.button(d, label("done", "Done"), CS.rect(nova, 1005, 0, Rect2i(86, 253, 74, 25)), 0, done_cb, true, "info_done")
	show_overlay(d)
	sp._overlay_back = sp._close_overlay
	CS.focus_by_key(d, "info_done")


func _stat_cols(d: Control, r: Rect2i, left: Array, right: Array, size: int) -> void:
	for i in left.size():
		var y := r.position.y + i * 15
		CS.text(d, str(left[i][0]), Rect2i(r.position.x, y, 44, 14), size, Color(0.6, 0.6, 0.6))
		CS.text(d, str(left[i][1]), Rect2i(r.position.x + 44, y, 70, 14), size, Color.WHITE)
		CS.text(d, str(right[i][0]), Rect2i(r.position.x + 128, y, 50, 14), size, Color(0.6, 0.6, 0.6))
		CS.text(d, str(right[i][1]), Rect2i(r.position.x + 178, y, 78, 14), size, Color.WHITE)


# --- Bar (DLOG/DITL 1013, PICT 8503) -------------------------------------------------------------------

func bar(b: Dictionary) -> void:
	var d := CS.frame(nova, 1013, 8503)
	CS.scroll_text(d, str(b.get("text", "")), CS.rect(nova, 1013, 6, Rect2i(16, 10, 230, 106)), CS.BODY, Color.WHITE)
	var hire := CS.button(d, str(b.get("hire", "Hire Escort")), CS.rect(nova, 1013, 4, Rect2i(6, 125, 146, 26)), 4,
		sp._bar_screens.open_hire, bool(b.get("canHire", true)), "bar_hire")
	CS.button(d, str(b.get("holovid", "Holovid")), CS.rect(nova, 1013, 2, Rect2i(6, 154, 146, 26)), 2, sp._holovid, true, "bar_holovid")
	CS.button(d, str(b.get("gamble", "Gamble")), CS.rect(nova, 1013, 1, Rect2i(156, 125, 99, 26)), 1,
		sp._bar_screens.open_gamble, true, "bar_gamble")
	CS.button(d, str(b.get("leave", "Leave")), CS.rect(nova, 1013, 0, Rect2i(156, 154, 99, 26)), 0, sp._show_hub, true, "bar_leave")
	hire.refused.connect(func(): nova.sound_beep(4))
	msg_label = null
	show_window(d)
	_want_key = ""
	finish_focus("bar_holovid")


# --- Holovid news ---------------------------------------------------------------------------------------

func holovid(h: Dictionary) -> void:
	var pid := int(h.pict)
	var d := CS.frame(nova, 999999, pid if pid >= 0 else 9000)
	var sz: Vector2 = d.size
	var tw := int(sz.x * 0.8)
	CS.scroll_text(d, str(h.text), Rect2i(int(sz.x * 0.1), 20, tw, int(sz.y * 0.58)), 12, Color.WHITE)
	var bw := 120
	CS.button(d, label("leave", "Leave"), Rect2i(int(sz.x / 2) - bw / 2, int(sz.y) - 40, bw, 25), 0, sp._close_holovid, true, "holo_leave")
	show_overlay(d)
	sp._overlay_back = sp._close_holovid
	CS.focus_by_key(d, "holo_leave")


# --- Mission BBS (DLOG/DITL 1006, PICT 8505) -------------------------------------------------------------------

func bbs(date: String) -> void:
	var d := CS.frame(nova, 1006, 8505)
	var hr := CS.rect(nova, 1006, 7, Rect2i(14, 3, 396, 15))
	CS.text(d, str(sp._story_labels.get("missionBBS", "Mission BBS")), Rect2i(hr.position, Vector2i(hr.size.x / 2, hr.size.y)), 11, Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT, true)
	CS.text(d, date, Rect2i(hr.position.x + hr.size.x / 2, hr.position.y, hr.size.x / 2, hr.size.y), 10, Color(0.75, 0.75, 0.75), HORIZONTAL_ALIGNMENT_RIGHT)
	var lr := CS.rect(nova, 1006, 1, Rect2i(10, 30, 195, 144))
	var listbox := Control.new()
	listbox.position = Vector2(lr.position)
	listbox.size = Vector2(lr.size)
	listbox.clip_contents = true
	listbox.mouse_filter = Control.MOUSE_FILTER_PASS
	d.add_child(listbox)
	var nodes := {}
	nodes.title = CS.text(d, "", CS.rect(nova, 1006, 4, Rect2i(233, 34, 269, 21)), 11, Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT, true)
	var tr := CS.rect(nova, 1006, 3, Rect2i(233, 60, 267, 93))
	var brief := CS.scroll_text(d, "", tr, CS.BODY - 1, Color.WHITE)
	nodes.text = brief.label
	nodes.brief = brief
	nodes.accept = CS.button(d, str(sp._story_labels.get("accept", "Accept")), CS.rect(nova, 1006, 0, Rect2i(266, 170, 99, 25)), 0,
		sp._bbs_accept, true, "bbs_accept")
	nodes.accept.disabled = true
	nodes.accept.visible = false
	var leave := CS.button(d, str(sp._story_labels.get("leave", "Leave")), CS.rect(nova, 1006, 6, Rect2i(368, 170, 99, 25)), 6,
		sp._show_hub, true, "bbs_leave")
	var rows: Array = []
	var first_key := ""
	var list: Array = sp._bbs_list
	for i in list.size():
		var m: Dictionary = list[i]
		var id := int(m.id)
		var rr := Rect2i(lr.position.x, lr.position.y + i * 13, lr.size.x, 13)
		var b := CS.row(d, rr, 50 + i)
		d.remove_child(b)
		listbox.add_child(b)
		b.position = Vector2(0, i * 13)
		b.name = "bbs_row%d" % i
		b.set_meta("fkey", "bbs_row%d" % i)
		var lb := CS.cell(b, str(m.name), 3, lr.size.x - 6, 13, Color(0.65, 0.65, 0.65))
		b.focus_entered.connect(func():
			for k in rows.size():
				rows[k].set_selected(k == i)
			var top := i * 13
			var off := -int(listbox.get_meta("off", 0))
			var offs := int(listbox.get_meta("off", 0))
			if top < offs:
				offs = top
			elif top + 13 > offs + lr.size.y:
				offs = top + 13 - lr.size.y
			listbox.set_meta("off", offs)
			for k in rows.size():
				rows[k].position.y = k * 13 - offs
			sp._bbs_show(id))
		b.pressed.connect(func(): sp._bbs_show(id))
		rows.append(b)
		if first_key == "":
			first_key = "bbs_row%d" % i
	if list.is_empty():
		CS.text(d, "No missions available.", Rect2i(lr.position.x + 2, lr.position.y + 2, lr.size.x - 4, 13), 10, Color(0.6, 0.6, 0.6))
	sp._bbs_nodes = nodes
	msg_label = null
	show_window(d)
	_want_key = ""
	finish_focus(first_key if first_key != "" else "bbs_leave")


func bbs_present(o: Dictionary) -> void:
	var n: Dictionary = sp._bbs_nodes
	n.title.text = str(o.title)
	n.text.text = str(o.text)
	n.brief.scroll_vertical = 0
	n.accept.disabled = false
	n.accept.visible = true


## The dialog inside the open overlay host (tests / focus code).
func ov_top() -> Control:
	if sp._overlay == null:
		return null
	return sp._overlay.get_child(sp._overlay.get_child_count() - 1)
