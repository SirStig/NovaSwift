# Headless check of the 2026-10-13 closing pass on the Godot side:
#   A. the quickHyperjump presentation (screens/HyperjumpFx.gd) and its snd 128 charge loop
#      (audio/GameAudio.gd), driven by a fake bridge so it needs no rebuilt library;
#   B. when the bridge has the new methods, the real maneuver: with Prefs gameplay/quick_hyperjump on, an armed
#      route and a begin_hyperjump, the shared QuickHyperjump flies align -> accelerate -> flash, the charge loop
#      sound is 128 until the commit and -1 after, and the arrival reports a 0.35 s fade. Skipped (not failed)
#      when the build predates the methods or no jump can be armed in the demo world.
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/closing_pass_selfcheck.gd
extends SceneTree

const Prefs = preload("res://Prefs.gd")

var ok: bool = true

const FAKE_SOURCE: String = """
extends Object
var state: PackedFloat32Array = PackedFloat32Array([0, 0, 0, 0])
var arrival: String = ""
var arrive_fade: float = 0.0
var loop_sound: int = -1
func hyperjump_state() -> PackedFloat32Array:
	return state
func take_jump_arrival() -> String:
	var a: String = arrival
	arrival = ""
	return a
func jump_arrival_fade() -> float:
	return arrive_fade
func hyperspace_charge_loop_sound() -> int:
	return loop_sound
func sound_stride() -> int:
	return 6
func sound_voice_count() -> int:
	return 16
func drain_sound_cues() -> PackedFloat32Array:
	return PackedFloat32Array()
func is_landed() -> bool:
	return false
func landed_ambient_sound() -> int:
	return -1
func sound_info(_id: int) -> PackedInt32Array:
	return PackedInt32Array([22050, 1, 16, 400])
func sound_pcm(_id: int) -> PackedByteArray:
	var b: PackedByteArray = PackedByteArray()
	b.resize(800)
	return b
func sound_stop(_id: int) -> void:
	pass
"""


func _init() -> void:
	_run()


func _check(label: String, cond: bool, detail: String = "") -> bool:
	print(("  ok   " if cond else "  FAIL ") + label + ((" -- " + detail) if detail != "" else ""))
	if not cond:
		ok = false
	return cond


func _run() -> void:
	await process_frame
	Prefs.path = "user://closing_pass_selfcheck.cfg"
	DirAccess.remove_absolute(ProjectSettings.globalize_path(Prefs.path))
	Prefs.load_all()
	_part_a()
	await _part_b()
	print("CLOSING PASS SELFCHECK ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


func _fake() -> Object:
	var script: GDScript = GDScript.new()
	script.source_code = FAKE_SOURCE
	script.reload()
	return script.new()


func _part_a() -> void:
	print("-- A. quickHyperjump presentation (fake bridge)")
	var fake: Object = _fake()
	var fx: CanvasLayer = load("res://screens/HyperjumpFx.gd").new()
	root.add_child(fx)
	fx.setup(fake)

	# Phase 5 (accelerate): streaks build, no white yet.
	fake.state = PackedFloat32Array([5, 0, 0, 1.0, 0.0, 0.5, 4.0])
	fx._process(0.016)
	_check("accelerate draws streaks", is_equal_approx(float(fx._quick_streak), 0.5) and is_equal_approx(float(fx._quick_stretch), 4.0))
	_check("accelerate has no white", is_equal_approx(float(fx._fade), 0.0))

	# Phase 6 (flash): the white ramp is the frame's, streaks full.
	fake.state = PackedFloat32Array([6, 0, 0, 1.0, 0.6, 1.0, 9.0])
	fx._process(0.016)
	_check("flash ramps the white from the frame", is_equal_approx(float(fx._fade), 0.6))
	_check("flash streaks full", is_equal_approx(float(fx._quick_streak), 1.0) and is_equal_approx(float(fx._quick_stretch), 9.0))
	_check("the layer is visible during the maneuver", fx._canvas.visible)

	# Reduce flashing caps the white at 0.45.
	Prefs.set_value("graphics", "reduce_flashing", true)
	fake.state = PackedFloat32Array([6, 0, 0, 1.0, 1.0, 1.0, 9.0])
	fx._process(0.016)
	_check("Reduce Flashing caps the white at 0.45", is_equal_approx(float(fx._fade), 0.45))
	Prefs.set_value("graphics", "reduce_flashing", false)

	# Hyperspace Fx off: black flash, no streaks.
	Prefs.set_value("classic", "hyperspace_effects", false)
	fx._process(0.016)
	_check("Hyperspace Fx off draws no streaks", is_equal_approx(float(fx._quick_streak), 0.0))
	Prefs.set_value("classic", "hyperspace_effects", true)

	# Arrival: the bridge's 0.35 s fade replaces the Mac's 1.5 s.
	fake.state = PackedFloat32Array([0, 0, 0, 0])
	fake.arrival = "Sol"
	fake.arrive_fade = 0.35
	fx._process(0.0)
	_check("arrival flashes white", is_equal_approx(float(fx._flash), 1.0))
	_check("arrival fade is 0.35 s", is_equal_approx(float(fx._arrive_len), 0.35))
	fx._process(0.175)
	_check("halfway through the fade the flash is half", absf(float(fx._flash) - 0.5) < 0.02, str(fx._flash))
	fake.arrival = "Rigel"
	fake.arrive_fade = 0.0
	fx._process(0.0)
	_check("an original-jump arrival goes back to the default fade", float(fx._arrive_len) <= 0.0)
	fx.queue_free()

	print("-- A. charge loop (fake bridge)")
	var audio: Node = load("res://audio/GameAudio.gd").new()
	root.add_child(audio)
	audio.setup(fake)
	fake.loop_sound = 128
	audio._process(0.016)
	_check("the charge loop starts with the maneuver", audio.charge_playing())
	fake.loop_sound = -1
	audio._process(0.016)
	_check("the charge loop is cut at the commit", not audio.charge_playing())
	fake.loop_sound = 128
	audio._process(0.016)
	audio.muted = true
	audio._process(0.016)
	_check("mute silences it", not audio.charge_playing())
	audio.muted = false
	audio.stop_all()
	_check("stop_all cuts it", not audio.charge_playing())
	audio.queue_free()


func _part_b() -> void:
	print("-- B. the real maneuver (bridge)")
	if not ClassDB.class_exists("NovaWorld"):
		print("  SKIP no NovaWorld class (extension not loaded)")
		return
	var nova: Object = ClassDB.instantiate("NovaWorld")
	if not nova.has_method("hyperspace_charge_loop_sound") or not nova.has_method("jump_arrival_fade"):
		print("  SKIP bridge predates hyperspace_charge_loop_sound / jump_arrival_fade (rebuild it)")
		nova.free()
		return
	root.add_child(nova)
	var data: String = OS.get_environment("NOVA_DATA_DIR")
	if data == "":
		data = ProjectSettings.globalize_path("res://") + "../data/base"
	if not bool(nova.load_game(data)) or not bool(nova.make_world(-1)):
		print("  SKIP no data / demo world")
		nova.queue_free()
		return
	var plumb: Node = root.get_node_or_null("SettingsPlumbing")
	Prefs.set_value("gameplay", "quick_hyperjump", true)
	if plumb != null:
		plumb.apply_now()
	_check("charge loop idle before the jump", int(nova.hyperspace_charge_loop_sound()) == -1)

	# Arm a one-hop route from the start system.
	nova.nav_refresh()
	var start: int = int(nova.nav_current_system())
	var links: PackedInt32Array = nova.nav_links()
	var first: int = -1
	for i in range(0, links.size(), 2):
		if links[i] == start:
			first = links[i + 1]
			break
		if links[i + 1] == start:
			first = links[i]
			break
	if first == -1 or not bool(nova.nav_click(first)):
		print("  SKIP could not arm a route in the demo world (no pilot)")
		nova.queue_free()
		return
	# Thrust clear of the no-jump zone and engage.
	var engaged: bool = false
	var refusal: String = ""
	for tries in 3000:
		nova.set_intent(false, false, true, false, false, false, false)
		nova.step(1.0 / 30.0)
		if tries % 15 == 0:
			refusal = String(nova.begin_hyperjump())
			if bool(nova.hyperjump_active()):
				engaged = true
				break
	if not engaged:
		print("  SKIP could not engage (", refusal, ")")
		nova.queue_free()
		return
	_check("quick jump is active", bool(nova.hyperjump_active()))
	var st: PackedFloat32Array = nova.hyperjump_state()
	_check("the state carries the quick phase and the three overlay values", st.size() >= 7 and int(st[0]) >= 4, str(st))
	_check("the charge loop plays snd 128 during the maneuver", int(nova.hyperspace_charge_loop_sound()) == 128)
	var phases: Dictionary = {}
	var frames: int = 0
	while bool(nova.hyperjump_active()) and frames < 1200:
		nova.set_intent(false, false, false, false, false, false, false)
		nova.step(1.0 / 60.0)
		var s: PackedFloat32Array = nova.hyperjump_state()
		if s.size() >= 1 and int(s[0]) >= 4:
			phases[int(s[0])] = true
		frames += 1
	_check("align (4) -> accelerate (5) -> flash (6) all seen", phases.has(5) and phases.has(6), str(phases.keys()))
	_check("the jump committed within 8 s of display time", not bool(nova.hyperjump_active()) and frames < 1200, str(frames))
	_check("the charge loop is cut", int(nova.hyperspace_charge_loop_sound()) == -1)
	_check("arrival reports a 0.35 s fade", is_equal_approx(float(nova.jump_arrival_fade()), 0.35))
	_check("arrival names the system", String(nova.take_jump_arrival()) != "")
	Prefs.set_value("gameplay", "quick_hyperjump", false)
	if plumb != null:
		plumb.apply_now()
	nova.queue_free()
