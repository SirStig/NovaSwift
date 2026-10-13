# NOVA Swift — in-flight pause menu (Esc / pad Start).
#
# Resume · Settings · Save & Quit to menu · Quit. The flight sim is paused by
# Main.gd while this is up. It only reports the choice; Main.gd does the saving
# and screen changes. Esc / B / Start again resume.
#
# Presentation: with the data loaded and Settings > Presentation > "Modern dialogs"
# off (the default), this is drawn in the Classic UI kit (ui/classic/): the app's
# dësc dialog frame (PICT 8524/8525/8526) with the original three-state buttons.
# Otherwise the plain Nova Swift panel below. Same signals, same button order.
extends CanvasLayer

const ShellUI = preload("res://screens/ShellUI.gd")
const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")
const ClassicDialog = preload("res://ui/classic/ClassicDialog.gd")

signal resume
signal settings
signal player_info
signal save_quit_to_menu
signal quit

var first_button: Control
var buttons: Array[Control] = []
var classic_dialog: Control     # the ClassicDialog when drawn in Classic presentation


func setup(nova: Object, can_save: bool) -> void:
	layer = 60
	ClassicTheme.setup(nova)
	if ClassicTheme.classic("dialogs"):
		_setup_classic(nova, can_save)
		return
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


func _setup_classic(nova: Object, can_save: bool) -> void:
	var specs := [
		{"label": "Resume", "action": func(): resume.emit()},
		{"label": "Player Info", "action": func(): player_info.emit()},
		{"label": "Settings", "action": func(): settings.emit()},
	]
	if can_save:
		specs.append({"label": "Save & Quit to Menu", "action": func(): save_quit_to_menu.emit()})
	specs.append({"label": "Quit", "action": func(): quit.emit()})
	classic_dialog = ClassicDialog.panel(nova, {"title": "Paused", "body_buttons": specs, "body_buttons_width": 220})
	ClassicDialog.modal(self, classic_dialog, 0.78)
	for i in specs.size():
		buttons.append(classic_dialog.item(i))
	first_button = buttons[0]


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
		if classic_dialog != null:
			classic_dialog.focus_first.call_deferred()
		else:
			ShellUI.focus(first_button)
