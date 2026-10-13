# NOVA Swift — title-menu music.
#
# The Apple app plays exactly one track, only over its main menu: the file named
# by STR# 130 #2 (`FUN_004ab5d0`), looked for in the plug-ins folder first and
# then in Nova Files, each as the bare name, ".mov", then ".mp3" — the candidate
# order is `OriginalAudio.musicCandidates`. The bridge hands over the name
# (`title_music_name()`); this node does the lookup and, if the file is an mp3,
# plays it. Godot cannot decode QuickTime, so a ".mov" hit (or no hit) is simply
# silence — never an error. No hover sounds anywhere in the menus.
#
# Volume follows Prefs (master × music, mute).
extends AudioStreamPlayer

const Prefs = preload("res://Prefs.gd")

const FOLDERS := ["Nova Plug-ins", "Nova Files"]
const EXTENSIONS := ["", ".mov", ".mp3"]

var track_path := ""    # what was found (may be undecodable), for tests


## The folders the active plug-in set puts in front of the base data (selected total conversion's own
## folders, enabled plug-in folders, then the base data) -- see NovaPlugins.media_dirs. Empty when the
## bridge has no plug-in runtime (old binary).
static func plugin_roots() -> PackedStringArray:
	var out := PackedStringArray()
	if not ClassDB.class_exists("NovaPlugins"):
		return out
	var pl: Object = ClassDB.instantiate("NovaPlugins")
	if pl == null or not pl.has_method("media_dirs"):
		return out
	var arr = JSON.parse_string(str(pl.media_dirs()))
	if arr is Array:
		for d in arr:
			out.append(str(d))
	return out


## Find the track named by `name` in an ordered list of search roots (plug-in folders first, base data
## last): per root the bare name, ".mov", then ".mp3", a direct hit before a nested one. "" if none.
static func locate_in(roots: PackedStringArray, name: String) -> String:
	if name == "":
		return ""
	for r in roots:
		for ext in EXTENSIONS:
			var file: String = name + ext
			var p: String = String(r).path_join(file)
			if FileAccess.file_exists(p):
				return p
			var hit: String = _find_nested(String(r), file, 3)
			if hit != "":
				return hit
	return ""


## Find the track named by `name` under `data_dir`, or "". Exposed for tests.
static func locate(data_dir: String, name: String) -> String:
	if name == "" or data_dir == "":
		return ""
	var plug: PackedStringArray = plugin_roots()
	if not plug.is_empty():
		var first: String = locate_in(plug, name)
		if first != "":
			return first
	for folder in FOLDERS:
		for ext in EXTENSIONS:
			var file: String = name + ext
			# Direct hits first, then one level deeper (imported data may nest).
			for base in [data_dir.path_join(folder), data_dir]:
				var p: String = base.path_join(file)
				if FileAccess.file_exists(p):
					return p
			var hit := _find_nested(data_dir, file, 3)
			if hit != "" and (folder == "Nova Files" or hit.contains(folder)):
				return hit
	return ""


static func _find_nested(dir: String, file: String, depth: int) -> String:
	var d := DirAccess.open(dir)
	if d == null:
		return ""
	for sub in d.get_directories():
		var p := dir.path_join(sub)
		if FileAccess.file_exists(p.path_join(file)):
			return p.path_join(file)
		if depth > 1:
			var hit := _find_nested(p, file, depth - 1)
			if hit != "":
				return hit
	return ""


## Start the title music for the loaded game, if there is a playable file.
func start(nova: Object, data_dir: String) -> void:
	stop()
	if nova == null or not nova.has_method("title_music_name"):
		return
	track_path = locate(data_dir, str(nova.title_music_name()))
	if not bool(Prefs.get_value("classic", "intro_music")):   # the original Preferences window's "Intro Music"
		return
	if track_path == "" or track_path.get_extension().to_lower() != "mp3":
		return
	var stream := AudioStreamMP3.load_from_file(track_path)
	if stream == null:
		return
	stream.loop = true
	self.stream = stream
	refresh_volume()
	if is_inside_tree():
		play()
	else:
		tree_entered.connect(play, CONNECT_ONE_SHOT)


func refresh_volume() -> void:
	var g := Prefs.music_gain()
	volume_db = linear_to_db(g) if g > 0.0 else -80.0
