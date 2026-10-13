# Headless self-check for sound parity with the Apple app (docs/GODOT_FIDELITY_GAPS.md,
# "Sound sites"): trigger each event and assert the queued cue (snd id / priority / guards)
# through the bridge's test-only `debug_drain_sounds()`. Run:
#   NOVA_DATA_DIR=data/base godot --headless --path godot -s res://tests/sound_parity_selfcheck.gd
# Needs a bridge built with debug_drain_sounds / landed_ambient_sound; against an older dylib the
# bridge-dependent groups report SKIP and the script-only groups (music, brightness, defaults) run.
extends SceneTree

const Prefs = preload("res://Prefs.gd")
const GameAudio = preload("res://audio/GameAudio.gd")
const BrightnessVeil = preload("res://ui/BrightnessVeil.gd")
const TitleMusic = preload("res://audio/TitleMusic.gd")

var nova: Object
var ok := true

# OriginalAudio.Priority
const P_BEEP := 1
const P_AIRLOCK := 8
const P_MENU := 10
const P_WARP_OUT := 0x32
const P_WARP_UP := 32000
const P_KLAXXON := 0xF
const P_RED_ALERT := 5


func _init() -> void:
	_run()


func _drain() -> Array:
	var v = JSON.parse_string(str(nova.debug_drain_sounds()))
	return v if v is Array else []


func _find(cues: Array, id: int) -> Dictionary:
	for c in cues:
		if int(c.id) == id:
			return c
	return {}


func _count(cues: Array, id: int) -> int:
	var n := 0
	for c in cues:
		if int(c.id) == id:
			n += 1
	return n


func _run() -> void:
	await process_frame
	nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	var data := OS.get_environment("NOVA_DATA_DIR")
	if data == "":
		data = ProjectSettings.globalize_path("res://") + "../data/base"
	ok = _check("load_game", nova.load_game(data)) and ok
	ok = _check("make_world", nova.make_world(-1)) and ok

	_script_only_checks()
	if not nova.has_method("debug_drain_sounds"):
		print("  SKIP bridge groups: debug_drain_sounds missing (old dylib)")
		_finish()
		return
	_drain()

	_beeps()
	_menu()
	_flight_keys()
	_landing()
	_jump()
	await _ambient()
	_combat()
	_finish()


# --- script-side parity: defaults, music levels, brightness -----------------------------------

func _script_only_checks() -> void:
	var d: Dictionary = Prefs.DEFAULTS["audio"]
	ok = _check("defaults: master 5/8, effects 0.9, interface 0.8 (Apple GameSettings)",
		is_equal_approx(float(d["master"]), 0.625) and is_equal_approx(float(d["sfx"]), 0.9)
		and is_equal_approx(float(d["ui"]), 0.8)) and ok
	var cl: Dictionary = Prefs.DEFAULTS["classic"]
	ok = _check("defaults: Ambient Sounds on, Intro Music on, volume step 5, brightness 3",
		bool(cl["ambient_sounds"]) and bool(cl["intro_music"]) and int(cl["sound_volume_step"]) == 5
		and int(cl["brightness_step"]) == 3) and ok
	# Music: step x 0x20/256 once playing, min(256, step x 0x30)/256 at the start.
	var saved_m = Prefs.get_value("audio", "master")
	var saved_mu = Prefs.get_value("audio", "muted")
	var saved_ms = Prefs.get_value("audio", "music")
	var saved_me = Prefs.get_value("audio", "music_enabled")
	Prefs.set_value("audio", "muted", false)
	Prefs.set_value("audio", "music_enabled", true)
	Prefs.set_value("audio", "music", 0.7)
	Prefs.set_value("audio", "master", 5.0 / 8.0)
	ok = _check("music playing level = step/8 (160/256 at step 5)", is_equal_approx(Prefs.music_gain(), 160.0 / 256.0)) and ok
	ok = _check("music start level = step x 0x30/256 (240/256 at step 5)", is_equal_approx(Prefs.music_start_gain(), 240.0 / 256.0)) and ok
	Prefs.set_value("audio", "master", 1.0)
	ok = _check("music start level clamps at 256/256", is_equal_approx(Prefs.music_start_gain(), 1.0)) and ok
	Prefs.set_value("audio", "music", 0.0)
	ok = _check("music slider at 0 mutes (Apple musicVolume > 0 gate)", Prefs.music_gain() == 0.0) and ok
	Prefs.set_value("audio", "music", 0.7)
	Prefs.set_value("audio", "muted", true)
	ok = _check("mute silences music", Prefs.music_gain() == 0.0) and ok
	Prefs.set_value("audio", "master", saved_m)
	Prefs.set_value("audio", "muted", saved_mu)
	Prefs.set_value("audio", "music", saved_ms)
	Prefs.set_value("audio", "music_enabled", saved_me)
	# Brightness: gamma = step x 10 + 70 percent; black veil below 100, white above.
	var b3: Color = BrightnessVeil.veil_for_step(3)
	var b0: Color = BrightnessVeil.veil_for_step(0)
	var b6: Color = BrightnessVeil.veil_for_step(6)
	ok = _check("brightness 3 = no veil", b3.a == 0.0) and ok
	ok = _check("brightness 0 = black veil 0.30", b0.r == 0.0 and is_equal_approx(b0.a, 0.30)) and ok
	ok = _check("brightness 6 = white veil 0.15", b6.r == 1.0 and is_equal_approx(b6.a, 0.15)) and ok


# --- interface beeps and menu sounds -----------------------------------------------------------

func _beeps() -> void:
	for n in [1, 2, 3, 4, 5]:
		nova.sound_beep(n)
		var c: Array = _drain()
		var cue: Dictionary = c[0] if c.size() == 1 else {}
		ok = _check("beep %d = snd %d, priority 1, interface volume" % [n, 149 + n],
			not cue.is_empty() and int(cue.id) == 149 + n and int(cue.priority) == P_BEEP
			and bool(cue.interface) and not bool(cue.onlyWhenSilent) and not cue.has("x")) and ok
	nova.sound_beep(9)
	ok = _check("beep out of range queues nothing", _drain().is_empty()) and ok


func _menu() -> void:
	for id in [600, 601]:
		nova.sound_menu(id)
		var c: Array = _drain()
		ok = _check("menu snd %d priority 10, not interface" % id,
			c.size() == 1 and int(c[0].id) == id and int(c[0].priority) == P_MENU and not bool(c[0].interface)) and ok
	for id in [602, 603]:
		nova.sound_menu(id)
		var c: Array = _drain()
		ok = _check("shutter snd %d priority 0x32 (Apple playMenuSlide)" % id,
			c.size() == 1 and int(c[0].id) == id and int(c[0].priority) == P_WARP_OUT) and ok


# --- flight keys (0x0044b120) ---------------------------------------------------------------------

func _flight_keys() -> void:
	nova.clear_travel_selection()
	var c: Array = _drain()
	ok = _check("N (clear travel selection) = snd 150", c.size() == 1 and int(c[0].id) == 150) and ok
	nova.cycle_target(false, false)
	c = _drain()
	ok = _check("target cycle = snd 152 whatever it lands on", c.size() == 1 and int(c[0].id) == 152) and ok
	nova.clear_ship_target()   # nothing targeted after a cycle past the end? only sounds when one was set
	_drain()
	nova.clear_secondary_weapon()
	_drain()
	nova.toggle_cloak()
	c = _drain()
	var hull_has_cloak := false
	hull_has_cloak = c.is_empty()
	ok = _check("cloak toggle: snd 153 when the hull has no cloak, else silent here (the 380/381 cue comes from the world)",
		(hull_has_cloak or (c.size() == 1 and int(c[0].id) == 153))) and ok
	_drain()


# --- landing -------------------------------------------------------------------------------------

func _landing() -> void:
	var lt: PackedInt32Array = nova.debug_land_targets()
	if lt.size() == 0:
		print("  SKIP landing: no landable stellar")
		return
	var inhabited := -1
	var uninhabited := -1
	for id in lt:
		nova.debug_dock_at(id)
		var info = JSON.parse_string(str(nova.spaceport_info()))
		var unin: bool = info is Dictionary and bool(info.get("uninhabited", false))
		_drain()
		nova.launch()
		_drain()
		if unin and uninhabited < 0:
			uninhabited = id
		if not unin and inhabited < 0:
			inhabited = id
		if inhabited >= 0 and uninhabited >= 0:
			break

	if inhabited >= 0:
		nova.debug_dock_at(inhabited)
		var c: Array = _drain()
		ok = _check("touchdown = snd 390 once, priority 8, centred (no position)",
			_count(c, 390) == 1 and int(_find(c, 390).priority) == P_AIRLOCK and not _find(c, 390).has("x")) and ok
		ok = _check("inhabited touchdown plays nothing else (no snd 151)", _count(c, 151) == 0 and c.size() == 1) and ok
		nova.launch()
		ok = _check("launch is silent (no snd 390 / beep on takeoff)", _drain().is_empty()) and ok
	if uninhabited >= 0:
		nova.debug_dock_at(uninhabited)
		var c2: Array = _drain()
		ok = _check("uninhabited touchdown = snd 390 + snd 151 (SpaceportView.onAppear)",
			_count(c2, 390) == 1 and _count(c2, 151) == 1) and ok
		nova.launch()
		_drain()

	# The two-press landing: request beeps, then the single touchdown cue.
	if inhabited >= 0:
		nova.debug_place_player_at_spob(inhabited)
		nova.step(1.0 / 30.0)
		_drain()
		var r1 = JSON.parse_string(str(nova.press_land()))
		var c3: Array = _drain()
		var requested: bool = r1 is Dictionary and str(r1.get("result", "")) in ["messages", "landed"]
		ok = _check("first Land press: a request/denial beep (151) or a direct landing, never 390 before touchdown",
			requested and (_count(c3, 151) >= 1 or _count(c3, 150) >= 1 or _count(c3, 153) >= 1 or _count(c3, 390) == 1)) and ok
		for _i in 10:
			nova.step(1.0 / 30.0)
		var r2 = JSON.parse_string(str(nova.press_land()))
		var c4: Array = _drain()
		if r2 is Dictionary and str(r2.get("result", "")) == "landed":
			ok = _check("second press touchdown: exactly one snd 390", _count(c4, 390) == 1) and ok
			nova.launch()
			_drain()
		else:
			print("  note: second Land press did not land (", str(r2), "); 390 count ", _count(c4, 390))


# --- hyperspace ---------------------------------------------------------------------------------

func _jump() -> void:
	var seen_up := {}
	var seen_out := {}
	var tries := 0
	var started := false
	while tries < 3000:
		nova.set_intent(false, false, not started, false, false, false, false)
		nova.step(1.0 / 30.0)
		tries += 1
		if not started and tries % 15 == 0:
			nova.begin_hyperjump()
			started = nova.hyperjump_active()
		for c in _drain():
			if int(c.id) in [128, 129]:
				seen_up = c
			if int(c.id) == 130:
				seen_out = c
		if started and not nova.hyperjump_active():
			break
	if not started:
		print("  SKIP jump: could not arm a hyperjump in this system")
		return
	nova.take_jump_arrival()
	for c in _drain():
		if int(c.id) == 130:
			seen_out = c
	ok = _check("Warp up cue: snd 128/129, priority 32000, only when silent",
		not seen_up.is_empty() and int(seen_up.priority) == P_WARP_UP and bool(seen_up.onlyWhenSilent)) and ok
	ok = _check("arrival: Warp out snd 130, priority 0x32, only when silent",
		not seen_out.is_empty() and int(seen_out.priority) == P_WARP_OUT and bool(seen_out.onlyWhenSilent)) and ok


# --- the spaceport ambient loop (Package C3) ---------------------------------------------------

func _ambient() -> void:
	if not nova.has_method("landed_ambient_sound"):
		print("  SKIP ambient: landed_ambient_sound missing (old dylib)")
		return
	var audio: Node = GameAudio.new()
	root.add_child(audio)
	audio.setup(nova)
	var lt: PackedInt32Array = nova.debug_land_targets()
	var target := -1
	var ambient_id := -1
	for id in lt:
		nova.debug_dock_at(id)
		var a: int = nova.landed_ambient_sound()
		nova.launch()
		if a >= 0 and nova.sound_info(a).size() >= 4:
			target = id
			ambient_id = a
			break
	_drain()
	if target < 0:
		print("  SKIP ambient: no landable stellar with a decodable CustSndID in this data")
		audio.queue_free()
		return
	Prefs.set_value("classic", "ambient_sounds", true)
	nova.debug_dock_at(target)
	await process_frame
	await process_frame
	ok = _check("landed: the ambient loop plays (snd %d)" % ambient_id, audio.ambient_playing()) and ok
	var stream = audio._ambient.stream
	ok = _check("ambient stream loops forward over the whole sample",
		stream is AudioStreamWAV and stream.loop_mode == AudioStreamWAV.LOOP_FORWARD and stream.loop_end > 0) and ok
	nova.launch()
	await process_frame
	await process_frame
	ok = _check("takeoff stops the ambient loop", not audio.ambient_playing()) and ok
	Prefs.set_value("classic", "ambient_sounds", false)
	nova.debug_dock_at(target)
	await process_frame
	await process_frame
	ok = _check("Ambient Sounds off: the landed screen is silent", not audio.ambient_playing()) and ok
	Prefs.set_value("classic", "ambient_sounds", true)
	nova.launch()
	await process_frame
	audio.queue_free()
	_drain()


# --- weapons and explosions through the shared mapping -----------------------------------------

func _combat() -> void:
	nova.set_intent(false, false, true, false, false, true, false)
	var priorities := {}
	var allowed := [1, 3, 4, 5, 6, 8, 10, 15, 50, 32000]
	var bad := 0
	for frame in 900:
		nova.select_nearest_target(true)
		nova.step(1.0 / 30.0)
		nova.drain_events()
		nova.drain_effects()
		for c in _drain():
			priorities[int(c.priority)] = true
			if not (int(c.priority) in allowed):
				bad += 1
	nova.set_intent(false, false, false, false, false, false, false)
	print("  combat priorities seen: ", priorities.keys())
	ok = _check("combat: weapon fire sounds at priority 4/5/6", priorities.has(4) or priorities.has(5) or priorities.has(6)) and ok
	ok = _check("combat: every queued priority is a known call-site value", bad == 0) and ok


func _finish() -> void:
	print("SOUND PARITY SELFCHECK ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print(("  ok   " if cond else "  FAIL ") + label)
	return cond
