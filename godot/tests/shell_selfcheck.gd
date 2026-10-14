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
	# This file checks the plain (Nova Swift) menus; classic_reskin_selfcheck covers the Classic ones.
	Prefs.set_value("presentation", "modern_menu", true)
	Prefs.set_value("presentation", "modern_dialogs", true)
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
		if b.text != "Multiplayer":   # the multiplayer entry is an optional add-on button
			mm_buttons.append(b.text)
	_ok(mm_buttons == ["Open Pilot", "New Pilot", "Settings", "Plug-ins", "Plugin Editor", "About Nova", "Quit"], "menu buttons: %s" % str(mm_buttons))
	var tm = shell.main_menu.music
	_ok(tm != null, "title music node exists (found track: '%s')" % tm.track_path)
	var track := TitleMusic.locate(shell.data_dir, nova.title_music_name())
	print("INFO title music name='%s' file='%s'" % [nova.title_music_name(), track])

	# --- open pilots and back -----------------------------------------------------
	var opener := root.gui_get_focus_owner()
	var menu_buttons: Array = shell.main_menu.find_children("*", "Button", true, false)
	shell._open_pilots(false)
	await process_frame
	await process_frame
	_ok(shell.pilot_menu != null and shell.main_menu.visible and shell.main_menu.is_inside_tree(), "Open Pilot stacks over the main menu: it stays in the tree and visible")
	_ok(menu_buttons.all(func(b): return b.focus_mode == Control.FOCUS_NONE), "...and is inert (no control under it can take focus)")
	_ok(root.gui_get_focus_owner() != null and shell.pilot_menu.is_ancestor_of(root.gui_get_focus_owner()), "focus moved into the pilot dialog")
	shell.pilot_menu._cancel()
	await process_frame
	await process_frame
	_ok(shell.pilot_menu == null and shell.main_menu.visible, "pilot menu Close returns to the main menu")
	_ok(menu_buttons.all(func(b): return b.focus_mode == Control.FOCUS_ALL), "...whose controls are live again")
	_ok(root.gui_get_focus_owner() == opener, "...and focus is back on the control that opened it (%s)" % (opener.text if opener else "none"))

	# --- settings: focus navigation -------------------------------------------------
	opener = root.gui_get_focus_owner()
	shell._open_settings(shell.main_menu)
	await process_frame
	await process_frame
	var st = shell.settings
	_ok(st != null and shell.main_menu.visible and shell.main_menu.is_inside_tree(), "Settings opens over the menu: the menu stays in the tree and visible")
	_ok(menu_buttons.all(func(b): return b.focus_mode == Control.FOCUS_NONE), "...and inert while Settings is up (no input / focus underneath)")
	fo = root.gui_get_focus_owner()
	_ok(fo == st.tab_buttons["Presentation"], "settings focus starts on the Interface sidebar entry")
	st.show_page("Audio")
	await process_frame
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
	var ed: Node = st.open_controls_editor()
	await process_frame
	_ok(ed.rows.size() >= 40, "Controls Editor lists %d actions" % ed.rows.size())
	var missing := []
	for g in Controls.GROUPS:
		for a in Controls.GROUPS[g]:
			if not Controls.BINDINGS.has(a):
				missing.append(a)
	_ok(missing.is_empty(), "every grouped action exists in BINDINGS " + str(missing))

	# --- rebinding -------------------------------------------------------------------
	_ok(_keys_of("land") == [KEY_L], "land default key is L")
	ed._on_row("land")
	_ok(ed.capture_event(_key(KEY_H)), "capture consumes a key")
	_ok(_keys_of("land") == [KEY_H], "InputMap: land now H")
	_ok(Controls.overrides["land"]["keys"] == [KEY_H], "override recorded")
	# conflict swap: give 'galaxy_map' (M) the key H -> land receives M
	ed._on_row("galaxy_map")
	ed.capture_event(_key(KEY_H))
	_ok(_keys_of("galaxy_map") == [KEY_H] and _keys_of("land") == [KEY_M], "conflict swaps: galaxy_map=H, land=M")
	# cancel with Esc
	ed._on_row("hyperjump")
	ed.capture_event(_key(KEY_ESCAPE))
	_ok(_keys_of("hyperjump") == [KEY_J], "Esc cancels a capture")
	# pad button
	ed.set_tab(1)
	ed._on_row("fire_primary")
	var jb := InputEventJoypadButton.new()
	jb.button_index = JOY_BUTTON_RIGHT_SHOULDER
	jb.pressed = true
	ed.capture_event(jb)
	var padbtns := []
	for e in InputMap.action_get_events("fire_primary"):
		if e is InputEventJoypadButton:
			padbtns.append(e.button_index)
	_ok(padbtns == [JOY_BUTTON_RIGHT_SHOULDER], "pad rebind lands in InputMap (RB)")
	_ok(ed.chip_text("fire_primary") == "RB", "row chip refreshed: " + ed.chip_text("fire_primary"))
	ed.close()
	await process_frame

	# --- persist + reload --------------------------------------------------------------
	st.close()
	await process_frame
	await process_frame
	_ok(shell.main_menu.visible and shell.settings == null, "closing settings restores the menu")
	_ok(menu_buttons.all(func(b): return b.focus_mode == Control.FOCUS_ALL) and root.gui_get_focus_owner() == opener, "...focus returns to the control that opened Settings")
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
	for b in shell.pause_menu.find_children("*", "BaseButton", true, false):
		pb.append(b.text)
	_ok(pb == ["", "Resume", "Galaxy Map", "Pilot Info", "Missions", "Story Guide", "Preferences", "Report Issue", "Full Screen", "Multiplayer", "Save Pilot", "Load Pilot", "Main Menu", "Quit Game"], "pause sidebar rows (Apple GameMenuView + Quit Game): " + str(pb))
	var pause_btns: Array = shell.pause_menu.find_children("*", "BaseButton", true, false)
	var pause_opener := root.gui_get_focus_owner()
	shell.pause_menu.sidebar_rows["Preferences"].grab_focus()
	pause_opener = shell.pause_menu.sidebar_rows["Preferences"]
	shell._open_settings(shell.pause_menu)
	await process_frame
	await process_frame
	_ok(shell.is_paused() and shell.pause_menu.visible and shell.pause_menu.is_inside_tree(), "settings stacks over the pause sidebar (it stays up, visible)")
	_ok(pause_btns.all(func(b): return b.focus_mode == Control.FOCUS_NONE), "...and the sidebar is inert underneath")
	shell.settings.close()
	await process_frame
	await process_frame
	_ok(shell.pause_menu.visible and pause_btns.all(func(b): return b.focus_mode == Control.FOCUS_ALL), "closing settings: the sidebar is live again")
	_ok(root.gui_get_focus_owner() == pause_opener, "...focus back on Preferences, the row that opened it")
	shell.close_pause()
	await process_frame
	_ok(not shell.is_paused() and resumed[0] == 1, "pause closes, resumed emitted")

	# --- data setup ---------------------------------------------------------------------------
	var had_data: bool = shell.has_data
	shell.has_data = false   # the no-data gate: the wizard can't be dismissed
	shell._open_data_setup(false)
	await process_frame
	await process_frame
	_ok(shell.in_menu() and shell.data_setup != null, "data setup opens")
	_ok(shell.data_setup.gated and shell.data_setup.step == "welcome", "gated wizard starts on the welcome page")
	fo = root.gui_get_focus_owner()
	_ok(fo != null, "data setup has a focused control")
	shell.data_setup.back.emit()
	_ok(shell.data_setup != null, "...and Esc/back can't dismiss it while gated")
	shell.data_setup._go("source")
	await process_frame
	_ok(not shell.data_setup.try_source("/nonexistent/path"), "bad path rejected")
	if nova.has_method("data_import_inspect_start"):
		_ok(shell.data_setup.try_source(shell.data_dir), "good folder accepted for inspection")
		for _i in 600:
			if not shell.data_setup.inspection.is_empty():
				break
			await process_frame
			OS.delay_msec(20)
		_ok(bool(shell.data_setup.inspection.get("valid", false)), "inspection validates the data folder")
	shell._close_data_setup()
	shell.has_data = had_data
	await process_frame
	_ok(OS.get_environment("HOME") == "" or Prefs.data_candidates().has(OS.get_environment("HOME").path_join(".local/share/NovaSwift/data")), "search includes ~/.local/share/NovaSwift/data")
	_ok(Prefs.data_candidates().has(ProjectSettings.globalize_path("user://data")), "search includes user://data")

	print("RESULT: ", "ALL PASS" if _fails == 0 else "%d FAIL" % _fails)
	quit(_fails)
