# NOVA Swift -- multiplayer plug-in awareness: what a server requires, how it compares with this install, and the
# wire form that goes into the LAN beacon / NSQ1 status reply / --public directory entry.
#
# Wire form (`plugin_wire`): {sig, count, tc, addons[], plugins:[{id, name, hash}]} with `hash` = the first 16 hex of the
# content hash (the full hash is only in the directory entry and the handshake manifest). The beacon carries only
# {sig, count, tc}; the unicast status reply carries the whole list (it fits one datagram for ~40 plug-ins).
#
# Comparison is by plug-in id + content hash, the same rule the handshake gate uses (PluginManifest), so a row that
# shows a check here is a row the server will accept.
#
# Loaded with preload() (no class_name), like Controls.gd.
extends RefCounted

const Proto = preload("res://net/NetProto.gd")

const HASH_LEN := 16
const MAX_WIRE_PLUGINS := 40

static var _cache: Dictionary = {}
static var _cache_at: int = 0


## This install's plug-in set (bridge net_plugin_info), cached for a few seconds: {plugins:[{id,name,contentHash,tc}],
## tc, addons, sig, count}. Empty plugins when the bridge predates the call.
static func local_info(nova: Object, fresh: bool = false) -> Dictionary:
	var now: int = Time.get_ticks_msec()
	if not fresh and not _cache.is_empty() and now - _cache_at < 8000:
		return _cache
	var out: Dictionary = {"plugins": [], "tc": "", "addons": [], "sig": "", "count": 0}
	if nova != null and nova.has_method("net_plugin_info"):
		var v: Variant = JSON.parse_string(str(nova.net_plugin_info()))
		if v is Dictionary:
			out = v
	_cache = out
	_cache_at = now
	return out


static func invalidate() -> void:
	_cache = {}


## The compact form for beacons / status replies. `full` adds the plug-in list.
static func plugin_wire(info: Dictionary, full: bool) -> Dictionary:
	var w: Dictionary = {"sig": str(info.get("sig", "")), "count": int(info.get("count", 0)), "tc": str(info.get("tc", ""))}
	if full:
		var list: Array = []
		for p in (info.get("plugins", []) as Array):
			if list.size() >= MAX_WIRE_PLUGINS:
				break
			var d: Dictionary = p
			list.append({"id": str(d.get("id", "")), "name": str(d.get("name", "")), "hash": short_hash(str(d.get("contentHash", d.get("hash", ""))))})
		w["plugins"] = list
		w["addons"] = info.get("addons", [])
	return w


static func short_hash(h: String) -> String:
	return h.substr(0, HASH_LEN)


static func _same_hash(a: String, b: String) -> bool:
	if a == "" or b == "":
		return true   # an unknown hash (older server / hand-written directory entry) can only be matched by id
	var n: int = mini(mini(a.length(), b.length()), HASH_LEN)
	return a.substr(0, n) == b.substr(0, n)


## Compare the server's required plug-ins (each {id, name, hash|contentHash}) and total conversion with this install.
## -> {rows:[{id,name,state:"ok"|"wrong"|"missing"}], extra:[{id,name}], tc_server, tc_local, tc_mismatch, ok}
static func compare(required: Array, server_tc: String, local: Dictionary) -> Dictionary:
	var mine: Dictionary = {}
	for p in (local.get("plugins", []) as Array):
		mine[str((p as Dictionary).get("id", ""))] = p
	var rows: Array = []
	var want: Dictionary = {}
	for r in required:
		var d: Dictionary = r
		var id: String = str(d.get("id", ""))
		want[id] = true
		var state: String = "missing"
		if mine.has(id):
			var lh: String = str((mine[id] as Dictionary).get("contentHash", ""))
			state = "ok" if _same_hash(lh, str(d.get("hash", d.get("contentHash", "")))) else "wrong"
		rows.append({"id": id, "name": str(d.get("name", id)), "state": state})
	var extra: Array = []
	for id in mine:
		if not want.has(id):
			extra.append({"id": id, "name": str((mine[id] as Dictionary).get("name", id))})
	var tc_local: String = str(local.get("tc", ""))
	var tc_mismatch: bool = server_tc != tc_local
	var ok: bool = extra.is_empty() and not tc_mismatch
	for r in rows:
		if str((r as Dictionary)["state"]) != "ok":
			ok = false
	return {"rows": rows, "extra": extra, "tc_server": server_tc, "tc_local": tc_local, "tc_mismatch": tc_mismatch, "ok": ok}


## Server's plug-in list from a handshake manifest JSON ({plugins:[{id,name,contentHash}]}).
static func required_from_manifest(manifest_json: String) -> Array:
	if manifest_json.length() > 65536:
		return []
	var v: Variant = Proto.parse_json(manifest_json)
	var out: Array = []
	if v is Dictionary and (v as Dictionary).get("plugins") is Array:
		for p in ((v as Dictionary)["plugins"] as Array):
			if out.size() >= 64:
				break
			if p is Dictionary:
				var d: Dictionary = (p as Dictionary).duplicate()
				d["id"] = Proto.str_field(d.get("id", ""), 96)
				d["name"] = Proto.str_field(d.get("name", d["id"]), 64)
				d["contentHash"] = Proto.str_field(d.get("contentHash", ""), 128)
				out.append(d)
	return out


# --- the player's own set, restored after a session --------------------------------------------------------

const NetPrefs = preload("res://net/NetPrefs.gd")


## The Shell (has load_data_async) among `from`'s ancestors or, failing that, the tree's first matching node.
static func find_shell(from: Node) -> Node:
	var n: Node = from
	while n != null:
		if n.has_method("load_data_async"):
			return n
		n = n.get_parent()
	var root: Node = from.get_tree().root
	var stack: Array = root.get_children()
	var depth_guard: int = 0
	while not stack.is_empty() and depth_guard < 400:
		depth_guard += 1
		var c: Node = stack.pop_back()
		if c.has_method("load_data_async"):
			return c
		if c.get_child_count() < 40:
			stack.append_array(c.get_children())
	return null


## True when no pilot is flying (the data objects may be replaced): the Shell is on a menu screen.
static func at_main_menu(shell: Node) -> bool:
	return shell != null and shell.has_method("in_menu") and bool(shell.in_menu()) and shell.get("pause_menu") == null


## Remember the player's own plug-in set ONCE (the first change of a session wins; later joins don't overwrite it).
static func remember_own_set(pl: Object) -> void:
	if not NetPrefs.plugin_restore().is_empty():
		return
	var enabled: Dictionary = {}
	var v: Variant = JSON.parse_string(str(pl.list()))
	if v is Array:
		for p in v:
			enabled[str((p as Dictionary).get("id", ""))] = bool((p as Dictionary).get("enabled", false))
	NetPrefs.set_plugin_restore({"enabled": enabled, "manual": bool(pl.manual_order())})
