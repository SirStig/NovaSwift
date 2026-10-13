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
extends ScrollContainer

const DevUI = preload("res://debug/DevUI.gd")
const ErrorReport = preload("res://ui/ErrorReport.gd")   # prefilled GitHub issue + logs folder (error boundary helpers)

const INCLUDED := [
	["doc.text", "Your description", "The note you write above"],
	["person.crop.circle", "Pilot save", "Ship, outfits, cargo, missions, legal record, story bits"],
	["list.bullet.rectangle", "Game log", "The recent log, control-bit writes attributed to their source"],
	["checkmark.seal.fill", "Self-test results", "The diagnostics battery, run just now"],
	["info.circle", "Build & system info", "App version, OS, GPU and which plug-ins are enabled"],
]

var _tools: Node
var _note: TextEdit
var _count: Label
var _result: VBoxContainer
var _recent: VBoxContainer
var _create_btn: Button
var _busy := false
var _confirm_delete := ""


func setup(tools: Node) -> void:
	_tools = tools
	follow_focus = true
	horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	size_flags_vertical = Control.SIZE_EXPAND_FILL
	var m := DevUI.margin(self, 14, 12, 14, 14)
	var grid := DevUI.responsive_grid(m, 2, 520, 12, 12)

	# --- left: write it up, and what gets collected
	var left := DevUI.vbox(grid, 12)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var desc := DevUI.section_card(left, "Describe it", "pencil", DevUI.GREEN)
	var frame := PanelContainer.new()
	frame.add_theme_stylebox_override("panel", DevUI._box(Color(0, 0, 0, 0.3), Color(1, 1, 1, 0.0), 11, Vector2(0, 0), 0))
	desc.add_child(frame)
	_note = TextEdit.new()
	_note.placeholder_text = "What happened? What did you expect instead?\n\nWhere were you, what were you flying, what did you click?"
	_note.custom_minimum_size = Vector2(0, 150)
	_note.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	_note.scroll_fit_content_height = false
	_note.text_changed.connect(func(): _count.text = "%d characters" % _note.text.length())
	frame.add_child(_note)
	var row := DevUI.hbox(desc, 10)
	_count = DevUI.label(row, "0 characters", 11, DevUI.FAINT)
	_count.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_count.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	_create_btn = DevUI.primary_button(row, "Create Report", "ladybug.fill", _create)
	DevUI.wrap_label(desc, "A rough note is fine. The details that are hard to describe (where you were, what you were flying, which story flags are set) are collected automatically.", 11, DevUI.DIM)

	var inc := DevUI.section_card(left, "What gets included", "doc.zipper", DevUI.BLUE)
	for it in INCLUDED:
		var r := DevUI.hbox(inc, 10)
		var tile := PanelContainer.new()
		tile.add_theme_stylebox_override("panel", DevUI._box(Color(DevUI.BLUE.r, DevUI.BLUE.g, DevUI.BLUE.b, 0.13), Color(0, 0, 0, 0), 8, Vector2(7, 7), 0))
		tile.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		DevUI.icon_rect(tile, it[0], 15, DevUI.BLUE)
		r.add_child(tile)
		var c := DevUI.vbox(r, 0)
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		DevUI.label(c, it[1], 13, DevUI.TEXT)
		DevUI.wrap_label(c, it[2], 11, DevUI.FAINT)
	var priv := DevUI.hbox(inc, 8)
	DevUI.icon_rect(priv, "shield.fill", 14, DevUI.GREEN).size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	DevUI.wrap_label(priv, "No game data is included. None of your imported EV Nova files, artwork or sound is copied into the report; plug-ins are listed by name only.", 11, DevUI.DIM)

	# --- right: the freshly built report, then the history
	var right := DevUI.vbox(grid, 12)
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_result = DevUI.vbox(right, 12)
	var prev := DevUI.section_card(right, "Previous reports", "clock", DevUI.AMBER)
	_recent = DevUI.vbox(prev, 8)


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
	_create_btn.disabled = true
	_create_btn.text = "Collecting…"
	DevUI.clear_children(_result)
	await get_tree().process_frame
	var r := make_report(_tools.dbg, _note.text)
	_busy = false
	_create_btn.disabled = false
	_create_btn.text = "Create Report"
	DevUI.clear_children(_result)
	if not r.ok:
		var err := DevUI.section_card(_result, "Couldn't build the report", "exclamationmark.triangle.fill", DevUI.RED)
		DevUI.wrap_label(err, str(r.error), 12, DevUI.RED)
		return
	last = r
	var path := str(r.path)
	var body := DevUI.section_card(_result, "Report ready", "checkmark.circle.fill", DevUI.GREEN)
	(body.get_parent().get_parent() as PanelContainer).add_theme_stylebox_override("panel",
		DevUI.panel_style(Color(DevUI.GREEN.r, DevUI.GREEN.g, DevUI.GREEN.b, 0.07), Color(DevUI.GREEN.r, DevUI.GREEN.g, DevUI.GREEN.b, 0.4), 10))
	var fr := DevUI.hbox(body, 8)
	DevUI.icon_rect(fr, "doc.zipper", 18, DevUI.GREEN)
	var fc := DevUI.vbox(fr, 0)
	fc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	DevUI.label(fc, path.get_file(), 12, Color.WHITE, true).clip_text = true
	DevUI.wrap_label(fc, path.get_base_dir(), 10, DevUI.FAINT, true)
	var pills := DevUI.flow(body, 5)
	for f in r.files:
		DevUI.pill(pills, str(f), DevUI.BLUE, "doc.text")
	var chips := DevUI.flow(body, 6)
	DevUI.button(chips, "Show in folder", func(): OS.shell_show_in_file_manager(path), DevUI.GREEN, false, "folder")
	DevUI.button(chips, "Copy path", func(): DisplayServer.clipboard_set(path), DevUI.GREEN, false, "doc.on.doc")
	DevUI.caps(body, "What you're sending", DevUI.FAINT, 9)
	var sum := RichTextLabel.new()
	sum.custom_minimum_size = Vector2(0, 150)
	sum.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sum.selection_enabled = true
	sum.focus_mode = Control.FOCUS_ALL
	sum.text = str(r.summary).left(4000)
	sum.add_theme_font_size_override("normal_font_size", 10)
	sum.add_theme_stylebox_override("normal", DevUI._box(Color(0, 0, 0, 0.35), Color(1, 1, 1, 0.07), 8, Vector2(8, 6)))
	body.add_child(sum)
	_refresh_recent()


func _fmt_size(n: int) -> String:
	if n >= 1048576:
		return "%.1f MB" % (float(n) / 1048576.0)
	return "%.0f KB" % maxf(1.0, float(n) / 1024.0)


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
		var e := DevUI.empty_state(_recent, "reports", "No reports yet", "Reports you create show up here, with the folder they were saved in.")
		e.custom_minimum_size = Vector2(0, 170)
		return
	for f in files.slice(0, 8):
		var p: String = dir.path_join(f)
		var card := PanelContainer.new()
		card.add_theme_stylebox_override("panel", DevUI._box(Color(1, 1, 1, 0.035), Color(1, 1, 1, 0.07), 10, Vector2(10, 8)))
		_recent.add_child(card)
		var row := DevUI.hbox(card, 10)
		DevUI.icon_rect(row, "doc.zipper", 20, DevUI.AMBER)
		var c := DevUI.vbox(row, 1)
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var nm := DevUI.label(c, f, 12, Color(1, 1, 1, 0.9), true)
		nm.clip_text = true
		nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		var when := Time.get_datetime_string_from_unix_time(FileAccess.get_modified_time(p), true)
		var fa := FileAccess.open(p, FileAccess.READ)
		var size_n := int(fa.get_length()) if fa != null else 0
		DevUI.label(c, "%s  ·  %s" % [when, _fmt_size(size_n)], 10, DevUI.FAINT)
		DevUI.icon_button(row, "folder", "Show in folder", func(): OS.shell_show_in_file_manager(p), DevUI.GREEN, 14)
		DevUI.icon_button(row, "doc.on.doc", "Copy path", func(): DisplayServer.clipboard_set(p), DevUI.BLUE, 14)
		var del := DevUI.icon_button(row, "trash", "Delete this report", func(): pass, DevUI.RED, 14)
		del.pressed.connect(func():
			if _confirm_delete == p:
				DirAccess.remove_absolute(p)
				_confirm_delete = ""
				_refresh_recent()
			else:
				_confirm_delete = p
				del.text = "Delete?"
				del.tooltip_text = "Press again to delete")


var last := {}
