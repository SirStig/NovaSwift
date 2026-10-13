# NOVA Swift — Report tab / "Report a Bug" (port of BugReport.swift + BugReportView.swift).
#
# Builds one shareable .zip: report.txt (your note + build, data set, pilot, outfits, cargo,
# missions, legal record, every control bit set), pilot.json (the full save -- a repro),
# diagnostics.txt (the self-test battery) and console.log (the captured log: the engine's
# `Logging` output with control-bit writes attributed to their source, plus Godot's own log).
# No game data is included (BYO-data model): nothing from the imported EV Nova files, plug-ins
# by name only. The text assembly is shared Swift (BugReportText); this script zips with
# ZIPPacker and saves to a user-visible folder (Documents/NovaSwift/Diagnostics, falling back to
# user://Diagnostics; NOVA_REPORT_DIR overrides), then offers to reveal it in the file manager.
# Always reachable (Settings > Support), independent of debug mode.
extends VBoxContainer

const DevUI = preload("res://debug/DevUI.gd")

var _tools: Node
var _note: TextEdit
var _result: VBoxContainer
var _recent: VBoxContainer
var _busy := false


func setup(tools: Node) -> void:
	_tools = tools
	add_theme_constant_override("separation", 6)
	DevUI.label(self, "Describe it", 12, DevUI.GREEN)
	_note = TextEdit.new()
	_note.placeholder_text = "What happened? What did you expect instead?"
	_note.custom_minimum_size = Vector2(0, 90)
	_note.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	add_child(_note)
	var bar := DevUI.hbox(self, 8)
	DevUI.button(bar, "Create Report", _create, DevUI.GREEN)
	DevUI.wrap_label(self, "A rough note is fine — where you were, what you were flying and which story flags are set are collected automatically. Included: your note, the pilot save, the recent game log, a self-test, build / OS info. No game data is included.", 10)
	var sc := DevUI.scroll(self)
	var col := DevUI.vbox(sc, 6)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_result = DevUI.vbox(col, 4)
	DevUI.label(col, "PREVIOUS REPORTS", 10, DevUI.GREEN)
	_recent = DevUI.vbox(col, 3)


func on_show() -> void:
	_refresh_recent()


func focus_first() -> void:
	if _note != null:
		_note.grab_focus()


## Where reports are written.
static func reports_dir() -> String:
	var env := OS.get_environment("NOVA_REPORT_DIR")
	if env != "":
		return env
	var docs := OS.get_system_dir(OS.SYSTEM_DIR_DOCUMENTS)
	if docs != "":
		return docs.path_join("NovaSwift").path_join("Diagnostics")
	return ProjectSettings.globalize_path("user://Diagnostics")


static func build_info() -> String:
	return "NovaSwift (Godot) %s · Godot %s" % [str(ProjectSettings.get_setting("application/config/version", "?")),
		Engine.get_version_info().get("string", "?")]


static func os_info() -> String:
	var gpu := ""
	if DisplayServer.get_name() != "headless":
		gpu = " · GPU " + RenderingServer.get_video_adapter_name()
	return "%s %s%s" % [OS.get_name(), OS.get_version(), gpu]


## Assemble and zip. Returns {ok, path, summary, files: [names], error}.
static func make_report(dbg: Object, note: String, dir := "") -> Dictionary:
	if dir == "":
		dir = reports_dir()
	var res = JSON.parse_string(dbg.bug_report_files(note, build_info(), os_info(), ""))
	if not (res is Dictionary):
		return {"ok": false, "error": "The bridge returned no report."}
	if DirAccess.make_dir_recursive_absolute(dir) != OK:
		dir = ProjectSettings.globalize_path("user://Diagnostics")
		DirAccess.make_dir_recursive_absolute(dir)
	var path := dir.path_join("NovaSwift-report-%s.zip" % res.stamp)
	var zip := ZIPPacker.new()
	if zip.open(path) != OK:
		return {"ok": false, "error": "Couldn't write " + path}
	var names := []
	for name in res.files:
		zip.start_file(name)
		zip.write_file(str(res.files[name]).to_utf8_buffer())
		zip.close_file()
		names.append(name)
	zip.close()
	return {"ok": true, "path": path, "summary": res.summary, "files": names}


func _create() -> void:
	if _busy or _tools.dbg == null:
		return
	_busy = true
	DevUI.clear_children(_result)
	DevUI.label(_result, "Collecting…", 11, DevUI.AMBER)
	await get_tree().process_frame
	var r := make_report(_tools.dbg, _note.text)
	_busy = false
	DevUI.clear_children(_result)
	if not r.ok:
		DevUI.label(_result, str(r.error), 12, DevUI.RED)
		return
	last = r
	DevUI.label(_result, "Report ready", 13, DevUI.GREEN)
	DevUI.wrap_label(_result, str(r.path), 11, Color.WHITE)
	DevUI.wrap_label(_result, "Contains: " + ", ".join(r.files), 10)
	var row := DevUI.hbox(_result, 8)
	DevUI.button(row, "Show in folder", func(): OS.shell_show_in_file_manager(str(r.path)), DevUI.GREEN)
	DevUI.button(row, "Copy path", func(): DisplayServer.clipboard_set(str(r.path)), DevUI.GREEN)
	var sum := RichTextLabel.new()
	sum.fit_content = true
	sum.text = str(r.summary).left(1800)
	sum.add_theme_font_size_override("normal_font_size", 10)
	_result.add_child(sum)
	_refresh_recent()


func _refresh_recent() -> void:
	DevUI.clear_children(_recent)
	var dir := reports_dir()
	var files := []
	for f in (DirAccess.get_files_at(dir) if DirAccess.dir_exists_absolute(dir) else PackedStringArray()):
		if f.ends_with(".zip"):
			files.append(f)
	files.sort()
	files.reverse()
	if files.is_empty():
		DevUI.label(_recent, "None yet.", 10, DevUI.DIM)
	for f in files.slice(0, 8):
		var p: String = dir.path_join(f)
		var row := DevUI.hbox(_recent, 8)
		DevUI.label(row, f, 10, Color(1, 1, 1, 0.75))
		DevUI.button(row, "Show", func(): OS.shell_show_in_file_manager(p), DevUI.GREEN)


var last := {}
