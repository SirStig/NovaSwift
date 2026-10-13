# NOVA Swift updater -- the small progress window shown in updater mode (see UpdaterMode.gd).
#
# Deliberately plain Controls, no theme / kit / data / bridge dependency. Steps:
#   1. wait for the game process (--pid) to exit (up to --wait seconds)
#   2. recover any half-finished earlier swap, then UpdateInstall.apply() on a worker thread
#   3. write user://update/state.json for the next game start ("installed" or "failed")
#   4. start the launcher (the new version, or the restored old one after a failure) and quit
extends Control

const UpdateConfig = preload("res://updater/UpdateConfig.gd")
const UpdateInstall = preload("res://updater/UpdateInstall.gd")
const UpdaterMode = preload("res://updater/UpdaterMode.gd")

var _opts: Dictionary = {}
var _status: Label
var _bar: ProgressBar
var _detail: Label
var _button: Button
var _thread: Thread
var _result: Dictionary = {}
var _progress: Vector2i = Vector2i.ZERO
var _phase: String = "wait"
var _waited: float = 0.0
var _poll: float = 0.0
var _relaunch_at: float = -1.0
var _failed_message: String = ""


func setup(opts: Dictionary) -> void:
	_opts = opts
	set_anchors_preset(Control.PRESET_FULL_RECT)
	_build()
	if DisplayServer.get_name() != "headless":
		DisplayServer.window_set_title("NovaSwift Updater")
		DisplayServer.window_set_size(Vector2i(560, 220))
		var scr: Vector2i = DisplayServer.screen_get_size()
		DisplayServer.window_set_position((scr - Vector2i(560, 220)) / 2)
	print("NOVA Swift updater: install=%s staging=%s pid=%d" % [opts["install_dir"], opts["staging"], int(opts["pid"])])


func _build() -> void:
	var bg: ColorRect = ColorRect.new()
	bg.color = Color(0.06, 0.06, 0.08)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var box: VBoxContainer = VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.offset_left = 28
	box.offset_right = -28
	box.offset_top = 24
	box.offset_bottom = -20
	box.add_theme_constant_override("separation", 12)
	add_child(box)
	var title: Label = Label.new()
	title.text = "NovaSwift Updater"
	title.add_theme_font_size_override("font_size", 22)
	title.add_theme_color_override("font_color", Color(1.0, 0.7, 0.28))
	box.add_child(title)
	_status = Label.new()
	_status.text = "Waiting for NovaSwift to close..."
	_status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_status)
	_bar = ProgressBar.new()
	_bar.min_value = 0.0
	_bar.max_value = 1.0
	_bar.show_percentage = false
	_bar.custom_minimum_size = Vector2(0, 14)
	box.add_child(_bar)
	_detail = Label.new()
	_detail.modulate = Color(1, 1, 1, 0.6)
	_detail.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	box.add_child(_detail)
	_button = Button.new()
	_button.text = "Quit"
	_button.visible = false
	_button.pressed.connect(func() -> void: get_tree().quit())
	box.add_child(_button)


func _process(delta: float) -> void:
	match _phase:
		"wait":
			_poll += delta
			_waited += delta
			if _poll < 0.25:
				return
			_poll = 0.0
			var pid: int = int(_opts.get("pid", 0))
			if not UpdaterMode.pid_alive(pid):
				_start_swap()
			elif _waited > float(maxi(5, int(_opts.get("wait", 30)))):
				_fail("NovaSwift did not close in time, so nothing was changed.", false)
		"swap":
			_bar.value = float(_progress.x) / float(maxi(1, _progress.y))
			if _thread != null and not _thread.is_alive():
				_result = _thread.wait_to_finish()
				_thread = null
				_finish_swap()
		"relaunch":
			if _relaunch_at >= 0.0:
				_relaunch_at -= delta
				if _relaunch_at <= 0.0:
					_relaunch_at = -1.0
					_relaunch_and_quit()


func _start_swap() -> void:
	_phase = "swap"
	_status.text = "Installing the update..."
	_detail.text = "Replacing game files. Please do not turn off your device."
	var install: String = str(_opts["install_dir"])
	var staging: String = str(_opts["staging"])
	if not DirAccess.dir_exists_absolute(staging) or not DirAccess.dir_exists_absolute(install):
		_fail("The downloaded update was not found, so nothing was changed.", true)
		return
	var root: String = UpdateInstall.payload_root(staging)
	var retries: int = 24 if OS.get_name() == "Windows" else 2
	_thread = Thread.new()
	var opts: Dictionary = {"retries": retries, "progress": Callable(self, "_on_progress")}
	_thread.start(_do_swap.bind(install, root, opts))


func _do_swap(install: String, root: String, opts: Dictionary) -> Dictionary:
	return UpdateInstall.apply(install, root, opts)


func _on_progress(done: int, total: int) -> void:
	_progress = Vector2i(done, total)


func _finish_swap() -> void:
	var install: String = str(_opts["install_dir"])
	var staging: String = str(_opts["staging"])
	if bool(_result.get("ok", false)):
		UpdateInstall.remove_tree(staging)
		UpdateInstall.write_state({"status": "installed", "from": str(_opts["from"]), "to": str(_opts["to"]),
			"install_dir": install})
		_bar.value = 1.0
		_status.text = "Update installed. Starting NovaSwift..."
		_detail.text = ""
	else:
		UpdateInstall.remove_tree(staging)
		_fail(str(_result.get("error", "The update could not be installed.")), true)
		return
	_phase = "relaunch"
	_relaunch_at = 0.6


## A failure: record it for the next start, restore the old version (already rolled back), start it.
func _fail(message: String, relaunch: bool) -> void:
	_failed_message = message
	var text: String = message
	UpdateInstall.write_state({"status": "failed", "from": str(_opts.get("from", "")), "to": str(_opts.get("to", "")),
		"error": text, "install_dir": str(_opts.get("install_dir", ""))})
	_status.text = "The update could not be installed."
	_detail.text = message + ("\nYour previous version is being restored." if relaunch else "")
	if relaunch:
		_phase = "relaunch"
		_relaunch_at = 2.5
	else:
		# The game never closed: it is still running, so do not start a second one.
		_phase = "done"
		_detail.text = message + "\nNothing was changed."
		_button.visible = true


func _relaunch_and_quit() -> void:
	var target: String = str(_opts.get("relaunch", ""))
	if target == "" or not FileAccess.file_exists(target):
		var install: String = str(_opts.get("install_dir", ""))
		var cands: PackedStringArray = PackedStringArray([install.path_join("NovaSwift.sh"),
			install.path_join("NovaSwift.exe"), install.path_join("NovaSwift.x86_64")])
		target = ""
		for c in cands:
			if FileAccess.file_exists(c):
				target = c
				break
	if target == "":
		_status.text = "Please start NovaSwift manually."
		_detail.text = _failed_message + "\nThe launcher could not be found in " + str(_opts.get("install_dir", ""))
		_button.visible = true
		return
	var pid: int = OS.create_process(target, PackedStringArray())
	if pid <= 0:
		_status.text = "Please start NovaSwift manually."
		_detail.text = "The updater could not start " + target
		_button.visible = true
		return
	get_tree().quit()
