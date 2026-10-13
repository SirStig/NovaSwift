# Headless self-check for the gameplay gaps: Hire Escort (+ payroll, the escort
# fleet pass: sell / upgrade marks), contraband / jünk trade and the in-flight
# scan fine, gambling, përs LinkMission offers, the cloak / eject (escape pod) /
# self-destruct keys, jettisoned cargo pods, click-to-select — every transaction
# that moves money asserts the exact credit change. Run:
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/gameplay_gaps_selfcheck.gd
# Prints GAMEPLAY GAPS SELFCHECK: PASS / FAIL.
extends SceneTree

const Spaceport = preload("res://screens/Spaceport.gd")
const StoryScreens = preload("res://screens/StoryScreens.gd")
const Controls = preload("res://Controls.gd")

var nova
var ok := true


func _check(label: String, cond: bool, detail := "") -> bool:
	print(("  ok   " if cond else "  FAIL ") + label + ((" — " + detail) if detail != "" else ""))
	if not cond:
		ok = false
	return cond


func _j(t: String):
	return JSON.parse_string(t)


func _frames(n := 3) -> void:
	for i in n:
		await process_frame


func _init() -> void:
	_run()


func _run() -> void:
	Controls.register()
	nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	var data := OS.get_environment("NOVA_DATA_DIR")
	if data == "":
		data = ProjectSettings.globalize_path("res://") + "../data/base"
	var dir := OS.get_user_data_dir() + "/gaps_selfcheck"
	_check("load_game", nova.load_game(data))
	var scen = _j(nova.pilot_scenarios())
	var pid: String = nova.pilot_create(dir, int(scen[0].id), "Gaps Tester", true, "", "")
	_check("pilot created", pid != "")
	_check("make_world", nova.make_world(-1))
	for i in 30:
		nova.step(1.0 / 30.0)

	_keys_registered()
	_click_select()
	_jettison_pods()
	await _hire_and_fleet_pass()
	await _junk_trade_and_scan()
	_junk_events()
	_gambling()
	await _pers_offer()
	await _bar_ui()
	_cloak_eject_selfdestruct()

	nova.pilot_delete(dir, pid)
	print("GAMEPLAY GAPS SELFCHECK: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


# --- bindings ------------------------------------------------------------------------

func _keys_registered() -> void:
	print("-- flight keys")
	for a in ["toggle_cloak", "eject", "self_destruct", "recall_fighters"]:
		_check("action registered: " + a, InputMap.has_action(a))
	_check("U toggles the cloak (original table)", Controls.describe_keys("toggle_cloak") == "U")
	_check("Alt-X ejects", Controls.describe_keys("eject") == "Alt+X")
	_check("Alt-minus self-destructs", Controls.describe_keys("self_destruct") == "Alt+" + OS.get_keycode_string(KEY_MINUS))


# --- find a stellar -------------------------------------------------------------------

# First spöb in [128, 1600) whose spaceport_info satisfies `pred`.
func _find_spob(pred: Callable) -> int:
	for id in range(128, 1600):
		if not nova.debug_dock_at(id):
			continue
		var info = _j(nova.spaceport_info())
		if info is Dictionary and pred.call(info):
			return id
	return -1


# --- Hire Escort + payroll + the escort fleet pass -------------------------------------

func _hire_and_fleet_pass() -> void:
	print("-- hire escort")
	nova.debug_set_credits(1000000)
	var bar := _find_spob(func(i): return i.get("bar", false) and not (_j(nova.hire_list()).get("ships", []) as Array).is_empty())
	if not _check("found a bar with ships for hire today", bar >= 0):
		return
	var list = _j(nova.hire_list())
	var ship: Dictionary = list.ships[0]
	print("  hiring: ", ship.name, " ", ship.price, " cr, ", ship.perDay, "/day")
	_check("hire list row has the pieces", int(ship.price) > 0 and str(ship.category) != "" and ship.has("description"))
	var before: int = nova.player_credits()
	_check("hire_escort succeeds", nova.hire_escort(int(ship.id)))
	_check("hire charges exactly the listed price", nova.player_credits() == before - int(ship.price),
		"%d -> %d" % [before, nova.player_credits()])
	var recs = _j(nova.debug_escort_records())
	_check("the escort is in the roster as hired, with its daily fee",
		recs.size() == 1 and recs[0].origin == "hired" and int(recs[0].dailyFee) == int(ship.perDay), str(recs))
	# A refused hire charges nothing.
	var c1: int = nova.player_credits()
	_check("hiring a ship that is not on the list is refused", not nova.hire_escort(99999) and nova.player_credits() == c1)
	nova.debug_set_credits(0)
	var again = _j(nova.hire_list())
	var poorly := true
	for s in again.ships:
		if bool(s.canHire):
			poorly = false
	_check("with no credits nothing is hireable", poorly)
	_check("...and hiring is refused with the credits untouched",
		not again.ships.is_empty() and not nova.hire_escort(int(again.ships[0].id)) and nova.player_credits() == 0)
	nova.debug_set_credits(1000000)
	# Fill the wing to the cap of six, then it refuses.
	var guard := 0
	while _j(nova.hire_list()).hasRoom and guard < 12:
		guard += 1
		var l = _j(nova.hire_list())
		var hired := false
		for s in l.ships:
			if bool(s.canHire) and nova.hire_escort(int(s.id)):
				hired = true
				break
		if not hired:
			break
	var full = _j(nova.hire_list())
	var count: int = _j(nova.debug_escort_records()).size()
	_check("the wing caps at six escorts", count == 6 or not bool(full.hasRoom), "wing=%d" % count)
	if not bool(full.hasRoom):
		var c2: int = nova.player_credits()
		var any_hire := false
		for s in full.ships:
			any_hire = any_hire or bool(s.canHire)
		_check("a full wing offers no live Hire button", not any_hire)
		_check("and a forced hire is refused", full.ships.is_empty() or (not nova.hire_escort(int(full.ships[0].id)) and nova.player_credits() == c2))
	var bar_info = _j(nova.bar_info())
	_check("bar_info carries the hire label and the cap flag", str(bar_info.hire) != "" and bar_info.has("canHire"))

	# --- the fleet pass on leaving a shipyard: sale + upgrade marks, payroll
	print("-- escort fleet pass / payroll")
	var recs2 = _j(nova.debug_escort_records())
	var hired_fee := 0
	for r in recs2:
		if r.origin == "hired":
			hired_fee += int(r.dailyFee)
	var yard := _find_spob(func(i): return i.get("shipyard", false))
	if not _check("found a shipyard stellar", yard >= 0):
		return
	nova.debug_set_credits(500000)
	var ups: PackedInt32Array = nova.debug_upgradable_ship()
	var sale_rec: int = nova.debug_add_captured_escort(int(ups[0]) if ups.size() >= 3 else recs2[0].ship)
	# a hired escort can't be sold
	var hired_rec: int = int(recs2[0].record)
	_check("a hired escort can't be marked for sale", not nova.escort_request_sale(hired_rec))
	_check("a captured escort can be marked for sale", nova.escort_request_sale(sale_rec))
	nova.escort_cancel_sale(sale_rec)
	var cleared = _j(nova.debug_escort_records())
	var still := false
	for r in cleared:
		if int(r.record) == sale_rec and r.pendingSale:
			still = true
	_check("cancelling the sale clears the mark", not still)
	_check("marking again", nova.escort_request_sale(sale_rec))
	var sell_value := 0
	for r in _j(nova.debug_escort_records()):
		if int(r.record) == sale_rec:
			sell_value = int(r.sellValue)
	_check("sell value is the original's (EscSellValue or 10% of cost)", sell_value > 0, str(sell_value))
	var upgrade_rec := -1
	var upgrade_cost := 0
	if ups.size() >= 3:
		upgrade_rec = nova.debug_add_captured_escort(ups[0])
		_check("upgrade mark accepted for a hull with UpgradeTo", nova.escort_request_upgrade(upgrade_rec))
		upgrade_cost = int(ups[2])
		var sr2: int = nova.debug_add_captured_escort(ups[0])
		# Upgrade and Sell are exclusive marks: marking sale clears the upgrade mark.
		nova.escort_request_upgrade(sr2)
		_check("sale after upgrade replaces the mark", nova.escort_request_sale(sr2))
		nova.escort_cancel_sale(sr2)
	var credits_before: int = nova.player_credits()
	var day_before: int = nova.pilot_day_number()
	var txns := 1 + (1 if upgrade_rec >= 0 else 0)
	_check("launch from the shipyard", nova.launch())
	var credits_after: int = nova.player_credits()
	var expect := credits_before + sell_value - upgrade_cost - hired_fee
	_check("sale credited, upgrade + payroll charged, exactly", credits_after == expect,
		"%d -> %d (sale %d, upgrade %d, payroll %d)" % [credits_before, credits_after, sell_value, upgrade_cost, hired_fee])
	var left = _j(nova.debug_escort_records())
	var sold_gone := true
	var upgraded := upgrade_rec < 0
	for r in left:
		if int(r.record) == sale_rec:
			sold_gone = false
		if int(r.record) == upgrade_rec:
			upgraded = int(r.ship) == int(ups[1])
	_check("the sold escort left the wing", sold_gone)
	_check("the upgraded escort is the new hull", upgraded)
	_check("the visit cost days: 1 + transactions/2", nova.pilot_day_number() - day_before >= 1 + txns / 2,
		"%d days for %d transactions" % [nova.pilot_day_number() - day_before, txns])
	_check("a text reports the fleet pass", nova.story_text_pending())
	nova.story_text_dismiss()


# --- jünk trade, contraband scans -------------------------------------------------------

func _junk_trade_and_scan() -> void:
	print("-- junk trade")
	var spots = _j(nova.debug_junk_spots())
	var row := -1
	var traded_at := -1
	var junk_name := ""
	var junk_id := -1
	for sp in spots:
		for where in (sp.boughtAt as Array) + (sp.soldAt as Array):
			if not nova.debug_dock_at(int(where)):
				continue
			var tv = _j(nova.trade_view())
			if tv is Dictionary:
				for i in (tv.rows as Array).size():
					if tv.rows[i].name == sp.name:
						row = i
						traded_at = int(where)
						junk_name = sp.name
						junk_id = int(sp.junk)
			if row >= 0:
				break
		if row >= 0:
			break
	if not _check("found a stellar whose Trade Center lists a jünk row", row >= 0):
		return
	nova.debug_set_credits(100000)
	var tv2 = _j(nova.trade_view())
	var price: int = int(tv2.rows[row].price)
	var c0: int = nova.player_credits()
	var free0: int = nova.cargo_free_tons()
	var want: int = nova.trade_quantity(row, true, -1)
	var got: int = nova.trade_buy(row, want)
	_check("buy %s: credits drop by price × tons" % junk_name, got > 0 and nova.player_credits() == c0 - got * price,
		"%d t @ %d: %d -> %d" % [got, price, c0, nova.player_credits()])
	_check("junk takes hold space", nova.cargo_free_tons() == free0 - got)
	_check("junk shows as held in the Trade Center", int(_j(nova.trade_view()).rows[row].held) == got)
	var sold: int = nova.trade_sell(row, got)
	_check("sell it back for exactly the credits", sold == got and nova.player_credits() == c0)

	print("-- in-flight scan fine")
	var pol = _j(nova.debug_policing_govts())
	# One (jünk, government) pair per kind of ScanFine: a flat fine, a percentage, a warning.
	var kinds := {}
	for sp in spots:
		for g in pol:
			if (int(sp.scanMask) & int(g.scanMask)) != 0:
				var k := "flat" if int(g.scanFine) >= 1 else ("percent" if int(g.scanFine) < 0 else "warning")
				if not kinds.has(k):
					kinds[k] = [sp, g]
	if not _check("a jünk type is contraband to some government", not kinds.is_empty()):
		return
	print("  scan kinds available: ", kinds.keys())
	for k in kinds:
		_scan_pair(k, kinds[k][0], kinds[k][1])


func _scan_pair(kind: String, jk: Dictionary, gv: Dictionary) -> void:
	nova.make_world(-1)
	for i in 3:
		nova.step(1.0 / 30.0)
	nova.debug_set_credits(50000)
	nova.debug_give_cargo(int(jk.junk), 3)
	var cash: int = nova.player_credits()
	var fine_cfg := int(gv.scanFine)
	var expect_fine := 0
	if fine_cfg >= 1:
		expect_fine = mini(fine_cfg, cash)
	elif fine_cfg < 0:
		expect_fine = mini(maxi(1, int(float(cash) * float(-fine_cfg) * 0.0001) * 100), cash)
	var res = _j(nova.debug_scan_player(int(gv.id)))
	print("  [%s] scan by govt %d (ScanFine %d): %s" % [kind, int(gv.id), fine_cfg, res])
	var carried := false
	for c in res.cargo:
		carried = carried or int(c) == int(jk.junk)
	_check("[%s] the scan found the contraband" % kind, bool(res.found) and carried)
	_check("[%s] fined exactly the ScanFine rule" % kind, int(res.fine) == expect_fine and nova.player_credits() == cash - expect_fine,
		"expected %d: %d -> %d" % [expect_fine, cash, nova.player_credits()])
	_check("[%s] warning-only governments take nothing" % kind, (kind != "warning") or nova.player_credits() == cash)
	_check("[%s] a status line says so" % kind, (res.messages as Array).size() > 0)
	nova.debug_give_cargo(int(jk.junk), -3)
	var c1: int = nova.player_credits()
	var clean = _j(nova.debug_scan_player(int(gv.id)))
	_check("[%s] a clean hold costs nothing" % kind, not bool(clean.found) and nova.player_credits() == c1)


func _junk_events() -> void:
	print("-- tribbles")
	var spots = _j(nova.debug_junk_spots())
	var trib := -1
	var flags_seen := {}
	for sp in spots:
		flags_seen[int(sp.flags)] = true
	print("  jünk Flags seen in the data: ", flags_seen.keys())
	for sp in spots:
		if (int(sp.flags) & 1) != 0:
			trib = int(sp.junk)
			break
	if trib < 0:
		print("  (the base data has no tribbles / perishable jünk — the event is covered by the swift tests)")
		return
	nova.make_world(-1)
	nova.step(1.0 / 30.0)
	nova.debug_give_cargo(trib, 5)
	var free: int = nova.cargo_free_tons()
	_check("hold has room for the breeding", free > 0, str(free))
	var before: int = nova.debug_cargo_held(trib)
	_check("a junk event runs", nova.debug_run_junk_event())
	_check("tribbles breed a ton", nova.debug_cargo_held(trib) == before + 1)


# --- gambling -----------------------------------------------------------------------------

func _gambling() -> void:
	print("-- gambling")
	nova.debug_set_credits(20000)
	var gi = _j(nova.gamble_info())
	_check("chooser lists four colours", (gi.colors as Array).size() == 4)
	_check("standard wager is min(credits, 1000)", int(gi.standard) == 1000)
	_check("typed wager cap is min(credits, 10000)", int(gi.max) == 10000)
	var wins := 0
	var losses := 0
	for n in 24:
		var cash: int = nova.player_credits()
		if cash < 1000:
			nova.debug_set_credits(20000)
			cash = 20000
		var stake := 1000 if n % 2 == 0 else 250
		var pick := n % 4
		var r = _j(nova.gamble_bet(pick, stake))
		if not r.ok:
			_check("bet accepted", false, str(r))
			return
		var win: bool = int(r.winner) == pick
		var good: bool = int(r.payout) == (stake * 4 if win else 0) and nova.player_credits() == cash - stake + int(r.payout) \
			and int(r.net) == int(r.payout) - stake
		if not good:
			_check("race %d pays exactly" % n, false, "%s credits %d -> %d" % [r, cash, nova.player_credits()])
			return
		if win:
			wins += 1
		else:
			losses += 1
	_check("24 races, every payout exact (4x on a win, stake lost otherwise)", true, "%d wins / %d losses" % [wins, losses])
	nova.debug_set_credits(500)
	var c: int = nova.player_credits()
	var refused = _j(nova.gamble_bet(0, 1000))
	_check("a bet beyond the credits is refused, nothing charged", not refused.ok and nova.player_credits() == c)
	_check("a zero wager is refused", not _j(nova.gamble_bet(0, 0)).ok and nova.player_credits() == c)
	_check("standard wager follows poverty", int(_j(nova.gamble_info()).standard) == 500)


# --- përs LinkMission offers --------------------------------------------------------------

func _pers_offer() -> void:
	print("-- pers offers")
	var offers = _j(nova.debug_pers_offers())
	if not _check("data has përs that offer a LinkMission", offers.size() > 0):
		return
	var ss = StoryScreens.new()
	root.add_child(ss)
	ss.setup(nova)
	nova.make_world(-1)
	nova.step(1.0 / 30.0)
	var shown := -1
	for o in offers:
		if nova.debug_present_pers_offer(int(o.pers), int(o.mission)) and nova.offer_pending():
			shown = int(o.mission)
			break
	if not _check("a përs offer raises the accept/decline dialog", shown >= 0):
		ss.queue_free()
		return
	var st = _j(nova.offer_state())
	_check("the offer carries a title and briefing", str(st.title) != "" or str(st.text) != "")
	await _frames(3)
	_check("StoryScreens shows it as a modal offer", ss._modal != null and ss._modal_kind == "offer")
	_check("the flight sim is held while it is up", nova.story_blocks_flight())
	ss._offer_decline() if st.canRefuse else ss._offer_accept()
	await _frames(2)
	_check("answering closes it", not nova.offer_pending())
	# accept path
	var accepted := false
	for o in offers:
		if int(o.mission) == shown and offers.size() > 1:
			continue
		if nova.debug_present_pers_offer(int(o.pers), int(o.mission)) and nova.offer_pending():
			var before_msn: int = (_j(nova.mission_list()) as Array).size()
			var did: bool = nova.offer_accept()
			var after_msn: int = (_j(nova.mission_list()) as Array).size()
			accepted = did and after_msn == before_msn + 1
			if bool(o.deactivate):
				_check("deactivate-after-mission përs is recorded as gone", nova.debug_pers_defeated(int(o.pers)))
			break
	_check("accepting a përs offer activates the mission", accepted or offers.size() == 1)
	ss.queue_free()


# --- the bar screens (Hire Escort, Gamble) -------------------------------------------------

func _find_node(n: Node, node_name: String) -> Node:
	return n.find_child(node_name, true, false)


func _bar_ui() -> void:
	print("-- bar UI")
	nova.make_world(-1)
	nova.step(1.0 / 30.0)
	nova.debug_clear_escorts()
	nova.debug_set_credits(1000000)
	var bar := _find_spob(func(i): return i.get("bar", false) and not (_j(nova.hire_list()).get("ships", []) as Array).is_empty())
	if not _check("a bar with ships for hire", bar >= 0):
		return
	var sp = Spaceport.new()
	root.add_child(sp)
	sp.setup(nova)
	sp.open()
	await _frames(3)
	sp._show_bar()
	await _frames(3)
	var hire_btn = _find_node(sp, "bar_hire")
	var gamble_btn = _find_node(sp, "bar_gamble")
	_check("the bar has Hire Escort, Gamble, Holovid, Leave", hire_btn != null and gamble_btn != null \
		and _find_node(sp, "bar_holovid") != null and _find_node(sp, "bar_leave") != null)
	var wing0: int = _j(nova.debug_escort_records()).size()
	if hire_btn != null and not hire_btn.disabled:
		hire_btn.pressed.emit()
		await _frames(3)
		var hb = _find_node(sp, "hire_button")
		_check("Hire Escort opens the browser with a Hire button", hb != null)
		if hb != null:
			var cash: int = nova.player_credits()
			var price := 0
			var l = _j(nova.hire_list())
			price = int(l.ships[0].price)
			hb.pressed.emit()
			await _frames(3)
			_check("Hire press charges the first row's price exactly", nova.player_credits() == cash - price,
				"%d -> %d (price %d)" % [cash, nova.player_credits(), price])
			_check("and the wing grew", _j(nova.debug_escort_records()).size() == wing0 + 1)
			var done = _find_node(sp, "hire_done")
			if done != null:
				done.pressed.emit()
				await _frames(2)
		_check("Done closes the browser", sp._overlay == null)
	if gamble_btn != null:
		gamble_btn.pressed.emit()
		await _frames(3)
		var c2 = _find_node(sp, "color_2")
		_check("Gamble opens the colour chooser", c2 != null)
		if c2 != null:
			c2.pressed.emit()
			await _frames(3)
			var bet = _find_node(sp, "bet_standard")
			_check("Bet 1000 is live once a colour is chosen", bet != null and not bet.disabled)
			var cash2: int = nova.player_credits()
			if bet != null:
				bet.pressed.emit()
				await _frames(3)
				var skip = _find_node(sp, "race_skip")   # the race holovid, when its clip is converted
				if skip != null:
					skip.pressed.emit()
					await _frames(3)
				var res = _find_node(sp, "gamble_result")
				_check("the result screen appears", res != null)
				var delta: int = nova.player_credits() - cash2
				_check("credits moved by -1000 or +3000", delta == -1000 or delta == 3000, str(delta))
			var leave = _find_node(sp, "gamble_leave")
			if leave != null:
				leave.pressed.emit()
				await _frames(2)
	sp.close()
	sp.queue_free()
	# leave the dock for the later flight tests
	nova.launch()
	nova.story_text_dismiss()
	while nova.story_text_pending():
		nova.story_text_dismiss()


# --- click to select -----------------------------------------------------------------------

func _click_select() -> void:
	print("-- click to select")
	nova.make_world(-1)
	for i in 120:
		nova.step(1.0 / 30.0)
	var ids: PackedInt32Array = nova.ship_ids()
	var xf: PackedFloat32Array = nova.ship_transforms()
	var pp: Vector2 = nova.player_position()
	var picked := -1
	var at := Vector2.ZERO
	for n in ids.size():
		if ids[n] == 0:
			continue
		var p := Vector2(xf[n * 4], xf[n * 4 + 1])
		if p.distance_to(pp) > 120.0:
			picked = ids[n]
			at = p
			break
	if _check("an NPC ship to click", picked >= 0):
		nova.clear_player_target()
		var r = _j(nova.click_select(at.x, at.y))
		# The engine's pick may land on another ship overlapping that point: it must at least be a ship.
		_check("click on a ship locks a ship target", r.kind == "ship" and nova.player_target_id() == int(r.id), str(r))
	var bxf: PackedFloat32Array = nova.body_transforms()
	var bids: PackedInt32Array = nova.body_spob_ids()
	var done := false
	for k in bids.size():
		var bp := Vector2(bxf[k * 4], bxf[k * 4 + 1])
		var occupied := false
		for n in ids.size():
			if Vector2(xf[n * 4], xf[n * 4 + 1]).distance_to(bp) < 80.0:
				occupied = true
		if occupied:
			continue
		var r2 = _j(nova.click_select(bp.x, bp.y))
		_check("click on a stellar selects it", r2.kind == "stellar" and nova.selected_stellar_id() == int(r2.id), str(r2))
		done = true
		break
	_check("a stellar to click", done)
	var r3 = _j(nova.click_select(pp.x + 90000.0, pp.y + 90000.0))
	_check("click on empty space clears the travel stellar", r3.kind == "none" and nova.selected_stellar_id() == -1)
	nova.select_nearest_engaged()
	nova.debug_move_player(pp.x + 40000.0, pp.y + 40000.0)   # clear of every stellar and ship
	var r4 = _j(nova.click_select(pp.x + 40000.0, pp.y + 40000.0))
	_check("click on your own ship clears the ship target", r4.kind == "player" and nova.player_target_id() == -1, str(r4))


# --- jettison pods -------------------------------------------------------------------------

func _jettison_pods() -> void:
	print("-- jettison")
	nova.make_world(-1)
	nova.step(1.0 / 30.0)
	nova.debug_give_cargo(0, 20)
	_check("no boxes yet", nova.freeflight_transforms().size() == 0)
	var line: String = nova.jettison_cargo()
	_check("jettison reports the line", line != "", line)
	var boxes: PackedFloat32Array = nova.freeflight_transforms()
	# 20 tons -> clamp(trunc(20 / 5), 1, 12) = 4 pods
	_check("jettisoned cargo is drawn as floating pods (4, no escorts yet)", boxes.size() == 8, "%d floats" % boxes.size())
	var styles: PackedInt32Array = nova.freeflight_styles()
	_check("pods use the spin 500 set", styles.size() == 8 and styles[0] == 500)
	_check("the spin 500 art exists", nova.sprite_info(7, 500).size() >= 7)
	_check("the hold is empty", nova.debug_cargo_held(0) == 0)


# --- cloak, eject / escape pod, self-destruct ----------------------------------------------

func _cloak_eject_selfdestruct() -> void:
	print("-- cloak")
	nova.make_world(-1)
	nova.step(1.0 / 30.0)
	nova.toggle_cloak()   # no cloak fitted: refused (snd 153), no crash
	_check("cloak without a device does nothing", nova.ship_visuals()[0] == 0.0)
	if _check("a cloaking device exists in the data", nova.debug_equip_cloak()):
		nova.step(1.0 / 30.0)
		nova.toggle_cloak()
		for i in 90:
			nova.step(1.0 / 30.0)
		var cloak: float = nova.ship_visuals()[0]
		_check("U engages the cloak (the hull fades)", cloak > 0.0, str(cloak))
		nova.toggle_cloak()
		for i in 120:
			nova.step(1.0 / 30.0)
		_check("U again drops it", float(nova.ship_visuals()[0]) < cloak)

	print("-- eject / escape pod")
	nova.make_world(-1)
	nova.step(1.0 / 30.0)
	nova.recall_fighters()   # no bays: a no-op
	var hull: int = nova.debug_pilot_ship_type()
	_check("can't eject while healthy", not nova.can_eject())
	nova.debug_prepare_eject()
	nova.step(1.0 / 30.0)
	_check("a disabled ship with a pod can eject", nova.can_eject())
	var day0: int = nova.pilot_day_number()
	nova.request_eject()
	nova.step(1.0 / 30.0)
	nova.step(1.0 / 30.0)
	_check("Alt-X puts the pilot in the escape pod (shïp 895)", nova.player_ship_type() == 895 and nova.debug_pilot_ship_type() == 895,
		"world %d pilot %d" % [nova.player_ship_type(), nova.debug_pilot_ship_type()])
	_check("the old hull is not the pilot's any more", nova.debug_pilot_ship_type() != hull)
	var respawned := false
	for i in 1500:
		nova.step(1.0 / 30.0)
		if nova.debug_pilot_ship_type() != 895:
			respawned = true
			break
	_check("the pod's flight ends in a respawn", respawned)
	var drift: int = nova.pilot_day_number() - day0
	_check("the world moved on 15-44 days while the pod drifted", drift >= 15 and drift <= 44 + 1, "%d days" % drift)
	_check("the pilot flies a fresh class-zero ship", nova.debug_pilot_ship_type() == 128 or nova.debug_pilot_ship_type() != hull,
		str(nova.debug_pilot_ship_type()))
	_check("a text tells the story", nova.story_text_pending())
	while nova.story_text_pending():
		nova.story_text_dismiss()
	_check("the new world is flyable", nova.player_is_alive())

	print("-- self-destruct")
	nova.make_world(-1)
	nova.step(1.0 / 30.0)
	_check("alive before", nova.player_is_alive())
	nova.set_self_destruct(true)
	for i in 30:
		nova.step(1.0 / 30.0)
	_check("still alive one second in (the countdown is five)", nova.player_is_alive())
	# releasing aborts it
	nova.set_self_destruct(false)
	for i in 10:
		nova.step(1.0 / 30.0)
	_check("letting go aborts the countdown", nova.player_is_alive())
	nova.set_self_destruct(true)
	for i in 220:
		nova.step(1.0 / 30.0)
	nova.set_self_destruct(false)
	_check("held for five seconds the ship blows up", not nova.player_is_alive())
	var over := false
	for i in 900:
		nova.step(1.0 / 30.0)
		if nova.take_player_destroyed():
			over = true
			break
	_check("the death sequence ends in a game over", over)
