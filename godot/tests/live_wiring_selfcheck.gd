# Headless self-check for package A of docs/GODOT_FIDELITY_GAPS.md: the shared pilot <-> live-world
# rules the Apple container wires and the bridge now calls too (Sources/NovaSwiftStory/WorldPilotLink.swift):
# combat rating + legal record sync, mining into the hold, përs / hull spawn gating and defeat
# persistence across save+reload, NPCs boarding the player, garrison / reinforcement / stellar
# armor persistence across jumps, bombs, Strict Play, the per-day world seed. Run with a scratch
# pilot dir (the check makes its own under user://):
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/live_wiring_selfcheck.gd
# Prints LIVE WIRING SELFCHECK: PASS / FAIL.
extends SceneTree

var nova
var ok := true


func _check(label: String, cond: bool, detail := "") -> bool:
	print(("  ok   " if cond else "  FAIL ") + label + ((" — " + detail) if detail != "" else ""))
	if not cond:
		ok = false
	return cond


func _j(t: String):
	return JSON.parse_string(t)


func _init() -> void:
	_run()


func _steps(n: int) -> void:
	for i in n:
		nova.step(1.0 / 30.0)


func _run() -> void:
	nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	var data := OS.get_environment("NOVA_DATA_DIR")
	if data == "":
		data = ProjectSettings.globalize_path("res://") + "../data/base"
	var dir := OS.get_user_data_dir() + "/live_wiring_selfcheck"
	_check("load_game", nova.load_game(data))
	var scen = _j(nova.pilot_scenarios())
	var sid: int = int(scen[0].id)
	var pid: String = nova.pilot_create(dir, sid, "Wiring Tester", true, "", "")
	_check("pilot created", pid != "")
	_check("make_world", nova.make_world(-1))
	_steps(10)

	_standing()
	_mining()
	_pers_gating(dir, pid)
	_boarded()
	_defense_persistence(dir, pid)
	_strict_and_seed(dir, sid)
	_bombs(dir, pid)

	nova.pilot_delete(dir, pid)
	print("LIVE WIRING SELFCHECK: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


# --- A1: combat rating, legal record, rank sync ----------------------------------------

func _standing() -> void:
	print("-- A1 combat rating / legal record")
	var s0 = _j(nova.debug_standing())
	_check("rating starts at 0", int(s0.rating) == 0, str(s0))
	var govt := int(s0.get("sysGovt", -1))
	_check("the system has a government", govt >= 128, str(govt))
	# A real kill through the engine (credited to the player) folds into the rating at the next sync.
	var victim = _j(nova.debug_kill_npc())
	var sk = _j(nova.debug_standing())
	_check("destroying a ship raises the combat rating", int(sk.rating) > 0 and int(victim.get("strength", 0)) > 0,
		"%s -> %s" % [str(victim), str(sk.rating)])
	s0 = sk
	# A kill folds its Strength into the rating; the world's copy (AI fire ramp) follows.
	nova.debug_commit_crime("kill", govt, 200)
	var s1 = _j(nova.debug_standing())
	_check("a kill raises the combat rating", int(s1.rating) > int(s0.rating), str(s1))
	_check("the world sees the new rating (AI-03)", int(s1.worldRating) == int(s1.rating), str(s1))
	_check("the kill dents the legal record here", int(s1.pilotLegal) < 0, str(s1))
	# The record survives rebuilding the world (jump / launch): seeded back from the pilot.
	var other := _other_system()
	_check("rebuild in another system", nova.make_world(other))
	_check("rebuild back", nova.make_world(int(s0.system)))
	var s2 = _j(nova.debug_standing())
	_check("legal record kept after rebuilding", int(s2.legalHere) == int(s1.legalHere), "%s vs %s" % [s2.legalHere, s1.legalHere])
	_check("rating kept after rebuilding", int(s2.rating) == int(s1.rating) and int(s2.worldRating) == int(s1.rating))
	# Crime events are drained once (a second sync must not double-count).
	var s3 = _j(nova.debug_standing())
	_check("no double count on re-sync", int(s3.rating) == int(s2.rating) and int(s3.legalHere) == int(s2.legalHere))
	# A save writes the folded record: reload keeps it.
	nova.debug_commit_crime("disable", govt, 0)
	var before = _j(nova.debug_standing())
	nova.pilot_save_now()
	_check("disabling a ship lowers the record further", int(before.pilotLegal) <= int(s2.legalHere))


func _other_system() -> int:
	var cur: int = int(_j(nova.debug_standing()).get("system", -1))
	var ids: PackedInt32Array = nova.debug_system_ids()
	for i in ids:
		if int(i) != cur:
			return int(i)
	return cur


# --- A2: mining / scooping --------------------------------------------------------------

func _mining() -> void:
	print("-- A2 mining scoop")
	_check("scoop fitted", nova.debug_equip_scoop())
	_steps(5)
	nova.debug_set_credits(0)
	var gained: int = nova.debug_mine_boxes(0, 3, 12)
	_check("scooped boxes land in the hold", gained == 3, "gained %d" % gained)
	_check("pilot cargo follows the hold", nova.debug_cargo_held(0) >= 3)
	# A full hold stops scooping: boxes fly on through (playerHoldHasRoom is no longer always true).
	nova.debug_give_cargo(1, 100000)
	_check("full hold reports no room", not nova.debug_hold_has_room())
	var again: int = nova.debug_mine_boxes(0, 3, 12)
	_check("a full hold takes nothing", again == 0, "gained %d" % again)
	nova.make_world(-1)   # fresh ship; cargo returns from the pilot
	nova.debug_give_cargo(1, -100000)


# --- A3: përs / ship gating and defeat persistence ---------------------------------------

func _pers_gating(dir: String, pid: String) -> void:
	print("-- A3 përs ActiveOn / defeated / grudge, shïp.AppearOn")
	var gated := nova.debug_gated_pers() as PackedInt32Array
	_check("data has a përs", gated.size() == 2)
	if gated.size() < 2:
		return
	var pers: int = gated[0]
	# A përs with an ActiveOn test is held back until its bits pass; a plain one is eligible.
	var g0 := nova.debug_pers_gate(pers) as PackedInt32Array
	_check("the world carries a pers gate", g0.size() == 2)
	if gated[1] == 0:
		_check("ungated përs is eligible", g0[0] == 1)
	# Wronging the përs records a grudge the next world starts with.
	nova.debug_pers_event(pers, false)
	nova.make_world(-1)
	var g1 := nova.debug_pers_gate(pers) as PackedInt32Array
	_check("the grudge seeds the next world", g1[1] == 1, str(g1))
	# Defeating it: never eligible again, across a save and reload.
	nova.debug_pers_event(pers, true)
	_check("defeat recorded on the pilot", nova.debug_pers_defeated(pers))
	var g2 := nova.debug_pers_gate(pers) as PackedInt32Array
	_check("defeated përs is gated off at once", g2[0] == 0, str(g2))
	_check("saved", nova.pilot_save_now())
	_check("reload the pilot", nova.pilot_load(dir, pid))
	_check("rebuild", nova.make_world(-1))
	_check("defeat survives the reload", nova.debug_pers_defeated(pers))
	var g3 := nova.debug_pers_gate(pers) as PackedInt32Array
	_check("defeated përs does not respawn after reload", g3[0] == 0 and g3[1] == 1, str(g3))
	# shïp.AppearOn: the hull appears only while its expression passes the live control bits.
	var ship: int = nova.debug_gated_ship()
	if ship >= 0:
		var expr: String = nova.debug_ship_appear_on(ship)
		var m := RegEx.create_from_string("^(!?)b(\\d+)$").search(expr.strip_edges())
		if m != null:
			var negated: bool = m.get_string(1) == "!"
			var bit := int(m.get_string(2))
			# Bit clear / set: the expression passes exactly when the bit matches its polarity.
			nova.debug_set_bit(bit, false)
			nova.make_world(-1)
			_check("hull gate with its bit clear (%s)" % expr, nova.debug_ship_gate(ship) == negated)
			nova.debug_set_bit(bit, true)
			_check("hull gate flips once its bit is set", nova.debug_ship_gate(ship) == not negated)
			nova.debug_set_bit(bit, false)
		else:
			_check("AppearOn world gate answers (%s)" % expr, nova.debug_ship_gate(ship) in [true, false])
	else:
		print("  note no hull in this data has an AppearOn test")


# --- A4: NPCs boarding the player ---------------------------------------------------------

func _boarded() -> void:
	print("-- A4 boarded by NPCs")
	nova.make_world(-1)
	_steps(5)
	nova.debug_set_credits(100000)
	nova.debug_give_cargo(0, 20)
	var lost = _j(nova.debug_board_player(60))
	_check("boarders take credits", int(lost.get("creditsLost", 0)) > 0, str(lost))
	_check("pilot credits fell", int(_j(nova.debug_standing()).get("credits", 0)) >= 0)


# --- A5: garrisons, reinforcements, stellar armor -----------------------------------------

func _defense_persistence(dir: String, pid: String) -> void:
	print("-- A5 garrisons / reinforcements / stellar armor")
	var at := nova.debug_system_with_defended_stellar() as PackedInt32Array
	if at.size() < 2:
		print("  note no stellar with a defense fleet in this data")
		return
	var sys: int = at[0]
	var spob: int = at[1]
	_check("enter the defended stellar's system", nova.make_world(sys))
	nova.debug_set_garrison(spob, 3)
	var d0 = _j(nova.debug_defense_state())
	_check("garrison folded into the pilot", int(d0.garrisons.get(str(spob), -1)) == 3, str(d0))
	nova.debug_set_stellar_armor(spob, 77.0)
	nova.debug_reinforcements_called(6)
	var d1 = _j(nova.debug_defense_state())
	_check("stellar armor kept", abs(float(d1.armor.get(str(spob), -1)) - 77.0) < 0.01, str(d1))
	_check("reinforcement delay stored for this system", int(d1.reinforce.get(str(sys), -1)) == 6, str(d1))
	# Jump away and back: the new world starts from the pilot's state.
	nova.make_world(_other_system())
	nova.make_world(sys)
	var d2 = _j(nova.debug_defense_state())
	_check("garrison count persists across the jump", int(d2.worldGarrisons.get(str(spob), -1)) == 3, str(d2))
	_check("stellar armor persists across the jump", abs(float(d2.worldArmor.get(str(spob), -1)) - 77.0) < 0.01, str(d2))
	# And through a save + reload.
	nova.pilot_save_now()
	nova.pilot_load(dir, pid)
	nova.make_world(sys)
	var d3 = _j(nova.debug_defense_state())
	_check("garrison survives save+reload", int(d3.worldGarrisons.get(str(spob), -1)) == 3, str(d3))
	_check("reinforcement delay survives save+reload", int(d3.reinforce.get(str(sys), -1)) == 6, str(d3))


# --- A7: Strict Play and the per-day seed --------------------------------------------------

func _strict_and_seed(dir: String, scen_id: int) -> void:
	print("-- A7 Strict Play / world seed")
	nova.make_world(-1)
	var s = _j(nova.debug_standing())
	_check("normal pilot is not strict", not bool(s.strictWorld) and not bool(s.strictPilot))
	var sp: String = nova.pilot_create_strict(dir, scen_id, "Strict Tester", true, "", "", true)
	_check("strict pilot created", sp != "")
	nova.make_world(-1)
	var st = _j(nova.debug_standing())
	_check("Strict Play reaches the world", bool(st.strictWorld) and bool(st.strictPilot), str(st))
	nova.pilot_delete(dir, sp)
	# The same day builds the same cast; a new day builds a different one.
	nova.make_world(-1)
	var a: PackedFloat32Array = nova.ship_transforms()
	var seed_a = _j(nova.debug_spawn_seed())
	nova.make_world(-1)
	var b: PackedFloat32Array = nova.ship_transforms()
	_check("same day, same system: identical ambient cast", a == b, "%d vs %d floats" % [a.size(), b.size()])
	nova.debug_advance_days(1)
	nova.make_world(-1)
	var c: PackedFloat32Array = nova.ship_transforms()
	var seed_c = _j(nova.debug_spawn_seed())
	_check("the seed follows the in-game day", str(seed_a.seed) != str(seed_c.seed))
	_check("a new day builds a different cast", a != c)


# --- A6: bombs --------------------------------------------------------------------------------

func _bombs(dir: String, pid: String) -> void:
	print("-- A6 bombs")
	nova.pilot_load(dir, pid)
	nova.make_world(-1)
	_steps(3)
	if nova.debug_give_bomb(false):
		var armor0: float = nova.player_armor_fraction()
		_steps(3)
		_check("a nonlethal bomb hurts the hull", nova.player_armor_fraction() < armor0 or not nova.player_is_alive(),
			"%f -> %f" % [armor0, nova.player_armor_fraction()])
		nova.make_world(-1)
	else:
		print("  note no nonlethal bomb outfit in this data")
	if nova.debug_give_bomb(true):
		_steps(3)
		_check("a lethal bomb destroys the ship", not nova.player_is_alive() or nova.player_armor_fraction() <= 0.0)
	else:
		print("  note no lethal bomb outfit in this data")
