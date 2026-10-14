# Headless check of the new-pilot flow: intro, training offer + coach, death / killed readout, Strict
# Play deletion, save slots + backups, frequent autosave, one-time hints.
#   NOVA_DATA_DIR=$PWD/data/base NOVA_PILOTS_DIR=<scratch> godot --headless --path godot -s res://tests/new_pilot_flow_selfcheck.gd
extends SceneTree

const Prefs = preload("res://Prefs.gd")
const Shell = preload("res://screens/Shell.gd")
const PilotFiles = preload("res://screens/PilotFiles.gd")
const PilotMenu = preload("res://screens/PilotMenu.gd")
const Hints = preload("res://screens/Hints.gd")
const GameAudio = preload("res://audio/GameAudio.gd")

var _fails := 0
var _chosen := 0


func _ok(cond: bool, what: String) -> void:
	print(("PASS " if cond else "FAIL ") + what)
	if not cond:
		_fails += 1


func _wait(seconds: float) -> void:
	var end := Time.get_ticks_msec() + int(seconds * 1000.0)
	while Time.get_ticks_msec() < end:
		await process_frame


func _rm_rf(path: String) -> void:
	if not DirAccess.dir_exists_absolute(path):
		return
	for d in DirAccess.get_directories_at(path):
		_rm_rf(path.path_join(d))
	for f in DirAccess.get_files_at(path):
		DirAccess.remove_absolute(path.path_join(f))
	DirAccess.remove_absolute(path)


## Stand-in bridge for the docked-hint test.
class StubNova extends RefCounted:
	var real: Object
	var landed := true
	func is_landed() -> bool: return landed
	func tutorial_active() -> bool: return false
	func has_pilot_save() -> bool: return true
	func game_hints() -> String: return real.game_hints()
	func game_hint_for_screen(s: String) -> String: return real.game_hint_for_screen(s)


func _init() -> void:
	var scratch := OS.get_user_data_dir() + "/new_pilot_flow_check"
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
	_ok(nova.load_game(data), "load_game")
	var scen = JSON.parse_string(nova.pilot_scenarios())
	var sid := int(scen[0].id)

	# --- the shell, the New Pilot dialog, the intro, the training offer ---------------------------
	var shell = Shell.new()
	root.add_child(shell)
	shell.setup(nova, audio)
	shell.data_dir = data
	shell.has_data = true
	shell.pilot_chosen.connect(func(): _chosen += 1)
	shell._open_main_menu()
	await _wait(0.3)
	shell._open_pilots(true)
	await _wait(0.3)
	_ok(shell.main_menu._creating, "the New Pilot dialog puts the menu in the Creating Pilot state")
	var creating = JSON.parse_string(nova.classic_menu_readout_state(pilots, "", "creating"))
	_ok(str(creating.centred).to_lower().contains("creating"), "readout state 'creating': %s" % creating.centred)
	var pm = shell.pilot_menu
	pm._name_edit.text = "Flow Test"
	pm._c_name_ok()
	await _wait(0.2)
	pm._c_start("Flow Test", "Rocinante")
	await _wait(0.3)
	_ok(not shell.main_menu._creating and shell.pilot_menu == null, "creating ends when the pilot is written")
	var intro_info = JSON.parse_string(nova.pilot_intro(sid))
	var has_intro: bool = not (intro_info.slides as Array).is_empty() or str(intro_info.text) != ""
	_ok(has_intro, "the scenario has an intro (%d slides, %d chars of text)" % [(intro_info.slides as Array).size(), str(intro_info.text).length()])
	_ok(shell.intro != null and _chosen == 0, "intro sequence is playing after New Pilot")
	if shell.intro != null:
		var n: int = shell.intro.pages.size()
		shell.intro.advance()
		_ok(n < 2 or shell.intro.index == 1, "click advances to the next page")
		shell.intro._skip.pressed.emit()
		await _wait(0.2)
	_ok(shell.intro == null, "skip ends the intro")
	_ok(shell.offer != null and _chosen == 0, "the flight-training offer follows (first pilot)")
	shell.offer.skip.emit()
	await _wait(0.2)
	_ok(shell.offer == null and _chosen == 1, "Skip on the offer begins play")
	var pid := ""
	var rows = JSON.parse_string(nova.pilot_list(pilots))
	pid = str(rows[0].id)
	_ok(str(rows[0].name) == "Flow Test", "the new pilot is on disk")

	# --- flight training -----------------------------------------------------------------------------
	_ok(nova.make_world(-1), "world for the real pilot")
	var real_credits: int = nova.player_credits()
	shell.start_training("play")
	await _wait(0.3)
	_ok(shell.coach != null and nova.tutorial_active() and _chosen == 2, "Start Training swaps in the sandbox and builds its world")
	var st = JSON.parse_string(nova.tutorial_state())
	_ok(int(st.count) >= 7 and str(st.steps[0].id) == "welcome", "course: %d steps, starts with the welcome card" % int(st.count))
	_ok(not nova.pilot_autosave("launch") and not nova.pilot_save_now(), "nothing saves during training")
	shell.coach.complete("fly")
	_ok(int(JSON.parse_string(nova.tutorial_state()).index) == 0, "a stray goal does not skip the manual welcome card")
	shell.coach.continue_step()
	shell.coach.complete("target")
	_ok(int(JSON.parse_string(nova.tutorial_state()).index) == 1, "a goal for another step is ignored")
	shell.coach.complete("fly")
	_ok(int(JSON.parse_string(nova.tutorial_state()).index) == 2, "fly completes its step")
	for i in 12:
		shell.coach.skip_step() if str(shell.coach.current_step().get("goal", "")) != "" else shell.coach.continue_step()
		if shell.coach == null:
			break
	await _wait(0.2)
	_ok(shell.coach == null and not nova.tutorial_active(), "finishing the course ends training")
	_ok(Prefs.tutorial_completed(), "...and it is remembered, so it is not offered again")
	_ok(_chosen == 3 and nova.player_credits() == real_credits and nova.pilot_name() == "Flow Test", "the real pilot is back untouched and play begins")
	shell.has_data = true
	shell._offer_training()
	_ok(shell.offer == null and _chosen == 4, "no offer once training was completed")

	# --- death: the killed state ----------------------------------------------------------------------------
	_ok(shell.main_menu == null, "(in flight: no menu)")
	shell.on_player_killed()
	await _wait(0.4)
	_ok(shell.killed_id == pid and shell.main_menu != null, "death returns to the menu with the pilot marked killed")
	var cm = shell.main_menu.classic_menu
	var cen: String = str(cm._readout.data.get("centred", ""))
	_ok(cen == "Flow Test has been killed", "menu readout: '%s'" % cen)
	var before := _chosen
	shell._enter_ship()
	_ok(_chosen == before, "Enter Ship only beeps for a killed pilot")
	_ok(FileAccess.file_exists(nova.pilot_file_path(pilots, pid)), "a non-strict death keeps the pilot file (resumes from the last launch)")
	var kenny = JSON.parse_string(nova.classic_menu_readout_state(pilots, pid, "killed"))
	_ok(str(kenny.centred).ends_with("has been killed"), "killed state text comes from STR# 2002")

	# --- save slots and backups ----------------------------------------------------------------------------------
	_ok(nova.pilot_load(pilots, pid), "reload the pilot")
	_ok(nova.pilot_save_now() and nova.pilot_save_now(), "two manual saves rotate a backup")
	var groups = JSON.parse_string(nova.pilot_groups(pilots))
	var g = groups[0]
	_ok(groups.size() == 1 and g.slots.size() == 1 and int(g.slots[0].backups) >= 1, "group has 1 slot with %d backup(s)" % int(g.slots[0].backups))
	var hist = JSON.parse_string(nova.pilot_group_history(pilots, str(g.group)))
	_ok(hist.size() >= 1 and str(hist[0].path).contains("Backups"), "backup history lists the backup files")
	_ok(not nova.pilot_restore(pilots, str(g.slots[0].id), "/etc/hosts"), "restore refuses files outside Backups")
	_ok(nova.pilot_restore(pilots, str(g.slots[0].id), str(hist[0].path)), "restore rolls the slot back to a backup")
	var slot2: String = nova.pilot_add_slot(pilots, str(g.group))
	g = JSON.parse_string(nova.pilot_groups(pilots))[0]
	_ok(slot2 != "" and g.slots.size() == 2 and int(g.slots[1].slot) == 2, "New Save Slot adds Slot 2")
	_ok(nova.pilot_rename_group(pilots, str(g.group), "Renamed") and str(JSON.parse_string(nova.pilot_groups(pilots))[0].name) == "Renamed", "rename applies to the group")
	# UI: group + backups screens build in both presentations
	shell._open_pilots(false)
	await _wait(0.2)
	pm = shell.pilot_menu
	pm._show_group(slot2)
	await _wait(0.1)
	_ok(str(pm._group_id) == str(g.group), "group screen (classic) opens")
	pm._show_backups(0)
	await _wait(0.1)
	Prefs.set_value("presentation", "modern_dialogs", true)
	var pm2 = PilotMenu.new()
	root.add_child(pm2)
	pm2.setup(nova, pilots, false)
	pm2._show_group(slot2)
	await _wait(0.1)
	_ok(str(pm2._group_id) == str(g.group) and pm2._panel.get_child_count() > 4, "group screen (plain) opens")
	pm2._show_backups(0)
	await _wait(0.1)
	_ok(pm2._panel.get_child_count() > 2, "backups screen (plain) lists backups")
	pm2.queue_free()
	Prefs.set_value("presentation", "modern_dialogs", false)
	pm._classic = true
	var chosen_before := _chosen
	pm._restore(str(g.slots[0].id), str(hist[0].path))
	await _wait(0.2)
	_ok(_chosen == chosen_before + 1, "restoring a backup plays that slot")
	_ok(nova.pilot_delete_slot(pilots, slot2) and JSON.parse_string(nova.pilot_groups(pilots))[0].slots.size() == 1, "delete one slot keeps the pilot")

	# --- Strict Play ----------------------------------------------------------------------------------------------------
	var sp: String = nova.pilot_create_strict(pilots, sid, "Doomed", true, "", "Ship", true)
	_ok(sp != "", "strict pilot created")
	nova.pilot_save_now()
	nova.pilot_save_now()
	var sp_group: String = ""
	for gr in JSON.parse_string(nova.pilot_groups(pilots)):
		for sl in gr.slots:
			if str(sl.id) == sp:
				sp_group = str(gr.group)
	var slotx: String = nova.pilot_add_slot(pilots, sp_group)
	var dead = JSON.parse_string(nova.pilot_killed())
	_ok(str(dead.result) == "deleted" and str(dead.id) == sp, "Strict Play death deletes the pilot")
	_ok(not FileAccess.file_exists(nova.pilot_file_path(pilots, sp)), "...its file is gone")
	_ok(not DirAccess.dir_exists_absolute(pilots.path_join("Backups").path_join(sp)), "...and its backups")
	_ok(slotx == "" or not FileAccess.file_exists(nova.pilot_file_path(pilots, slotx)), "...and every other slot")
	_ok(FileAccess.file_exists(nova.pilot_file_path(pilots, pid)), "other pilots are untouched")
	_ok(str(JSON.parse_string(nova.pilot_killed()).result) == "none", "no live pilot after the delete")

	# --- frequent autosave ----------------------------------------------------------------------------------------------------
	_ok(nova.pilot_load(pilots, pid) and nova.make_world(-1), "reload pilot for autosave")
	_ok(not nova.pilot_autosave("periodic") and not nova.pilot_autosave("jump") and not nova.pilot_autosave("land"),
		"default (original cadence): periodic / jump / land do not save")
	_ok(nova.pilot_autosave("launch"), "launch always saves")
	Prefs.set_value("gameplay", "frequent_autosave", true)
	Prefs.apply_saving(nova)
	_ok(nova.frequent_autosave_on(), "Prefs [gameplay] frequent_autosave reaches the bridge")
	_ok(nova.pilot_autosave("periodic") and nova.pilot_autosave("jump") and nova.pilot_autosave("land"),
		"frequent autosave: periodic / jump / land now save")
	Prefs.set_value("gameplay", "frequent_autosave", false)
	Prefs.apply_saving(nova)

	# --- hints: shown once --------------------------------------------------------------------------------------------------------
	shell.main_menu = null
	shell.pilot_menu = null
	var hints = shell.hints
	hints._process(0.1)
	_ok(hints.current_id == "flight", "first flight shows the Getting started card")
	hints.dismiss()
	hints._process(0.1)
	_ok(hints.current_id == "" and Prefs.get_value("hints", "flight_card") == true, "dismissed: it does not come back")
	var stub := StubNova.new()
	stub.real = nova
	hints._nova = stub
	var screen := ["hub"]
	hints.screen_provider = func(): return screen[0]
	hints._process(0.1)
	_ok(hints.current_id == "spaceport.services", "first landing shows the spaceport hint")
	hints._process(0.1)
	hints.dismiss()
	hints._process(0.1)
	_ok(hints.current_id == "", "...once")
	screen[0] = "bbs"
	hints._process(0.1)
	_ok(hints.current_id == "missionBBS.howto", "first Mission BBS shows its hint")
	hints.dismiss()
	screen[0] = "outfitter"
	hints._process(0.1)
	_ok(hints.current_id == "outfitter.howto", "first Outfitter shows its hint")
	hints.dismiss()
	screen[0] = "trade"
	hints._process(0.1)
	_ok(hints.current_id == "", "no hint on the Trade Center")
	Prefs.set_value("hints", "enabled", false)
	Prefs.reset_hints()
	hints._process(0.1)
	_ok(hints.current_id == "", "Tutorial hints off: nothing shows")
	Prefs.set_value("hints", "enabled", true)
	hints._nova = nova
	hints._process(0.1)
	_ok(hints.current_id == "" or hints.current_id == "flight", "Show all hints again clears the flags")
	_ok(not Prefs.hint_seen("novaswift.hint.outfitter.howto"), "...hint flags are cleared")

	_rm_rf(scratch)
	print("new_pilot_flow_selfcheck: %d failure(s)" % _fails)
	quit(1 if _fails > 0 else 0)
