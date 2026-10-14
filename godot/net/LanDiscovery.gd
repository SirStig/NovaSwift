# NOVA Swift -- LAN discovery and server pinging over plain UDP.
#
# Hosts / dedicated servers announce themselves: a small beacon (NetProto.encode_beacon: name, players/max,
# version, password?, port) is broadcast to 255.255.255.255:53736 every 2 s. The multiplayer browser listens
# on 53736 and keeps a table of what it hears (entries expire after 7 s without a beacon).
#
# The same socket answers unicast queries ("NSQ1" -> a beacon), which is how the Saved Servers list measures
# ping and shows live player counts for servers that are not on the LAN. A server on the default game port
# answers on 53736; one on port P answers on P + 1 (open that UDP port too if you want it pingable from the
# internet; joining only needs the game port).
#
# Everything is best effort: a bind failure (port taken, no network) is reported through `last_error` and
# never stops the game. poll() must be called every frame (NetService does).
#
# Loaded with preload() (no class_name), like Controls.gd.
extends RefCounted

const Proto = preload("res://net/NetProto.gd")

const ANNOUNCE_EVERY := 2.0
const EXPIRE_AFTER := 7.0
const QUERY_TIMEOUT := 3.0

## "ip:port" (game port) -> {name, players, max, ver, pw, port, rules, dedicated, ip, seen}
var servers: Dictionary = {}
## "host:port" (as asked) -> {rtt_ms, info, t} for completed queries; rtt_ms -1 = no answer yet / timed out.
var pings: Dictionary = {}
var last_error: String = ""

var _listen: PacketPeerUDP = null      # bound to Proto.LAN_PORT: beacons (browser) and queries (default-port server)
var _query_sock: PacketPeerUDP = null  # bound to game port + 1 for a custom-port server
var _tx: PacketPeerUDP = null          # unbound: broadcasts out, sends queries, receives their answers
var _provider: Callable = Callable()
var _announce_in: float = 0.0
var _now: float = 0.0
var _pending: Dictionary = {}          # "ip:qport" -> {key, t0, ms0, ip, qport, legacy_sent}
var _guard: Proto.QueryGuard = Proto.QueryGuard.new()   # per-source-IP NSQ1 rate limits (anti-amplification)
const MAX_PENDING := 512
const MAX_PKTS_PER_FRAME := 64


## Start listening for beacons (the LAN browser). Safe to call twice.
func start_listening() -> bool:
	if _listen != null:
		return true
	var s: PacketPeerUDP = PacketPeerUDP.new()
	s.set_broadcast_enabled(true)
	var err: int = s.bind(Proto.LAN_PORT, "*")
	if err != OK:
		last_error = "Can't listen for LAN games (UDP %d is busy: %s)." % [Proto.LAN_PORT, error_string(err)]
		return false
	_listen = s
	return true


## Start announcing. `provider` returns the beacon info Dictionary (called per beacon, so counts stay live).
func start_announcing(provider: Callable, game_port: int) -> bool:
	_provider = provider
	_ensure_tx()
	_announce_in = 0.0
	var qport: int = game_port + 1
	if qport == Proto.LAN_PORT:
		return start_listening() or true   # the listen socket doubles as the query responder
	if _query_sock == null:
		var s: PacketPeerUDP = PacketPeerUDP.new()
		var err: int = s.bind(qport, "*")
		if err != OK:
			last_error = "Server pinging is off (UDP %d is busy: %s)." % [qport, error_string(err)]
			return false
		_query_sock = s
	return true


func stop_announcing() -> void:
	_provider = Callable()
	if _query_sock != null:
		_query_sock.close()
		_query_sock = null


func stop() -> void:
	stop_announcing()
	for s in [_listen, _tx]:
		if s != null:
			(s as PacketPeerUDP).close()
	_listen = null
	_tx = null
	servers.clear()
	_pending.clear()


func is_announcing() -> bool:
	return _provider.is_valid()


func _ensure_tx() -> void:
	if _tx != null:
		return
	_tx = PacketPeerUDP.new()
	_tx.set_broadcast_enabled(true)


## Ask host:game_port for its beacon; poll() fills `pings[key]`. Returns the key.
func query(host: String, game_port: int) -> String:
	var key: String = "%s:%d" % [host, game_port]
	_ensure_tx()
	var ip: String = host if host.is_valid_ip_address() else _resolve(host)
	pings[key] = {"rtt_ms": -1, "info": {}, "t": _now, "ok": false}
	if ip == "":
		return key
	var qport: int = Proto.LAN_PORT if game_port == Proto.DEFAULT_PORT else game_port + 1
	_tx.set_dest_address(ip, qport)
	if _pending.size() >= MAX_PENDING:
		return key
	_tx.put_packet(Proto.build_query())   # v2: 1200 bytes (older servers only answer the bare 4-byte form: see _legacy_retry)
	_pending["%s:%d" % [ip, qport]] = {"key": key, "ms0": Time.get_ticks_msec(), "t0": _now, "ip": ip, "qport": qport, "legacy_sent": false}
	return key


## Hostname -> IP, remembered (IP.resolve_hostname blocks; the Public list queries many names every few seconds).
var _dns: Dictionary = {}   # host -> {ip, t}


func _resolve(host: String) -> String:
	var c: Variant = _dns.get(host)
	if c is Dictionary:
		var age: float = _now - float((c as Dictionary)["t"])
		if age < (300.0 if str((c as Dictionary)["ip"]) != "" else 20.0):
			return str((c as Dictionary)["ip"])
	var ip: String = IP.resolve_hostname(host)
	_dns[host] = {"ip": ip, "t": _now}
	return ip


func ping_ms(host: String, game_port: int) -> int:
	return int((pings.get("%s:%d" % [host, game_port], {}) as Dictionary).get("rtt_ms", -1))


## Table rows sorted by name: [{key, name, players, max, ver, pw, port, ip, ...}].
func lan_list() -> Array:
	var out: Array = []
	for k in servers:
		var row: Dictionary = (servers[k] as Dictionary).duplicate()
		row["key"] = k
		out.append(row)
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool: return str(a["name"]).naturalnocasecmp_to(str(b["name"])) < 0)
	return out


func poll(delta: float) -> void:
	_now += delta
	if _provider.is_valid():
		_announce_in -= delta
		if _announce_in <= 0.0:
			_announce_in = ANNOUNCE_EVERY
			_broadcast()
	if _listen != null:
		_drain(_listen, true)
	if _query_sock != null:
		_drain(_query_sock, false)
	if _tx != null:
		_drain_replies()
	for k in servers.keys():
		if _now - float((servers[k] as Dictionary)["seen"]) > EXPIRE_AFTER:
			servers.erase(k)
	for pk in _pending.keys():
		var pd: Dictionary = _pending[pk]
		var age: float = _now - float(pd["t0"])
		if age > QUERY_TIMEOUT:
			_pending.erase(pk)
		elif not bool(pd["legacy_sent"]) and age > maxf(0.6, QUERY_TIMEOUT / 3.0) and _tx != null:
			# No answer to the v2 request: an older server only knows the bare 4-byte "NSQ1". Once.
			pd["legacy_sent"] = true
			_tx.set_dest_address(str(pd["ip"]), int(pd["qport"]))
			_tx.put_packet(Proto.QUERY_MAGIC.to_utf8_buffer())


func _info() -> Dictionary:
	var v: Variant = _provider.call()
	return v if v is Dictionary else {}


func _broadcast() -> void:
	if _tx == null:
		return
	var pkt: PackedByteArray = Proto.encode_beacon(_info())
	_tx.set_dest_address("255.255.255.255", Proto.LAN_PORT)
	_tx.put_packet(pkt)


## Beacons -> table; queries -> unicast reply (only while announcing), rate limited and size capped.
func _drain(sock: PacketPeerUDP, take_beacons: bool) -> void:
	var n: int = 0
	while sock.get_available_packet_count() > 0:
		var pkt: PackedByteArray = sock.get_packet()
		n += 1
		if n > MAX_PKTS_PER_FRAME:
			continue   # flood: read and discard
		var ip: String = sock.get_packet_ip()
		var port: int = sock.get_packet_port()
		var qk: int = Proto.query_kind(pkt)
		if qk != Proto.Q_DROP:
			if _provider.is_valid() and port > 0 and _guard.admit(ip, pkt, _now) != Proto.Q_DROP:
				var reply: PackedByteArray
				if qk == Proto.Q_LEGACY:
					reply = Proto.legacy_reply()   # tiny "upgrade" notice: a bare query is an amplification vector
				elif qk == Proto.Q_CERT:
					reply = Proto.encode_cert_reply(_info(), mini(pkt.size(), 1400))   # Godot-only 1300-byte request: the cert reply never exceeds it
				else:
					reply = Proto.encode_status_reply(_info(), Proto.query_reply_cap(pkt.size()))
				if not reply.is_empty():
					sock.set_dest_address(ip, port)
					sock.put_packet(reply)
		elif take_beacons:
			_note_beacon(ip, pkt)


func _note_beacon(ip: String, pkt: PackedByteArray) -> void:
	var info: Dictionary = Proto.decode_beacon(pkt)
	if info.is_empty():
		return
	var key: String = "%s:%d" % [ip, int(info["port"])]
	if servers.size() >= 256 and not servers.has(key):
		return
	info["ip"] = ip
	info["seen"] = _now
	servers[key] = info


func _drain_replies() -> void:
	var n: int = 0
	while _tx.get_available_packet_count() > 0:
		var pkt: PackedByteArray = _tx.get_packet()
		n += 1
		var ip: String = _tx.get_packet_ip()
		var port: int = _tx.get_packet_port()
		var pk: String = "%s:%d" % [ip, port]
		if n > MAX_PKTS_PER_FRAME or not _pending.has(pk):
			continue   # nobody asked this address
		var info: Dictionary = Proto.decode_beacon(pkt)
		if info.is_empty():
			continue
		var p: Dictionary = _pending[pk]
		pings[str(p["key"])] = {"rtt_ms": maxi(1, Time.get_ticks_msec() - int(p["ms0"])), "info": info, "t": _now, "ok": true}
		_pending.erase(pk)
