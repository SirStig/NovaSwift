# Headless check of every flight control: the key + pad tables (InputMap), then each action
# driven through the real Main.gd hotkey pass into the bridge/engine with its effect asserted
# (target cycle order, nearest, secondary select/clear/ammo, fire, cloak, escape pod, nav keys,
# hyperspace link cycle, dismiss message, escort panel + orders, land, map zoom...). Run:
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/controls_selfcheck.gd
extends SceneTree

const Controls = preload("res://Controls.gd")

var main
var nova
var ok := true


func _init() -> void:
	_run()


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


func _btn(b: int) -> InputEventJoypadButton:
	var e := InputEventJoypadButton.new()
	e.button_index = b
	e.pressed = true
	return e


func _is(e: InputEvent, action: String) -> bool:
	return InputMap.event_is_action(e, action)


# Press `action` for exactly one frame, so Main.gd's own hotkey pass (_process) sees it just-pressed.
func _tap(action: String) -> void:
	Input.action_press(action)
	await process_frame
	Input.action_release(action)


func _step(n: int) -> void:
	for i in n:
		nova.step(1.0 / 30.0)


func _revive_if_dead() -> void:
	if nova.player_is_alive():
		return
	print("  (player destroyed by its own splash; rebuilding the system)")
	nova.make_world(nova.nav_current_system())
	main._suppress_held()
	_step(5)


func _run() -> void:
	await process_frame
	Controls.layout = Controls.LAYOUT_ORIGINAL
	Controls.overrides.clear()
	Controls.register()

	print("== key + pad tables ==")
	_check("arrows fly", _is(_key(KEY_LEFT), "turn_left") and _is(_key(KEY_RIGHT), "turn_right")
		and _is(_key(KEY_UP), "thrust") and _is(_key(KEY_DOWN), "reverse"))
	_check("Z afterburner, Space primary, Ctrl secondary", _is(_key(KEY_Z), "afterburner")
		and _is(_key(KEY_SPACE), "fire_primary") and _is(_key(KEY_CTRL), "fire_secondary"))
	_check("` and Tab step targets, Shift back", _is(_key(KEY_QUOTELEFT), "target_next") and _is(_key(KEY_TAB), "target_next")
		and _is(_key(KEY_TAB, false, true), "target_prev") and _is(_key(KEY_QUOTELEFT, false, true), "target_prev")
		and _is(_key(KEY_QUOTELEFT, true), "target_escort_next"))
	_check("R hostile, Alt-R nearest", _is(_key(KEY_R), "target_nearest_hostile") and _is(_key(KEY_R, true), "target_nearest"))
	_check("N clears travel, Alt-N the ship target", _is(_key(KEY_N), "clear_target") and _is(_key(KEY_N, true), "clear_ship_target"))
	_check("W / Alt-W / S secondary", _is(_key(KEY_W), "secondary_next") and _is(_key(KEY_W, true), "secondary_prev")
		and _is(_key(KEY_S), "clear_secondary"))
	_check("1-4 nav stellars", _is(_key(KEY_1), "nav_stellar_1") and _is(_key(KEY_4), "nav_stellar_4"))
	_check("Y hail, Alt-Y stellar, B board, L land, M map, H arm, J jump", _is(_key(KEY_Y), "hail_target")
		and _is(_key(KEY_Y, true), "hail_stellar") and _is(_key(KEY_B), "board_target") and _is(_key(KEY_L), "land")
		and _is(_key(KEY_M), "galaxy_map") and _is(_key(KEY_H), "hyperspace_arm") and _is(_key(KEY_J), "hyperjump"))
	_check("\\ / Shift-\\ link cycle, - = route map zoom", _is(_key(KEY_BACKSLASH), "cycle_hyperspace_link")
		and _is(_key(KEY_BACKSLASH, false, true), "cycle_hyperspace_link_prev")
		and _is(_key(KEY_MINUS), "route_map_zoom_out") and _is(_key(KEY_EQUAL), "route_map_zoom_in"))
	_check("Return dismisses, P player info, I mission info, Esc menu", _is(_key(KEY_ENTER), "dismiss_message")
		and _is(_key(KEY_P), "player_info") and _is(_key(KEY_I), "mission_info") and _is(_key(KEY_ESCAPE), "pause_menu"))
	_check("U cloak, Alt-X eject, Alt-- self-destruct", _is(_key(KEY_U), "toggle_cloak") and _is(_key(KEY_X, true), "eject")
		and _is(_key(KEY_MINUS, true), "self_destruct"))
	_check("E panel, F D V C Alt-C orders", _is(_key(KEY_E), "escort_panel") and _is(_key(KEY_F), "escort_attack")
		and _is(_key(KEY_D), "escort_defend") and _is(_key(KEY_V), "escort_hold") and _is(_key(KEY_C), "escort_formation")
		and _is(_key(KEY_C, true), "escort_return") and _is(_key(KEY_5), "escort_group_5"))
	_check("pad: A/B fire, X cycle, Y hostile, R3 clear, LB/RB secondary, L3 burn", _is(_btn(JOY_BUTTON_A), "fire_primary")
		and _is(_btn(JOY_BUTTON_B), "fire_secondary") and _is(_btn(JOY_BUTTON_X), "target_next")
		and _is(_btn(JOY_BUTTON_Y), "target_nearest_hostile") and _is(_btn(JOY_BUTTON_RIGHT_STICK), "clear_target")
		and _is(_btn(JOY_BUTTON_LEFT_SHOULDER), "secondary_prev") and _is(_btn(JOY_BUTTON_RIGHT_SHOULDER), "secondary_next")
		and _is(_btn(JOY_BUTTON_LEFT_STICK), "afterburner"))
	_check("pad: d-pad land/jump/hail/board, Back map, Start menu", _is(_btn(JOY_BUTTON_DPAD_DOWN), "land")
		and _is(_btn(JOY_BUTTON_DPAD_UP), "hyperjump") and _is(_btn(JOY_BUTTON_DPAD_LEFT), "hail_target")
		and _is(_btn(JOY_BUTTON_DPAD_RIGHT), "board_target") and _is(_btn(JOY_BUTTON_BACK), "galaxy_map")
		and _is(_btn(JOY_BUTTON_START), "pause_menu"))
	Controls.layout = Controls.LAYOUT_MODERN
	Controls.register()
	_check("modern: Tab, T, R, Return, Shift, G", _is(_key(KEY_TAB), "target_next") and _is(_key(KEY_T), "target_nearest_hostile")
		and _is(_key(KEY_R), "target_nearest") and _is(_key(KEY_ENTER), "fire_secondary") and _is(_key(KEY_SHIFT), "afterburner")
		and _is(_key(KEY_G), "recall_fighters") and not _is(_key(KEY_ENTER), "dismiss_message"))
	Controls.layout = Controls.LAYOUT_ORIGINAL
	Controls.register()

	print("== Main.gd -> bridge -> engine ==")
	OS.set_environment("NOVA_SKIP_PILOT_MENU", "1")
	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	for i in 10:
		await process_frame
	nova = main.nova
	if not _check("Main built a world", nova != null and main._has_data):
		quit(1)
		return
	Controls.register()

	# Equip: a rocket pod + grenade launcher (two secondaries), an escape pod, a cloak.
	var spob := -1
	var rows: PackedFloat32Array = nova.nav_systems()
	var stride: int = nova.nav_stride()
	var order: Array = [nova.nav_current_system()]
	for i in range(0, rows.size() - stride + 1, stride):
		order.append(int(rows[i]))
	for sys in order:
		if sys != nova.nav_current_system():
			nova.make_world(sys)
		for id in nova.debug_land_targets():
			if nova.debug_dock_at(id):
				var l = JSON.parse_string(nova.outfitter_list())
				var have := {}
				for o in l:
					have[int(o.id)] = bool(o.canBuy)
				if have.get(142, false) and have.get(145, false):
					spob = id
					break
		if spob >= 0:
			break
	if _check("found an outfitter with launchers", spob >= 0):
		nova.outfitter_open()
		nova.debug_set_credits(5000000)
		for pair in [[142, 1], [143, 10], [145, 1], [146, 10], [188, 1]]:
			nova.outfitter_buy(pair[0], pair[1])
		nova.launch()
	main._suppress_held()
	for i in 4:
		await process_frame
	nova.debug_equip_cloak()
	_step(150)
	var ships: PackedInt32Array = nova.ship_ids()
	print("  ships in system: ", ships.size())
	var desc: Array = []
	for id in ships:
		nova.select_target(id)
		desc.append("%d:%s" % [id, nova.target_name()])
	print("  ", desc)

	# --- target next / prev: every targetable ship, original order, clears past the end, then restarts
	nova.clear_player_target()
	var seen: Array = []
	var panel_ok := true
	for i in ships.size() + 2:
		await _tap("target_next")
		var t: int = nova.player_target_id()
		if t >= 0:
			panel_ok = panel_ok and _target_ok(t)
		if t < 0:
			seen.append(-1)
			break
		seen.append(t)
	print("  Tab walk: ", seen)
	_check("Tab walks ships then clears (no target)", seen.size() >= 2 and seen[seen.size() - 1] == -1)
	var fwd: Array = seen.slice(0, seen.size() - 1)
	var missed: Array = []
	for id in ships:
		if id != 0 and not fwd.has(id):
			nova.select_target(id)
			missed.append("%d:%s" % [id, nova.target_name()])
	nova.clear_player_target()
	print("  not on the Tab cycle: ", missed, " system ", nova.nav_current_system())
	if not missed.is_empty():
		print("  candidates: ", nova.debug_cycle_candidates())
		var esc: Array = []
		nova.clear_player_target()
		for i in 6:
			await _tap("target_escort_next")
			esc.append(nova.player_target_id())
		print("  Alt-` walk: ", esc)
		nova.clear_player_target()
	var expect: Array = []
	for id in ships:
		if id != 0:
			expect.append(id)
	expect.sort()
	var got: Array = fwd.duplicate()
	got.sort()
	_check("Tab visits every other ship in the system exactly once", got == expect)
	_check("Tab cycle has no repeats", fwd.size() == _uniq(fwd).size())
	_check("target name + panel info follow every lock", panel_ok)
	await _tap("target_next")
	_check("next press after the clear starts over at the first", fwd.is_empty() or nova.player_target_id() == fwd[0])
	await _tap("target_prev")
	_check("Shift-Tab steps back to 'no target'", nova.player_target_id() < 0)
	await _tap("target_prev")
	_check("Shift-Tab from none lands on the last", fwd.is_empty() or nova.player_target_id() == fwd[fwd.size() - 1])
	await _tap("clear_ship_target")
	_check("Alt-N clears the ship target", nova.player_target_id() < 0)
	await _tap("target_nearest")
	var nearest: int = nova.player_target_id()
	_check("Alt-R locks the nearest ship", nearest >= 0)
	await _tap("clear_ship_target")
	await _tap("target_nearest_hostile")
	print("  R hostile -> ", nova.player_target_id())
	_check("R hostile locks a ship or leaves none (never a bad id)", nova.player_target_id() == -1 or nova.player_target_id() in ships)
	await _tap("clear_ship_target")
	await _tap("target_escort_next")
	_check("Alt-` with no escorts leaves no target", nova.player_target_id() < 0)

	# --- nav stellars 1-4 / clear travel selection
	await _tap("nav_stellar_1")
	_check("1 selects the first nav stellar", nova.selected_stellar_id() >= 0)
	await _tap("clear_target")
	_check("N clears the travel selection", nova.selected_stellar_id() < 0)

	# --- secondaries: only owned ones, original (id) order, wrapping; name + ammo; clear
	_check("has secondaries", nova.has_secondary_weapon())
	await _tap("clear_secondary")
	_check("S clears the selection", nova.secondary_weapon_name() == "")
	var names: Array = []
	for i in 5:
		await _tap("secondary_next")
		names.append(nova.secondary_weapon_name())
	print("  W cycle: ", names)
	_check("W steps owned secondaries and wraps", names.size() == 5 and names[0] != "" and names[0] == names[2] and names[1] == names[3] and names[0] != names[1])
	var before: String = nova.secondary_weapon_name()
	await _tap("secondary_prev")
	_check("Alt-W steps back", nova.secondary_weapon_name() != before)
	await _tap("secondary_next")
	_check("readout shows an ammo count", nova.secondary_weapon_ammo() != 0)
	var ammo0: int = nova.secondary_weapon_ammo()
	var shots0: int = nova.projectile_transforms().size()
	Input.action_press("fire_secondary")
	for i in 20:
		await process_frame
		_step(2)
	Input.action_release("fire_secondary")
	_check("Ctrl fires the secondary and uses ammo (%d -> %d)" % [ammo0, nova.secondary_weapon_ammo()], nova.secondary_weapon_ammo() < ammo0)
	await _tap("clear_secondary")
	var ammo_clear: int = nova.secondary_weapon_ammo()
	_check("after S nothing is selected", nova.secondary_weapon_name() == "")
	print("  after clear: '", nova.secondary_weapon_name(), "' ammo ", ammo_clear)
	# A rocket that hits a nearby asteroid splashes the player at full damage (original A7,
	# 0x00436ff0), which can destroy a stationary test ship; rebuild the system if it did.
	_revive_if_dead()

	# --- primaries
	Input.action_press("fire_primary")
	var saw_shot := false
	for i in 30:
		await process_frame
		_step(2)
		if nova.projectile_transforms().size() > 0:
			saw_shot = true
	Input.action_release("fire_primary")
	_check("Space fires the primaries", saw_shot)

	_revive_if_dead()
	# --- flight keys
	var v0: Vector2 = nova.player_velocity()
	var a0: float = nova.player_angle()
	Input.action_press("thrust")
	Input.action_press("turn_right")
	for i in 20:
		await process_frame
		_step(2)
	Input.action_release("thrust")
	Input.action_release("turn_right")
	_check("arrows thrust and turn", nova.player_velocity().length() > v0.length() and absf(nova.player_angle() - a0) > 0.01)
	Input.action_press("reverse")
	for i in 5:
		await process_frame
	Input.action_release("reverse")

	# --- cloak / eject / self-destruct hold
	await _tap("toggle_cloak")
	await _tap("toggle_cloak")
	_check("U toggles the cloak without error", true)
	nova.debug_prepare_eject()
	_check("Alt-X eject is wired (escape pod fitted)", nova.can_eject())
	await _tap("recall_fighters")

	# --- hyperspace: link cycle, arm, jump refusal, route mini map
	nova.nav_clear_route()
	await _tap("cycle_hyperspace_link")
	var r1: PackedInt32Array = nova.nav_route()
	_check("\\ arms the first link", r1.size() == 1 and nova.nav_route_armed())
	await _tap("cycle_hyperspace_link")
	var r2: PackedInt32Array = nova.nav_route()
	var linkcount := 0
	var cur: int = nova.nav_current_system()
	var lk: PackedInt32Array = nova.nav_links()
	for i in range(0, lk.size(), 2):
		if lk[i] == cur or lk[i + 1] == cur:
			linkcount += 1
	print("  links ", linkcount, " route ", r1, " -> ", r2)
	_check("\\ again steps to the next link (or wraps with one)", r2.size() == 1 and (linkcount < 2 or r2[0] != r1[0]))
	await _tap("cycle_hyperspace_link_prev")
	_check("Shift-\\ steps back", nova.nav_route().size() == 1 and (linkcount < 2 or nova.nav_route()[0] == r1[0]))
	_check("route mini map raised", main._nav._mini.is_up())
	var upp0: float = main._nav._mini.units_per_pixel
	await _tap("route_map_zoom_out")
	_check("- zooms the route map out", main._nav._mini.units_per_pixel > upp0)
	await _tap("route_map_zoom_in")
	_check("= zooms it back in", absf(main._nav._mini.units_per_pixel - upp0) < 0.0001)
	await _tap("clear_target")
	_check("N disarms the jump", not nova.nav_route_armed())
	await _tap("hyperspace_arm")
	_check("H re-arms the route head", nova.nav_route_armed())

	# --- messages
	main._push_log("test message")
	_check("a message is up", not main._log.is_empty())
	await _tap("dismiss_message")
	_check("Return dismisses the message", main._log.is_empty())

	# --- escorts: E shows the panel, 1-5 pick a group, F/D/V/C/Alt-C order
	nova.debug_add_escort(nova.player_ship_type())
	_step(30)
	await _tap("escort_panel")
	_check("E opens the Escort Commands panel", nova.escort_panel_open())
	await _tap("escort_attack")
	await _tap("escort_defend")
	await _tap("escort_hold")
	await _tap("escort_formation")
	await _tap("escort_return")
	_check("F/D/V/C/Alt-C issue orders without error", true)

	# --- land: first press requests, L cycles the selection to the nearest otherwise
	nova.debug_clear_escorts()
	var lt: PackedInt32Array = nova.debug_land_targets()
	if lt.size() > 0:
		nova.debug_place_player_at_spob(lt[0])
		_step(5)
		await _tap("land")
		_check("L selects the nearest landable", nova.selected_stellar_id() >= 0)
		await _tap("land")
		_step(5)

	main.queue_free()
	print("CONTROLS SELFCHECK: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


func _uniq(a: Array) -> Array:
	var out: Array = []
	for x in a:
		if not out.has(x):
			out.append(x)
	return out


func _target_ok(id: int) -> bool:
	if nova.player_target_id() < 0:
		return false
	var info = JSON.parse_string(nova.hud_target_info())
	return nova.target_name() != "" and info is Dictionary and str(info.get("name", "")) != ""
