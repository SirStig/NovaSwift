# NOVA Swift -- the public server directory (servers/servers.json in the SirStig/NovaSwift-Plugins repo).
#
# No backend of ours: the list is a JSON file in a GitHub repo (people add their server with a pull request).
# This node downloads it over HTTPS only, caches it in user://server_directory.json with its ETag and refreshes
# at most every 24 h (an If-None-Match request answered 304 just renews the timestamp; offline falls back to the
# cache). The directory is only a list of addresses: online/players/version/ping always come from a live UDP
# status query (LanDiscovery.query), never from the file.
#
# Static helpers (parse, sort, filter, entry building) are pure and unit-tested by tests/net_ui_selfcheck.gd.
extends Node

const Proto = preload("res://net/NetProto.gd")

const URL := "https://raw.githubusercontent.com/SirStig/NovaSwift-Plugins/main/servers/servers.json"
const CACHE_PATH := "user://server_directory.json"
const MAX_AGE_SEC := 24 * 3600
const MAX_BYTES := 512 * 1024
const MAX_ENTRIES := 500
const REGIONS := ["na-east", "na-west", "sa", "eu", "af", "me", "as", "oc", "global"]
const PR_URL := "https://github.com/SirStig/NovaSwift-Plugins/blob/main/servers/README.md"

signal updated

var entries: Array = []        # sanitized entries (see parse)
var status: String = ""        # "", "loading", "ok", "cached", "offline", "error"
var message: String = ""
var fetched_at: int = 0        # unix time of the last successful fetch / revalidation
var url: String = URL

var _http: HTTPRequest = null
var _etag: String = ""


func _ready() -> void:
	_load_cache()


## Load from cache, and fetch when stale (or `force`). Safe to call repeatedly.
func refresh(force: bool = false) -> void:
	if entries.is_empty() and _etag == "":
		_load_cache()
	if status == "loading":
		return
	var age: int = int(Time.get_unix_time_from_system()) - fetched_at
	if not force and fetched_at > 0 and age < MAX_AGE_SEC and not entries.is_empty():
		status = "cached"
		updated.emit()
		return
	if not url.begins_with("https://"):
		status = "error"
		message = "The directory address must be https."
		updated.emit()
		return
	if _http == null:
		_http = HTTPRequest.new()
		_http.timeout = 12.0
		_http.body_size_limit = MAX_BYTES
		_http.request_completed.connect(_on_done)
		add_child(_http)
	var headers: PackedStringArray = PackedStringArray(["User-Agent: NovaSwift", "Accept: application/json"])
	if _etag != "" and not entries.is_empty():
		headers.append("If-None-Match: " + _etag)
	status = "loading"
	message = ""
	var err: int = _http.request(url, headers)
	if err != OK:
		_fail("Couldn't start the download (%s)." % error_string(err))
	updated.emit()


func _on_done(result: int, code: int, headers: PackedStringArray, body: PackedByteArray) -> void:
	if result != HTTPRequest.RESULT_SUCCESS:
		_fail("Couldn't reach the server directory.")
		return
	if code == 304:
		fetched_at = int(Time.get_unix_time_from_system())
		_save_cache(_cached_body())
		status = "ok"
		updated.emit()
		return
	if code != 200:
		_fail("The server directory answered HTTP %d." % code)
		return
	var text: String = body.get_string_from_utf8()
	var parsed: Dictionary = parse(text)
	if not bool(parsed["ok"]):
		_fail("The server directory is malformed: " + str(parsed["error"]))
		return
	entries = parsed["entries"]
	_etag = ""
	for h in headers:
		if h.to_lower().begins_with("etag:"):
			_etag = h.substr(5).strip_edges()
	fetched_at = int(Time.get_unix_time_from_system())
	_save_cache(text)
	status = "ok"
	message = ""
	updated.emit()


func _fail(msg: String) -> void:
	status = "offline" if not entries.is_empty() else "error"
	message = msg + (" Showing the saved copy." if not entries.is_empty() else "")
	updated.emit()


func _cached_body() -> String:
	var f: FileAccess = FileAccess.open(CACHE_PATH, FileAccess.READ)
	if f == null:
		return ""
	var v: Variant = JSON.parse_string(f.get_as_text())
	return str((v as Dictionary).get("body", "")) if v is Dictionary else ""


func _load_cache() -> void:
	var f: FileAccess = FileAccess.open(CACHE_PATH, FileAccess.READ)
	if f == null:
		return
	var v: Variant = JSON.parse_string(f.get_as_text())
	if not (v is Dictionary):
		return
	var d: Dictionary = v
	var parsed: Dictionary = parse(str(d.get("body", "")))
	if bool(parsed["ok"]):
		entries = parsed["entries"]
		_etag = str(d.get("etag", ""))
		fetched_at = int(d.get("fetched_at", 0))


func _save_cache(body: String) -> void:
	var f: FileAccess = FileAccess.open(CACHE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"etag": _etag, "fetched_at": fetched_at, "body": body}))


# --- pure helpers ------------------------------------------------------------------------------------------------

## servers.json text -> {ok, error, entries:[{id,name,host,port,region,description,owner,contact,rules,plugins,max,added,website}]}.
## Entries that fail basic checks are skipped; a wrong top-level shape fails the whole file.
static func parse(text: String) -> Dictionary:
	var js: JSON = JSON.new()
	var v: Variant = js.data if js.parse(text) == OK else null
	if not (v is Dictionary) or not ((v as Dictionary).get("servers") is Array):
		return {"ok": false, "error": "not a server list", "entries": []}
	var out: Array = []
	var seen: Dictionary = {}
	for item in (v as Dictionary)["servers"]:
		if not (item is Dictionary) or out.size() >= MAX_ENTRIES:
			continue
		var d: Dictionary = item
		var host: String = str(d.get("host", "")).strip_edges()
		var port: int = int(d.get("port", Proto.DEFAULT_PORT))
		if host == "" or host.contains(" ") or port < 1 or port > 65535:
			continue
		var key: String = "%s:%d" % [host.to_lower(), port]
		if seen.has(key):
			continue
		seen[key] = true
		var owner: Dictionary = d.get("owner", {}) if d.get("owner", {}) is Dictionary else {}
		var site: String = str(d.get("website", ""))
		var plugins: Array = []
		var raw_plugins: Variant = d.get("plugins", [])
		if raw_plugins is Array:
			for p in (raw_plugins as Array):
				if p is Dictionary:
					plugins.append({"id": str((p as Dictionary).get("id", "")), "name": str((p as Dictionary).get("name", (p as Dictionary).get("id", ""))),
						"contentHash": str((p as Dictionary).get("contentHash", ""))})
		out.append({"id": str(d.get("id", key)), "name": Proto.clean_name(str(d.get("name", host)), host), "host": host, "port": port,
			"region": str(d.get("region", "global")), "description": str(d.get("description", "")).substr(0, 300),
			"owner": str(owner.get("name", "")), "contact": str(owner.get("contact", "")), "rules": str(d.get("rules", "")),
			"plugins": plugins, "tc": str(d.get("totalConversion", "")), "max": int(d.get("maxPlayers", 0)), "added": str(d.get("added", "")),
			"website": site if site.begins_with("https://") else ""})
	return {"ok": true, "error": "", "entries": out}


## One display row = directory entry + live status. `live` is the LanDiscovery.pings[...] record ({} = no data).
## state: "checking" (no answer yet), "online", "offline".
static func row_for(entry: Dictionary, live: Dictionary, checking: bool) -> Dictionary:
	var row: Dictionary = entry.duplicate()
	var info: Dictionary = live.get("info", {}) if live.get("info", {}) is Dictionary else {}
	var ok: bool = bool(live.get("ok", false))
	row["state"] = "online" if ok else ("checking" if checking else "offline")
	row["ping"] = int(live.get("rtt_ms", -1)) if ok else -1
	row["players"] = int(info.get("players", 0)) if ok else 0
	row["live_max"] = int(info.get("max", entry.get("max", 0))) if ok else int(entry.get("max", 0))
	row["ver"] = str(info.get("ver", "")) if ok else ""
	row["pw"] = bool(info.get("pw", false)) if ok else false
	row["dedicated"] = bool(info.get("dedicated", false)) if ok else false
	row["compatible"] = ok and int(info.get("proto", Proto.PROTO)) == Proto.PROTO
	row["dtls"] = ok and bool(info.get("dtls", false))
	if ok:   # what the server says it runs now beats the (possibly stale) directory entry
		row["sig"] = str(info.get("sig", ""))
		var live_plugins: Variant = info.get("plugins", [])
		if live_plugins is Array and not (live_plugins as Array).is_empty():
			row["plugins"] = live_plugins
			row["tc"] = str(info.get("tc", ""))
	return row


## filters: {compatible: bool, has_players: bool, region: String ("" = any)}. Offline rows are kept unless a
## live-data filter is on.
static func filter_rows(rows: Array, filters: Dictionary) -> Array:
	var out: Array = []
	var region: String = str(filters.get("region", ""))
	for r in rows:
		var row: Dictionary = r
		if region != "" and str(row.get("region", "")) != region:
			continue
		if bool(filters.get("compatible", false)) and not bool(row.get("compatible", false)):
			continue
		if bool(filters.get("has_players", false)) and int(row.get("players", 0)) < 1:
			continue
		out.append(row)
	return out


## Online first by ping (lowest first), then checking, then offline; ties by name.
static func sort_rows(rows: Array) -> Array:
	var rank: Dictionary = {"online": 0, "checking": 1, "offline": 2}
	var out: Array = rows.duplicate()
	out.sort_custom(func(a: Dictionary, b: Dictionary) -> bool:
		var ra: int = int(rank.get(str(a.get("state", "offline")), 2))
		var rb: int = int(rank.get(str(b.get("state", "offline")), 2))
		if ra != rb:
			return ra < rb
		if ra == 0 and int(a["ping"]) != int(b["ping"]):
			return int(a["ping"]) < int(b["ping"])
		return str(a.get("name", "")).naturalnocasecmp_to(str(b.get("name", ""))) < 0)
	return out


## The servers.json entry a dedicated server prints for --public. `plugins` = net_ready_manifest()["plugins"].
static func build_entry(opts: Dictionary, host: String, plugins: Array, today: String, tc: String = "", addons: Array = []) -> Dictionary:
	var nm: String = str(opts.get("name", "NovaSwift Server"))
	var slug: String = ""
	for i in nm.to_lower().length():
		var c: String = nm.to_lower().substr(i, 1)
		slug += c if (c >= "a" and c <= "z") or (c >= "0" and c <= "9") else "-"
	while slug.contains("--"):
		slug = slug.replace("--", "-")
	slug = slug.strip_edges().trim_prefix("-").trim_suffix("-")
	var region: String = str(opts.get("region", "global"))
	var plist: Array = []
	for p in plugins:
		if p is Dictionary:
			plist.append({"id": str((p as Dictionary).get("id", "")), "name": str((p as Dictionary).get("name", "")),
				"contentHash": str((p as Dictionary).get("contentHash", ""))})
	var e: Dictionary = {"id": slug if slug != "" else "my-server", "name": nm, "host": host if host != "" else "YOUR.PUBLIC.IP.OR.HOSTNAME",
		"port": int(opts.get("port", Proto.DEFAULT_PORT)), "region": region if REGIONS.has(region) else "global",
		"description": str(opts.get("description", "")) if str(opts.get("description", "")) != "" else "A NovaSwift dedicated server.",
		"owner": {"name": str(opts.get("owner", "")) if str(opts.get("owner", "")) != "" else "YOUR NAME", "contact": str(opts.get("contact", ""))},
		"rules": str(opts.get("rules", "safe")), "plugins": plist, "maxPlayers": int(opts.get("max_players", 8)), "added": today}
	if str(opts.get("website", "")).begins_with("https://"):
		e["website"] = str(opts["website"])
	# Load order is the order of "plugins". The total conversion and its add-ons are extra, optional fields.
	if tc != "":
		e["totalConversion"] = tc
	if not addons.is_empty():
		e["tcAddons"] = addons
	return e
