# Headless check of the app shell: main menu -> settings focus navigation, persist
# + reload a setting, rebind an action (InputMap reflects it, conflict swap),
# reset defaults, pause menu, data-setup, title-music lookup.
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/shell_selfcheck.gd
extends SceneTree

const Controls = preload("res://Controls.gd")
const Prefs = preload("res://Prefs.gd")
const Shell = preload("res://screens/Shell.gd")
const Settings = preload("res://screens/Settings.gd")
const TitleMusic = preload("res://audio/TitleMusic.gd")
const GameAudio = preload("res://audio/GameAudio.gd")

var _fails := 0


func _ok(cond: bool, what: String) -> void:
	print(("PASS " if cond else "FAIL ") + what)
	if not cond:
		_fails += 1


func _key(code: int) -> InputEventKey:
	var e := InputEventKey.new()
	e.physical_keycode = code
	e.pressed = true
	return e


func _keys_of(action: String) -> Array:
	var out := []
	for e in InputMap.action_get_events(action):
		if e is InputEventKey:
			out.append(e.physical_keycode)
	return out


func _init() -> void:
	Prefs.path = OS.get_user_data_dir() + "/shell_check_settings.cfg"
	DirAccess.remove_absolute(Prefs.path)
	Prefs.load_all()
	Controls.register()

	var nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	var audio = GameAudio.new()
	root.add_child(audio)
	audio.setup(nova)
	var shell = Shell.new()
	root.add_child(shell)
	shell.setup(nova, audio)

	# --- start: main menu with data ----------------------------------------------
	shell.start()
	await process_frame
	await process_frame
	_ok(shell.has_data and shell.main_menu != null, "start() with data opens the main menu (" + shell.data_dir + ")")
	_ok(shell.in_menu(), "in_menu() while the main menu is up")
	var fo := root.gui_get_focus_owner()
	_ok(fo != null and fo is Button and fo.text == "Open Pilot", "main menu focus lands on a button (%s)" % (fo.text if fo else "none"))
	var mm_buttons := []
	for b in shell.main_menu.find_children("*", "Button", true, false):
		mm_buttons.append(b.text)
	_ok(mm_buttons == ["Open Pilot", "New Pilot", "Settings", "Game Data…", "Quit"], "menu buttons: %s" % str(mm_buttons))
	var tm = shell.main_menu.music
	_ok(tm != null, "title music node exists (found track: '%s')" % tm.track_path)
	var track := TitleMusic.locate(shell.data_dir, nova.title_music_name())
	print("INFO title music name='%s' file='%s'" % [nova.title_music_name(), track])

	# --- open pilots and back -----------------------------------------------------
	shell._open_pilots(false)
	await process_frame
	_ok(shell.pilot_menu != null and not shell.main_menu.visible, "Open Pilot shows the pilot menu, hides main menu")
	shell.pilot_menu._cancel()
	await process_frame
	_ok(shell.pilot_menu == null and shell.main_menu.visible, "pilot menu Back returns to the main menu")

	# --- settings: focus navigation -------------------------------------------------
	shell._open_settings(shell.main_menu)
	await process_frame
	await process_frame
	var st = shell.settings
	_ok(st != null and not shell.main_menu.visible, "Settings opens over the menu")
	fo = root.gui_get_focus_owner()
	_ok(fo == st.tab_buttons["Audio"], "settings focus starts on the Audio tab")
	var master: HSlider = st.sliders["audio.master"]
	master.grab_focus()
	await process_frame
	_ok(root.gui_get_focus_owner() == master, "slider takes focus")
	# Simulated ui_right on a focused slider: HSlider steps its value.
	var before := master.value
	master.value = 0.5   # (parse_input_event is not delivered headless; drive the value)
	await process_frame
	_ok(is_equal_approx(float(Prefs.get_value("audio", "master")), 0.5) and before != 0.5, "slider change lands in Prefs (master 0.5)")
	_ok(is_equal_approx(audio.master_volume, 0.5), "changed -> apply_prefs pushes master volume into GameAudio")
	st.show_page("Video")
	await process_frame
	st.sliders["video.scale"].value = 1.5
	st.show_page("Controls")
	await process_frame
	st.sliders["input.deadzone"].value = 0.3
	_ok(is_equal_approx(Controls.stick_deadzone, 0.3), "dead zone is a runtime setting (0.3)")
	_ok(is_equal_approx(InputMap.action_get_deadzone("turn_left"), 0.3), "InputMap deadzone re-registered")

	# Focus walk on the Controls page: down from the tab reaches a control.
	var tab: Button = st.tab_buttons["Controls"]
	tab.grab_focus()
	var n := tab.find_valid_focus_neighbor(SIDE_BOTTOM)
	_ok(n != null, "tab has a focus neighbour below (%s)" % (n.name if n else "none"))
	_ok(st.rebind_buttons.size() >= 40, "Controls page lists %d actions" % st.rebind_buttons.size())
	var missing := []
	for g in Controls.GROUPS:
		for a in Controls.GROUPS[g]:
			if not Controls.BINDINGS.has(a):
				missing.append(a)
	_ok(missing.is_empty(), "every grouped action exists in BINDINGS " + str(missing))

	# --- rebinding -------------------------------------------------------------------
	_ok(_keys_of("land") == [KEY_L], "land default key is L")
	st._begin_capture("land", "keys", st.rebind_buttons["land"].key)
	_ok(st.capture_event(_key(KEY_H)), "capture consumes a key")
	_ok(_keys_of("land") == [KEY_H], "InputMap: land now H")
	_ok(Controls.overrides["land"]["keys"] == [KEY_H], "override recorded")
	# conflict swap: give 'galaxy_map' (M) the key H -> land receives M
	st._begin_capture("galaxy_map", "keys", st.rebind_buttons["galaxy_map"].key)
	st.capture_event(_key(KEY_H))
	_ok(_keys_of("galaxy_map") == [KEY_H] and _keys_of("land") == [KEY_M], "conflict swaps: galaxy_map=H, land=M")
	# cancel with Esc
	st._begin_capture("hyperjump", "keys", st.rebind_buttons["hyperjump"].key)
	st.capture_event(_key(KEY_ESCAPE))
	_ok(_keys_of("hyperjump") == [KEY_J], "Esc cancels a capture")
	# pad button
	st._begin_capture("fire_primary", "buttons", st.rebind_buttons["fire_primary"].pad)
	var jb := InputEventJoypadButton.new()
	jb.button_index = JOY_BUTTON_RIGHT_SHOULDER
	jb.pressed = true
	st.capture_event(jb)
	var padbtns := []
	for e in InputMap.action_get_events("fire_primary"):
		if e is InputEventJoypadButton:
			padbtns.append(e.button_index)
	_ok(padbtns == [JOY_BUTTON_RIGHT_SHOULDER], "pad rebind lands in InputMap (RB)")
	_ok(st.rebind_buttons["fire_primary"].pad.text == "Pad: RB", "row text refreshed: " + st.rebind_buttons["fire_primary"].pad.text)

	# --- persist + reload --------------------------------------------------------------
	st.close()
	await process_frame
	_ok(shell.main_menu.visible and shell.settings == null, "closing settings restores the menu")
	var cfg := ConfigFile.new()
	_ok(cfg.load(Prefs.path) == OK, "settings.cfg written")
	_ok(is_equal_approx(float(cfg.get_value("audio", "master")), 0.5), "cfg: audio.master=0.5")
	_ok(is_equal_approx(float(cfg.get_value("video", "scale")), 1.5), "cfg: video.scale=1.5")
	_ok(cfg.get_value("keys", "land", {}).get("keys", []) == [KEY_M], "cfg: land key override saved")
	Controls.overrides = {}
	Controls.stick_deadzone = 0.15
	Prefs.load_all()
	Controls.register()
	_ok(is_equal_approx(float(Prefs.get_value("audio", "master")), 0.5), "reload: master 0.5")
	_ok(is_equal_approx(Controls.stick_deadzone, 0.3), "reload: dead zone 0.3")
	_ok(_keys_of("galaxy_map") == [KEY_H] and _keys_of("land") == [KEY_M], "reload: rebinds re-applied by register()")

	# --- reset defaults ------------------------------------------------------------------
	shell._open_settings(shell.main_menu)
	await process_frame
	st = shell.settings
	st.show_page("Controls")
	st._reset_page()
	await process_frame
	_ok(_keys_of("land") == [KEY_L] and _keys_of("galaxy_map") == [KEY_M], "Defaults restores bindings")
	_ok(is_equal_approx(Controls.stick_deadzone, 0.15), "Defaults restores dead zone")
	st.close()
	await process_frame

	# --- pause menu -------------------------------------------------------------------------
	_ok(InputMap.has_action("pause_menu"), "pause_menu action registered")
	shell.main_menu.queue_free()
	shell.main_menu = null
	await process_frame
	var resumed := [0]
	shell.resumed.connect(func(): resumed[0] += 1)
	shell.open_pause()
	await process_frame
	await process_frame
	_ok(shell.is_paused() and shell.pause_menu != null, "pause menu opens")
	fo = root.gui_get_focus_owner()
	_ok(fo != null and fo.text == "Resume", "pause focus on Resume")
	var pb := []
	for b in shell.pause_menu.find_children("*", "Button", true, false):
		pb.append(b.text)
	_ok(pb == ["Resume", "Settings", "Save & Quit to Menu", "Quit"], "pause buttons: " + str(pb))
	shell._open_settings(shell.pause_menu)
	await process_frame
	_ok(shell.is_paused() and not shell.pause_menu.visible, "settings over pause hides pause")
	shell.settings.close()
	await process_frame
	_ok(shell.pause_menu.visible, "closing settings re-shows pause")
	shell.close_pause()
	await process_frame
	_ok(not shell.is_paused() and resumed[0] == 1, "pause closes, resumed emitted")

	# --- data setup ---------------------------------------------------------------------------
	shell._open_data_setup(false)
	await process_frame
	await process_frame
	_ok(shell.in_menu() and shell.data_setup != null, "data setup opens")
	fo = root.gui_get_focus_owner()
	_ok(fo != null and fo.text == "Choose Folder…", "data setup focus on the folder picker")
	_ok(not shell.data_setup.try_dir("/nonexistent/path"), "bad folder rejected")
	var found := [""]
	shell.data_loaded.connect(func(d): found[0] = d)
	_ok(shell.data_setup.try_dir(shell.data_dir), "good folder accepted")
	await process_frame
	_ok(found[0] == shell.data_dir and str(Prefs.get_value("data", "dir")) == shell.data_dir, "chosen path persisted in settings")
	_ok(shell.main_menu != null, "after data found the main menu opens")
	_ok(OS.get_environment("HOME") == "" or Prefs.data_candidates().has(OS.get_environment("HOME").path_join(".local/share/NovaSwift/data")), "search includes ~/.local/share/NovaSwift/data")
	_ok(Prefs.data_candidates().has(ProjectSettings.globalize_path("user://data")), "search includes user://data")

	print("RESULT: ", "ALL PASS" if _fails == 0 else "%d FAIL" % _fails)
	quit(_fails)
