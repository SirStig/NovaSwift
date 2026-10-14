# Headless check of the multiplayer layer: address parsing, LAN beacon encode/decode, saved-servers Prefs
# round trip, server-option parsing, the Multiplayer hub building, and a real ENet handshake + relay between a
# server and two clients on localhost against a stand-in bridge (so it needs no new dylib). A second block talks
# to the real NovaWorld only if its bridge has the net_* API (SKIP otherwise).
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/net_ui_selfcheck.gd
extends SceneTree

const Proto = preload("res://net/NetProto.gd")
const Transport = preload("res://net/NetTransport.gd")
const Lan = preload("res://net/LanDiscovery.gd")
const NetPrefs = preload("res://net/NetPrefs.gd")
const ServerMain = preload("res://net/ServerMain.gd")
const Prefs = preload("res://Prefs.gd")
const Hub = preload("res://screens/multiplayer/MultiplayerHub.gd")
const Directory = preload("res://net/ServerDirectory.gd")

const PORT := 53791

var _fails := 0


## A bridge stand-in with the net_* surface; records what the transport feeds it.
class FakeNova extends RefCounted:
	var begun: Array = []
	var joined: Array = []
	var left: Array = []
	var received: Array = []
	var out: Array = []
	var ended: bool = false
	var manifest: String = "{\"signature\":\"abc\",\"plugins\":[]}"
	func net_begin(id: int, nm: String, host: bool, rules: String) -> bool:
		begun.append([id, nm, host, rules])
		return true
	func net_end() -> void:
		ended = true
	func net_peer_joined(id: int, nm: String) -> void:
		joined.append([id, nm])
	func net_peer_left(id: int) -> void:
		left.append(id)
	func net_receive(id: int, data: PackedByteArray) -> void:
		received.append([id, data])
	func net_outgoing() -> Array:
		var o: Array = out
		out = []
		return o
	func net_ready_manifest() -> String:
		return manifest
	func net_chat(_t: String) -> void:
		pass


func _ok(cond: bool, what: String) -> void:
	print(("PASS " if cond else "FAIL ") + what)
	if not cond:
		_fails += 1


func _pump(ts: Array, seconds: float) -> void:
	var n: int = int(seconds / 0.02)
	for i in n:
		for t in ts:
			(t as RefCounted).call("poll", 0.02)
		await create_timer(0.02).timeout


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_address()
	_test_beacon()
	_test_rules_and_manifest()
	_test_plugin_gate()
	_test_prefs()
	_test_server_args()
	_test_directory()
	await _test_hub()
	await _test_enet()
	_test_real_bridge()
	print("RESULT: ", "ALL PASS" if _fails == 0 else "%d FAIL" % _fails)
	quit(_fails)


func _test_address() -> void:
	var a: Dictionary = Proto.parse_address("192.168.1.20")
	_ok(bool(a["ok"]) and a["host"] == "192.168.1.20" and int(a["port"]) == Proto.DEFAULT_PORT, "address: bare host takes the default port")
	a = Proto.parse_address(" play.example.com:4000 ")
	_ok(bool(a["ok"]) and a["host"] == "play.example.com" and int(a["port"]) == 4000, "address: host:port, trimmed")
	a = Proto.parse_address("[::1]:5000")
	_ok(bool(a["ok"]) and a["host"] == "::1" and int(a["port"]) == 5000, "address: [ipv6]:port")
	a = Proto.parse_address("fe80::1")
	_ok(bool(a["ok"]) and a["host"] == "fe80::1" and int(a["port"]) == Proto.DEFAULT_PORT, "address: bare ipv6 literal")
	a = Proto.parse_address("nova://host:7")
	_ok(bool(a["ok"]) and a["host"] == "host" and int(a["port"]) == 7, "address: scheme prefix stripped")
	for bad in ["", "host:0", "host:99999", "host:abc", "[::1", "a b"]:
		_ok(not bool(Proto.parse_address(bad)["ok"]), "address: rejects '%s'" % bad)
	_ok(Proto.format_address("h", 53735) == "h" and Proto.format_address("h", 9) == "h:9" and Proto.format_address("::1", 9) == "[::1]:9", "address: format round trip")


func _test_beacon() -> void:
	var b: PackedByteArray = Proto.encode_beacon({"name": "Test Game", "players": 2, "max": 8, "ver": "9.9", "pw": true, "port": 4242, "rules": "safe", "dedicated": true})
	var d: Dictionary = Proto.decode_beacon(b)
	_ok(d.get("name") == "Test Game" and int(d["players"]) == 2 and int(d["max"]) == 8 and d["ver"] == "9.9" and bool(d["pw"]) and int(d["port"]) == 4242 and bool(d["dedicated"]), "beacon: encode/decode round trip")
	_ok(Proto.decode_beacon("garbage".to_utf8_buffer()).is_empty(), "beacon: garbage rejected")
	_ok(Proto.decode_beacon((Proto.BEACON_MAGIC + "{\"port\":0}").to_utf8_buffer()).is_empty(), "beacon: bad port rejected")
	_ok(Proto.is_query(Proto.query_packet()) and not Proto.is_query(b), "beacon: query packet recognised")
	var pk: PackedByteArray = Proto.pack_data(-1, PackedByteArray([1, 2, 3]))
	var u: Dictionary = Proto.unpack_data(pk)
	_ok(int(u["id"]) == -1 and (u["data"] as PackedByteArray) == PackedByteArray([1, 2, 3]), "frame: data packet round trip (id -1)")
	# A real loopback exchange through LanDiscovery's query path.
	var srv: RefCounted = Lan.new()
	var cli: RefCounted = Lan.new()
	var ok: bool = srv.start_announcing(func() -> Dictionary: return {"name": "Loop", "players": 1, "max": 4, "port": 53792, "dedicated": true}, 53792)
	if ok:
		cli.query("127.0.0.1", 53792)
		for i in 30:
			srv.poll(0.02)
			cli.poll(0.02)
			OS.delay_msec(10)
		var pr: Dictionary = cli.pings.get("127.0.0.1:53792", {})
		_ok(bool(pr.get("ok", false)) and (pr.get("info", {}) as Dictionary).get("name") == "Loop", "lan: unicast status query answered")
	else:
		print("SKIP lan query (could not bind): ", srv.last_error)
	srv.stop()
	cli.stop()


func _test_rules_and_manifest() -> void:
	_ok(Proto.preset_of(Proto.rules_for_preset("safe")) == "safe" and Proto.preset_of(Proto.rules_for_preset("full")) == "full", "rules: presets round trip")
	var r: Dictionary = Proto.rules_for_preset("safe")
	r["friendly_fire"] = true
	_ok(Proto.preset_of(r) == "custom", "rules: tweaked = custom")
	_ok(Proto.manifest_signature("{\"b\":1,\"a\":2}") == Proto.manifest_signature("{ \"a\": 2, \"b\": 1 }"), "manifest: key order and spacing ignored")


func _test_prefs() -> void:
	var old_path: String = Prefs.path
	Prefs.path = "user://net_selfcheck_settings.cfg"
	DirAccess.remove_absolute(Prefs.path)
	Prefs.load_all()
	_ok(NetPrefs.saved().is_empty() and NetPrefs.recent().is_empty(), "prefs: starts empty")
	NetPrefs.save_server("Home", "10.0.0.5", 53735, "pw")
	NetPrefs.save_server("Home2", "10.0.0.5", 53735)
	NetPrefs.save_server("Far", "far.example.com", 4000)
	_ok(NetPrefs.saved().size() == 2 and NetPrefs.is_saved("10.0.0.5", 53735), "prefs: saved servers de-duplicate by address")
	NetPrefs.add_recent("a", 1)
	NetPrefs.add_recent("b", 2)
	NetPrefs.add_recent("a", 1)
	_ok(NetPrefs.recent().size() == 2 and str((NetPrefs.recent()[0] as Dictionary)["host"]) == "a", "prefs: recent is newest-first, no duplicates")
	Prefs.load_all()   # re-read from disk
	_ok(NetPrefs.saved().size() == 2 and NetPrefs.recent().size() == 2, "prefs: saved + recent survive a reload")
	NetPrefs.remove_saved("far.example.com", 4000)
	_ok(NetPrefs.saved().size() == 1, "prefs: remove saved")
	var f: Dictionary = NetPrefs.host_form()
	f["password"] = "secret"
	f["max"] = 6
	NetPrefs.save_host_form(f)
	Prefs.load_all()
	_ok(int(NetPrefs.host_form()["max"]) == 6 and str(NetPrefs.host_form()["password"]) == "", "prefs: host form saved, password never written")
	DirAccess.remove_absolute(Prefs.path)
	Prefs.path = old_path
	Prefs.load_all()


func _test_server_args() -> void:
	var o: Dictionary = ServerMain.parse_args(PackedStringArray(["--port", "4000", "--name", "My Server", "--password=pw", "--max-players", "6", "--rules", "full", "--no-lan"]))
	_ok(int(o["port"]) == 4000 and o["name"] == "My Server" and o["password"] == "pw" and int(o["max_players"]) == 6 and o["rules"] == "full" and not bool(o["lan"]), "server args: flags parsed")
	o = ServerMain.parse_args(PackedStringArray())
	_ok(int(o["port"]) == Proto.DEFAULT_PORT and o["rules"] == "safe" and bool(o["lan"]), "server args: defaults")
	var cfg: String = "user://net_selfcheck_server.cfg"
	var c: ConfigFile = ConfigFile.new()
	c.set_value("server", "name", "FromCfg")
	c.set_value("server", "port", 5000)
	c.set_value("rules", "friendly_fire", true)
	c.save(cfg)
	o = ServerMain.parse_args(PackedStringArray(["--port", "6000"]), cfg)
	_ok(o["name"] == "FromCfg" and int(o["port"]) == 6000 and o["rules"] == "custom" and bool((o["custom_rules"] as Dictionary)["friendly_fire"]), "server args: cfg < command line, [rules] = custom")
	DirAccess.remove_absolute(cfg)


func _test_plugin_gate() -> void:
	var NP: GDScript = load("res://net/NetPlugins.gd") as GDScript
	var local: Dictionary = {"plugins": [{"id": "a", "name": "A", "contentHash": "1111111111111111aaaa"}, {"id": "x", "name": "X", "contentHash": "ffff"}], "tc": "", "addons": [], "sig": "s", "count": 2}
	var req: Array = [{"id": "a", "name": "A", "contentHash": "1111111111111111bbbb"}, {"id": "b", "name": "B", "contentHash": "2222"}, {"id": "c", "name": "C", "hash": "9"}]
	var cmp: Dictionary = NP.compare(req, "", local)
	_ok(not bool(cmp["ok"]) and str(cmp["rows"][0]["state"]) == "ok" and str(cmp["rows"][1]["state"]) == "missing", "plugins: matching prefix hash is ok, absent plug-in is missing")
	local["plugins"][0]["contentHash"] = "9999999999999999"
	cmp = NP.compare(req, "", local)
	_ok(str(cmp["rows"][0]["state"]) == "wrong" and (cmp["extra"] as Array).size() == 1 and str(cmp["extra"][0]["id"]) == "x", "plugins: other version and extras are reported")
	_ok(bool(NP.compare([{"id": "a", "name": "A", "hash": "9999999999999999"}], "tc1", {"plugins": [{"id": "a", "name": "A", "contentHash": "9999999999999999"}], "tc": "tc1"})["ok"]), "plugins: an identical set (and total conversion) matches")
	_ok(NP.compare([], "tcS", {"plugins": [], "tc": "tcL"})["tc_mismatch"], "plugins: a different total conversion is flagged")
	var w: Dictionary = NP.plugin_wire(local, true)
	_ok((w["plugins"] as Array).size() == 2 and str(w["plugins"][0]["hash"]).length() <= 16, "plugins: the wire form carries short hashes")
	var beacon: Dictionary = Proto.decode_beacon(Proto.encode_beacon({"name": "s", "port": 1, "plugin_wire": w, "dtls": true, "fp": "f", "cert": "C"}, true))
	_ok(int((beacon["plugins"] as Array).size()) == 2 and bool(beacon["dtls"]) and str(beacon["cert"]) == "C" and str(beacon["sig"]) == "s" and int(beacon["proto"]) == Proto.PROTO, "beacon: status reply carries plug-ins, key and protocol")
	var plain: Dictionary = Proto.decode_beacon(Proto.encode_beacon({"name": "s", "port": 1, "plugin_wire": w, "dtls": true, "fp": "f", "cert": "C"}, false))
	_ok((plain["plugins"] as Array).is_empty() and str(plain["cert"]) == "" and str(plain["sig"]) == "s", "beacon: the LAN broadcast carries only the signature, no list or certificate")
	var m_a: String = "{\"signature\":\"1\",\"plugins\":[{\"id\":\"a\",\"name\":\"A\",\"contentHash\":\"h\"}],\"cosmetic\":[]}"
	var m_b: String = "{\"signature\":\"1\",\"plugins\":[{\"id\":\"a\",\"name\":\"A\",\"contentHash\":\"h\"}],\"cosmetic\":[{\"id\":\"skin\",\"name\":\"Skin\"}]}"
	_ok(Proto.manifest_signature(m_a) == Proto.manifest_signature(m_b), "manifest: cosmetic plug-ins never change the gate signature")


func _test_hub() -> void:
	var svc: Node = root.get_node_or_null("NetService")
	if svc == null:
		svc = (load("res://net/NetService.gd") as GDScript).new()
		svc.name = "NetService"
		root.add_child(svc)
	await process_frame
	var fake: FakeNova = FakeNova.new()
	for t in Hub.TABS:
		var hub: CanvasLayer = Hub.new()
		root.add_child(hub)
		hub.setup(fake, "Host" if t == "Session" else t)
		await process_frame
		_ok(hub.is_inside_tree() and hub.first_control != null, "hub: builds the %s tab headless" % t)
		hub.queue_free()
		await process_frame
	_ok(not svc.hub_open, "hub: releases the keyboard on close")
	_ok(Hub.TABS == ["Session", "Browse", "Host"], "hub: tabs are Browse / Host (+ Session while connected)")
	var hb: CanvasLayer = Hub.new()
	root.add_child(hb)
	hb.setup(fake, "")
	await process_frame
	_ok(hb.tab == "Browse", "hub: opens on Browse")
	var rows: Array = hb._browse_rows()
	_ok(rows is Array, "hub: merged browse list builds")
	var merged: Dictionary = {"sources": ["Saved"], "host": "h", "port": 1, "name": "A", "players": -1, "state": "checking", "pw": false}
	Hub._merge_row(merged, {"sources": ["Public"], "host": "h", "port": 1, "name": "B", "players": 3, "state": "online", "pw": true, "region": "eu"})
	_ok((merged["sources"] as Array).size() == 2 and int(merged["players"]) == 3 and str(merged["state"]) == "online" and bool(merged["pw"]) and str(merged["name"]) == "A" and str(merged["region"]) == "eu",
		"hub: a saved + public duplicate merges into one row")
	hb._quick_connect()
	await process_frame
	_ok(root.find_child("NovaAlert", true, false) != null, "hub: Quick Connect opens its dialog")
	hb.queue_free()
	await process_frame


func _wait_for(cond: Callable, ts: Array, seconds: float) -> bool:
	var n: int = int(seconds / 0.02)
	for i in n:
		for t in ts:
			(t as RefCounted).call("poll", 0.02)
		if cond.call():
			return true
		await create_timer(0.02).timeout
	return false


func _test_enet() -> void:
	var sn: FakeNova = FakeNova.new()
	var c1n: FakeNova = FakeNova.new()
	var c2n: FakeNova = FakeNova.new()
	var srv: RefCounted = Transport.new()
	var c1: RefCounted = Transport.new()
	var c2: RefCounted = Transport.new()
	var evs: Array = []
	for t in [srv, c1, c2]:
		(t as RefCounted).connect("event", func(e: Dictionary) -> void: evs.append(e))
	var err: int = srv.host(sn, {"port": PORT, "max_players": 3, "name": "Test", "display_name": "Host", "password": "pw", "has_local_player": true})
	_ok(err == OK and sn.begun.size() == 1 and sn.begun[0][0] == 1 and sn.begun[0][2] == true, "enet: server up, bridge net_begin(1, ..., host)")
	var all: Array = [srv, c1, c2]
	# wrong password
	c1.join(c1n, "127.0.0.1", PORT, "Alice", "nope", {"skip_probe": true})
	var rej: bool = await _wait_for(func() -> bool: return evs.any(func(e: Dictionary) -> bool: return e["type"] == "rejected" and e["code"] == "password"), all, 3.0)
	_ok(rej, "enet: wrong password is rejected with a reason")
	# manifest mismatch
	c1n.manifest = "{\"signature\":\"zzz\",\"plugins\":[{\"id\":\"x\",\"name\":\"X\",\"contentHash\":\"h\"}]}"
	c1 = Transport.new()
	c1.connect("event", func(e: Dictionary) -> void: evs.append(e))
	evs.clear()
	c1.join(c1n, "127.0.0.1", PORT, "Alice", "pw", {"skip_probe": true})
	all = [srv, c1, c2]
	rej = await _wait_for(func() -> bool: return evs.any(func(e: Dictionary) -> bool: return e["type"] == "rejected" and e["code"] == "plugins"), all, 3.0)
	_ok(rej, "enet: plug-in manifest mismatch is rejected")
	# good joins
	c1n = FakeNova.new()
	c1 = Transport.new()
	c1.connect("event", func(e: Dictionary) -> void: evs.append(e))
	evs.clear()
	c1.join(c1n, "127.0.0.1", PORT, "Alice", "pw", {"skip_probe": true})
	c2.join(c2n, "127.0.0.1", PORT, "Bob", "pw", {"skip_probe": true})
	all = [srv, c1, c2]
	var good: bool = await _wait_for(func() -> bool: return c1.state == "connected" and c2.state == "connected" and srv.ready_count() == 2, all, 4.0)
	_ok(good, "enet: two clients complete the handshake")
	if good:
		_ok(c1n.begun.size() == 1 and c1n.begun[0][2] == false and c1.local_id != 1 and c1.local_id > 0, "enet: client bridge net_begin(local, name, guest)")
		_ok(sn.joined.size() == 2 and c1n.joined.any(func(j: Array) -> bool: return j[0] == 1), "enet: server bridge sees both guests; guests learn the host (peer 1)")
		await _wait_for(func() -> bool: return c1n.joined.size() >= 2 and c2n.joined.size() >= 2, all, 2.0)
		_ok(c1n.joined.any(func(j: Array) -> bool: return j[0] == c2.local_id), "enet: clients learn of each other through the server")
		# data relay: c1 broadcasts reliably, c2 -> c1 directly, server -> all unreliable
		c1n.out.append({"to": -1, "reliable": true, "data": PackedByteArray([7, 7])})
		c2n.out.append({"to": c1.local_id, "reliable": false, "data": PackedByteArray([9])})
		sn.out.append({"to": -1, "reliable": false, "data": PackedByteArray([5])})
		await _wait_for(func() -> bool: return sn.received.size() >= 1 and c2n.received.size() >= 2 and c1n.received.size() >= 2, all, 3.0)
		_ok(sn.received.any(func(r: Array) -> bool: return r[0] == c1.local_id and r[1] == PackedByteArray([7, 7])), "relay: client broadcast reaches the server bridge tagged with the sender")
		_ok(c2n.received.any(func(r: Array) -> bool: return r[0] == c1.local_id and r[1] == PackedByteArray([7, 7])), "relay: ... and the other client")
		_ok(c1n.received.any(func(r: Array) -> bool: return r[0] == c2.local_id and r[1] == PackedByteArray([9])), "relay: client-to-client direct message (unreliable)")
		_ok(c1n.received.any(func(r: Array) -> bool: return r[0] == 1 and r[1] == PackedByteArray([5])), "relay: server broadcast reaches clients as peer 1")
		await _wait_for(func() -> bool: return c1.rtt_ms >= 0, all, 4.0)
		_ok(c1.rtt_ms >= 0, "enet: client measures a ping")
		# a fourth connection is refused as full (max 3 incl. host = 2 guests)
		var c3: RefCounted = Transport.new()
		var evs3: Array = []
		c3.connect("event", func(e: Dictionary) -> void: evs3.append(e))
		c3.join(FakeNova.new(), "127.0.0.1", PORT, "Cara", "pw", {"skip_probe": true})
		all.append(c3)
		var full: bool = await _wait_for(func() -> bool: return evs3.any(func(e: Dictionary) -> bool: return e["type"] == "rejected" and e["code"] == "full"), all, 3.0)
		_ok(full, "enet: a full server refuses with 'full'")
		# leave
		var gone: int = c2.local_id
		c2.close("")
		await _wait_for(func() -> bool: return sn.left.has(gone) and c1n.left.has(gone), [srv, c1], 3.0)
		_ok(sn.left.has(gone) and c1n.left.has(gone) and c2n.ended, "enet: clean leave reaches the server and the other client; bridge net_end called")
		# kick
		var cid: int = c1.local_id
		srv.kick(cid, "bye")
		var kicked: bool = await _wait_for(func() -> bool: return evs.any(func(e: Dictionary) -> bool: return e["type"] == "kicked"), [srv, c1], 3.0)
		_ok(kicked and c1n.ended, "enet: kick delivers the reason and ends the client session")
	srv.close("")
	_ok(sn.ended, "enet: server close ends the bridge session")
	# refused port: nothing listening -> timeout / disconnect event, not a hang
	var lone: RefCounted = Transport.new()
	var evs4: Array = []
	lone.connect("event", func(e: Dictionary) -> void: evs4.append(e))
	lone.join(FakeNova.new(), "127.0.0.1", PORT + 7, "Dan", "")
	await _wait_for(func() -> bool: return evs4.any(func(e: Dictionary) -> bool: return e["type"] in ["timeout", "disconnected"]), [lone], 14.0)
	_ok(evs4.any(func(e: Dictionary) -> bool: return e["type"] in ["timeout", "disconnected"]), "enet: connecting to nothing ends with a timeout event")
	lone.close("", false)


func _test_real_bridge() -> void:
	if not ClassDB.class_exists("NovaWorld"):
		print("SKIP real bridge (NovaWorld not loaded)")
		return
	var w: Object = ClassDB.instantiate("NovaWorld")
	if not w.has_method("net_begin"):
		print("SKIP real bridge: this dylib predates the net_* API")
		w.free()
		return
	var ok: bool = bool(w.net_begin(1, "[Server]", true, JSON.stringify(Proto.rules_for_preset("safe"))))
	_ok(ok, "bridge: net_begin(1, host) accepts a pilot-less host")
	var st: Variant = JSON.parse_string(str(w.net_state()))
	_ok(st is Dictionary and bool((st as Dictionary).get("active", false)), "bridge: net_state reports an active session")
	_ok(w.net_outgoing() is Array, "bridge: net_outgoing returns an Array")
	w.net_end()
	w.free()


func _test_directory() -> void:
	var good: String = JSON.stringify({"version": 1, "servers": [
		{"id": "a", "name": "Alpha", "host": "a.example.com", "port": 53735, "region": "eu", "rules": "safe", "maxPlayers": 8, "website": "http://x", "plugins": [{"id": "p", "name": "P", "contentHash": "h"}]},
		{"id": "b", "name": "Beta", "host": "b.example.com", "port": 6000, "region": "oc", "rules": "full", "maxPlayers": 4},
		{"id": "dup", "host": "A.example.com", "port": 53735}, {"id": "bad", "host": "", "port": 1}, {"id": "bad2", "host": "h", "port": 70000}]})
	var r: Dictionary = Directory.parse(good)
	_ok(bool(r["ok"]) and (r["entries"] as Array).size() == 2, "directory: parses, drops duplicates and invalid entries")
	_ok(str((r["entries"][0] as Dictionary)["website"]) == "" and (r["entries"][0]["plugins"] as Array).size() == 1, "directory: http websites are dropped, plug-ins kept")
	_ok(not bool(Directory.parse("[1]")["ok"]) and not bool(Directory.parse("nope")["ok"]), "directory: rejects a wrong shape")
	_ok(bool(Directory.parse(JSON.stringify({"version": 1, "servers": []}))["ok"]), "directory: empty list is valid")
	var ea: Dictionary = r["entries"][0]
	var eb: Dictionary = r["entries"][1]
	var live_a: Dictionary = {"ok": true, "rtt_ms": 80, "info": {"players": 2, "max": 8, "ver": Proto.game_version(), "pw": true}}
	var live_b: Dictionary = {"ok": true, "rtt_ms": 30, "info": {"players": 0, "max": 4, "ver": "0.0.0-other", "pw": false, "proto": 99}}
	var rows: Array = [Directory.row_for(ea, live_a, false), Directory.row_for(eb, live_b, false), Directory.row_for(ea, {}, false)]
	_ok(str(rows[0]["state"]) == "online" and bool(rows[0]["compatible"]) and bool(rows[0]["pw"]), "directory: online row, compatible, password")
	_ok(not bool(rows[1]["compatible"]) and str(rows[2]["state"]) == "offline", "directory: protocol mismatch and offline rows")
	var live_c: Dictionary = {"ok": true, "rtt_ms": 30, "info": {"players": 0, "max": 4, "ver": "0.0.0-other", "pw": false}}
	_ok(bool(Directory.row_for(eb, live_c, false)["compatible"]), "directory: a different game version with the same protocol is still compatible")
	_ok(str(Directory.row_for(ea, {}, true)["state"]) == "checking", "directory: checking state")
	var sorted: Array = Directory.sort_rows(rows)
	_ok(int(sorted[0]["ping"]) == 30 and str(sorted[2]["state"]) == "offline", "directory: sorted by ping, offline last")
	_ok(Directory.filter_rows(rows, {"compatible": true}).size() == 1, "directory: compatible-only filter")
	_ok(Directory.filter_rows(rows, {"has_players": true}).size() == 1, "directory: has-players filter")
	_ok(Directory.filter_rows(rows, {"region": "oc"}).size() == 1, "directory: region filter")
	var e: Dictionary = Directory.build_entry({"name": "My Cool Server!", "port": 6000, "rules": "full", "max_players": 12, "region": "mars"}, "", [{"id": "x", "name": "X", "contentHash": "h"}], "2026-10-13")
	_ok(str(e["id"]) == "my-cool-server" and str(e["region"]) == "global" and int(e["port"]) == 6000 and (e["plugins"] as Array).size() == 1, "directory: --public entry (slug, region fallback, plug-ins)")
	var o: Dictionary = ServerMain.parse_args(PackedStringArray(["--public", "--upnp", "--region", "eu", "--owner", "Jo", "--address", "play.x.com"]))
	_ok(bool(o["public"]) and bool(o["upnp"]) and o["region"] == "eu" and o["owner"] == "Jo" and o["address"] == "play.x.com", "server args: --public --upnp --region --owner --address")
