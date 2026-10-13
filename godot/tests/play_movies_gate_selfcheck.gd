# Headless check (E3): the original "QuickTime Movies" preference (Prefs [classic] play_movies,
# Ui_PlayMovieFileModal 0x0049db00) gates EVERY Godot movie path. With it off, the shared dësc lookup
# (docking, story texts, intro text / GIF key, acknowledgements) and the hypergate / wormhole entry movie
# find nothing, play_gate runs its continuation at once without an overlay, and the bar / offer paths
# read the same pref. A source scan then asserts no movie caller bypasses the pref.
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/play_movies_gate_selfcheck.gd
extends SceneTree

const Prefs = preload("res://Prefs.gd")
const DescMovie = preload("res://ui/DescMovie.gd")

var _fails: int = 0


func _ok(cond: bool, what: String) -> void:
	print(("PASS " if cond else "FAIL ") + what)
	if not cond:
		_fails += 1


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	Prefs.path = OS.get_user_data_dir() + "/play_movies_gate.cfg"
	DirAccess.remove_absolute(Prefs.path)
	Prefs.load_all()
	Prefs.set_value("classic", "play_movies", false)
	# Every desc id, including the ones the data really names (docking 128+, gate 128+, intro 20000, X key 32766).
	for id in [128, 150, 338, 20000, 32766]:
		_ok(DescMovie.lookup(id).is_empty(), "pref off: lookup(%d) finds nothing" % id)
		_ok(DescMovie.lookup_gate(id).is_empty(), "pref off: lookup_gate(%d) finds nothing" % id)
	var ran: Array = [0]
	var overlay: CanvasLayer = DescMovie.play_gate(self.root, 150, func(): ran[0] += 1)
	_ok(overlay == null and ran[0] == 1, "pref off: play_gate continues at once, no overlay")

	# Source scan: every file that plays or converts a movie reads the pref (directly or through DescMovie).
	var files: Dictionary = {}
	for f in ["res://screens/BarScreens.gd", "res://screens/StoryScreens.gd", "res://screens/IntroSequence.gd",
			"res://screens/MainMenu.gd", "res://screens/Spaceport.gd", "res://screens/GalaxyMap.gd", "res://Main.gd"]:
		files[f] = FileAccess.get_file_as_string(f)
	_ok(files["res://screens/BarScreens.gd"].contains('"play_movies"'), "BarScreens (race clips) reads play_movies")
	_ok(files["res://screens/StoryScreens.gd"].contains('"play_movies"'), "StoryScreens (offer movies) reads play_movies")
	for f in ["res://screens/IntroSequence.gd", "res://screens/MainMenu.gd", "res://screens/Spaceport.gd",
			"res://screens/GalaxyMap.gd", "res://Main.gd"]:
		var src: String = files[f]
		_ok(not src.contains("MoviePlayer.new()") and not src.contains("Movies.transcode(") and
			(src.contains("DescMovie.lookup") or src.contains("DescMovie.play_gate")), "%s plays only through the gated DescMovie" % f)
	var dm: String = FileAccess.get_file_as_string("res://ui/DescMovie.gd")
	_ok(dm.contains('Prefs.get_value("classic", "play_movies")'), "DescMovie._lookup reads play_movies")
	print("play_movies_gate_selfcheck: %d failure(s)" % _fails)
	quit(1 if _fails > 0 else 0)
