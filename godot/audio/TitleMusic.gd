# NOVA Swift — title-menu music.
#
# The Apple app plays exactly one track, only over its main menu: the file named
# by STR# 130 #2 (`FUN_004ab5d0`), looked for in the plug-ins folder first and
# then in Nova Files, each as the bare name, ".mov", then ".mp3" — the candidate
# order is `OriginalAudio.musicCandidates`. The bridge hands over the name
# (`title_music_name()`); this node does the lookup and, if the file is an mp3,
# plays it. Godot cannot decode QuickTime, so a ".mov" hit has its audio track extracted ONCE by
# Movies.gd's ffmpeg path (cached WAV; Apple's AVFoundation plays the .mov's audio directly) and
# starts as soon as that finishes, in the background; with no ffmpeg (or no audio track), or no hit,
# it is silence — never an error. No hover sounds anywhere in the menus.
#
# Playback is the original's (`FUN_004ab5d0` / `FUN_004ab8d0` / `FUN_004ab820`), as Apple's
# GameAudio runs it: the track plays ONCE per main-menu visit (nothing rewinds it), starts at
# min(256, step x 0x30)/256, drops to step x 0x20/256 at the first 40-tick service (2/3 s), and
# leaving the menu fades it out 8/256 per 60 Hz tick. The sound-volume step is the master slider
# (step / 8), so the playing level is `Prefs.music_gain()`; the Music slider only mutes at 0.
extends AudioStreamPlayer

signal faded   # the fade-out finished (the track is stopped)

const Prefs = preload("res://Prefs.gd")
const Movies = preload("res://Movies.gd")

const FOLDERS := ["Nova Plug-ins", "Nova Files"]
const EXTENSIONS := ["", ".mov", ".mp3"]

var track_path := ""    # what was found (may be undecodable), for tests
var _fading := false
var _fade_gain := 0.0
var _service := 0.0     # seconds since the track started; < 40/60 = still at the start level
var _waiting_mov := ""  # a .mov whose audio is being extracted in the background


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
			var p: String = _file_ci(String(r), file)
			if p != "":
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
			for base in [_dir_ci(data_dir, folder), data_dir]:
				var p: String = _file_ci(str(base), file)
				if p != "":
					return p
			var hit := _find_nested(data_dir, file, 3)
			if hit != "" and (folder == "Nova Files" or hit.to_lower().contains(folder.to_lower())):
				return hit
	return ""


## `dir/file` matched case-insensitively (the original ran on case-insensitive Windows/Mac
## filesystems; Linux is case-sensitive), exact spelling first. "" if absent.
static func _file_ci(dir: String, file: String) -> String:
	if dir == "":
		return ""
	var exact: String = dir.path_join(file)
	if FileAccess.file_exists(exact):
		return exact
	var d := DirAccess.open(dir)
	if d == null:
		return ""
	var low: String = file.to_lower()
	for n in d.get_files():
		if n.to_lower() == low:
			return dir.path_join(n)
	return ""


## `dir/sub` folder matched case-insensitively; "" if absent.
static func _dir_ci(dir: String, sub: String) -> String:
	var exact: String = dir.path_join(sub)
	if DirAccess.dir_exists_absolute(exact):
		return exact
	var d := DirAccess.open(dir)
	if d == null:
		return ""
	var low: String = sub.to_lower()
	for n in d.get_directories():
		if n.to_lower() == low:
			return dir.path_join(n)
	return ""


static func _find_nested(dir: String, file: String, depth: int) -> String:
	var d := DirAccess.open(dir)
	if d == null:
		return ""
	for sub in d.get_directories():
		var p := dir.path_join(sub)
		var f := _file_ci(p, file)
		if f != "":
			return f
		if depth > 1:
			var hit := _find_nested(p, file, depth - 1)
			if hit != "":
				return hit
	return ""


## Start the title music for the loaded game, if there is a playable file.
func start(nova: Object, data_dir: String) -> void:
	stop()
	_waiting_mov = ""
	if nova == null or not nova.has_method("title_music_name"):
		return
	track_path = locate(data_dir, str(nova.title_music_name()))
	if not bool(Prefs.get_value("classic", "intro_music")):   # the original Preferences window's "Intro Music"
		return
	if track_path == "":
		return
	var ext: String = track_path.get_extension().to_lower()
	if ext == "mp3":
		var stream := AudioStreamMP3.load_from_file(track_path)
		if stream != null:
			stream.loop = false   # plays once per visit
			_begin(stream)
	elif ext == "mov":
		var wav: String = Movies.audio_ready(track_path)
		if wav != "":
			_begin_wav(wav)
		elif Movies.available():
			_waiting_mov = track_path
			Movies.convert_audio_async(track_path)
			set_process(true)


func _begin_wav(path: String) -> void:
	var w: AudioStreamWAV = AudioStreamWAV.load_from_file(path)
	if w != null:
		_begin(w)


func _begin(stream: AudioStream) -> void:
	self.stream = stream
	_service = 0.0
	set_process(true)
	refresh_volume()
	if is_inside_tree():
		play()
	else:
		tree_entered.connect(play, CONNECT_ONE_SHOT)


func _ready() -> void:
	set_process(false)


func _process(delta: float) -> void:
	if _waiting_mov != "":
		if Movies.audio_pending(_waiting_mov):
			return
		var src: String = _waiting_mov
		_waiting_mov = ""
		var wav: String = Movies.audio_ready(src)
		if wav != "" and not _fading and src == track_path:
			_begin_wav(wav)
		else:
			set_process(false)
		return
	if _fading:
		_fade_gain -= (8.0 / 256.0) * delta * 60.0
		if _fade_gain <= 0.0:
			_fading = false
			set_process(false)
			stop()
			faded.emit()
			return
		volume_db = linear_to_db(_fade_gain)
		return
	if _service < 40.0 / 60.0:
		_service += delta
		if _service >= 40.0 / 60.0:
			refresh_volume()   # the 40-tick service re-levels to the playing volume


func refresh_volume() -> void:
	if _fading:
		return
	var g := Prefs.music_gain() if _service >= 40.0 / 60.0 else Prefs.music_start_gain()
	volume_db = linear_to_db(g) if g > 0.0 else -80.0


## Leave the menu: step the volume down 8/256 per 60 Hz tick from its current level, then stop
## and emit `faded`. Silent or finished tracks end at once.
func fade_out() -> void:
	_waiting_mov = ""   # a track still being extracted never starts after the menu is left
	if not playing or _fading:
		if not _fading:
			faded.emit()
		return
	_fade_gain = db_to_linear(volume_db)
	_fading = true
	set_process(true)
