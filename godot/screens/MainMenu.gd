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
const PilotFiles = preload("res://screens/PilotFiles.gd")
const DescMovie = preload("res://ui/DescMovie.gd")
const NovaTheme = preload("res://ui/novaswift/NovaTheme.gd")
const NovaSVG = preload("res://ui/novaswift/NovaSVG.gd")

signal new_pilot
signal open_pilot
signal settings
signal game_data
signal plugins
signal plugin_editor
signal multiplayer_hub
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
	if has_data:
		ShellUI.button(box, "Plug-ins", func(): plugins.emit(), nova)
		ShellUI.button(box, "Plugin Editor", func(): plugin_editor.emit(), nova)
		ShellUI.button(box, "Multiplayer", func(): multiplayer_hub.emit(), nova)
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

	# Port-only extras, kept off the original's artwork: Plug-ins and the Plugin Editor, as clean
	# glass pills in the bottom-left corner (NovaSwift's own controls, not EV Nova button art).
	# Game Data is not offered here: missing data opens the setup wizard by itself, and
	# Settings > "Re-import / Change Game Data…" covers changing it.
	_extra = Control.new()
	_extra.set_anchors_preset(Control.PRESET_FULL_RECT)
	_extra.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_extra)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	row.grow_vertical = Control.GROW_DIRECTION_BEGIN
	row.offset_left = 18
	row.offset_bottom = -18
	row.offset_top = -18
	_extra.add_child(row)
	var pg := _pill(row, "Plug-ins", "puzzlepiece.extension.fill", "Browse, install and order plug-ins", func():
		nova.sound_beep(1)
		plugins.emit())
	var pe := _pill(row, "Plugin Editor", "wrench.and.screwdriver", "Create and edit plug-ins", func():
		nova.sound_beep(1)
		plugin_editor.emit())
	var mp := _pill(row, "Multiplayer", "person.2.fill", "Host, join by address, LAN and dedicated servers", func():
		nova.sound_beep(1)
		multiplayer_hub.emit())
	pg.focus_neighbor_right = pg.get_path_to(pe)
	pe.focus_neighbor_left = pe.get_path_to(pg)
	pe.focus_neighbor_right = pe.get_path_to(mp)
	mp.focus_neighbor_left = mp.get_path_to(pe)
	mp.focus_neighbor_top = mp.get_path_to(classic_menu.buttons["quit"]) if classic_menu.buttons.get("quit") != null else NodePath()
	var q = classic_menu.buttons.get("quit")
	if q != null:
		q.focus_neighbor_bottom = q.get_path_to(pg)
		pg.focus_neighbor_top = pg.get_path_to(q)
		pe.focus_neighbor_top = pe.get_path_to(q)

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


## A NovaSwift "glass pill" for the port-only extras over the Classic artwork: smoked dark glass,
## a hairline rim that warms to amber on hover / focus, an SVG glyph and a semibold label.
func _pill(parent: Control, text: String, glyph: String, tip: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.tooltip_text = tip
	b.focus_mode = Control.FOCUS_ALL
	var scale: float = maxf(1.0, DisplayServer.screen_get_scale()) if DisplayServer.get_name() != "headless" else 1.0
	b.icon = NovaSVG.texture(glyph, int(round(16.0 * scale)), NovaTheme.AMBER)
	b.add_theme_constant_override("icon_max_width", 16)
	b.add_theme_constant_override("h_separation", 8)
	b.add_theme_font_override("font", NovaTheme.font("body", "semibold"))
	b.add_theme_font_size_override("font_size", 13)
	var white := Color(1, 1, 1, 0.92)
	for c in ["font_color", "font_focus_color", "font_hover_color", "font_pressed_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(c, white)
	var pad := Vector2(16, 9)
	var amber := NovaTheme.AMBER
	b.add_theme_stylebox_override("normal", NovaTheme.box(Color(0.03, 0.03, 0.035, 0.78), 18, Color(1, 1, 1, 0.16), 1, pad))
	b.add_theme_stylebox_override("hover", NovaTheme.box(Color(0.09, 0.075, 0.05, 0.9), 18, Color(amber.r, amber.g, amber.b, 0.75), 1, pad))
	b.add_theme_stylebox_override("pressed", NovaTheme.box(Color(amber.r, amber.g, amber.b, 0.28), 18, amber, 1, pad))
	b.add_theme_stylebox_override("hover_pressed", NovaTheme.box(Color(amber.r, amber.g, amber.b, 0.28), 18, amber, 1, pad))
	b.add_theme_stylebox_override("focus", NovaTheme.box(Color(0, 0, 0, 0), 18, amber, 2, pad))
	b.pressed.connect(cb)
	parent.add_child(b)
	return b


# About Nova: the data's own dësc 32767.
func _show_about() -> void:
	var nova: Object = classic_menu.nova if classic_menu != null else _nova
	if nova == null or nova.classic_desc_text(32767) == "":
		return
	if classic_menu != null:
		classic_menu.blocked = true
	# AboutNovaText: the NovaSwift header over dësc 32767, in the generic dësc dialog.
	# The picture variant when dësc 32767 has a Graphic (Apple DescTextDialog graphicID:).
	var pict: int = int(nova.classic_desc_graphic(32767)) if nova.has_method("classic_desc_graphic") else -1
	var d = ClassicDialog.desc_dialog(nova, nova.about_nova_text(str(ProjectSettings.get_setting("application/config/version", "0.7.0"))), pict)
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
	var pict: int = int(nova.classic_desc_graphic(32766)) if nova.has_method("classic_desc_graphic") else -1
	var d = ClassicDialog.desc_dialog(nova, nova.classic_desc_text(32766), pict)
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


## Leave the menu for the game. A playing title track fades out (8/256 per 60 Hz tick, the
## original's 0x004ab820, as Apple's `setMusicAllowed(false)`), so the menu lingers invisible and
## inert until the fade ends; with no music it frees at once.
func leave() -> void:
	if music != null and is_instance_valid(music) and music.has_method("fade_out") and bool(music.playing):
		visible = false
		if classic_menu != null:
			classic_menu.blocked = true
		set_process_unhandled_input(false)
		set_process_unhandled_key_input(false)
		music.faded.connect(queue_free)
		music.fade_out()
	else:
		queue_free()


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
