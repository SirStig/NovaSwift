# NOVA Swift — startup main menu (New Pilot / Open Pilot / Settings / Quit).
#
# Shown before the pilot screen when real data is loaded. Modelled on the Apple
# app's ModernMainMenuView: the NOVA SWIFT wordmark over a dark star-field, a
# column of buttons below it. Pure Godot focus navigation (arrows / d-pad / left
# stick, Enter / A); no hover sounds, as in the original's menus. The title music
# (audio/TitleMusic.gd) plays only while this menu is up.
#
# Presentation: with the data loaded and Settings > Presentation > "Modern main menu" off
# (the default), this is the authentic menu instead (ui/classic/ClassicMainMenu.gd, a port of
# the Apple AuthenticMainMenuView: title picture, shutter strips, the six real buttons,
# the loaded-pilot readout). Preferences opens NovaSwift's own Settings screen (original
# dialogs only ever sit behind a button inside it). The plain menu below is the Nova Swift option.
#
# The menu only reports what was chosen; Main.gd decides what happens next.
extends CanvasLayer

const ShellUI = preload("res://screens/ShellUI.gd")
const TitleMusic = preload("res://audio/TitleMusic.gd")
const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")
const ClassicMainMenu = preload("res://ui/classic/ClassicMainMenu.gd")
const ClassicDialog = preload("res://ui/classic/ClassicDialog.gd")
const ClassicButton = preload("res://ui/classic/ClassicButton.gd")
const PilotFiles = preload("res://screens/PilotFiles.gd")
const DescMovie = preload("res://ui/DescMovie.gd")

signal new_pilot
signal open_pilot
signal settings
signal game_data
signal plugins
signal quit
## Classic menu: "Enter Ship" -- resume the newest pilot (the host opens the list if none).
signal enter_ship

var music: Node   # TitleMusic, or null
var first_button: Control
var _root: Control
var classic_menu: Control    # the ClassicMainMenu when drawn in Classic presentation
var _about: Control
var _extra: Control
var _nova: Object
## The loaded pilot that was killed ("" = none): the readout says "<name> has been killed".
var killed_id := ""
var _creating := false   # the New Pilot dialog is up: the readout says "Creating Pilot..."


func setup(nova: Object, data_dir: String, has_data: bool) -> void:
	layer = 50
	ClassicTheme.setup(nova)
	_nova = nova
	if has_data and ClassicTheme.classic("menu"):
		_setup_classic(nova, data_dir)
		return
	_root = ShellUI.screen(self, 1.0)
	_root.add_child(_Stars.new())
	_root.move_child(_root.get_child(_root.get_child_count() - 1), 1)   # above the backdrop, below the UI

	var box := ShellUI.panel(_root, 380, 10)
	# The panel's frame is part of the look on the Apple menu's controls; here the
	# wordmark sits inside it so one container centres the whole stack.
	var logo := TextureRect.new()
	logo.texture = _icon()
	logo.custom_minimum_size = Vector2(96, 96)
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	box.add_child(logo)
	var t := ShellUI.title(box, "NOVA SWIFT", 40)
	t.add_theme_color_override("font_color", ShellUI.ACCENT)
	var sub := ShellUI.label(box, "A native port of Escape Velocity Nova", 14)
	sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER

	first_button = ShellUI.button(box, "Open Pilot", func(): open_pilot.emit(), nova)
	ShellUI.button(box, "New Pilot", func(): new_pilot.emit(), nova)
	ShellUI.button(box, "Settings", func(): settings.emit(), nova)
	ShellUI.button(box, "Game Data…", func(): game_data.emit(), nova)
	if has_data:
		ShellUI.button(box, "Plug-ins", func(): plugins.emit(), nova)
	if has_data:
		ShellUI.button(box, "About Nova", _show_about, nova)
	ShellUI.button(box, "Quit", func(): quit.emit(), nova)
	ShellUI.focus(first_button)

	if has_data:
		music = TitleMusic.new()
		music.name = "TitleMusic"
		add_child(music)
		music.start(nova, data_dir)


func _setup_classic(nova: Object, data_dir: String) -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	classic_menu = ClassicMainMenu.make(nova)
	_root.add_child(classic_menu)
	refresh_pilot()
	classic_menu.chosen.connect(_on_classic_choice)
	first_button = classic_menu.buttons.get("open_pilot")

	# Port-only extras, kept off the original's artwork: the data folder.
	_extra = Control.new()
	_extra.set_anchors_preset(Control.PRESET_FULL_RECT)
	_extra.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_extra)
	var gd = ClassicButton.make("Game Data…", 120)
	gd.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	gd.position = Vector2(14, -(gd.size.y + 12))
	gd.pressed.connect(func():
		nova.sound_beep(1)
		game_data.emit())
	_extra.add_child(gd)
	var pg = ClassicButton.make("Plug-ins", 120)   # Apple's Classic menu has a "Plugins" extra button
	pg.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	pg.position = Vector2(14 + 120 + 10, -(pg.size.y + 12))
	pg.pressed.connect(func():
		nova.sound_beep(1)
		plugins.emit())
	_extra.add_child(pg)
	gd.focus_neighbor_right = gd.get_path_to(pg)
	pg.focus_neighbor_left = pg.get_path_to(gd)
	var q = classic_menu.buttons.get("quit")
	if q != null:
		q.focus_neighbor_bottom = q.get_path_to(gd)
		gd.focus_neighbor_top = gd.get_path_to(q)
		gd.focus_neighbor_right = gd.get_path_to(q)

	music = TitleMusic.new()
	music.name = "TitleMusic"
	add_child(music)
	music.start(nova, data_dir)


## Re-read the pilot for the readout (the host calls it when the pilot list changed): the killed
## pilot when there is one, else the newest. "Creating Pilot..." wins while the New Pilot dialog is up.
func refresh_pilot() -> void:
	if classic_menu == null:
		return
	var dir := PilotFiles.dir()
	var parsed = JSON.parse_string(classic_menu.nova.pilot_list(dir))
	var id: String = str(parsed[0]["id"]) if (parsed is Array and not parsed.is_empty()) else ""
	var state := ""
	if _creating:
		state = "creating"
	elif killed_id != "" and FileAccess.file_exists(classic_menu.nova.pilot_file_path(dir, killed_id)):
		id = killed_id
		state = "killed"
	classic_menu.set_pilot(dir, id, state)


## The New Pilot dialog opened / closed (Apple: sheet == .newPilot).
func set_creating(on: bool) -> void:
	_creating = on
	refresh_pilot()


func _on_classic_choice(action: String) -> void:
	match action:
		"new_pilot": new_pilot.emit()
		"open_pilot": open_pilot.emit()
		"enter_ship": enter_ship.emit()
		"prefs": settings.emit()
		"about": _show_about()
		"quit": quit.emit()


# About Nova: the data's own dësc 32767.
func _show_about() -> void:
	var nova: Object = classic_menu.nova if classic_menu != null else _nova
	if nova == null or nova.classic_desc_text(32767) == "":
		return
	if classic_menu != null:
		classic_menu.blocked = true
	# AboutNovaText: the NovaSwift header over dësc 32767, in the generic dësc dialog.
	var d = ClassicDialog.desc_dialog(nova, nova.about_nova_text(str(ProjectSettings.get_setting("application/config/version", "1.0.0"))))
	d.activated.connect(func(_i): _close_about())   # OK press and Esc / B: one close path
	_about = ClassicDialog.modal(_root, d, 0.6)


# X: the Acknowledgements text, dësc 32766 (NovaCommand_DispatchToMode 0x004872a0). A conversion's dësc
# carries its movie here (EV Classic / EV Override: "EV Haikus.gif"), played with the text.
func _unhandled_key_input(event: InputEvent) -> void:
	if classic_menu == null or classic_menu.blocked or _about != null or not (event is InputEventKey):
		return
	var k: InputEventKey = event
	if not k.pressed or k.echo or k.keycode != KEY_X or k.ctrl_pressed or k.alt_pressed or k.meta_pressed:
		return
	get_viewport().set_input_as_handled()
	_show_acknowledgements()


func _show_acknowledgements() -> void:
	var nova: Object = classic_menu.nova if classic_menu != null else _nova
	if nova == null or nova.classic_desc_text(32766) == "":
		return
	classic_menu.blocked = true
	var clip: Dictionary = DescMovie.lookup(32766)
	if not clip.is_empty() and not bool(clip.get("after", false)):
		DescMovie.play(self, clip, _open_acknowledgements)
	else:
		_open_acknowledgements()


func _open_acknowledgements() -> void:
	var nova: Object = classic_menu.nova if classic_menu != null else _nova
	var d = ClassicDialog.desc_dialog(nova, nova.classic_desc_text(32766))
	d.activated.connect(func(_i): _close_acknowledgements())
	_about = ClassicDialog.modal(_root, d, 0.6)


func _close_acknowledgements() -> void:
	if _about == null:
		return
	var clip: Dictionary = DescMovie.lookup(32766)
	_close_about()
	if not clip.is_empty() and bool(clip.get("after", false)):
		classic_menu.blocked = true
		DescMovie.play(self, clip, func():
			classic_menu.blocked = false
			classic_menu.focus_default.call_deferred())


func _close_about() -> void:
	if _about == null:
		return    # accepted + cancelled can both fire for the one OK press
	if _about != null:
		_about.queue_free()
		_about = null
	if classic_menu != null:
		classic_menu.blocked = false
		classic_menu.focus_default.call_deferred()


## A pilot dialog / sub-screen opens over the menu or closes. The classic menu stays on screen
## behind the dialog (inert); the plain menu hides.
func dialog_open(on: bool) -> void:
	if classic_menu != null:
		classic_menu.blocked = on
		if _extra != null:
			_extra.visible = not on
		visible = true
		if not on:
			classic_menu.focus_default.call_deferred()
		return
	visible = not on
	if not on:
		refocus()


# res://icon.png via the import pipeline when it ran, else straight off disk
# (a fresh checkout run headless has no import cache).
static func _icon() -> Texture2D:
	if ResourceLoader.exists("res://icon.png"):
		return load("res://icon.png")
	var img := Image.load_from_file(ProjectSettings.globalize_path("res://icon.png"))
	return ImageTexture.create_from_image(img) if img != null else null


## Called by Main after Settings changed the volumes.
func refresh_music() -> void:
	if music != null:
		music.refresh_volume()


## Back to the menu from a sub-screen: put focus back on the first button.
func refocus() -> void:
	if classic_menu != null:
		classic_menu.blocked = false
		classic_menu.focus_default.call_deferred()
		return
	ShellUI.focus(first_button)


# A few hundred fixed stars, drawn once.
class _Stars extends Control:
	var _pts := PackedVector2Array()

	func _init() -> void:
		set_anchors_preset(Control.PRESET_FULL_RECT)
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		var rng := RandomNumberGenerator.new()
		rng.seed = 0x5EA
		for i in 260:
			_pts.append(Vector2(rng.randf(), rng.randf()))

	func _draw() -> void:
		for p in _pts:
			var a := 0.25 + 0.6 * fmod(p.x * 977.0 + p.y * 311.0, 1.0)
			draw_circle(p * size, 1.0 + fmod(p.y * 53.0, 1.0), Color(0.85, 0.88, 1.0, a))
