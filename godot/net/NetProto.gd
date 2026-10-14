# NOVA Swift -- multiplayer wire constants and pure helpers (no state, no scene access).
#
# Shared by NetTransport (ENet), LanDiscovery (UDP beacons), ServerMain (dedicated server) and the
# multiplayer screens, and unit-tested headless by tests/net_ui_selfcheck.gd. See docs/MULTIPLAYER.md
# "Playing online on Linux / Steam Deck / Windows".
#
# Loaded with preload() (no class_name), like Controls.gd.
extends RefCounted

## The network PROTOCOL version (mirrors Swift `CrossPlayProtocol.wireProtocol`): bumped only when the handshake, the
## packet framing or the NetSession wire format changes incompatibly. Different app versions with the same PROTO
## connect fine; the game version is informational (a "different version" note), not a gate.
const PROTO := 1
const DEFAULT_PORT := 53735
## UDP port LAN beacons are broadcast to / listened on (and the query port of a default-port server).
const LAN_PORT := 53736
const MAX_NAME := 24
## Server names can be longer than pilot names (the public directory allows 40).
const MAX_SERVER_NAME := 40
## The online hosting guide (the players' "how do I host" link; there is no site page for it yet).
const HOSTING_URL := "https://github.com/SirStig/NovaSwift/blob/main/docs/MULTIPLAYER.md#host-a-public-server-in-5-minutes"

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
const K_REPORT := 0x0A     # client -> server: {id: int (0 = auto-detected invalid data), reason: "invalid"|"abuse"|"cheat"|"spam", detail: string <= 120}
const K_DATA := 0x10       # game bytes (bridge net_outgoing / net_receive)

## Packet size limits (bytes, whole packet including the kind byte). Anything bigger is dropped unread.
const MAX_PKT_DATA := 65536
const MAX_PKT_HELLO := 32768
const MAX_PKT_SMALL := 1024   # CHAT / PING / REPORT
const MAX_PKT_CONTROL := 65536
const MAX_CHAT := 200
const MAX_REPORT_DETAIL := 120
const MAX_LIST := 64
const REPORT_REASONS: Array = ["invalid", "abuse", "cheat", "spam"]

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


## True for characters that never belong in a name / chat line: control characters (< 32, 127, 0x80-0x9F) and
## zero-width / bidi / format / variation-selector / tag characters.
static func is_invisible(c: int) -> bool:
	if c < 32 or c == 127 or (c >= 0x80 and c <= 0x9F):
		return true
	if c < 0xAD:
		return false
	return (c == 0xAD or c == 0x34F or c == 0x61C or c == 0x115F or c == 0x1160 or c == 0x17B4 or c == 0x17B5
		or (c >= 0x180B and c <= 0x180E) or (c >= 0x200B and c <= 0x200F) or (c >= 0x202A and c <= 0x202E)
		or (c >= 0x2060 and c <= 0x206F) or c == 0x3164 or (c >= 0xFE00 and c <= 0xFE0F) or c == 0xFEFF or c == 0xFFA0
		or (c >= 0xFFF9 and c <= 0xFFFB) or (c >= 0xE0000 and c <= 0xE007F))


## Unicode space separators that are folded to one plain space (NBSP, en/em spaces, ideographic space...).
static func _is_exotic_space(c: int) -> bool:
	return c == 0xA0 or c == 0x1680 or (c >= 0x2000 and c <= 0x200A) or c == 0x202F or c == 0x205F or c == 0x3000


## Strip invisible/control characters, fold exotic spaces, collapse whitespace runs to one space, trim, cap the length.
## Never empty (returns `fallback`). Mirrors Swift CrossPlayProtocol.cleanName.
static func clean_name(raw: String, fallback: String = "Pilot", max_len: int = MAX_NAME) -> String:
	var out: String = _clean_text(raw, max_len, true)
	return out if out != "" else fallback


static func _clean_text(raw: String, max_len: int, collapse: bool) -> String:
	var out: PackedStringArray = PackedStringArray()
	var last_space: bool = true   # leading spaces are dropped
	var n: int = mini(raw.length(), max_len * 4 + 64)   # never walk a megabyte string
	for i in n:
		var c: int = raw.unicode_at(i)
		if is_invisible(c) or (c >= 0xD800 and c <= 0xDFFF) or c > 0x10FFFF:
			continue
		if c == 32 or _is_exotic_space(c):
			if last_space and collapse:
				continue
			out.append(" ")
			last_space = true
			continue
		out.append(char(c))
		last_space = false
	var s: String = "".join(out).strip_edges()
	if s.length() > max_len:
		s = s.substr(0, max_len).strip_edges()
	return s


## Free text from the wire (descriptions, reasons, plug-in names): invisible chars stripped, spaces collapsed, capped.
## May be empty.
static func clean_text(raw: Variant, max_len: int = 120) -> String:
	if not (raw is String or raw is StringName):
		return ""
	return _clean_text(str(raw), max_len, true)


const RESERVED_NAMES: Array = ["server", "admin", "administrator", "moderator", "mod", "host", "system", "console",
	"novaswift", "staff", "gm", "operator", "sysop", "owner"]
const _LEET: Dictionary = {"0": "o", "1": "l", "3": "e", "4": "a", "5": "s", "7": "t", "8": "b", "$": "s", "@": "a",
	"!": "l", "|": "l", "\u0430": "a", "\u0435": "e", "\u043E": "o", "\u0440": "p", "\u0441": "c", "\u0445": "x",
	"\u0456": "i", "\u0455": "s", "\u04CF": "l", "\u0501": "d", "\u051B": "q", "\u0261": "g", "\u0131": "i"}


## Lowercase, look-alike digits/symbols mapped to letters, everything but a-z0-9 dropped: "Adm1n", "S3rv3r" -> "admin", "server".
static func normalize_name(s: String) -> String:
	var out: String = ""
	var low: String = s.to_lower()
	for i in mini(low.length(), 256):
		var ch: String = low.substr(i, 1)
		if _LEET.has(ch):
			ch = str(_LEET[ch])
		var c: int = ch.unicode_at(0) if ch != "" else 0
		if (c >= 97 and c <= 122) or (c >= 48 and c <= 57):
			out += ch
	return out


static func is_reserved_name(s: String) -> bool:
	if RESERVED_NAMES.has(normalize_name(s)) or RESERVED_NAMES.has(normalize_name(s.replace("1", "i").replace("!", "i").replace("|", "i"))):
		return true
	# "server2", "Admin007": the unmapped letters+digits with trailing digits removed.
	var plain: String = ""
	var low: String = s.to_lower()
	for i in mini(low.length(), 256):
		var c: int = low.unicode_at(i)
		if (c >= 97 and c <= 122) or (c >= 48 and c <= 57):
			plain += low.substr(i, 1)
	while plain != "" and plain.unicode_at(plain.length() - 1) >= 48 and plain.unicode_at(plain.length() - 1) <= 57:
		plain = plain.substr(0, plain.length() - 1)
	return plain == "server" or plain == "admin"


## A pilot name from the wire (HELLO / PEER_JOIN / WELCOME / chat sender): clean_name + no '[' / ']' + reserved and
## look-alike staff names ("Server", "Adm1n", ...) are replaced by `fallback`.
static func clean_player_name(raw: Variant, fallback: String = "Pilot") -> String:
	if not (raw is String or raw is StringName):
		return fallback
	var t: String = str(raw).replace("[", "").replace("]", "")
	var out: String = _clean_text(t, MAX_NAME, true)
	if out == "" or is_reserved_name(out):
		return fallback
	return out


## '[' -> '[lb]' so remote text can't open a BBCode tag in a RichTextLabel (']' stays as is).
static func escape_bbcode(s: String) -> String:
	return s.replace("[", "[lb]")


## A chat line from the wire or the keyboard: control/format characters removed (a normal space stays; other Unicode
## spaces become one), trimmed, at most MAX_CHAT characters. "" when nothing is left.
static func clean_chat(raw: Variant) -> String:
	if not (raw is String or raw is StringName):
		return ""
	return _clean_text(str(raw), MAX_CHAT, false)


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


## A canonical string for comparing two PluginManifest JSONs (key order and whitespace do not matter). Entries and
## field lengths are capped; a set of more than MAX_LIST plug-ins is compared through a hash of the whole sorted list.
static func manifest_signature(json_text: String) -> String:
	var t: String = json_text.strip_edges()
	if t == "" or t.length() > MAX_PKT_CONTROL:
		return ""
	var v: Variant = parse_json(t)
	if v is Dictionary and (v as Dictionary).get("plugins") is Array:
		# Only the GAMEPLAY plug-ins' id + content hash decide compatibility (cosmetic ones ride along, never compared).
		var rows: Array = []
		for p in ((v as Dictionary)["plugins"] as Array):
			if rows.size() >= 512:
				break
			if p is Dictionary:
				rows.append(clean_text((p as Dictionary).get("id", ""), 96) + "=" + clean_text((p as Dictionary).get("contentHash", ""), 128))
		rows.sort()
		var joined: String = "|".join(PackedStringArray(rows))
		return joined if rows.size() <= MAX_LIST else "big:" + joined.sha256_text()
	if v is Dictionary:
		return JSON.stringify(v, "", true)
	if v is Array:
		return JSON.stringify(v)
	return t


# --- framing ---------------------------------------------------------------------------------------

## Largest whole packet accepted for a kind (0 = unknown kind: ignore). `from_server` = the receiver is a client.
static func packet_limit(kind: int, from_server: bool = false) -> int:
	match kind:
		K_HELLO: return MAX_PKT_HELLO
		K_DATA: return MAX_PKT_DATA
		K_CHAT: return 2048 if from_server else MAX_PKT_SMALL
		K_PING, K_PONG, K_REPORT: return MAX_PKT_SMALL
		K_PEER_JOIN, K_PEER_LEFT, K_KICK: return 4096
		K_WELCOME, K_REJECT: return MAX_PKT_CONTROL
	return 0


## JSON text -> Variant, or null on any error. Unlike JSON.parse_string this never logs, so a stream of garbage
## packets can't flood the log.
static func parse_json(text: String) -> Variant:
	if text.contains("\\u0000"):
		return null   # an escaped NUL makes the engine log an error per packet
	var js: JSON = JSON.new()
	if js.parse(text) != OK:
		return null
	return js.data


## Bytes -> String without the engine's "Unicode parsing error" log lines: ASCII is decoded natively, anything with high
## bytes is validated as strict UTF-8 first ("" when invalid, so garbage can't flood the log).
static func safe_utf8(b: PackedByteArray) -> String:
	if b.size() > MAX_PKT_CONTROL or b.find(0) != -1:
		return ""
	if b.get_string_from_ascii().to_utf8_buffer().size() == b.size():
		return b.get_string_from_ascii()
	var i: int = 0
	var n: int = b.size()
	while i < n:
		var c: int = b[i]
		if c < 0x80:
			i += 1
			continue
		var need: int = 0
		var lo: int = 0x80
		var hi: int = 0xBF
		if c >= 0xC2 and c <= 0xDF:
			need = 1
		elif c >= 0xE0 and c <= 0xEF:
			need = 2
			if c == 0xE0:
				lo = 0xA0
			elif c == 0xED:
				hi = 0x9F
		elif c >= 0xF0 and c <= 0xF4:
			need = 3
			if c == 0xF0:
				lo = 0x90
			elif c == 0xF4:
				hi = 0x8F
		else:
			return ""
		if i + need >= n + 0 and i + need > n - 1:
			return ""
		var d: int = b[i + 1]
		if d < lo or d > hi:
			return ""
		for k in range(2, need + 1):
			var e: int = b[i + k]
			if e < 0x80 or e > 0xBF:
				return ""
		i += need + 1
	return b.get_string_from_utf8()


static func pack_control(kind: int, body: Dictionary) -> PackedByteArray:
	var b: PackedByteArray = PackedByteArray()
	b.append(kind)
	b.append_array(JSON.stringify(body).to_utf8_buffer())
	return b


## Control packet -> its JSON body, or {} when too short / too long for its kind / not a JSON object.
static func unpack_control(pkt: PackedByteArray) -> Dictionary:
	if pkt.size() < 2 or pkt.size() > MAX_PKT_CONTROL:
		return {}
	var lim: int = packet_limit(pkt[0], true)
	if lim == 0 or pkt.size() > lim:
		return {}
	var v: Variant = parse_json(safe_utf8(pkt.slice(1)))
	return v if v is Dictionary else {}


## Safe field readers for decoded JSON: wrong type -> default, numbers clamped, strings capped and cleaned.
static func num_int(v: Variant, lo: int, hi: int, dflt: int = 0) -> int:
	if v is int:
		return clampi(int(v), lo, hi)
	if v is float:
		var f: float = v
		if is_nan(f) or is_inf(f):
			return clampi(dflt, lo, hi)
		return int(clampf(f, float(lo), float(hi)))
	if v is bool:
		return clampi(1 if v else 0, lo, hi)
	return clampi(dflt, lo, hi)


static func num_float(v: Variant, lo: float, hi: float, dflt: float = 0.0) -> float:
	if v is int or v is float:
		var f: float = float(v)
		if is_nan(f) or is_inf(f):
			return clampf(dflt, lo, hi)
		return clampf(f, lo, hi)
	return clampf(dflt, lo, hi)


static func str_field(v: Variant, max_len: int) -> String:
	return clean_text(v, max_len)


static func pack_data(peer_id: int, payload: PackedByteArray) -> PackedByteArray:
	var b: PackedByteArray = PackedByteArray()
	b.resize(5)
	b[0] = K_DATA
	b.encode_s32(1, peer_id)
	b.append_array(payload)
	return b


## -> {id, data} or {} when too short / too long.
static func unpack_data(pkt: PackedByteArray) -> Dictionary:
	if pkt.size() < 5 or pkt.size() > MAX_PKT_DATA or pkt[0] != K_DATA:
		return {}
	return {"id": pkt.decode_s32(1), "data": pkt.slice(5)}


# --- LAN beacon --------------------------------------------------------------------------------------

## {name, players, max, ver, pw, port, rules, dedicated} -> "NSB1" + JSON. `with_cert` adds the DTLS certificate and
## (unless `with_list` is false) the plug-in list + add-ons: those only go in unicast status replies.
static func encode_beacon(info: Dictionary, with_cert: bool = false, with_list: bool = true) -> PackedByteArray:
	var d: Dictionary = {
		"name": clean_name(str(info.get("name", "NovaSwift")), "NovaSwift", MAX_SERVER_NAME),
		"players": int(info.get("players", 0)),
		"max": int(info.get("max", 0)),
		"ver": str(info.get("ver", game_version())),
		"pw": bool(info.get("pw", false)),
		"port": int(info.get("port", DEFAULT_PORT)),
		"rules": str(info.get("rules", "")),
		"dedicated": bool(info.get("dedicated", false)),
		"proto": PROTO,
	}
	if bool(info.get("truncated", false)):
		d["truncated"] = true   # the plug-in list was left out to fit the reply cap
	if bool(info.get("dtls", false)):
		d["dtls"] = true
		d["fp"] = str(info.get("fp", ""))
		if with_cert:   # only in unicast status replies (a certificate is too big for the LAN broadcast)
			d["cert"] = str(info.get("cert", ""))
	# Plug-in requirements (net/NetPlugins.gd plugin_wire): signature + count + total conversion always, the list
	# only in unicast status replies (with_cert), where the size limit is looser than a LAN broadcast's.
	var pw: Variant = info.get("plugin_wire")
	if pw is Dictionary:
		d["sig"] = str((pw as Dictionary).get("sig", ""))
		d["pcount"] = int((pw as Dictionary).get("count", 0))
		d["tc"] = str((pw as Dictionary).get("tc", ""))
		if with_cert and with_list:
			d["plugins"] = (pw as Dictionary).get("plugins", [])
			d["addons"] = (pw as Dictionary).get("addons", [])
	var b: PackedByteArray = BEACON_MAGIC.to_utf8_buffer()
	b.append_array(JSON.stringify(d).to_utf8_buffer())
	return b


## A status reply that fits `cap` bytes: the full NSB1 JSON, else without the plug-in list (sig, pcount, tc only),
## else also without the DTLS certificate. Empty only when even the smallest form does not fit.
static func encode_status_reply(info: Dictionary, cap: int) -> PackedByteArray:
	var full: PackedByteArray = encode_beacon(info, true, true)
	if full.size() <= cap:
		return full
	var trimmed: Dictionary = info.duplicate()
	trimmed["truncated"] = true
	var compact: PackedByteArray = encode_beacon(trimmed, true, false)
	if compact.size() <= cap:
		return compact
	var tiny: PackedByteArray = encode_beacon(trimmed, false, false)
	return tiny if tiny.size() <= cap else PackedByteArray()


## Back to the info dictionary, or {} when it is not a beacon / is malformed. Every field is type-checked and clamped.
static func decode_beacon(pkt: PackedByteArray) -> Dictionary:
	if pkt.size() < 6 or pkt.size() > 6144:
		return {}
	if pkt[0] != 0x4E or pkt[1] != 0x53 or pkt[2] != 0x42 or pkt[3] != 0x31:
		return {}
	var v: Variant = parse_json(safe_utf8(pkt.slice(4)))
	if not (v is Dictionary):
		return {}
	var d: Dictionary = v
	var port: int = num_int(d.get("port", 0), 0, 65535, 0)
	if port < 1:
		return {}
	var plugins: Array = []
	var raw_plugins: Variant = d.get("plugins", [])
	if raw_plugins is Array:
		for p in (raw_plugins as Array):
			if plugins.size() >= MAX_LIST:
				break
			if p is Dictionary:
				var pd: Dictionary = p
				var pid: String = str_field(pd.get("id", ""), 64)
				plugins.append({"id": pid, "name": str_field(pd.get("name", pid), 64), "hash": str_field(pd.get("hash", pd.get("contentHash", "")), 64)})
	var addons: Array = []
	var raw_addons: Variant = d.get("addons", [])
	if raw_addons is Array:
		for a in (raw_addons as Array):
			if addons.size() >= MAX_LIST:
				break
			if a is String or a is StringName:
				addons.append(str_field(a, 64))
	var cert: String = ""
	var raw_cert: Variant = d.get("cert", "")
	if raw_cert is String and (raw_cert as String).length() <= 4096:
		cert = raw_cert
	return {"name": clean_name(str_field(d.get("name", ""), MAX_SERVER_NAME), "Server", MAX_SERVER_NAME),
		"players": num_int(d.get("players", 0), 0, 4096), "max": num_int(d.get("max", 0), 0, 4096),
		"ver": str_field(d.get("ver", ""), 32), "pw": d.get("pw", false) == true,
		"port": port, "rules": str_field(d.get("rules", ""), 16), "dedicated": d.get("dedicated", false) == true,
		"proto": num_int(d.get("proto", PROTO), 0, 65535, PROTO),
		"dtls": d.get("dtls", false) == true, "fp": str_field(d.get("fp", ""), 128), "cert": cert,
		"sig": str_field(d.get("sig", ""), 2048), "pcount": num_int(d.get("pcount", -1), -1, 4096, -1) if d.has("pcount") else -1,
		"tc": str_field(d.get("tc", ""), 64), "plugins": plugins, "addons": addons}


# --- NSQ1 status query (anti-amplification) -----------------------------------------------------------
#
# Request v2: "NSQ1" + 0x02 + 3 random bytes + zero padding, exactly QUERY_V2_SIZE (1200) bytes: a spoofed-source
# request therefore costs the attacker as much bandwidth as the reply costs the victim. Responders:
#   * ignore anything shorter than QUERY_MIN (512) bytes or longer than QUERY_MAX (1500), except the legacy bare
#     4-byte "NSQ1", which only gets the compact beacon (no plug-in list / cert), at most 1 per source IP per 5 s and
#     QUERY_LEGACY_PER_SEC (20) per second globally;
#   * never send more than min(request length, QUERY_REPLY_MAX = 1200) bytes (encode_status_reply);
#   * apply a per-source-IP token bucket (burst 5, 2/s refill; at most 4096 tracked IPs) -> QueryGuard.

const QUERY_V2_SIZE := 1200
const QUERY_MIN := 512
const QUERY_MAX := 1500
const QUERY_REPLY_MAX := 1200
const QUERY_LEGACY_PER_SEC := 20
const QUERY_LEGACY_IP_GAP := 5.0
const QUERY_BURST := 5.0
const QUERY_REFILL := 2.0
const QUERY_MAX_IPS := 4096
## admit() verdicts
const Q_DROP := 0
const Q_LEGACY := 1
const Q_V2 := 2
## Godot-only extension (version byte 3, QUERY_CERT_SIZE bytes): asks an encrypted server for its DTLS certificate, which
## does not fit the 1200-byte reply budget next to the status fields. Other implementations just drop it.
const Q_CERT := 3
const QUERY_CERT_SIZE := 1300


## The 1200-byte v2 request every client sends.
static func build_query() -> PackedByteArray:
	var b: PackedByteArray = PackedByteArray()
	b.resize(QUERY_V2_SIZE)
	b.fill(0)
	b[0] = 0x4E   # N
	b[1] = 0x53   # S
	b[2] = 0x51   # Q
	b[3] = 0x31   # 1
	b[4] = 0x02
	b[5] = randi() & 0xFF
	b[6] = randi() & 0xFF
	b[7] = randi() & 0xFF
	return b


## 0 = not a query we answer, 1 = legacy bare "NSQ1", 2 = valid v2 (512..1500 bytes, version byte 2).
static func query_kind(pkt: PackedByteArray) -> int:
	var n: int = pkt.size()
	if n == 4:
		return Q_LEGACY if (pkt[0] == 0x4E and pkt[1] == 0x53 and pkt[2] == 0x51 and pkt[3] == 0x31) else Q_DROP
	if n < QUERY_MIN or n > QUERY_MAX:
		return Q_DROP
	if pkt[0] != 0x4E or pkt[1] != 0x53 or pkt[2] != 0x51 or pkt[3] != 0x31:
		return Q_DROP
	if pkt[4] == 0x01 or pkt[4] == 0x02:   # 0x01 is what the status prober on GitHub's runners sends
		return Q_V2
	return Q_CERT if pkt[4] == 0x03 else Q_DROP


## The DTLS-certificate request (see Q_CERT).
static func build_cert_query() -> PackedByteArray:
	var b: PackedByteArray = build_query()
	b.resize(QUERY_CERT_SIZE)
	b[4] = 0x03
	return b


## NSB1 reply carrying only what a client needs to pin the key: {name, port, proto, dtls, fp, cert}.
static func encode_cert_reply(info: Dictionary, cap: int) -> PackedByteArray:
	if not bool(info.get("dtls", false)):
		return PackedByteArray()
	var d: Dictionary = {"name": clean_name(str(info.get("name", "NovaSwift")), "NovaSwift", MAX_SERVER_NAME), "port": int(info.get("port", DEFAULT_PORT)),
		"proto": PROTO, "dtls": true, "fp": str(info.get("fp", "")), "cert": str(info.get("cert", ""))}
	var b: PackedByteArray = BEACON_MAGIC.to_utf8_buffer()
	b.append_array(JSON.stringify(d).to_utf8_buffer())
	return b if b.size() <= cap else PackedByteArray()


## The only answer a bare 4-byte "NSQ1" gets now: "update your client".
static func legacy_reply() -> PackedByteArray:
	return (BEACON_MAGIC + "{\"proto\":" + str(PROTO) + ",\"upgrade\":true}").to_utf8_buffer()


## Largest reply (bytes) allowed for a request of this length.
static func query_reply_cap(request_len: int) -> int:
	return mini(request_len, QUERY_REPLY_MAX)


static func is_query(pkt: PackedByteArray) -> bool:
	return query_kind(pkt) != Q_DROP


## Kept for old call sites: now the v2 request.
static func query_packet() -> PackedByteArray:
	return build_query()


## Per-source rate limiting for NSQ1 responders. `admit(ip, pkt, now)` -> Q_DROP / Q_LEGACY / Q_V2.
class QueryGuard extends RefCounted:
	var buckets: Dictionary = {}       # ip -> [tokens, last_time]
	var legacy_last: Dictionary = {}   # ip -> last legacy answer time
	var _legacy_sec: int = -1
	var _legacy_n: int = 0
	var _pruned_at: float = -100.0
	var _lpruned_at: float = -100.0

	## Same rule as NetProto.query_kind (an inner class can't call the outer script's statics).
	static func _kind(pkt: PackedByteArray) -> int:
		var n: int = pkt.size()
		if n == 4:
			return 1 if (pkt[0] == 0x4E and pkt[1] == 0x53 and pkt[2] == 0x51 and pkt[3] == 0x31) else 0
		if n < 512 or n > 1500:
			return 0
		if pkt[0] != 0x4E or pkt[1] != 0x53 or pkt[2] != 0x51 or pkt[3] != 0x31:
			return 0
		if pkt[4] == 1:
			return 2
		return pkt[4] if (pkt[4] == 2 or pkt[4] == 3) else 0

	func admit(ip: String, pkt: PackedByteArray, now: float) -> int:
		var kind: int = _kind(pkt)
		if kind == 0 or ip == "":
			return 0
		if not _take_token(ip, now):
			return 0
		if kind >= 2:
			return kind
		# legacy: 1 per IP per 5 s, 20/s globally
		if legacy_last.has(ip) and now - float(legacy_last[ip]) < 5.0:
			return 0
		var sec: int = int(floor(now))
		if sec != _legacy_sec:
			_legacy_sec = sec
			_legacy_n = 0
		if _legacy_n >= 20:
			return 0
		if legacy_last.size() >= 4096:
			_prune_legacy(now)
			if legacy_last.size() >= 4096:
				return 0
		_legacy_n += 1
		legacy_last[ip] = now
		return 1

	func _take_token(ip: String, now: float) -> bool:
		var b: Variant = buckets.get(ip)
		if b == null:
			if buckets.size() >= 4096:
				_prune(now)
				if buckets.size() >= 4096:
					return false   # table full of live sources: refuse new ones rather than evict
			buckets[ip] = [4.0, now]   # burst 5, this request takes one
			return true
		var row: Array = b
		var tokens: float = minf(5.0, float(row[0]) + maxf(0.0, now - float(row[1])) * 2.0)
		row[1] = now
		if tokens < 1.0:
			row[0] = tokens
			return false
		row[0] = tokens - 1.0
		return true

	## Drop buckets that have fully refilled (idle >= 2.5 s): they are equivalent to absent. At most twice a second.
	func _prune(now: float) -> void:
		if now - _pruned_at < 0.5 and now >= _pruned_at:
			return
		_pruned_at = now
		for k in buckets.keys():
			if now - float((buckets[k] as Array)[1]) >= 2.5 or now < float((buckets[k] as Array)[1]):
				buckets.erase(k)

	func _prune_legacy(now: float) -> void:
		if now - _lpruned_at < 0.5 and now >= _lpruned_at:
			return
		_lpruned_at = now
		for k in legacy_last.keys():
			if now - float(legacy_last[k]) >= 5.0 or now < float(legacy_last[k]):
				legacy_last.erase(k)
