# Headless self-check for the multiplayer bridge (net_*): two NovaWorld instances, each with its
# own NetSession, with the "network" being this script moving net_outgoing() -> net_receive().
# SKIPs (exit 0) on a bridge dylib that predates net_begin. Run:
#   NOVA_DATA_DIR=data/base godot --headless --path godot -s res://tests/net_bridge_selfcheck.gd
extends SceneTree


func _init() -> void:
	_run()


func _run() -> void:
	await process_frame
	if not ClassDB.class_exists("NovaWorld"):
		print("  SKIP no NovaWorld class (extension not loaded)")
		quit(0)
		return
	var a: Object = ClassDB.instantiate("NovaWorld")
	var b: Object = ClassDB.instantiate("NovaWorld")
	if not a.has_method("net_begin") or not a.has_method("net_outgoing"):
		print("  SKIP bridge predates net_begin (rebuild it)")
		a.free()
		b.free()
		quit(0)
		return
	root.add_child(a)
	root.add_child(b)
	var ok := true

	# Optional world: with game data both players fly the same system, so sync engages.
	var data := OS.get_environment("NOVA_DATA_DIR")
	if data == "":
		data = ProjectSettings.globalize_path("res://") + "../data/base"
	var have_world: bool = a.load_game(data) and b.load_game(data)
	var sys := -1
	if have_world:
		have_world = a.make_world(-1)
		if have_world:
			sys = int(a.nav_current_system())
			have_world = b.make_world(sys)
	if not have_world:
		print("  note: no game data, running session-only checks")

	# Host = peer 1, guest = peer 2000 (ids are Godot multiplayer peer ids).
	ok = _check("host begins", a.net_begin(1, "Host", true, "")) and ok
	ok = _check("guest begins", b.net_begin(2000, "Guest", false, "")) and ok
	var sa: Dictionary = JSON.parse_string(a.net_state())
	ok = _check("state active/host", sa.get("active", false) and sa.get("is_host", false) and int(sa.get("local_id", 0)) == 1) and ok

	# The frontend reports the link both ways, then pumps.
	a.net_peer_joined(2000, "Guest")
	b.net_peer_joined(1, "Host")
	_pump(a, 1, b, 2000)

	var st_a: Dictionary = JSON.parse_string(a.net_state())
	var st_b: Dictionary = JSON.parse_string(b.net_state())
	if have_world:
		# Presence is announced on the first step() once a world exists.
		a.step(1.0 / 30.0)
		b.step(1.0 / 30.0)
		_pump(a, 1, b, 2000)
		st_a = JSON.parse_string(a.net_state())
		st_b = JSON.parse_string(b.net_state())
		ok = _check("both see 2 players", st_a.players.size() == 2 and st_b.players.size() == 2) and ok
		ok = _check("co-located", bool(st_b.players[0].in_my_system) and bool(st_b.players[1].in_my_system)) and ok
		ok = _check("authority is smallest id", int(st_a.authority_id) == 1 and int(st_b.authority_id) == 1) and ok
		for i in 30:
			a.step(1.0 / 30.0)
			b.step(1.0 / 30.0)
			_pump(a, 1, b, 2000)
		ok = _check("guest world mirrors the host ship", b.ship_count() >= 2) and ok
		ok = _check("host world holds the guest ship", a.ship_count() >= 2) and ok

	# Chat and rules ride the same pump.
	a.net_chat("hello from host")
	_pump(a, 1, b, 2000)
	var evs: Array = JSON.parse_string(b.net_events())
	var got_chat := false
	for e in evs:
		if e.get("type", "") == "chat" and e.get("text", "") == "hello from host":
			got_chat = true
	ok = _check("guest received chat event", got_chat) and ok

	a.net_set_rules('{"preset":"safe"}')
	_pump(a, 1, b, 2000)
	var rb: Dictionary = JSON.parse_string(b.net_state()).rules
	ok = _check("guest adopted host rules", not bool(rb.pvp_damage_real)) and ok
	ok = _check("manifest json", JSON.parse_string(a.net_ready_manifest()) is Dictionary) and ok

	# Leaving.
	a.net_peer_left(2000)
	var after: Dictionary = JSON.parse_string(a.net_state())
	ok = _check("guest dropped from roster", after.players.size() <= 1) and ok
	a.net_end()
	b.net_end()
	a.net_outgoing()
	b.net_outgoing()
	ok = _check("ended -> inactive", not bool(JSON.parse_string(a.net_state()).active)) and ok

	print("NET BRIDGE SELFCHECK ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


## Deliver every queued packet between the two worlds until quiet (what ENet would do).
func _pump(a: Object, a_id: int, b: Object, b_id: int) -> void:
	for _round in 8:
		var moved := false
		for p in a.net_outgoing():
			moved = true
			if int(p.to) == -1 or int(p.to) == b_id:
				b.net_receive(a_id, p.data)
		for p in b.net_outgoing():
			moved = true
			if int(p.to) == -1 or int(p.to) == a_id:
				a.net_receive(b_id, p.data)
		if not moved:
			return


func _check(label: String, cond: bool) -> bool:
	print(("  ok   " if cond else "  FAIL ") + label)
	return cond
