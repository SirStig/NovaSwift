# NOVA Swift -- the error boundary screen (docs/GODOT_LAYER.md "Errors and crash reporting").
#
# Built from plain Godot Controls and the engine's DEFAULT theme only. It depends on no game script, no UI kit
# and no bridge (just ErrorReport.gd / CrashLogger.gd, which are equally standalone), so it still works when
# everything else is broken. Used full-screen by Boot.gd and as a paused overlay by ErrorWatch.gd.
#
# setup(opts):  title, message, hints (Array of String), detail (technical text), location ("file:line"),
#               retry / menu / continue (bool: show those buttons), issue_title.
# Signals: retry_pressed, menu_pressed, continue_pressed.
# Mouse, keyboard (Tab / arrows / Enter, Esc = Continue or Back) and pad (focus navigation) all work.
# Loaded with preload() (no class_name).
extends Control

const CrashLogger = preload("res://ui/CrashLogger.gd")
const ErrorReport = preload("res://ui/ErrorReport.gd")

signal retry_pressed
signal menu_pressed
signal continue_pressed

var opts: Dictionary = {}
var details_text: TextEdit
var details_toggle: Button
var status: Label
var first_button: Button
var buttons: Dictionary = {}   # id -> Button

var _summary: String = ""


func setup(options: Dictionary) -> void:
	opts = options
	process_mode = Node.PROCESS_MODE_ALWAYS
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_STOP
	_build()


func _build() -> void:
	var bg: ColorRect = ColorRect.new()
	bg.color = Color(0.05, 0.05, 0.07, 0.96)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)
	var center: CenterContainer = CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(center)
	var panel: PanelContainer = PanelContainer.new()
	var vp: Vector2 = get_viewport_rect().size if is_inside_tree() else Vector2(1280, 720)
	panel.custom_minimum_size = Vector2(minf(780.0, maxf(320.0, vp.x - 48.0)), 0)
	center.add_child(panel)
	var margin: MarginContainer = MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 18)
	panel.add_child(margin)
	var col: VBoxContainer = VBoxContainer.new()
	col.add_theme_constant_override("separation", 10)
	margin.add_child(col)

	var title: Label = Label.new()
	title.text = str(opts.get("title", "Something went wrong"))
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(1.0, 0.55, 0.45))
	title.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	col.add_child(title)

	var msg: Label = Label.new()
	msg.text = str(opts.get("message", ""))
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg.add_theme_font_size_override("font_size", 16)
	col.add_child(msg)

	var hints: Array = opts.get("hints", []) as Array
	for h in hints:
		var hl: Label = Label.new()
		hl.text = "•  " + str(h)
		hl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		hl.add_theme_font_size_override("font_size", 13)
		hl.add_theme_color_override("font_color", Color(0.78, 0.82, 0.9))
		col.add_child(hl)

	var location: String = str(opts.get("location", ""))
	if location != "":
		var loc: Label = Label.new()
		loc.text = "Where: " + ErrorReport.sanitize(location)
		loc.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		loc.add_theme_font_size_override("font_size", 12)
		loc.add_theme_color_override("font_color", Color(0.65, 0.7, 0.8))
		col.add_child(loc)

	details_toggle = Button.new()
	details_toggle.text = "▸ Technical details"
	details_toggle.flat = true
	details_toggle.alignment = HORIZONTAL_ALIGNMENT_LEFT
	details_toggle.pressed.connect(_toggle_details)
	col.add_child(details_toggle)
	details_text = TextEdit.new()
	details_text.editable = false
	details_text.custom_minimum_size = Vector2(0, 190)
	details_text.add_theme_font_size_override("font_size", 12)
	details_text.text = _full_details()
	details_text.visible = false
	col.add_child(details_text)

	var info: Label = Label.new()
	info.text = ErrorReport.system_info()
	info.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	info.add_theme_font_size_override("font_size", 11)
	info.add_theme_color_override("font_color", Color(0.55, 0.6, 0.7))
	col.add_child(info)

	var row: HFlowContainer = HFlowContainer.new()
	row.add_theme_constant_override("h_separation", 8)
	row.add_theme_constant_override("v_separation", 8)
	col.add_child(row)
	if bool(opts.get("continue", false)):
		_btn(row, "continue", "Continue anyway", _on_continue)
	if bool(opts.get("menu", false)):
		_btn(row, "menu", "Back to main menu", _on_menu)
	if bool(opts.get("retry", false)):
		_btn(row, "retry", "Retry", _on_retry)
	_btn(row, "report", "Report a bug", _on_report)
	_btn(row, "copy", "Copy details", _on_copy)
	_btn(row, "logs", "Open logs folder", ErrorReport.open_logs_folder)
	_btn(row, "bundle", "Save report bundle", _on_bundle)
	_btn(row, "quit", "Quit", _on_quit)

	status = Label.new()
	status.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	status.add_theme_font_size_override("font_size", 12)
	status.add_theme_color_override("font_color", Color(0.55, 0.9, 0.6))
	col.add_child(status)

	_summary = "%s\n%s" % [str(opts.get("title", "")), str(opts.get("message", ""))]
	if first_button != null:
		first_button.call_deferred("grab_focus")


func _btn(parent: Control, id: String, label: String, cb: Callable) -> Button:
	var b: Button = Button.new()
	b.text = label
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = Vector2(0, 38)
	b.pressed.connect(cb)
	parent.add_child(b)
	buttons[id] = b
	if first_button == null:
		first_button = b
	return b


func _full_details() -> String:
	var t: String = str(opts.get("detail", "")).strip_edges()
	var loc: String = str(opts.get("location", ""))
	var lines: PackedStringArray = CrashLogger.recent_lines(30)
	var out: String = ""
	if t != "":
		out += t + "\n"
	if loc != "":
		out += "at " + loc + "\n"
	if not lines.is_empty():
		out += "\n--- recent log ---\n" + "\n".join(lines)
	return ErrorReport.sanitize(out)


func _toggle_details() -> void:
	details_text.visible = not details_text.visible
	details_toggle.text = ("▾ " if details_text.visible else "▸ ") + "Technical details"


func _say(text: String) -> void:
	if status != null:
		status.text = text


func _issue_title() -> String:
	var t: String = str(opts.get("issue_title", ""))
	return t if t != "" else "[Godot %s] %s" % [ErrorReport.version(), str(opts.get("title", "Error"))]


func _issue_summary() -> String:
	var s: String = "%s\n%s" % [str(opts.get("message", "")), str(opts.get("detail", ""))]
	var loc: String = str(opts.get("location", ""))
	if loc != "":
		s += "\nat " + loc
	return s.strip_edges()


func _on_report() -> void:
	ErrorReport.open_issue(_issue_title(), _issue_summary())
	_say("Opened your browser. Use “Save report bundle” and attach the zip for the full log.")


func _on_copy() -> void:
	DisplayServer.clipboard_set(ErrorReport.report_text(_summary, str(opts.get("detail", "")) + "\n" + str(opts.get("location", "")), CrashLogger.recent_lines(60)))
	_say("Copied to the clipboard.")


func _on_bundle() -> void:
	var r: Dictionary = ErrorReport.save_bundle(_issue_summary(), str(opts.get("detail", "")))
	if bool(r.get("ok", false)):
		var p: String = str(r.get("path", ""))
		OS.shell_show_in_file_manager(p)
		_say("Saved: " + ErrorReport.sanitize(p))
	else:
		_say(str(r.get("error", "Couldn't save the bundle.")))


func _on_retry() -> void:
	retry_pressed.emit()


func _on_menu() -> void:
	menu_pressed.emit()


func _on_continue() -> void:
	continue_pressed.emit()


func _on_quit() -> void:
	get_tree().quit()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		if buttons.has("continue"):
			get_viewport().set_input_as_handled()
			continue_pressed.emit()
		elif buttons.has("menu"):
			get_viewport().set_input_as_handled()
			menu_pressed.emit()
