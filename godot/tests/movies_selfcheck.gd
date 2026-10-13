# Headless self-check for movie conversion (Movies.gd) and playback (ui/MoviePlayer.gd).
# Needs ffmpeg for the conversion half (skipped with a note if absent). Run:
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/movies_selfcheck.gd
# Prints MOVIES SELFCHECK: PASS / FAIL.
extends SceneTree

const Movies = preload("res://Movies.gd")
const MoviePlayer = preload("res://ui/MoviePlayer.gd")

var ok: bool = true


func _check(label: String, cond: bool, detail: String = "") -> bool:
	print(("  ok   " if cond else "  FAIL ") + label + ((" — " + detail) if detail != "" else ""))
	if not cond:
		ok = false
	return cond


func _init() -> void:
	var data: String = OS.get_environment("NOVA_DATA_DIR")
	if data == "":
		data = ProjectSettings.globalize_path("res://") + "../data/base"
	Movies.cache_root = "user://movies_selfcheck"
	Movies._rm_rf(ProjectSettings.globalize_path(Movies.cache_root))
	var src: String = Movies.find_movie("race 1.MOV", Movies.search_roots(data))
	_check("finds Race 1.mov (case-insensitive)", src != "", src)
	_check("no clip -> empty", Movies.find_movie("nope.mov", Movies.search_roots(data)) == "")

	# Graceful skip with ffmpeg forced missing.
	Movies.ffmpeg_override = Movies.MISSING
	_check("forced-missing: no ffmpeg", not Movies.available())
	_check("forced-missing: transcode returns {}", Movies.transcode(src).is_empty())
	Movies.convert_async(src)
	_check("forced-missing: async is a no-op", not Movies.is_pending(src) and Movies.ready(src).is_empty())
	Movies.ffmpeg_override = ""

	if not Movies.available():
		print("  note ffmpeg not installed - conversion checks skipped")
	else:
		var t0: int = Time.get_ticks_msec()
		var a: Dictionary = Movies.transcode(src)
		var t1: int = Time.get_ticks_msec()
		_check("converts Race 1.mov", not a.is_empty(), "%s in %d ms" % [str(a.get("kind", "")), t1 - t0])
		var first_ok: bool = (FileAccess.file_exists(String(a.get("path", ""))) if a.get("kind", "") == "ogv"
			else int(a.get("count", 0)) > 10)
		_check("output is real (ogv file / frame sequence)", first_ok)
		var b: Dictionary = Movies.transcode(src)
		var t2: int = Time.get_ticks_msec()
		_check("second call is a cache hit", b == a and (t2 - t1) < 100, "%d ms" % (t2 - t1))
		_check("ready() agrees", Movies.ready(src) == a)
		# Background path on another clip.
		var src2: String = Movies.find_movie("Race 2.mov", Movies.search_roots(data))
		Movies.convert_async(src2)
		Movies.wait(src2)
		_check("async conversion lands in the cache", not Movies.ready(src2).is_empty())
		# Playback: finishes on skip, exactly once.
		var p: Control = MoviePlayer.new()
		root.add_child(p)
		p.setup(a, Vector2(440, 260))
		var fired: Array = [0]
		p.finished.connect(func(): fired[0] += 1)
		p.skip()
		p.skip()
		_check("player skip fires finished once", fired[0] == 1)
		if a.get("kind", "") == "frames":
			var p2: Control = MoviePlayer.new()
			root.add_child(p2)
			p2.setup(a, Vector2(440, 260))
			var f2: Array = [0]
			p2.finished.connect(func(): f2[0] += 1)
			for i in 400:
				p2._process(1.0 / 30.0)
			_check("frame clip runs to its end", f2[0] == 1)
	Movies._rm_rf(ProjectSettings.globalize_path(Movies.cache_root))
	print("MOVIES SELFCHECK: " + ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
