# Headless drive of screens/PilotMenu.gd: new pilot -> chosen signal -> reopen ->
# list shows it -> delete flow. Run like pilot_selfcheck.gd.
extends SceneTree

const PilotMenu = preload("res://screens/PilotMenu.gd")
const Prefs = preload("res://Prefs.gd")
var _chosen := 0


func _init() -> void:
	Prefs.path = OS.get_user_data_dir() + "/pilot_menucheck_settings.cfg"
	Prefs.set_value("presentation", "modern_dialogs", true)   # this checks the plain screen
	var nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	var dir := OS.get_user_data_dir() + "/pilot_menucheck"
	nova.load_game(ProjectSettings.globalize_path("res://") + "../data/base")
	var m = PilotMenu.new()
	root.add_child(m)
	m.setup(nova, dir)
	m.pilot_chosen.connect(func(): _chosen += 1)
	m._show_new()
	await process_frame
	print("focus owner: ", root.gui_get_focus_owner())
	m._create()
	await process_frame
	print("chosen after create: ", _chosen, " name=", nova.pilot_name())
	var m2 = PilotMenu.new()
	root.add_child(m2)
	m2.setup(nova, dir)
	await process_frame
	print("pilots listed: ", m2._pilots.size(), " focus: ", root.gui_get_focus_owner())
	m2._confirm_delete(m2._pilots[0])
	await process_frame
	print("delete confirm focus: ", root.gui_get_focus_owner().text)
	nova.pilot_delete(dir, m2._pilots[0].id)
	m2._show_list()
	print("after delete: ", m2._pilots.size())
	quit()
