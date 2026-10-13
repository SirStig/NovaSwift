# Headless self-check for the 2026-10-13 closing pass (docs/reverse-engineering/FIDELITY_PLAN.md, "2026-10-13 closing
# pass (text, hints, Player Info, quotes, Apple fixes)"):
#   A. the new-pilot travel hint chain (STR# 2002 #22-31) through the bridge's debug_travel_hint_* seams, with the
#      original's texts read back from the data, not copied;
#   B. Controls.first_key_name (what the hints embed; "" when unbound);
#   C. Player Info: Tab / Shift-Tab cycle General -> Cargo -> Extras -> Honors (wrapping), Enter closes;
#   D. the spaceport ambient loop only starts for CustSndID >= 128 (0x00491f30).
# Groups that need a method the loaded bridge lacks report SKIP (an older dylib), not FAIL.
# Run:  NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/status_text_closing_selfcheck.gd
# Prints STATUS TEXT CLOSING SELFCHECK: PASS / FAIL.
extends SceneTree

const Controls = preload("res://Controls.gd")
const Prefs = preload("res://Prefs.gd")
const GameAudio = preload("res://audio/GameAudio.gd")

var main: Node
var nova: Object
var ok: bool = true


func _init() -> void:
	_run()


func _check(label: String, cond: bool, detail: String = "") -> bool:
	print(("  ok   " if cond else "  FAIL ") + label + ((" -- " + detail) if detail != "" else ""))
	if not cond:
		ok = false
	return cond


func _run() -> void:
	await process_frame
	var pilots: String = OS.get_user_data_dir() + "/status_text_closing_pilots"
	DirAccess.make_dir_recursive_absolute(pilots)
	OS.set_environment("NOVA_PILOTS_DIR", pilots)
	OS.set_environment("NOVA_SKIP_PILOT_MENU", "1")

	main = load("res://Main.tscn").instantiate()
	root.add_child(main)
	for i in 10:
		await process_frame
	nova = main.nova
	if not _check("Main built a world", nova != null and main._has_data):
		quit(1)
		return

	_hint_keys()
	_hints()
	await _player_info_tabs()
	await _ambient_gate()

	print("STATUS TEXT CLOSING SELFCHECK: " + ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)


# B. ---------------------------------------------------------------------------------------------

func _hint_keys() -> void:
	print("== key names the hints embed ==")
	_check("Land is bound to L", Controls.first_key_name("land") == OS.get_keycode_string(KEY_L),
		Controls.first_key_name("land"))
	_check("an action with no keyboard key names \"\" (the original's unbound expansion)",
		Controls.first_key_name("recall_fighters") == "")


# A. ---------------------------------------------------------------------------------------------

func _hints() -> void:
	print("== new-pilot travel hints (STR# 2002 #22-31; 0x00451f8f) ==")
	if not (nova.has_method("debug_travel_hint_state") and nova.has_method("set_hint_key_names")):
		print("  SKIP hints: the bridge predates the travel hint chain")
		return
	var strs: PackedStringArray = nova.classic_strings(2002)
	nova.set_hint_key_names("L", "M", "J")
	nova.debug_travel_hint_begin()
	_check("a created pilot starts at -3", int(nova.debug_travel_hint_state()) == -3)
	# Near a landing planet: #23 + stellar + #24 + the Land key + #25.
	var welcome: String = str(nova.debug_travel_hint_eval(0.0, false))
	var expect_welcome: String = strs[22] + " Earth " + strs[23] + "L" + strs[24]
	_check("the welcome hint is #23 + stellar + #24 + key + #25", welcome == expect_welcome, welcome)
	_check("... and moves the state to -2", int(nova.debug_travel_hint_state()) == -2)
	# A launch below state 3 is silent and re-arms the hyperspace hint (the original's quirk).
	_check("launch below state 3 shows no launch line", not bool(nova.debug_travel_hint_launch()))
	_check("... and resets the state to -1", int(nova.debug_travel_hint_state()) == -1)
	var hyper: String = str(nova.debug_travel_hint_eval(0.0, false))
	_check("the hyperspace hint is #26 + map key + #27 + jump key + #28",
		hyper == strs[25] + "M" + strs[26] + "J" + strs[27], hyper)
	_check("... and moves the state to 0", int(nova.debug_travel_hint_state()) == 0)
	_check("every further launch before a jump re-arms it", not bool(nova.debug_travel_hint_launch())
		and int(nova.debug_travel_hint_state()) == -1)
	nova.debug_travel_hint_eval(0.0, false)   # back to 0
	_check("inside 2,000,000 nothing shows", str(nova.debug_travel_hint_eval(1900000.0, false)) == "")
	_check("a disabled ship gets no range hint", str(nova.debug_travel_hint_eval(3000000.0, true)) == "")
	_check("beyond 2,000,000: #30, state 1", str(nova.debug_travel_hint_eval(3000000.0, false)) == strs[29]
		and int(nova.debug_travel_hint_state()) == 1)
	_check("state 1 waits for 10,000,000", str(nova.debug_travel_hint_eval(9000000.0, false)) == "")
	_check("beyond 10,000,000: #31, state 2", str(nova.debug_travel_hint_eval(11000000.0, false)) == strs[30]
		and int(nova.debug_travel_hint_state()) == 2)
	nova.debug_travel_hint_latch()
	_check("a latched state shows the launch line again", bool(nova.debug_travel_hint_launch()))


# C. ---------------------------------------------------------------------------------------------

func _tab_event(shift: bool) -> InputEventKey:
	var ev: InputEventKey = InputEventKey.new()
	ev.keycode = KEY_TAB
	ev.physical_keycode = KEY_TAB
	ev.shift_pressed = shift
	ev.pressed = true
	return ev


func _player_info_tabs() -> void:
	print("== Player Info Tab / Shift-Tab (0x00499c10, callback 0x0049a3a0) ==")
	var story: Node = main._story
	if story == null or not story.has_method("open_info") or not story.has_method("_cycle_info_tab"):
		print("  SKIP player info: no story screens")
		return
	story.open_info("general")
	await process_frame
	_check("opens on General", story._info_tab == "general" and story._info != null)
	story._input(_tab_event(false))
	await process_frame
	_check("Tab -> Cargo", story._info_tab == "cargo", story._info_tab)
	story._input(_tab_event(false))
	await process_frame
	story._input(_tab_event(false))
	await process_frame
	_check("Tab, Tab -> Honors", story._info_tab == "honors", story._info_tab)
	story._input(_tab_event(false))
	await process_frame
	_check("Tab wraps to General", story._info_tab == "general", story._info_tab)
	story._input(_tab_event(true))
	await process_frame
	_check("Shift-Tab wraps back to Honors", story._info_tab == "honors", story._info_tab)
	var enter: InputEventKey = InputEventKey.new()
	enter.keycode = KEY_ENTER
	enter.physical_keycode = KEY_ENTER
	enter.pressed = true
	story._input(enter)
	await process_frame
	_check("Enter closes the window", story._info == null)


# D. ---------------------------------------------------------------------------------------------

func _ambient_gate() -> void:
	print("== spaceport ambient: CustSndID >= 128 only ==")
	var audio: Node = GameAudio.new()
	root.add_child(audio)
	audio.setup(nova)
	Prefs.set_value("classic", "ambient_sounds", true)
	audio.start_ambient(100)
	_check("an id below 128 starts no loop", not audio.ambient_playing())
	audio.queue_free()
