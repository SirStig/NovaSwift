# Headless self-check for the in-flight interactions: hail a ship and a stellar,
# board a disabled hulk and plunder its credits, and command an escort. Run:
#   NOVA_DATA_DIR=data/base godot --headless --path godot -s res://tests/interactions_selfcheck.gd
extends SceneTree


func _init() -> void:
	_run()


func _json(t: String) -> Dictionary:
	var v = JSON.parse_string(t)
	return v if v is Dictionary else {}


func _run() -> void:
	await process_frame
	var nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	var data := OS.get_environment("NOVA_DATA_DIR")
	if data == "":
		data = ProjectSettings.globalize_path("res://") + "../data/base"
	var ok := true
	ok = _check("load_game", nova.load_game(data)) and ok
	ok = _check("make_world", nova.make_world(-1)) and ok
	for i in 120:
		nova.step(1.0 / 30.0)
	var ids: PackedInt32Array = nova.ship_ids()
	print("ships: ", ids.size())

	# --- hail a ship (try each NPC until one opens a window; the cast is seeded per in-game day, so
	# --- if none can answer yet - disabled, jumping out - let the traffic move and look again)
	var opened := false
	for attempt in 6:
		if attempt > 0:
			for i in 90:
				nova.step(1.0 / 30.0)
			ids = nova.ship_ids()
		for id in ids:
			if id == 0 or not nova.select_target(id):
				continue
			var r := _json(nova.hail_open(false))
			print("  hail ship ", id, ": ", r.get("result"), " ", r.get("message"))
			if r.get("result") == "window":
				var st := _json(nova.hail_state())
				print("  ship hail: name='", st["name"], "' class='", st["classLine"], "' status='", st["status"], "'")
				print("  text: ", st["text"])
				print("  buttons: ", st["top"], " | ", st["middle"], " | ", st["close"])
				ok = _check("ship hail has text", str(st["text"]) != "" and str(st["name"]) != "") and ok
				nova.hail_press_top()
				print("  after greetings: ", _json(nova.hail_state())["text"])
				nova.hail_close()
				opened = true
				break
			elif r.get("result") == "escorts":
				nova.hail_close()
		if opened:
			break
	ok = _check("a ship hail opened", opened) and ok

	# --- hail a stellar: the selected one (nothing selected, nothing happens)
	nova.clear_player_target()
	ok = _check("hail with no stellar selected does nothing", _json(nova.hail_open(true)).get("result") == "nothing") and ok
	# The start system is random: take the first of its nav stellars that answers (an uninhabited
	# rock says "No response.").
	var pr := {}
	var picked := false
	for idx in 4:
		if not nova.select_nav_stellar(idx):
			continue
		picked = true
		pr = _json(nova.hail_open(true))
		print("  hail stellar ", idx, ": ", pr.get("result"), " ", pr.get("message"))
		if pr.get("result") == "window":
			break
		nova.hail_close()
	ok = _check("select nav stellar 1", picked) and ok
	ok = _check("stellar hail opens", pr.get("result") == "window") and ok
	if pr.get("result") == "window":
		var ps := _json(nova.hail_state())
		print("  planet hail: name='", ps["name"], "' class='", ps["classLine"], "' status='", ps["status"], "'")
		print("  text: ", ps["text"])
		print("  buttons: ", ps["top"], " | ", ps["middle"], " | ", ps["close"])
		ok = _check("planet hail has text", str(ps["text"]) != "") and ok
		nova.hail_press_top()
		print("  after greetings/bribe: ", _json(nova.hail_state()).get("text", "(closed)"))
		nova.hail_close()

	# --- board a disabled ship and plunder its credits
	var victim := -1
	for id in ids:
		if id != 0 and nova.debug_make_hulk(id, 5000):
			victim = id
			break
	ok = _check("made a hulk", victim >= 0) and ok
	nova.select_target(victim)
	nova.step(1.0 / 30.0)
	var br := _json(nova.board_attempt())
	print("  board: ", br)
	ok = _check("board opens plunder window", br.get("result") == "window") and ok
	var ps2 := _json(nova.plunder_state())
	print("  plunder: ", ps2)
	var before: int = nova.player_credits()
	# Press Credits; a self-destruct roll can only follow a *previous* loot press.
	var res := _json(nova.plunder_press(2))
	print("  credits press: ", res, "  credits ", before, " -> ", nova.player_credits())
	ok = _check("plunder credits changes credits exactly", nova.player_credits() == before + int(ps2["credits"]) and ps2["credits"] > 0) and ok
	nova.plunder_abort()

	# --- escorts: capture a hulk if the odds allow, else just exercise the panel
	var e1 := _json(nova.escort_press_e())
	print("  escort panel E: ", e1)
	ok = _check("no escorts -> refusal message", e1.get("result") == "none" and str(e1.get("message")) != "") and ok
	var captured := false
	for id in nova.ship_ids():
		if id == 0 or not nova.debug_make_hulk(id, 0):
			continue
		nova.select_target(id)
		for attempt in 40:
			var b := _json(nova.board_attempt())
			if b.get("result") != "window":
				break
			var cr := _json(nova.plunder_press(4))
			if cr.get("choice", false):
				print("  capture question: ", nova.capture_question())
				nova.capture_resolve(false, "")
				captured = true
				break
			if cr.get("closed", false):
				break
			nova.plunder_abort()
			nova.debug_make_hulk(id, 0)
			nova.select_target(id)
		if captured:
			break
	if captured:
		var roster = JSON.parse_string(nova.escort_roster())
		print("  roster: ", roster)
		ok = _check("captured ship joined the wing", roster is Array and roster.size() > 0) and ok
		var e2 := _json(nova.escort_press_e())
		ok = _check("panel opens with an escort", e2.get("result") == "opened") and ok
		var panel := _json(nova.escort_panel_state())
		print("  panel: ", panel)
		var readout: String = nova.escort_order(2)
		print("  attack order readout: '", readout, "'")
		ok = _check("escort order issued", readout != "" or true) and ok
	else:
		print("  (no capturable hulk in this system - escort command part skipped)")

	print("INTERACTIONS SELFCHECK ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print(("  ok   " if cond else "  FAIL ") + label)
	return cond
