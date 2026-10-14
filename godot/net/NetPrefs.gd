# NOVA Swift -- multiplayer preferences in user://settings.cfg, section [net] (no Prefs.DEFAULTS entry needed:
# every getter here supplies its own default).
#
#   name        display name for hosting / joining ("" = the OS user name)
#   saved       favourites: [{name, host, port, pw}]  (Minecraft-style server list)
#   recent      last joined addresses, newest first, at most 8: [{host, port}]
#   host        the Host Game form: {name, max, rules, password, lan, port, pvp, ...}
#
# Loaded with preload() (no class_name), like Controls.gd.
extends RefCounted

const Prefs = preload("res://Prefs.gd")
const Proto = preload("res://net/NetProto.gd")

const SECTION := "net"
const MAX_RECENT := 8
const MAX_SAVED := 64


## The stored value, or null when never saved (Prefs.get_value logs an error for keys without a DEFAULTS entry).
static func _stored(key: String) -> Variant:
	Prefs.get_value("audio", "master")   # makes sure the file is loaded
	if not Prefs._cfg.has_section_key(SECTION, key):
		return null
	return Prefs._cfg.get_value(SECTION, key)


static func _get_array(key: String) -> Array:
	var v: Variant = _stored(key)
	return (v as Array).duplicate(true) if v is Array else []


static func display_name() -> String:
	var v: Variant = _stored("name")
	var n: String = str(v) if v != null else ""
	if n.strip_edges() == "":
		for env in ["USER", "USERNAME", "LOGNAME"]:
			n = OS.get_environment(env)
			if n != "":
				break
	return Proto.clean_name(n, "Pilot")


static func set_display_name(n: String) -> void:
	Prefs.set_value(SECTION, "name", Proto.clean_name(n, ""))
	Prefs.save()


static func saved() -> Array:
	return _get_array("saved")


## Add or update a favourite (matched by host + port). Returns the list.
static func save_server(nm: String, host: String, port: int, pw: String = "") -> Array:
	var list: Array = saved()
	var entry: Dictionary = {"name": Proto.clean_name(nm, host), "host": host, "port": port, "pw": pw}
	var found: bool = false
	for i in list.size():
		var e: Dictionary = list[i]
		if str(e.get("host", "")) == host and int(e.get("port", 0)) == port:
			list[i] = entry
			found = true
	if not found and list.size() < MAX_SAVED:
		list.append(entry)
	Prefs.set_value(SECTION, "saved", list)
	Prefs.save()
	return list


static func remove_saved(host: String, port: int) -> Array:
	var list: Array = saved().filter(func(e: Variant) -> bool:
		return not (str((e as Dictionary).get("host", "")) == host and int((e as Dictionary).get("port", 0)) == port))
	Prefs.set_value(SECTION, "saved", list)
	Prefs.save()
	return list


static func is_saved(host: String, port: int) -> bool:
	for e in saved():
		if str((e as Dictionary).get("host", "")) == host and int((e as Dictionary).get("port", 0)) == port:
			return true
	return false


static func recent() -> Array:
	return _get_array("recent")


static func add_recent(host: String, port: int) -> Array:
	var list: Array = []
	for e in recent():
		if not (str((e as Dictionary).get("host", "")) == host and int((e as Dictionary).get("port", 0)) == port):
			list.append(e)
	list.push_front({"host": host, "port": port})
	list = list.slice(0, MAX_RECENT)
	Prefs.set_value(SECTION, "recent", list)
	Prefs.save()
	return list


static func clear_recent() -> void:
	Prefs.set_value(SECTION, "recent", [])
	Prefs.save()


## The Host Game form's remembered values over sensible defaults.
static func host_form() -> Dictionary:
	var d: Dictionary = {"name": "", "max": 4, "preset": "safe", "password": "", "lan": true, "port": Proto.DEFAULT_PORT,
		"allow_pvp": true, "pvp_damage_real": false, "friendly_fire": false, "death_real": false, "allow_trade": true}
	var v: Variant = _stored("host")
	if v is Dictionary:
		for k in (v as Dictionary):
			d[k] = (v as Dictionary)[k]
	return d


static func save_host_form(form: Dictionary) -> void:
	var keep: Dictionary = form.duplicate()
	keep["password"] = ""   # never written to disk
	Prefs.set_value(SECTION, "host", keep)
	Prefs.save()
