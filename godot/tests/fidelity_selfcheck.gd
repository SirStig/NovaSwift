# Headless check for the Godot fidelity pass: the original's key table, the selected
# stellar (and landing on it, not on the nearest), landing refusal + bribe, hypergate
# travel, the map's Find, the staggered death-burst sounds, and escort damage carried
# across a jump but refilled by a launch. Run:
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/fidelity_selfcheck.gd
extends SceneTree

const Controls = preload("res://Controls.gd")

var nova
var ok := true


func _init() -> void:
	_run()


func _json(t: String):
	return JSON.parse_string(t)


func _check(label: String, cond: bool) -> bool:
	print(("  ok   " if cond else "  FAIL ") + label)
	if not cond:
		ok = false
	return cond


func _key(code: int, alt := false, shift := false) -> InputEventKey:
	var e := InputEventKey.new()
	e.physical_keycode = code
	e.alt_pressed = alt
	e.shift_pressed = shift
	e.pressed = true
	return e


func _is(e: InputEvent, action: String) -> bool:
	return InputMap.event_is_action(e, action)


func _run() -> void:
	await process_frame
	nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	var data := OS.get_environment("NOVA_DATA_DIR")
	if data == "":
		data = ProjectSettings.globalize_path("res://") + "../data/base"
	_check("load_game", nova.load_game(data))
	_check("make_world", nova.make_world(-1))

	_test_keys()
	_test_planet_select_and_land()
	_test_refusal_and_bribe()
	_test_gate()
	_test_find()
	_test_death_bursts()
	_test_escorts()

	print("FIDELITY SELFCHECK ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


# --- 1. the original's keys -----------------------------------------------------

func _test_keys() -> void:
	print("-- keys")
	Controls.layout = Controls.LAYOUT_ORIGINAL
	Controls.reset_defaults()
	Controls.register()
	_check("Z = afterburner", _is(_key(KEY_Z), "afterburner"))
	_check("arrows fly", _is(_key(KEY_UP), "thrust") and _is(_key(KEY_DOWN), "reverse")
		and _is(_key(KEY_LEFT), "turn_left") and _is(_key(KEY_RIGHT), "turn_right"))
	_check("WASD no longer flies", not _is(_key(KEY_A), "turn_left") and not _is(_key(KEY_D), "turn_right")
		and not _is(_key(KEY_S), "reverse"))
	_check("W / Alt-W secondary", _is(_key(KEY_W), "secondary_next") and _is(_key(KEY_W, true), "secondary_prev")
		and not _is(_key(KEY_W), "secondary_prev"))
	_check("S clears the secondary", _is(_key(KEY_S), "clear_secondary"))
	_check("` / Shift-` / Alt-` cycle targets", _is(_key(KEY_QUOTELEFT), "target_next")
		and _is(_key(KEY_QUOTELEFT, false, true), "target_prev")
		and _is(_key(KEY_QUOTELEFT, true), "target_escort_next"))
	_check("R hostile / Alt-R nearest", _is(_key(KEY_R), "target_nearest_hostile") and _is(_key(KEY_R, true), "target_nearest"))
	_check("N / Alt-N clear", _is(_key(KEY_N), "clear_target") and _is(_key(KEY_N, true), "clear_ship_target"))
	_check("1-4 nav stellars", _is(_key(KEY_1), "nav_stellar_1") and _is(_key(KEY_4), "nav_stellar_4"))
	_check("E panel (not G), D defend (not X)", _is(_key(KEY_E), "escort_panel") and not _is(_key(KEY_G), "escort_panel")
		and _is(_key(KEY_D), "escort_defend") and not _is(_key(KEY_X), "escort_defend"))
	_check("F attack V hold C formation Alt-C return", _is(_key(KEY_F), "escort_attack") and _is(_key(KEY_V), "escort_hold")
		and _is(_key(KEY_C), "escort_formation") and _is(_key(KEY_C, true), "escort_return"))
	_check("Y hail / Alt-Y stellar, L land, M map, J jump, H arm, B board",
		_is(_key(KEY_Y), "hail_target") and _is(_key(KEY_Y, true), "hail_stellar") and _is(_key(KEY_L), "land")
		and _is(_key(KEY_M), "galaxy_map") and _is(_key(KEY_J), "hyperjump") and _is(_key(KEY_H), "hyperspace_arm")
		and _is(_key(KEY_B), "board_target"))
	_check("P / I info", _is(_key(KEY_P), "player_info") and _is(_key(KEY_I), "mission_info"))
	_check("Ctrl fires the secondary, Space the primary", _is(_key(KEY_CTRL), "fire_secondary") and _is(_key(KEY_SPACE), "fire_primary"))
	# The pad layout is unchanged (Apple PadBindings).
	var rb := InputEventJoypadButton.new()
	rb.device = -1
	rb.button_index = JOY_BUTTON_DPAD_DOWN
	_check("pad D-pad down still lands", _is(rb, "land"))
	# The alternative layout (the Apple app's modernKeyBindings), default off.
	Controls.layout = Controls.LAYOUT_MODERN
	Controls.register()
	_check("modern: Shift burns, Return fires secondary, Tab targets", _is(_key(KEY_SHIFT), "afterburner")
		and _is(_key(KEY_ENTER), "fire_secondary") and _is(_key(KEY_TAB), "target_next") and not _is(_key(KEY_Z), "afterburner"))
	Controls.layout = Controls.LAYOUT_ORIGINAL
	Controls.register()
	_check("layout defaults to original", Controls.layout == Controls.LAYOUT_ORIGINAL)


# --- 2. planet select, land on the selected one ----------------------------------

func _landable_ids() -> Array:
	var xf: PackedFloat32Array = nova.body_transforms()
	var ids: PackedInt32Array = nova.body_spob_ids()
	var out := []
	for n in ids.size():
		if int(xf[n * 4 + 3]) == 0:
			out.append(ids[n])
	return out


func _drain() -> PackedStringArray:
	return nova.drain_interaction_messages()


func _test_planet_select_and_land() -> void:
	print("-- planet select + land on the selected stellar")
	nova.make_world(-1)
	for i in 5:
		nova.step(1.0 / 30.0)
	_check("nothing selected at start", nova.selected_stellar_id() == -1)
	var ro: PackedStringArray = nova.nav_readout()
	_check("nav readout: Nav System Off", ro.size() == 3 and ro[1] == "")
	_check("1 selects the first nav stellar", nova.select_nav_stellar(0) and nova.selected_stellar_id() >= 0)
	ro = nova.nav_readout()
	print("  nav readout: ", ro)
	_check("nav readout names the selected stellar", ro[1] != "" and ro[0] != "")
	nova.clear_travel_selection()
	_check("N clears the travel selection", nova.selected_stellar_id() == -1)

	# A system with two landable stellars (the start system may have one).
	var lands := _landable_ids()
	var rows: PackedFloat32Array = nova.nav_systems()
	var stride: int = nova.nav_stride()
	var i := 0
	while lands.size() < 2 and i + stride <= rows.size():
		nova.make_world(int(rows[i]))
		nova.step(1.0 / 30.0)
		lands = _landable_ids()
		i += stride
	_check("found a system with two landable stellars", lands.size() >= 2)
	if lands.size() < 2:
		return
	var a: int = lands[0]
	var b: int = lands[1]
	nova.debug_place_player_at_spob(a)   # parked on A: A is by far the nearest
	nova.debug_select_stellar(b)
	_drain()
	var r = _json(nova.press_land())
	_check("first press only requests (no landing)", r["result"] == "messages" and not nova.is_landed())
	var msgs := _drain()
	print("  first press: ", msgs)
	_check("request line posted", msgs.size() >= 1)
	nova.step(1.0 / 30.0)
	r = _json(nova.press_land())
	msgs = _drain()
	print("  second press on far B: ", msgs)
	_check("second press on the selected (far) stellar does not land on the nearest", not nova.is_landed())
	nova.debug_select_stellar(a)
	r = _json(nova.press_land())
	_drain()
	nova.step(1.0 / 30.0)       # inside 250 px: the clearance line arms
	_check("clearance line posted", _drain().size() >= 1)
	r = _json(nova.press_land())
	_check("second press lands on the selected stellar", r["result"] == "landed" and nova.is_landed()
		and nova.landed_spob_id() == a)
	nova.launch()


# --- 3. refusal, bribe, landing ---------------------------------------------------

func _test_refusal_and_bribe() -> void:
	print("-- refused landing, bribe, allowed")
	var pairs: PackedInt32Array = nova.debug_refused_stellars()
	print("  candidates: ", pairs.size() / 2)
	var done := false
	for k in range(0, pairs.size(), 2):
		var sys := pairs[k]
		var spob := pairs[k + 1]
		nova.make_world(sys)
		nova.step(1.0 / 30.0)
		if not nova.debug_place_player_at_spob(spob):
			continue
		nova.debug_select_stellar(spob)
		_drain()
		var r = _json(nova.press_land())
		var refused := _drain()
		if nova.selected_stellar_id() != -1 or r["result"] != "messages":
			continue   # this stellar does not refuse the starting pilot
		print("  refused at spob ", spob, " (system ", sys, "): ", refused)
		_check("refusal message posted and selection dropped", refused.size() >= 1 and nova.selected_stellar_id() == -1)
		# Try to buy clearance from the stellar.
		nova.debug_select_stellar(spob)
		var h = _json(nova.hail_open(true))
		if h["result"] != "window":
			continue
		var st = _json(nova.hail_state())
		print("  hail: ", st.get("top"), " | ", st.get("text"))
		nova.hail_press_top()
		st = _json(nova.hail_state())
		if st.has("payment"):
			nova.hail_press_payment(true)
		var line: PackedStringArray = nova.drain_interaction_messages()
		print("  after bribe: ", line)
		if nova.hail_is_open() and not st.has("payment"):
			nova.hail_close()
			continue
		nova.hail_close()
		# Now the same press is allowed.
		nova.debug_select_stellar(spob)
		r = _json(nova.press_land())
		var after := _drain()
		if nova.selected_stellar_id() == -1:
			continue   # the bribe did not take for this one; try the next candidate
		_check("after the bribe the request is granted", nova.selected_stellar_id() == spob)
		nova.step(1.0 / 30.0)
		r = _json(nova.press_land())
		_check("and landing is allowed", r["result"] == "landed" and nova.is_landed())
		done = true
		nova.launch()
		break
	_check("a refusal + bribe + landing case was exercised", done)


# --- 4. hypergate travel ---------------------------------------------------------

func _gate_pos(spob: int) -> Vector2:
	var xf: PackedFloat32Array = nova.body_transforms()
	var ids: PackedInt32Array = nova.body_spob_ids()
	for n in ids.size():
		if ids[n] == spob:
			return Vector2(xf[n * 4], xf[n * 4 + 1])
	return Vector2(INF, INF)


func _test_gate() -> void:
	print("-- hypergate travel")
	var gates: PackedInt32Array = nova.debug_gates(false)
	_check("data has a usable hypergate", gates.size() >= 4)
	if gates.size() < 4:
		return
	var sys := gates[0]
	var gate := gates[1]
	nova.make_world(sys)
	nova.step(1.0 / 30.0)
	nova.debug_place_player_at_spob(gate)
	nova.debug_select_stellar(gate)
	# A fresh pilot is refused by the stock "Hypergate" government (MinStatus 32767).
	var denied = _json(nova.press_land())
	var deny_msgs := _drain()
	print("  fresh pilot at the gate: ", deny_msgs)
	_check("a gate refuses a pilot without standing", denied["result"] == "messages" and nova.selected_stellar_id() == -1)
	nova.debug_set_reputation(100)
	nova.debug_select_stellar(gate)
	var fuel_before: float = nova.player_fuel_fraction()
	var r = _json(nova.press_land())
	nova.step(1.0 / 30.0)
	r = _json(nova.press_land())
	_check("landing on a gate opens the picker", r["result"] == "gate" and nova.gate_picker_open())
	var st = _json(nova.gate_picker_state())
	print("  picker: ", st.get("name"), " -> ", st.get("destinations"))
	_check("picker lists destinations", st["destinations"].size() > 0)
	var d: Dictionary = st["destinations"][0]
	_check("choosing a destination travels", nova.gate_picker_choose(int(d["gate"])))
	_check("now in the destination system", nova.nav_current_system() == int(d["system"]))
	var pos: Vector2 = nova.player_position()
	var gp := _gate_pos(int(d["gate"]))
	print("  emerged at ", pos, " gate at ", gp)
	_check("emerged from the far gate", pos.distance_to(gp) < 200.0)
	_check("a gate spends no fuel", absf(nova.player_fuel_fraction() - fuel_before) < 0.0001)
	_check("arrival is reported", nova.take_jump_arrival() != "")
	# A wormhole flings you without a choice.
	var worms: PackedInt32Array = nova.debug_gates(true)
	if worms.size() >= 4:
		nova.make_world(worms[0])
		nova.step(1.0 / 30.0)
		nova.debug_place_player_at_spob(worms[1])
		nova.debug_select_stellar(worms[1])
		nova.press_land()
		nova.step(1.0 / 30.0)
		r = _json(nova.press_land())
		print("  wormhole: ", r)
		_check("a wormhole transports", r["result"] == "transported" and nova.nav_current_system() != worms[0])
	else:
		print("  (no independent wormhole in this data)")


# --- 5. the map's Find ------------------------------------------------------------

func _test_find() -> void:
	print("-- map find")
	nova.make_world(-1)
	nova.nav_refresh()
	var cur: int = nova.nav_current_system()
	var name: String = nova.nav_system_name(cur)
	_check("current system is known by name", name != "")
	var found: int = nova.nav_find(name.substr(0, maxi(3, name.length() / 2)).to_lower())
	_check("find resolves a prefix of a known system to it", found == cur)
	_check("find selects without plotting", nova.nav_selected() == cur and nova.nav_route().size() == 0)
	_check("find fails on nonsense", nova.nav_find("qqqq zzzz") == -1)
	var nebs = _json(nova.nav_nebulae(true))
	print("  nebulae in data: ", nebs.size())
	if nebs.size() > 0:
		var n: Dictionary = nebs[0]
		var pid: int = n["picts"][n["picts"].size() - 1] if n["picts"].size() > 0 else int(n["full"])
		var info: PackedInt32Array = nova.pict_info(pid)
		_check("nebula art decodes portably", info.size() >= 2 and info[0] > 0 and nova.pict_rgba(pid).size() >= info[0] * info[1] * 4)
	_check("gate links are available for the map", nova.nav_gate_links().size() % 3 == 0)


# --- 6. NPC death bursts ----------------------------------------------------------

func _test_death_bursts() -> void:
	print("-- death bursts")
	nova.make_world(-1)
	var boom: int = nova.debug_boom_with_sound()
	_check("a bööm with a sound exists", boom >= 0)
	var before: int = nova.debug_death_cues_emitted()
	nova.debug_begin_death_bursts(4242, boom)
	nova.debug_begin_death_bursts(4242, boom)   # a repeat for the same ship is ignored
	var counts := []
	for t in 25:   # 2.5 s in 0.1 s frames
		nova.step(0.1)
		counts.append(nova.debug_death_cues_emitted() - before)
	print("  cues by 0.1 s: ", counts)
	_check("bursts are staggered (1 at once, ~5 by 0.8 s)", counts[0] == 1 and counts[7] >= 4 and counts[7] <= 6 and counts[3] < counts[7])
	_check("ten bursts in all (nine + the final blast)", counts[24] == 10)


# --- 7. escorts across a jump and a launch ---------------------------------------

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


func _test_escorts() -> void:
	print("-- escorts carried across a jump")
	nova.make_world(-1)
	for i in 5:
		nova.step(1.0 / 30.0)
	var rec: int = nova.debug_add_escort(nova.player_ship_type())
	_check("hired an escort into the wing", rec >= 0)
	for i in 30:
		nova.step(1.0 / 30.0)
	nova.debug_damage_escorts(0.5)
	var before = _json(nova.debug_escort_states())
	print("  before jump: ", before)
	_check("escort is hurt", before.size() == 1 and before[0]["armor"] < 0.6)
	# Plot and fly a jump.
	nova.nav_refresh()
	var start: int = nova.nav_current_system()
	var links: PackedInt32Array = nova.nav_links()
	var first := -1
	for i in range(0, links.size(), 2):
		if links[i] == start:
			first = links[i + 1]
			break
		if links[i + 1] == start:
			first = links[i]
			break
	_check("a linked system to jump to", first != -1 and nova.nav_click(first))
	_check("jump flew", _jump_once())
	for i in 3:
		nova.step(1.0 / 30.0)
	var after = _json(nova.debug_escort_states())
	print("  after jump: ", after)
	_check("the escort followed", after.size() == 1 and int(after[0]["record"]) == rec)
	_check("its damage was carried (not refilled)", after.size() == 1 and after[0]["armor"] < 0.6 and after[0]["armor"] > 0.4)
	# A launch refills.
	var lands := _landable_ids()
	if lands.size() > 0:
		nova.debug_place_player_at_spob(lands[0])
		nova.select_nav_stellar(0)
		nova.attempt_land()
		if nova.is_landed():
			nova.launch()
			for i in 3:
				nova.step(1.0 / 30.0)
			var relaunched = _json(nova.debug_escort_states())
			print("  after launch: ", relaunched)
			_check("a launch brings the escort back at full strength", relaunched.size() == 1 and relaunched[0]["armor"] > 0.99)
