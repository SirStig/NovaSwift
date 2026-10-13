# NOVA Swift — Data Setup wizard: the Godot port of the Apple app's DataSetupWizard
# (app/NovaSwift/Launcher/DataSetupWizard.swift) over the shared importer (NovaSwiftPluginStore.GameDataImport,
# reached through the bridge's data_import_* methods).
#
# Bring-your-own-data: NOVA Swift never ships or fetches EV Nova's data; it copies a set the player already
# owns into a managed folder (Prefs.managed_data_dir) and plays from there. With no valid data this is the ONLY
# screen the app shows (plus Quit and Settings); after a successful import the shell goes
# straight to the main menu. Settings > Data & Advanced > "Re-import / Change Game Data" opens it again.
#
#   welcome -> ownership -> [acquire_intro -> acquire_register -> acquire_run] -> locate -> source
#           -> inspect (results) -> import (progress / cancel) -> success
#
# "I already have my files" jumps from welcome (or Re-import opens straight) to `source`. Picking a source: an
# in-app, controller-friendly browser (ui/novaswift/DataFileBrowser.gd), the native file dialog on desktops,
# a typed path, installs the background scanner found, and recently used sources.
extends CanvasLayer

const Prefs = preload("res://Prefs.gd")
const T = preload("res://ui/novaswift/NovaTheme.gd")
const NC = preload("res://ui/novaswift/NovaControls.gd")
const Chrome = preload("res://ui/novaswift/NovaChrome.gd")
const Importer = preload("res://DataImporter.gd")
const Scanner = preload("res://DataScanner.gd")
const Browser = preload("res://ui/novaswift/DataFileBrowser.gd")

## The import finished and the managed folder is ready (path). The shell loads it.
signal data_found(dir: String)
signal quit
## Esc / B pressed on the first page of a re-import (never emitted while gated).
signal back
## The Settings button (display / controls / audio are usable without data).
signal settings_requested

const PLATFORMS := ["windows", "mac", "steamdeck", "linux"]
const PLATFORM_LABELS := ["Windows", "Mac", "Steam Deck", "Linux"]

## No valid data exists: nothing may be dismissed (only Quit / Settings / Plug-in Editor).
var gated := false
var dialog: Dictionary
var first_button: Control
var path_edit: LineEdit
var step := ""
var platform := "linux"
var source_path := ""
var inspection: Dictionary = {}
var import_status: Dictionary = {}
var copy_plugins := true

var _nova: Object
var _history: Array = []
var _owns := 0               # 0 unknown, 1 yes, -1 no
var _status: Label
var _found_box: VBoxContainer
var _scanner: RefCounted
var _scan_label: Label
var _browser: CanvasLayer
var _native: FileDialog
var _poll := 0.0
var _phase_label: Label
var _bar: ProgressBar
var _count_label: Label
var _wait_label: Label
var _dots := 0.0
var _load_error := ""


## opts: {gated: bool, start_at_source: bool}
func setup(nova: Object, opts: Dictionary = {}) -> void:
	_nova = nova
	layer = 55
	gated = bool(opts.get("gated", false))
	platform = Importer.platform()
	copy_plugins = bool(Prefs.get_value("data", "import_plugins"))
	if bool(opts.get("start_at_source", false)):
		_owns = 1
		_show("source")
	else:
		_show("welcome")


# --- step plumbing ---------------------------------------------------------------------

func _sequence() -> Array:
	if _owns == 1:
		return ["welcome", "ownership", "locate", "source", "inspect", "import", "success"]
	if _owns == -1:
		return ["welcome", "ownership", "acquire_intro", "acquire_register", "acquire_run", "locate", "source", "inspect", "import", "success"]
	return ["welcome", "ownership"]


func _go(next: String) -> void:
	if step != "" and step != next:
		_history.append(step)
	_show(next)


func _back() -> void:
	if _history.is_empty():
		if gated:
			return
		back.emit()
		return
	var prev: String = _history.pop_back()
	_show(prev)


## Rebuild the dialog for `s` (footer buttons differ per step, so it is rebuilt, not mutated).
func _show(s: String) -> void:
	_teardown_dialog()
	step = s
	_phase_label = null
	_bar = null
	_count_label = null
	_wait_label = null
	match s:
		"welcome": _build_welcome()
		"ownership": _build_ownership()
		"acquire_intro": _build_acquire(0)
		"acquire_register": _build_acquire(1)
		"acquire_run": _build_acquire(2)
		"locate": _build_locate()
		"source": _build_source()
		"inspect": _build_inspect()
		"import": _build_import()
		"success": _build_success()
		"failure": _build_failure()
	if s == "source":
		_start_scan()


func _teardown_dialog() -> void:
	if not dialog.is_empty() and is_instance_valid(dialog.root):
		dialog.root.queue_free()
	dialog = {}
	first_button = null
	path_edit = null
	_found_box = null
	_status = null
	_scan_label = null


## A fresh dialog for this step. `buttons` use the NovaDialog spec ({text, default, cancel, enabled, cb}).
func _dlg(title: String, buttons: Array, width := 640.0) -> VBoxContainer:
	var seq := _sequence()
	dialog = Chrome.dialog(self, {"title": title, "width": width, "buttons": buttons})
	var box: VBoxContainer = dialog.body
	var i := seq.find(step)
	if i >= 0 and step != "success" and step != "welcome":
		NC.label(box, "Step %d of %d" % [i + 1, seq.size()], "caption", "semibold", T.TERTIARY)
		box.move_child(box.get_child(box.get_child_count() - 1), 0 if title == "" else 1)
	for b in dialog.buttons.values():
		if first_button == null:
			first_button = b
	if dialog.get("default") != null:
		first_button = dialog["default"]
	return box


func _back_spec() -> Dictionary:
	if _history.is_empty() and gated:
		return {"text": "Quit", "cb": func(): quit.emit()}
	return {"text": "Close" if _history.is_empty() else "Back", "cancel": true, "cb": _back}


func _text(box: Node, t: String, secondary := false) -> Label:
	return NC.label(box, t, "body", "regular", T.SECONDARY if secondary else T.WHITE, true)


func _link(box: Node, label: String, url: String) -> void:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	row.add_child(NC.button(label, "bordered", func(): OS.shell_open(url), "arrow.right"))
	NC.label(row, url, "caption", "regular", T.TERTIARY)


func _extras(box: Node) -> void:
	# Things allowed without data: Settings (display / controls / audio).
	if not gated:
		return
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	row.add_child(NC.button("Settings", "bordered", func(): settings_requested.emit(), "gearshape.fill"))


# --- pages ---------------------------------------------------------------------------------

func _build_welcome() -> void:
	var specs: Array = []
	specs.append({"text": "Quit" if gated else "Close", "cancel": not gated, "cb": func(): (quit.emit() if gated else back.emit())})
	specs.append({"text": "I Already Have My Files", "cb": func():
		_owns = 1
		_go("source")})
	specs.append({"text": "Next", "default": true, "cb": func(): _go("ownership")})
	var box := _dlg("Welcome to NOVA Swift", specs)
	_text(box, "NOVA Swift is the engine: it runs EV Nova on your %s. The game's data (ships, missions, art and sound) is copyrighted, so it isn't included." % _platform_name())
	_text(box, "You bring your own copy once, like slotting a cartridge into a console. Your files are copied into NOVA Swift's own folder and never changed or shared with anyone.", true)
	NC.label(box, "Until the data is imported there is nothing to play, so this is the only screen.", "caption", "regular", T.TERTIARY, true)
	_extras(box)


func _build_ownership() -> void:
	var box := _dlg("Do you have EV Nova?", [_back_spec()])
	_text(box, "First things first: do you already have EV Nova, or the data files from it?")
	var yes := NC.button("Yes, I own it or have the files   (go straight to importing)", "primary", func():
		_owns = 1
		_go("locate"), "checkmark.circle.fill")
	box.add_child(yes)
	var no := NC.button("Not yet, or I'm not sure   (show me how to get it)", "bordered", func():
		_owns = -1
		_go("acquire_intro"), "info.circle")
	box.add_child(no)
	first_button = yes
	Chrome.T_focus(yes)


func _build_acquire(page: int) -> void:
	var titles := ["Getting EV Nova", "Register your copy", "Get it running"]
	var box := _dlg(titles[page], [_back_spec(), {"text": "Next", "default": true, "cb": func(): _go(["acquire_register", "acquire_run", "locate"][page])}])
	match page:
		0:
			_text(box, "EV Nova isn't sold in any store any more: Ambrosia Software closed, and it was never released on Steam, GOG or an app store.")
			_text(box, "If you owned it before, you can still register and run your own copy. NOVA Swift can't give you the game; it only runs data you legally own.")
			_text(box, "Owning and registering EV Nova is fine; sharing its data files is not. NOVA Swift never includes the game, it just reads yours.", true)
		1:
			_text(box, "Decoder Ring, released in 2023 by Ambrosia's former president Andrew Welch, creates a valid registration code for a copy you own. It's the community-blessed way to register on a modern Mac.")
			_text(box, "It's only needed to run the classic app. Just want the data for NOVA Swift? Skip ahead: the Windows download on the next page needs no registration.", true)
			_link(box, "Find Decoder Ring", Importer.EVSTUFF_URL)
		2:
			_text(box, "Easiest: download the Windows build's .zip from the community page. No installing, no registration: NOVA Swift reads the .zip as it is (or unzip it and pick the folder).")
			_text(box, "On a Mac you can also install the community \"EV Nova mod 4\" build and launch it once: its Nova Files folder is ready to import too.", true)
			_link(box, "Get EV Nova", Importer.EVSTUFF_URL)
			NC.label(box, "On a Steam Deck: download in Desktop Mode (Firefox saves to ~/Downloads), then come back here.", "caption", "regular", T.TERTIARY, true)


func _platform_name() -> String:
	match platform:
		"windows": return "PC"
		"mac": return "Mac"
		"steamdeck": return "Steam Deck"
	return "computer"


func _build_locate() -> void:
	var box := _dlg("Where is my EV Nova?", [_back_spec(), {"text": "Next", "default": true, "cb": func(): _go("source")}], 680.0)
	var seg := NC.segmented(box, PLATFORM_LABELS, maxi(0, PLATFORMS.find(platform)), func(i: int):
		platform = PLATFORMS[i]
		_show("locate"))
	seg.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text(box, _guide_text(platform))
	var recs := PackedStringArray()
	recs.append("What to look for: a folder called \"Nova Files\" holding Nova Data 1.rez ... (Windows) or Nova Data 1.ndat ... (Mac), or the Windows .zip itself.")
	NC.label(box, recs[0], "caption", "regular", T.SECONDARY, true)


func _guide_text(p: String) -> String:
	match p:
		"windows":
			return "Your EV Nova folder is the one containing EV Nova.exe, with a Nova Files folder inside: a Community Edition install such as C:\\Program Files (x86)\\EV Nova or C:\\Games\\EV Nova. If you downloaded the Windows .zip you don't even need to unzip it. Pick the .zip, the game folder, or its Nova Files folder."
		"mac":
			return "On a Mac, EV Nova lives in Applications, with its Nova Files folder next to (or, for the community mod build, inside) EV Nova.app: right-click the app and choose Show Package Contents to look inside. Pick the whole game folder, or the Nova Files folder."
		"steamdeck":
			return "In Desktop Mode, get the game onto the Deck: from a USB stick or SD card (they show up under /run/media/...), by downloading the Windows .zip with Firefox (it lands in ~/Downloads), or over your network. Then come back to Game Mode: the browser on the next page has shortcuts for Home, Downloads and your SD card, and it works with the pad (A open, B up, Y use this folder)."
	return "Pick the folder that holds EV Nova.exe and Nova Files (for example under ~/.wine/drive_c/Program Files (x86)/EV Nova, or wherever you unzipped the Windows build), its Nova Files folder, or the Windows .zip itself."


func _build_source() -> void:
	var specs: Array = [_back_spec()]
	if _native_dialog_available():
		specs.append({"text": "System Dialog…", "cb": _open_native})
	specs.append({"text": "Browse…", "default": true, "cb": _open_browser})
	var box := _dlg("Choose your EV Nova data", specs, 700.0)
	_text(box, "Pick the game folder, its Nova Files folder, a single .rez / .ndat file, or the Windows .zip. Picking the whole folder also brings the music, fonts, race movies and plug-ins.")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	path_edit = NC.text_field("…or type a path and press Enter")
	path_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	path_edit.text_submitted.connect(func(t: String): try_source(t))
	row.add_child(path_edit)
	row.add_child(NC.button("Use", "bordered", func(): try_source(path_edit.text)))
	_status = NC.label(box, "", "caption", "regular", T.RED, true)
	var recents := Prefs.recent_sources()
	if not recents.is_empty():
		NC.label(box, "Recent", "caption", "semibold", T.SECONDARY)
		for r in recents:
			if FileAccess.file_exists(r) or DirAccess.dir_exists_absolute(r):
				box.add_child(_source_button(r, "clock.arrow.circlepath"))
	NC.label(box, "Found on this device", "caption", "semibold", T.SECONDARY)
	_found_box = VBoxContainer.new()
	_found_box.add_theme_constant_override("separation", 4)
	box.add_child(_found_box)
	_scan_label = NC.label(box, "", "caption", "regular", T.TERTIARY)
	_extras(box)


func _source_button(path: String, icon_name := "folder") -> Button:
	var b := NC.button(path, "bordered", func(): try_source(path), icon_name)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.clip_text = true
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return b


func _start_scan() -> void:
	_scanner = Scanner.new()
	if _scan_label != null:
		_scan_label.text = "Looking for EV Nova installs..."


func _native_dialog_available() -> bool:
	if platform == "steamdeck" or DisplayServer.get_name() == "headless":
		return false
	return DisplayServer.has_feature(DisplayServer.FEATURE_NATIVE_DIALOG_FILE)


func _open_native() -> void:
	if _native == null:
		_native = FileDialog.new()
		_native.access = FileDialog.ACCESS_FILESYSTEM
		_native.file_mode = FileDialog.FILE_MODE_OPEN_ANY
		_native.use_native_dialog = true
		_native.title = "Choose your EV Nova folder or file"
		_native.filters = PackedStringArray(["*.zip,*.rez,*.ndat ; EV Nova data"])
		_native.file_selected.connect(func(p: String): try_source(p))
		_native.dir_selected.connect(func(p: String): try_source(p))
		add_child(_native)
	var home := Prefs.user_home()
	if home != "":
		_native.current_dir = home
	_native.popup_centered(Vector2i(900, 560))


func _open_browser() -> void:
	if _browser != null:
		return
	var start := Prefs.user_home()
	var recents := Prefs.recent_sources()
	if not recents.is_empty() and DirAccess.dir_exists_absolute(recents[0].get_base_dir()):
		start = recents[0].get_base_dir()
	var list: Array = Importer.shortcuts()
	if _scanner != null:
		for f in _scanner.found:
			var p: String = f["path"]
			list.append({"label": "Found: " + p.get_file(), "path": p if f["kind"] != "zip" else p.get_base_dir()})
	_browser = Browser.new()
	add_child(_browser)
	_browser.open(start, list, "Choose your EV Nova folder, file or zip")
	_browser.chosen.connect(func(p: String):
		_close_browser()
		try_source(p))
	_browser.cancelled.connect(_close_browser)


func _close_browser() -> void:
	if _browser != null:
		_browser.queue_free()
		_browser = null
	if first_button != null and is_instance_valid(first_button):
		Chrome.T_focus(first_button)


## A path was picked / typed: inspect it (deep, off the main thread) and show what was found.
func try_source(path: String) -> bool:
	path = path.strip_edges()
	if path == "" or not (FileAccess.file_exists(path) or DirAccess.dir_exists_absolute(path)):
		if _status != null:
			_status.text = "That path doesn't exist."
		return false
	if not _nova.has_method("data_import_inspect_start"):
		if _status != null:
			_status.text = "This build of the game engine can't import data (data_import_* missing). Rebuild the bridge."
		return false
	source_path = path
	inspection = {}
	_go("inspect")
	return true


func _build_inspect() -> void:
	var done := not inspection.is_empty()
	var specs: Array = [{"text": "Back", "cancel": true, "cb": func():
			_nova.data_import_inspect_cancel()
			_back()}]
	if done:
		specs.append({"text": "Import", "default": true, "enabled": bool(inspection.get("valid", false)), "cb": _begin_import})
	var box := _dlg("What we found" if done else "Reading your files", specs, 700.0)
	if not done:
		_wait_label = NC.label(box, "Reading and checking your files. This can take a few seconds, longer for a zip.", "body", "regular", T.WHITE, true)
		NC.label(box, source_path, "caption", "regular", T.TERTIARY, true)
		if not _nova.data_import_inspect_start(source_path):
			_nova.data_import_inspect_cancel()
			_nova.data_import_inspect_start(source_path)
		return
	_fill_results(box)


func _line(box: Node, ok: int, text: String) -> void:
	# ok: 1 good, 0 note/warn, -1 problem
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	box.add_child(row)
	var mark := "✓" if ok > 0 else ("!" if ok == 0 else "✗")
	var col: Color = T.GREEN if ok > 0 else (T.ORANGE if ok == 0 else T.RED)
	var m := NC.label(row, mark, "body", "bold", col)
	m.custom_minimum_size = Vector2(18, 0)
	m.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	NC.label(row, text, "body", "regular", T.WHITE, true)


func _fill_results(box: VBoxContainer) -> void:
	var ins := inspection
	NC.label(box, source_path, "caption", "regular", T.TERTIARY, true)
	var err := str(ins.get("error", ""))
	var base_files: Array = ins.get("base_files", [])
	if not base_files.is_empty():
		_line(box, 1, "%s" % str(ins.get("layout_label", "EV Nova data")))
		var ver := str(ins.get("version", ""))
		if ver != "":
			_line(box, 1, ver)
		_line(box, 1, "%d data file(s), %d resources readable" % [base_files.size(), int(ins.get("resource_count", 0))])
		var af: Array = ins.get("audio_files", [])
		_line(box, 1 if not af.is_empty() else 0, "Music: " + (", ".join(PackedStringArray(af)) if not af.is_empty() else "none found"))
		var ff: Array = ins.get("font_files", [])
		_line(box, 1 if not ff.is_empty() else 0, "Original fonts: " + (", ".join(PackedStringArray(ff)) if not ff.is_empty() else "none found (look-alikes are used)"))
		var vf: Array = ins.get("video_files", [])
		_line(box, 1 if not vf.is_empty() else 0, "Race movies: %d" % vf.size())
	var plug_folders: Array = ins.get("plugin_folders", [])
	if not plug_folders.is_empty():
		var cb := CheckBox.new()
		cb.text = "Also copy the plug-ins found alongside (%d plug-in file(s) in %s)" % [int(ins.get("plugin_file_count", 0)), ", ".join(PackedStringArray(plug_folders))]
		cb.button_pressed = copy_plugins
		cb.focus_mode = Control.FOCUS_ALL
		cb.toggled.connect(func(on: bool):
			copy_plugins = on
			Prefs.set_value("data", "import_plugins", on))
		T.style_text(cb, "body", "regular", T.WHITE)
		box.add_child(cb)
	for w in ins.get("warnings", []):
		_line(box, 0, str(w))
	var need := float(ins.get("total_bytes", 0))
	var free := _free_space(Prefs.managed_data_dir())
	if need > 0.0:
		var enough := free < 0.0 or free >= need * 1.05 + 64.0 * 1048576.0
		_line(box, 1 if enough else -1, "Copy size %s into %s%s" % [Importer.fmt_bytes(need), Prefs.managed_data_dir(),
				"" if free < 0.0 else " (%s free)" % Importer.fmt_bytes(free)])
		if not enough:
			err = "Not enough free space for the import (needs about %s)." % Importer.fmt_bytes(need * 1.05 + 64.0 * 1048576.0)
			inspection["valid"] = false
			var imp: Variant = dialog.buttons.get("Import")
			if imp != null:
				(imp as BaseButton).disabled = true
	if err != "":
		_line(box, -1, err)
	elif bool(ins.get("valid", false)):
		NC.label(box, "Looks good. Importing copies these files (your originals stay untouched).", "caption", "regular", T.SECONDARY, true)


## Free bytes on the drive that holds `path` (-1 if unknown).
func _free_space(path: String) -> float:
	var p := path
	while p != "" and not DirAccess.dir_exists_absolute(p):
		var parent := p.get_base_dir()
		if parent == p:
			return -1.0
		p = parent
	var d := DirAccess.open(p)
	if d == null:
		return -1.0
	var left := d.get_space_left()
	return float(left) if left > 0 else -1.0


func _begin_import() -> void:
	var dest := Prefs.managed_data_dir()
	if not _nova.data_import_start(source_path, dest, copy_plugins):
		return
	import_status = {}
	_go("import")


func _build_import() -> void:
	var box := _dlg("Importing your data", [{"text": "Cancel", "cb": func():
			_nova.data_import_cancel()
			if _wait_label != null:
				_wait_label.text = "Cancelling..."}])
	_text(box, "Copying your EV Nova files. Nothing in the game is replaced until the whole copy checks out.")
	_phase_label = NC.label(box, "Starting...", "body", "semibold", T.AMBER, true)
	_bar = NC.progress(box, 0.0, 560.0)
	_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_count_label = NC.label(box, "", "caption", "regular", T.SECONDARY, true)
	_wait_label = NC.label(box, "", "caption", "regular", T.TERTIARY, true)


func _build_success() -> void:
	var box := _dlg("You're all set", [{"text": "Play", "default": true, "cb": _finish}])
	_text(box, "Your data is imported and lives in NOVA Swift's own folder on this %s. Choose Play to open the main menu." % _platform_name())
	NC.label(box, Prefs.managed_data_dir(), "caption", "regular", T.TERTIARY, true)
	var res := int(import_status.get("resource_count", 0))
	if res > 0:
		_line(box, 1, "%d resources%s" % [res, (" - " + str(import_status.get("version", ""))) if str(import_status.get("version", "")) != "" else ""])
	for w in import_status.get("warnings", []):
		_line(box, 0, str(w))
	var failed: Array = import_status.get("failed", [])
	if not failed.is_empty():
		_line(box, 0, "Couldn't copy: " + ", ".join(PackedStringArray(failed)))
	if _load_error != "":
		_line(box, -1, _load_error)


func _build_failure() -> void:
	var box := _dlg("That didn't work", [
		{"text": "Choose Again", "default": true, "cb": func():
			var i := _history.find("source")
			if i >= 0:
				_history = _history.slice(0, i)
			_show("source")}])
	var msg := str(import_status.get("error", ""))
	if _load_error != "":
		msg = _load_error
	if bool(import_status.get("cancelled", false)):
		msg = "The import was cancelled. Nothing was changed."
	_line(box, -1, msg if msg != "" else "The import failed.")
	_text(box, "Your previous data (if any) is untouched. Check that you picked the whole game folder, its Nova Files folder or the Windows .zip.", true)


## Called by the shell if loading the imported folder failed.
func show_load_failure(msg: String) -> void:
	_load_error = msg
	_show("failure")


func _finish() -> void:
	var dest := Prefs.managed_data_dir()
	Prefs.set_value("data", "dir", dest)
	Prefs.add_recent_source(source_path)
	Prefs.save()
	if _nova.has_method("data_import_discard"):
		_nova.data_import_discard()
	data_found.emit(dest)


# --- polling -------------------------------------------------------------------------------

func _process(delta: float) -> void:
	if step == "source" and _scanner != null and not _scanner.done:
		var before: int = _scanner.found.size()
		_scanner.step(16)
		if _found_box != null and is_instance_valid(_found_box):
			for i in range(before, _scanner.found.size()):
				var f: Dictionary = _scanner.found[i]
				var kind := "a zip" if f["kind"] == "zip" else ("a game folder" if f["kind"] == "install" else "data files")
				var b := _source_button(str(f["path"]), "externaldrive")
				b.tooltip_text = kind
				b.text = "%s   (%s)" % [f["path"], kind]
				_found_box.add_child(b)
		if _scanner.done and _scan_label != null:
			_scan_label.text = "" if not _scanner.found.is_empty() else "No installs found automatically. Use Browse… and pick yours."
	if step == "inspect" and inspection.is_empty():
		_dots += delta
		if _wait_label != null:
			_wait_label.text = "Reading and checking your files" + ".".repeat(1 + int(_dots * 2.0) % 3)
		_poll -= delta
		if _poll <= 0.0:
			_poll = 0.12
			var st: Dictionary = Importer.parse(_nova.data_import_inspect_status())
			if bool(st.get("done", false)) and not bool(st.get("running", false)):
				inspection = st.get("result", {})
				if inspection.is_empty():
					inspection = {"error": "Nothing was returned for that path.", "valid": false}
				_show("inspect")
	elif step == "import":
		_poll -= delta
		if _poll <= 0.0:
			_poll = 0.1
			import_status = Importer.parse(_nova.data_import_status())
			if _phase_label != null:
				_phase_label.text = str(import_status.get("phase", ""))
				_bar.value = float(import_status.get("fraction", 0.0))
				_count_label.text = "%d of %d files   (%s of %s)" % [int(import_status.get("files_done", 0)), int(import_status.get("files_total", 0)),
						Importer.fmt_bytes(float(import_status.get("bytes_done", 0))), Importer.fmt_bytes(float(import_status.get("bytes_total", 0)))]
			if bool(import_status.get("done", false)):
				if bool(import_status.get("ok", false)):
					_history.erase("import")
					_go("success")
				else:
					_go("failure")


func _unhandled_input(event: InputEvent) -> void:
	# Esc / B is routed by the dialog's cancel button; this only keeps it from leaking to the shell.
	if event.is_action_pressed("ui_cancel") and (gated or _browser != null):
		get_viewport().set_input_as_handled()
