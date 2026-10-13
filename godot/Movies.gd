# NOVA Swift — original-game movies (QuickTime .mov) for the Godot frontend.
#
# Godot can't decode QuickTime, so each clip is transcoded ONCE with an external
# ffmpeg into a cache under user://movies/ and played from there:
#   * "ogv"    — Ogg Theora (VideoStreamTheora), used when ffmpeg has the libtheora
#                encoder (most Linux / Windows builds do);
#   * "frames" — a JPEG frame sequence + movie.json (+ optional audio.wav), used when
#                ffmpeg lacks libtheora (Homebrew's ffmpeg, for one). ui/MoviePlayer.gd
#                plays either kind identically.
# ffmpeg is an OPTIONAL runtime dependency. Without it (or if conversion fails) every
# call here returns an empty result and callers skip the movie exactly as the original
# does with its "QuickTime Movies" preference off (Ui_PlayMovieFileModal 0x0049db00
# returns at once) — nothing blocks and nothing is reported as an error.
#
# Pure GDScript, loaded with preload() (no class_name). All entry points are static.
extends RefCounted

## "" = auto-detect; MISSING forces "no ffmpeg" (headless self-check); else a path.
const MISSING := "<missing>"
static var ffmpeg_override: String = ""
## Cache root; tests point this at a scratch dir.
static var cache_root: String = "user://movies"

static var _ffmpeg_cached: String = ""
static var _ffmpeg_probed: bool = false
static var _theora: int = -1                  # -1 unknown, 0 no, 1 yes
static var _jobs: Dictionary = {}             # cache key -> WorkerThreadPool task id


# --- ffmpeg discovery ----------------------------------------------------------

static func find_ffmpeg() -> String:
	if ffmpeg_override == MISSING:
		return ""
	if ffmpeg_override != "":
		return ffmpeg_override if FileAccess.file_exists(ffmpeg_override) else ""
	if _ffmpeg_probed:
		return _ffmpeg_cached
	_ffmpeg_probed = true
	var names: PackedStringArray = ["ffmpeg.exe", "ffmpeg"] if OS.get_name() == "Windows" else ["ffmpeg"]
	var dirs: PackedStringArray = []
	for d in OS.get_environment("PATH").split(";" if OS.get_name() == "Windows" else ":", false):
		dirs.append(d)
	for d in ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin"]:
		if not dirs.has(d):
			dirs.append(d)
	for d in dirs:
		for n in names:
			var p: String = String(d).path_join(n)
			if FileAccess.file_exists(p):
				_ffmpeg_cached = p
				return p
	return ""


static func available() -> bool:
	return find_ffmpeg() != ""


static func _has_encoder(ff: String, enc: String) -> bool:
	var out: Array = []
	if OS.execute(ff, ["-hide_banner", "-encoders"], out, true) != 0 or out.is_empty():
		return false
	return String(out[0]).contains(" " + enc + " ")


static func has_theora(ff: String) -> bool:
	if _theora < 0 or ffmpeg_override != "":
		_theora = 1 if _has_encoder(ff, "libtheora") else 0
	return _theora == 1


# --- locating a clip -----------------------------------------------------------

## A clip by filename, case-insensitively, the way the Apple app does: plug-in folders
## first, then the base data (direct hit in a folder, then nested). `roots` are the
## directories to search in priority order (see search_roots).
static func find_movie(name: String, roots: PackedStringArray) -> String:
	if name == "":
		return ""
	for r in roots:
		var hit: String = _find_in(r, name, 0)
		if hit != "":
			return hit
	return ""


static func _find_in(dir: String, name: String, depth: int) -> String:
	var da := DirAccess.open(dir)
	if da == null or depth > 4:
		return ""
	for f in da.get_files():
		if f.nocasecmp_to(name) == 0:
			return dir.path_join(f)
	for sub in da.get_directories():
		var hit: String = _find_in(dir.path_join(sub), name, depth + 1)
		if hit != "":
			return hit
	return ""


## Plug-in folders (a `plugins/` sibling of the base data dir) then the base dir itself.
static func search_roots(data_dir: String) -> PackedStringArray:
	var out := PackedStringArray()
	# The active plug-in set first (a total conversion's own Nova Files, enabled plug-in folders), then the
	# base data -- Ui_PlayMovieFileModal looks in "Nova Plug-ins" before "Nova Files".
	if ClassDB.class_exists("NovaPlugins"):
		var pl: Object = ClassDB.instantiate("NovaPlugins")
		if pl != null and pl.has_method("media_dirs"):
			var arr = JSON.parse_string(str(pl.media_dirs()))
			if arr is Array:
				for d in arr:
					if not out.has(str(d)):
						out.append(str(d))
	if data_dir == "":
		return out
	var parent: String = data_dir.simplify_path().get_base_dir()
	for p in [parent.path_join("plugins"), data_dir.path_join("Nova Plug-ins"), data_dir.path_join("plugins")]:
		if DirAccess.dir_exists_absolute(p) and not out.has(p):
			out.append(p)
	if not out.has(data_dir):
		out.append(data_dir)
	return out


# --- cache ---------------------------------------------------------------------

static func cache_dir() -> String:
	var d: String = ProjectSettings.globalize_path(cache_root)
	DirAccess.make_dir_recursive_absolute(d)
	return d


## `<name>_<hash of path+size+mtime>` so an edited/replaced source re-converts.
static func cache_key(src: String) -> String:
	var stem: String = src.get_file().get_basename().validate_filename().replace(" ", "_")
	var sig: String = "%s|%d|%d" % [src, _size(src), FileAccess.get_modified_time(src)]
	return "%s_%s" % [stem, String.num_int64(sig.hash(), 16)]


static func _size(src: String) -> int:
	var f := FileAccess.open(src, FileAccess.READ)
	if f == null:
		return 0
	var n: int = f.get_length()
	f.close()
	return n


## The cached conversion of `src`, or {} when none exists yet. Never converts.
## {"kind":"ogv","path"} or {"kind":"frames","dir","fps","count","audio"}.
static func ready(src: String) -> Dictionary:
	if src == "" or not FileAccess.file_exists(src):
		return {}
	var base: String = cache_dir().path_join(cache_key(src))
	if FileAccess.file_exists(base + ".ogv"):
		return {"kind": "ogv", "path": base + ".ogv"}
	var meta_path: String = base.path_join("movie.json")
	if FileAccess.file_exists(meta_path):
		var m: Variant = JSON.parse_string(FileAccess.get_file_as_string(meta_path))
		if m is Dictionary and int(m.get("count", 0)) > 0:
			var audio: String = base.path_join("audio.wav")
			return {"kind": "frames", "dir": base, "fps": float(m.get("fps", 24.0)), "count": int(m.count),
				"audio": audio if FileAccess.file_exists(audio) else ""}
	return {}


static func is_pending(src: String) -> bool:
	var key: String = cache_key(src)
	if not _jobs.has(key):
		return false
	if WorkerThreadPool.is_task_completed(int(_jobs[key])):
		WorkerThreadPool.wait_for_task_completion(int(_jobs[key]))
		_jobs.erase(key)
		return false
	return true


## Convert now (blocking, a few hundred ms for a race clip). Returns ready(src) or {}.
static func transcode(src: String) -> Dictionary:
	var hit: Dictionary = ready(src)
	if not hit.is_empty():
		return hit
	var ff: String = find_ffmpeg()
	if ff == "" or not FileAccess.file_exists(src):
		return {}
	var base: String = cache_dir().path_join(cache_key(src))
	if has_theora(ff) and _to_ogv(ff, src, base):
		return ready(src)
	_to_frames(ff, src, base)
	return ready(src)


static func _to_ogv(ff: String, src: String, base: String) -> bool:
	var part: String = base + ".part.ogv"
	var vf: String = "scale=trunc(iw/2)*2:trunc(ih/2)*2"
	for audio_args in [["-c:a", "libvorbis", "-q:a", "4"], ["-an"]]:
		var args: Array = ["-y", "-v", "error", "-i", src, "-map", "0:v:0", "-map", "0:a:0?", "-vf", vf,
			"-c:v", "libtheora", "-q:v", "7", "-pix_fmt", "yuv420p"] + audio_args + [part]
		if OS.execute(ff, PackedStringArray(args), [], true) == 0 and FileAccess.file_exists(part):
			DirAccess.rename_absolute(part, base + ".ogv")
			return true
		DirAccess.remove_absolute(part)
	return false


static func _to_frames(ff: String, src: String, base: String) -> bool:
	var tmp: String = base + ".part"
	_rm_rf(tmp)
	DirAccess.make_dir_recursive_absolute(tmp)
	var fps: int = 24
	var args: Array = ["-y", "-v", "error", "-i", src, "-map", "0:v:0", "-vf",
		"fps=%d,scale='min(640,iw)':-2" % fps, "-q:v", "4", tmp.path_join("f%04d.jpg")]
	var ok: bool = OS.execute(ff, PackedStringArray(args), [], true) == 0
	var count: int = 0
	if ok:
		var da := DirAccess.open(tmp)
		if da != null:
			for f in da.get_files():
				if f.ends_with(".jpg"):
					count += 1
	if count == 0:
		_rm_rf(tmp)
		return false
	# Optional audio track; absence or failure is fine.
	OS.execute(ff, PackedStringArray(["-y", "-v", "error", "-i", src, "-map", "0:a:0", "-ac", "2",
		"-ar", "44100", tmp.path_join("audio.wav")]), [], true)
	var f := FileAccess.open(tmp.path_join("movie.json"), FileAccess.WRITE)
	f.store_string(JSON.stringify({"fps": fps, "count": count}))
	f.close()
	_rm_rf(base)
	return DirAccess.rename_absolute(tmp, base) == OK


static func _rm_rf(dir: String) -> void:
	var da := DirAccess.open(dir)
	if da == null:
		return
	for f in da.get_files():
		da.remove(f)
	for d in da.get_directories():
		_rm_rf(dir.path_join(d))
	DirAccess.remove_absolute(dir)


## Convert in the background (no-op if cached, in flight, or ffmpeg is unavailable).
static func convert_async(src: String) -> void:
	if src == "" or find_ffmpeg() == "" or not ready(src).is_empty() or is_pending(src):
		return
	var key: String = cache_key(src)
	_jobs[key] = WorkerThreadPool.add_task(func(): transcode(src))


## Block until a background conversion of `src` finishes (tests only).
static func wait(src: String) -> void:
	var key: String = cache_key(src)
	if _jobs.has(key):
		WorkerThreadPool.wait_for_task_completion(int(_jobs[key]))
		_jobs.erase(key)


## Start background conversion of every clip the game ships that we know of
## (the four race clips); callers can add more via convert_async.
static func prewarm_race(data_dir: String) -> void:
	var roots: PackedStringArray = search_roots(data_dir)
	for i in range(1, 5):
		convert_async(find_movie("Race %d.mov" % i, roots))
