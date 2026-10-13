# NOVA Swift — "where is your EV Nova data?" screen.
#
# Shown at startup when no data is found (instead of silently dropping into the
# demo world), and from the main menu's "Game Data…" button. Same ground rules as
# the Apple app's DataSetupWizard: NOVA Swift never ships or fetches EV Nova's
# data; it only reads a copy the player already owns. The folder to point at is
# the game's "Nova Files" folder (or the folder that contains it) — anything
# holding the .ndat / .rez files.
#
# Folder picker: Godot's own FileDialog (non-native, so it's a Control the
# gamepad can drive with focus navigation, which the OS pickers aren't). Typing
# a path is also supported. The chosen folder is validated by loading it, then
# saved to settings ([data] dir) and reported through `data_found`.
extends CanvasLayer

const ShellUI = preload("res://screens/ShellUI.gd")
const Prefs = preload("res://Prefs.gd")

## A folder that loads as EV Nova data was chosen/found (already saved to settings).
signal data_found(dir: String)
## "Run demo" — play the data-free demo world.
signal run_demo
signal quit
## Esc / B pressed. Main goes back to the main menu if that's where it came from.
signal back

var path_edit: LineEdit
var first_button: Button

var _nova: Object
var _root: Control
var _status: Label
var _dialog: FileDialog


func setup(nova: Object, allow_demo := true) -> void:
	_nova = nova
	layer = 55
	_root = ShellUI.screen(self, 1.0)
	var box := ShellUI.panel(_root, 700, 8)
	ShellUI.title(box, "Find your EV Nova data", 28)
	ShellUI.label(box, "NOVA Swift plays the EV Nova you already own — it doesn't include or download any game data. Point it at your copy: the game's Nova Files folder (or the folder containing it) with the .ndat / .rez files inside.", 15, ShellUI.TEXT)
	ShellUI.label(box, "Easiest: unzip the Windows build of EV Nova and choose that folder. Or drop the files into one of the places below and press Rescan:", 15)
	var places := PackedStringArray()
	for d in Prefs.data_candidates():
		places.append("  " + d)
	ShellUI.label(box, "\n".join(places), 13, ShellUI.MUTED)

	first_button = ShellUI.button(box, "Choose Folder…", _open_picker)
	path_edit = LineEdit.new()
	path_edit.placeholder_text = "…or type a folder path and press Enter"
	path_edit.custom_minimum_size = Vector2(0, 38)
	path_edit.text_submitted.connect(try_dir)
	box.add_child(path_edit)
	ShellUI.button(box, "Rescan Default Locations", _rescan)
	if allow_demo:
		ShellUI.button(box, "Run Demo (no data)", func(): run_demo.emit())
	ShellUI.button(box, "Quit", func(): quit.emit())
	_status = ShellUI.label(box, "", 14, Color(1.0, 0.6, 0.5))
	ShellUI.focus(first_button)

	_dialog = FileDialog.new()
	_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_dialog.use_native_dialog = false
	_dialog.title = "Choose your EV Nova data folder"
	_dialog.size = Vector2i(900, 560)
	_dialog.dir_selected.connect(try_dir)
	_dialog.theme = ShellUI.theme()
	add_child(_dialog)


func _open_picker() -> void:
	var home := OS.get_environment("HOME")
	if home == "":
		home = OS.get_environment("USERPROFILE")
	if home != "":
		_dialog.current_dir = home
	_dialog.popup_centered()


func _rescan() -> void:
	var dir := Prefs.find_data(_nova)
	if dir == "":
		_status.text = "No EV Nova data found in any of those locations yet."
	else:
		_found(dir)


## Validate a chosen folder by loading it; on success persist and report it.
func try_dir(dir: String) -> bool:
	dir = dir.strip_edges()
	if dir == "" or not DirAccess.dir_exists_absolute(dir):
		_status.text = "That folder doesn't exist."
		return false
	if not _nova.load_game(dir):
		_status.text = "No EV Nova data in that folder. Pick the whole game folder (or its Nova Files folder)."
		return false
	_found(dir)
	return true


func _found(dir: String) -> void:
	Prefs.set_value("data", "dir", dir)
	Prefs.save()
	data_found.emit(dir)


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and not _dialog.visible:
		get_viewport().set_input_as_handled()
		back.emit()
