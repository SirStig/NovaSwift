# NOVA Swift — "where is your EV Nova data?" screen (the Apple app's DataSetupWizard Import step,
# drawn as its NovaDialog: amber title, text body, footer buttons -- the original dialog frame in
# Classic presentation, the modern chrome with "Modern dialog chrome" on, a plain card without data).
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
const T = preload("res://ui/novaswift/NovaTheme.gd")
const NC = preload("res://ui/novaswift/NovaControls.gd")
const Chrome = preload("res://ui/novaswift/NovaChrome.gd")

## A folder that loads as EV Nova data was chosen/found (already saved to settings).
signal data_found(dir: String)
## "Run demo" — play the data-free demo world.
signal run_demo
signal quit
## Esc / B pressed. Main goes back to the main menu if that's where it came from.
signal back

var path_edit: LineEdit
var first_button: Control
var dialog: Dictionary

var _nova: Object
var _root: Control
var _status: Label
var _dialog: FileDialog


func setup(nova: Object, allow_demo := true) -> void:
	_nova = nova
	layer = 55
	var specs := []
	if allow_demo:
		specs.append({"text": "Run Demo (no data)", "cb": func(): run_demo.emit()})
	specs.append({"text": "Quit", "cb": func(): quit.emit()})
	specs.append({"text": "Choose Folder…", "default": true, "cb": _open_picker})
	dialog = Chrome.dialog(self, {"title": "Find your EV Nova data", "width": 560.0, "buttons": specs})
	_root = dialog.root
	var box: VBoxContainer = dialog.body
	first_button = dialog.buttons["Choose Folder…"]
	NC.label(box, "NOVA Swift plays the EV Nova you already own — it doesn't include or download any game data. Point it at your copy: the game's Nova Files folder (or the folder containing it) with the .ndat / .rez files inside.", "body", "regular", T.WHITE, true)
	NC.label(box, "Easiest: unzip the Windows build of EV Nova and choose that folder. Or drop the files into one of the places below and press Rescan:", "body", "regular", T.SECONDARY, true)
	var places := PackedStringArray()
	for d in Prefs.data_candidates():
		places.append("  " + d)
	NC.label(box, "\n".join(places), "caption", "regular", T.TERTIARY, true)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	path_edit = NC.text_field("…or type a folder path and press Enter")
	path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_edit.text_submitted.connect(try_dir)
	row.add_child(path_edit)
	row.add_child(NC.button("Rescan Default Locations", "bordered", _rescan, "arrow.clockwise"))
	_status = NC.label(box, "", "caption", "regular", Color(1.0, 0.6, 0.5), true)

	_dialog = FileDialog.new()
	_dialog.file_mode = FileDialog.FILE_MODE_OPEN_DIR
	_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_dialog.use_native_dialog = false
	_dialog.title = "Choose your EV Nova data folder"
	_dialog.size = Vector2i(900, 560)
	_dialog.dir_selected.connect(try_dir)
	_dialog.theme = T.theme()
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
