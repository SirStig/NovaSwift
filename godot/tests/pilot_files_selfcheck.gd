# Headless check of pilots-as-files, the Apple-style Settings, the Classic Preferences window and the
# loading screen:
#   NOVA_DATA_DIR=$PWD/data/base NOVA_PILOTS_DIR=<scratch> godot --headless --path godot -s res://tests/pilot_files_selfcheck.gd
extends SceneTree

const Prefs = preload("res://Prefs.gd")
const Shell = preload("res://screens/Shell.gd")
const PilotFiles = preload("res://screens/PilotFiles.gd")
const PilotMenu = preload("res://screens/PilotMenu.gd")
const Settings = preload("res://screens/Settings.gd")
const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")
const GameAudio = preload("res://audio/GameAudio.gd")

var _fails := 0


func _ok(cond: bool, what: String) -> void:
	print(("PASS " if cond else "FAIL ") + what)
	if not cond:
		_fails += 1


## A minimal Windows .plt (plaintext blocks; same layout as the Swift importer's test encoder).
func _synthetic_plt(path: String) -> void:
	var b1 := PackedByteArray()
	b1.resize(0xE952)
	var b2 := PackedByteArray()
	b2.resize(0x66FE)
	b1.encode_u16(0x14, 3)
	b1.encode_u16(0x16, 14)
	b1.encode_u16(0x18, 1180)
	b1.encode_u32(0x281A, 123456)
	for i in 0x40:
		b1.encode_u16(0xE6CE + 2 * i, 0xFFFF)
		b1.encode_u16(0xE74E + 2 * i, 0xFFFF)
		b1.encode_u16(0xE8CE + 2 * i, 0xFFFF)
	b2.encode_u16(0, 300)
	b2.encode_u16(4, 1)
	for i in 0x200:
		b2.encode_u16(0x3590 + 2 * i, 0xFFFF)
		b2.encode_u16(0x3990 + 2 * i, 0xFFFF)
	for i in 0x400:
		b2.encode_u16(0x1006 + 2 * i, 1)
	for i in 4:
		b2.encode_u16(0x5D90 + 2 * i, 0xFFFF)
	var out := PackedByteArray()
	out.resize(4)
	out.encode_u32(0, b1.size())
	out.append_array(b1)
	var h := PackedByteArray()
	h.resize(4)
	h.encode_u32(0, b2.size())
	out.append_array(h)
	out.append_array(b2)
	out.append_array("Serenity".to_utf8_buffer())
	out.append(0)
	var f := FileAccess.open(path, FileAccess.WRITE)
	f.store_buffer(out)
	f.close()


func _wait(seconds: float) -> void:
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		await process_frame


func _init() -> void:
	var scratch := OS.get_user_data_dir() + "/pilot_files_check"
	_rm_rf(scratch)
	DirAccess.make_dir_recursive_absolute(scratch)
	Prefs.path = scratch + "/settings.cfg"
	Prefs.load_all()
	PilotFiles.legacy_dir = scratch + "/legacy"
	var pilots := scratch + "/Pilots"
	OS.set_environment("NOVA_PILOTS_DIR", pilots)

	var nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	var audio = GameAudio.new()
	root.add_child(audio)
	audio.setup(nova)
	var data := OS.get_environment("NOVA_DATA_DIR")
	if data == "":
		data = ProjectSettings.globalize_path("res://") + "../data/base"

	# --- the Pilots folder -------------------------------------------------------------
	_ok(PilotFiles.dir() == pilots and DirAccess.dir_exists_absolute(pilots), "NOVA_PILOTS_DIR picks the Pilots folder")
	OS.set_environment("NOVA_PILOTS_DIR", "")
	var def := PilotFiles.default_dir()
	print("INFO default Pilots folder on this machine: ", def)
	_ok(def.ends_with("Pilots"), "default folder is a visible 'Pilots' folder")
	DirAccess.remove_absolute(def)                 # (default_dir() created it; leave no trace)
	DirAccess.remove_absolute(def.get_base_dir())
	OS.set_environment("NOVA_PILOTS_DIR", pilots)

	_ok(nova.load_game(data), "load_game")
	var scen = JSON.parse_string(nova.pilot_scenarios())
	var id: String = nova.pilot_create(pilots, int(scen[0].id), "Ada Test", true, "", "")
	var file: String = nova.pilot_file_path(pilots, id)
	_ok(id != "" and FileAccess.file_exists(file) and file.get_base_dir() == pilots and file.ends_with(".evpilot"),
		"create -> %s appears in the Pilots folder" % file.get_file())

	# --- open from anywhere -------------------------------------------------------------
	var elsewhere := scratch + "/Downloads"
	DirAccess.make_dir_recursive_absolute(elsewhere)
	var copy := elsewhere + "/friend.evpilot"
	DirAccess.copy_absolute(file, copy)
	nova.pilot_delete(pilots, id)
	_ok(not FileAccess.file_exists(file), "pilot removed from the folder")
	var info = JSON.parse_string(nova.pilot_inspect_file(copy))
	_ok(info.kind == "evpilot" and info.name == "Ada Test", "inspect: native pilot file")
	var opened: String = nova.pilot_open_file(pilots, copy)
	_ok(opened == id and nova.pilot_name() == "Ada Test", "open by path loads the pilot from outside the folder")
	_ok(FileAccess.file_exists(file), "...and brings it into the Pilots folder")
	_ok(nova.make_world(-1), "world builds for the opened pilot")
	_ok(nova.pilot_open_file(pilots, scratch + "/nothing.evpilot") == "", "a missing file does not open")

	# --- original pilot import -------------------------------------------------------------
	var plt := elsewhere + "/Old Captain.plt"
	_synthetic_plt(plt)
	var oinfo = JSON.parse_string(nova.pilot_inspect_file(plt))
	_ok(oinfo.kind == "original", "inspect: original EV Nova pilot (%s)" % str(oinfo.get("format", "")))
	var junk := elsewhere + "/notes.txt"
	var jf := FileAccess.open(junk, FileAccess.WRITE)
	jf.store_string("not a pilot")
	jf.close()
	_ok(JSON.parse_string(nova.pilot_inspect_file(junk)).kind == "unknown", "inspect: junk file is unknown")
	var sum = JSON.parse_string(nova.pilot_import_preview(plt))
	_ok(not sum.has("error") and int(sum.credits) == 123456, "import preview: credits %s" % str(sum.get("credits")))
	var before := (JSON.parse_string(nova.pilot_list(pilots)) as Array).size()
	var nid: String = nova.pilot_import_commit(pilots)
	_ok(nid != "" and FileAccess.file_exists(nova.pilot_file_path(pilots, nid)), "import commit saves a .evpilot in the Pilots folder")
	_ok((JSON.parse_string(nova.pilot_list(pilots)) as Array).size() == before + 1 and nova.player_credits() == 123456,
		"imported pilot is listed and live (credits %d)" % nova.player_credits())
	_ok(FileAccess.file_exists(plt), "the original file is untouched")

	# --- migration from user://pilots ---------------------------------------------------------
	var legacy_id: String = nova.pilot_create(PilotFiles.legacy_dir, int(scen[0].id), "Old Pilot", false, "", "")
	_ok(legacy_id != "" and not FileAccess.file_exists(nova.pilot_file_path(pilots, legacy_id)), "legacy pilot exists only in the old store")
	_ok(PilotFiles.migrate_legacy() >= 1, "migrate_legacy copies the old store")
	_ok(FileAccess.file_exists(nova.pilot_file_path(pilots, legacy_id)) and FileAccess.file_exists(nova.pilot_file_path(PilotFiles.legacy_dir, legacy_id)),
		"...into the Pilots folder, keeping the originals")
	_ok(PilotFiles.migrate_legacy() == 0, "migration runs once")

	# --- recent list ----------------------------------------------------------------------------
	PilotFiles.note_recent(copy)
	var rows := PilotFiles.recent_rows(nova, pilots)
	_ok(rows.size() >= 3 and rows[0].path == copy, "recent list: newest opened first (%d rows)" % rows.size())
	var ids := {}
	for r in rows:
		ids[r.id] = true
	_ok(ids.size() == rows.size(), "recent list has no duplicate pilots")

	await process_frame
	# --- picker choice ---------------------------------------------------------------------------
	_ok(not PilotFiles.want_native(), "headless has no native dialogs -> Godot's FileDialog")
	var fd := PilotFiles.pick_file(root, pilots, func(_p): pass, Callable(), false)
	_ok(fd is FileDialog and not fd.use_native_dialog and fd.current_dir == pilots and fd.file_mode == FileDialog.FILE_MODE_OPEN_FILE,
		"pick_file builds a focus-navigable FileDialog starting in the Pilots folder")
	fd.queue_free()
	OS.set_environment("SteamDeck", "1")
	_ok(PilotFiles.steam_deck_game_mode() and not PilotFiles.want_native(), "Steam Deck game mode never uses the native picker")
	OS.set_environment("SteamDeck", "")

	# --- Open Pilot screen -------------------------------------------------------------------------
	Prefs.set_value("presentation", "modern_dialogs", true)
	var pm = PilotMenu.new()
	root.add_child(pm)
	pm.setup(nova, pilots)
	await process_frame
	var texts := []
	for b in pm.find_children("*", "Button", true, false):
		texts.append(b.text)
	_ok(texts.has("New Pilot") and texts.has("Import EV Nova Pilot…") and texts.any(func(t): return str(t).begins_with("Ada Test")), "modern Open Pilot (Select a Pilot): New Pilot / Import EV Nova Pilot… footer, recents listed: %s" % str(texts))
	var chosen := [0]
	pm.pilot_chosen.connect(func(): chosen[0] += 1)
	_ok(pm.open_path(copy) and chosen[0] == 1, "open_path(.evpilot) loads and emits pilot_chosen")
	var pm2 = PilotMenu.new()
	root.add_child(pm2)
	pm2.setup(nova, pilots)
	pm2.open_path(plt)
	await process_frame
	var labels := ""
	for l in pm2.find_children("*", "Label", true, false):
		labels += l.text + "\n"
	_ok(labels.contains("Old Captain") and labels.contains("123,456"), "opening an original pilot shows the import summary")
	var chosen2 := [0]
	pm2.pilot_chosen.connect(func(): chosen2[0] += 1)
	_ok(pm2.import_commit() and chosen2[0] == 1, "Create Pilot imports and plays it")
	# Classic presentation.
	Prefs.set_value("presentation", "modern_dialogs", false)
	ClassicTheme.setup(nova)
	var pm3 = PilotMenu.new()
	root.add_child(pm3)
	pm3.over_menu = true
	pm3.setup(nova, pilots)
	await process_frame
	await process_frame
	_ok(not pm3._ndlg.is_empty() and pm3._ndlg.mode == "classic", "classic Open Pilot: the Select a Pilot NovaDialog in the original frame")
	pm3.queue_free()

	# --- Settings (Apple layout) -----------------------------------------------------------------
	Prefs.set_value("presentation", "modern_menu", true)
	var st = Settings.new()
	root.add_child(st)
	st.setup(nova)
	await process_frame
	await process_frame
	_ok(st.tab_buttons.keys() == Settings.PAGES and st.page == "Presentation", "sidebar lists %s" % str(Settings.PAGE_TITLES.values()))
	for p in Settings.PAGES:
		st.show_page(p)
		await process_frame
		await process_frame
		var tab: Button = st.tab_buttons[p]
		_ok(st.first_control != null and tab.focus_neighbor_right == tab.get_path_to(st.first_control), "%s: right from the sidebar enters the page" % p)
		_ok(root.gui_get_focus_owner() == tab, "%s: focus rests on its sidebar entry" % p)
	st.show_page("Support")
	await process_frame
	var support_text := ""
	for l in st.find_children("*", "Label", true, false):
		support_text += l.text + "\n"
	_ok(support_text.contains(pilots), "Data & Advanced shows the Pilots folder")
	_ok(st.find_children("*", "Button", true, false).any(func(b): return b.text == "Change Pilots Folder…"), "Change Pilots Folder button present")
	PilotFiles.set_dir(scratch + "/OtherPilots")
	Prefs.set_value("pilots", "dir", "")
	# Original Preferences window.
	st.show_page("Presentation")
	await process_frame
	var cp_btn: Button
	for b in st.find_children("*", "Button", true, false):
		if b.text.begins_with("Original Preferences"):
			cp_btn = b
	_ok(cp_btn != null, "Interface page has the Original Preferences Window button")
	cp_btn.pressed.emit()
	await process_frame
	await process_frame
	var cp = st.classic_prefs
	_ok(cp != null and cp.dialog.window_size != Vector2i(0, 0) and st._root.visible, "Classic Preferences opens (DLOG 4003 %s) stacked over Settings, which stays visible" % str(cp.dialog.window_size))
	var intro = cp.dialog.item(7)
	_ok(intro != null and intro.button_pressed == true, "Intro Music checkbox starts on (Apple default)")
	intro.button_pressed = false
	await process_frame
	_ok(Prefs.get_value("classic", "intro_music") == false, "unchecking Intro Music writes Prefs [classic]")
	var vol_before := float(Prefs.get_value("audio", "master"))
	cp._volume(-1)
	_ok(float(Prefs.get_value("audio", "master")) < vol_before or vol_before == 0.0, "volume arrow lowers the master volume (%.3f)" % float(Prefs.get_value("audio", "master")))
	var closed := [0]
	cp.closed.connect(func(): closed[0] += 1)
	cp.dialog.item(0).pressed.emit()
	await process_frame
	await process_frame
	_ok(closed[0] == 1 and st.classic_prefs == null and st._root.visible, "OK closes it and returns to Settings")
	st.close()

	# --- loading screen ------------------------------------------------------------------------------
	var shell = Shell.new()
	root.add_child(shell)
	shell.setup(nova, audio)
	shell.show_loading("Quick thing")
	await _wait(0.05)
	shell.hide_loading()
	await _wait(0.45)
	_ok(shell.loading == null, "a fast operation never shows the loading screen")
	shell.show_loading("Slow thing")
	await _wait(0.12)
	_ok(shell.loading == null, "not yet at 120 ms")
	await _wait(0.3)
	_ok(shell.loading != null, "a slow operation shows it after ~250 ms")
	shell.set_loading_progress("Indexing", 0.5, "5 / 10")
	await _wait(0.1)
	_ok(shell.loading.percent() > 0 and not shell.loading.indeterminate, "real progress drives the bar (%d%%)" % shell.loading.percent())
	shell.hide_loading()
	_ok(shell.loading != null, "...and stays up a moment once shown (no flicker)")
	await _wait(0.7)
	_ok(shell.loading == null, "...then goes")

	var t0 := Time.get_ticks_msec()
	var ok2: bool = await shell.load_data_async(data)
	var ms := Time.get_ticks_msec() - t0
	_ok(ok2 and JSON.parse_string(nova.pilot_scenarios()).size() > 0, "load_game_async installs the game data (%d ms)" % ms)
	print("INFO async data load took ", ms, " ms")
	_ok(not shell._loading_wanted, "loading screen cleans up after the load")

	print("RESULT: ", "ALL PASS" if _fails == 0 else "%d FAIL" % _fails)
	quit(_fails)


func _rm_rf(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for d in DirAccess.get_directories_at(path):
		_rm_rf(path.path_join(d))
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)
