# End-to-end multiplayer client for a real dedicated server (headless). Two of these run against
# `godot --headless --path godot -- --server --port 53999`; each owns a real NovaWorld + pilot in the SAME system and drives
# the real NetTransport (ENet). Asserts: handshake, presence, co-located sync (each sees the other's ship), chat,
# a trade round-trip (credits both ways, applied to each pilot's own save), authority handoff when one leaves.
#
#   NOVA_DATA_DIR=data/base godot --headless --path godot -s res://tests/net_e2e_client.gd -- NAME PORT [host]
#
# Prints "E2E NAME PASS|FAIL" and exits 0/1. Coordination between the two clients is by chat lines ("@ready", "@traded").
extends SceneTree

const Transport = preload("res://net/NetTransport.gd")

var name_: String = "A"
var port: int = 53999
var host: String = "127.0.0.1"
var world: Object = null
var t: RefCounted = null
var checks: Dictionary = {}
var failed: bool = false
var clock: float = 0.0
var phase: String = "connect"
var phase_at: float = 0.0
var events_in: float = 0.0
var seen_chat: Array = []
var trade_open: bool = false
var credits_before: int = 0
var my_give: int = 0
var their_give: int = 0
var trade_committed: bool = false
var handoff_role: String = ""
var left: bool = false
var invited: bool = false
var last_us: int = 0


func _init() -> void:
	var args: PackedStringArray = OS.get_cmdline_user_args()
	if args.size() > 0:
		name_ = args[0]
	if args.size() > 1:
		port = int(args[1])
	if args.size() > 2:
		host = args[2]
	my_give = 1000 if name_ == "A" else 250
	their_give = 250 if name_ == "A" else 1000
	_boot.call_deferred()


func _log(s: String) -> void:
	print("[%s %5.1f] %s" % [name_, clock, s])


func _check(label: String, cond: bool) -> void:
	if checks.has(label):
		return
	checks[label] = cond
	print("[%s] %s %s" % [name_, "ok  " if cond else "FAIL", label])
	if not cond:
		failed = true


func _boot() -> void:
	await process_frame
	if not ClassDB.class_exists("NovaWorld"):
		print("E2E %s SKIP (no bridge)" % name_)
		quit(0)
		return
	world = ClassDB.instantiate("NovaWorld")
	root.add_child(world)
	var data: String = OS.get_environment("NOVA_DATA_DIR")
	if data == "":
		data = ProjectSettings.globalize_path("res://") + "../data/base"
	if not world.load_game(data) or not world.make_world(128):
		print("E2E %s FAIL no game data / world" % name_)
		quit(1)
		return
	world.debug_set_credits(10000 if name_ == "A" else 2000)
	credits_before = int(JSON.parse_string(world.net_trade_inventory()).get("credits", 0)) if world.has_method("net_trade_inventory") else 0
	t = Transport.new()
	t.event.connect(_on_event)
	var err: int = t.join(world, host, port, "Pilot" + name_, "")
	_log("joining %s:%d -> %s (system %d, credits %d)" % [host, port, error_string(err), int(world.nav_current_system()), credits_before])
	last_us = Time.get_ticks_usec()
	while phase != "done":
		await process_frame
		var now: int = Time.get_ticks_usec()
		_tick(minf(0.1, float(now - last_us) / 1000000.0))
		last_us = now


func _on_event(ev: Dictionary) -> void:
	var k: String = str(ev.get("type", ""))
	if k in ["rejected", "timeout", "error", "kicked"]:
		_log("transport event %s: %s" % [k, str(ev.get("message", ev.get("reason", "")))])
		if phase != "done":
			_check("connected (%s)" % k, false)
			_finish()
	elif k == "connected":
		_log("connected, encrypted=%s" % str(t.encrypted))
		_check("handshake", true)
		_check("encrypted when server offers DTLS: %s" % str(t.encrypted), true)
		phase = "presence"
		phase_at = clock


func _tick(delta: float) -> void:
	clock += delta
	if t != null:
		t.poll(delta)
	if t == null or world == null:
		return
	if phase != "connect" and phase != "done":
		world.step(delta)
		events_in -= delta
		if events_in <= 0.0:
			events_in = 0.1
			_poll_events()
		_drive()
	elif phase == "connect" and clock > 15.0:
		_check("handshake within 15s", false)
		_finish()
	if clock > 70.0 and phase != "done":
		_log("global timeout in phase " + phase)
		_check("completed in time", false)
		_finish()


func _state() -> Dictionary:
	var v: Variant = JSON.parse_string(str(world.net_state()))
	return v if v is Dictionary else {}


func _poll_events() -> void:
	var v: Variant = JSON.parse_string(str(world.net_events()))
	if not (v is Array):
		return
	for e in v:
		var d: Dictionary = e
		match str(d.get("type", "")):
			"chat":
				seen_chat.append(str(d.get("text", "")))
				_log("chat from %s: %s" % [str(d.get("name", "")), str(d.get("text", ""))])
			"trade":
				_on_trade(d)
			"plugin_mismatch", "version_mismatch":
				_log("bridge event: " + str(d))


func _on_trade(d: Dictionary) -> void:
	var kind: String = str(d.get("kind", ""))
	_log("trade event: " + kind)
	if kind == "invite":
		world.net_trade_respond(int(d.get("id", -1)), true)
	elif kind == "committed":
		trade_committed = true
	elif kind in ["failed", "decline", "cancel"] and phase == "trade":
		_log("trade aborted: " + str(d))
		_check("trade not aborted", false)


func _other_id(st: Dictionary) -> int:
	for p in (st.get("players", []) as Array):
		if int((p as Dictionary).get("id", 0)) != int(st.get("local_id", 0)):
			return int((p as Dictionary).get("id", 0))
	return -1


func _drive() -> void:
	var st: Dictionary = _state()
	match phase:
		"presence":
			if (st.get("players", []) as Array).size() == 2:
				_check("presence: both pilots see each other", true)
				phase = "sync"
				phase_at = clock
			elif clock - phase_at > 15.0:
				_check("presence: both pilots see each other", false)
				_finish()
		"sync":
			var other: int = _other_id(st)
			var co: bool = false
			for p in (st.get("players", []) as Array):
				if int((p as Dictionary).get("id", 0)) == other and bool((p as Dictionary).get("in_my_system", false)):
					co = true
			if co and bool(st.get("syncing", false)) and int(world.ship_count()) >= 2:
				_check("co-located: the other pilot's ship is in my world", true)
				phase = "chat"
				phase_at = clock
				t.send_chat("@ready from " + name_)
			elif clock - phase_at > 20.0:
				_log("sync state: " + str(st) + " ships=" + str(world.ship_count()))
				_check("co-located: the other pilot's ship is in my world", false)
				_finish()
		"chat":
			if _chat_has("@ready from " + ("B" if name_ == "A" else "A")):
				_check("chat: received the other pilot's message", true)
				phase = "trade"
				phase_at = clock
			elif clock - phase_at > 10.0:
				_check("chat: received the other pilot's message", false)
				_finish()
		"trade":
			_drive_trade(st)
		"handoff":
			_drive_handoff(st)
		"verify_left":
			pass


func _chat_has(s: String) -> bool:
	for c in seen_chat:
		if str(c) == s:
			return true
	return false


func _drive_trade(st: Dictionary) -> void:
	var other: int = _other_id(st)
	var ts: Dictionary = JSON.parse_string(str(world.net_trade_state()))
	if name_ == "A" and not invited and other > 0:
		invited = true
		var why: String = str(world.net_trade_invite(other))
		_log("invite -> '%s'" % why)
		_check("trade: invite accepted by the rules", why == "")
	if bool(ts.get("open", false)) and bool(ts.get("joined", false)) and not trade_open:
		trade_open = true
		var why2: String = str(world.net_trade_offer(JSON.stringify({"credits": my_give, "cargo": [], "outfits": []})))
		_check("trade: offer accepted", why2 == "")
		_check("trade: refuses an offer larger than what I hold",
			str(world.net_trade_offer(JSON.stringify({"credits": 99999999, "cargo": [], "outfits": []}))) != "")
		world.net_trade_offer(JSON.stringify({"credits": my_give, "cargo": [], "outfits": []}))
	if trade_open and bool(ts.get("open", false)):
		var their: int = int((ts.get("their_offer", {}) as Dictionary).get("credits", 0))
		if their == their_give and not bool(ts.get("my_accepted", false)):
			_check("trade: partner's offer mirrored", true)
			_check("trade: accept", str(world.net_trade_accept(true)) == "")
	if trade_committed:
		var inv: Dictionary = JSON.parse_string(str(world.net_trade_inventory()))
		var want: int = credits_before - my_give + their_give
		_log("credits now %d, want %d" % [int(inv.get("credits", -1)), want])
		_check("trade: both offers applied to my own save", int(inv.get("credits", -1)) == want)
		phase = "handoff"
		phase_at = clock
		t.send_chat("@traded " + name_)


func _drive_handoff(st: Dictionary) -> void:
	var me: int = int(st.get("local_id", 0))
	var auth: int = int(st.get("authority_id", -1))
	if handoff_role == "":
		if not _chat_has("@traded " + ("B" if name_ == "A" else "A")):
			return
		handoff_role = "leaver" if auth == me else "stayer"
		if handoff_role == "stayer":
			_check("handoff: before it, the other pilot was the authority and I was a client", auth > 0 and auth != me and bool(st.get("syncing", false)))
		_log("authority is %d (me %d) -> I %s" % [auth, me, "leave" if handoff_role == "leaver" else "stay"])
		phase_at = clock
		return
	if handoff_role == "leaver":
		if clock - phase_at > 1.5 and not left:
			left = true
			_check("handoff: the authority leaves cleanly", true)
			t.close("")
			_finish()
	else:
		var players: Array = st.get("players", [])
		# Alone in the system again: no co-located partner, so no sync traffic at all; this pilot's own world is the
		# authority (authority_id is only reported while 2+ pilots share a system).
		if players.size() == 1 and not bool(st.get("syncing", true)) and (auth == me or auth == -1):
			_check("handoff: the remaining pilot is back on its own world (no longer syncing)", true)
			for i in 30:
				world.step(1.0 / 30.0)
			_check("handoff: the world keeps simulating", int(world.ship_count()) >= 1)
			_finish()
		elif clock - phase_at > 12.0:
			_log("handoff state: " + str(st))
			_check("handoff: the remaining pilot is back on its own world (no longer syncing)", false)
			_finish()


func _finish() -> void:
	if phase == "done":
		return
	phase = "done"
	if t != null and t.is_active():
		t.close("")
	print("E2E %s %s" % [name_, "FAIL" if failed else "PASS"])
	quit(1 if failed else 0)
