# Plugin Editor. Full-screen stand-in for the Apple PluginEditorView: top bar (document, undo,
# file, save, validation, test run), sidebar (tools + resource types by category), and eight
# tools — Overview, Resources (list + inspector), Galaxy Map, Star System, Story & Bits,
# Validation, Project & Export, Bundle Files.
# The document lives in NovaEditor (the bridge). This file only draws and forwards edits.
extends CanvasLayer

const EdTheme = preload("res://editor/EditorTheme.gd")
const T = preload("res://ui/novaswift/NovaTheme.gd")
const PilotFiles = preload("res://screens/PilotFiles.gd")
const Inspector = preload("res://editor/Inspector.gd")
const GalaxyCanvas = preload("res://editor/GalaxyCanvas.gd")
const SystemCanvas = preload("res://editor/SystemCanvas.gd")
const StoryCanvas = preload("res://editor/StoryCanvas.gd")
const RECENTS_PATH := "user://editor_recents.json"

signal closed
signal test_requested

## id, label, icon, subtitle
const TOOLS := [
	["overview", "Overview", "square.stack.3d.up", "Your plug-in at a glance: every resource it adds or changes."],
	["resources", "Resources", "cylinder", "Browse any resource type and edit its fields."],
	["galaxy", "Galaxy Map", "map", "Move systems and draw hyperlinks."],
	["system", "Star System", "sun.max", "Place stellars, manage links."],
	["story", "Story & Bits", "arrow.triangle.branch", "Missions and crons wired by control bits."],
	["lint", "Validation", "checkmark.seal.fill", "Problems the game would trip over."],
	["project", "Project & Export", "shippingbox", "Name, author, save, export and install."],
	["bundle", "Bundle Files", "files", "The files this plug-in is made of."],
]

var nova: Object
var ed: Object
var data_dir := ""
var tool := "overview"
var type_code := ""
var selected_id := -1
var _st := {}
var _types: Array = []
var _system_id := -1
var _show_empty := false
var _collapsed := {}
var _type_rows := {}
var _lint := {}

var _root: Control
var _title: Label
var _subtitle: Label
var _dirty_chip: Control
var _undo: Button
var _redo: Button
var _save_btn: Button
var _badge: Button
var _status: Label
var _type_search: LineEdit
var _type_box: VBoxContainer
var _tool_host: Control
var _tool_title: Label
var _tool_sub: Label
var _tool_icon: TextureRect
var _tool_actions: HBoxContainer
var _tool_buttons := {}
var _file_menu: PopupMenu
var _file_btn: Button
var _installed_menu: PopupMenu
var _dirty_dialog: ConfirmationDialog
var _confirm: ConfirmationDialog
var _confirm_cb: Callable
var _renumber: ConfirmationDialog
var _renumber_spin: SpinBox
var _renumber_refs: CheckBox
var _toast: PanelContainer
var _toast_label: Label
var _toast_tween: Tween
var _lint_timer: Timer
var _picker_host: Inspector
var _focus_search: LineEdit
var _res_list: ItemList
var _inspector: Inspector


func setup(world: Object, base_dir: String) -> void:
	nova = world
	data_dir = base_dir
	layer = 60
	if ClassDB.class_exists("NovaEditor"):
		ed = ClassDB.instantiate("NovaEditor")
		ed.attach(nova)
		ed.new_document()
	_build()
	_pull()
	_load_types()
	_refresh_lint()
	_show_tool("overview")


# --- shell --------------------------------------------------------------------------------------

func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	EdTheme.install(_root)
	add_child(_root)
	var bg := ColorRect.new()
	bg.color = EdTheme.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(bg)

	var col := EdTheme.vbox(0)
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(col)
	col.add_child(_top_bar())
	col.add_child(EdTheme.hline())

	var body := EdTheme.hbox(0)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(body)
	body.add_child(_sidebar())
	var vline := ColorRect.new()
	vline.color = EdTheme.LINE
	vline.custom_minimum_size = Vector2(1, 0)
	body.add_child(vline)

	var main := EdTheme.vbox(0)
	main.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(main)
	main.add_child(_tool_header())
	main.add_child(EdTheme.hline())
	_tool_host = Control.new()
	_tool_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tool_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_tool_host.clip_contents = true
	main.add_child(_tool_host)

	col.add_child(EdTheme.hline())
	col.add_child(_status_bar())

	_toast = PanelContainer.new()
	_toast.add_theme_stylebox_override("panel", T.box(Color(0.18, 0.18, 0.19, 0.97), 18, Color(1, 1, 1, 0.16), 1, Vector2(16, 8)))
	_toast.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_toast.visible = false
	_toast_label = EdTheme.label("", 13, EdTheme.TEXT, "medium")
	_toast.add_child(_toast_label)
	_root.add_child(_toast)

	_picker_host = Inspector.new()
	_picker_host.custom_minimum_size = Vector2.ZERO
	_picker_host.size = Vector2.ZERO
	_picker_host.ed = ed
	_root.add_child(_picker_host)

	_file_menu = PopupMenu.new()
	_file_menu.id_pressed.connect(_on_file)
	_root.add_child(_file_menu)
	_installed_menu = PopupMenu.new()
	_installed_menu.id_pressed.connect(_on_installed)
	_root.add_child(_installed_menu)

	_dirty_dialog = ConfirmationDialog.new()
	_dirty_dialog.title = "Close the Plugin Editor?"
	_dirty_dialog.dialog_text = "You have unsaved changes."
	_dirty_dialog.ok_button_text = "Don't Save"
	_dirty_dialog.add_button("Save", true, "save")
	_dirty_dialog.confirmed.connect(_discard_and_close)
	_dirty_dialog.custom_action.connect(func(act: StringName) -> void:
		if str(act) == "save":
			_dirty_dialog.hide()
			_save(false)
			if not bool(_st.get("dirty", false)):
				_finish_close())
	_root.add_child(_dirty_dialog)

	_confirm = ConfirmationDialog.new()
	_confirm.confirmed.connect(func() -> void:
		if _confirm_cb.is_valid():
			_confirm_cb.call())
	_root.add_child(_confirm)

	_renumber = ConfirmationDialog.new()
	_renumber.title = "Change Resource ID"
	_renumber.ok_button_text = "Change ID"
	var rv := EdTheme.vbox(10)
	rv.add_child(EdTheme.wrap_label("Pick a new ID. Companion resources (sprites, descriptions) move with it.", 12, EdTheme.SECONDARY))
	var rh := EdTheme.hbox(8)
	rh.add_child(EdTheme.label("New ID", 13, EdTheme.SECONDARY))
	_renumber_spin = EdTheme.spin(128, 128, 32767)
	rh.add_child(_renumber_spin)
	rv.add_child(rh)
	_renumber_refs = CheckBox.new()
	_renumber_refs.text = "Update every reference to it"
	_renumber_refs.button_pressed = true
	rv.add_child(_renumber_refs)
	_renumber.add_child(rv)
	_renumber.confirmed.connect(_do_renumber)
	_root.add_child(_renumber)

	_lint_timer = Timer.new()
	_lint_timer.one_shot = true
	_lint_timer.wait_time = 0.8
	_lint_timer.timeout.connect(_refresh_lint)
	add_child(_lint_timer)


func _top_bar() -> Control:
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", T.box(EdTheme.BAR, 0, Color(0, 0, 0, 0), 0, Vector2(10, 7)))
	var h := EdTheme.hbox(8)
	bar.add_child(h)

	var back := EdTheme.button("Close", _request_close, "ghost", "chevron.left")
	back.tooltip_text = "Back to the main menu  (Esc)"
	h.add_child(back)
	h.add_child(_vsep())

	var doc_icon := PanelContainer.new()
	doc_icon.add_theme_stylebox_override("panel", T.box(Color(EdTheme.AMBER.r, EdTheme.AMBER.g, EdTheme.AMBER.b, 0.16), 8, Color(0, 0, 0, 0), 0, Vector2(6, 6)))
	doc_icon.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	doc_icon.add_child(EdTheme.icon_rect("puzzlepiece.extension.fill", 18, EdTheme.AMBER))
	h.add_child(doc_icon)
	var names := EdTheme.vbox(0)
	names.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var title_row := EdTheme.hbox(8)
	_title = EdTheme.label("Untitled Plug-in", 15, EdTheme.TEXT, "semibold")
	_title.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	title_row.add_child(_title)
	_dirty_chip = EdTheme.chip("Edited", EdTheme.AMBER)
	_dirty_chip.tooltip_text = "Unsaved changes"
	title_row.add_child(_dirty_chip)
	names.add_child(title_row)
	_subtitle = EdTheme.label("", 11, EdTheme.TERTIARY)
	_subtitle.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_subtitle.custom_minimum_size.x = 120
	names.add_child(_subtitle)
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(names)

	_undo = EdTheme.icon_button("undo", "Undo  (⌘Z)", _do_undo)
	_redo = EdTheme.icon_button("redo", "Redo  (⇧⌘Z)", _do_redo)
	h.add_child(_undo)
	h.add_child(_redo)
	h.add_child(_vsep())
	_file_btn = EdTheme.button("File", _open_file_menu, "ghost", "folder")
	_file_btn.tooltip_text = "New, open, recent, save as, export"
	h.add_child(_file_btn)
	_save_btn = EdTheme.button("Save", func() -> void: _save(false), "plain", "square.and.arrow.down")
	_save_btn.tooltip_text = "Save  (⌘S)"
	h.add_child(_save_btn)
	h.add_child(_vsep())
	_badge = EdTheme.button("No issues", func() -> void: _show_tool("lint"), "ghost", "checkmark.seal.fill")
	_badge.tooltip_text = "Validation"
	h.add_child(_badge)
	var run := EdTheme.button("Test Run", _test_run, "accent", "play.fill")
	run.tooltip_text = "Fly the merged game with this plug-in in a sandbox pilot  (⌘R)"
	h.add_child(run)
	return bar


func _vsep() -> Control:
	var r := ColorRect.new()
	r.color = Color(1, 1, 1, 0.1)
	r.custom_minimum_size = Vector2(1, 22)
	r.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	return r


func _sidebar() -> Control:
	var side := PanelContainer.new()
	side.custom_minimum_size = Vector2(250, 0)
	side.add_theme_stylebox_override("panel", T.box(EdTheme.SIDE, 0, Color(0, 0, 0, 0), 0, Vector2(10, 10)))
	var v := EdTheme.vbox(2)
	side.add_child(v)
	v.add_child(EdTheme.margin(EdTheme.caps("Workspace"), 8, 2, 0, 4))
	for i in TOOLS.size():
		var t: Array = TOOLS[i]
		var b := EdTheme.button(str(t[1]), _show_tool.bind(str(t[0])), "nav", str(t[2]))
		b.tooltip_text = "%s  (⌘%d)" % [str(t[3]), i + 1]
		_tool_buttons[str(t[0])] = b
		v.add_child(b)

	var sep := EdTheme.hline()
	v.add_child(EdTheme.margin(sep, 4, 8, 4, 8))
	var th := EdTheme.hbox(4)
	th.add_child(EdTheme.margin(EdTheme.caps("Resource types"), 8, 0, 0, 0))
	th.add_child(EdTheme.spacer())
	var eye := EdTheme.icon_button("eye.slash", "Show types this game has none of", Callable(), EdTheme.TERTIARY)
	eye.pressed.connect(func() -> void:
		_show_empty = not _show_empty
		EdTheme.set_icon(eye, "eye" if _show_empty else "eye.slash", EdTheme.AMBER if _show_empty else EdTheme.TERTIARY, 16)
		eye.tooltip_text = "Hide empty types" if _show_empty else "Show types this game has none of"
		_fill_types())
	th.add_child(eye)
	v.add_child(th)
	_type_search = EdTheme.field("Filter types", "magnifyingglass")
	_type_search.text_changed.connect(func(_t: String) -> void: _fill_types())
	v.add_child(_type_search)
	_type_box = EdTheme.vbox(1)
	var sc := EdTheme.scroll(_type_box)
	sc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	v.add_child(EdTheme.margin(sc, 0, 6, 0, 0))
	return side


func _tool_header() -> Control:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", T.box(EdTheme.BG, 0, Color(0, 0, 0, 0), 0, Vector2(20, 12)))
	var h := EdTheme.hbox(12)
	p.add_child(h)
	_tool_icon = EdTheme.icon_rect("square.stack.3d.up", 22, EdTheme.AMBER)
	h.add_child(_tool_icon)
	var v := EdTheme.vbox(0)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tool_title = EdTheme.heading("Overview", 18)
	v.add_child(_tool_title)
	_tool_sub = EdTheme.label("", 12, EdTheme.SECONDARY)
	_tool_sub.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	v.add_child(_tool_sub)
	h.add_child(v)
	_tool_actions = EdTheme.hbox(6)
	_tool_actions.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	h.add_child(_tool_actions)
	return p


func _status_bar() -> Control:
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", T.box(EdTheme.BAR, 0, Color(0, 0, 0, 0), 0, Vector2(12, 4)))
	var h := EdTheme.hbox(10)
	bar.add_child(h)
	_status = EdTheme.label("", 11, EdTheme.SECONDARY)
	_status.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_status.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	h.add_child(_status)
	h.add_child(EdTheme.icon_rect("keyboard", 13, EdTheme.TERTIARY))
	h.add_child(EdTheme.label("⌘S Save   ⌘Z Undo   ⌘N New   ⌘F Find   ⌘R Test Run   ⌘1–8 Tools", 11, EdTheme.TERTIARY))
	return bar


func _toast_show(text: String, bad := false) -> void:
	if _toast == null:
		return
	_toast_label.text = text
	_toast_label.add_theme_color_override("font_color", EdTheme.BAD if bad else EdTheme.TEXT)
	_toast.visible = true
	_toast.modulate.a = 0.0
	_toast.reset_size()
	var vp := _root.size
	_toast.position = Vector2((vp.x - _toast.size.x) * 0.5, vp.y - _toast.size.y - 44)
	if _toast_tween != null and _toast_tween.is_valid():
		_toast_tween.kill()
	_toast_tween = create_tween()
	_toast_tween.tween_property(_toast, "modulate:a", 1.0, 0.15)
	_toast_tween.tween_interval(1.8)
	_toast_tween.tween_property(_toast, "modulate:a", 0.0, 0.4)
	_toast_tween.tween_callback(func() -> void: _toast.visible = false)


# --- document state -----------------------------------------------------------------------------

func _pull() -> void:
	if ed == null:
		_status.text = "The plug-in editor bridge is not in this build."
		return
	var parsed: Variant = JSON.parse_string(ed.status())
	_st = parsed if parsed is Dictionary else {}
	var dirty := bool(_st.get("dirty", false))
	_title.text = str(_st.get("name", "Untitled Plug-in"))
	_dirty_chip.visible = dirty
	_undo.disabled = not bool(_st.get("canUndo", false))
	_redo.disabled = not bool(_st.get("canRedo", false))
	_undo.tooltip_text = ("Undo %s  (⌘Z)" % str(_st.get("undo", ""))) if str(_st.get("undo", "")) != "" else "Nothing to undo"
	_redo.tooltip_text = ("Redo %s  (⇧⌘Z)" % str(_st.get("redo", ""))) if str(_st.get("redo", "")) != "" else "Nothing to redo"
	var path := _doc_path()
	var meta: Array = []
	if str(_st.get("author", "")) != "":
		meta.append("by " + str(_st.get("author", "")))
	if str(_st.get("version", "")) != "":
		meta.append("v" + str(_st.get("version", "")))
	meta.append(path.get_file() if path != "" else "Not saved yet")
	_subtitle.text = "  ·  ".join(meta)
	_subtitle.tooltip_text = path
	var err := str(_st.get("error", ""))
	if err != "":
		_set_status(err, true)
	else:
		_set_status(path if path != "" else "Unsaved plug-in, layered over the loaded game", false)
	for id in _tool_buttons:
		var b: Button = _tool_buttons[id]
		var on := str(id) == tool
		b.add_theme_stylebox_override("normal", T.box(EdTheme.SELECT if on else Color(0, 0, 0, 0), 7, Color(0, 0, 0, 0), 0, Vector2(10, 7)))
		var c := EdTheme.AMBER if on else EdTheme.TEXT
		for st in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
			b.add_theme_color_override(st, c)
		var icon_name := ""
		for t in TOOLS:
			if str(t[0]) == str(id):
				icon_name = str(t[2])
		EdTheme.set_icon(b, icon_name, EdTheme.AMBER if on else EdTheme.SECONDARY, 16)


func _set_status(text: String, bad: bool) -> void:
	_status.text = text
	_status.add_theme_color_override("font_color", EdTheme.BAD if bad else EdTheme.SECONDARY)


func _doc_path() -> String:
	var path := str(_st.get("path", ""))
	return path if path != "" else str(_st.get("folder", ""))


## After any document change: status, type counts, lint (debounced).
func _on_edited() -> void:
	_pull()
	_refresh_type_counts()
	if _lint_timer != null and _lint_timer.is_inside_tree():
		_lint_timer.start()
	if _res_list != null and is_instance_valid(_res_list) and _inspector != null and is_instance_valid(_inspector):
		for i in _res_list.item_count:
			if int(_res_list.get_item_metadata(i)) == selected_id:
				var prov := str(_inspector.info.get("prov", "override"))
				_res_list.set_item_text(i, "#%d   %s" % [selected_id, str(_inspector.info.get("name", ""))])
				_res_list.set_item_icon(i, _prov_dot(prov))
				break


func _refresh_lint() -> void:
	if ed == null or _badge == null:
		return
	var parsed: Variant = JSON.parse_string(ed.lint())
	_lint = parsed if parsed is Dictionary else {}
	var errors := int(_lint.get("errors", 0))
	var warnings := int(_lint.get("warnings", 0))
	var color := EdTheme.SECONDARY
	if errors > 0:
		_badge.text = "%d error%s" % [errors, "" if errors == 1 else "s"]
		EdTheme.set_icon(_badge, "xmark.circle.fill", EdTheme.BAD)
		color = EdTheme.BAD
	elif warnings > 0:
		_badge.text = "%d warning%s" % [warnings, "" if warnings == 1 else "s"]
		EdTheme.set_icon(_badge, "exclamationmark.triangle.fill", EdTheme.WARN)
		color = EdTheme.WARN
	else:
		_badge.text = "No issues"
		EdTheme.set_icon(_badge, "checkmark.seal.fill", EdTheme.NEW_C)
	for st in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		_badge.add_theme_color_override(st, color)


# --- resource types sidebar ---------------------------------------------------------------------

func _load_types() -> void:
	_types = []
	if ed == null:
		return
	var parsed: Variant = JSON.parse_string(ed.types())
	if parsed is Array:
		_types = parsed
	if type_code == "" and not _types.is_empty():
		type_code = str(_types[0].get("type", ""))
	_fill_types()


func _type_row(code: String) -> Dictionary:
	for row in _types:
		if str(row.get("type", "")) == code:
			return row
	return {}


func _fill_types() -> void:
	for c in _type_box.get_children():
		_type_box.remove_child(c)
		c.queue_free()
	_type_rows.clear()
	var q := _type_search.text.strip_edges().to_lower()
	var by_cat := {}
	for row in _types:
		var code := str(row.get("type", ""))
		var count := int(row.get("count", 0))
		var changed := int(row.get("changed", 0))
		if not _show_empty and count == 0 and changed == 0 and code != type_code and q == "":
			continue
		if q != "" and not str(row.get("name", "")).to_lower().contains(q) and not code.to_lower().contains(q):
			continue
		var cat := EdTheme.type_category(code, str(row.get("kind", "")))
		if not by_cat.has(cat):
			by_cat[cat] = []
		(by_cat[cat] as Array).append(row)
	for cat in EdTheme.CATEGORIES:
		if not by_cat.has(cat):
			continue
		var rows: Array = by_cat[cat]
		var collapsed := bool(_collapsed.get(cat, false)) and q == ""
		var head := EdTheme.button(str(cat).to_upper(), Callable(), "ghost")
		head.alignment = HORIZONTAL_ALIGNMENT_LEFT
		T.style_text(head, "caption", "semibold", EdTheme.TERTIARY, 10)
		EdTheme.set_icon(head, "chevron.right" if collapsed else "chevron.down", EdTheme.TERTIARY, 10)
		head.add_theme_stylebox_override("normal", T.box(Color(0, 0, 0, 0), 6, Color(0, 0, 0, 0), 0, Vector2(6, 3)))
		head.add_theme_stylebox_override("hover", T.box(EdTheme.HOVER, 6, Color(0, 0, 0, 0), 0, Vector2(6, 3)))
		head.pressed.connect(func() -> void:
			_collapsed[cat] = not bool(_collapsed.get(cat, false))
			_fill_types())
		_type_box.add_child(EdTheme.margin(head, 0, 6, 0, 0))
		if collapsed:
			continue
		for row in rows:
			_type_box.add_child(_type_button(row))


func _type_button(row: Dictionary) -> Control:
	var code := str(row.get("type", ""))
	var on := code == type_code and tool == "resources"
	var b := EdTheme.row_button(_pick_type.bind(code), on)
	b.tooltip_text = "%s  ('%s')" % [str(row.get("name", "")), code]
	var h := EdTheme.hbox(8)
	var count := int(row.get("count", 0))
	h.add_child(EdTheme.icon_rect(EdTheme.type_icon(code, str(row.get("kind", ""))), 15, EdTheme.AMBER if on else (EdTheme.SECONDARY if count > 0 else EdTheme.TERTIARY)))
	var l := EdTheme.label(str(row.get("name", "")), 13, EdTheme.TEXT if count > 0 or on else EdTheme.TERTIARY, "medium" if on else "regular")
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	h.add_child(l)
	var changed := EdTheme.chip("+%d" % int(row.get("changed", 0)), EdTheme.AMBER)
	changed.visible = int(row.get("changed", 0)) > 0
	changed.tooltip_text = "Changed in this plug-in"
	h.add_child(changed)
	var n := EdTheme.label(str(count), 11, EdTheme.TERTIARY)
	h.add_child(n)
	EdTheme.fill_row(b, h, 8, 5)
	_type_rows[code] = {"changed": changed, "count": n}
	return b


func _refresh_type_counts() -> void:
	if ed == null:
		return
	var parsed: Variant = JSON.parse_string(ed.types())
	if not parsed is Array:
		return
	_types = parsed
	for row in _types:
		var code := str(row.get("type", ""))
		if not _type_rows.has(code):
			continue
		var refs: Dictionary = _type_rows[code]
		var chip: Control = refs["changed"]
		var c := int(row.get("changed", 0))
		chip.visible = c > 0
		var inner: Node = chip.get_child(0)
		var chip_label: Label = inner.get_child(inner.get_child_count() - 1)
		chip_label.text = "+%d" % c
		(refs["count"] as Label).text = str(int(row.get("count", 0)))


func _pick_type(code: String) -> void:
	if code != type_code:
		selected_id = -1
	type_code = code
	_show_tool("resources")


# --- tools --------------------------------------------------------------------------------------

func _show_tool(which: String) -> void:
	var was := tool
	tool = which
	_pull()
	_res_list = null
	_inspector = null
	_focus_search = null
	for c in _tool_host.get_children():
		_tool_host.remove_child(c)
		c.queue_free()
	for c in _tool_actions.get_children():
		_tool_actions.remove_child(c)
		c.queue_free()
	for t in TOOLS:
		if str(t[0]) == which:
			_tool_title.text = str(t[1])
			_tool_sub.text = str(t[3])
			_tool_icon.texture = EdTheme.icon(str(t[2]), 22, EdTheme.AMBER)
	if was != which or which == "resources":
		_fill_types()
	if ed == null:
		_host(EdTheme.empty_state("exclamationmark.triangle.fill", "Editor bridge missing", "NovaEditor isn't in this build of the Godot bridge. Rebuild the GDExtension."))
		return
	match which:
		"overview": _tool_overview()
		"resources": _tool_resources()
		"galaxy": _tool_galaxy()
		"system": _tool_system()
		"story": _tool_story()
		"lint": _tool_lint()
		"project": _tool_project()
		"bundle": _tool_bundle()


func _host(c: Control) -> Control:
	_tool_host.add_child(c)
	c.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	return c


## A scrolling, padded, width-capped page for card-based tools.
func _page(max_w := 920.0) -> VBoxContainer:
	var v := EdTheme.vbox(14)
	var cap := HBoxContainer.new()
	cap.add_theme_constant_override("separation", 0)
	cap.add_child(EdTheme.spacer())
	cap.add_child(v)
	cap.add_child(EdTheme.spacer())
	var sc := EdTheme.scroll(EdTheme.margin(cap, 24, 20, 24, 28))
	_host(sc)
	var fit := func() -> void:
		v.custom_minimum_size.x = maxf(300.0, minf(max_w, sc.size.x - 60))
	sc.resized.connect(fit)
	fit.call()
	return v


# --- Overview ---

func _tool_overview() -> void:
	var page := _page()
	var rows_parsed: Variant = JSON.parse_string(ed.changes())
	var rows: Array = rows_parsed if rows_parsed is Array else []
	var n_new := 0
	for r in rows:
		if str(r.get("prov", "")) == "new":
			n_new += 1

	var tiles := EdTheme.hbox(12)
	page.add_child(tiles)
	tiles.add_child(_tile("square.stack.3d.up", str(rows.size()), "Resources touched", EdTheme.TEXT, Callable()))
	tiles.add_child(_tile("plus.circle", str(n_new), "New", EdTheme.NEW_C, Callable()))
	tiles.add_child(_tile("pencil", str(rows.size() - n_new), "Modified", EdTheme.AMBER, Callable()))
	var errs := int(_lint.get("errors", 0))
	var warns := int(_lint.get("warnings", 0))
	tiles.add_child(_tile("checkmark.seal.fill" if errs + warns == 0 else "exclamationmark.triangle.fill", str(errs + warns), "Issues", EdTheme.BAD if errs > 0 else (EdTheme.WARN if warns > 0 else EdTheme.NEW_C), _show_tool.bind("lint")))

	if rows.is_empty():
		_getting_started(page)
		return

	var by_type := {}
	var order: Array = []
	for r in rows:
		var ty := str(r.get("type", ""))
		if not by_type.has(ty):
			by_type[ty] = []
			order.append(ty)
		(by_type[ty] as Array).append(r)
	for ty in order:
		var list: Array = by_type[ty]
		var card := EdTheme.card(12)
		page.add_child(card)
		var body := EdTheme.card_body(card)
		body.add_theme_constant_override("separation", 2)
		var head := EdTheme.hbox(8)
		head.add_child(EdTheme.icon_rect(EdTheme.type_icon(str(ty)), 16, EdTheme.AMBER))
		head.add_child(EdTheme.label(str(list[0].get("typeName", ty)), 14, EdTheme.TEXT, "semibold"))
		head.add_child(EdTheme.chip(str(list.size()), EdTheme.SECONDARY))
		head.add_child(EdTheme.spacer())
		head.add_child(EdTheme.button("Browse", _pick_type.bind(str(ty)), "ghost", "arrow.right"))
		body.add_child(EdTheme.margin(head, 4, 0, 0, 6))
		for r in list:
			body.add_child(_change_row(r))


func _tile(icon_name: String, value: String, caption: String, color: Color, cb: Callable) -> Control:
	var b := EdTheme.row_button(cb)
	b.add_theme_stylebox_override("normal", T.box(EdTheme.CARD, 10, EdTheme.CARD_LINE, 1))
	b.add_theme_stylebox_override("hover", T.box(EdTheme.CARD.lightened(0.05) if cb.is_valid() else EdTheme.CARD, 10, EdTheme.CARD_LINE, 1))
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if cb.is_valid() else Control.CURSOR_ARROW
	var v := EdTheme.vbox(2)
	var top := EdTheme.hbox(8)
	top.add_child(EdTheme.icon_rect(icon_name, 16, color))
	top.add_child(EdTheme.label(value, 24, EdTheme.TEXT, "semibold"))
	v.add_child(top)
	v.add_child(EdTheme.label(caption, 12, EdTheme.SECONDARY))
	EdTheme.fill_row(b, v, 14, 12)
	return b


func _change_row(r: Dictionary) -> Control:
	var ty := str(r.get("type", ""))
	var rid := int(r.get("id", -1))
	var prov := str(r.get("prov", ""))
	var b := EdTheme.row_button(_open_resource.bind(ty, rid))
	var h := EdTheme.hbox(10)
	h.add_child(EdTheme.icon_rect("circle.fill", 8, EdTheme.prov_color(prov)))
	var nm := EdTheme.label(str(r.get("name", "")), 13, EdTheme.TEXT, "medium")
	nm.custom_minimum_size.x = 200
	nm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	h.add_child(nm)
	h.add_child(EdTheme.label("#%d" % rid, 11, EdTheme.TERTIARY))
	var sm := EdTheme.label(str(r.get("summary", "")), 12, EdTheme.SECONDARY)
	sm.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sm.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	h.add_child(sm)
	h.add_child(EdTheme.chip(EdTheme.prov_label(prov), EdTheme.prov_color(prov)))
	EdTheme.fill_row(b, h, 10, 7)
	b.tooltip_text = str(r.get("summary", ""))
	return b


func _getting_started(page: VBoxContainer) -> void:
	var card := EdTheme.card(20)
	page.add_child(card)
	var body := EdTheme.card_body(card)
	body.add_theme_constant_override("separation", 12)
	body.add_child(EdTheme.heading("Start building", 17))
	body.add_child(EdTheme.wrap_label("A plug-in is a layer over the loaded game. Edit anything and only your changes are saved — the base data is never touched.", 13))
	var steps := [
		["cylinder", "Edit resources", "Pick a type in the sidebar, then change fields or press New.", func() -> void: _pick_type(type_code if type_code != "" else "shïp")],
		["map", "Shape the galaxy", "Drag systems, draw hyperlinks, place stellars.", func() -> void: _show_tool("galaxy")],
		["arrow.triangle.branch", "Wire the story", "See which missions and crons start each other.", func() -> void: _show_tool("story")],
		["play.fill", "Test run", "Fly your changes with a sandbox pilot.", _test_run],
	]
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	body.add_child(grid)
	for s in steps:
		var b := EdTheme.row_button(s[3])
		b.add_theme_stylebox_override("normal", T.box(Color(1, 1, 1, 0.04), 10, EdTheme.CARD_LINE, 1))
		b.add_theme_stylebox_override("hover", T.box(EdTheme.SELECT, 10, Color(EdTheme.AMBER.r, EdTheme.AMBER.g, EdTheme.AMBER.b, 0.35), 1))
		var h := EdTheme.hbox(12)
		h.add_child(EdTheme.icon_rect(str(s[0]), 22, EdTheme.AMBER))
		var v := EdTheme.vbox(2)
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		v.add_child(EdTheme.label(str(s[1]), 14, EdTheme.TEXT, "semibold"))
		var d := EdTheme.label(str(s[2]), 12, EdTheme.SECONDARY)
		d.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		d.custom_minimum_size.x = 220
		v.add_child(d)
		h.add_child(v)
		EdTheme.fill_row(b, h, 14, 12)
		grid.add_child(b)

	var open := EdTheme.card(16)
	page.add_child(open)
	var ob := EdTheme.card_body(open)
	var oh := EdTheme.hbox(8)
	oh.add_child(EdTheme.heading("Open a plug-in", 15))
	oh.add_child(EdTheme.spacer())
	oh.add_child(EdTheme.button("Open File…", func() -> void: _pick_open(false), "plain", "folder"))
	oh.add_child(EdTheme.button("Open Folder…", func() -> void: _pick_open(true), "plain", "folder"))
	oh.add_child(EdTheme.button("Installed…", _popup_installed, "plain", "puzzlepiece.extension"))
	ob.add_child(oh)
	var recents := _recents()
	if recents.is_empty():
		ob.add_child(EdTheme.label("No recent plug-ins yet.", 12, EdTheme.TERTIARY))
	for r in recents:
		var path := str(r.get("path", ""))
		var b := EdTheme.row_button(_open_any.bind(path))
		var h := EdTheme.hbox(10)
		h.add_child(EdTheme.icon_rect("clock", 14, EdTheme.TERTIARY))
		var l := EdTheme.label(str(r.get("name", path.get_file())), 13)
		l.custom_minimum_size.x = 180
		h.add_child(l)
		var p := EdTheme.label(path, 11, EdTheme.TERTIARY)
		p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		p.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		h.add_child(p)
		EdTheme.fill_row(b, h, 8, 6)
		ob.add_child(b)


# --- Resources ---

func _prov_dot(prov: String) -> Texture2D:
	return EdTheme.icon("circle.fill", 8, EdTheme.prov_color(prov) if prov != "base" else Color(0, 0, 0, 0))


func _tool_resources() -> void:
	var row := _type_row(type_code)
	var tname := str(row.get("name", type_code))
	_tool_title.text = tname if tname != "" else "Resources"
	_tool_sub.text = "%d in the merged game  ·  %d in this plug-in  ·  type '%s'" % [int(row.get("count", 0)), int(row.get("changed", 0)), type_code]
	_tool_icon.texture = EdTheme.icon(EdTheme.type_icon(type_code, str(row.get("kind", ""))), 22, EdTheme.AMBER)
	var new_btn := EdTheme.button("New", _create_current, "plain", "plus")
	new_btn.tooltip_text = "New %s  (⌘N)" % tname
	_tool_actions.add_child(new_btn)

	var split := HSplitContainer.new()
	_host(split)
	var left := PanelContainer.new()
	left.custom_minimum_size = Vector2(300, 0)
	left.add_theme_stylebox_override("panel", T.box(EdTheme.WELL, 0, Color(0, 0, 0, 0), 0, Vector2(10, 10)))
	split.add_child(left)
	var lv := EdTheme.vbox(8)
	left.add_child(lv)
	var search := EdTheme.field("Search by name or ID", "magnifyingglass")
	_focus_search = search
	lv.add_child(search)
	var legend := EdTheme.hbox(10)
	for p in [["new", "New"], ["override", "Modified"], ["plugin", "Other plug-in"]]:
		var lh := EdTheme.hbox(4)
		lh.add_child(EdTheme.icon_rect("circle.fill", 7, EdTheme.prov_color(str(p[0]))))
		lh.add_child(EdTheme.label(str(p[1]), 11, EdTheme.TERTIARY))
		legend.add_child(lh)
	lv.add_child(legend)
	var list := ItemList.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	list.fixed_icon_size = Vector2i(8, 8)
	list.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	_res_list = list
	lv.add_child(list)
	var count_label := EdTheme.label("", 11, EdTheme.TERTIARY)
	lv.add_child(count_label)

	var right := PanelContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.add_theme_stylebox_override("panel", T.box(EdTheme.BG))
	split.add_child(right)
	var insp := Inspector.new()
	_inspector = insp
	var sc := EdTheme.scroll(EdTheme.margin(insp, 22, 18, 22, 28))
	insp.scroller = sc
	right.add_child(sc)
	var empty := EdTheme.empty_state(EdTheme.type_icon(type_code), "Nothing selected", "Pick a %s from the list, or create a new one." % tname.to_lower(), [EdTheme.button("New %s" % tname, _create_current, "accent", "plus")])
	right.add_child(empty)
	insp.edited.connect(_on_edited)
	insp.navigate.connect(_open_resource)
	insp.message.connect(func(t: String, bad: bool) -> void:
		if bad:
			_set_status(t, true)
		_toast_show(t, bad))
	insp.command.connect(_on_inspector_command)

	var show := func() -> void:
		empty.visible = selected_id < 0
		sc.visible = selected_id >= 0
		if selected_id >= 0:
			insp.show_resource(ed, type_code, selected_id)
			sc.scroll_vertical = 0
	var fill := func() -> void:
		list.clear()
		var parsed: Variant = JSON.parse_string(ed.browse(type_code, search.text))
		var rows: Array = parsed if parsed is Array else []
		var pick := -1
		for r in rows:
			var rid := int(r.get("id", 0))
			var prov := str(r.get("prov", ""))
			var i := list.add_item("#%d   %s" % [rid, str(r.get("name", ""))], _prov_dot(prov))
			list.set_item_metadata(i, rid)
			if prov == "plugin":
				list.set_item_tooltip(i, "From %s" % str(r.get("plugin", "")))
			if rid == selected_id:
				pick = i
		count_label.text = "%d shown" % rows.size()
		if pick >= 0:
			list.select(pick)
			list.ensure_current_is_visible()
	search.text_changed.connect(func(_t: String) -> void: fill.call())
	search.text_submitted.connect(func(_t: String) -> void:
		if list.item_count > 0:
			list.select(0)
			list.item_selected.emit(0))
	list.item_selected.connect(func(i: int) -> void:
		selected_id = int(list.get_item_metadata(i))
		show.call())
	fill.call()
	if selected_id < 0 and list.item_count > 0:
		list.select(0)
		selected_id = int(list.get_item_metadata(0))
	show.call()


func _open_resource(ty: String, rid: int) -> void:
	if ty == "" or rid < 0:
		return
	type_code = ty
	selected_id = rid
	_show_tool("resources")


func _on_inspector_command(what: String) -> void:
	match what:
		"duplicate": _duplicate_current()
		"revert": _revert_current()
		"renumber":
			_renumber_spin.value = selected_id
			_renumber.popup_centered(Vector2i(380, 0))
		"delete":
			_ask("Delete this resource?", "It is removed from your plug-in. You can undo this.", "Delete", func() -> void:
				ed.remove(type_code, selected_id)
				selected_id = -1
				_on_edited()
				_show_tool("resources")
				_toast_show("Deleted"))


func _ask(title: String, text: String, ok: String, cb: Callable) -> void:
	_confirm.title = title
	_confirm.dialog_text = text
	_confirm.ok_button_text = ok
	_confirm_cb = cb
	_confirm.popup_centered(Vector2i(380, 0))


func _do_renumber() -> void:
	var to := int(_renumber_spin.value)
	if to == selected_id:
		return
	var parsed: Variant = JSON.parse_string(ed.renumber(type_code, selected_id, to, _renumber_refs.button_pressed))
	if parsed is Dictionary and bool((parsed as Dictionary).get("ok", false)):
		selected_id = to
		_on_edited()
		_show_tool("resources")
		_toast_show("Now #%d" % to)
	else:
		var err := str((parsed as Dictionary).get("error", "Couldn't change the ID.")) if parsed is Dictionary else "Couldn't change the ID."
		_set_status(err, true)
		_toast_show(err, true)


# --- Galaxy ---

func _tool_galaxy() -> void:
	var parsed: Variant = JSON.parse_string(ed.galaxy())
	var stack := Control.new()
	_host(stack)
	var map := GalaxyCanvas.new()
	map.set_data(parsed if parsed is Dictionary else {})
	stack.add_child(map)
	map.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	var systems: Array = map.data.get("systems", [])
	_tool_sub.text = "%d systems  ·  %d nebulae  ·  scroll to zoom, drag empty space to pan" % [systems.size(), (map.data.get("nebulae", []) as Array).size()]

	var bar := _floating(stack, Control.PRESET_TOP_LEFT, Vector2(14, 14))
	var bh := EdTheme.hbox(4)
	bar.add_child(bh)
	var sel_btn := EdTheme.icon_button("cursorarrow", "Select & move systems", Callable(), EdTheme.AMBER)
	var link_btn := EdTheme.icon_button("link", "Link mode: click two systems to link or unlink them (hold Shift to keep chaining)", Callable(), EdTheme.SECONDARY)
	var set_mode := func(m: String) -> void:
		map.set_mode(m)
		EdTheme.set_icon(sel_btn, "cursorarrow", EdTheme.AMBER if m == "select" else EdTheme.SECONDARY, 16)
		EdTheme.set_icon(link_btn, "link", EdTheme.AMBER if m == "link" else EdTheme.SECONDARY, 16)
		sel_btn.add_theme_stylebox_override("normal", T.box(EdTheme.SELECT if m == "select" else Color(0, 0, 0, 0), 7))
		link_btn.add_theme_stylebox_override("normal", T.box(EdTheme.SELECT if m == "link" else Color(0, 0, 0, 0), 7))
	sel_btn.pressed.connect(set_mode.bind("select"))
	link_btn.pressed.connect(set_mode.bind("link"))
	bh.add_child(sel_btn)
	bh.add_child(link_btn)
	set_mode.call("select")
	bh.add_child(_vsep())
	var find := EdTheme.field("Find system", "magnifyingglass")
	find.custom_minimum_size.x = 200
	_focus_search = find
	bh.add_child(find)
	find.text_changed.connect(func(t: String) -> void:
		map.highlight = t
		map.queue_redraw())
	bh.add_child(_vsep())
	bh.add_child(EdTheme.icon_button("zoom.out", "Zoom out", func() -> void: map.zoom_by(1.0 / 1.25)))
	bh.add_child(EdTheme.icon_button("zoom.in", "Zoom in", func() -> void: map.zoom_by(1.25)))
	bh.add_child(EdTheme.icon_button("fit", "Fit the whole galaxy", func() -> void: map.fit(map.content_rect())))

	var legend := _floating(stack, Control.PRESET_BOTTOM_RIGHT, Vector2(-14, -14))
	var lv := EdTheme.hbox(12)
	legend.add_child(lv)
	for p in [["base", "Base game"], ["override", "Modified"], ["new", "New"]]:
		var lh := EdTheme.hbox(5)
		var base := str(p[0]) == "base"
		lh.add_child(EdTheme.icon_rect("circle.fill" if base else "circle", 10, EdTheme.SECONDARY if base else EdTheme.prov_color(str(p[0]))))
		lh.add_child(EdTheme.label(str(p[1]), 11, EdTheme.SECONDARY))
		lv.add_child(lh)

	var info := _floating(stack, Control.PRESET_BOTTOM_LEFT, Vector2(14, -14))
	info.visible = false
	var iv := EdTheme.vbox(6)
	info.add_child(iv)
	var show_sel := func(id: int) -> void:
		for c in iv.get_children():
			c.queue_free()
		var s: Dictionary = map.system(id)
		info.visible = not s.is_empty()
		if s.is_empty():
			return
		var h := EdTheme.hbox(8)
		h.add_child(EdTheme.icon_rect("sun.max", 16, Color(float(s.get("r", 0.7)), float(s.get("g", 0.7)), float(s.get("b", 0.7)))))
		h.add_child(EdTheme.label(str(s.get("name", "")), 15, EdTheme.TEXT, "semibold"))
		h.add_child(EdTheme.chip("#%d" % id, EdTheme.SECONDARY))
		if str(s.get("prov", "base")) != "base":
			h.add_child(EdTheme.chip(EdTheme.prov_label(str(s.get("prov", ""))), EdTheme.prov_color(str(s.get("prov", "")))))
		iv.add_child(h)
		iv.add_child(EdTheme.label("(%d, %d)  ·  %d links  ·  %d stellars" % [int(s.get("x", 0)), int(s.get("y", 0)), (s.get("links", []) as Array).size(), int(s.get("spobs", 0))], 12, EdTheme.SECONDARY))
		var row := EdTheme.hbox(6)
		row.add_child(EdTheme.button("Open System", func() -> void:
			_system_id = id
			_show_tool("system"), "accent", "sun.max"))
		row.add_child(EdTheme.button("Edit Record", _open_resource.bind("sÿst", id), "plain", "slider.horizontal.3"))
		iv.add_child(row)
		info.reset_size()
	find.text_submitted.connect(func(t: String) -> void:
		var q := t.strip_edges().to_lower()
		if q == "":
			return
		for s in map.data.get("systems", []):
			if str(s.get("name", "")).to_lower().contains(q) or str(int(s.get("id", -1))) == q:
				var sid := int(s.get("id", -1))
				map.focus_system(sid)
				show_sel.call(sid)
				break)
	map.selected.connect(show_sel)
	map.opened.connect(func(id: int) -> void:
		_system_id = id
		_show_tool("system"))
	map.moved.connect(func(id: int, x: int, y: int) -> void:
		ed.galaxy_move(id, x, y)
		_on_edited()
		show_sel.call(id))
	map.link_toggled.connect(func(a: int, b: int, on: bool) -> void:
		var st: Variant = JSON.parse_string(ed.galaxy_link(a, b, on))
		_on_edited()
		var err := str((st as Dictionary).get("error", "")) if st is Dictionary else ""
		if err != "":
			_toast_show(err, true)
		else:
			_toast_show("%s %s ↔ %s" % ["Linked" if on else "Unlinked", str(map.system(a).get("name", a)), str(map.system(b).get("name", b))])
		var fresh: Variant = JSON.parse_string(ed.galaxy())
		map.set_data(fresh if fresh is Dictionary else {}))
	if _system_id >= 0:
		var sid := _system_id
		show_sel.call(sid)
		map.selected_id = sid
		map.view_changed.connect(func() -> void: pass)
		map.resized.connect(func() -> void:
			if map.size.x > 10:
				map.focus_system(sid), CONNECT_ONE_SHOT | CONNECT_DEFERRED)


func _floating(parent: Control, preset: int, offset: Vector2) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", T.box(Color(0.12, 0.12, 0.13, 0.94), 10, Color(1, 1, 1, 0.12), 1, Vector2(8, 6)))
	parent.add_child(p)
	p.set_anchors_and_offsets_preset(preset)
	p.grow_horizontal = Control.GROW_DIRECTION_BEGIN if offset.x < 0 else Control.GROW_DIRECTION_END
	p.grow_vertical = Control.GROW_DIRECTION_BEGIN if offset.y < 0 else Control.GROW_DIRECTION_END
	p.offset_left += offset.x
	p.offset_right += offset.x
	p.offset_top += offset.y
	p.offset_bottom += offset.y
	return p


# --- Star system ---

func _tool_system() -> void:
	if _system_id < 0:
		_system_id = selected_id if type_code == "sÿst" and selected_id >= 0 else _first_system()
	var parsed: Variant = JSON.parse_string(ed.system_info(_system_id))
	var info: Dictionary = parsed if parsed is Dictionary else {}
	var choose := EdTheme.button("Choose System…", Callable(), "plain", "magnifyingglass")
	_tool_actions.add_child(choose)
	choose.pressed.connect(func() -> void:
		_picker_host.ed = ed
		_picker_host.open_picker("sÿst", _system_id, choose, func(id: int) -> void:
			if id >= 0:
				_system_id = id
				_show_tool("system")))
	if info.is_empty():
		_host(EdTheme.empty_state("sun.max", "No system selected", "Choose a system, or double-click one on the galaxy map.", [EdTheme.button("Open Galaxy Map", _show_tool.bind("galaxy"), "accent", "map")]))
		return
	_tool_title.text = str(info.get("name", "Star System"))
	_tool_sub.text = "System #%d  ·  %s  ·  at (%d, %d)" % [_system_id, str(info.get("govtName", "")), int(info.get("x", 0)), int(info.get("y", 0))]

	var split := HSplitContainer.new()
	_host(split)
	var left := PanelContainer.new()
	left.custom_minimum_size = Vector2(330, 0)
	left.add_theme_stylebox_override("panel", T.box(EdTheme.WELL))
	split.add_child(left)
	var lv := EdTheme.vbox(12)
	left.add_child(EdTheme.scroll(EdTheme.margin(lv, 14, 14, 14, 14)))

	var head := EdTheme.card(14)
	lv.add_child(head)
	var hb := EdTheme.card_body(head)
	var hr := EdTheme.hbox(6)
	hr.add_child(EdTheme.button("Edit Record", _open_resource.bind("sÿst", _system_id), "plain", "slider.horizontal.3"))
	hr.add_child(EdTheme.button("Show on Map", _show_tool.bind("galaxy"), "plain", "map"))
	hb.add_child(hr)
	hb.add_child(EdTheme.wrap_label("Drag stellars on the map to move them. Double-click one to edit it.", 11, EdTheme.TERTIARY))

	var links: Array = info.get("links", [])
	var lc := EdTheme.card(12)
	lv.add_child(lc)
	var lb := EdTheme.card_body(lc)
	lb.add_theme_constant_override("separation", 2)
	var lh := EdTheme.hbox(6)
	lh.add_child(EdTheme.caps("Hyperlinks  ·  %d / 16" % links.size()))
	lh.add_child(EdTheme.spacer())
	var add_link := EdTheme.button("Add", Callable(), "ghost", "plus")
	lh.add_child(add_link)
	lb.add_child(EdTheme.margin(lh, 4, 0, 0, 4))
	add_link.pressed.connect(func() -> void:
		_picker_host.ed = ed
		_picker_host.open_picker("sÿst", -1, add_link, func(id: int) -> void:
			if id < 0:
				return
			var st: Variant = JSON.parse_string(ed.galaxy_link(_system_id, id, true))
			var err := str((st as Dictionary).get("error", "")) if st is Dictionary else ""
			_on_edited()
			_toast_show(err if err != "" else "Linked", err != "")
			_show_tool("system")))
	if links.is_empty():
		lb.add_child(EdTheme.label("No hyperlinks — this system is unreachable.", 12, EdTheme.WARN))
	for link in links:
		var lid := int(link.get("id", 0))
		var row := EdTheme.hbox(4)
		var b := EdTheme.row_button(func() -> void:
			_system_id = lid
			_show_tool("system"))
		var h := EdTheme.hbox(8)
		h.add_child(EdTheme.icon_rect("sun.max", 13, EdTheme.SECONDARY))
		var nl := EdTheme.label(str(link.get("name", "")), 13)
		nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(nl)
		h.add_child(EdTheme.label("#%d" % lid, 11, EdTheme.TERTIARY))
		EdTheme.fill_row(b, h, 8, 5)
		b.tooltip_text = "Go to %s" % str(link.get("name", ""))
		row.add_child(b)
		row.add_child(EdTheme.icon_button("link.slash", "Unlink", func() -> void:
			ed.galaxy_link(_system_id, lid, false)
			_on_edited()
			_toast_show("Unlinked")
			_show_tool("system"), EdTheme.TERTIARY))
		lb.add_child(row)

	var stellars: Array = info.get("stellars", [])
	var sc := EdTheme.card(12)
	lv.add_child(sc)
	var sb := EdTheme.card_body(sc)
	sb.add_theme_constant_override("separation", 2)
	var sh := EdTheme.hbox(6)
	sh.add_child(EdTheme.caps("Stellars  ·  %d / 16" % stellars.size()))
	sh.add_child(EdTheme.spacer())
	var add_st := EdTheme.button("Add", Callable(), "ghost", "plus")
	sh.add_child(add_st)
	sb.add_child(EdTheme.margin(sh, 4, 0, 0, 4))
	add_st.pressed.connect(func() -> void:
		_picker_host.ed = ed
		_picker_host.open_picker("spöb", -1, add_st, func(id: int) -> void:
			if id < 0:
				return
			var st: Variant = JSON.parse_string(ed.system_add_stellar(_system_id, id))
			var err := str((st as Dictionary).get("error", "")) if st is Dictionary else ""
			_on_edited()
			_toast_show(err if err != "" else "Stellar added", err != "")
			_show_tool("system")))
	if stellars.is_empty():
		sb.add_child(EdTheme.label("Empty space. Add a stellar to give pilots somewhere to land.", 12, EdTheme.TERTIARY))

	var canvas_box := Control.new()
	canvas_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(canvas_box)
	var map := SystemCanvas.new()
	map.set_info(info)
	canvas_box.add_child(map)
	map.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	for sp in stellars:
		var sid := int(sp.get("id", 0))
		var row := EdTheme.hbox(4)
		var b := EdTheme.row_button(func() -> void:
			map.selected_id = sid
			map.queue_redraw())
		var h := EdTheme.hbox(8)
		h.add_child(EdTheme.icon_rect("planet", 13, EdTheme.SECONDARY))
		var nl := EdTheme.label(str(sp.get("name", "")), 13)
		nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		nl.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		h.add_child(nl)
		h.add_child(EdTheme.label("%d, %d" % [int(sp.get("x", 0)), int(sp.get("y", 0))], 11, EdTheme.TERTIARY))
		EdTheme.fill_row(b, h, 8, 5)
		row.add_child(b)
		row.add_child(EdTheme.icon_button("slider.horizontal.3", "Edit stellar", _open_resource.bind("spöb", sid), EdTheme.TERTIARY))
		row.add_child(EdTheme.icon_button("minus", "Remove from this system", _remove_stellar.bind(sid), EdTheme.TERTIARY))
		sb.add_child(row)

	var zoom := _floating(canvas_box, Control.PRESET_TOP_RIGHT, Vector2(-14, 14))
	var zh := EdTheme.hbox(2)
	zoom.add_child(zh)
	zh.add_child(EdTheme.icon_button("zoom.out", "Zoom out", func() -> void: map.zoom_by(1.0 / 1.25)))
	zh.add_child(EdTheme.icon_button("zoom.in", "Zoom in", func() -> void: map.zoom_by(1.25)))
	zh.add_child(EdTheme.icon_button("fit", "Fit", func() -> void: map.fit(map.content_rect())))
	map.moved.connect(func(id: int, x: int, y: int) -> void:
		ed.stellar_move(id, x, y)
		_on_edited())
	map.opened.connect(func(id: int) -> void: _open_resource("spöb", id))


func _remove_stellar(sid: int) -> void:
	ed.system_remove_stellar(_system_id, sid)
	_on_edited()
	_toast_show("Stellar removed")
	_show_tool("system")


# --- Story ---

func _tool_story() -> void:
	var parsed: Variant = JSON.parse_string(ed.story())
	var data: Dictionary = parsed if parsed is Dictionary else {}
	_tool_sub.text = "%d missions & crons  ·  %d storylines  ·  %d control bits in use" % [(data.get("nodes", []) as Array).size(), int(data.get("components", 0)), int(data.get("bitCount", 0))]
	var split := HSplitContainer.new()
	_host(split)
	var stack := Control.new()
	stack.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	split.add_child(stack)
	var map := StoryCanvas.new()
	map.set_data(data)
	stack.add_child(map)
	map.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	var bar := _floating(stack, Control.PRESET_TOP_LEFT, Vector2(14, 14))
	var bh := EdTheme.hbox(4)
	bar.add_child(bh)
	var find := EdTheme.field("Find mission, cron or storyline", "magnifyingglass")
	find.custom_minimum_size.x = 260
	_focus_search = find
	bh.add_child(find)
	find.text_changed.connect(func(t: String) -> void:
		map.highlight = t
		map.queue_redraw())
	find.text_submitted.connect(func(_t: String) -> void: map.focus_node(map.first_match()))
	var mine := CheckBox.new()
	mine.text = "Only my changes"
	mine.toggled.connect(func(on: bool) -> void:
		map.only_touched = on
		map.queue_redraw())
	bh.add_child(mine)
	bh.add_child(_vsep())
	bh.add_child(EdTheme.icon_button("zoom.out", "Zoom out", func() -> void: map.zoom_by(1.0 / 1.25)))
	bh.add_child(EdTheme.icon_button("zoom.in", "Zoom in", func() -> void: map.zoom_by(1.25)))
	bh.add_child(EdTheme.icon_button("fit", "Fit everything", func() -> void: map.fit(map.content_rect())))

	var legend := _floating(stack, Control.PRESET_BOTTOM_LEFT, Vector2(14, -14))
	var lh := EdTheme.hbox(12)
	legend.add_child(lh)
	for p in [[Color(0.82, 0.82, 0.86), "Mission"], [Color(0.45, 0.65, 1.0), "Cron"], [EdTheme.AMBER, "In this plug-in"], [EdTheme.BAD, "Unreachable"]]:
		var item := EdTheme.hbox(5)
		item.add_child(EdTheme.icon_rect("circle.fill", 9, p[0]))
		item.add_child(EdTheme.label(str(p[1]), 11, EdTheme.SECONDARY))
		lh.add_child(item)
	lh.add_child(_vsep())
	for p in [[StoryCanvas.STARTS, "starts"], [Color(0.35, 0.85, 0.5), "enables"], [Color(1.0, 0.35, 0.3), "disables"]]:
		var item := EdTheme.hbox(5)
		var line := ColorRect.new()
		line.color = p[0]
		line.custom_minimum_size = Vector2(14, 2)
		line.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		item.add_child(line)
		item.add_child(EdTheme.label(str(p[1]), 11, EdTheme.SECONDARY))
		lh.add_child(item)

	var side := PanelContainer.new()
	side.custom_minimum_size = Vector2(320, 0)
	side.add_theme_stylebox_override("panel", T.box(EdTheme.WELL))
	split.add_child(side)
	var sv := EdTheme.vbox(12)
	side.add_child(EdTheme.scroll(EdTheme.margin(sv, 14, 14, 14, 14)))
	var sel_card := EdTheme.card(12)
	sv.add_child(sel_card)
	var sel := EdTheme.card_body(sel_card)
	sel.add_child(EdTheme.wrap_label("Click a node to inspect it. Double-click opens it.", 12, EdTheme.TERTIARY))
	map.selected.connect(func(ty: String, rid: int, n: Dictionary) -> void:
		for c in sel.get_children():
			c.queue_free()
		var h := EdTheme.hbox(8)
		h.add_child(EdTheme.icon_rect(EdTheme.type_icon(ty), 16, EdTheme.AMBER))
		var nl := EdTheme.label(str(n.get("name", "")).get_slice(";", 0), 14, EdTheme.TEXT, "semibold")
		nl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		nl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(nl)
		sel.add_child(h)
		var chips := HFlowContainer.new()
		chips.add_theme_constant_override("h_separation", 6)
		chips.add_theme_constant_override("v_separation", 6)
		var is_cron := bool(n.get("cron", false))
		chips.add_child(EdTheme.chip("%s #%d" % ["Cron" if is_cron else "Mission", rid], EdTheme.SECONDARY))
		if str(n.get("story", "")) != "":
			chips.add_child(EdTheme.chip(str(n.get("story", "")), EdTheme.INFO))
		if bool(n.get("touched", false)):
			chips.add_child(EdTheme.chip("In this plug-in", EdTheme.AMBER))
		if bool(n.get("unreachable", false)):
			chips.add_child(EdTheme.chip("Unreachable", EdTheme.BAD))
		if bool(n.get("dead", false)):
			chips.add_child(EdTheme.chip("Dead end", EdTheme.WARN))
		sel.add_child(chips)
		sel.add_child(EdTheme.button("Edit %s" % ("Cron" if is_cron else "Mission"), _open_resource.bind(ty, rid), "accent", "slider.horizontal.3")))
	map.opened.connect(_open_resource)

	var bits_card := EdTheme.card(12)
	sv.add_child(bits_card)
	var bb := EdTheme.card_body(bits_card)
	bb.add_child(EdTheme.caps("Control bits"))
	var look := EdTheme.hbox(6)
	var bit_spin := EdTheme.spin(0, 0, 9999)
	bit_spin.prefix = "b"
	look.add_child(bit_spin)
	var refs := EdTheme.vbox(2)
	var show_bit := func(bit: int) -> void:
		for c in refs.get_children():
			c.queue_free()
		var rp: Variant = JSON.parse_string(ed.bit_refs(bit))
		var rows: Array = rp if rp is Array else []
		refs.add_child(EdTheme.label("b%d  ·  %d reference%s" % [bit, rows.size(), "" if rows.size() == 1 else "s"], 12, EdTheme.TEXT, "semibold"))
		for r in rows:
			var ty := str(r.get("type", ""))
			var rid := int(r.get("id", -1))
			var role := str(r.get("role", ""))
			var b := EdTheme.row_button(_open_resource.bind(ty, rid))
			var h := EdTheme.hbox(6)
			h.add_child(EdTheme.chip("sets" if role == "set" else ("tests" if role == "test" else role), EdTheme.NEW_C if role == "set" else EdTheme.INFO))
			var l := EdTheme.label(str(r.get("name", "")).get_slice(";", 0), 12)
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			h.add_child(l)
			h.add_child(EdTheme.label(str(r.get("field", "")), 10, EdTheme.TERTIARY))
			EdTheme.fill_row(b, h, 6, 4)
			b.tooltip_text = "%s #%d  ·  %s" % [ty, rid, str(r.get("field", ""))]
			refs.add_child(b)
	look.add_child(EdTheme.button("Look Up", func() -> void: show_bit.call(int(bit_spin.value)), "plain", "magnifyingglass"))
	bb.add_child(look)
	bb.add_child(refs)
	bb.add_child(EdTheme.caps("Bits in use"))
	var grid := HFlowContainer.new()
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	bb.add_child(grid)
	for bit in (data.get("bits", []) as Array).slice(0, 240):
		var n := int(bit.get("bit", 0))
		var status := str(bit.get("status", "ok"))
		var color := EdTheme.AMBER if bool(bit.get("touched", false)) else (EdTheme.SECONDARY if status == "ok" else EdTheme.WARN)
		var b := EdTheme.button(str(n), func() -> void:
			bit_spin.value = n
			show_bit.call(n), "ghost")
		for st in ["font_color", "font_hover_color", "font_pressed_color"]:
			b.add_theme_color_override(st, color)
		b.tooltip_text = "b%d  ·  %d references  ·  %s" % [n, int(bit.get("n", 0)), status]
		b.custom_minimum_size = Vector2(40, 0)
		grid.add_child(b)


# --- Validation ---

func _tool_lint() -> void:
	_refresh_lint()
	_tool_actions.add_child(EdTheme.button("Check Again", func() -> void: _show_tool("lint"), "plain", "arrow.clockwise"))
	var issues: Array = _lint.get("issues", [])
	var errors := int(_lint.get("errors", 0))
	var warnings := int(_lint.get("warnings", 0))
	if issues.is_empty():
		_host(EdTheme.empty_state("checkmark.seal.fill", "No problems found", "References resolve, IDs are in range and nothing the game needs is missing.", [EdTheme.button("Test Run", _test_run, "accent", "play.fill")]))
		return
	var page := _page()
	var filter := {"sev": ""}
	var tiles := EdTheme.hbox(12)
	page.add_child(tiles)
	var list := EdTheme.vbox(6)
	var fill := func() -> void:
		for c in list.get_children():
			c.queue_free()
		for row in issues:
			var sev := str(row.get("severity", ""))
			if str(filter["sev"]) != "" and sev != str(filter["sev"]):
				continue
			list.add_child(_issue_row(row))
	var notes := issues.size() - errors - warnings
	tiles.add_child(_tile("xmark.circle.fill", str(errors), "Errors", EdTheme.BAD, func() -> void:
		filter["sev"] = "error" if str(filter["sev"]) != "error" else ""
		fill.call()))
	tiles.add_child(_tile("exclamationmark.triangle.fill", str(warnings), "Warnings", EdTheme.WARN, func() -> void:
		filter["sev"] = "warning" if str(filter["sev"]) != "warning" else ""
		fill.call()))
	tiles.add_child(_tile("info.circle.fill", str(notes), "Notes", EdTheme.INFO, func() -> void:
		filter["sev"] = "info" if str(filter["sev"]) != "info" else ""
		fill.call()))
	page.add_child(EdTheme.label("Click a tile to filter. Click an issue to jump to it.", 11, EdTheme.TERTIARY))
	page.add_child(list)
	fill.call()


func _issue_row(row: Dictionary) -> Control:
	var sev := str(row.get("severity", ""))
	var ty := str(row.get("type", ""))
	var rid := int(row.get("id", -1))
	var color := EdTheme.BAD if sev == "error" else (EdTheme.WARN if sev == "warning" else EdTheme.INFO)
	var icon_name := "xmark.circle.fill" if sev == "error" else ("exclamationmark.triangle.fill" if sev == "warning" else "info.circle.fill")
	var b := EdTheme.row_button(_open_resource.bind(ty, rid))
	b.add_theme_stylebox_override("normal", T.box(EdTheme.CARD, 8, EdTheme.CARD_LINE, 1))
	var h := EdTheme.hbox(10)
	h.add_child(EdTheme.icon_rect(icon_name, 16, color))
	var v := EdTheme.vbox(2)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var msg := EdTheme.label(str(row.get("message", "")), 13)
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	v.add_child(msg)
	var meta := EdTheme.hbox(6)
	meta.add_child(EdTheme.icon_rect(EdTheme.type_icon(ty), 12, EdTheme.TERTIARY))
	meta.add_child(EdTheme.label("%s #%d" % [ty, rid], 11, EdTheme.TERTIARY))
	if str(row.get("field", "")) != "":
		meta.add_child(EdTheme.chip(str(row.get("field", "")), EdTheme.TERTIARY))
	if str(row.get("code", "")) != "":
		meta.add_child(EdTheme.label(str(row.get("code", "")), 10, EdTheme.TERTIARY))
	v.add_child(meta)
	h.add_child(v)
	h.add_child(EdTheme.icon_rect("chevron.right", 12, EdTheme.TERTIARY))
	EdTheme.fill_row(b, h, 12, 9)
	return b


# --- Project ---

func _tool_project() -> void:
	var page := _page(760)
	var info := EdTheme.card(18)
	page.add_child(info)
	var ib := EdTheme.card_body(info)
	ib.add_theme_constant_override("separation", 10)
	ib.add_child(EdTheme.heading("Plug-in details", 15))
	var fields := {}
	for spec in [["name", "Name", "Shown in the Plug-ins list"], ["author", "Author", "You, or your team"], ["version", "Version", "e.g. 1.0"]]:
		var row := EdTheme.hbox(12)
		var l := EdTheme.label(str(spec[1]), 13, EdTheme.SECONDARY)
		l.custom_minimum_size.x = 110
		row.add_child(l)
		var e := EdTheme.field(str(spec[2]))
		e.text = str(_st.get(str(spec[0]), ""))
		e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(e)
		fields[spec[0]] = e
		ib.add_child(row)
	var nrow := EdTheme.hbox(12)
	var nl := EdTheme.label("Notes", 13, EdTheme.SECONDARY)
	nl.custom_minimum_size.x = 110
	nl.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	nrow.add_child(nl)
	var notes := TextEdit.new()
	notes.custom_minimum_size = Vector2(0, 110)
	notes.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	notes.placeholder_text = "What does this plug-in change? Credits, requirements…"
	notes.text = str(_st.get("notes", ""))
	notes.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	nrow.add_child(notes)
	ib.add_child(nrow)
	var apply := func() -> void:
		var n := (fields["name"] as LineEdit).text
		var a := (fields["author"] as LineEdit).text
		var v := (fields["version"] as LineEdit).text
		if n == str(_st.get("name", "")) and a == str(_st.get("author", "")) and v == str(_st.get("version", "")) and notes.text == str(_st.get("notes", "")):
			return
		ed.set_plugin_info(n, a, v, notes.text)
		_on_edited()
	for k in fields:
		var e: LineEdit = fields[k]
		e.focus_exited.connect(apply)
		e.text_submitted.connect(func(_t: String) -> void: apply.call())
	notes.focus_exited.connect(apply)

	var share := EdTheme.card(18)
	page.add_child(share)
	var sb := EdTheme.card_body(share)
	sb.add_theme_constant_override("separation", 6)
	sb.add_child(EdTheme.heading("Save & share", 15))
	var path := _doc_path()
	sb.add_child(EdTheme.label(path if path != "" else "Not saved yet", 12, EdTheme.TERTIARY))
	var install := func() -> void:
		var st: Variant = JSON.parse_string(ed.install())
		_pull()
		var err := str((st as Dictionary).get("error", "")) if st is Dictionary else ""
		_toast_show(err if err != "" else "Installed — reload the game data to play it", err != "")
	for spec in [
		["square.and.arrow.down", "Save", "Write your changes to the plug-in file.  ⌘S", func() -> void: _save(false)],
		["doc.on.doc", "Save As…", "Save to a new .rez (or classic .ndat) file and keep editing it.", func() -> void: _save(true)],
		["square.and.arrow.up", "Export Copy…", "Write a copy without changing which file you're editing.", func() -> void: _save_dialog(true)],
		["puzzlepiece.extension.fill", "Install into Plug-ins", "Copy into your Plug-ins folder so the game loads it.", install],
	]:
		var b := EdTheme.row_button(spec[3])
		var h := EdTheme.hbox(12)
		h.add_child(EdTheme.icon_rect(str(spec[0]), 18, EdTheme.AMBER))
		var v := EdTheme.vbox(1)
		v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		v.add_child(EdTheme.label(str(spec[1]), 13, EdTheme.TEXT, "semibold"))
		v.add_child(EdTheme.label(str(spec[2]), 12, EdTheme.SECONDARY))
		h.add_child(v)
		h.add_child(EdTheme.icon_rect("chevron.right", 12, EdTheme.TERTIARY))
		EdTheme.fill_row(b, h, 10, 8)
		sb.add_child(b)

	var conf := EdTheme.card(18)
	page.add_child(conf)
	var cb := EdTheme.card_body(conf)
	cb.add_child(EdTheme.heading("Conflicts", 15))
	var cp: Variant = JSON.parse_string(ed.conflicts())
	var conflicts: Array = cp if cp is Array else []
	if conflicts.is_empty():
		var ok := EdTheme.hbox(8)
		ok.add_child(EdTheme.icon_rect("checkmark.circle.fill", 14, EdTheme.NEW_C))
		ok.add_child(EdTheme.label("No other enabled plug-in owns a record this one replaces.", 12, EdTheme.SECONDARY))
		cb.add_child(ok)
	else:
		cb.add_child(EdTheme.wrap_label("These records also come from another enabled plug-in. Whichever loads last wins.", 12, EdTheme.SECONDARY))
		for row in conflicts:
			var ty := str(row.get("type", ""))
			var rid := int(row.get("id", -1))
			var b := EdTheme.row_button(_open_resource.bind(ty, rid))
			var h := EdTheme.hbox(8)
			h.add_child(EdTheme.icon_rect("exclamationmark.triangle.fill", 13, EdTheme.WARN))
			var l := EdTheme.label("%s #%d  %s" % [ty, rid, str(row.get("name", ""))], 13)
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			h.add_child(l)
			h.add_child(EdTheme.chip(str(row.get("plugin", "")), EdTheme.PLUGIN_C))
			EdTheme.fill_row(b, h, 8, 5)
			cb.add_child(b)


# --- Bundle ---

func _tool_bundle() -> void:
	var parsed: Variant = JSON.parse_string(ed.bundle())
	var info: Dictionary = parsed if parsed is Dictionary else {}
	var page := _page(760)
	var card := EdTheme.card(18)
	page.add_child(card)
	var body := EdTheme.card_body(card)
	var head := EdTheme.hbox(8)
	head.add_child(EdTheme.heading("Layout", 15))
	head.add_child(EdTheme.chip(str(info.get("format", "rez")).to_upper(), EdTheme.SECONDARY))
	head.add_child(EdTheme.chip("Folder" if bool(info.get("folder", false)) else "Single file", EdTheme.SECONDARY))
	head.add_child(EdTheme.spacer())
	var path := str(info.get("path", ""))
	if path != "":
		head.add_child(EdTheme.button("Show in Folder", func() -> void: OS.shell_show_in_file_manager(path), "plain", "folder"))
	body.add_child(head)
	body.add_child(EdTheme.label(path if path != "" else "Not saved yet", 12, EdTheme.TERTIARY))
	var files: Array = info.get("files", [])
	var fc := EdTheme.card(14)
	page.add_child(fc)
	var fb := EdTheme.card_body(fc)
	fb.add_theme_constant_override("separation", 4)
	fb.add_child(EdTheme.caps("Files  ·  %d" % files.size()))
	if files.is_empty():
		fb.add_child(EdTheme.wrap_label("A new plug-in is a single file until you save it. Opening a plug-in folder shows each data file and HD pack here.", 12, EdTheme.SECONDARY))
	for f in files:
		var h := EdTheme.hbox(10)
		var pack := bool(f.get("pack", false))
		h.add_child(EdTheme.icon_rect("sparkles" if pack else "doc.text", 15, EdTheme.AMBER if pack else EdTheme.SECONDARY))
		var l := EdTheme.label(str(f.get("name", "")), 13)
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(l)
		if str(f.get("name", "")) == str(info.get("primary", "")):
			h.add_child(EdTheme.chip("Primary", EdTheme.AMBER))
		h.add_child(EdTheme.chip("HD pack" if pack else "Data", EdTheme.TERTIARY))
		fb.add_child(EdTheme.margin(h, 6, 4, 6, 4))


# --- commands -----------------------------------------------------------------------------------

func _create_current() -> void:
	if type_code == "" or ed == null:
		return
	var tname := str(_type_row(type_code).get("name", "Resource"))
	var parsed: Variant = JSON.parse_string(ed.create(type_code, "New " + tname))
	if parsed is Dictionary and bool((parsed as Dictionary).get("ok", false)):
		selected_id = int((parsed as Dictionary).get("id", -1))
		_on_edited()
		_show_tool("resources")
		if _inspector != null:
			_inspector.call_deferred("focus_name")
		_toast_show("Created %s #%d" % [tname, selected_id])
	else:
		_pull()
		_toast_show(str((parsed as Dictionary).get("error", "Couldn't create it.")) if parsed is Dictionary else "Couldn't create it.", true)


func _duplicate_current() -> void:
	if selected_id < 0 or type_code == "":
		return
	var parsed: Variant = JSON.parse_string(ed.duplicate(type_code, selected_id))
	if parsed is Dictionary and bool((parsed as Dictionary).get("ok", false)):
		selected_id = int((parsed as Dictionary).get("id", -1))
		_on_edited()
		_show_tool("resources")
		_toast_show("Duplicated as #%d" % selected_id)
	else:
		_pull()


func _revert_current() -> void:
	if selected_id < 0:
		return
	_ask("Revert to the base game?", "Your changes to this resource are dropped from the plug-in. You can undo this.", "Revert", func() -> void:
		ed.revert(type_code, selected_id)
		_on_edited()
		_show_tool("resources")
		_toast_show("Reverted"))


func _do_undo() -> void:
	if ed == null:
		return
	var label := str(_st.get("undo", ""))
	ed.undo()
	_on_edited()
	_show_tool(tool)
	if label != "":
		_toast_show("Undid " + label)


func _do_redo() -> void:
	if ed == null:
		return
	var label := str(_st.get("redo", ""))
	ed.redo()
	_on_edited()
	_show_tool(tool)
	if label != "":
		_toast_show("Redid " + label)


func _test_run() -> void:
	if ed == null:
		return
	var system := _system_id
	if system < 0 and type_code == "sÿst":
		system = selected_id
	var ship := selected_id if type_code == "shïp" else -1
	if not ed.begin_test(nova, data_dir, system, ship):
		_toast_show("A test run or training flight is already going.", true)
		return
	test_requested.emit()


func _request_close() -> void:
	_pull()
	if bool(_st.get("dirty", false)):
		_dirty_dialog.dialog_text = "You have unsaved changes in \"%s\"." % str(_st.get("name", "this plug-in"))
		_dirty_dialog.popup_centered(Vector2i(400, 0))
		return
	_finish_close()


func _discard_and_close() -> void:
	_finish_close()


func _finish_close() -> void:
	closed.emit()


func _save(as_new: bool) -> void:
	_pull()
	if not as_new and _doc_path() != "":
		var parsed: Variant = JSON.parse_string(ed.save())
		_remember(_doc_path(), str(_st.get("name", "")))
		_pull()
		var err := str((parsed as Dictionary).get("error", "")) if parsed is Dictionary else ""
		_toast_show(err if err != "" else "Saved", err != "")
		_refresh_lint()
		return
	_save_dialog(false)


func _save_dialog(export_copy: bool) -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_SAVE_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.use_native_dialog = PilotFiles.want_native()
	fd.filters = PackedStringArray(["*.rez ; Plug-in", "*.ndat ; Classic data"])
	fd.current_file = str(_st.get("name", "Plug-in")).replace(" ", "") + ".rez"
	fd.current_dir = data_dir
	fd.title = "Export Copy" if export_copy else "Save Plug-in"
	fd.file_selected.connect(func(p: String) -> void:
		if export_copy:
			ed.export_copy(p)
			_toast_show("Exported a copy")
		else:
			ed.save_as(p, false)
			_remember(p, str(_st.get("name", "")))
			_toast_show("Saved")
		_pull()
		if tool in ["project", "bundle", "overview"]:
			_show_tool(tool)
		fd.queue_free())
	fd.canceled.connect(fd.queue_free)
	_root.add_child(fd)
	fd.popup_centered_ratio(0.6)


func _open_file_menu() -> void:
	_file_menu.clear()
	_file_menu.add_item("New Plug-in", 0)
	_file_menu.add_item("Open File…", 1)
	_file_menu.add_item("Open Folder…", 2)
	_file_menu.add_item("Open Installed…", 3)
	_file_menu.add_separator("Recent")
	var recents := _recents()
	if recents.is_empty():
		_file_menu.add_item("No Recent Plug-ins", 9)
		_file_menu.set_item_disabled(_file_menu.item_count - 1, true)
	else:
		var i := 0
		for row in recents:
			_file_menu.add_item(str(row.get("name", row.get("path", ""))), 20 + i)
			_file_menu.set_item_tooltip(_file_menu.item_count - 1, str(row.get("path", "")))
			i += 1
	_file_menu.add_separator()
	_file_menu.add_item("Save", 100)
	_file_menu.add_item("Save As…", 101)
	_file_menu.add_item("Export Copy…", 102)
	_file_menu.add_item("Install into Plug-ins", 103)
	_file_menu.reset_size()
	_file_menu.position = Vector2i(_file_btn.global_position + Vector2(0, _file_btn.size.y + 4))
	_file_menu.popup()


func _confirm_discard(then: Callable) -> void:
	_pull()
	if bool(_st.get("dirty", false)):
		_ask("Discard unsaved changes?", "\"%s\" has changes that aren't saved." % str(_st.get("name", "")), "Discard", then)
	else:
		then.call()


func _reset_to_document() -> void:
	selected_id = -1
	_system_id = -1
	_load_types()
	_on_edited()
	_refresh_lint()
	_show_tool("overview")


func _on_file(id: int) -> void:
	match id:
		0:
			_confirm_discard(func() -> void:
				ed.new_document()
				_reset_to_document())
		1:
			_pick_open(false)
		2:
			_pick_open(true)
		3:
			_popup_installed()
		100:
			_save(false)
		101:
			_save(true)
		102:
			_save_dialog(true)
		103:
			ed.install()
			_pull()
			_toast_show("Installed into Plug-ins")
		_:
			if id >= 20:
				var rows := _recents()
				var idx := id - 20
				if idx < rows.size():
					_open_any(str(rows[idx].get("path", "")))


func _pick_open(folder: bool) -> void:
	_confirm_discard(func() -> void:
		var fd := FileDialog.new()
		fd.file_mode = FileDialog.FILE_MODE_OPEN_DIR if folder else FileDialog.FILE_MODE_OPEN_FILE
		fd.access = FileDialog.ACCESS_FILESYSTEM
		fd.use_native_dialog = PilotFiles.want_native()
		fd.current_dir = data_dir
		fd.title = "Open Plug-in Folder" if folder else "Open Plug-in"
		if not folder:
			fd.filters = PackedStringArray(["*.rez, *.ndat ; Plug-in data"])
		var chosen := func(p: String) -> void:
			_open_any(p, false)
			fd.queue_free()
		if folder:
			fd.dir_selected.connect(chosen)
		else:
			fd.file_selected.connect(chosen)
		fd.canceled.connect(fd.queue_free)
		_root.add_child(fd)
		fd.popup_centered_ratio(0.6))


func _open_any(path: String, ask := true) -> void:
	if path == "":
		return
	var go := func() -> void:
		var parsed: Variant = JSON.parse_string(ed.open_path(path))
		var err := str((parsed as Dictionary).get("error", "")) if parsed is Dictionary else ""
		if err == "":
			_remember(path, path.get_file())
		_reset_to_document()
		_toast_show(err if err != "" else "Opened " + path.get_file(), err != "")
	if ask:
		_confirm_discard(go)
	else:
		go.call()


func _popup_installed() -> void:
	_installed_menu.clear()
	var parsed: Variant = JSON.parse_string(ed.installed())
	var rows: Array = parsed if parsed is Array else []
	if rows.is_empty():
		_installed_menu.add_item("No installed plug-ins", 0)
		_installed_menu.set_item_disabled(0, true)
	else:
		var i := 0
		for row in rows:
			_installed_menu.add_item(str(row.get("name", row.get("id", ""))), i)
			_installed_menu.set_item_metadata(i, str(row.get("id", "")))
			i += 1
	_installed_menu.reset_size()
	_installed_menu.position = Vector2i(_file_btn.global_position + Vector2(0, _file_btn.size.y + 4))
	_installed_menu.popup()


func _on_installed(index: int) -> void:
	var id := str(_installed_menu.get_item_metadata(index))
	if id == "":
		return
	_confirm_discard(func() -> void:
		ed.open_installed(id)
		_reset_to_document())


func _recents() -> Array:
	if not FileAccess.file_exists(RECENTS_PATH):
		return []
	var parsed: Variant = JSON.parse_string(FileAccess.get_file_as_string(RECENTS_PATH))
	return parsed if parsed is Array else []


func _remember(path: String, nm: String) -> void:
	if path == "":
		return
	var rows: Array = []
	for row in _recents():
		if str(row.get("path", "")) != path:
			rows.append(row)
	rows.push_front({"path": path, "name": nm if nm != "" else path.get_file()})
	while rows.size() > 8:
		rows.pop_back()
	var f := FileAccess.open(RECENTS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(rows))


func _first_system() -> int:
	var parsed: Variant = JSON.parse_string(ed.galaxy())
	if parsed is Dictionary:
		var systems: Array = (parsed as Dictionary).get("systems", [])
		if not systems.is_empty():
			return int(systems[0].get("id", -1))
	return -1


func _unhandled_input(event: InputEvent) -> void:
	if not visible or ed == null or not event is InputEventKey or not event.pressed or event.echo:
		return
	var key := event as InputEventKey
	if key.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		var focus := _root.get_viewport().gui_get_focus_owner()
		if focus is LineEdit or focus is TextEdit:
			focus.release_focus()
			return
		_request_close()
		return
	if not key.ctrl_pressed and not key.meta_pressed:
		return
	if key.keycode >= KEY_1 and key.keycode <= KEY_8:
		get_viewport().set_input_as_handled()
		_show_tool(str(TOOLS[key.keycode - KEY_1][0]))
		return
	match key.keycode:
		KEY_S:
			get_viewport().set_input_as_handled()
			_save(key.shift_pressed)
		KEY_Z:
			get_viewport().set_input_as_handled()
			if key.shift_pressed:
				_do_redo()
			else:
				_do_undo()
		KEY_Y:
			get_viewport().set_input_as_handled()
			_do_redo()
		KEY_N:
			get_viewport().set_input_as_handled()
			if tool != "resources":
				_show_tool("resources")
			_create_current()
		KEY_D:
			get_viewport().set_input_as_handled()
			if tool == "resources":
				_duplicate_current()
		KEY_F:
			get_viewport().set_input_as_handled()
			if _focus_search != null and is_instance_valid(_focus_search):
				_focus_search.grab_focus()
				_focus_search.select_all()
			else:
				_type_search.grab_focus()
		KEY_R:
			get_viewport().set_input_as_handled()
			_test_run()
		KEY_O:
			get_viewport().set_input_as_handled()
			_pick_open(false)
