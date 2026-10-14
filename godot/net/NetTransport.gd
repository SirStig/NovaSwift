# NOVA Swift -- ENet transport for multiplayer (LAN, direct IP:port, dedicated servers).
#
# A star topology: one server (a player's game "Host Game", or a headless dedicated server) and N clients.
# Clients only ever talk to the server; the server relays client-to-client game bytes, so the engine's
# per-system authority (which can be any co-located player) works unchanged. ENet peer ids ARE the bridge
# peer ids (the server is always 1), which keeps net_receive(src) / net_outgoing(to) one-to-one with the wire.
#
# Every frame (poll):
#   * the ENet peer is serviced; control packets drive the handshake, game packets are handed to
#     bridge.net_receive(src, bytes);
#   * bridge.net_outgoing() is drained and sent (channel 0 reliable / channel 1 unreliable).
# All bridge calls are guarded with has_method(): on a bridge built before the net_* API, the transport
# still connects, chats and relays (K_CHAT), it just carries no simulation.
#
# Handshake: client connects -> HELLO {proto, version, name, pw, manifest} -> server checks protocol, game
# version, password, capacity and the plug-in manifest (bridge.net_ready_manifest) -> WELCOME {your_id,
# peers...} or REJECT {code, message}. Timeouts: 10 s to connect, 8 s to finish the handshake, 20 s of
# silence once connected (the client pings every 2 s).
#
# Events (signal `event(ev)`): {type: "hosting"|"connecting"|"connected"|"rejected"|"timeout"|"disconnected"|
# "kicked"|"peer_joined"|"peer_left"|"chat"|"error", ...}. The UI (NetService) listens to these.
#
# Loaded with preload() (no class_name), like Controls.gd.
extends RefCounted

const Proto = preload("res://net/NetProto.gd")
const NetCrypto = preload("res://net/NetCrypto.gd")
const NetPrefs = preload("res://net/NetPrefs.gd")
const NetPlugins = preload("res://net/NetPlugins.gd")

signal event(ev: Dictionary)

const CONNECT_TIMEOUT := 10.0
const HANDSHAKE_TIMEOUT := 8.0
const IDLE_TIMEOUT := 20.0
const PING_EVERY := 2.0
const SERVER_ID := 1
## How long a joining client waits for the server's plain UDP status reply (is it encrypted? which key?) before
## connecting in plain mode.
const PROBE_TIMEOUT := 1.2
## Server-side abuse limits (docs/MULTIPLAYER.md "Hardening"): per-peer token buckets, per-IP caps, temp bans.
const PKT_RATE := 300.0          # packets / s sustained
const PKT_BURST := 600.0
const BYTE_RATE := 524288.0      # bytes / s sustained
const BYTE_BURST := 1048576.0
const MAX_VIOLATIONS := 50       # rate-limit / malformed-packet strikes before a kick
const VIOLATION_WINDOW := 60.0
const MAX_PER_IP := 4            # simultaneous connections per address (loopback exempt)
const TEMPBAN_SECS := 600.0
const ABUSE_KICKS_FOR_BAN := 3
const CHAT_BURST := 4.0
const CHAT_REFILL := 2.0         # tokens / s  (= 1 message per 0.5 s sustained)
const CHAT_VIOLATIONS := 10      # dropped chat lines within 30 s -> kick
const CHAT_VIOLATION_WINDOW := 30.0
const REPORT_WINDOW := 60.0
const REPORT_DISTINCT_KICK := 3
const REPORT_INVALID_KICK := 5

var peer: ENetMultiplayerPeer = null
## "none" | "server" | "client"
var mode: String = "none"
## "idle" | "connecting" | "handshaking" | "connected" | "closed"
var state: String = "idle"
## The NovaWorld (or a stand-in with the same net_* methods); may be null.
var bridge: Object = null
## True once bridge.net_begin returned true (the simulation is networked).
var bridge_active: bool = false
var local_id: int = 0
var display_name: String = "Pilot"
var server_name: String = ""
var password: String = ""
var max_players: int = 8
var port: int = Proto.DEFAULT_PORT
var rules_json: String = ""
var address: String = ""
## Client: smoothed round trip to the server, ms (-1 = unknown).
var rtt_ms: int = -1
## id -> {name, ready, t0, last_rx, rtt, ip}. Server: every connection. Client: the other players (ready).
var peers: Dictionary = {}
## True when this process has a local player in the session (a Host Game); false for a dedicated server.
var has_local_player: bool = true
var banned: Dictionary = {}
## ip -> clock time the temporary ban ends (abuse kicks, report kicks).
var temp_bans: Dictionary = {}
## ip -> number of abuse kicks.
var abuse_kicks: Dictionary = {}
## target id -> {by: {reporter id -> time}, invalid: {reporter id -> true}}
var _reports: Dictionary = {}
## Client side: the chat token bucket and the host's display label.
var _chat_tokens: float = CHAT_BURST
var _chat_at: float = 0.0
var _host_label: String = ""
## True when the ENet link is DTLS-encrypted (host: started with encryption; client: connected with a pinned key).
var encrypted: bool = false
## Host side: {key, cert, pem, fp} while hosting encrypted (the beacon / status reply advertises pem + fp).
var dtls_creds: Dictionary = {}
var _probe: PacketPeerUDP = null
var _probe_t0: float = 0.0
var _probe_legacy_sent: bool = false
var _probe_stage: int = 0
var _probe_info: Dictionary = {}
var _join_opts: Dictionary = {}
## id -> clock time to really disconnect: lets a REJECT / KICK packet flush before the link goes down.
var _closing: Dictionary = {}

var _clock: float = 0.0
var _t_state: float = 0.0
var _last_rx: float = 0.0
var _next_ping: float = 0.0
var _closed_reason: String = ""


# --- lifecycle ---------------------------------------------------------------------------------------

## Start listening. opts: {port, max_players, name (server), display_name (host player), password, rules_json,
## has_local_player}. Returns OK or an Error code.
func host(nova: Object, opts: Dictionary) -> int:
	close("restart", false)
	bridge = nova
	port = int(opts.get("port", Proto.DEFAULT_PORT))
	max_players = clampi(int(opts.get("max_players", 8)), 1, 32)
	display_name = Proto.clean_name(str(opts.get("display_name", "Pilot")))
	server_name = Proto.clean_name(str(opts.get("name", display_name + "'s game")), "NovaSwift", Proto.MAX_SERVER_NAME)
	password = str(opts.get("password", ""))
	rules_json = str(opts.get("rules_json", JSON.stringify(Proto.rules_for_preset("safe"))))
	has_local_player = bool(opts.get("has_local_player", true))
	var p: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	# +2 slack so a refused (full / wrong version) joiner can still be told why before it is dropped.
	var err: int = p.create_server(port, max_players + 2)
	if err != OK:
		_emit({"type": "error", "message": _bind_error(err)})
		return err
	encrypted = false
	dtls_creds = {}
	if bool(opts.get("dtls", false)):
		dtls_creds = opts.get("dtls_creds", {}) as Dictionary if opts.get("dtls_creds", null) is Dictionary else NetCrypto.server_credentials()
		var topt: TLSOptions = NetCrypto.server_options(dtls_creds)
		var derr: int = ERR_UNAVAILABLE if topt == null else p.host.dtls_server_setup(topt)
		if derr != OK:
			p.close()
			dtls_creds = {}
			_emit({"type": "error", "message": "Couldn't enable encryption (%s). This build may lack TLS support; host without \"Encrypt connection\"." % error_string(derr)})
			return derr
		encrypted = true
	_attach(p)
	mode = "server"
	state = "connected"
	local_id = SERVER_ID
	peers.clear()
	bridge_active = _bridge_begin(SERVER_ID, display_name, true, rules_json)
	_emit({"type": "hosting", "port": port, "bridge": bridge_active})
	return OK


## Connect to host:port. Returns OK or an Error code (the connection itself completes asynchronously).
## First a short plain UDP status query (game port + 1) learns whether the server is encrypted and which key it
## uses; no answer = plain. opts: {accept_new_key: bool} to re-pin a server whose key changed.
func join(nova: Object, host_name: String, host_port: int, name: String, pw: String = "", opts: Dictionary = {}) -> int:
	close("restart", false)
	bridge = nova
	display_name = Proto.clean_name(name)
	password = pw
	port = host_port
	address = Proto.format_address(host_name, host_port)
	_join_opts = opts.duplicate()
	_join_opts["host"] = host_name
	encrypted = false
	mode = "client"
	state = "connecting"
	_t_state = _clock
	_emit({"type": "connecting", "address": address})
	var ip: String = host_name if host_name.is_valid_ip_address() else IP.resolve_hostname(host_name)
	if ip == "" or bool(opts.get("skip_probe", false)):
		return _start_client(host_name, host_port, {})
	_probe = PacketPeerUDP.new()
	var qport: int = Proto.LAN_PORT if host_port == Proto.DEFAULT_PORT else host_port + 1
	if _probe.set_dest_address(ip, qport) != OK:
		_probe = null
		return _start_client(host_name, host_port, {})
	_probe.put_packet(Proto.build_query())
	_probe_legacy_sent = false
	_probe_stage = 0
	_probe_info = {}
	_probe_t0 = _clock
	return OK


func _poll_probe() -> void:
	var info: Dictionary = {}
	while _probe.get_available_packet_count() > 0:
		var got: Dictionary = Proto.decode_beacon(_probe.get_packet())
		if got.is_empty():
			continue
		if _probe_stage == 1:
			# the certificate reply: only the key material is taken from it
			if str(got.get("cert", "")) != "" and bool(got.get("dtls", false)):
				_probe_info["cert"] = got["cert"]
				_probe_info["fp"] = got.get("fp", _probe_info.get("fp", ""))
				info = _probe_info
				break
		else:
			info = got
			break
	if _probe_stage == 0 and not info.is_empty() and bool(info.get("dtls", false)) and str(info.get("cert", "")) == "":
		# An encrypted server's certificate doesn't fit the status reply: ask for it separately.
		_probe_info = info
		_probe_stage = 1
		_probe_t0 = _clock
		_probe.put_packet(Proto.build_cert_query())
		return
	if info.is_empty() and _probe_stage == 0 and not _probe_legacy_sent and _clock - _probe_t0 > PROBE_TIMEOUT / 2.0:
		_probe_legacy_sent = true   # an older server only answers the bare 4-byte query
		_probe.put_packet(Proto.QUERY_MAGIC.to_utf8_buffer())
	if info.is_empty() and _clock - _probe_t0 < PROBE_TIMEOUT:
		return
	if info.is_empty() and _probe_stage == 1:
		info = _probe_info   # no certificate came back: _start_client reports it
	_probe.close()
	_probe = null
	var err: int = _start_client(str(_join_opts["host"]), port, info)
	if err != OK and mode == "client":
		_fail_client("error", "Couldn't start connecting to %s (%s)." % [address, error_string(err)])


## Decide plain / DTLS from the status reply `info` (may be empty), then open the ENet client.
func _start_client(host_name: String, host_port: int, info: Dictionary) -> int:
	var tls: TLSOptions = null
	var pinned: Dictionary = NetPrefs.trusted_key(host_name, host_port)
	var server_dtls: bool = bool(info.get("dtls", false)) or (info.is_empty() and not pinned.is_empty())
	if server_dtls:
		var pem: String = str(info.get("cert", ""))
		if pem == "" and not pinned.is_empty():
			pem = str(pinned.get("pem", ""))
		var fp: String = NetCrypto.fingerprint(pem)
		if pem == "" or fp == "":
			_fail_client("error", "%s uses an encrypted connection but did not share its key. Try again, or make sure its status port (UDP %d) is reachable." % [address, host_port + 1])
			return OK
		if not pinned.is_empty() and str(pinned.get("fp", "")) != fp and not bool(_join_opts.get("accept_new_key", false)):
			_fail_client("key_changed", "The encryption key of %s has CHANGED since you first joined (was %s, now %s). This can mean the server was reinstalled - or that someone is intercepting the connection. Only continue if you expected it." % [
				address, NetCrypto.short_fp(str(pinned.get("fp", ""))), NetCrypto.short_fp(fp)],
				{"host": host_name, "port": host_port, "old_fp": str(pinned.get("fp", "")), "new_fp": fp, "pem": pem})
			return OK
		tls = NetCrypto.client_options(pem)
		if tls == null:
			_fail_client("error", "%s sent an unreadable encryption key." % address)
			return OK
		if pinned.is_empty() or str(pinned.get("fp", "")) != fp:
			NetPrefs.trust_key(host_name, host_port, pem, fp)   # trust on first use (or after the player accepted a change)
			_emit({"type": "key_pinned", "address": address, "fp": fp, "first": pinned.is_empty()})
	var p: ENetMultiplayerPeer = ENetMultiplayerPeer.new()
	var err: int = p.create_client(host_name, host_port)
	if err != OK:
		return err
	if tls != null:
		var derr: int = p.host.dtls_client_setup(NetCrypto.COMMON_NAME, tls)
		if derr != OK:
			p.close()
			_fail_client("error", "Couldn't start the encrypted connection (%s)." % error_string(derr))
			return OK
		encrypted = true
	_attach(p)
	mode = "client"
	state = "connecting"
	_t_state = _clock
	return OK


func is_active() -> bool:
	return (peer != null or _probe != null) and mode != "none"


func is_connected_to_session() -> bool:
	return is_active() and state == "connected"


## Leave / stop hosting. `announce` = emit the "disconnected" event.
func close(reason: String = "", announce: bool = true) -> void:
	if _probe != null:
		_probe.close()
		_probe = null
	if peer == null:
		mode = "none"
		state = "idle"
		return
	if mode == "server":
		for id in peers.keys():
			if bool((peers[id] as Dictionary).get("ready", false)):
				_send_control(int(id), Proto.K_KICK, {"reason": "The host closed the game."})
		peer.poll()
	_end_bridge()
	peer.close()
	peer = null
	encrypted = false
	dtls_creds = {}
	var was: String = mode
	mode = "none"
	state = "closed"
	peers.clear()
	local_id = 0
	rtt_ms = -1
	if announce:
		_emit({"type": "disconnected", "reason": reason if reason != "" else ("Hosting stopped." if was == "server" else "Left the game.")})


## net_end(), then drain once more: the final packet (a kick, a goodbye) stays drainable after it.
func _end_bridge() -> void:
	if bridge_active and bridge != null and bridge.has_method("net_end"):
		bridge.net_end()
		_pump_outgoing(true)
	bridge_active = false


func _attach(p: ENetMultiplayerPeer) -> void:
	peer = p
	peer.peer_connected.connect(_on_peer_connected)
	peer.peer_disconnected.connect(_on_peer_disconnected)
	_last_rx = _clock
	_next_ping = _clock + PING_EVERY
	peers.clear()
	_closed_reason = ""


# --- per-frame ---------------------------------------------------------------------------------------

func poll(delta: float) -> void:
	if peer == null and _probe != null:
		_clock += delta
		_poll_probe()
		return
	if peer == null:
		return
	_clock += delta
	peer.poll()
	if peer == null:
		return
	if mode == "client":
		_poll_client_connection()
		if peer == null:
			return
	while peer != null and peer.get_available_packet_count() > 0:
		var from: int = peer.get_packet_peer()
		var ch: int = peer.get_packet_channel()
		var pkt: PackedByteArray = peer.get_packet()
		if peer.get_packet_error() != OK:
			continue
		_handle_packet(from, ch, pkt)
	if peer == null:
		return
	if mode == "client":
		_check_client_disconnect()   # after the packets: a REJECT / KICK arrives together with the disconnect
		if peer == null:
			return
	_pump_outgoing()
	if mode == "server":
		_server_timers()
	elif mode == "client":
		_client_timers()


func _poll_client_connection() -> void:
	var st: int = peer.get_connection_status()
	if st == MultiplayerPeer.CONNECTION_CONNECTED and state == "connecting":
		state = "handshaking"
		_t_state = _clock
		local_id = peer.get_unique_id()
		var manifest: String = ""
		if bridge != null and bridge.has_method("net_ready_manifest"):
			manifest = str(bridge.net_ready_manifest())
		_send_control(SERVER_ID, Proto.K_HELLO, {"proto": Proto.PROTO, "version": Proto.game_version(),
			"name": display_name, "pw": Proto.hash_password(password), "manifest": manifest})
	if state == "connecting" and _clock - _t_state > CONNECT_TIMEOUT:
		_fail_client("timeout", "Timed out connecting to %s. Check the address, that the server is running, and that port %d/udp is open.%s" % [address, port, _tls_hint()])
	elif state == "handshaking" and _clock - _t_state > HANDSHAKE_TIMEOUT:
		_fail_client("timeout", "%s didn't answer the handshake. It may be a different game or a stalled server." % address)


func _check_client_disconnect() -> void:
	if peer.get_connection_status() != MultiplayerPeer.CONNECTION_DISCONNECTED:
		return
	if state == "connecting":
		_fail_client("timeout", "Couldn't reach %s. Check the address, that the server is running, and that port %d/udp is open.%s" % [address, port, _tls_hint()])
	else:
		_fail_client("disconnected", _closed_reason if _closed_reason != "" else "Lost the connection to the server.")


func _tls_hint() -> String:
	if encrypted:
		return " This connection is encrypted: the server must also be running with encryption and the same key."
	return " (If the server uses an encrypted connection, its status port - UDP %d - must be reachable so this game can detect that.)" % (port + 1)


func _client_timers() -> void:
	if state != "connected":
		return
	if _clock >= _next_ping:
		_next_ping = _clock + PING_EVERY
		_send_control(SERVER_ID, Proto.K_PING, {"t": _clock, "rtt": rtt_ms}, false)
	if _clock - _last_rx > IDLE_TIMEOUT:
		_fail_client("timeout", "The server stopped responding.")


func _server_timers() -> void:
	for cid in _closing.keys():
		if _clock >= float(_closing[cid]):
			_closing.erase(cid)
			if peer != null and peer.get_peer(int(cid)) != null:
				peer.disconnect_peer(int(cid), true)
	for id in peers.keys():
		var info: Dictionary = peers[id]
		if bool(info.get("ready", false)):
			if _clock - float(info.get("last_rx", _clock)) > IDLE_TIMEOUT:
				_drop(int(id), "timeout")
		elif _clock - float(info.get("t0", _clock)) > HANDSHAKE_TIMEOUT:
			_drop(int(id), "handshake timeout")


## Client-side failure: report once, tear down.
func _fail_client(kind: String, message: String, detail: Dictionary = {}) -> void:
	var was_connected: bool = state == "connected"
	_end_bridge()
	if peer != null:
		peer.close()
	peer = null
	if _probe != null:
		_probe.close()
		_probe = null
	mode = "none"
	state = "closed"
	peers.clear()
	if kind == "timeout" and not was_connected:
		_emit({"type": "timeout", "message": message})
	elif kind == "key_changed" or kind == "error":
		_emit({"type": "rejected" if kind == "key_changed" else "error", "code": kind, "message": message, "detail": detail, "address": address})
	else:
		_emit({"type": "disconnected", "reason": message})


# --- packets -----------------------------------------------------------------------------------------

func _handle_packet(from: int, ch: int, pkt: PackedByteArray) -> void:
	if pkt.size() < 1:
		return
	var kind: int = pkt[0]
	if mode == "server":
		if _closing.has(from):
			return
		if not peers.has(from):
			peers[from] = _new_peer(from)
		var info: Dictionary = peers[from]
		info["last_rx"] = _clock
		if not _rate_ok(from, info, pkt.size()):
			return
		var lim: int = Proto.packet_limit(kind, false)
		if lim == 0:
			return   # unknown kind: ignored
		if pkt.size() > lim:
			_violation(from, "oversize packet (kind %d, %d bytes)" % [kind, pkt.size()])
			return
		match kind:
			Proto.K_HELLO: _server_hello(from, Proto.unpack_control(pkt))
			Proto.K_DATA: _server_data(from, ch, pkt)
			Proto.K_PING: _server_ping(from, Proto.unpack_control(pkt))
			Proto.K_CHAT: _server_chat(from, Proto.unpack_control(pkt))
			Proto.K_REPORT: _server_report(from, Proto.unpack_control(pkt))
	else:
		var lim_c: int = Proto.packet_limit(kind, true)
		if lim_c == 0 or pkt.size() > lim_c:
			return   # unknown kind / oversize: dropped unread
		_last_rx = _clock
		match kind:
			Proto.K_WELCOME: _client_welcome(Proto.unpack_control(pkt))
			Proto.K_REJECT: _client_reject(Proto.unpack_control(pkt))
			Proto.K_PEER_JOIN: _client_peer_join(Proto.unpack_control(pkt))
			Proto.K_PEER_LEFT: _client_peer_left(Proto.unpack_control(pkt))
			Proto.K_KICK: _client_kick(Proto.unpack_control(pkt))
			Proto.K_PONG: _client_pong(Proto.unpack_control(pkt))
			Proto.K_CHAT: _client_chat(Proto.unpack_control(pkt))
			Proto.K_DATA:
				var d: Dictionary = Proto.unpack_data(pkt)
				if not d.is_empty() and state == "connected" and bridge_active:
					bridge.net_receive(int(d["id"]), d["data"] as PackedByteArray)


## Per-peer token buckets (packets and bytes). False = drop this packet (and count a violation).
func _rate_ok(id: int, info: Dictionary, size: int) -> bool:
	var dt: float = maxf(0.0, _clock - float(info.get("rl_at", _clock)))
	info["rl_at"] = _clock
	var pk: float = minf(PKT_BURST, float(info.get("pk_tok", PKT_BURST)) + dt * PKT_RATE)
	var by: float = minf(BYTE_BURST, float(info.get("by_tok", BYTE_BURST)) + dt * BYTE_RATE)
	if pk < 1.0 or by < float(size):
		info["pk_tok"] = pk
		info["by_tok"] = by
		_violation(id, "packet rate limit")
		return false
	info["pk_tok"] = pk - 1.0
	info["by_tok"] = by - float(size)
	return true


## One strike against a peer; MAX_VIOLATIONS inside VIOLATION_WINDOW kicks it (and counts toward an IP temp ban).
func _violation(id: int, why: String) -> void:
	if not peers.has(id):
		return
	var info: Dictionary = peers[id]
	if _clock - float(info.get("viol_t0", _clock)) > VIOLATION_WINDOW:
		info["viol_t0"] = _clock
		info["viol"] = 0
	info["viol"] = int(info.get("viol", 0)) + 1
	if int(info["viol"]) >= MAX_VIOLATIONS:
		_abuse_kick(id, "Too many invalid or too-fast packets (%s)." % why)


func _abuse_kick(id: int, why: String) -> void:
	if not peers.has(id):
		return
	var ip: String = str((peers[id] as Dictionary).get("ip", ""))
	var n: int = int(abuse_kicks.get(ip, 0)) + 1
	if ip != "":
		abuse_kicks[ip] = n
		if n >= ABUSE_KICKS_FOR_BAN and not _is_loopback(ip):
			temp_bans[ip] = _clock + TEMPBAN_SECS
	_emit({"type": "abuse", "id": id, "ip": ip, "message": why, "kicks": n})
	if bool((peers[id] as Dictionary).get("ready", false)):
		kick(id, why)
	else:
		_reject(id, Proto.REJECT_BAD, why, {})


func _send_control(to: int, kind: int, body: Dictionary, reliable: bool = true) -> void:
	_send_raw(to, Proto.pack_control(kind, body), reliable)


func _send_raw(to: int, pkt: PackedByteArray, reliable: bool) -> void:
	if peer == null:
		return
	peer.set_target_peer(to)
	peer.transfer_channel = Proto.CH_RELIABLE if reliable else Proto.CH_UNRELIABLE
	peer.transfer_mode = MultiplayerPeer.TRANSFER_MODE_RELIABLE if reliable else MultiplayerPeer.TRANSFER_MODE_UNRELIABLE
	peer.put_packet(pkt)


# --- server side -------------------------------------------------------------------------------------

func _on_peer_connected(id: int) -> void:
	if mode == "server":
		peers[id] = _new_peer(id)
		var ip: String = str((peers[id] as Dictionary).get("ip", ""))
		if _is_temp_banned(ip) or banned.has(ip):
			_reject(id, Proto.REJECT_BANNED, "You are banned from this server.", {})
			return
		if not _is_loopback(ip):
			var same: int = 0
			for oid in peers:
				if int(oid) != id and str((peers[oid] as Dictionary).get("ip", "")) == ip:
					same += 1
			if same >= MAX_PER_IP:
				_reject(id, Proto.REJECT_FULL, "Too many connections from your address.", {})


func _new_peer(id: int) -> Dictionary:
	return {"name": "", "ready": false, "t0": _clock, "last_rx": _clock, "rtt": -1, "ip": _peer_ip(id),
		"pk_tok": PKT_BURST, "by_tok": BYTE_BURST, "rl_at": _clock, "viol": 0, "viol_t0": _clock,
		"chat_tok": CHAT_BURST, "chat_at": _clock, "chat_viol": [], "last_chat": "", "last_chat_at": -100.0,
		"reports_sent": []}


static func _is_loopback(ip: String) -> bool:
	return ip == "127.0.0.1" or ip == "::1" or ip == "localhost" or ip.begins_with("::ffff:127.")


func _is_temp_banned(ip: String) -> bool:
	if ip == "" or _is_loopback(ip) or not temp_bans.has(ip):
		return false
	if _clock >= float(temp_bans[ip]):
		temp_bans.erase(ip)
		return false
	return true


func _on_peer_disconnected(id: int) -> void:
	_closing.erase(id)
	if mode == "server":
		_forget(id, "left")
	elif mode == "client" and id == SERVER_ID:
		_closed_reason = _closed_reason if _closed_reason != "" else "The server closed the connection."


func ready_count() -> int:
	var n: int = 0
	for id in peers:
		if bool((peers[id] as Dictionary).get("ready", false)):
			n += 1
	return n


func _server_hello(id: int, hello: Dictionary) -> void:
	var info: Dictionary = peers[id]
	if bool(info.get("ready", false)):
		return
	if hello.is_empty():
		_reject(id, Proto.REJECT_BAD, "Bad handshake.", {})
		return
	var their_proto: int = Proto.num_int(hello.get("proto", 0), 0, 65535)
	if their_proto != Proto.PROTO:
		_reject(id, Proto.REJECT_PROTO, "This server speaks a different multiplayer protocol (server %d, you %d). Update NovaSwift." % [Proto.PROTO, their_proto], {})
		return
	var their_pw: String = Proto.str_field(hello.get("pw", ""), 128)
	info["name"] = Proto.clean_player_name(hello.get("name", ""), "Pilot %d" % id)
	if password != "" and Proto.hash_password(password) != their_pw:
		_reject(id, Proto.REJECT_PASSWORD, "Wrong password." if their_pw != "" else "This server needs a password.", {})
		return
	var ip: String = str(info.get("ip", ""))
	if _is_temp_banned(ip):
		_reject(id, Proto.REJECT_BANNED, "You are temporarily banned from this server.", {})
		return
	if banned.has(ip):
		_reject(id, Proto.REJECT_BANNED, "You are banned from this server.", {})
		return
	var cap: int = max_players - (1 if has_local_player else 0)
	if ready_count() >= cap:
		_reject(id, Proto.REJECT_FULL, "The server is full (%d/%d)." % [ready_count() + (1 if has_local_player else 0), max_players], {})
		return
	var mine: String = ""
	if bridge != null and bridge.has_method("net_ready_manifest"):
		mine = str(bridge.net_ready_manifest())
	var theirs: String = hello.get("manifest", "") as String if hello.get("manifest", "") is String else ""
	if theirs.length() > 30000:
		_reject(id, Proto.REJECT_BAD, "Bad handshake.", {})
		return
	if mine != "" and theirs != "" and Proto.manifest_signature(mine) != Proto.manifest_signature(theirs):
		var li: Dictionary = NetPlugins.local_info(bridge, true)
		_reject(id, Proto.REJECT_PLUGINS, "Your enabled plug-ins don't match the server's. Match its plug-in list, then rejoin.",
			{"server_manifest": mine, "client_manifest": theirs, "server_tc": str(li.get("tc", "")), "server_addons": li.get("addons", [])})
		return
	var nm: String = _unique_name(Proto.clean_player_name(hello.get("name", ""), "Pilot %d" % id), id)
	info["name"] = nm
	info["ready"] = true
	var list: Array = []
	if has_local_player:
		list.append({"id": SERVER_ID, "name": display_name})
	for oid in peers:
		if int(oid) != id and bool((peers[oid] as Dictionary).get("ready", false)):
			list.append({"id": int(oid), "name": str((peers[oid] as Dictionary)["name"])})
	_send_control(id, Proto.K_WELCOME, {"your_id": id, "server_name": server_name, "host_name": display_name if has_local_player else "[Server]",
		"has_local_player": has_local_player, "rules": rules_json, "peers": list, "max": max_players, "proto": Proto.PROTO,
		"version": Proto.game_version()})
	for oid in peers:
		if int(oid) != id and bool((peers[oid] as Dictionary).get("ready", false)):
			_send_control(int(oid), Proto.K_PEER_JOIN, {"id": id, "name": nm})
	if bridge_active and bridge.has_method("net_peer_joined"):
		bridge.net_peer_joined(id, nm)
	_emit({"type": "peer_joined", "id": id, "name": nm})


func _unique_name(want: String, id: int) -> String:
	var taken: Dictionary = {display_name.to_lower(): true} if has_local_player else {}
	for oid in peers:
		if int(oid) != id and bool((peers[oid] as Dictionary).get("ready", false)):
			taken[str((peers[oid] as Dictionary)["name"]).to_lower()] = true
	var nm: String = want
	var n: int = 2
	while taken.has(nm.to_lower()):
		nm = "%s (%d)" % [want, n]
		n += 1
	return nm


func _reject(id: int, code: String, message: String, detail: Dictionary) -> void:
	_send_control(id, Proto.K_REJECT, {"code": code, "message": message, "detail": detail})
	_emit({"type": "refused", "id": id, "code": code, "message": message, "ip": str((peers[id] as Dictionary).get("ip", "")),
		"name": str((peers[id] as Dictionary).get("name", ""))})
	_closing[id] = _clock + 0.3
	peers.erase(id)


func _server_ping(id: int, body: Dictionary) -> void:
	var info: Dictionary = peers[id]
	info["rtt"] = Proto.num_int(body.get("rtt", -1), -1, 60000, -1)
	_send_control(id, Proto.K_PONG, {"t": Proto.num_float(body.get("t", 0.0), -1.0e9, 1.0e9)}, false)


func _server_chat(id: int, body: Dictionary) -> void:
	var info: Dictionary = peers[id]
	if not bool(info.get("ready", false)):
		return
	var text: String = Proto.clean_chat(body.get("text", ""))
	if text == "":
		return
	# Token bucket (burst 4, 2/s) + duplicate suppression; 10 dropped lines in 30 s = kick.
	var dt: float = maxf(0.0, _clock - float(info.get("chat_at", _clock)))
	info["chat_at"] = _clock
	var tok: float = minf(CHAT_BURST, float(info.get("chat_tok", CHAT_BURST)) + dt * CHAT_REFILL)
	var dupe: bool = text == str(info.get("last_chat", "")) and _clock - float(info.get("last_chat_at", -100.0)) < 5.0
	if tok < 1.0 or dupe:
		info["chat_tok"] = tok
		_chat_violation(id, info)
		return
	info["chat_tok"] = tok - 1.0
	info["last_chat"] = text
	info["last_chat_at"] = _clock
	if text.begins_with("/"):
		_server_command(id, info, text)
		return
	var out: Dictionary = {"id": id, "name": str(info["name"]), "text": text}
	for oid in peers:
		if bool((peers[oid] as Dictionary).get("ready", false)):
			_send_control(int(oid), Proto.K_CHAT, out)
	_emit({"type": "chat", "id": id, "name": str(info["name"]), "text": text})


func _chat_violation(id: int, info: Dictionary) -> void:
	var v: Array = info.get("chat_viol", []) as Array
	v.append(_clock)
	while not v.is_empty() and _clock - float(v[0]) > CHAT_VIOLATION_WINDOW:
		v.pop_front()
	info["chat_viol"] = v
	if v.size() >= CHAT_VIOLATIONS:
		_abuse_kick(id, "Kicked for spamming chat.")


## "/report <name|id> [why]" is honoured (as an "abuse" report); /votekick, /votes, /help and anything else are
## logged and ignored by this server (votekick lives in the Apple-hosted server only).
func _server_command(id: int, info: Dictionary, text: String) -> void:
	var parts: PackedStringArray = text.substr(1).split(" ", false, 2)
	var cmd: String = parts[0].to_lower() if parts.size() > 0 else ""
	_emit({"type": "command", "id": id, "name": str(info["name"]), "text": text})
	if cmd == "report" and parts.size() > 1:
		var target: int = find_peer(parts[1])
		if target > 0:
			_apply_report(id, target, "abuse", parts[2] if parts.size() > 2 else "")


## K_REPORT {id, reason, detail}: counted per target; 3 distinct reporters inside 60 s, or 5 "invalid" reports, kicks
## the target and temp-bans its address for 10 minutes.
func _server_report(id: int, body: Dictionary) -> void:
	var info: Dictionary = peers[id]
	if not bool(info.get("ready", false)) or body.is_empty():
		return
	var sent: Array = info.get("reports_sent", []) as Array
	while not sent.is_empty() and _clock - float(sent[0]) > REPORT_WINDOW:
		sent.pop_front()
	if sent.size() >= 6:
		_violation(id, "report spam")
		return
	sent.append(_clock)
	info["reports_sent"] = sent
	var target: int = Proto.num_int(body.get("id", 0), 0, 2147483647)
	var reason: String = Proto.str_field(body.get("reason", ""), 16)
	if not Proto.REPORT_REASONS.has(reason):
		reason = "invalid"
	var detail: String = Proto.str_field(body.get("detail", ""), Proto.MAX_REPORT_DETAIL)
	if target == 0:
		_emit({"type": "report", "from": id, "from_name": str(info["name"]), "target": 0, "reason": reason, "detail": detail, "message": "auto-detected invalid data"})
		return
	_apply_report(id, target, reason, detail)


func _apply_report(from: int, target: int, reason: String, detail: String) -> void:
	if target == from or target == SERVER_ID or not peers.has(target) or not bool((peers[target] as Dictionary).get("ready", false)):
		return
	var rec: Dictionary = _reports.get(target, {"by": {}, "invalid": {}})
	var by: Dictionary = rec["by"]
	by[from] = _clock
	for k in by.keys():
		if _clock - float(by[k]) > REPORT_WINDOW:
			by.erase(k)
	if reason == "invalid":
		(rec["invalid"] as Dictionary)[from] = true   # one "invalid" vote per reporter per target
	_reports[target] = rec
	_emit({"type": "report", "from": from, "from_name": str((peers[from] as Dictionary).get("name", "")), "target": target,
		"target_name": str((peers[target] as Dictionary).get("name", "")), "reason": reason, "detail": detail,
		"message": "%d distinct reporter(s), %d invalid" % [by.size(), (rec["invalid"] as Dictionary).size()]})
	if by.size() >= REPORT_DISTINCT_KICK or (rec["invalid"] as Dictionary).size() >= REPORT_INVALID_KICK:
		var ip: String = str((peers[target] as Dictionary).get("ip", ""))
		if ip != "" and not _is_loopback(ip):
			temp_bans[ip] = _clock + TEMPBAN_SECS
		_reports.erase(target)
		kick(target, "Removed after player reports. You can rejoin in 10 minutes.")


func _server_data(from: int, ch: int, pkt: PackedByteArray) -> void:
	var info: Dictionary = peers[from]
	if not bool(info.get("ready", false)):
		return
	var d: Dictionary = Proto.unpack_data(pkt)
	if d.is_empty():
		return
	var target: int = Proto.num_int(d["id"], -1, 2147483647, -1)
	var payload: PackedByteArray = d["data"] as PackedByteArray
	var reliable: bool = ch != Proto.CH_UNRELIABLE
	if target == -1 or target == SERVER_ID:
		if bridge_active:
			bridge.net_receive(from, payload)
	if target == -1:
		var out: PackedByteArray = Proto.pack_data(from, payload)
		for oid in peers:
			if int(oid) != from and bool((peers[oid] as Dictionary).get("ready", false)):
				_send_raw(int(oid), out, reliable)
	elif target != SERVER_ID and peers.has(target) and bool((peers[target] as Dictionary).get("ready", false)):
		_send_raw(target, Proto.pack_data(from, payload), reliable)


## Disconnect a peer (kick). `reason` is shown to them.
func kick(id: int, reason: String = "Kicked by the host.", ban: bool = false) -> bool:
	if mode != "server" or not peers.has(id):
		return false
	if ban:
		banned[str((peers[id] as Dictionary).get("ip", ""))] = true
	if bridge_active and bridge.has_method("net_kick"):
		bridge.net_kick(id, ban)   # the session's own kick/ban list + its goodbye packet
		_pump_outgoing()
	_send_control(id, Proto.K_KICK, {"reason": reason})
	_forget(id, "kicked")
	_closing[id] = _clock + 0.3
	return true


func _drop(id: int, reason: String) -> void:
	if peer != null:
		peer.disconnect_peer(id, false)
	_forget(id, reason)


func _forget(id: int, reason: String) -> void:
	if not peers.has(id):
		return
	var info: Dictionary = peers[id]
	peers.erase(id)
	_reports.erase(id)
	if not bool(info.get("ready", false)):
		return
	for oid in peers:
		if bool((peers[oid] as Dictionary).get("ready", false)):
			_send_control(int(oid), Proto.K_PEER_LEFT, {"id": id, "reason": reason})
	if bridge_active and bridge.has_method("net_peer_left"):
		bridge.net_peer_left(id)
	_emit({"type": "peer_left", "id": id, "name": str(info.get("name", "")), "reason": reason})


func find_peer(token: String) -> int:
	var t: String = token.strip_edges()
	if t.is_valid_int() and peers.has(t.to_int()):
		return t.to_int()
	for id in peers:
		if str((peers[id] as Dictionary).get("name", "")).to_lower() == t.to_lower():
			return int(id)
	return -1


# --- client side -------------------------------------------------------------------------------------

func _client_welcome(w: Dictionary) -> void:
	if state != "handshaking" or w.is_empty():
		return
	state = "connected"
	local_id = Proto.num_int(w.get("your_id", peer.get_unique_id()), 1, 2147483647, peer.get_unique_id())
	server_name = Proto.clean_name(Proto.str_field(w.get("server_name", ""), Proto.MAX_SERVER_NAME), "Server", Proto.MAX_SERVER_NAME)
	rules_json = w.get("rules", "") as String if w.get("rules", "") is String and (w.get("rules", "") as String).length() <= 4096 else ""
	max_players = Proto.num_int(w.get("max", max_players), 1, 64, max_players)
	has_local_player = w.get("has_local_player", true) != false
	bridge_active = _bridge_begin(local_id, display_name, false, "")
	peers.clear()
	var raw_label: Variant = w.get("host_name", server_name)
	_host_label = "[Server]" if (raw_label is String and raw_label == "[Server]" and not has_local_player) else Proto.clean_name(Proto.str_field(raw_label, Proto.MAX_NAME), "Host")
	var host_label: String = _host_label
	if bridge_active and bridge.has_method("net_peer_joined"):
		bridge.net_peer_joined(SERVER_ID, host_label)   # the host's participant (a dedicated server has no pilot but still relays/authors)
	var plist: Variant = w.get("peers", [])
	if plist is Array:
		for item in (plist as Array):
			if peers.size() >= Proto.MAX_LIST:
				break
			if not (item is Dictionary):
				continue
			var o: Dictionary = item
			var oid: int = Proto.num_int(o.get("id", 0), 0, 2147483647)
			if oid <= 0:
				continue
			var onm: String = Proto.clean_player_name(o.get("name", ""), "Pilot %d" % oid)
			peers[oid] = {"name": onm, "ready": true}
			if oid != SERVER_ID and bridge_active and bridge.has_method("net_peer_joined"):
				bridge.net_peer_joined(oid, onm)
	_last_rx = _clock
	var sv: String = Proto.str_field(w.get("version", ""), 32)
	_emit({"type": "connected", "address": address, "server_name": server_name, "id": local_id, "bridge": bridge_active,
		"has_host_player": has_local_player, "host_name": host_label, "rules": rules_json,
		"server_version": sv, "version_differs": sv != "" and sv != Proto.game_version()})


func _client_reject(r: Dictionary) -> void:
	var detail: Dictionary = {}
	var rd: Variant = r.get("detail", {})
	if rd is Dictionary:
		var d: Dictionary = rd
		var addons: Array = []
		var raw_addons: Variant = d.get("server_addons", [])
		if raw_addons is Array:
			for a in (raw_addons as Array):
				if addons.size() < Proto.MAX_LIST and (a is String):
					addons.append(Proto.str_field(a, 64))
		detail = {"server_manifest": d.get("server_manifest", "") as String if d.get("server_manifest", "") is String and (d.get("server_manifest", "") as String).length() <= 30000 else "",
			"client_manifest": d.get("client_manifest", "") as String if d.get("client_manifest", "") is String and (d.get("client_manifest", "") as String).length() <= 30000 else "",
			"server_tc": Proto.str_field(d.get("server_tc", ""), 64), "server_addons": addons}
	var code: String = Proto.str_field(r.get("code", "refused"), 32)
	_closed_reason = Proto.clean_text(r.get("message", "The server refused the connection."), 300)
	if _closed_reason == "":
		_closed_reason = "The server refused the connection."
	if peer != null:
		peer.close()
	peer = null
	mode = "none"
	state = "closed"
	peers.clear()
	_emit({"type": "rejected", "code": code, "message": _closed_reason, "detail": detail, "address": address})


func _client_peer_join(b: Dictionary) -> void:
	if state != "connected":
		return
	var id: int = Proto.num_int(b.get("id", 0), 0, 2147483647)
	if id <= 0 or (peers.size() >= Proto.MAX_LIST and not peers.has(id)):
		return
	var nm: String = Proto.clean_player_name(b.get("name", ""), "Pilot %d" % id)
	peers[id] = {"name": nm, "ready": true}
	if bridge_active and bridge.has_method("net_peer_joined"):
		bridge.net_peer_joined(id, nm)
	_emit({"type": "peer_joined", "id": id, "name": nm})


func _client_peer_left(b: Dictionary) -> void:
	var id: int = Proto.num_int(b.get("id", 0), 0, 2147483647)
	var nm: String = str((peers.get(id, {}) as Dictionary).get("name", ""))
	peers.erase(id)
	if bridge_active and bridge.has_method("net_peer_left"):
		bridge.net_peer_left(id)
	_emit({"type": "peer_left", "id": id, "name": nm, "reason": Proto.clean_text(b.get("reason", ""), 64)})


func _client_kick(b: Dictionary) -> void:
	var why: String = Proto.clean_text(b.get("reason", ""), 300)
	if why == "":
		why = "Disconnected by the host."
	_closed_reason = why
	_end_bridge()
	if peer != null:
		peer.close()
	peer = null
	mode = "none"
	state = "closed"
	peers.clear()
	_emit({"type": "kicked", "reason": why})


func _client_pong(b: Dictionary) -> void:
	var sent: float = Proto.num_float(b.get("t", _clock), -1.0e9, 1.0e9, _clock)
	var ms: int = clampi(int(round((_clock - sent) * 1000.0)), 0, 60000)
	rtt_ms = ms if rtt_ms < 0 else int(round(rtt_ms * 0.7 + ms * 0.3))


func _client_chat(b: Dictionary) -> void:
	var text: String = Proto.clean_chat(b.get("text", ""))
	if text == "":
		return
	var id: int = Proto.num_int(b.get("id", 0), 0, 2147483647)
	var nm: String
	if id == SERVER_ID:
		nm = _host_label if _host_label != "" else "Host"
	elif peers.has(id):
		nm = str((peers[id] as Dictionary).get("name", "?"))   # the roster's name, never the packet's
	else:
		nm = Proto.clean_player_name(b.get("name", ""), "?")
	_emit({"type": "chat", "id": id, "name": nm, "text": text})


# --- bridge pump -------------------------------------------------------------------------------------

func _bridge_begin(id: int, name: String, is_host: bool, rules: String) -> bool:
	if bridge == null or not bridge.has_method("net_begin"):
		return false
	var ok: Variant = bridge.net_begin(id, name, is_host, rules)
	return bool(ok)


func _pump_outgoing(final: bool = false) -> void:
	if (not bridge_active and not final) or bridge == null or not bridge.has_method("net_outgoing") or state != "connected" or peer == null:
		return
	var batch: Variant = bridge.net_outgoing()
	if not (batch is Array):
		return
	for item in batch:
		if not (item is Dictionary):
			continue
		var m: Dictionary = item
		var data: PackedByteArray = m.get("data", PackedByteArray()) as PackedByteArray
		var to: int = int(m.get("to", -1))
		var reliable: bool = bool(m.get("reliable", true))
		if mode == "server":
			if to == -1:
				var out: PackedByteArray = Proto.pack_data(SERVER_ID, data)
				for oid in peers:
					if bool((peers[oid] as Dictionary).get("ready", false)):
						_send_raw(int(oid), out, reliable)
			elif peers.has(to) and bool((peers[to] as Dictionary).get("ready", false)):
				_send_raw(to, Proto.pack_data(SERVER_ID, data), reliable)
		else:
			_send_raw(SERVER_ID, Proto.pack_data(to, data), reliable)


## Chat through the bridge when it has net_chat (the engine's chat log + moderation), else the transport's own.
## Returns false when the line was empty, we're not in a session, or the local rate limit (burst 4, 2/s) dropped it.
func send_chat(text: String) -> bool:
	var t: String = Proto.clean_chat(text)
	if t == "" or not is_connected_to_session():
		return false
	if not (mode == "server" and not has_local_player):   # the dedicated console is exempt
		var dt: float = maxf(0.0, _clock - _chat_at)
		_chat_at = _clock
		_chat_tokens = minf(CHAT_BURST, _chat_tokens + dt * CHAT_REFILL)
		if _chat_tokens < 1.0:
			return false
		_chat_tokens -= 1.0
	if bridge_active and bridge != null and bridge.has_method("net_chat"):
		bridge.net_chat(t)
	elif mode == "server":
		_server_say(t)
	else:
		_send_control(SERVER_ID, Proto.K_CHAT, {"text": t})
	return true


## Tell the server about a player (K_REPORT). target 0 = auto-detected invalid data. reason: invalid|abuse|cheat|spam.
func send_report(target: int, reason: String, detail: String = "") -> void:
	if mode != "client" or not is_connected_to_session():
		return
	if not Proto.REPORT_REASONS.has(reason):
		reason = "invalid"
	_send_control(SERVER_ID, Proto.K_REPORT, {"id": maxi(0, target), "reason": reason, "detail": Proto.str_field(detail, Proto.MAX_REPORT_DETAIL)})


func _server_say(t: String) -> void:
	var nm: String = display_name if has_local_player else "[Server]"
	for oid in peers:
		if bool((peers[oid] as Dictionary).get("ready", false)):
			_send_control(int(oid), Proto.K_CHAT, {"id": SERVER_ID, "name": nm, "text": t})
	_emit({"type": "chat", "id": SERVER_ID, "name": nm, "text": t})


## Players as the transport knows them (used when net_state is unavailable): [{id, name, rtt}].
func roster() -> Array:
	var out: Array = []
	if not is_active():
		return out
	if mode == "server":
		out.append({"id": SERVER_ID, "name": display_name if has_local_player else "[Server]", "rtt": 0})
		for id in peers:
			var info: Dictionary = peers[id]
			if bool(info.get("ready", false)):
				out.append({"id": int(id), "name": str(info["name"]), "rtt": int(info.get("rtt", -1))})
	else:
		out.append({"id": local_id, "name": display_name, "rtt": rtt_ms})
		for id in peers:
			out.append({"id": int(id), "name": str((peers[id] as Dictionary)["name"]), "rtt": -1})
	return out


func _peer_ip(id: int) -> String:
	var pp: ENetPacketPeer = peer.get_peer(id) if peer != null else null
	return pp.get_remote_address() if pp != null else ""


func _emit(ev: Dictionary) -> void:
	event.emit(ev)


static func _bind_error(err: int) -> String:
	if err == ERR_CANT_CREATE:
		return "Couldn't open the port. Another game or server may already be using it - pick a different port."
	return "Couldn't start the server (%s)." % error_string(err)
