# Headless check of the Classic (original EV Nova UI) spaceport, comm, plunder and story
# screens: each builds from the real DITL/PICT with the expected item counts and sizes,
# focus navigation follows the DITL geometry, transactions still change credits exactly,
# and the Nova Swift toggle brings the plain screens back. Composes PNG previews (scratch dir)
# from the built node trees (UiCompose.gd).
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/classic_spaceport_selfcheck.gd
extends SceneTree

const Prefs = preload("res://Prefs.gd")
const Controls = preload("res://Controls.gd")
const T = preload("res://ui/classic/ClassicTheme.gd")
const Spaceport = preload("res://screens/Spaceport.gd")
const Interactions = preload("res://screens/Interactions.gd")
const StoryScreens = preload("res://screens/StoryScreens.gd")
const Compose = preload("res://tests/UiCompose.gd")

const OUT := "/private/tmp/claude-504/-Users-joshuakac1-Projects-EV-NOVA/6adade1c-9674-407a-b6fb-4f119b38cb13/scratchpad/"
const VIEW := Vector2i(1280, 720)

var nova
var fails := 0


func _ok(cond: bool, what: String, detail := "") -> void:
	print(("PASS " if cond else "FAIL ") + what + ((" — " + detail) if detail != "" else ""))
	if not cond:
		fails += 1


func _frames(n := 3) -> void:
	for i in n:
		await process_frame


func _key(action: String) -> void:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	root.push_input(e)


func _j(t: String):
	return JSON.parse_string(t)


func _count(n: Node, cls: String) -> int:
	return n.find_children("*", cls, true, false).size()


func _init() -> void:
	_run()


func _run() -> void:
	get_root().content_scale_aspect = Window.CONTENT_SCALE_ASPECT_IGNORE
	get_root().content_scale_size = VIEW
	get_root().size = VIEW
	Prefs.path = OS.get_user_data_dir() + "/classic_spaceport_settings.cfg"
	DirAccess.remove_absolute(Prefs.path)
	Prefs.load_all()
	Controls.register()
	nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	if not nova.load_game(OS.get_environment("NOVA_DATA_DIR")):
		print("FAIL no game data")
		quit(1)
		return
	T.setup(nova)
	var scen = _j(nova.pilot_scenarios())
	nova.pilot_create(OS.get_user_data_dir() + "/classic_spaceport", int(scen[0].id), "Classic Tester", true, "", "")
	nova.make_world(-1)
	nova.step(1.0 / 30.0)
	# A stellar with every service.
	var spob := -1
	for id in range(128, 1600):
		if not nova.debug_dock_at(id):
			continue
		var i = _j(nova.spaceport_info())
		if i is Dictionary and i.get("bar", false) and i.get("trade", false) and i.get("outfitter", false) and i.get("shipyard", false) \
				and not (_j(nova.outfitter_list()) as Array).is_empty() and not (_j(nova.shipyard_list()) as Array).is_empty():
			spob = id
			break
	_ok(spob >= 0, "found a stellar with bar + trade + outfitter + shipyard", str(spob))
	nova.debug_set_credits(5000000)

	var sp = Spaceport.new()
	root.add_child(sp)
	sp.setup(nova)
	sp.open()
	if nova.offer_pending():
		nova.offer_decline()
	while nova.story_text_pending():
		nova.story_text_dismiss()
	await _frames()
	var info = _j(nova.spaceport_info())
	print("viewport rect: ", sp._root.get_viewport_rect().size, " window ", root.size)

	# --- landing screen ---------------------------------------------------------------------
	var hub = sp._c.hub_dlg
	_ok(hub != null and sp._classic(), "classic hub dialog built")
	_ok(hub.window_size == Vector2i(618, 517), "hub is the 618x517 spaceport frame (PICT 8500)", str(hub.window_size))
	_ok(not sp._modern_center.visible, "plain Nova Swift panel hidden in Classic")
	for k in ["hub_bar", "hub_bbs", "hub_trade", "hub_shipyard", "hub_outfitter", "hub_leave"]:
		_ok(hub.find_child(k, true, false) != null, "hub has " + k)
	var leave = hub.find_child("hub_leave", true, false)
	_ok(leave.position == Vector2(471, 456), "Leave sits in DITL #1000 item 11's slot", str(leave.position))
	var bar_b = hub.find_child("hub_bar", true, false)
	_ok(bar_b.position == Vector2(3, 333) and int(bar_b.size.x) == 145, "Bar is DITL #1000 item 10 (3,333) 145 wide", str(bar_b.position))
	_ok(root.gui_get_focus_owner() == bar_b, "hub focuses Bar first")
	_key("ui_down")
	await _frames()
	_ok(root.gui_get_focus_owner() == hub.find_child("hub_bbs", true, false), "ui_down steps Bar -> Mission BBS by DITL geometry")
	_key("ui_right")
	await _frames()
	_ok(root.gui_get_focus_owner() == hub.find_child("hub_outfitter", true, false), "ui_right crosses to the right column (nearest slot: Outfitter)",
		str(root.gui_get_focus_owner().name))
	Compose.compose(sp._root, VIEW, OUT + "classic_landing.png")

	# --- trade center -------------------------------------------------------------------------
	sp._show_trade()
	await _frames()
	var win = sp._c.win_dlg
	var tv = _j(nova.trade_view())
	_ok(win.window_size == Vector2i(426, 252), "trade window is the 426x252 frame (PICT 8510)", str(win.window_size))
	_ok(_count(win, "BaseButton") >= tv.rows.size(), "one row button per commodity (%d)" % tv.rows.size())
	_ok(win.find_child("trade_buy", true, false) != null and win.find_child("trade_sell", true, false) != null and win.find_child("trade_done", true, false) != null, "Buy / Sell / Done buttons")
	_ok(not hub.find_child("hub_leave", true, false).focus_mode == Control.FOCUS_ALL, "hub is not focusable under the window")
	var scale := (win as Control).scale.x
	_ok(scale <= 1.5, "trade window is not blown up to fill the screen (scale %.2f)" % scale)
	var c0: int = nova.player_credits()
	var price := int(tv.rows[0].price)
	var buyb = win.find_child("trade_buy", true, false)
	_ok(not buyb.disabled, "Buy enabled for the selected row")
	buyb.pressed.emit()
	await _frames()
	var spent: int = c0 - nova.player_credits()
	_ok(spent > 0 and spent % price == 0, "Buy button: credits drop by tons*price exactly", "%d @ %d" % [spent, price])
	var sellb = sp._c.win_dlg.find_child("trade_sell", true, false)
	sellb.pressed.emit()
	await _frames()
	_ok(nova.player_credits() == c0, "Sell button restores the credits exactly")
	Compose.compose(sp._root, VIEW, OUT + "classic_trade.png")
	_key("shop_buy_qty")
	await _frames()
	_ok(sp._overlay != null and sp._c.ov_top().window_size == Vector2i(172, 72), "quantity prompt is the 172x72 native box")
	Compose.compose(sp._root, VIEW, OUT + "classic_qty.png")
	var edit = sp._overlay.find_child("qty_edit", true, false)
	_ok(edit != null and root.gui_get_focus_owner() == edit, "prompt field has focus")
	edit.text = "3"
	sp._overlay.find_child("qty_ok", true, false).pressed.emit()
	await _frames()
	_ok(sp._overlay == null and c0 - nova.player_credits() == 3 * price, "typed quantity buys exactly 3 tons", str(c0 - nova.player_credits()))
	sp._trade_sell(0)
	await _frames()
	_key("ui_cancel")
	await _frames()
	_ok(sp._screen == "hub" and sp._c.win_dlg == null, "ui_cancel returns to the landing screen")

	# --- outfitter -----------------------------------------------------------------------------
	sp._show_outfitter()
	await _frames()
	win = sp._c.win_dlg
	_ok(win.window_size == Vector2i(765, 321), "outfitter is the 765x321 frame (PICT 8502)", str(win.window_size))
	_ok(win.find_children("tile*", "Button", true, false).size() == 20, "4x5 = 20 grid tiles")
	var ol: Array = sp._items
	var shown := 0
	for t in win.find_children("tile*", "Button", true, false):
		if t.has_item:
			shown += 1
	_ok(shown == mini(20, ol.size()), "tiles show the first %d outfits" % mini(20, ol.size()), str(shown))
	_ok(win.find_child("shop_buy", true, false).position == Vector2(288, 289), "Buy at DITL #1002 item 6 (288,289)")
	_ok(win.find_child("shop_up", true, false) != null and win.find_child("shop_down", true, false) != null, "scroll arrows present")
	var first_sel: int = sp._sel_id
	_key("ui_right")
	await _frames()
	_ok(sp._sel_id != first_sel or ol.size() < 2, "ui_right moves the selection in the grid")
	var pick = null
	for it in ol:
		if it.canBuy and int(it.price) > 0 and not str(it.name).is_empty():
			pick = it
			break
	if pick != null:
		var gi: int = sp._c.grid.index_of(int(pick.id))
		sp._c.grid.select_index(gi, true)
		await _frames()
		var cc: int = nova.player_credits()
		var buy = sp._c.win_dlg.find_child("shop_buy", true, false)
		_ok(not buy.disabled, "Buy enabled for " + str(pick.name))
		buy.pressed.emit()
		await _frames()
		var after = null
		for it in _j(nova.outfitter_list()):
			if int(it.id) == int(pick.id):
				after = it
		_ok(cc - nova.player_credits() == int(pick.price), "outfit Buy changes credits by exactly the price", "%d" % (cc - nova.player_credits()))
		if after != null and int(after.owned) > int(pick.owned):
			sp._c.win_dlg.find_child("shop_sell", true, false).pressed.emit()
			await _frames()
			_ok(nova.player_credits() == cc, "Sell returns the credits exactly")
	Compose.compose(sp._root, VIEW, OUT + "classic_outfitter.png")
	if ol.size() > 20:
		sp._c.win_dlg.find_child("shop_down", true, false).pressed.emit()
		await _frames()
		_ok(sp._c.grid.top_row == 1, "down arrow scrolls the grid one row")
	_key("ui_cancel")
	await _frames()

	# --- shipyard + ship info --------------------------------------------------------------------
	sp._show_shipyard()
	await _frames()
	win = sp._c.win_dlg
	_ok(win.window_size == Vector2i(765, 323), "shipyard is the 765x323 frame (PICT 8501)", str(win.window_size))
	_ok(win.find_child("shop_info", true, false) != null and win.find_child("shop_buy", true, false).position == Vector2(365, 289), "Info + Buy Ship at DITL #1004 slots")
	Compose.compose(sp._root, VIEW, OUT + "classic_shipyard.png")
	sp._ship_info()
	await _frames()
	var ov = sp._overlay.get_child(sp._overlay.get_child_count() - 1)
	_ok(ov.window_size == Vector2i(614, 537) or ov.window_size == Vector2i(250, 285), "ship info is DLOG 1019 (614x537) or 1005 (250x285)", str(ov.window_size))
	Compose.compose(sp._root, VIEW, OUT + "classic_shipinfo.png")
	_key("ui_cancel")
	await _frames()
	_ok(sp._overlay == null and sp._screen == "shipyard", "ui_cancel closes only the ship info")
	var ships: Array = _j(nova.shipyard_list())
	var buy_ship = null
	for s in ships:
		if s.canBuy and (buy_ship == null or int(s.price) < int(buy_ship.price)):
			buy_ship = s
	if buy_ship != null:
		sp._sel_id = int(buy_ship.id)
		sp._show_shipyard()
		await _frames()
		var c3: int = nova.player_credits()
		print("  buying ", buy_ship, " sel=", sp._sel_id, " btn disabled=", sp._c.win_dlg.find_child("shop_buy", true, false).disabled)
		sp._c.win_dlg.find_child("shop_buy", true, false).pressed.emit()
		await _frames()
		_ok(c3 - nova.player_credits() == int(buy_ship.price), "Buy Ship changes credits by the net price", "%d vs %d" % [c3 - nova.player_credits(), int(buy_ship.price)])
	_key("ui_cancel")
	await _frames()

	# --- mission BBS + bar ------------------------------------------------------------------------
	sp._open_bbs()
	await _frames()
	if sp._screen == "bbs":
		win = sp._c.win_dlg
		_ok(win.window_size == Vector2i(510, 201), "BBS is the 510x201 frame (PICT 8505)", str(win.window_size))
		Compose.compose(sp._root, VIEW, OUT + "classic_bbs.png")
		_key("ui_cancel")
		await _frames()
	sp._show_bar()
	await _frames()
	win = sp._c.win_dlg
	_ok(win.window_size == Vector2i(263, 185), "bar is the 263x185 frame (PICT 8503)", str(win.window_size))
	_ok(win.find_child("bar_hire", true, false) != null and win.find_child("bar_gamble", true, false) != null, "bar has Hire Escort / Gamble")
	Compose.compose(sp._root, VIEW, OUT + "classic_bar.png")
	var hb = win.find_child("bar_hire", true, false)
	if not hb.disabled:
		hb.pressed.emit()
		await _frames()
		_ok(sp._overlay != null and sp._overlay.find_child("hire_button", true, false) != null, "Hire Escort browser opens on the shipyard frame")
		Compose.compose(sp._root, VIEW, OUT + "classic_hire.png")
		_key("ui_cancel")
		await _frames()
	sp._c.win_dlg.find_child("bar_gamble", true, false).pressed.emit()
	await _frames()
	_ok(sp._overlay != null and sp._overlay.find_child("color_0", true, false) != null, "Gamble chooser (PICT 8529) opens")
	Compose.compose(sp._root, VIEW, OUT + "classic_gamble.png")
	_key("ui_cancel")
	await _frames()
	_key("ui_cancel")
	await _frames()
	_ok(sp._screen == "hub", "back at the landing screen")

	# --- modern toggle -------------------------------------------------------------------------------
	Prefs.apply_ui_mode(Prefs.UI_NOVA_SWIFT)
	sp.close()
	sp.open()
	await _frames()
	_ok(not sp._classic() and sp._modern_center.visible and sp._c.hub_dlg == null, "Nova Swift toggle: plain hub, no Classic dialogs")
	sp._show_outfitter()
	await _frames()
	_ok(sp._tiles.size() > 0 and sp._c.win_dlg == null, "Nova Swift toggle: the plain outfitter grid")
	Prefs.apply_ui_mode(Prefs.UI_CLASSIC)
	sp.close()

	await _comm_and_story()
	print("classic_spaceport_selfcheck: %d failure(s)" % fails)
	quit(1 if fails > 0 else 0)


func _comm_and_story() -> void:
	nova.launch()
	while nova.story_text_pending():
		nova.story_text_dismiss()
	nova.make_world(-1)
	for i in 120:
		nova.step(1.0 / 30.0)
	var ia = Interactions.new()
	root.add_child(ia)
	ia.setup(nova)
	# ship hail
	var opened := false
	for id in nova.ship_ids():
		if id == 0 or not nova.select_target(id):
			continue
		var r = _j(nova.hail_open(false))
		if r.get("result") == "window":
			ia._kind = "hail"
			ia._show_hail()
			opened = true
			break
		elif r.get("result") == "escorts":
			nova.hail_close()
	if opened:
		await _frames()
		var d = ia._dialog.find_children("*", "Control", true, false).filter(func(c): return c.has_method("focus_first"))
		_ok(d.size() >= 1 and d[0].window_size == Vector2i(423, 215), "ship hail is the 423x215 frame (PICT 8511)", str(d[0].window_size if d.size() else ""))
		_ok(ia._dialog.find_child("btn_top", true, false) != null and ia._dialog.find_child("btn_close", true, false) != null, "Greetings / Close Channel buttons")
		Compose.compose(ia, VIEW, OUT + "classic_hail.png")
		_key("ui_cancel")
		await _frames()
		_ok(ia._dialog == null, "ui_cancel closes the channel")
	else:
		print("  (no hailable ship this run)")
	# plunder
	var victim := -1
	for id in nova.ship_ids():
		if id != 0 and nova.debug_make_hulk(id, 5000):
			victim = id
			break
	nova.select_target(victim)
	nova.step(1.0 / 30.0)
	ia.board()
	await _frames()
	if ia._dialog != null:
		var pd = ia._dialog.find_children("*", "Control", true, false).filter(func(c): return c.has_method("focus_first"))
		_ok(pd[0].window_size == Vector2i(309, 198), "plunder dialog is the 309x198 frame (PICT 8515)", str(pd[0].window_size))
		var names := []
		for n in ["Energy", "Cargo", "Credits", "Ammo", "Capture Ship", "Abort"]:
			names.append(ia._dialog.find_child("btn_" + n, true, false) != null)
		_ok(not names.has(false), "six plunder buttons in the DITL slots")
		var ab = ia._dialog.find_child("btn_Abort", true, false)
		_ok(ab.position == Vector2(91, 166) and int(ab.size.x) == 126, "Abort is the isolated item 0 slot (91,166) 126 wide", str(ab.position))
		var cs = ia._dialog.find_child("btn_Credits", true, false)
		var before: int = nova.player_credits()
		var st = _j(nova.plunder_state())
		if not cs.disabled:
			cs.pressed.emit()
			await _frames()
			_ok(nova.player_credits() == before + int(st.credits), "plunder Credits button moves exactly the loot", "%d" % (nova.player_credits() - before))
		Compose.compose(ia, VIEW, OUT + "classic_plunder.png")
		if ia._dialog != null:
			_key("ui_cancel")
			await _frames()
	nova.plunder_abort()

	# escorts window + commands panel (no escort needed to build the window)
	ia._open_escorts()
	await _frames()
	var ed = ia._dialog.find_children("*", "Control", true, false).filter(func(c): return c.has_method("focus_first"))
	_ok(ed[0].window_size.x == 424, "escorts window is the 424-wide frame (PICT 8513)", str(ed[0].window_size))
	Compose.compose(ia, VIEW, OUT + "classic_escorts.png")
	_key("ui_cancel")
	await _frames()

	# story screens
	var ss = StoryScreens.new()
	root.add_child(ss)
	ss.setup(nova)
	ss._open_text_classic({"title": "Mission", "text": "Welcome aboard, Captain. The Federation thanks you for your service.\n\nReport to the nearest spaceport.", "pict": -1})
	await _frames()
	_ok(ss._modal != null and ss._modal_kind == "text", "story text opens as the dësc reader")
	Compose.compose(ss, VIEW, OUT + "classic_storytext.png")
	ss._modal_cancel.call()
	await _frames()
	ss._open_offer_classic({"title": "Cargo run to Sol", "text": "Deliver 10 tons of food.\n\nPays 2,500 credits.", "pict": -1, "canRefuse": true, "accept": "Accept", "refuse": "Refuse", "destination": "Earth — Sol"})
	await _frames()
	_ok(ss._modal != null and ss._modal_buttons.size() == 2, "mission offer: Refuse + Accept (DITL 1016 items 1/0)")
	Compose.compose(ss, VIEW, OUT + "classic_offer.png")
	ss._modal_cancel.call_deferred()
	await _frames()
	ss._close_modal()
	ss.open_info("general")
	await _frames()
	_ok(ss._info != null and root.gui_get_focus_owner() is BaseButton, "Player Info (DITL 1017) opens with a focused tab")
	Compose.compose(ss, VIEW, OUT + "classic_playerinfo.png")
	ss.close_info()
	ss.open_info("missions")
	await _frames()
	_ok(ss._info != null, "Mission Info (DITL 1012) opens")
	Compose.compose(ss, VIEW, OUT + "classic_missioninfo.png")
	ss.close_info()
