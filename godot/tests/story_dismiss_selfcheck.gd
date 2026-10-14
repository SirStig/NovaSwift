# Soft-lock regression: a completion text over the spaceport must close on Enter even when the
# frontend pokes the bridge (buy_commodity / offer_roll / offer_state ...) in the following frames.
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/story_dismiss_selfcheck.gd
extends SceneTree

const Prefs = preload("res://Prefs.gd")
const Controls = preload("res://Controls.gd")
const T = preload("res://ui/classic/ClassicTheme.gd")
const Spaceport = preload("res://screens/Spaceport.gd")
const StoryScreens = preload("res://screens/StoryScreens.gd")

var nova
var fails := 0


func _ok(cond: bool, what: String, detail := "") -> void:
	print(("PASS " if cond else "FAIL ") + what + ((" -- " + detail) if detail != "" else ""))
	if not cond:
		fails += 1


func _frames(n := 3) -> void:
	for i in n:
		await process_frame


func _enter() -> void:
	for p in [true, false]:
		var e := InputEventKey.new()
		e.keycode = KEY_ENTER
		e.physical_keycode = KEY_ENTER
		e.pressed = p
		Input.parse_input_event(e)


func _dialogs(ss) -> int:
	var n := 0
	for c in ss.get_children():
		if c is Control and c.visible:
			n += 1
	return n


func _init() -> void:
	_run()


func _run() -> void:
	get_root().size = Vector2i(1280, 720)
	Prefs.path = OS.get_user_data_dir() + "/story_dismiss_settings.cfg"
	DirAccess.remove_absolute(Prefs.path)
	Prefs.load_all()
	Controls.register()
	nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	if not nova.load_game(OS.get_environment("NOVA_DATA_DIR")):
		print("FAIL no game data")
		quit(1)
		return
	T.setup(nova)
	var scen = JSON.parse_string(nova.pilot_scenarios())
	nova.pilot_create(OS.get_user_data_dir() + "/story_dismiss", int(scen[0].id), "Dismiss Tester", true, "", "")
	nova.make_world(-1)
	nova.step(1.0 / 30.0)
	var spob := -1
	for id in range(128, 1600):
		if nova.debug_dock_at(id) and nova.commodity_count() > 0:
			spob = id
			break
	_ok(spob >= 0, "docked at a stellar with a commodity exchange", str(spob))
	nova.debug_set_credits(100000)
	var sp = Spaceport.new()
	root.add_child(sp)
	sp.setup(nova)
	var ss = StoryScreens.new()
	root.add_child(ss)
	ss.setup(nova)
	sp.open()
	while nova.story_text_pending():
		nova.story_text_dismiss()
	if nova.offer_pending():
		nova.offer_decline()
	await _frames()

	# Queue a completion text: first mission that raises exactly one.
	var queued := false
	for mid in range(128, 900):
		nova.debug_complete_mission(mid)
		var n := 0
		while nova.story_text_pending() and n < 6:
			n += 1
			nova.story_text_dismiss()
		if n == 1:
			nova.debug_complete_mission(mid)     # re-complete: texts again
			if nova.story_text_pending():
				queued = true
				break
	_ok(queued, "a completion text is queued by the engine")
	await _frames(2)
	_ok(ss._modal != null and ss._modal_kind == "text", "StoryScreens shows it")

	await _frames(3)
	_enter()
	nova.buy_commodity(0, 10)
	nova.commodity_held(0)
	nova.player_credits()
	_ok(nova.offer_roll("bbs") == 0, "offer_roll(\"bbs\") (unknown context) is a harmless 0")
	nova.offer_state()
	await _frames(4)
	_ok(not nova.story_text_pending(), "engine text consumed by Enter")
	_ok(ss._modal == null, "no modal left in StoryScreens")
	_ok(_dialogs(ss) == 0, "no visible dialog node left under StoryScreens", str(_dialogs(ss)))
	_ok(not ss.blocks_flight(), "StoryScreens does not block")
	_ok(not nova.story_blocks_flight(), "engine does not block")

	# Engine text vanishing under a live dialog closes it.
	nova.debug_complete_mission(130)
	for mid in range(128, 700):
		nova.debug_complete_mission(mid)
		if nova.story_text_pending():
			break
	await _frames(2)
	if nova.story_text_pending():
		_ok(ss._modal != null, "second text shown")
		while nova.story_text_pending():
			nova.story_text_dismiss()     # engine drops it behind the dialog
		await _frames(3)
		_ok(ss._modal == null and _dialogs(ss) == 0, "dialog closed itself when its engine text disappeared")
	# Never two dialogs, even when the open path fires twice (movie finished + skipped).
	var t := {"title": "", "text": "dup", "pict": -1}
	ss._open_text_classic(t)
	ss._open_text_classic(t)
	var hosts := 0
	for c in ss.get_children():
		if c.is_in_group("story_modal_host"):
			hosts += 1
	_ok(hosts == 1, "re-opening replaces the dialog instead of stacking", str(hosts))
	ss._modal_from_engine = true
	await _frames(2)
	_ok(ss._modal == null, "an engine-less text dialog closes itself")
	ss._open_text_classic(t)
	ss._modal_cancel = Callable()      # a dead cancel Callable
	ss._modal_kind = "text"
	var e := InputEventAction.new()
	e.action = "ui_cancel"
	e.pressed = true
	Input.parse_input_event(e)
	await _frames(3)
	_ok(ss._modal == null and _dialogs(ss) == 0, "Esc still closes a text whose cancel Callable is dead")
	print("DONE fails=", fails)
	quit(1 if fails > 0 else 0)
