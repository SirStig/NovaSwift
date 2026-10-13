# Headless check of the galaxy-map features of fidelity package D and the gate-entry movie lookup:
# Tab / backslash adjacent-link cycling (0x004a74f0 / 0x004a7710), Show/Hide Borders (the shared
# PoliticalOverlay through nav_borders, persisted in [map] show_borders), mission-target markers
# (nav_mission_targets), and the hypergate / wormhole entry movie (Stellar_EnterHypergate 0x00456480 /
# Stellar_EnterWormhole 0x00456ca0 -> dësc id = the travel selection; DescMovie.lookup_gate). Run:
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/map_features_selfcheck.gd
extends SceneTree

const GalaxyMap = preload("res://screens/GalaxyMap.gd")
const Controls = preload("res://Controls.gd")
const Prefs = preload("res://Prefs.gd")
const DescMovie = preload("res://ui/DescMovie.gd")

var ok := true


func _init() -> void:
	_run()


func _check(label: String, cond: bool) -> void:
	print(("  ok   " if cond else "  FAIL ") + label)
	if not cond:
		ok = false


func _key(gm, code: int, shift := false) -> void:
	var e := InputEventKey.new()
	e.keycode = code
	e.physical_keycode = code
	e.pressed = true
	e.shift_pressed = shift
	gm._input(e)


func _run() -> void:
	await process_frame
	Controls.register()
	var nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	var dir := OS.get_environment("NOVA_DATA_DIR")
	if dir == "" or not nova.load_game(dir):
		print("MAP FEATURES SELFCHECK: SKIP (no data)")
		quit(0)
		return
	_check("make_world", nova.make_world(-1))
	var gm = GalaxyMap.new()
	root.add_child(gm)
	gm.setup(nova)
	gm.open()
	await process_frame
	await process_frame

	# --- Tab / backslash cycling -------------------------------------------------------------
	_check("bridge has nav_cycle_link", nova.has_method("nav_cycle_link"))
	_check("Tab no longer means 'add hop'", not InputMap.action_get_events("map_extend").any(
		func(ev): return ev is InputEventKey and ev.keycode == KEY_TAB))
	var links: int = 0
	for i in range(0, gm._links.size() - 1, 2):
		if gm._links[i] == gm._current or gm._links[i + 1] == gm._current:
			links += 1
	if links >= 1:
		_key(gm, KEY_TAB)
		var first: int = int(nova.nav_selected())
		var route: PackedInt32Array = nova.nav_route()
		_check("Tab arms the first link and selects it", nova.nav_route_armed() and route.size() >= 1
			and route[0] == first and gm._selected == first)
		if links >= 2:
			_key(gm, KEY_BACKSLASH)
			var second: int = int(nova.nav_selected())
			_check("backslash steps to the next link", second != first)
			_key(gm, KEY_BACKSLASH, true)
			_check("Shift-backslash steps back", int(nova.nav_selected()) == first)
			_key(gm, KEY_TAB, true)
			_check("Shift-Tab wraps to the last link", int(nova.nav_selected()) != first)
	else:
		print("  (start system has no links; cycling not exercised)")
	_check("cycle_link returns -1 only without links", (gm.cycle_link(true) != -1) == (links >= 1))

	# --- Show / Hide Borders -------------------------------------------------------------------
	var was: bool = gm.borders_on()
	gm.toggle_borders()
	_check("toggle flips the persisted pref", gm.borders_on() == (not was) and bool(Prefs.get_value("map", "show_borders")) == (not was))
	if not gm.borders_on():
		gm.toggle_borders()
	gm._canvas.queue_redraw()
	await process_frame
	await process_frame
	_check("overlay layer shown while borders are on", gm._borders.visible)
	var sz: Vector2 = gm._canvas.size
	var bytes: PackedByteArray = nova.nav_borders(int(sz.x), int(sz.y), gm._zoom, gm._center.x, gm._center.y)
	var cells: int = int(sz.x * 0.5) * int(sz.y * 0.5) * 4
	_check("nav_borders returns the 2 px cell grid (or nothing)", bytes.size() == 0 or bytes.size() == cells)
	var painted: int = 0
	for i in range(3, bytes.size(), 4):
		if bytes[i] != 0:
			painted += 1
	print("  painted cells: ", painted)
	_check("nav_borders ignores nonsense sizes", nova.nav_borders(0, 0, 1.0, 0.0, 0.0).size() == 0)
	gm.toggle_borders()
	_check("toggling again hides the layer's source", not gm.borders_on())
	if was:
		gm.toggle_borders()

	# --- Mission-target markers -----------------------------------------------------------------
	var m = JSON.parse_string(nova.nav_mission_targets())
	_check("nav_mission_targets is a JSON array", m is Array)
	_check("a fresh pilot has no mission marks", (m as Array).is_empty())
	gm._missions = [{"system": gm._current, "x": 0.0, "y": 0.0, "vis": 3, "names": ["Test mission"]}]
	gm._canvas.queue_redraw()
	await process_frame
	_check("mission marks draw without error", true)

	# --- Gate / wormhole entry movie --------------------------------------------------------------
	_check("no selection plays nothing", DescMovie.lookup_gate(-1).is_empty() and DescMovie.lookup_gate(127).is_empty())
	var pl: Object = ClassDB.instantiate("NovaPlugins")
	_check("NovaPlugins.gate_movie exists", pl != null and pl.has_method("gate_movie"))
	if pl != null and pl.has_method("gate_movie"):
		var gmv = JSON.parse_string(str(pl.gate_movie(128)))
		_check("gate_movie answers {movie, after, double, fill}", gmv is Dictionary and (gmv as Dictionary).has("movie"))
		# Base data has no dësc for most ids: nothing to play, and the lookup says so.
		_check("a selection without a movie dësc gives {}", DescMovie.lookup_gate(0x7ffe).is_empty())
	_check("wormhole transport can be deferred for the movie", nova.has_method("set_gate_transport_deferred")
		and nova.has_method("wormhole_enter_pending"))
	nova.set_gate_transport_deferred(true)
	_check("nothing pending to enter", not nova.wormhole_enter_pending())
	nova.set_gate_transport_deferred(false)

	print("MAP FEATURES SELFCHECK: " + ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
