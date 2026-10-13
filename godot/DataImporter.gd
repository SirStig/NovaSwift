# NOVA Swift — game-data importer glue (GDScript side of the Data Setup wizard).
#
# The copy / inspect / validate work is Swift (NovaSwiftPluginStore.GameDataImport, driven through the
# bridge's data_import_* methods, see bridge DataImport.swift); this file is the parts that are
# frontend-shaped: which platform the guide should talk to, where to look for likely installs and
# shortcut folders (Home, Downloads, SD card ...), and a time-sliced scanner that finds EV Nova installs
# without hitching a frame. Loaded with preload() (no class_name).
extends RefCounted

const Prefs = preload("res://Prefs.gd")

const EVSTUFF_URL := "https://andrews05.github.io/evstuff/"

## Folder names never descended into by the scanner.
const SKIP_DIRS := ["node_modules", "proc", "sys", "dev", "windows", "system volume information", "$recycle.bin",
	"appdata", "library", "snap", "flatpak", "steamapps", ".git", "__macosx"]


## "windows" | "mac" | "steamdeck" | "linux" -- what the platform guide opens on.
static func platform() -> String:
	match OS.get_name():
		"Windows":
			return "windows"
		"macOS":
			return "mac"
	if is_steam_deck():
		return "steamdeck"
	return "linux"


static func is_steam_deck() -> bool:
	if OS.get_environment("SteamDeck") != "" or OS.get_environment("SteamOS") != "":
		return true
	if FileAccess.file_exists("/etc/os-release"):
		var f := FileAccess.open("/etc/os-release", FileAccess.READ)
		if f != null:
			var txt := f.get_as_text().to_lower()
			if txt.contains("steamos"):
				return true
	return DirAccess.dir_exists_absolute("/home/deck")


## Where the file browser opens and the shortcut row: [{label, path}], only folders that exist.
static func shortcuts() -> Array:
	var out: Array = []
	var home := Prefs.user_home()
	var add := func(label: String, path: String) -> void:
		if path != "" and DirAccess.dir_exists_absolute(path):
			for e in out:
				if e["path"] == path:
					return
			out.append({"label": label, "path": path})
	add.call("Home", home)
	for sub in ["Downloads", "Documents", "Desktop"]:
		add.call(sub, home.path_join(sub))
	# Steam Deck / Linux removable media (SD card appears under /run/media/<user>/<label>).
	for base in ["/run/media", "/media", "/mnt"]:
		for e in _subdirs(base):
			var sub_path: String = base.path_join(e)
			var kids := _subdirs(sub_path)
			if base == "/run/media" and not kids.is_empty() and not _has_data_hint(sub_path):
				for k in kids:
					add.call("SD card / drive: " + k, sub_path.path_join(k))
			else:
				add.call("Drive: " + e, sub_path)
	if OS.get_name() == "macOS":
		for e in _subdirs("/Volumes"):
			add.call("Volume: " + e, "/Volumes".path_join(e))
	if OS.get_name() == "Windows":
		for d in DirAccess.get_drive_count():
			var dn := DirAccess.get_drive_name(d)
			add.call("Drive " + dn, dn + "/")
	return out


static func _has_data_hint(dir: String) -> bool:
	return looks_like_install(dir) != ""


## "" | "files" (holds Nova Data resource files) | "install" (holds a Nova Files folder).
static func looks_like_install(dir: String) -> String:
	var d := DirAccess.open(dir)
	if d == null:
		return ""
	var result := ""
	d.list_dir_begin()
	var name := d.get_next()
	while name != "":
		var low := name.to_lower()
		if d.current_is_dir():
			if low == "nova files":
				result = "install"
		elif low.begins_with("nova data") and (low.ends_with(".rez") or low.ends_with(".ndat")):
			if result == "":
				result = "files"
		name = d.get_next()
	d.list_dir_end()
	return result


static func _subdirs(dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	var d := DirAccess.open(dir)
	if d == null:
		return out
	d.list_dir_begin()
	var n := d.get_next()
	while n != "":
		if d.current_is_dir() and not n.begins_with("."):
			out.append(n)
		n = d.get_next()
	d.list_dir_end()
	out.sort()
	return out


## Format a byte count ("812 MB", "1.4 GB").
static func fmt_bytes(b: float) -> String:
	var mb := b / 1048576.0
	if mb >= 1024.0:
		return "%.1f GB" % (mb / 1024.0)
	return "%d MB" % int(round(mb))


## Parse a bridge JSON string into a Dictionary ({} on failure).
static func parse(json: String) -> Dictionary:
	var v: Variant = JSON.parse_string(json)
	if v is Dictionary:
		return v
	return {}
