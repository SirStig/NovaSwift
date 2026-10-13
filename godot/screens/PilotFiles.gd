# NOVA Swift — pilots as real files: where the Pilots folder is, one-time migration from the old
# user://pilots store, the recent-pilots list, and the Open Pilot file picker.
#
# Like the original, a pilot is an ordinary file the player can see, copy, back up and open from
# anywhere: `<Pilots folder>/<uuid>.evpilot` (the Apple app's PilotArchive format, with its
# rotating `Backups/` beside it). The folder is, in order:
#   1. $NOVA_PILOTS_DIR (tests, portable installs)
#   2. Settings > Data & Advanced > Pilots folder  (Prefs [pilots] dir)
#   3. <Documents>/NovaSwift/Pilots         Windows %USERPROFILE%\Documents, macOS ~/Documents,
#                                           Linux / Steam Deck ~/Documents (XDG documents dir)
#   4. ~/.local/share/NovaSwift/Pilots      when Documents can't be written (or does not exist)
#   5. user://pilots                        last resort (the Godot user dir)
# Documents (not the EV Nova data folder) is the default on purpose: the data folder is often a
# read-only or repo-internal copy, and a visible, findable folder is what the original offered.
#
# Open Pilot uses the OS file picker (FileDialog.use_native_dialog) starting in that folder. The
# native picker is not gamepad-drivable, so `want_native()` is false when a pad is the active
# input (or on Steam Deck game mode) and Godot's own focus-navigable FileDialog is used instead.
#
# Loaded with preload() (no class_name), like Controls.gd. All state is static.
extends RefCounted

const Prefs = preload("res://Prefs.gd")
const Controls = preload("res://Controls.gd")
const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")

const FOLDER_NAME := "Pilots"
const MAX_RECENT := 8
## Where pilots lived before they were real files; tests point it at a scratch dir.
static var legacy_dir := "user://pilots"


# --- the Pilots folder ---------------------------------------------------------------

static func _writable(dir: String) -> bool:
	if dir == "":
		return false
	if not DirAccess.dir_exists_absolute(dir):
		if DirAccess.make_dir_recursive_absolute(dir) != OK:
			return false
	var probe := dir.path_join(".nova_write_test")
	var f := FileAccess.open(probe, FileAccess.WRITE)
	if f == null:
		return false
	f.close()
	DirAccess.remove_absolute(probe)
	return true


static func _home() -> String:
	var home := OS.get_environment("HOME")
	if home == "":
		home = OS.get_environment("USERPROFILE")
	return home


## The default folder for this OS (ignoring env / the Settings override).
static func default_dir() -> String:
	var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if docs != "" and DirAccess.dir_exists_absolute(docs):
		var d := docs.path_join("NovaSwift").path_join(FOLDER_NAME)
		if _writable(d):
			return d
	var home := _home()
	if home != "":
		var d2 := home.path_join(".local/share/NovaSwift").path_join(FOLDER_NAME)
		if _writable(d2):
			return d2
	return ProjectSettings.globalize_path("user://pilots")


## The Pilots folder in use (absolute, created on demand).
static func dir() -> String:
	var env := OS.get_environment("NOVA_PILOTS_DIR")
	if env != "":
		DirAccess.make_dir_recursive_absolute(env)
		return env
	var set := str(Prefs.get_value("pilots", "dir"))
	if set != "" and _writable(set):
		return set
	return default_dir()


static func is_custom() -> bool:
	return OS.get_environment("NOVA_PILOTS_DIR") != "" or str(Prefs.get_value("pilots", "dir")) != ""


## Settings > Pilots folder > Change…: point at `new_dir`, copying the pilots already in the old
## folder across (the originals stay). "" restores the default. Returns the folder now in use.
static func set_dir(new_dir: String) -> String:
	var old := dir()
	Prefs.set_value("pilots", "dir", new_dir)
	var now := dir()
	if now != old:
		copy_pilots(old, now)
	return now


# --- migration & copying -------------------------------------------------------------

static func _copy_file(src: String, dst: String) -> bool:
	var data := FileAccess.get_file_as_bytes(src)
	if data.is_empty() and FileAccess.get_open_error() != OK:
		return false
	var f := FileAccess.open(dst, FileAccess.WRITE)
	if f == null:
		return false
	f.store_buffer(data)
	f.close()
	return true


## Copy every `.evpilot` (and its `Backups/<id>/` history) from `from` into `to`; files that
## already exist in `to` are skipped, the source is never touched. Returns pilots copied.
static func copy_pilots(from: String, to: String) -> int:
	from = from.simplify_path()
	to = to.simplify_path()
	if from == to or not DirAccess.dir_exists_absolute(from):
		return 0
	DirAccess.make_dir_recursive_absolute(to)
	var copied := 0
	for f in DirAccess.get_files_at(from):
		if f.get_extension() != "evpilot":
			continue
		var dst := to.path_join(f)
		if FileAccess.file_exists(dst):
			continue
		if _copy_file(from.path_join(f), dst):
			copied += 1
			var id := f.get_basename()
			var bsrc := from.path_join("Backups").path_join(id)
			if DirAccess.dir_exists_absolute(bsrc):
				var bdst := to.path_join("Backups").path_join(id)
				DirAccess.make_dir_recursive_absolute(bdst)
				for b in DirAccess.get_files_at(bsrc):
					if not FileAccess.file_exists(bdst.path_join(b)):
						_copy_file(bsrc.path_join(b), bdst.path_join(b))
	return copied


## Once per install: bring the pilots saved in the old `user://pilots` store into the Pilots
## folder (copy; the originals stay). Returns how many were copied (0 when already done).
static func migrate_legacy() -> int:
	if bool(Prefs.get_value("pilots", "migrated")):
		return 0
	var src := ProjectSettings.globalize_path(legacy_dir)
	var n := copy_pilots(src, dir())
	Prefs.set_value("pilots", "migrated", true)
	Prefs.save()
	if n > 0:
		print("NOVA Swift: copied %d pilot(s) from %s to %s" % [n, src, dir()])
	return n


# --- recent pilots -------------------------------------------------------------------

static func recent_paths() -> Array:
	var out := []
	var raw = Prefs.get_value("pilots", "recent")
	if raw is Array:
		for p in raw:
			if FileAccess.file_exists(str(p)) and not out.has(str(p)):
				out.append(str(p))
	return out


static func note_recent(path: String) -> void:
	var list := recent_paths()
	list.erase(path)
	list.push_front(path)
	Prefs.set_value("pilots", "recent", list.slice(0, MAX_RECENT))
	Prefs.save()


## The compact list the Open Pilot screen shows: recently opened files first, topped up with the
## newest pilots in the Pilots folder. Rows are `pilot_inspect_file` dictionaries plus `path`.
static func recent_rows(nova: Object, folder: String, limit := 5) -> Array:
	var rows := []
	var seen := {}
	for p in recent_paths():
		var info = JSON.parse_string(nova.pilot_inspect_file(p))
		if info is Dictionary and info.get("kind", "") == "evpilot":
			info["path"] = p
			rows.append(info)
			seen[str(info.get("id", p))] = true
	var listed = JSON.parse_string(nova.pilot_list(folder))
	if listed is Array:
		for r in listed:
			if seen.has(str(r["id"])):
				continue
			var path: String = nova.pilot_file_path(folder, str(r["id"]))
			r["kind"] = "evpilot"
			r["path"] = path
			rows.append(r)
	return rows.slice(0, limit)


# --- the picker ----------------------------------------------------------------------

## Steam Deck game mode (gamescope / the Steam UI): the OS file picker can't be driven by the pad.
static func steam_deck_game_mode() -> bool:
	return OS.get_environment("SteamDeck") == "1" or OS.get_environment("SteamGamepadUI") != "" \
			or OS.get_environment("XDG_CURRENT_DESKTOP").to_lower() == "gamescope"


## Use the OS picker? Not when a pad is the active input (it can't drive it) or on Deck game
## mode, and not when the platform has no native dialogs (then Godot's own is used). Keyboard /
## mouse players get the native picker; with a pad plugged in but the keyboard in use that is
## still the case, since ClassicTheme.nav_active also tracks key navigation this errs toward the
## pad-safe Godot dialog only while navigation input is live.
static func want_native() -> bool:
	if not DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE):
		return false
	if steam_deck_game_mode():
		return false
	return not (Controls.pad_connected() and ClassicTheme.nav_active)


const FILTERS := ["*.evpilot, *.plt ; EV Nova pilots (NovaSwift and original)", "* ; All files"]


## Open the file picker over `host` starting in `start` (the Pilots folder); `on_file(path)` gets the
## chosen file. Returns the FileDialog (it frees itself when done). `native` null = auto.
static func pick_file(host: Node, start: String, on_file: Callable, on_cancel := Callable(), native: Variant = null) -> FileDialog:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.use_native_dialog = want_native() if native == null else bool(native)
	fd.title = "Open Pilot"
	fd.filters = PackedStringArray(FILTERS)
	fd.current_dir = start
	fd.size = Vector2i(900, 560)
	fd.file_selected.connect(func(p: String):
		on_file.call(p)
		fd.queue_free())
	fd.canceled.connect(func():
		if on_cancel.is_valid():
			on_cancel.call()
		fd.queue_free())
	host.add_child(fd)
	if not fd.use_native_dialog:
		var shell_ui := load("res://screens/ShellUI.gd")
		fd.theme = shell_ui.theme()
	fd.popup_centered()
	return fd


## A folder picker (Settings > Pilots folder > Change…). Same native / pad rule.
static func pick_folder(host: Node, start: String, on_dir: Callable, native: Variant = null) -> FileDialog:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.use_native_dialog = want_native() if native == null else bool(native)
	fd.title = "Choose the Pilots folder"
	fd.current_dir = start
	fd.size = Vector2i(900, 560)
	fd.dir_selected.connect(func(p: String):
		on_dir.call(p)
		fd.queue_free())
	fd.canceled.connect(fd.queue_free)
	host.add_child(fd)
	if not fd.use_native_dialog:
		fd.theme = load("res://screens/ShellUI.gd").theme()
	fd.popup_centered()
	return fd
