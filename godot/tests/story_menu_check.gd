# Headless drive of the story screens' focus navigation and input handling: the
# landing mission offer (modal, owns input), the Mission BBS (list focus, stepping
# presents a listing, accept action, reopen), the Bar + Holovid, and the Player /
# Mission Info window. Run like story_selfcheck.gd. Prints STORY MENU CHECK: PASS / FAIL.
extends SceneTree

const Spaceport = preload("res://screens/Spaceport.gd")
const StoryScreens = preload("res://screens/StoryScreens.gd")
const Controls = preload("res://Controls.gd")
var ok := true
var launches := 0
var nova


func _check(label: String, cond: bool, detail := "") -> void:
	print(("  ok   " if cond else "  FAIL ") + label + ((" — " + detail) if detail != "" else ""))
	if not cond:
		ok = false


func _key(action: String) -> void:
	var e := InputEventAction.new()
	e.action = action
	e.pressed = true
	root.push_input(e)


func _frames(n := 3) -> void:
	for i in n:
		await process_frame


func _focus_text() -> String:
	var f = root.gui_get_focus_owner()
	return "" if f == null else (f.text if "text" in f else str(f))


# Read every pending story text, as a player pressing OK.
func _clear_texts(ss) -> int:
	var n := 0
	while nova.story_text_pending() or ss._modal != null:
		await _frames(2)
		if ss._modal != null:
			_key("ui_cancel")
			await _frames(2)
			n += 1
		if n > 12:
			break
	return n


func _init() -> void:
	Controls.register()
	nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	var data := OS.get_environment("NOVA_DATA_DIR")
	if data == "":
		data = ProjectSettings.globalize_path("res://") + "../data/base"
	nova.load_game(data)
	var scen = JSON.parse_string(nova.pilot_scenarios())
	nova.pilot_create(OS.get_user_data_dir() + "/story_menucheck", int(scen[0].id), "Menu Tester", true, "", "")
	nova.make_world(-1)
	nova.step(1.0 / 30.0)
	_check("land", nova.attempt_land())

	var sp = Spaceport.new()
	root.add_child(sp)
	sp.setup(nova)
	sp.launch_requested.connect(func(): launches += 1)
	var ss = StoryScreens.new()
	root.add_child(ss)
	ss.setup(nova)
	ss.close_spaceport_screen.connect(sp.story_close_screen)
	sp.open()   # the landing roll offers the main spaceport's next mission
	await _frames()

	# --- landing offer: a modal that owns input
	if ss._modal != null:
		_check("offer dialog: a button has focus", root.gui_get_focus_owner() is Button, _focus_text())
		var before := launches
		_key("launch")   # L must not launch the spaceport underneath
		await _frames()
		_check("offer dialog: underlying spaceport ignores launch", launches == before and ss._modal != null)
		_key("ui_down")
		await _frames()
		_check("offer dialog: focus stays inside", ss._modal_buttons.has(root.gui_get_focus_owner()))
		_key("ui_cancel")   # refuse (or nothing if it can't be refused)
		await _frames()
		if ss._modal != null:
			root.gui_get_focus_owner().pressed.emit()
			await _frames()
		_check("offer dialog: closes", ss._modal == null and not nova.offer_pending())
	else:
		print("  (no landing offer this time)")
	await _clear_texts(ss)
	_check("hub focuses a service button", sp._screen == "hub" and root.gui_get_focus_owner() is Button, _focus_text())
	_check("no launch yet", launches == 0)

	# --- Mission BBS
	sp._open_bbs()
	await _frames()
	_check("BBS opens", sp._screen == "bbs")
	var listings: Array = sp._bbs_list
	_check("BBS has listings", listings.size() > 0)
	if listings.size() > 0:
		_check("BBS: a listing has focus and is shown", root.gui_get_focus_owner() is Button and sp._bbs_nodes.title.text != "",
			sp._bbs_nodes.title.text)
		_check("BBS: accept enabled", not sp._bbs_nodes.accept.disabled)
		if listings.size() > 1:
			var t0: String = sp._bbs_nodes.title.text
			_key("ui_down")
			await _frames()
			_check("BBS: ui_down presents the next listing", sp._bbs_nodes.title.text != t0,
				"%s -> %s" % [t0, sp._bbs_nodes.title.text])
		var active0: int = JSON.parse_string(nova.mission_list()).size()
		_key("bbs_accept")
		await _frames(3)
		await _clear_texts(ss)
		await _frames(3)
		var active1: int = JSON.parse_string(nova.mission_list()).size()
		_check("BBS: accept action takes the mission", active1 == active0 + 1, "%d -> %d" % [active0, active1])
		_check("BBS: reopens afresh or closes", sp._screen == "bbs" or sp._screen == "hub", sp._screen)
	if sp._screen == "bbs":
		_key("ui_cancel")
		await _frames()
	_check("BBS: ui_cancel -> landing screen", sp._screen == "hub")

	# --- Bar and Holovid
	sp._show_bar()
	await _frames()
	_check("bar: a button has focus", root.gui_get_focus_owner() is Button, _focus_text())
	root.gui_get_focus_owner().pressed.emit()   # Holovid
	await _frames()
	_check("bar: Holovid overlay opens", sp._overlay != null)
	_key("ui_cancel")
	await _frames()
	_check("bar: ui_cancel closes only the Holovid", sp._overlay == null and sp._screen == "bar")
	await create_timer(0.6).timeout
	await _frames()
	if ss._modal != null:
		print("  a patron made a pitch: modal up")
		_key("ui_cancel")
		await _frames()
		await _clear_texts(ss)
	_key("ui_cancel")
	await _frames()
	_check("bar: ui_cancel -> landing screen", sp._screen == "hub" and launches == 0)

	# --- Player Info / Mission Info
	ss.open_info("missions")
	await _frames()
	_check("info window opens with a focused button", ss._info != null and root.gui_get_focus_owner() is Button, _focus_text())
	var ms = JSON.parse_string(nova.mission_list())
	if ms.size() > 0:
		_check("info: missions tab lists the accepted mission", ss._info_sel == int(ms[0].id))
	_key("ui_cancel")
	await _frames()
	_check("info: ui_cancel closes", ss._info == null)
	ss.open_info("general")
	await _frames()
	_check("info: general tab builds", ss._info != null)
	ss.close_info()

	# --- finally B on the landing screen launches
	_key("ui_cancel")
	await _frames()
	_check("landing screen: ui_cancel (B) requests launch", launches == 1)
	print("STORY MENU CHECK: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
