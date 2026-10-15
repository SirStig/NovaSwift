# NOVA Swift — navigation glue (Godot): owns the galaxy map screen and the
# hyperjump visual, and turns the M / J actions into bridge calls. Kept out of
# Main.gd so the flight script only needs a handful of hook lines.
#
# All routing, fog-of-war, fuel and jump rules are the Swift core's (the bridge's
# `nav_*` / `begin_hyperjump` calls) — this file contains none of them.
#
# NOVA_SELFTEST=nav makes the app plot a 2-hop route from the start system, fly
# the real jump twice and print the system names, then quit (headless-friendly).

extends Node

const GalaxyMap = preload("res://screens/GalaxyMap.gd")
const HyperjumpFx = preload("res://screens/HyperjumpFx.gd")
const RouteMiniMap = preload("res://screens/RouteMiniMap.gd")
const Prefs = preload("res://Prefs.gd")

signal log_message(text: String)
signal arrived(system_name: String)
signal screen_closed

var nova
var _map
var _fx
var _mini


func setup(world) -> void:
	nova = world
	_map = GalaxyMap.new()
	add_child(_map)
	_map.setup(nova)
	_map.message.connect(func(t): log_message.emit(t))
	_map.closed.connect(func(): screen_closed.emit())
	_map.jump_requested.connect(engage_hyperjump)
	_fx = HyperjumpFx.new()
	add_child(_fx)
	_fx.setup(nova)
	_fx.arrived.connect(_on_arrived)
	_mini = RouteMiniMap.new()
	add_child(_mini)
	_mini.setup(nova)


# While the map is up the flight sim is paused and Main skips its flight pass.
func blocks_flight() -> bool:
	return _map != null and _map.is_open()


# The map's chart cursor handed the pad to the UI pointer (to reach the frame's buttons).
func map_pad_outside() -> bool:
	return _map != null and _map.pad_outside()


# Flight-time hotkeys: M / Back opens the map, J / D-pad up engages the hyperdrive.
func process_hotkeys() -> void:
	if Input.is_action_just_pressed("galaxy_map"):
		_map.open()
	elif Input.is_action_just_pressed("hyperjump"):
		engage_hyperjump()
	# `\` / Shift-`\` step the armed hyperspace link (snd 152, raised by the bridge) and
	# raise the route mini map; H (Main.gd arms the route) raises it too; - / = zoom it.
	if Input.is_action_just_pressed("cycle_hyperspace_link_prev"):
		if nova.cycle_hyperspace_link(false):
			_mini.show_map()
	elif Input.is_action_just_pressed("cycle_hyperspace_link"):
		if nova.cycle_hyperspace_link(true):
			_mini.show_map()
	if Input.is_action_just_pressed("hyperspace_arm"):
		_mini.show_map()
	if not Input.is_key_pressed(KEY_ALT):   # Alt-- is the self-destruct
		if Input.is_action_just_pressed("route_map_zoom_out"):
			if _mini.zoom(true):
				nova.sound_beep(1)
		elif Input.is_action_just_pressed("route_map_zoom_in"):
			if _mini.zoom(false):
				nova.sound_beep(1)
	for m in nova.drain_nav_messages():
		log_message.emit(m)


# Landing on a hypergate the pilot may use: the map in gate mode (pick a destination).
func open_gate_picker() -> void:
	_map.open_gate()


func engage_hyperjump() -> void:
	if nova.hyperjump_active():
		return
	# "" = engaged (or a silent refusal); otherwise the original's status text:
	# #29 no course, #10 out of fuel, #42 too close to the system centre.
	var refusal: String = nova.begin_hyperjump()
	if refusal == "" and nova.hyperjump_active():
		return
	# The `autoRoutePlotting` enhancement turns a refused J into the map, silently (Apple
	# GameContainerView .hyperjump: `if !attemptJump() { if autoRoutePlotting { showingMap = true } ... }`).
	if auto_route_enabled():
		_map.open(true)
		return
	if refusal != "":
		nova.sound_beep(4)   # the refused jump sounds snd 153 (0x0044b120)
		log_message.emit(refusal)


## The Settings > Gameplay "Automatic route plotting" enhancement (off by default).
static func auto_route_enabled() -> bool:
	return bool(Prefs.get_value("gameplay", "auto_route_plotting"))


func _on_arrived(system_name: String) -> void:
	if nova.nav_route().size() > 0:   # the jump sequence redraws the route map when a route remains
		_mini.show_map()
	# The arrival status line (buoy / "Arriving in the X system on <date>.") is the bridge's now (B1).
	arrived.emit(system_name)


# MARK: Headless self-test

var _map_test_frames := -1


func run_selftest_if_requested() -> void:
	if OS.get_environment("NOVA_SELFTEST") == "map":
		# Open the real map screen and click a neighbouring system with a synthetic
		# mouse event, so the drawing and input paths run (needs a few frames).
		nova.nav_refresh()
		_map.open()
		_map_test_frames = 0
		return
	if OS.get_environment("NOVA_SELFTEST") != "nav":
		return
	var ok := _selftest()
	print("NAV SELFTEST: ", "PASS" if ok else "FAIL")
	get_tree().quit(0 if ok else 1)


func _sys_name(id: int) -> String:
	var n: String = nova.nav_system_name(id)
	return n if n != "" else "#%d" % id


# Fly the real jump: thrust clear of the no-jump zone, engage, step until the
# engine fires it and the bridge rebuilds the world.
func _jump_once() -> bool:
	var tries := 0
	var refusal := ""
	while tries < 3000:
		nova.set_intent(false, false, true, false, false, false, false)
		nova.step(1.0 / 30.0)
		tries += 1
		if tries % 15 == 0:
			refusal = nova.begin_hyperjump()
			if nova.hyperjump_active():
				break
	if not nova.hyperjump_active():
		print("  could not engage after ", tries, " ticks: '", refusal, "'")
		return false
	print("  engaged after ", tries, " ticks")
	var ticks := 0
	while nova.hyperjump_active() and ticks < 6000:
		nova.set_intent(false, false, false, false, false, false, false)
		nova.step(1.0 / 30.0)
		ticks += 1
	var arrival: String = nova.take_jump_arrival()
	print("  jump flew ", ticks, " ticks, arrived: ", arrival)
	return arrival != ""


func _selftest() -> bool:
	nova.nav_refresh()
	var start: int = nova.nav_current_system()
	print("NAV SELFTEST start: ", _sys_name(start), " (", start, ")  jumps=", nova.player_jumps_remaining(),
		" max_hops=", nova.nav_max_jump_hops())
	var rows: PackedFloat32Array = nova.nav_systems()
	var stride: int = nova.nav_stride()
	var seen := 0
	for i in range(0, rows.size(), stride):
		seen += 1
	print("  drawable systems: ", seen, "  links: ", nova.nav_links().size() / 2)

	# Hop 1: a system linked to the start. Hop 2: one linked to hop 1, not the start.
	var links: PackedInt32Array = nova.nav_links()
	var first := -1
	for i in range(0, links.size(), 2):
		if links[i] == start:
			first = links[i + 1]
			break
		if links[i + 1] == start:
			first = links[i]
			break
	if first == -1:
		print("  start system has no drawable links")
		return false
	var second := -1
	for i in range(0, links.size(), 2):
		var other := -1
		if links[i] == first:
			other = links[i + 1]
		elif links[i + 1] == first:
			other = links[i]
		if other != -1 and other != start:
			second = other
			break
	if second == -1:
		print("  no second hop beyond ", first)
		return false

	if not nova.nav_click(first):
		print("  click did not arm ", first)
		return false
	nova.nav_shift_click(second)
	var route: PackedInt32Array = nova.nav_route()
	var names: PackedStringArray = []
	for id in route:
		names.append(_sys_name(id))
	print("  route: ", _sys_name(start), " -> ", " -> ".join(names), "  armed=", nova.nav_route_armed())
	if route.size() != 2:
		return false

	# Refusals print the original's text.
	nova.nav_clear_route()
	print("  no-route refusal: '", nova.begin_hyperjump(), "'")
	nova.nav_click(first)
	nova.nav_shift_click(second)

	var fuel_before: int = nova.player_jumps_remaining()
	for hop in 2:
		print("  jump ", hop + 1, " from ", _sys_name(nova.nav_current_system()))
		if not _jump_once():
			return false
		print("  now in ", _sys_name(nova.nav_current_system()), " (", nova.nav_current_system(),
			")  jumps left ", nova.player_jumps_remaining(), "  route left ", nova.nav_route().size())
	var end: int = nova.nav_current_system()
	print("  fuel: ", fuel_before, " -> ", nova.player_jumps_remaining(), " jumps")
	return end == second


func _process(_delta: float) -> void:
	if _map_test_frames < 0:
		return
	_map_test_frames += 1
	if _map_test_frames == 5:
		var links: PackedInt32Array = nova.nav_links()
		var cur: int = nova.nav_current_system()
		var target := -1
		for i in range(0, links.size(), 2):
			if links[i] == cur: target = links[i + 1]
			elif links[i + 1] == cur: target = links[i]
			if target != -1: break
		var pos: Vector2 = _map._to_screen(_map._info[target]["pos"])
		var click := InputEventMouseButton.new()
		click.button_index = MOUSE_BUTTON_LEFT
		click.pressed = true
		click.position = pos
		_map._input(click)   # parse_input_event is not delivered headless
	if _map_test_frames == 10:
		print("MAP SELFTEST: size=", _map._canvas.size, " zoom=", _map._zoom, " route=", nova.nav_route(),
			" armed=", nova.nav_route_armed(), " selected=", nova.nav_selected())
		get_tree().quit(0)
