# Headless self-check for the story runtime: create a pilot, land, read the Mission
# BBS, accept a mission whose destination is in this or a neighbouring system, jump
# there, land, and check the payment and completion text arrive; also checks that
# crons/day advance on launch, and that Player Info and the Mission Info list
# marshal. Run (background it and kill after ~90 s — macOS has no `timeout`):
#   NOVA_DATA_DIR=data/base godot --headless --path godot -s res://tests/story_selfcheck.gd
# Prints STORY SELFCHECK: PASS / FAIL.
extends SceneTree

var nova
var ok := true


func _check(label: String, cond: bool, detail := "") -> bool:
	print(("  ok   " if cond else "  FAIL ") + label + ((" — " + detail) if detail != "" else ""))
	if not cond:
		ok = false
	return cond


func _init() -> void:
	nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	var data := OS.get_environment("NOVA_DATA_DIR")
	if data == "":
		data = ProjectSettings.globalize_path("res://") + "../data/base"
	var dir := OS.get_user_data_dir() + "/story_selfcheck"
	_check("load_game", nova.load_game(data))
	var scen = JSON.parse_string(nova.pilot_scenarios())
	var id := ""
	var found := false
	# The start system is random and the board small: try fresh pilots until one's
	# board holds a mission reachable in a few jumps.
	for attempt in 8:
		if id != "":
			nova.pilot_delete(dir, id)
		id = nova.pilot_create(dir, int(scen[0].id), "Story Tester", true, "", "")
		_check("pilot created", id != "")
		_check("make_world", nova.make_world(-1))
		nova.step(1.0 / 30.0)
		var r := _run_mission(nova.nav_current_system())
		if r >= 0:
			found = r == 1
			break
		print("  (attempt ", attempt + 1, ": no suitable board — new pilot)")
	_check("a deliverable mission was found and completed", found)

	nova.pilot_delete(dir, id)
	print("STORY SELFCHECK: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


func _drain_texts() -> Array:
	var out := []
	while nova.story_text_pending():
		out.append(JSON.parse_string(nova.story_text_info()))
		nova.story_text_dismiss()
	return out


# Systems within `hops` links of `sys` (breadth-first over the drawable links).
func _within(sys: int, hops: int) -> Array:
	var seen := [sys]
	var frontier := [sys]
	for _h in hops:
		var next := []
		for f in frontier:
			for n in _neighbours(f):
				if not (n in seen):
					seen.append(n)
					next.append(n)
		frontier = next
	return seen


func _neighbours(sys: int) -> Array:
	var out := []
	var links: PackedInt32Array = nova.nav_links()
	for i in range(0, links.size(), 2):
		if links[i] == sys:
			out.append(links[i + 1])
		elif links[i + 1] == sys:
			out.append(links[i])
	return out


func _find_mission(id: int):
	var ms = JSON.parse_string(nova.mission_list())
	for m in ms:
		if int(m.id) == id:
			return m
	return null


func _run_mission(start_sys: int) -> int:
	_check("landed", nova.attempt_land())
	var texts := _drain_texts()
	print("  landing texts: ", texts.size())
	# The landing offer (main spaceport lane), as Spaceport.open() rolls it.
	var roll: int = nova.offer_roll("spaceport")
	print("  spaceport lane roll -> ", roll)
	if nova.offer_pending():
		var o = JSON.parse_string(nova.offer_state())
		print("  landing offer: ", o.title, " (can refuse: ", o.canRefuse, ")")
		_check("offer has text", str(o.text) != "")
		if o.canRefuse:
			nova.offer_decline()
		else:
			nova.offer_accept()
		_drain_texts()
	var jumps: int = nova.player_jumps_remaining()
	var allowed: Array = _within(start_sys, mini(jumps, 3))
	print("  start system: ", nova.nav_system_name(start_sys), " (", start_sys, ")  jumps ", jumps, "  reachable: ", allowed.size())

	var chosen := -1
	var dest_sys := -1
	var dest_spob := -1
	var tried := {}
	for attempt in 40:
		var open = JSON.parse_string(nova.bbs_open(false))
		if attempt == 0:
			_check("BBS opens or says why", open.open or true, str(open))
		if not open.open:
			print("  BBS closed: ", open.text)
			break
		var list = JSON.parse_string(nova.bbs_list())
		if attempt == 0:
			print("  BBS offers: ", list.size())
			_check("BBS lists missions", list.size() > 0)
		var pick = null
		for m in list:
			if not tried.has(int(m.id)):
				pick = m
				break
		if pick == null:
			break
		tried[int(pick.id)] = true
		var shown: int = nova.bbs_select(int(pick.id))
		if shown != 1:
			_drain_texts()
			continue
		var offer = JSON.parse_string(nova.offer_state())
		if attempt == 0:
			_check("BBS offer has original text", str(offer.text) != "" and str(offer.title) != "",
				str(offer.title))
		var coins: int = nova.player_credits()
		if not nova.bbs_accept():
			_drain_texts()
			continue
		var t := _drain_texts()
		var ms = JSON.parse_string(nova.mission_list())
		var m = _find_mission(int(pick.id))
		if m == null:
			continue
		print("  accepted: ", m.name, " -> ", m.destination, " / ", m.system, "  [", m.objective, "]")
		if int(m.systemId) in allowed and int(m.destinationId) >= 0:
			chosen = int(pick.id)
			dest_sys = int(m.systemId)
			dest_spob = int(m.destinationId)
			break
		if m.canAbort:
			nova.mission_abort(int(pick.id))
			_drain_texts()
	if chosen < 0:
		return -1

	# The Mission Info list and Player Info marshal.
	var pi = JSON.parse_string(nova.player_info())
	_check("player info pages", pi.general.left.size() > 0 and pi.general.right.size() > 0 and str(pi.cargo) != "")

	# Launch: the visit's day ticks (crons, tribute, deadlines ride along).
	var day0: int = nova.pilot_day_number()
	_check("launch", nova.launch())
	_check("launch advanced the calendar", nova.pilot_day_number() > day0,
		"day %d -> %d (%s)" % [day0, nova.pilot_day_number(), nova.pilot_date_text()])
	_drain_texts()
	nova.drain_story_messages()
	nova.step(1.0 / 30.0)

	var legs := 0
	while dest_sys != nova.nav_current_system() and legs < 4:
		nova.nav_refresh()
		if legs == 0:
			_check("course plotted to the destination system", nova.nav_plot_course(dest_sys), nova.nav_system_name(dest_sys))
		if not _jump_once():
			print("  jump failed")
			return 0
		legs += 1
		_drain_texts()
	_check("arrived", nova.nav_current_system() == dest_sys, "%d jump(s)" % legs)
	_check("mission survives the jump", _find_mission(chosen) != null)

	# Set down on the destination's pad and land: completion pays and tells.
	var credits0: int = nova.player_credits()
	_check("placed at destination stellar", nova.debug_place_player_at_spob(dest_spob))
	nova.step(1.0 / 30.0)
	_check("land at destination", nova.attempt_land())
	var comp := _drain_texts()
	var m2 = _find_mission(chosen)
	print("  completion texts: ", comp.size(), "  credits ", credits0, " -> ", nova.player_credits())
	for t in comp:
		print("    [", t.title, "] ", str(t.text).substr(0, 90).replace("\n", " "))
	_check("mission completed (gone from the active list)", m2 == null or str(m2.objective).begins_with("Report"),
		str(m2))
	_check("payment received", nova.player_credits() > credits0)
	_check("completion text shown", comp.size() > 0)
	return 1


# Fly the real jump, as NavScreens' selftest does.
func _jump_once() -> bool:
	var tries := 0
	while tries < 3000:
		nova.set_intent(false, false, true, false, false, false, false)
		nova.step(1.0 / 30.0)
		tries += 1
		if tries % 15 == 0:
			nova.begin_hyperjump()
			if nova.hyperjump_active():
				break
	if not nova.hyperjump_active():
		return false
	var ticks := 0
	while nova.hyperjump_active() and ticks < 6000:
		nova.set_intent(false, false, false, false, false, false, false)
		nova.step(1.0 / 30.0)
		ticks += 1
	return nova.take_jump_arrival() != ""
