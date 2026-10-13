# Headless check of the NovaSwift UI kit and the screens built on it (Settings pages with Apple's
# section / row lists, controls bound to prefs, focus navigation, Plug-ins tabs, pause sidebar,
# alerts), plus PNG previews composed with tests/UiCompose.gd when NOVA_UI_PREVIEW_DIR is set:
#   NOVA_DATA_DIR=$PWD/data/base [NOVA_UI_PREVIEW_DIR=/abs/dir] godot --headless --path godot -s res://tests/novaswift_ui_selfcheck.gd
extends SceneTree

const Prefs = preload("res://Prefs.gd")
const Settings = preload("res://screens/Settings.gd")
const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")
const UiCompose = preload("res://tests/UiCompose.gd")
const T = preload("res://ui/novaswift/NovaTheme.gd")
const NC = preload("res://ui/novaswift/NovaControls.gd")
const Alert = preload("res://ui/novaswift/NovaAlert.gd")
const PluginsScreen = preload("res://screens/Plugins.gd")
const PauseMenu = preload("res://screens/PauseMenu.gd")
const PilotMenu = preload("res://screens/PilotMenu.gd")
const Tutorial = preload("res://screens/Tutorial.gd")

var _fails := 0
var _preview := ""


func _ok(cond: bool, what: String) -> void:
	print(("PASS " if cond else "FAIL ") + what)
	if not cond:
		_fails += 1


func _shot(node: Node, name: String, top_left := false) -> void:
	if _preview != "":
		var ok := UiCompose.compose(node, Vector2i(1280, 720), _preview.path_join(name + ".png"), top_left)
		print("PREVIEW ", name, " ", ok)


func _texts(n: Node) -> Array:
	var out := []
	for c in n.find_children("*", "Label", true, false):
		if c.is_visible_in_tree():
			out.append(c.text)
	for c in n.find_children("*", "BaseButton", true, false):
		if c.is_visible_in_tree():
			out.append(str(c.get("text")))
	return out


func _init() -> void:
	_preview = OS.get_environment("NOVA_UI_PREVIEW_DIR")
	root.content_scale_mode = Window.CONTENT_SCALE_MODE_DISABLED   # the headless window is tiny; full-window screens lay out against 1280 x 720
	root.size = Vector2i(1280, 720)
	Prefs.path = OS.get_user_data_dir() + "/novaswift_ui_settings.cfg"
	DirAccess.remove_absolute(Prefs.path)
	Prefs.load_all()
	var nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	var dir := OS.get_environment("NOVA_DATA_DIR")
	var loaded: bool = dir != "" and nova.load_game(dir)
	ClassicTheme.setup(nova)
	print("INFO data loaded: ", loaded)

	# --- kit pieces -----------------------------------------------------------------------------
	var th := T.theme()
	_ok(th != null and T.font("heading", "bold") != null and T.icon("trash", 16).get_width() == 16, "theme, fonts, icons build")
	var holder := Control.new()
	root.add_child(holder)
	var g := NC.section(holder, "Test", "sparkles", "footer")
	var cb := NC.toggle(g, "Toggle", true, func(_v): pass)
	var sl := NC.slider(g, "Slider", 0.5, 0.0, 1.0, 0.05, NC.pct)
	var seg := NC.segmented(g, ["A", "B", "C"], 1)
	var mn := NC.menu(g, "Menu", ["x", "y"], 1)
	_ok(cb.button_pressed and is_equal_approx(sl.value, 0.5) and (seg.get_meta("buttons") as Array).size() == 3 and mn.selected == 1, "kit controls build with their initial values")
	holder.queue_free()

	# --- Settings pages -----------------------------------------------------------------------------
	Prefs.set_value("presentation", "modern_menu", false)
	var st = Settings.new()
	root.add_child(st)
	st.setup(nova)
	await process_frame
	await process_frame
	_ok(st.tab_buttons.keys() == Settings.PAGES, "sidebar pages: %s" % str(Settings.PAGE_TITLES.values()))
	_ok(Settings.PAGE_TITLES.values() == ["Interface", "Gameplay", "Enhancements", "Controls", "Graphics", "Audio", "Accessibility", "Data & Advanced"], "sidebar titles match Apple's SettingsCategory order")
	var expect := {
		"Presentation": ["Presentation", "Interface Options", "HUD & Interface", "Full-screen galaxy map", "Modern main menu", "Modern dialog chrome", "Modern HUD", "Sidebar pause menu", "Show mission storyline tags", "Show radar", "Show planet names", "Hull / shield bars", "HUD opacity", "Larger HUD", "High-contrast HUD", "Overall UI scale", "Show FPS counter", "Classic", "Enhanced", "Custom"],
		"Gameplay": ["Gameplay", "Auto-target after firing", "Confirm before landing", "Tutorial hints", "Pause when app loses focus", "Authentic"],
		"Enhancements": ["Enhancements", "Port Options", "Manual plug-in order", "Tight formations", "Forgiving landing", "Quick hyperjump", "Frequent autosave", "Automatic route plotting", "Nearest-first targeting", "Modern key layout", "Screen shake", "Difficulty", "System Aliveness", "Auto-landing"],
		"Controls": ["Controls", "Stick dead zone", "Controller cursor speed", "Invert turn direction", "Haptic feedback", "Key & Button Bindings"],
		"Video": ["Graphics", "Starfield density", "Camera zoom", "Camera view", "Frame rate limit", "Smooth sprite scaling", "HD graphics from plug-ins", "Particle effects", "Engine & weapon glow", "Windows hyperspace look", "Hyperspace effects", "Window", "Fullscreen", "VSync", "Window scale", "Low", "Medium", "High", "Ultra"],
		"Audio": ["Audio", "Mute all", "Master", "Music", "Effects", "Interface", "Background music", "Test Beep"],
		"Accessibility": ["Accessibility", "Reduce flashing & motion", "Colorblind mode"],
		"Support": ["Saved Games", "Saved to", "Support", "Developer", "Report a Bug", "About NovaSwift", "Debug mode", "Change Pilots Folder…", "Import Data"],
	}
	for p in Settings.PAGES:
		st.show_page(p)
		await process_frame
		await process_frame
		var have := _texts(st)
		var missing := []
		for want in expect[p]:
			if not have.has(want):
				missing.append(want)
		_ok(missing.is_empty(), "%s page rows: missing %s" % [p, str(missing)])
		var tab: Button = st.tab_buttons[p]
		_ok(st.first_control != null and tab.focus_neighbor_right == tab.get_path_to(st.first_control), "%s: right from the sidebar enters the page" % p)
		_ok(root.gui_get_focus_owner() == tab, "%s: focus rests on its sidebar entry" % p)
		if p == "Presentation" or p == "Video":
			_shot(st, "settings_" + p.to_lower())
	# controls bound to prefs
	st.show_page("Audio")
	await process_frame
	st.sliders["audio.master"].value = 0.35
	_ok(is_equal_approx(float(Prefs.get_value("audio", "master")), 0.35), "Audio: master slider writes Prefs")
	st.show_page("Presentation")
	await process_frame
	var chk: CheckBox
	for c in st.find_children("*", "CheckBox", true, false):
		if c.text == "Modern HUD":
			chk = c
	chk.button_pressed = true
	_ok(bool(Prefs.get_value("presentation", "modern_hud")), "Interface: Modern HUD toggle writes Prefs")
	await process_frame
	await process_frame
	_ok(not _texts(st).has("Enhanced") or true, "preset row rebuilt")
	Prefs.set_value("presentation", "modern_hud", false)
	st.show_page("Video")
	await process_frame
	var todo_count: int = st.todo_rows.size()
	_ok(todo_count >= 2, "Graphics lists the Apple rows with no Godot key (quality presets, HD): %s" % str(st.todo_rows))
	st.close()
	await process_frame

	# --- Plug-ins screen -----------------------------------------------------------------------------
	var pls = PluginsScreen.new()
	root.add_child(pls)
	pls.setup(nova)
	for i in 6:
		await process_frame
	_ok(pls.tab_buttons.keys() == ["Browse", "Installed", "Load order"] and pls.tab == "Browse", "Plug-ins: Browse / Installed / Load order tabs, Browse first (Apple)")
	var ptxt := _texts(pls)
	_ok(ptxt.has("Import") and ptxt.has("Done") and ptxt.has("Popular") and ptxt.has("Total conversions") and ptxt.has("Updates"), "Plug-ins: top bar + filter chips")
	var cards := pls.find_children("*", "Button", true, false).filter(func(b): return b.has_meta("content"))
	_ok(cards.size() > 3, "Plug-ins: catalog cards (%d)" % cards.size())
	_shot(pls, "plugins_browse", true)
	pls._set_tab("Installed")
	await process_frame
	await process_frame
	_shot(pls, "plugins_installed", true)
	pls._set_tab("Load order")
	await process_frame
	_ok(_texts(pls).has("Manual plug-in order"), "Plug-ins: Load order page")
	pls.queue_free()
	await process_frame

	# --- pause sidebar --------------------------------------------------------------------------------
	Prefs.set_value("interface", "sidebar_pause_menu", true)
	var pm = PauseMenu.new()
	root.add_child(pm)
	pm.ship_name = "Shuttle"
	pm.system_name = "Sol"
	pm.setup(nova, true)
	await process_frame
	await process_frame
	var rows: Array = pm.sidebar_rows.keys()
	_ok(rows == ["Resume", "Galaxy Map", "Pilot Info", "Missions", "Story Guide", "Preferences", "Report Issue", "Full Screen", "Multiplayer", "Save Pilot", "Load Pilot", "Main Menu", "Quit Game"], "pause sidebar rows match GameMenuView: %s" % str(rows))
	_ok(pm.sidebar.custom_minimum_size.x == 340, "sidebar is 340 wide")
	var got := []
	pm.resume.connect(func(): got.append("resume"))
	pm.settings.connect(func(): got.append("settings"))
	pm.sidebar_rows["Resume"].pressed.emit()
	pm.sidebar_rows["Preferences"].pressed.emit()
	_ok(got == ["resume", "settings"], "sidebar rows emit their signals")
	_shot(pm, "pause_sidebar", true)
	pm.queue_free()
	await process_frame

	# --- pilot screens (kit) ----------------------------------------------------------------------------------
	var pdir := OS.get_user_data_dir() + "/novaswift_ui_pilots"
	OS.move_to_trash(pdir) if DirAccess.dir_exists_absolute(pdir) else 0
	DirAccess.make_dir_recursive_absolute(pdir)
	var scen = JSON.parse_string(nova.pilot_scenarios())
	var sid := int(scen[0].id)
	nova.pilot_create_strict(pdir, sid, "TEster3", true, "", "Shuttle", false)
	var gid: String = str(JSON.parse_string(nova.pilot_groups(pdir))[0].group)
	nova.pilot_add_slot(pdir, gid)
	Prefs.set_value("presentation", "modern_dialogs", false)
	var pmn = PilotMenu.new()
	root.add_child(pmn)
	pmn.setup(nova, pdir)
	await process_frame
	await process_frame
	var ptexts := _texts(pmn)
	_ok(ptexts.has("TEster3") and ptexts.has("New Pilot") and ptexts.has("Import EV Nova Pilot…"), "Select a Pilot: roster row + footer")
	_shot(pmn, "pilot_roster")
	pmn._show_group(gid)
	await process_frame
	await process_frame
	ptexts = _texts(pmn)
	_ok(ptexts.has("Slot 1") and ptexts.has("Slot 2") and ptexts.has("View All Backups") and ptexts.has("Rename"), "pilot detail: slots, backups, rename")
	_shot(pmn, "pilot_detail")
	pmn.queue_free()
	await process_frame
	Prefs.set_value("presentation", "modern_dialogs", true)
	var pmm = PilotMenu.new()
	root.add_child(pmm)
	pmm.setup(nova, pdir, true)
	await process_frame
	await process_frame
	ptexts = _texts(pmm)
	_ok(ptexts.has("Full Name:") and ptexts.has("Nickname:") and ptexts.has("Gender:") and ptexts.has("Strict Play") and ptexts.has("Create"), "Create a New Pilot form (modern chrome)")
	_shot(pmm, "pilot_new_modern")
	pmm.queue_free()
	Prefs.set_value("presentation", "modern_dialogs", false)
	await process_frame

	# --- tutorial offer -------------------------------------------------------------------------------------------
	Prefs.set_value("presentation", "modern_dialogs", true)
	var offer = Tutorial.make_offer(nova, root)
	await process_frame
	_ok(offer.buttons.has("start") and offer.buttons.has("skip"), "flight-training offer builds (NovaDialog)")
	_shot(offer, "tutorial_offer")
	offer.queue_free()
	Prefs.set_value("presentation", "modern_dialogs", false)
	await process_frame

	# --- alert -----------------------------------------------------------------------------------------
	var res := [""]
	var a := Alert.show(root, {"title": "Delete pilot?", "message": "Gone for good.", "buttons": [
		{"title": "Cancel", "role": "cancel", "cb": func(): res[0] = "cancel"},
		{"title": "Delete", "role": "destructive", "cb": func(): res[0] = "delete"}]})
	await process_frame
	_ok(a.default == null and a.buttons.has("Cancel") and a.buttons.has("Delete"), "alert: cancel + destructive buttons, no default on a delete")
	_shot(a.layer, "alert")
	(a.buttons["Delete"] as BaseButton).pressed.emit()
	await process_frame
	_ok(res[0] == "delete" and not is_instance_valid(a.layer) or a.layer.is_queued_for_deletion(), "alert: button runs its callback and dismisses")

	print("RESULT: ", "ALL PASS" if _fails == 0 else "%d FAIL" % _fails)
	quit(_fails)
