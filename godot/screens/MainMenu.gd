# NOVA Swift — startup main menu (New Pilot / Open Pilot / Settings / Quit).
#
# Shown before the pilot screen when real data is loaded. Modelled on the Apple
# app's ModernMainMenuView: the NOVA SWIFT wordmark over a dark star-field, a
# column of buttons below it. Pure Godot focus navigation (arrows / d-pad / left
# stick, Enter / A); no hover sounds, as in the original's menus. The title music
# (audio/TitleMusic.gd) plays only while this menu is up.
#
# The menu only reports what was chosen; Main.gd decides what happens next.
extends CanvasLayer

const ShellUI = preload("res://screens/ShellUI.gd")
const TitleMusic = preload("res://audio/TitleMusic.gd")

signal new_pilot
signal open_pilot
signal settings
signal game_data
signal quit

var music: Node   # TitleMusic, or null
var first_button: Button
var _root: Control


func setup(nova: Object, data_dir: String, has_data: bool) -> void:
	layer = 50
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
	ShellUI.button(box, "Quit", func(): quit.emit(), nova)
	ShellUI.focus(first_button)

	if has_data:
		music = TitleMusic.new()
		music.name = "TitleMusic"
		add_child(music)
		music.start(nova, data_dir)


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
