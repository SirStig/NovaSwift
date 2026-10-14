# Headless security check of the multiplayer layer: name / chat / BBCode sanitising, the NSQ1 v2 anti-amplification
# helpers (request, guard, reply cap), NSB1 decode clamping, garbage-packet fuzzing, and a real ENet loopback server
# exercising the chat limiter, K_REPORT kicks, reserved names and malformed packets.
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/net_security_selfcheck.gd
extends SceneTree

const Proto = preload("res://net/NetProto.gd")
const Transport = preload("res://net/NetTransport.gd")
const NetPrefs = preload("res://net/NetPrefs.gd")

const PORT := 53794

var _fails: int = 0


class FakeNova extends RefCounted:
	var joined: Array = []
	var received: Array = []
	func net_begin(_id: int, _nm: String, _host: bool, _rules: String) -> bool:
		return true
	func net_end() -> void:
		pass
	func net_peer_joined(id: int, nm: String) -> void:
		joined.append([id, nm])
	func net_peer_left(_id: int) -> void:
		pass
	func net_receive(id: int, data: PackedByteArray) -> void:
		received.append([id, data])
	func net_outgoing() -> Array:
		return []
	func net_ready_manifest() -> String:
		return "{\"signature\":\"abc\",\"plugins\":[]}"


func _ok(cond: bool, what: String) -> void:
	print(("PASS " if cond else "FAIL ") + what)
	if not cond:
		_fails += 1


func _initialize() -> void:
	_run.call_deferred()


func _run() -> void:
	_test_names()
	_test_chat_bbcode()
	_test_query()
	_test_beacon_clamp()
	_test_fuzz()
	_test_prefs_block()
	await _test_enet()
	print("net_security_selfcheck: %s" % ("OK" if _fails == 0 else "%d FAILED" % _fails))
	quit(1 if _fails > 0 else 0)


func _test_names() -> void:
	_ok(Proto.clean_name("  A\u200Bl\u202Eic\u0007e \t  Smith  ") == "Alice Smith" or Proto.clean_name("  A\u200Bl\u202Eic\u0007e   Smith  ") == "Alice Smith", "clean_name strips zero-width / bidi / control, collapses spaces")
	_ok(Proto.clean_name("a\u00A0\u00A0\u3000b") == "a b", "clean_name folds exotic spaces")
	_ok(Proto.clean_name("\u200B\u200D\uFEFF", "Pilot") == "Pilot", "clean_name: only invisible -> fallback")
	_ok(Proto.clean_name("x".repeat(100)).length() == 24 and Proto.clean_name("y".repeat(100), "n", 40).length() == 40, "clean_name caps 24 / 40")
	_ok(Proto.clean_name("a\u0085b\u007Fc\u0080d\U0E0041") == "abcd", "clean_name strips C1, DEL and tag characters")
	for bad in ["Server", "ADMIN", "Adm1n", "S3rv3r", "[Server]", "m0d", "Host", "n0vasw1ft", "g_m", "Op3rator", "sys0p", "0wner", "server2", "Admin007", "\u0430dmin"]:
		_ok(Proto.clean_player_name(bad, "Pilot 9") == "Pilot 9", "reserved name rejected: " + bad)
	for good in ["Alice", "Servers of Doom", "Moderately", "Bob_5"]:
		_ok(Proto.clean_player_name(good, "Pilot 9") == good, "ordinary name kept: " + good)
	_ok(Proto.clean_player_name("a[b]c") == "abc", "clean_player_name removes brackets")
	_ok(Proto.clean_player_name(12345, "F") == "F" and Proto.clean_player_name(null, "F") == "F", "clean_player_name: non-string -> fallback")


func _test_chat_bbcode() -> void:
	for evil in ["[b]x[/b]", "[url=evil]click[/url]", "[img]res://x.png[/img]", "[color=red]hi[/color]"]:
		var esc: String = Proto.escape_bbcode(evil)
		_ok(not esc.contains("[b") and not esc.contains("[u") and not esc.contains("[i") and not esc.contains("[c"), "escape_bbcode inert: " + evil)
		var rt: RichTextLabel = RichTextLabel.new()
		rt.bbcode_enabled = true
		rt.parse_bbcode(esc)
		_ok(rt.get_parsed_text() == evil, "escaped text renders literally: " + evil)
		rt.free()
		var nm: String = Proto.clean_player_name(evil, "Pilot")
		_ok(not nm.contains("[") and not nm.contains("]"), "player name has no brackets: " + evil)
	_ok(Proto.clean_chat("  hi\u200B there\n\u0001 ") == "hi there", "clean_chat strips control/format, trims")
	_ok(Proto.clean_chat("x".repeat(500)).length() == 200, "clean_chat caps 200")
	_ok(Proto.clean_chat("\u200B\u0001") == "" and Proto.clean_chat(5) == "", "clean_chat: empty / non-string -> ''")


func _test_query() -> void:
	var q: PackedByteArray = Proto.build_query()
	_ok(q.size() == 1200 and q.slice(0, 4).get_string_from_ascii() == "NSQ1" and q[4] == 2, "NSQ1 v2 request: 1200 bytes, 'NSQ1' 0x02")
	_ok(q.slice(8).count(0) == 1192, "NSQ1 v2 request: zero padded")
	_ok(Proto.query_kind(q) == Proto.Q_V2 and Proto.query_kind("NSQ1".to_utf8_buffer()) == Proto.Q_LEGACY, "query_kind: v2 and legacy")
	var short: PackedByteArray = q.slice(0, 511)
	_ok(Proto.query_kind(short) == Proto.Q_DROP, "request shorter than 512 is ignored")
	var big: PackedByteArray = q.duplicate()
	big.resize(1600)
	_ok(Proto.query_kind(big) == Proto.Q_DROP, "oversize request is ignored")
	var wrong: PackedByteArray = q.duplicate()
	wrong[4] = 9
	_ok(Proto.query_kind(wrong) == Proto.Q_DROP and Proto.query_kind(PackedByteArray([1, 2, 3, 4])) == Proto.Q_DROP, "bad version byte / garbage ignored")
	_ok(Proto.query_reply_cap(1200) == 1200 and Proto.query_reply_cap(1500) == 1200 and Proto.query_reply_cap(600) == 600, "reply cap = min(request, 1200)")
	var big_info: Dictionary = {"name": "S", "port": 53735, "dtls": true, "fp": "f", "cert": "C".repeat(900),
		"plugin_wire": {"sig": "s", "count": 40, "tc": "", "plugins": _fake_plugins(40), "addons": []}}
	var full: PackedByteArray = Proto.encode_status_reply(big_info, 1200)
	_ok(full.size() > 0 and full.size() <= 1200, "status reply fits the cap (%d bytes)" % full.size())
	var cut: PackedByteArray = Proto.encode_status_reply(big_info, 1200)
	var cut_info: Dictionary = Proto.decode_beacon(cut)
	_ok(cut.size() <= 1200 and not cut_info.is_empty() and (cut_info["plugins"] as Array).is_empty() and cut_info["sig"] == "s" and cut_info["pcount"] == 40, "over-size reply drops the plug-in list (sig / pcount / tc stay)")
	var legacy: PackedByteArray = Proto.legacy_reply()
	_ok(legacy.size() <= 64 and legacy.get_string_from_utf8().contains("upgrade"), "legacy reply is the tiny upgrade notice")
	var v1: PackedByteArray = Proto.build_query()
	v1[4] = 1
	_ok(Proto.query_kind(v1) == Proto.Q_V2, "version byte 1 (the status prober) is accepted")
	# guard
	var g: Proto.QueryGuard = Proto.QueryGuard.new()
	var t: float = 100.0
	var served: int = 0
	for i in 20:
		if g.admit("9.9.9.9", q, t) != Proto.Q_DROP:
			served += 1
	_ok(served == 5, "token bucket: burst of 5 then dropped (got %d)" % served)
	_ok(g.admit("9.9.9.9", q, t + 0.6) == Proto.Q_V2 and g.admit("9.9.9.9", q, t + 0.6) == Proto.Q_DROP, "token bucket refills 2/s")
	_ok(g.admit("8.8.8.8", q, t) == Proto.Q_V2, "another IP has its own bucket")
	var lg: Proto.QueryGuard = Proto.QueryGuard.new()
	var legacy_q: PackedByteArray = "NSQ1".to_utf8_buffer()
	_ok(lg.admit("1.1.1.1", legacy_q, 10.0) == Proto.Q_LEGACY and lg.admit("1.1.1.1", legacy_q, 12.0) == Proto.Q_DROP and lg.admit("1.1.1.1", legacy_q, 15.5) == Proto.Q_LEGACY, "legacy: 1 per IP per 5 s")
	var gl: Proto.QueryGuard = Proto.QueryGuard.new()
	var ok_legacy: int = 0
	for i in 60:
		if gl.admit("10.0.%d.%d" % [i / 250, i % 250], legacy_q, 50.0) == Proto.Q_LEGACY:
			ok_legacy += 1
	_ok(ok_legacy == 20, "legacy: 20 per second globally (got %d)" % ok_legacy)
	var tg: Proto.QueryGuard = Proto.QueryGuard.new()
	for i in 6000:
		tg.admit("172.%d.%d.%d" % [i / 65536 % 256, i / 256 % 256, i % 256], q, 200.0 + i * 0.0001)
	_ok(tg.buckets.size() <= 4096, "guard table capped at 4096 IPs (%d)" % tg.buckets.size())
	tg.admit("1.2.3.4", q, 400.0)
	_ok(tg.buckets.size() <= 4096 and tg.buckets.has("1.2.3.4"), "old entries are pruned, new IPs are admitted again")


func _fake_plugins(n: int) -> Array:
	var out: Array = []
	for i in n:
		out.append({"id": "plugin-%d" % i, "name": "Plug-in number %d" % i, "hash": "0123456789abcdef"})
	return out


func _test_beacon_clamp() -> void:
	var good: Dictionary = {"name": "[b]Evil[/b]\u200B Server", "players": 9999999, "max": -5, "ver": "v".repeat(200), "rules": "r".repeat(99), "port": 5000,
		"plugins": _fake_plugins(200), "addons": ["a".repeat(500)], "sig": "s".repeat(9000), "pcount": 99999}
	var pkt: PackedByteArray = (Proto.BEACON_MAGIC + JSON.stringify(good)).to_utf8_buffer()
	_ok(pkt.size() > 6144 and Proto.decode_beacon(pkt).is_empty(), "NSB1 over 6144 bytes rejected")
	good["sig"] = "s".repeat(100)
	var many: Array = []
	for i in 120:
		many.append({"id": "p%d" % i, "name": "n%d" % i, "hash": "h"})
	good["plugins"] = many
	pkt = (Proto.BEACON_MAGIC + JSON.stringify(good)).to_utf8_buffer()
	var d: Dictionary = Proto.decode_beacon(pkt)
	_ok(not d.is_empty() and (d["plugins"] as Array).size() <= 64 and int(d["players"]) == 4096 and int(d["max"]) == 0, "NSB1: players/max clamped, plugins <= 64")
	_ok(str(d["ver"]).length() <= 32 and str(d["rules"]).length() <= 16 and (d["addons"] as Array).size() == 1 and str((d["addons"] as Array)[0]).length() <= 64, "NSB1: ver / rules / addon strings capped")
	_ok(str(d["name"]).length() <= 40 and not str(d["name"]).contains("\u200B"), "NSB1: name cleaned")
	_ok(int(d["pcount"]) == 4096, "NSB1: pcount clamped")
	for junk in ["[1,2]", "\"str\"", "12", "null", "{\"port\":\"x\"}", "{\"port\":{\"a\":1}}", "{\"port\":5,\"name\":[1],\"players\":{}, \"plugins\":\"no\", \"addons\":[1,{},null]}"]:
		var r: Dictionary = Proto.decode_beacon((Proto.BEACON_MAGIC + junk).to_utf8_buffer())
		_ok(r.is_empty() or (r["plugins"] as Array).is_empty(), "NSB1 junk survives: " + junk)


func _test_fuzz() -> void:
	var rng: RandomNumberGenerator = RandomNumberGenerator.new()
	rng.seed = 424242
	var json_bits: Array = ["{", "}", "[", "]", "\"", ":", ",", "null", "true", "-1", "\"name\"", "\"id\"", "\"text\"", "\"peers\"", "\"plugins\"",
		"\"manifest\"", "\"detail\"", "{\"id\":", "NaN", "9223372036854775807", "\"[b]x\""]
	var kinds: Array = [Proto.K_HELLO, Proto.K_WELCOME, Proto.K_REJECT, Proto.K_PEER_JOIN, Proto.K_PEER_LEFT, Proto.K_KICK, Proto.K_PING, Proto.K_PONG, Proto.K_CHAT, Proto.K_REPORT, Proto.K_DATA, 0, 0x7F, 0xFF]
	var guard: Proto.QueryGuard = Proto.QueryGuard.new()
	for i in 3000:
		var pkt: PackedByteArray = PackedByteArray()
		var mode: int = rng.randi() % 4
		if mode == 0:
			pkt.resize(rng.randi() % 300)
			for j in pkt.size():
				pkt[j] = rng.randi() & 0xFF
		elif mode == 1:
			pkt.append(kinds[rng.randi() % kinds.size()])
			var s: String = ""
			for j in rng.randi_range(1, 14):
				s += str(json_bits[rng.randi() % json_bits.size()])
			pkt.append_array(s.to_utf8_buffer())
		elif mode == 2:
			pkt.append(kinds[rng.randi() % kinds.size()])
			pkt.append_array(JSON.stringify({"id": rng.randi(), "name": "[b]" + "x".repeat(rng.randi() % 80), "text": "\u202E" + "t".repeat(rng.randi() % 400),
				"peers": [1, "a", {"id": "x", "name": 5}, null], "plugins": [[], {}, 7], "manifest": 5, "reason": {}, "detail": [1], "t": "nan", "rtt": 1e300}).to_utf8_buffer())
		else:
			pkt = Proto.BEACON_MAGIC.to_utf8_buffer()
			pkt.append_array(JSON.stringify({"port": rng.randi() % 70000, "players": rng.randf() * 1e12, "name": [rng.randi()], "plugins": [rng.randi(), {"id": [1]}]}).to_utf8_buffer())
		var body: Dictionary = Proto.unpack_control(pkt)
		Proto.unpack_data(pkt)
		Proto.decode_beacon(pkt)
		Proto.query_kind(pkt)
		guard.admit("5.5.5.%d" % (i % 200), pkt, float(i) * 0.01)
		Proto.manifest_signature(Proto.safe_utf8(pkt))
		for k in body:
			Proto.clean_player_name(body[k])
			Proto.clean_chat(body[k])
			Proto.clean_text(body[k], 50)
			Proto.num_int(body[k], -5, 5)
			Proto.num_float(body[k], -1.0, 1.0)
	_ok(true, "fuzz: 3000 random packets through the decoders without error")


func _test_prefs_block() -> void:
	for n in NetPrefs.blocked():
		NetPrefs.unblock(n)
	for i in 70:
		NetPrefs.block("Troll%d" % i)
	_ok(NetPrefs.blocked().size() == 64 and NetPrefs.is_blocked("troll69") and not NetPrefs.is_blocked("Troll0"), "block list capped at 64 (oldest dropped), case-insensitive")
	for n in NetPrefs.blocked():
		NetPrefs.unblock(n)
	_ok(NetPrefs.blocked().is_empty(), "unblock removes entries")


func _pump(ts: Array, seconds: float) -> void:
	for i in int(seconds / 0.02):
		for t in ts:
			(t as RefCounted).call("poll", 0.02)
		await create_timer(0.02).timeout


func _wait_for(cond: Callable, ts: Array, seconds: float) -> bool:
	for i in int(seconds / 0.02):
		for t in ts:
			(t as RefCounted).call("poll", 0.02)
		if cond.call():
			return true
		await create_timer(0.02).timeout
	return false


func _client(name_: String, evs: Array) -> Array:
	var t: RefCounted = Transport.new()
	t.connect("event", func(e: Dictionary) -> void: evs.append(e))
	var n: FakeNova = FakeNova.new()
	t.join(n, "127.0.0.1", PORT, name_, "", {"skip_probe": true})
	return [t, n]


func _test_enet() -> void:
	var sn: FakeNova = FakeNova.new()
	var srv: RefCounted = Transport.new()
	var sevs: Array = []
	srv.connect("event", func(e: Dictionary) -> void: sevs.append(e))
	_ok(srv.host(sn, {"port": PORT, "max_players": 8, "name": "Sec", "display_name": "[Server]", "has_local_player": false}) == OK, "enet: server up")
	var evs: Array = [[], [], [], [], []]
	var cl: Array = []
	for i in 4:
		cl.append(_client(["Ann", "Bob", "Admin", "Cy[b]"][i], evs[i]))
	var all: Array = [srv]
	for c in cl:
		all.append(c[0])
	var up: bool = await _wait_for(func() -> bool: return srv.ready_count() == 4, all, 6.0)
	_ok(up, "enet: 4 clients joined")
	if not up:
		srv.close("", false)
		return
	var names: Array = []
	for id in srv.peers:
		names.append(str((srv.peers[id] as Dictionary)["name"]))
	_ok(not names.has("Admin") and names.has("Ann") and not names.any(func(n: String) -> bool: return n.contains("[")), "server renamed the reserved / bracket names: %s" % str(names))
	var a: RefCounted = cl[0][0]
	var b: RefCounted = cl[1][0]
	var c3: RefCounted = cl[2][0]
	var d4: RefCounted = cl[3][0]
	# chat limiter: a raw flood of 12 distinct lines reaches the room at most ~burst + a little
	var seen: Array = []
	b.connect("event", func(e: Dictionary) -> void:
		if e["type"] == "chat":
			seen.append(e))
	for i in 12:
		a._send_control(1, Proto.K_CHAT, {"text": "line %d" % i})
	await _pump(all, 0.6)
	_ok(seen.size() >= 3 and seen.size() <= 6, "server chat limiter: 12-line flood delivers %d (<= burst 4 + refill)" % seen.size())
	# the client-side limiter refuses too
	var sent: int = 0
	for i in 10:
		if b.send_chat("hello %d" % i):
			sent += 1
	_ok(sent >= 3 and sent <= 5, "client chat limiter: %d of 10 sent" % sent)
	# control chars and a command are not relayed as chat
	var cmd_seen: int = 0
	b.connect("event", func(e: Dictionary) -> void:
		if e["type"] == "chat" and str(e["text"]).begins_with("/"):
			cmd_seen += 1)
	await _pump(all, 2.0)
	c3._send_control(1, Proto.K_CHAT, {"text": "/votekick Ann"})
	await _pump(all, 0.4)
	_ok(cmd_seen == 0 and sevs.any(func(e: Dictionary) -> bool: return e["type"] == "command"), "chat commands are logged, never broadcast")
	# malformed packets are dropped without a crash and counted
	for i in 30:
		a._send_raw(1, PackedByteArray([Proto.K_HELLO, 0x7B, 0xFF]), true)
		a._send_raw(1, PackedByteArray([0xEE, 1, 2, 3]), true)
		a._send_raw(1, PackedByteArray([Proto.K_CHAT]) + PackedByteArray("x".repeat(2000).to_utf8_buffer()), true)
	await _pump(all, 0.5)
	_ok(srv.ready_count() >= 3, "malformed / oversize packets do not crash the server")
	# reports: three distinct reporters kick Ann (cl[0]) and temp-ban (loopback is exempt from the ban itself)
	var aid: int = a.local_id
	var kicked: Array = []
	a.connect("event", func(e: Dictionary) -> void:
		if e["type"] == "kicked":
			kicked.append(e))
	b.send_report(aid, "abuse", "rude")
	await _pump(all, 0.1)
	_ok(srv.peers.has(aid), "one report does not kick")
	c3.send_report(aid, "spam", "")
	d4.send_report(aid, "cheat", "x".repeat(500))
	var gone: bool = await _wait_for(func() -> bool: return not srv.peers.has(aid), all, 3.0)
	_ok(gone and sevs.any(func(e: Dictionary) -> bool: return e["type"] == "report"), "3 distinct reporters kick the target")
	await _pump(all, 0.5)
	_ok(kicked.size() == 1, "the target is told it was removed")
	# a client ignores forged oversize / unknown packets from the server side too (decoders already fuzzed above)
	srv.close("", false)


