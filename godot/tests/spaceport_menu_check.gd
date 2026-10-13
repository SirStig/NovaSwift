# Headless drive of screens/Spaceport.gd's focus navigation and input handling:
# landing screen -> Trade Center (focus, ui_down, press = buy, sell action) ->
# quantity prompt -> Outfitter (tiles, ui_right, press buys 1, sell action) ->
# Shipyard (+ info overlay) -> back with ui_cancel -> ui_cancel on the landing
# screen emits launch_requested. Run like spaceport_selfcheck.gd. Prints
# SPACEPORT MENU CHECK: PASS / FAIL.
extends SceneTree

const Spaceport = preload("res://screens/Spaceport.gd")
const Controls = preload("res://Controls.gd")
const Prefs = preload("res://Prefs.gd")
# NOVA_UI=modern drives the plain Nova Swift screens; the default is the Classic (original UI) ones.
var classic := OS.get_environment("NOVA_UI") != "modern"
var ok := true
var launches := 0


func _check(label: String, cond: bool, detail := "") -> void:
	print(("  ok   " if cond else "  FAIL ") + label + ((" — " + detail) if detail != "" else ""))
	if not cond:
		ok = false


func _key(action: String) -> void:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	root.push_input(e)


func _focus_text() -> String:
	var f = root.gui_get_focus_owner()
	return "" if f == null else (f.text if "text" in f else str(f))


func _init() -> void:
	Prefs.path = OS.get_user_data_dir() + "/menucheck_settings.cfg"
	Prefs.load_all()
	Prefs.apply_ui_mode(Prefs.UI_CLASSIC if classic else Prefs.UI_NOVA_SWIFT)
	Controls.register()
	var nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	var data := OS.get_environment("NOVA_DATA_DIR")
	if data == "":
		data = ProjectSettings.globalize_path("res://") + "../data/base"
	nova.load_game(data)
	var scen = JSON.parse_string(nova.pilot_scenarios())
	nova.pilot_create(OS.get_user_data_dir() + "/spaceport_menucheck", int(scen[0].id), "Menu Tester", true, "", "")
	nova.make_world(-1)
	nova.step(1.0 / 30.0)
	_check("land", nova.attempt_land())

	var sp = Spaceport.new()
	root.add_child(sp)
	sp.setup(nova)
	sp.launch_requested.connect(func(): launches += 1)
	sp.open()
	# This check has no story dialog layer: settle the landing offer the way a refusal would.
	if nova.offer_pending():
		nova.offer_decline()
	while nova.story_text_pending():
		nova.story_text_dismiss()
	await process_frame
	await process_frame
	var info = JSON.parse_string(nova.spaceport_info())
	print("hub: ", info.name, " focus=", _focus_text())
	_check("hub focuses a service button", root.gui_get_focus_owner() is BaseButton)

	if info.trade:
		sp._show_trade()
		await process_frame
		await process_frame
		var rows: Array = sp._trade_data.rows
		_check("trade: a row has focus", root.gui_get_focus_owner() is BaseButton and sp._trade_sel == 0)
		_key("ui_down")
		await process_frame
		_check("trade: ui_down moves to row 1", sp._trade_sel == 1, "sel=%d" % sp._trade_sel)
		var c0: int = nova.player_credits()
		var price: int = int(rows[1].price)
		if classic:
			# Classic: a row press selects (the original buys with the Buy button).
			root.gui_get_focus_owner().pressed.emit()
			await process_frame
			var buy = sp.find_child("trade_buy", true, false)
			_check("trade: Buy button is enabled for the selected row", buy != null and not buy.disabled)
			buy.pressed.emit()
		else:
			root.gui_get_focus_owner().pressed.emit()
		await process_frame
		await process_frame
		var spent: int = c0 - nova.player_credits()
		_check("trade: buying spends tons*price", spent > 0 and spent % price == 0,
			"spent %d @ %d" % [spent, price])
		_check("trade: selection kept after refresh", sp._trade_sel == 1 and root.gui_get_focus_owner() is BaseButton)
		_key("trade_sell")
		await process_frame
		await process_frame
		_check("trade: sell action sells back", nova.player_credits() == c0, "%d vs %d" % [nova.player_credits(), c0])
		_key("shop_buy_qty")
		await process_frame
		await process_frame
		_check("trade: quantity prompt opens with focus", sp._overlay != null and root.gui_get_focus_owner() is Control)
		_key("ui_down")   # -10 on the quantity box
		await process_frame
		_key("ui_cancel")
		await process_frame
		_check("trade: ui_cancel closes only the prompt", sp._overlay == null and sp._screen == "trade")
		_key("ui_cancel")
		await process_frame
		await process_frame
		_check("trade: ui_cancel returns to the landing screen", sp._screen == "hub")

	if info.outfitter:
		sp._show_outfitter()
		await process_frame
		await process_frame
		var first_id: int = sp._sel_id
		_check("outfitter: a tile has focus", root.gui_get_focus_owner() is BaseButton and first_id >= 0, _focus_text())
		_key("ui_right")
		await process_frame
		_check("outfitter: ui_right moves selection", sp._sel_id != first_id, "%d -> %d" % [first_id, sp._sel_id])
		var cc: int = nova.player_credits()
		var sel = sp._items[sp._find_item(sp._sel_id)]
		if sel.canBuy:
			root.gui_get_focus_owner().pressed.emit()
			await process_frame
			await process_frame
			_check("outfitter: pressing a tile buys one", nova.player_credits() == cc - int(sel.price))
			_key("trade_sell")
			await process_frame
			await process_frame
			_check("outfitter: sell action sells it back", nova.player_credits() == cc)
		_key("ui_cancel")
		await process_frame
		_check("outfitter: ui_cancel -> landing", sp._screen == "hub")

	if info.shipyard:
		sp._show_shipyard()
		await process_frame
		await process_frame
		_check("shipyard: a tile has focus", root.gui_get_focus_owner() is BaseButton)
		_key("ship_info")
		await process_frame
		await process_frame
		_check("shipyard: info overlay opens", sp._overlay != null)
		_key("ui_cancel")
		await process_frame
		_check("shipyard: ui_cancel closes info only", sp._overlay == null and sp._screen == "shipyard")
		_key("ui_cancel")
		await process_frame

	_check("no launch yet", launches == 0)
	_key("ui_cancel")
	await process_frame
	_check("landing screen: ui_cancel (B) requests launch", launches == 1)
	print("SPACEPORT MENU CHECK: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
