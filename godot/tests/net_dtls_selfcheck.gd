# DTLS selfcheck: an encrypted ENet host and Godot clients in one process.
#   NOVA_DATA_DIR=data/base godot --headless --path godot -s res://tests/net_dtls_selfcheck.gd
# Covers: auto-detect via the status reply, trust-on-first-use pin, the key-changed refusal (and accepting it),
# and a plain client meeting a DTLS-only server (clean timeout with a hint, no crash).
extends SceneTree

const Transport = preload("res://net/NetTransport.gd")
const Lan = preload("res://net/LanDiscovery.gd")
const NetCrypto = preload("res://net/NetCrypto.gd")
const NetPrefs = preload("res://net/NetPrefs.gd")

const PORT := 53971
var ok_all: bool = true
var srv: RefCounted = null
var lan: RefCounted = null
var creds: Dictionary = {}
var events: Array = []


func _init() -> void:
	_run.call_deferred()


func _check(label: String, cond: bool) -> void:
	print(("  ok   " if cond else "  FAIL ") + label)
	if not cond:
		ok_all = false


func _pump(seconds: float, clients: Array, until: Callable = Callable()) -> void:
	var n: int = int(seconds / 0.02)
	for i in n:
		if srv != null:
			srv.poll(0.02)
		if lan != null:
			lan.poll(0.02)
		for c in clients:
			if c != null:
				(c as RefCounted).poll(0.02)
		if until.is_valid() and until.call():
			return
		await create_timer(0.02).timeout


func _start_server(c: Dictionary) -> void:
	if srv != null:
		srv.close("", false)
	srv = Transport.new()
	creds = c
	var err: int = srv.host(null, {"port": PORT, "max_players": 4, "name": "dtls-test", "display_name": "[Server]", "has_local_player": false,
		"dtls": true, "dtls_creds": c})
	_check("server starts encrypted", err == OK and srv.encrypted)
	if lan == null:
		lan = Lan.new()
	lan.start_announcing(func() -> Dictionary:
		return {"name": "dtls-test", "players": 0, "max": 4, "port": PORT, "dtls": true, "fp": creds["fp"], "cert": creds["pem"], "dedicated": true}, PORT)


func _client(opts: Dictionary) -> RefCounted:
	var cl: RefCounted = Transport.new()
	events.clear()
	cl.event.connect(func(ev: Dictionary) -> void: events.append(ev))
	cl.join(null, "127.0.0.1", PORT, "Tester", "", opts)
	return cl


func _has(kind: String) -> bool:
	for e in events:
		if str((e as Dictionary).get("type", "")) == kind:
			return true
	return false


func _run() -> void:
	await process_frame
	NetPrefs.forget_key("127.0.0.1", PORT)
	var c1: Dictionary = NetCrypto.server_credentials("user://dtls_test_a.key", "user://dtls_test_a.crt")
	_check("certificate generated", not c1.is_empty() and str(c1["fp"]).length() == 64)
	_start_server(c1)

	var cl: RefCounted = _client({})
	await _pump(6.0, [cl], func() -> bool: return _has("connected"))
	_check("client connects, auto-detecting DTLS from the status reply", _has("connected") and cl.encrypted)
	_check("the key was pinned on first use", str(NetPrefs.trusted_key("127.0.0.1", PORT).get("fp", "")) == str(c1["fp"]))
	cl.close("")

	# Same key again: no prompt, connects.
	cl = _client({})
	await _pump(6.0, [cl], func() -> bool: return _has("connected"))
	_check("second join with the pinned key connects", _has("connected"))
	cl.close("")
	await _pump(0.5, [])

	# The server's key changes (reinstall / interception).
	var c2: Dictionary = NetCrypto.server_credentials("user://dtls_test_b.key", "user://dtls_test_b.crt")
	_start_server(c2)
	await _pump(0.5, [])
	cl = _client({})
	await _pump(6.0, [cl], func() -> bool: return _has("rejected"))
	var rej: Dictionary = {}
	for e in events:
		if str((e as Dictionary).get("type", "")) == "rejected":
			rej = e
	_check("a changed key is refused with a warning", str(rej.get("code", "")) == "key_changed" and not _has("connected"))
	_check("the pin still holds the OLD key", str(NetPrefs.trusted_key("127.0.0.1", PORT).get("fp", "")) == str(c1["fp"]))
	cl = _client({"accept_new_key": true})
	await _pump(6.0, [cl], func() -> bool: return _has("connected"))
	_check("accepting the change connects and re-pins", _has("connected") and str(NetPrefs.trusted_key("127.0.0.1", PORT).get("fp", "")) == str(c2["fp"]))
	cl.close("")
	await _pump(0.5, [])

	# A plain client (skips the status probe, like the Swift ENet client) against the DTLS-only server.
	NetPrefs.forget_key("127.0.0.1", PORT)
	cl = _client({"skip_probe": true})
	await _pump(13.0, [cl], func() -> bool: return _has("timeout") or _has("connected"))
	print("  events: ", events)
	var to: String = ""
	for e in events:
		if str((e as Dictionary).get("type", "")) == "timeout":
			to = str((e as Dictionary).get("message", ""))
	_check("a plain client is refused cleanly (timeout, never connects)", to != "" and not _has("connected"))
	_check("... and the message hints at encryption", to.contains("encrypted"))

	NetPrefs.forget_key("127.0.0.1", PORT)
	srv.close("", false)
	print("NET DTLS SELFCHECK ", "PASS" if ok_all else "FAIL")
	quit(0 if ok_all else 1)
