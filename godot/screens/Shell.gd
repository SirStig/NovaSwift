# NOVA Swift — app shell: owns the screens around the game (data setup, main
# menu, pilot menu, settings, pause menu) and the flow between them, so Main.gd
# only has to ask `in_menu()` / `is_paused()` and react to three signals.
#
#   start() ── no data ──► DataSetup ──► main menu     (or "Run demo")
#           └─ data ─────► MainMenu ──► PilotMenu ──► pilot_chosen
#                              └─ Settings · Game Data… · Quit
#   pause() (Esc / Start in flight) ──► Resume · Settings · Save & Quit to menu · Quit
#
# Screens are CanvasLayers; opening a sub-screen hides the one beneath it so
# gamepad focus can't wander into it. Esc/B inside a dialog uses ui_cancel; the
# separate `pause_menu` action (Esc / Start) is only polled by Main in flight.
extends Node

const Controls = preload("res://Controls.gd")
const Prefs = preload("res://Prefs.gd")
const PilotMenu = preload("res://screens/PilotMenu.gd")
const MainMenu = preload("res://screens/MainMenu.gd")
const PauseMenu = preload("res://screens/PauseMenu.gd")
const Settings = preload("res://screens/Settings.gd")
const DataSetup = preload("res://screens/DataSetup.gd")

const PILOT_DIR := "user://pilots"

## A data folder was loaded on the bridge (path).
signal data_loaded(dir: String)
## A pilot was created / loaded on the bridge: Main builds the world.
signal pilot_chosen
## "Run demo" from the data-setup screen.
signal demo_chosen
## The pause menu closed and play continues.
signal resumed
## The pause menu's Player Info button (Main opens the window after the menu closes).
signal player_info_requested

var nova: Object
var audio: Node
var data_dir := ""
var has_data := false

var main_menu: Node
var pilot_menu: Node
var data_setup: Node
var settings: Node
var pause_menu: Node
var _data_from_menu := false


func setup(world: Object, game_audio: Node) -> void:
	nova = world
	audio = game_audio


## Any full-screen shell screen is up (the world is not shown / stepped).
func in_menu() -> bool:
	return main_menu != null or pilot_menu != null or data_setup != null


func is_paused() -> bool:
	return pause_menu != null or (settings != null and not in_menu())


## Startup: find data, then the main menu — or the data-setup screen.
func start() -> void:
	data_dir = Prefs.find_data(nova)
	if data_dir == "":
		print("NOVA Swift: no EV Nova data found — showing data setup")
		_open_data_setup(false)
		return
	print("NOVA Swift: loaded data from ", data_dir)
	has_data = true
	data_loaded.emit(data_dir)
	_open_main_menu()


# --- main menu --------------------------------------------------------------------

func _open_main_menu() -> void:
	main_menu = MainMenu.new()
	add_child(main_menu)
	main_menu.setup(nova, data_dir, has_data)
	main_menu.new_pilot.connect(_open_pilots.bind(true))
	main_menu.open_pilot.connect(_open_pilots.bind(false))
	main_menu.settings.connect(_open_settings.bind(main_menu))
	main_menu.game_data.connect(func():
		main_menu.visible = false
		_open_data_setup(true))
	main_menu.quit.connect(quit_game)


func _open_pilots(start_new: bool) -> void:
	main_menu.visible = false
	pilot_menu = PilotMenu.new()
	add_child(pilot_menu)
	pilot_menu.pilot_chosen.connect(_on_pilot_chosen)
	pilot_menu.cancelled.connect(func():
		pilot_menu = null
		main_menu.visible = true
		main_menu.refocus())
	pilot_menu.setup(nova, ProjectSettings.globalize_path(PILOT_DIR), start_new)


func _on_pilot_chosen() -> void:
	pilot_menu = null
	if main_menu != null:
		main_menu.queue_free()   # also ends the title music
		main_menu = null
	pilot_chosen.emit()


# --- data setup -------------------------------------------------------------------

func _open_data_setup(from_menu: bool) -> void:
	_data_from_menu = from_menu
	data_setup = DataSetup.new()
	add_child(data_setup)
	data_setup.setup(nova)
	data_setup.data_found.connect(_on_data_found)
	data_setup.run_demo.connect(func():
		_close_data_setup()
		if main_menu != null:
			main_menu.queue_free()
			main_menu = null
		has_data = false
		demo_chosen.emit())
	data_setup.quit.connect(quit_game)
	data_setup.back.connect(func():
		if _data_from_menu:
			_close_data_setup()
			main_menu.visible = true
			main_menu.refocus())


func _close_data_setup() -> void:
	if data_setup != null:
		data_setup.queue_free()
		data_setup = null


func _on_data_found(dir: String) -> void:
	data_dir = dir
	has_data = true
	_close_data_setup()
	data_loaded.emit(dir)
	if main_menu != null:   # re-pointed at other data from the menu: rebuild it (new music)
		main_menu.queue_free()
		main_menu = null
	_open_main_menu()


# --- settings (from the main menu or the pause menu) -------------------------------

func _open_settings(underneath: Node) -> void:
	underneath.visible = false
	settings = Settings.new()
	add_child(settings)
	settings.setup(nova)
	settings.changed.connect(apply_prefs)
	settings.closed.connect(func():
		settings = null
		underneath.visible = true
		if underneath.has_method("refocus"):
			underneath.refocus()
		elif underneath.has_method("set_active"):
			underneath.set_active(true))


## Push saved settings into the live nodes (volumes, music).
func apply_prefs() -> void:
	Prefs.apply_audio(audio)
	if main_menu != null:
		main_menu.refresh_music()


# --- pause menu ---------------------------------------------------------------------

func open_pause() -> void:
	if pause_menu != null:
		return
	pause_menu = PauseMenu.new()
	add_child(pause_menu)
	pause_menu.setup(nova, has_data)
	pause_menu.resume.connect(close_pause)
	pause_menu.player_info.connect(func(): close_pause(); player_info_requested.emit())
	pause_menu.settings.connect(func(): _open_settings(pause_menu))
	pause_menu.save_quit_to_menu.connect(_save_and_menu)
	pause_menu.quit.connect(quit_game)


func close_pause() -> void:
	if pause_menu == null:
		return
	pause_menu.queue_free()
	pause_menu = null
	resumed.emit()


func _save_and_menu() -> void:
	if has_data:
		nova.pilot_save_now()
	pause_menu.queue_free()
	pause_menu = null
	_open_main_menu()


## Quit, saving the live pilot first when there is one.
func quit_game() -> void:
	if has_data and pilot_menu == null and main_menu == null and data_setup == null and nova != null:
		nova.pilot_autosave("backgroundLanded" if nova.is_landed() else "background")
	Prefs.save()
	get_tree().quit()
