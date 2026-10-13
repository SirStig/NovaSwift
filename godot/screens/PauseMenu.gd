# NOVA Swift — in-flight pause menu (Esc / pad Start).
#
# Resume · Settings · Save & Quit to menu · Quit. The flight sim is paused by
# Main.gd while this is up. It only reports the choice; Main.gd does the saving
# and screen changes. Esc / B / Start again resume.
extends CanvasLayer

const ShellUI = preload("res://screens/ShellUI.gd")

signal resume
signal settings
signal player_info
signal save_quit_to_menu
signal quit

var first_button: Button
var buttons: Array[Button] = []


func setup(nova: Object, can_save: bool) -> void:
	layer = 60
	var root := ShellUI.screen(self, 0.78)
	var box := ShellUI.panel(root, 340, 8)
	ShellUI.title(box, "Paused", 28)
	first_button = ShellUI.button(box, "Resume", func(): resume.emit(), nova)
	buttons.append(first_button)
	buttons.append(ShellUI.button(box, "Player Info", func(): player_info.emit(), nova))
	buttons.append(ShellUI.button(box, "Settings", func(): settings.emit(), nova))
	if can_save:
		buttons.append(ShellUI.button(box, "Save & Quit to Menu", func(): save_quit_to_menu.emit(), nova))
	buttons.append(ShellUI.button(box, "Quit", func(): quit.emit(), nova))
	ShellUI.focus(first_button)


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("pause_menu"):
		get_viewport().set_input_as_handled()
		resume.emit()


## Hide while a sub-screen (Settings) is on top, show again after.
func set_active(on: bool) -> void:
	visible = on
	if on:
		ShellUI.focus(first_button)
