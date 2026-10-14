# NOVA Swift -- multiplayer wire constants and pure helpers (no state, no scene access).
#
# Shared by NetTransport (ENet), LanDiscovery (UDP beacons), ServerMain (dedicated server) and the
# multiplayer screens, and unit-tested headless by tests/net_ui_selfcheck.gd. See docs/MULTIPLAYER.md
# "Playing online on Linux / Steam Deck / Windows".
#
# Loaded with preload() (no class_name), like Controls.gd.
extends RefCounted

## Bumped when the handshake or the packet framing below changes incompatibly.
const PROTO := 1
const DEFAULT_PORT := 53735
## UDP port LAN beacons are broadcast to / listened on (and the query port of a default-port server).
const LAN_PORT := 53736
const MAX_NAME := 24

# Packet kinds (first byte). Control kinds carry a UTF-8 JSON body; DATA carries [int32 peer id][bridge bytes].
const K_HELLO := 0x01      # client -> server: {proto, version, name, pw, manifest}
const K_WELCOME := 0x02    # server -> client: {your_id, server_name, rules, peers:[{id,name}], max}
const K_REJECT := 0x03     # server -> client: {code, message, detail}
const K_PEER_JOIN := 0x04  # server -> clients: {id, name}
const K_PEER_LEFT := 0x05  # server -> clients: {id, reason}
const K_KICK := 0x06       # server -> client: {reason}
const K_PING := 0x07       # client -> server: {t, rtt}
const K_PONG := 0x08       # server -> client: {t}
const K_CHAT := 0x09       # fallback chat (used only when the bridge has no net_chat): {text} / {id, name, text}
const K_DATA := 0x10       # game bytes (bridge net_outgoing / net_receive)

const CH_RELIABLE := 0
const CH_UNRELIABLE := 1

## Reject codes (K_REJECT.code); the UI maps them to titles.
const REJECT_VERSION := "version"
const REJECT_PROTO := "proto"
const REJECT_PASSWORD := "password"
const REJECT_FULL := "full"
const REJECT_PLUGINS := "plugins"
const REJECT_BANNED := "banned"
const REJECT_BAD := "bad_request"

const BEACON_MAGIC := "NSB1"
const QUERY_MAGIC := "NSQ1"


static func game_version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "0"))


## "host", "host:port", "1.2.3.4:5", "[::1]:5" -> {ok, host, port, error}. A bare IPv6 literal (two or more
## colons, no brackets) is taken whole with the default port.
static func parse_address(text: String, default_port: int = DEFAULT_PORT) -> Dictionary:
	var s: String = text.strip_edges()
	for scheme in ["nova://", "novaswift://", "udp://"]:
		if s.begins_with(scheme):
			s = s.substr(scheme.length())
	if s.ends_with("/"):
		s = s.substr(0, s.length() - 1)
	if s == "":
		return {"ok": false, "host": "", "port": default_port, "error": "Enter a server address, like 192.168.1.20 or play.example.com:53735."}
	var host: String = s
	var port: int = default_port
	if s.begins_with("["):
		var close: int = s.find("]")
		if close < 0:
			return {"ok": false, "host": "", "port": default_port, "error": "Missing ] in the IPv6 address."}
		host = s.substr(1, close - 1)
		var rest: String = s.substr(close + 1)
		if rest != "":
			if not rest.begins_with(":"):
				return {"ok": false, "host": "", "port": default_port, "error": "Unexpected text after the address."}
			var pr: Dictionary = _parse_port(rest.substr(1))
			if not bool(pr["ok"]):
				return {"ok": false, "host": "", "port": default_port, "error": str(pr["error"])}
			port = int(pr["port"])
	elif s.count(":") == 1:
		var i: int = s.rfind(":")
		host = s.substr(0, i)
		var pr2: Dictionary = _parse_port(s.substr(i + 1))
		if not bool(pr2["ok"]):
			return {"ok": false, "host": "", "port": default_port, "error": str(pr2["error"])}
		port = int(pr2["port"])
	if host.strip_edges() == "" or host.contains(" "):
		return {"ok": false, "host": "", "port": default_port, "error": "That doesn't look like a server address."}
	return {"ok": true, "host": host, "port": port, "error": ""}


static func _parse_port(t: String) -> Dictionary:
	var p: String = t.strip_edges()
	if p == "" or not p.is_valid_int():
		return {"ok": false, "port": 0, "error": "The port must be a number between 1 and 65535."}
	var n: int = p.to_int()
	if n < 1 or n > 65535:
		return {"ok": false, "port": 0, "error": "The port must be a number between 1 and 65535."}
	return {"ok": true, "port": n, "error": ""}


static func format_address(host: String, port: int) -> String:
	var h: String = "[%s]" % host if host.count(":") >= 2 else host
	return h if port == DEFAULT_PORT else "%s:%d" % [h, port]


## Trim, strip control characters, cap the length. Never empty.
static func clean_name(raw: String, fallback: String = "Pilot") -> String:
	var out: String = ""
	for i in raw.length():
		var c: int = raw.unicode_at(i)
		if c >= 32 and c != 127:
			out += raw.substr(i, 1)
	out = out.strip_edges()
	if out.length() > MAX_NAME:
		out = out.substr(0, MAX_NAME).strip_edges()
	return out if out != "" else fallback


static func hash_password(pw: String) -> String:
	return "" if pw == "" else ("novaswift:" + pw).sha256_text()


## SessionRules (the bridge's lenient snake_case keys) for a preset. "safe" = sparring, "full" = real stakes.
static func rules_for_preset(preset: String) -> Dictionary:
	var full: bool = preset == "full"
	return {"pvp_damage_real": full, "death_real": full, "friendly_fire": full, "allow_pvp": true,
		"allow_trade": true, "carry_encounter": full, "game_speed_multiplier": 1.0}


## Which preset a rules dictionary equals: "safe", "full" or "custom".
static func preset_of(rules: Dictionary) -> String:
	for p in ["safe", "full"]:
		var r: Dictionary = rules_for_preset(p)
		var same: bool = true
		for k in r:
			if k == "game_speed_multiplier":
				continue
			if bool(rules.get(k, false)) != bool(r[k]):
				same = false
		if same:
			return p
	return "custom"


## A canonical string for comparing two PluginManifest JSONs (key order and whitespace do not matter).
static func manifest_signature(json_text: String) -> String:
	var t: String = json_text.strip_edges()
	if t == "":
		return ""
	var v: Variant = JSON.parse_string(t)
	if v is Dictionary:
		return JSON.stringify(v, "", true)
	if v is Array:
		return JSON.stringify(v)
	return t


# --- framing ---------------------------------------------------------------------------------------

static func pack_control(kind: int, body: Dictionary) -> PackedByteArray:
	var b: PackedByteArray = PackedByteArray()
	b.append(kind)
	b.append_array(JSON.stringify(body).to_utf8_buffer())
	return b


static func unpack_control(pkt: PackedByteArray) -> Dictionary:
	if pkt.size() < 2 or pkt.size() > 65536:
		return {}
	var v: Variant = JSON.parse_string(pkt.slice(1).get_string_from_utf8())
	return v if v is Dictionary else {}


static func pack_data(peer_id: int, payload: PackedByteArray) -> PackedByteArray:
	var b: PackedByteArray = PackedByteArray()
	b.resize(5)
	b[0] = K_DATA
	b.encode_s32(1, peer_id)
	b.append_array(payload)
	return b


## -> {id, data} or {} when too short.
static func unpack_data(pkt: PackedByteArray) -> Dictionary:
	if pkt.size() < 5 or pkt[0] != K_DATA:
		return {}
	return {"id": pkt.decode_s32(1), "data": pkt.slice(5)}


# --- LAN beacon --------------------------------------------------------------------------------------

## {name, players, max, ver, pw, port, rules, dedicated} -> "NSB1" + JSON.
static func encode_beacon(info: Dictionary) -> PackedByteArray:
	var d: Dictionary = {
		"name": clean_name(str(info.get("name", "NovaSwift")), "NovaSwift"),
		"players": int(info.get("players", 0)),
		"max": int(info.get("max", 0)),
		"ver": str(info.get("ver", game_version())),
		"pw": bool(info.get("pw", false)),
		"port": int(info.get("port", DEFAULT_PORT)),
		"rules": str(info.get("rules", "")),
		"dedicated": bool(info.get("dedicated", false)),
	}
	var b: PackedByteArray = BEACON_MAGIC.to_utf8_buffer()
	b.append_array(JSON.stringify(d).to_utf8_buffer())
	return b


## Back to the info dictionary, or {} when it is not a beacon / is malformed.
static func decode_beacon(pkt: PackedByteArray) -> Dictionary:
	if pkt.size() < 6 or pkt.size() > 2048:
		return {}
	if pkt.slice(0, 4).get_string_from_ascii() != BEACON_MAGIC:
		return {}
	var v: Variant = JSON.parse_string(pkt.slice(4).get_string_from_utf8())
	if not (v is Dictionary):
		return {}
	var d: Dictionary = v
	var port: int = int(d.get("port", 0))
	if port < 1 or port > 65535:
		return {}
	return {"name": clean_name(str(d.get("name", "")), "Server"), "players": maxi(0, int(d.get("players", 0))),
		"max": maxi(0, int(d.get("max", 0))), "ver": str(d.get("ver", "")), "pw": bool(d.get("pw", false)),
		"port": port, "rules": str(d.get("rules", "")), "dedicated": bool(d.get("dedicated", false))}


static func is_query(pkt: PackedByteArray) -> bool:
	return pkt.size() == 4 and pkt.get_string_from_ascii() == QUERY_MAGIC


static func query_packet() -> PackedByteArray:
	return QUERY_MAGIC.to_utf8_buffer()
