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
const PluginsScreen = preload("res://screens/Plugins.gd")
const StoryGuide = preload("res://screens/StoryGuide.gd")
const DataSetup = preload("res://screens/DataSetup.gd")
const PilotFiles = preload("res://screens/PilotFiles.gd")
const LoadingScreen = preload("res://screens/LoadingScreen.gd")
const IntroSequence = preload("res://screens/IntroSequence.gd")
const Tutorial = preload("res://screens/Tutorial.gd")
const Hints = preload("res://screens/Hints.gd")

## Seconds a slow operation runs before the loading screen appears (no flash for quick ones),
## and the least time it then stays up (no flicker when the work ends just after).
const LOADING_DELAY := 0.25
const LOADING_MIN_SHOW := 0.5

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
var story_map: Node
var loading: Node              # the LoadingScreen while it is up
var intro: Node                # the new pilot's IntroSequence while it plays
var offer: Node                # the flight-training offer while it is up
var coach: Node                # the training flight's coach overlay (Tutorial.gd)
var hints: Node                # one-time hint cards (Hints.gd)
var killed_id := ""            # the loaded pilot that was killed: the menu reads "<name> has been killed"
var _training_exit := "play"   # "play" (new pilot: begin play after) | "menu" (replayed from Settings)
var _data_from_menu := false
var _loading_serial := 0       # bumped by every show/hide so stale delay timers do nothing
var _loading_wanted := false
var _booting := false          # start_async is still looking for / loading the data
var _loading_label := ""


func setup(world: Object, game_audio: Node) -> void:
	nova = world
	audio = game_audio
	Prefs.apply_saving(nova)
	hints = Hints.new()
	add_child(hints)
	hints.setup(nova, self)


## Any full-screen shell screen is up (the world is not shown / stepped).
func in_menu() -> bool:
	return main_menu != null or pilot_menu != null or data_setup != null or _booting \
			or intro != null or offer != null


func is_paused() -> bool:
	return pause_menu != null or (settings != null and not in_menu())


## Startup: find data, then the main menu — or the data-setup screen.
func start() -> void:
	PilotFiles.migrate_legacy()
	data_dir = Prefs.find_data(nova)
	_after_data_search()


## `start()` with the data loaded on a worker thread (`load_game_async`) while the loading screen
## animates and reports real progress (once the load has run > LOADING_DELAY). Main uses this;
## the synchronous `start()` stays for tests and tools.
func start_async() -> void:
	PilotFiles.migrate_legacy()
	_booting = true
	data_dir = await find_data_async()
	_booting = false
	_after_data_search()


func _after_data_search() -> void:
	if data_dir == "":
		print("NOVA Swift: no EV Nova data found — showing data setup")
		_open_data_setup(false)
		return
	print("NOVA Swift: loaded data from ", data_dir)
	has_data = true
	data_loaded.emit(data_dir)
	_open_main_menu()


## First `Prefs.data_candidates()` folder that loads, or "" -- loaded off the main thread.
func find_data_async() -> String:
	for dir in Prefs.data_candidates():
		if DirAccess.dir_exists_absolute(dir) and await load_data_async(dir):
			return dir
	return ""


## Load the game data at `dir` on the bridge's worker thread; true on success. The loading screen
## appears if it takes longer than LOADING_DELAY and shows the bridge's phase / fraction.
func load_data_async(dir: String, label := "Loading game data") -> bool:
	if not nova.load_game_async(dir):
		return false
	show_loading(label)
	var ok := false
	while true:
		var st = JSON.parse_string(nova.load_status())
		if st is Dictionary:
			set_loading_progress(str(st.get("phase", label)), float(st.get("fraction", 0.0)))
			if bool(st.get("done", false)):
				ok = bool(st.get("ok", false))
				break
		await get_tree().process_frame
	hide_loading()
	return ok


# --- loading screen (Apple LoadingView) ---------------------------------------------------
#
#   Shell.show_loading("Reloading plug-ins")            ; appears after LOADING_DELAY if still wanted
#   Shell.set_loading_progress("Reading", 0.4, "3 / 7") ; real progress (else the bar just sweeps)
#   Shell.hide_loading()                                ; gone (kept up >= LOADING_MIN_SHOW once shown)
#
# `show_loading(label, true)` skips the delay for work known to be long. Work that runs on the main
# thread cannot animate it -- run it as a worker + poll (see load_data_async) or yield a couple of
# frames after an immediate show_loading so it paints once.

func show_loading(label := "Loading", immediate := false) -> void:
	_loading_serial += 1
	_loading_wanted = true
	_loading_label = label
	if loading != null:
		loading.set_indeterminate(label)
		return
	if immediate:
		_create_loading()
		return
	var serial := _loading_serial
	get_tree().create_timer(LOADING_DELAY).timeout.connect(func():
		if _loading_wanted and _loading_serial == serial and loading == null:
			_create_loading())


func _create_loading() -> void:
	loading = LoadingScreen.new()
	add_child(loading)
	loading.set_indeterminate(_loading_label)


func set_loading_progress(phase: String, fraction: float, count := "") -> void:
	if _loading_label != phase:
		_loading_label = phase
	if loading != null:
		loading.set_progress(phase, fraction, count)


func hide_loading() -> void:
	_loading_serial += 1
	_loading_wanted = false
	if loading == null:
		return
	var shown: float = loading.shown_seconds
	var node := loading
	if shown >= LOADING_MIN_SHOW:
		loading = null
		node.queue_free()
		return
	var serial := _loading_serial
	get_tree().create_timer(LOADING_MIN_SHOW - shown).timeout.connect(func():
		if _loading_serial == serial and loading == node:
			loading = null
			node.queue_free())


func is_loading() -> bool:
	return loading != null


# --- main menu --------------------------------------------------------------------

func _open_main_menu() -> void:
	main_menu = MainMenu.new()
	add_child(main_menu)
	main_menu.killed_id = killed_id
	main_menu.setup(nova, data_dir, has_data)
	main_menu.new_pilot.connect(_open_pilots.bind(true))
	main_menu.open_pilot.connect(_open_pilots.bind(false))
	main_menu.settings.connect(_open_settings.bind(main_menu))
	main_menu.game_data.connect(func():
		main_menu.visible = false
		_open_data_setup(true))
	main_menu.plugins.connect(_open_plugins.bind(main_menu))
	main_menu.quit.connect(quit_game)
	main_menu.enter_ship.connect(_enter_ship)


## Classic menu "Enter Ship": resume the newest pilot; with none, open the pilot list.
func _enter_ship() -> void:
	if killed_id != "":
		nova.sound_beep(4)   # the loaded pilot was killed: Enter Ship only beeps until it is opened again
		return
	var dir := pilot_dir()
	var rows = JSON.parse_string(nova.pilot_list(dir))
	if rows is Array and not rows.is_empty() and nova.pilot_load(dir, str(rows[0]["id"])):
		_on_pilot_chosen()
	else:
		_open_pilots(false)


func _open_pilots(start_new: bool) -> void:
	main_menu.dialog_open(true)   # the classic menu stays on screen (inert) behind the dialog
	pilot_menu = PilotMenu.new()
	add_child(pilot_menu)
	pilot_menu.over_menu = main_menu.classic_menu != null
	pilot_menu.pilot_chosen.connect(_on_pilot_chosen)
	pilot_menu.pilot_created.connect(_on_pilot_created)
	pilot_menu.creating_changed.connect(func(on: bool): main_menu.set_creating(on))
	pilot_menu.cancelled.connect(func():
		pilot_menu = null
		main_menu.refresh_pilot()   # a pilot may have been deleted
		main_menu.dialog_open(false))
	pilot_menu.setup(nova, pilot_dir(), start_new)


## The Pilots folder (screens/PilotFiles.gd): a real, visible folder of .evpilot files.
func pilot_dir() -> String:
	return PilotFiles.dir()


## A new pilot was written (Apple NewPilotView.start): its scenario intro, then the flight-training
## offer (first pilot only), then play.
func _on_pilot_created(scenario_id: int) -> void:
	pilot_menu = null
	killed_id = ""
	if main_menu != null:
		main_menu.killed_id = ""
		main_menu.set_creating(false)
	intro = IntroSequence.new()
	add_child(intro)
	if not intro.setup(nova, scenario_id):
		intro.queue_free()
		intro = null
		_offer_training()
		return
	intro.finished.connect(func():
		intro.queue_free()
		intro = null
		_offer_training())


## Apple AppModel.offerTutorialAfterNewPilot: offer flight training once (until completed or
## skipped), only with Tutorial hints on; otherwise straight into play.
func _offer_training() -> void:
	if not (Prefs.hints_enabled() and not Prefs.tutorial_completed() and has_data):
		_on_pilot_chosen()
		return
	offer = Tutorial.make_offer(nova, self)
	offer.start.connect(func():
		_close_offer()
		start_training("play"))
	offer.skip.connect(func():
		_close_offer()
		_on_pilot_chosen())


func _close_offer() -> void:
	if offer != null:
		offer.queue_free()
		offer = null


func is_training() -> bool:
	return coach != null


## Begin a flight-training session over a throwaway pilot (Apple startTutorial(exit:)). `exit_mode`
## "play" begins play with the real pilot afterwards, "menu" returns to the main menu.
func start_training(exit_mode: String) -> void:
	if coach != null or not nova.tutorial_begin():
		if exit_mode == "play":
			_on_pilot_chosen()
		return
	_training_exit = exit_mode
	if main_menu != null:
		main_menu.queue_free()   # also ends the title music
		main_menu = null
	pilot_chosen.emit()          # Main builds the training world from the trainee
	coach = Tutorial.new()
	add_child(coach)
	coach.setup(nova, self, "Begin Your Journey" if exit_mode == "play" else "Return to Menu")
	coach.finished.connect(end_training)


## The course finished or was skipped (Apple finishTutorial): remembered so it is not auto-offered
## again, the real pilot is back, and play begins or the menu returns per the exit.
func end_training() -> void:
	if coach == null:
		return
	coach.queue_free()
	coach = null
	nova.tutorial_end()
	Prefs.mark_tutorial_completed()
	if pause_menu != null:
		pause_menu.queue_free()
		pause_menu = null
	if _training_exit == "play":
		pilot_chosen.emit()
	else:
		_open_main_menu()


func _on_pilot_chosen() -> void:
	pilot_menu = null
	killed_id = ""
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
	settings.allow_training = underneath == main_menu and has_data and main_menu != null
	settings.training_requested.connect(func():
		settings.close()
		start_training("menu"))
	settings.setup(nova)
	settings.changed.connect(apply_prefs)
	settings.closed.connect(func():
		settings = null
		underneath.visible = true
		if underneath.has_method("refocus"):
			underneath.refocus()
		elif underneath.has_method("set_active"):
			underneath.set_active(true))


## The Plug-ins manager (main menu / Settings); reloads the game data through the loading screen.
func _open_plugins(underneath: Node) -> void:
	underneath.visible = false
	var scr = PluginsScreen.new()
	add_child(scr)
	scr.setup(nova)
	scr.closed.connect(func():
		scr.queue_free()
		underneath.visible = true
		if underneath.has_method("refocus"):
			underneath.refocus()
		elif underneath.has_method("set_active"):
			underneath.set_active(true))


## Story Map / Story Guide over the pause menu (Apple GameMenuView "Story Guide"); the pause
## menu comes back, focused, when it closes.
func _open_story_map() -> void:
	if pause_menu == null or story_map != null:
		return
	var underneath := pause_menu
	underneath.set_active(false)
	story_map = StoryGuide.open(self, nova)
	story_map.closed.connect(func():
		story_map = null
		if is_instance_valid(underneath):
			underneath.set_active(true))


## Push saved settings into the live nodes (volumes, music).
func apply_prefs() -> void:
	Prefs.apply_audio(audio)
	Prefs.apply_saving(nova)
	if main_menu != null:
		main_menu.refresh_music()


# --- pause menu ---------------------------------------------------------------------

func open_pause() -> void:
	if pause_menu != null:
		return
	pause_menu = PauseMenu.new()
	add_child(pause_menu)
	if coach != null:
		pause_menu.save_label = "Leave Training"
	pause_menu.setup(nova, has_data)
	pause_menu.resume.connect(close_pause)
	pause_menu.player_info.connect(func(): close_pause(); player_info_requested.emit())
	pause_menu.settings.connect(func(): _open_settings(pause_menu))
	pause_menu.story_map.connect(_open_story_map)
	pause_menu.save_quit_to_menu.connect(_save_and_menu)
	pause_menu.quit.connect(quit_game)


func close_pause() -> void:
	if pause_menu == null:
		return
	pause_menu.queue_free()
	pause_menu = null
	resumed.emit()


func _save_and_menu() -> void:
	if coach != null:
		end_training()   # the training flight saves nothing
		return
	if has_data:
		nova.pilot_save_now()
	pause_menu.queue_free()
	pause_menu = null
	_open_main_menu()


## The pilot was lost (the death sequence ran out with no eject): back to the main menu
## without saving — the pilot resumes from its last launch, as in the original.
func return_to_menu() -> void:
	if in_menu():
		return
	if coach != null:
		end_training()
		return
	if pause_menu != null:
		pause_menu.queue_free()
		pause_menu = null
	if has_data and main_menu == null:
		_open_main_menu()
	else:
		start()


## The death sequence ran out with no eject (Apple GameContainerView.onPlayerDestroyed): Strict Play
## deletes the pilot (every slot and backup), otherwise it is marked killed -- the menu reads
## "<name> has been killed" and Enter Ship only beeps until a pilot is opened.
func on_player_killed() -> void:
	var r = JSON.parse_string(nova.pilot_killed())
	if r is Dictionary and str(r.get("result", "")) == "killed":
		killed_id = str(r.get("id", ""))
	else:
		killed_id = ""
	return_to_menu()


## Quit, saving the live pilot first when there is one.
func quit_game() -> void:
	if has_data and pilot_menu == null and main_menu == null and data_setup == null and nova != null:
		nova.pilot_autosave("backgroundLanded" if nova.is_landed() else "background")
	Prefs.save()
	get_tree().quit()
