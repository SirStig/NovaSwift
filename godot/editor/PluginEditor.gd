# Plugin Editor. Full-screen stand-in for the Apple PluginEditorView: dark three-pane shell,
# the same eight tools, schema inspector, previews, galaxy, system, story, lint, project, files.
# The document lives in NovaEditor (the bridge). This file only draws and forwards edits.
extends CanvasLayer

const EdTheme = preload("res://editor/EditorTheme.gd")
const PilotFiles = preload("res://screens/PilotFiles.gd")
const RECENTS_PATH := "user://editor_recents.json"

signal closed
signal test_requested

const TOOLS := [
	["changes", "Changes"],
	["resources", "Resources"],
	["galaxy", "Galaxy Map"],
	["system", "Star System"],
	["story", "Story & Bits"],
	["lint", "Validation"],
	["project", "Project & Export"],
	["bundle", "Bundle Files"],
]

var nova: Object
var ed: Object
var data_dir := ""
var tool := "changes"
var type_code := ""
var selected_id := -1
var _st := {}
var _types: Array = []
var _filling := false
var _system_id := -1

var _title: Label
var _undo: Button
var _redo: Button
var _badge: Button
var _status: Label
var _type_list: ItemList
var _type_search: LineEdit
var _tool_host: Control
var _tool_buttons := {}
var _file_menu: PopupMenu
var _file_btn: Button
var _installed_menu: PopupMenu
var _dirty_dialog: ConfirmationDialog
var _pending_close := false


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
	_show_tool("changes")


func _build() -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.mouse_filter = Control.MOUSE_FILTER_STOP
	EdTheme.install(root)
	add_child(root)
	var bg := ColorRect.new()
	bg.color = EdTheme.BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(bg)

	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	col.add_theme_constant_override("separation", 0)
	root.add_child(col)

	col.add_child(_top_bar())
	var split := HSplitContainer.new()
	split.size_flags_vertical = Control.SIZE_EXPAND_FILL
	col.add_child(split)
	split.add_child(_sidebar())
	_tool_host = Control.new()
	_tool_host.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_tool_host.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(_tool_host)

	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", EdTheme.fill(EdTheme.BAR))
	bar.custom_minimum_size = Vector2(0, 24)
	_status = EdTheme.label("", 11, EdTheme.SECONDARY)
	_status.offset_left = 12
	bar.add_child(_status)
	col.add_child(bar)

	_file_menu = PopupMenu.new()
	_file_menu.id_pressed.connect(_on_file)
	add_child(_file_menu)
	_installed_menu = PopupMenu.new()
	_installed_menu.id_pressed.connect(_on_installed)
	add_child(_installed_menu)

	_dirty_dialog = ConfirmationDialog.new()
	_dirty_dialog.title = "Close the Plugin Editor?"
	_dirty_dialog.dialog_text = "You have unsaved changes."
	_dirty_dialog.ok_button_text = "Don't Save"
	_dirty_dialog.add_button("Save", true, "save")
	_dirty_dialog.confirmed.connect(_discard_and_close)
	_dirty_dialog.custom_action.connect(func(act):
		if str(act) == "save":
			_save(false)
			if not bool(_st.get("dirty", false)):
				_finish_close())
	add_child(_dirty_dialog)


func _top_bar() -> Control:
	var bar := PanelContainer.new()
	bar.add_theme_stylebox_override("panel", EdTheme.fill(EdTheme.BAR))
	bar.custom_minimum_size = Vector2(0, 44)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	h.alignment = BoxContainer.ALIGNMENT_CENTER
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left", 10)
	margin.add_theme_constant_override("margin_right", 10)
	margin.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	margin.add_child(h)
	bar.add_child(margin)

	h.add_child(EdTheme.button("Close", _request_close))
	_file_btn = EdTheme.button("File", _open_file_menu)
	h.add_child(_file_btn)
	h.add_child(EdTheme.button("Save", func(): _save(false)))
	_undo = EdTheme.button("Undo", _do_undo)
	_redo = EdTheme.button("Redo", _do_redo)
	h.add_child(_undo)
	h.add_child(_redo)
	_title = EdTheme.label("Untitled Plug-in", 14)
	_title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	h.add_child(_title)
	_badge = EdTheme.button("Validate", func(): _show_tool("lint"))
	h.add_child(_badge)
	h.add_child(EdTheme.button("Test Run", _test_run, "accent"))
	return bar


func _sidebar() -> Control:
	var side := PanelContainer.new()
	side.custom_minimum_size = Vector2(220, 0)
	side.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_theme_stylebox_override("panel", EdTheme.fill(EdTheme.SIDE))
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 8)
	pad.add_theme_constant_override("margin_right", 8)
	pad.add_theme_constant_override("margin_top", 8)
	pad.add_theme_constant_override("margin_bottom", 8)
	pad.size_flags_vertical = Control.SIZE_EXPAND_FILL
	pad.add_child(v)
	side.add_child(pad)
	v.add_child(EdTheme.label("TOOLS", 10, EdTheme.TERTIARY))
	for pair in TOOLS:
		var b := EdTheme.button(pair[1], _show_tool.bind(pair[0]))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_tool_buttons[pair[0]] = b
		v.add_child(b)
	v.add_child(HSeparator.new())
	_type_search = EdTheme.field("Filter types")
	_type_search.text_changed.connect(func(_t): _fill_types())
	v.add_child(_type_search)
	_type_list = ItemList.new()
	_type_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_type_list.allow_reselect = true
	_type_list.item_selected.connect(_on_type)
	v.add_child(_type_list)
	return side


# --- chrome -------------------------------------------------------------------

func _pull() -> void:
	if ed == null:
		_status.text = "The plug-in editor bridge is not in this build."
		return
	var parsed = JSON.parse_string(ed.status())
	_st = parsed if parsed is Dictionary else {}
	var name := str(_st.get("name", "Untitled Plug-in"))
	_title.text = name + ("  •" if bool(_st.get("dirty", false)) else "")
	_undo.disabled = not bool(_st.get("canUndo", false))
	_redo.disabled = not bool(_st.get("canRedo", false))
	_undo.tooltip_text = str(_st.get("undo", ""))
	_redo.tooltip_text = str(_st.get("redo", ""))
	var err := str(_st.get("error", ""))
	var path := str(_st.get("path", ""))
	if path == "":
		path = str(_st.get("folder", ""))
	_status.text = err if err != "" else (path if path != "" else "Unsaved plug-in  ·  layered on the loaded game")
	_status.add_theme_color_override("font_color", EdTheme.BAD if err != "" else EdTheme.SECONDARY)
	for id in _tool_buttons:
		var b: Button = _tool_buttons[id]
		b.add_theme_color_override("font_color", EdTheme.AMBER if id == tool else EdTheme.TEXT)


func _load_types() -> void:
	_types = []
	if ed == null:
		return
	var parsed = JSON.parse_string(ed.types())
	if parsed is Array:
		_types = parsed
	if type_code == "" and not _types.is_empty():
		type_code = str(_types[0].get("type", ""))
	_fill_types()


func _fill_types() -> void:
	_type_list.clear()
	var q := _type_search.text.strip_edges().to_lower() if _type_search else ""
	var pick := 0
	for row in _types:
		var label := "%s  %d" % [str(row.get("name", "")), int(row.get("count", 0))]
		var changed := int(row.get("changed", 0))
		if changed > 0:
			label += "  +%d" % changed
		if q != "" and not label.to_lower().contains(q) and not str(row.get("type", "")).to_lower().contains(q):
			continue
		var i := _type_list.add_item(label)
		_type_list.set_item_metadata(i, str(row.get("type", "")))
		if changed > 0:
			_type_list.set_item_custom_fg_color(i, EdTheme.AMBER)
		if str(row.get("type", "")) == type_code:
			pick = i
	if _type_list.item_count > 0:
		_type_list.select(mini(pick, _type_list.item_count - 1))


func _on_type(index: int) -> void:
	type_code = str(_type_list.get_item_metadata(index))
	selected_id = -1
	if tool == "resources":
		_show_tool("resources")


# --- tools --------------------------------------------------------------------

func _show_tool(which: String, _rebuild := true) -> void:
	tool = which
	_pull()
	for c in _tool_host.get_children():
		c.queue_free()
	if ed == null:
		_tool_host.add_child(EdTheme.label("NovaEditor is missing from the Godot bridge.", 14, EdTheme.BAD))
		return
	match which:
		"changes": _tool_changes()
		"resources": _tool_resources()
		"galaxy": _tool_galaxy()
		"system": _tool_system()
		"story": _tool_story()
		"lint": _tool_lint()
		"project": _tool_project()
		"bundle": _tool_bundle()


func _scroll(parent: Node) -> ScrollContainer:
	var s := ScrollContainer.new()
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_EXPAND_FILL
	s.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	parent.add_child(s)
	return s


func _tool_changes() -> void:
	var rows = JSON.parse_string(ed.changes())
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sc := _scroll(_tool_host)
	sc.add_child(box)
	if not rows is Array or rows.is_empty():
		box.add_child(EdTheme.label("No changes yet. Pick a type and create or edit a resource.", 13, EdTheme.SECONDARY))
		return
	for row in rows:
		var b := Button.new()
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text = "%s #%d  %s    %s" % [row.get("typeName", ""), int(row.get("id", 0)), row.get("name", ""), row.get("summary", "")]
		b.add_theme_color_override("font_color", EdTheme.NEW_C if str(row.get("prov", "")) == "new" else EdTheme.AMBER)
		var ty := str(row.get("type", ""))
		var id := int(row.get("id", -1))
		b.pressed.connect(func():
			type_code = ty
			selected_id = id
			_fill_types()
			_show_tool("resources"))
		box.add_child(b)


func _tool_resources() -> void:
	var split := HSplitContainer.new()
	split.set_anchors_preset(Control.PRESET_FULL_RECT)
	split.anchor_right = 1
	split.anchor_bottom = 1
	_tool_host.add_child(split)
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(280, 0)
	left.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(left)
	var search := EdTheme.field("Filter resources")
	left.add_child(search)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 6)
	left.add_child(actions)
	actions.add_child(EdTheme.button("New", _create_current))
	actions.add_child(EdTheme.button("Duplicate", _duplicate_current))
	actions.add_child(EdTheme.button("Revert", _revert_current))
	var list := ItemList.new()
	list.size_flags_vertical = Control.SIZE_EXPAND_FILL
	left.add_child(list)
	var right := Control.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	split.add_child(right)

	var fill := func():
		list.clear()
		if type_code == "":
			return
		var parsed = JSON.parse_string(ed.browse(type_code, search.text))
		if not parsed is Array:
			return
		var pick := -1
		for row in parsed:
			var id := int(row.get("id", 0))
			var i := list.add_item("#%d  %s" % [id, row.get("name", "")])
			list.set_item_metadata(i, id)
			var prov := str(row.get("prov", ""))
			if prov == "new":
				list.set_item_custom_fg_color(i, EdTheme.NEW_C)
			elif prov == "override":
				list.set_item_custom_fg_color(i, EdTheme.AMBER)
			if id == selected_id:
				pick = i
		if pick >= 0:
			list.select(pick)
		elif list.item_count > 0 and selected_id < 0:
			list.select(0)
			selected_id = int(list.get_item_metadata(0))
		_fill_inspector(right)
	search.text_changed.connect(func(_t): fill.call())
	list.item_selected.connect(func(i):
		selected_id = int(list.get_item_metadata(i))
		_fill_inspector(right))
	fill.call()


func _fill_inspector(host: Control) -> void:
	for c in host.get_children():
		c.queue_free()
	if type_code == "" or selected_id < 0:
		host.add_child(EdTheme.label("Select a resource.", 13, EdTheme.SECONDARY))
		return
	var info = JSON.parse_string(ed.inspect(type_code, selected_id))
	if not info is Dictionary or info.is_empty():
		host.add_child(EdTheme.label("That resource isn't in the merged game.", 13, EdTheme.SECONDARY))
		return
	var sc := _scroll(host)
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_theme_constant_override("separation", 8)
	sc.add_child(box)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 8)
	box.add_child(head)
	var name := EdTheme.field("Name")
	name.text = str(info.get("name", ""))
	name.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name.text_submitted.connect(func(t):
		ed.rename(type_code, selected_id, t)
		_pull()
		_load_types())
	head.add_child(name)
	var prov := str(info.get("prov", ""))
	var badge := EdTheme.label("%s  #%d  %s" % [info.get("typeName", ""), int(info.get("id", 0)), prov], 12, EdTheme.AMBER if prov == "override" else EdTheme.SECONDARY)
	head.add_child(badge)
	if str(info.get("diffSummary", "")) != "":
		box.add_child(EdTheme.label(str(info.get("diffSummary", "")), 12, EdTheme.SECONDARY))
	var kind := str(info.get("kind", "form"))
	if kind == "form":
		_form(box, info)
		box.add_child(EdTheme.button("Show references", _show_refs.bind(box)))
	elif kind == "text":
		_text_editor(box, info)
	elif kind == "graphic":
		_graphic(box, info)
	elif kind == "sound":
		_sound(box, info)
	else:
		_hex_editor(box, info)
	if kind == "form" and bool(info.get("hexEditable", false)):
		box.add_child(EdTheme.label("BYTES", 10, EdTheme.TERTIARY))
		_hex_editor(box, info)


func _form(box: VBoxContainer, info: Dictionary) -> void:
	var fields: Array = info.get("fields", [])
	var values: Dictionary = info.get("values", {})
	var names: Dictionary = info.get("refNames", {})
	var group := ""
	_filling = true
	for f in fields:
		if str(f.get("group", "")) != group:
			group = str(f.get("group", ""))
			box.add_child(EdTheme.label(group.to_upper(), 10, EdTheme.TERTIARY))
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 8)
		box.add_child(row)
		var lab := EdTheme.label(str(f.get("label", f.get("key", ""))), 12, EdTheme.SECONDARY)
		lab.custom_minimum_size = Vector2(180, 0)
		lab.tooltip_text = str(f.get("help", ""))
		row.add_child(lab)
		var key := str(f.get("key", ""))
		var value = values.get(key, {})
		var kind := str(f.get("kind", "int"))
		var count := int(f.get("count", 1))
		if count > 1 and value is Dictionary and str(value.get("t", "")) == "array":
			_array_editor(row, f, value)
		elif kind == "flags":
			_flags(box, f, value)
		elif kind == "enum":
			_enum_menu(row, f, value)
		elif kind == "ref":
			_ref_editor(row, f, value, str(names.get(key, "")))
		elif kind == "color":
			_color_editor(row, f, value)
		elif kind in ["cstring", "pstring", "ncb", "str"]:
			var e := EdTheme.field("")
			e.text = str(value.get("v", "")) if value is Dictionary else ""
			e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			e.text_submitted.connect(func(t, k = key): _set_field(k, {"t": "str", "v": t}))
			row.add_child(e)
		elif kind == "point" and value is Dictionary:
			row.add_child(_coord_spin("x", int(value.get("x", 0)), key, value))
			row.add_child(_coord_spin("y", int(value.get("y", 0)), key, value))
		elif kind == "rect" and value is Dictionary:
			for part in ["top", "left", "bottom", "right"]:
				row.add_child(_rect_spin(part, int(value.get(part, 0)), key, value))
		elif kind == "mask64":
			var e := EdTheme.field("0x")
			e.text = str(value.get("v", "0x0")) if value is Dictionary else "0x0"
			e.text_submitted.connect(func(t, k = key): _set_field(k, {"t": "u64", "v": t}))
			row.add_child(e)
		elif kind == "blob":
			row.add_child(EdTheme.label(str(value.get("hex", "")) if value is Dictionary else "", 11, EdTheme.TERTIARY))
		else:
			var n := int(value.get("v", 0)) if value is Dictionary else 0
			var s := EdTheme.spin(n, int(f.get("min", -32768)), int(f.get("max", 32767)))
			s.value_changed.connect(func(v, k = key):
				if _filling:
					return
				_set_field(k, {"t": "int", "v": int(v)}))
			row.add_child(s)
	_filling = false


func _coord_spin(axis: String, n: int, key: String, value: Dictionary) -> SpinBox:
	var s := EdTheme.spin(n)
	s.value_changed.connect(func(v):
		if _filling:
			return
		value[axis] = int(v)
		value["t"] = "point"
		_set_field(key, value))
	return s


func _rect_spin(part: String, n: int, key: String, value: Dictionary) -> SpinBox:
	var s := EdTheme.spin(n)
	s.prefix = part.substr(0, 1)
	s.value_changed.connect(func(v):
		if _filling:
			return
		value[part] = int(v)
		value["t"] = "rect"
		_set_field(key, value))
	return s


func _array_editor(row: HBoxContainer, f: Dictionary, value: Dictionary) -> void:
	var items: Array = value.get("v", [])
	var wrap := HBoxContainer.new()
	wrap.add_theme_constant_override("separation", 4)
	wrap.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(wrap)
	var shown := mini(items.size(), 16)
	for i in shown:
		var cell = items[i]
		var n := int(cell.get("v", -1)) if cell is Dictionary else -1
		var s := EdTheme.spin(n)
		s.custom_minimum_size = Vector2(72, 0)
		s.tooltip_text = "#%d" % (i + 1)
		s.value_changed.connect(func(v, idx = i):
			if _filling:
				return
			ed.set_field_element(type_code, selected_id, str(f.get("key", "")), idx, JSON.stringify({"t": "int", "v": int(v)}))
			_pull())
		wrap.add_child(s)
	if items.size() > shown:
		wrap.add_child(EdTheme.label("+%d" % (items.size() - shown), 11, EdTheme.TERTIARY))


func _flags(box: VBoxContainer, f: Dictionary, value: Dictionary) -> void:
	var bits := int(value.get("v", 0)) if value is Dictionary else 0
	var grid := GridContainer.new()
	grid.columns = 2
	box.add_child(grid)
	for flag in f.get("flags", []):
		var c := CheckBox.new()
		c.text = str(flag.get("label", ""))
		c.button_pressed = (bits & int(flag.get("mask", 0))) != 0
		c.add_theme_color_override("font_color", EdTheme.TEXT)
		c.toggled.connect(func(on, mask = int(flag.get("mask", 0)), key = str(f.get("key", ""))):
			if _filling:
				return
			var cur := bits
			cur = (cur | mask) if on else (cur & ~mask)
			_set_field(key, {"t": "int", "v": cur}))
		grid.add_child(c)


func _enum_menu(row: HBoxContainer, f: Dictionary, value: Dictionary) -> void:
	var n := int(value.get("v", 0)) if value is Dictionary else 0
	var menu := OptionButton.new()
	menu.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var options: Array = f.get("options", [])
	var found := false
	for opt in options:
		var start := int(opt.get("start", 0))
		menu.add_item("%s (%d)" % [opt.get("label", ""), start])
		menu.set_item_metadata(menu.item_count - 1, start)
		if start == n:
			menu.select(menu.item_count - 1)
			found = true
	if not found:
		menu.add_item("Custom (%d)" % n)
		menu.set_item_metadata(menu.item_count - 1, n)
		menu.select(menu.item_count - 1)
	menu.item_selected.connect(func(i, key = str(f.get("key", ""))):
		if _filling:
			return
		_set_field(key, {"t": "int", "v": int(menu.get_item_metadata(i))}))
	row.add_child(menu)


func _ref_editor(row: HBoxContainer, f: Dictionary, value: Dictionary, ref_name: String) -> void:
	var n := int(value.get("v", -1)) if value is Dictionary else -1
	var s := EdTheme.spin(n)
	s.value_changed.connect(func(v, key = str(f.get("key", ""))):
		if _filling:
			return
		_set_field(key, {"t": "int", "v": int(v)}))
	row.add_child(s)
	var shown := ref_name if ref_name != "" else "—"
	row.add_child(EdTheme.label(shown, 12, EdTheme.SECONDARY))
	var target := str(f.get("ref", ""))
	if target != "":
		row.add_child(EdTheme.button("Jump", func():
			var base := int(f.get("refBase", 0))
			type_code = target
			selected_id = n + base if base != 0 else n
			_fill_types()
			_show_tool("resources")))


func _color_editor(row: HBoxContainer, f: Dictionary, value: Dictionary) -> void:
	var picker := ColorPickerButton.new()
	var r := float(value.get("r", 0)) / 255.0 if value is Dictionary else 0.0
	var g := float(value.get("g", 0)) / 255.0 if value is Dictionary else 0.0
	var b := float(value.get("b", 0)) / 255.0 if value is Dictionary else 0.0
	picker.color = Color(r, g, b)
	picker.custom_minimum_size = Vector2(48, 22)
	picker.color_changed.connect(func(c, key = str(f.get("key", ""))):
		if _filling:
			return
		_set_field(key, {"t": "color", "r": int(c.r * 255), "g": int(c.g * 255), "b": int(c.b * 255)}))
	row.add_child(picker)


func _set_field(key: String, value: Dictionary) -> void:
	ed.set_field(type_code, selected_id, key, JSON.stringify(value))
	_pull()
	_load_types()


func _text_editor(box: VBoxContainer, info: Dictionary) -> void:
	var text: Dictionary = info.get("text", {})
	var mode := str(text.get("mode", "plain"))
	if mode == "list":
		var edit := TextEdit.new()
		edit.custom_minimum_size = Vector2(0, 280)
		edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		var lines: PackedStringArray = PackedStringArray()
		for s in text.get("strings", []):
			lines.append(str(s).replace("\n", "\\n"))
		edit.text = "\n".join(lines)
		box.add_child(edit)
		box.add_child(EdTheme.label("One string per line. A real line break inside a string is \\n.", 11, EdTheme.TERTIARY))
		box.add_child(EdTheme.button("Apply text", func():
			var out: Array = []
			for line in edit.text.split("\n"):
				out.append(line.replace("\\n", "\n"))
			ed.set_text(type_code, selected_id, JSON.stringify({"strings": out}))
			_pull()))
		return
	var edit := TextEdit.new()
	edit.custom_minimum_size = Vector2(0, 240)
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.text = str(text.get("text", ""))
	box.add_child(edit)
	if mode == "desc":
		var pict := EdTheme.spin(int(text.get("picture", 0)), -1, 32767)
		var movie := EdTheme.field("Movie file")
		movie.text = str(text.get("movie", ""))
		box.add_child(pict)
		box.add_child(movie)
		var flags := int(text.get("flags", 0))
		var after := CheckBox.new()
		after.text = "Show movie after text"
		after.button_pressed = (flags & 1) != 0
		var big := CheckBox.new()
		big.text = "Double size"
		big.button_pressed = (flags & 2) != 0
		var cine := CheckBox.new()
		cine.text = "Cinematic"
		cine.button_pressed = (flags & 4) != 0
		box.add_child(after)
		box.add_child(big)
		box.add_child(cine)
		box.add_child(EdTheme.button("Apply description", func():
			var f := 0
			if after.button_pressed:
				f |= 1
			if big.button_pressed:
				f |= 2
			if cine.button_pressed:
				f |= 4
			ed.set_text(type_code, selected_id, JSON.stringify({
				"text": edit.text, "picture": int(pict.value), "movie": movie.text, "flags": f}))
			_pull()))
	else:
		box.add_child(EdTheme.button("Apply text", func():
			ed.set_text(type_code, selected_id, JSON.stringify({"text": edit.text}))
			_pull()))


func _graphic(box: VBoxContainer, info: Dictionary) -> void:
	var meta = JSON.parse_string(ed.graphic_info(type_code, selected_id))
	if not meta is Dictionary:
		meta = {}
	var rect := TextureRect.new()
	rect.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	rect.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	rect.custom_minimum_size = Vector2(0, 220)
	box.add_child(rect)
	var frame := 0
	var frames := int(meta.get("frames", 1))
	var apply := func():
		var bytes: PackedByteArray = ed.graphic_frame(type_code, selected_id, frame)
		if bytes.is_empty():
			return
		var image := Image.new()
		if bool(meta.get("png", false)):
			image.load_png_from_buffer(bytes)
		else:
			image.set_data(int(meta.get("w", 1)), int(meta.get("h", 1)), false, Image.FORMAT_RGBA8, bytes)
		rect.texture = ImageTexture.create_from_image(image)
	apply.call()
	if frames > 1:
		var slider := HSlider.new()
		slider.min_value = 0
		slider.max_value = frames - 1
		slider.step = 1
		slider.value_changed.connect(func(v):
			frame = int(v)
			apply.call())
		box.add_child(slider)
		box.add_child(EdTheme.label("%d frames" % frames, 11, EdTheme.TERTIARY))
	elif str(meta.get("error", "")) != "":
		box.add_child(EdTheme.label(str(meta.get("error", "")), 12, EdTheme.BAD))


func _sound(box: VBoxContainer, info: Dictionary) -> void:
	var meta = JSON.parse_string(ed.sound_info(type_code, selected_id))
	if not meta is Dictionary:
		return
	if str(meta.get("error", "")) != "":
		box.add_child(EdTheme.label(str(meta.get("error", "")), 12, EdTheme.BAD))
		return
	box.add_child(EdTheme.label("%.2f s   ·   %d Hz   ·   %d frames" % [float(meta.get("seconds", 0)), int(meta.get("rate", 0)), int(meta.get("frames", 0))], 13))
	var player := AudioStreamPlayer.new()
	box.add_child(player)
	box.add_child(EdTheme.button("Play", func():
		var pcm: PackedByteArray = ed.sound_pcm(type_code, selected_id)
		if pcm.is_empty():
			return
		var wav := AudioStreamWAV.new()
		wav.format = AudioStreamWAV.FORMAT_16_BITS
		wav.mix_rate = int(meta.get("rate", 22050))
		wav.stereo = false
		wav.data = pcm
		player.stream = wav
		player.play()))


func _hex_editor(box: VBoxContainer, info: Dictionary) -> void:
	var edit := TextEdit.new()
	edit.custom_minimum_size = Vector2(0, 120)
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.text = str(info.get("hex", ""))
	edit.editable = bool(info.get("hexEditable", false))
	var font := SystemFont.new()
	font.font_names = PackedStringArray(["Menlo", "Consolas", "monospace"])
	edit.add_theme_font_override("font", font)
	box.add_child(edit)
	if bool(info.get("hexEditable", false)):
		box.add_child(EdTheme.button("Apply hex", func():
			ed.set_hex(type_code, selected_id, edit.text)
			_pull()
			_show_tool("resources")))
	else:
		box.add_child(EdTheme.label("%d bytes — too large to edit as hex here." % int(info.get("bytes", 0)), 11, EdTheme.TERTIARY))


func _show_refs(box: VBoxContainer) -> void:
	var parsed = JSON.parse_string(ed.references(type_code, selected_id))
	if not parsed is Dictionary:
		return
	for heading in [["Uses", "uses"], ["Used by", "usedBy"]]:
		box.add_child(EdTheme.label(heading[0].to_upper(), 10, EdTheme.TERTIARY))
		var rows: Array = parsed.get(heading[1], [])
		if rows.is_empty():
			box.add_child(EdTheme.label("None", 12, EdTheme.TERTIARY))
		for row in rows:
			var b := EdTheme.button("%s #%d  %s  ·  %s" % [row.get("type", ""), int(row.get("id", 0)), row.get("name", ""), row.get("field", "")], func():
				type_code = str(row.get("type", ""))
				selected_id = int(row.get("id", -1))
				_fill_types()
				_show_tool("resources"))
			b.alignment = HORIZONTAL_ALIGNMENT_LEFT
			box.add_child(b)


func _tool_galaxy() -> void:
	var parsed = JSON.parse_string(ed.galaxy())
	var map := GalaxyMap.new()
	map.set_anchors_preset(Control.PRESET_FULL_RECT)
	map.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map.data = parsed if parsed is Dictionary else {}
	map.moved.connect(func(id, x, y):
		ed.galaxy_move(id, x, y)
		_pull())
	map.linked.connect(func(a, b, on):
		ed.galaxy_link(a, b, on)
		_pull()
		_show_tool("galaxy"))
	map.picked.connect(func(id):
		_system_id = id
		type_code = _type_named("System")
		selected_id = id
		_show_tool("system"))
	_tool_host.add_child(map)
	map.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _tool_system() -> void:
	if _system_id < 0:
		_system_id = selected_id if _is_syst(type_code) else _first_system()
	var info = JSON.parse_string(ed.system_info(_system_id))
	var split := HSplitContainer.new()
	split.set_anchors_preset(Control.PRESET_FULL_RECT)
	_tool_host.add_child(split)
	var left := VBoxContainer.new()
	left.custom_minimum_size = Vector2(280, 0)
	split.add_child(left)
	if not info is Dictionary or info.is_empty():
		left.add_child(EdTheme.label("No system selected. Open the galaxy map and click one.", 13, EdTheme.SECONDARY))
		return
	left.add_child(EdTheme.label("%s  #%d" % [info.get("name", ""), int(info.get("id", 0))], 16))
	left.add_child(EdTheme.label(str(info.get("govtName", "")), 12, EdTheme.SECONDARY))
	left.add_child(EdTheme.label("LINKS", 10, EdTheme.TERTIARY))
	for link in info.get("links", []):
		var id := int(link.get("id", 0))
		var b := EdTheme.button("#%d  %s" % [id, link.get("name", "")], func():
			_system_id = id
			_show_tool("system"))
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		left.add_child(b)
		left.add_child(EdTheme.button("Unlink", func():
			ed.galaxy_link(_system_id, id, false)
			_show_tool("system")))
	left.add_child(EdTheme.label("STELLARS", 10, EdTheme.TERTIARY))
	for sp in info.get("stellars", []):
		var sid := int(sp.get("id", 0))
		var row := HBoxContainer.new()
		left.add_child(row)
		var lab := EdTheme.label("#%d  %s   (%d, %d)" % [sid, sp.get("name", ""), int(sp.get("x", 0)), int(sp.get("y", 0))], 12)
		lab.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(lab)
		row.add_child(EdTheme.button("Remove", _remove_stellar.bind(sid)))
	var add := HBoxContainer.new()
	left.add_child(add)
	var spob_id := EdTheme.spin(-1, -1, 32767)
	spob_id.custom_minimum_size = Vector2(90, 0)
	add.add_child(spob_id)
	add.add_child(EdTheme.button("Add stellar", func():
		ed.system_add_stellar(_system_id, int(spob_id.value))
		_show_tool("system")))
	var map := SystemMap.new()
	map.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	map.size_flags_vertical = Control.SIZE_EXPAND_FILL
	map.info = info
	map.moved.connect(func(id, x, y):
		ed.stellar_move(id, x, y)
		_pull())
	split.add_child(map)


func _remove_stellar(sid: int) -> void:
	ed.system_remove_stellar(_system_id, sid)
	_show_tool("system")


func _tool_story() -> void:
	var parsed = JSON.parse_string(ed.story())
	var map := StoryMap.new()
	map.set_anchors_preset(Control.PRESET_FULL_RECT)
	map.data = parsed if parsed is Dictionary else {}
	map.picked.connect(func(ty, id):
		type_code = ty
		selected_id = id
		_fill_types()
		_show_tool("resources"))
	_tool_host.add_child(map)
	map.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)


func _tool_lint() -> void:
	var parsed = JSON.parse_string(ed.lint())
	var box := VBoxContainer.new()
	var sc := _scroll(_tool_host)
	sc.add_child(box)
	if not parsed is Dictionary:
		return
	var errors := int(parsed.get("errors", 0))
	var warnings := int(parsed.get("warnings", 0))
	_badge.text = "Validate" if errors + warnings == 0 else "%d issue%s" % [errors + warnings, "" if errors + warnings == 1 else "s"]
	box.add_child(EdTheme.label("%d errors, %d warnings" % [errors, warnings], 14, EdTheme.BAD if errors else EdTheme.AMBER if warnings else EdTheme.NEW_C))
	for row in parsed.get("issues", []):
		var sev := str(row.get("severity", ""))
		var color := EdTheme.BAD if sev == "error" else EdTheme.AMBER if sev == "warning" else EdTheme.SECONDARY
		var b := Button.new()
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.text = "%s  %s #%d  %s" % [sev, row.get("type", ""), int(row.get("id", 0)), row.get("message", "")]
		b.add_theme_color_override("font_color", color)
		b.pressed.connect(func():
			type_code = str(row.get("type", ""))
			selected_id = int(row.get("id", -1))
			_fill_types()
			_show_tool("resources"))
		box.add_child(b)


func _tool_project() -> void:
	var box := VBoxContainer.new()
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var sc := _scroll(_tool_host)
	var pad := MarginContainer.new()
	pad.add_theme_constant_override("margin_left", 16)
	pad.add_theme_constant_override("margin_top", 12)
	pad.add_theme_constant_override("margin_right", 16)
	pad.add_child(box)
	sc.add_child(pad)
	var name := EdTheme.field("Name")
	name.text = str(_st.get("name", ""))
	var author := EdTheme.field("Author")
	author.text = str(_st.get("author", ""))
	var version := EdTheme.field("Version")
	version.text = str(_st.get("version", ""))
	var notes := TextEdit.new()
	notes.custom_minimum_size = Vector2(0, 120)
	notes.placeholder_text = "Notes"
	notes.text = str(_st.get("notes", ""))
	for w in [name, author, version, notes]:
		w.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		box.add_child(w)
	box.add_child(EdTheme.button("Apply project info", func():
		ed.set_plugin_info(name.text, author.text, version.text, notes.text)
		_pull()))
	box.add_child(EdTheme.label("EXPORT", 10, EdTheme.TERTIARY))
	box.add_child(EdTheme.button("Export copy…", func(): _save_dialog(true)))
	box.add_child(EdTheme.button("Install into Plug-ins", func():
		ed.install()
		_pull()
		_status.text = "Installed a copy into the user Plug-ins folder. Reload the game data to play it."))
	var conflicts = JSON.parse_string(ed.conflicts())
	box.add_child(EdTheme.label("CONFLICTS", 10, EdTheme.TERTIARY))
	if conflicts is Array and not conflicts.is_empty():
		for row in conflicts:
			box.add_child(EdTheme.label("%s #%d overlaps %s" % [row.get("type", ""), int(row.get("id", 0)), row.get("plugin", "")], 12, EdTheme.AMBER))
	else:
		box.add_child(EdTheme.label("No other enabled plug-in owns a record this one replaces.", 12, EdTheme.SECONDARY))


func _tool_bundle() -> void:
	var parsed = JSON.parse_string(ed.bundle())
	var box := VBoxContainer.new()
	var sc := _scroll(_tool_host)
	sc.add_child(box)
	if not parsed is Dictionary:
		return
	box.add_child(EdTheme.label("Format %s" % str(parsed.get("format", "rez")), 13))
	box.add_child(EdTheme.label(str(parsed.get("path", "Not saved yet")), 12, EdTheme.SECONDARY))
	for f in parsed.get("files", []):
		var tag := "pack" if bool(f.get("pack", false)) else "data"
		box.add_child(EdTheme.label("%s    %s" % [tag, f.get("name", "")], 12))
	if (parsed.get("files", []) as Array).is_empty():
		box.add_child(EdTheme.label("A new plug-in is one file until you Save As.", 12, EdTheme.SECONDARY))


# --- commands -----------------------------------------------------------------

func _create_current() -> void:
	if type_code == "" or ed == null:
		return
	var parsed = JSON.parse_string(ed.create(type_code, "New"))
	if parsed is Dictionary and bool(parsed.get("ok", false)):
		selected_id = int(parsed.get("id", -1))
		_load_types()
		_show_tool("resources")
	else:
		_pull()


func _duplicate_current() -> void:
	if selected_id < 0:
		return
	var parsed = JSON.parse_string(ed.duplicate(type_code, selected_id))
	if parsed is Dictionary and bool(parsed.get("ok", false)):
		selected_id = int(parsed.get("id", -1))
		_load_types()
		_show_tool("resources")
	else:
		_pull()


func _revert_current() -> void:
	if selected_id < 0:
		return
	ed.revert(type_code, selected_id)
	_load_types()
	_show_tool("resources")


func _do_undo() -> void:
	ed.undo()
	_load_types()
	_show_tool(tool)


func _do_redo() -> void:
	ed.redo()
	_load_types()
	_show_tool(tool)


func _test_run() -> void:
	var system := _system_id
	if system < 0 and _is_syst(type_code):
		system = selected_id
	var ship := selected_id if _type_named("Ship") == type_code else -1
	if not ed.begin_test(nova, data_dir, system, ship):
		_status.text = "A test run or training flight is already going."
		return
	test_requested.emit()


func _request_close() -> void:
	_pull()
	if bool(_st.get("dirty", false)):
		_dirty_dialog.dialog_text = "You have unsaved changes in \"%s\"." % str(_st.get("name", "this plug-in"))
		_dirty_dialog.popup_centered()
		return
	_finish_close()


func _discard_and_close() -> void:
	_finish_close()


func _finish_close() -> void:
	closed.emit()


func _save(as_new: bool) -> void:
	_pull()
	if not as_new and str(_st.get("path", "")) != "":
		ed.save()
		_remember(str(_st.get("path", "")), str(_st.get("name", "")))
		_pull()
		return
	if not as_new and str(_st.get("folder", "")) != "":
		ed.save()
		_pull()
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
	fd.title = "Export copy" if export_copy else "Save Plug-in"
	fd.file_selected.connect(func(p):
		if export_copy:
			ed.export_copy(p)
		else:
			ed.save_as(p, false)
			_remember(p, str(_st.get("name", "")))
		_pull()
		fd.queue_free())
	fd.canceled.connect(fd.queue_free)
	add_child(fd)
	fd.popup_centered()


func _open_file_menu() -> void:
	_file_menu.clear()
	_file_menu.add_item("New", 0)
	_file_menu.add_item("Open…", 1)
	_file_menu.add_item("Open Folder…", 2)
	_file_menu.add_item("Open Installed…", 3)
	_file_menu.add_separator()
	var recents := _recents()
	if recents.is_empty():
		_file_menu.add_item("No Recent Plug-ins", 9)
		_file_menu.set_item_disabled(_file_menu.item_count - 1, true)
	else:
		var i := 0
		for row in recents:
			_file_menu.add_item(str(row.get("name", row.get("path", ""))), 20 + i)
			i += 1
	_file_menu.add_separator()
	_file_menu.add_item("Save", 100)
	_file_menu.add_item("Save As…", 101)
	_file_menu.add_item("Export Copy…", 102)
	_file_menu.add_item("Install into Plug-ins", 103)
	if _file_btn != null:
		var origin := _file_btn.global_position + Vector2(0, _file_btn.size.y)
		_file_menu.position = Vector2i(origin)
	_file_menu.popup()


func _on_file(id: int) -> void:
	match id:
		0:
			ed.new_document()
			selected_id = -1
			_load_types()
			_show_tool("changes")
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
		_:
			if id >= 20:
				var rows := _recents()
				var idx := id - 20
				if idx < rows.size():
					_open_any(str(rows[idx].get("path", "")))


func _pick_open(folder: bool) -> void:
	var fd := FileDialog.new()
	fd.file_mode = FileDialog.FILE_MODE_OPEN_DIR if folder else FileDialog.FILE_MODE_OPEN_FILE
	fd.access = FileDialog.ACCESS_FILESYSTEM
	fd.use_native_dialog = PilotFiles.want_native()
	fd.current_dir = data_dir
	fd.title = "Open Plug-in"
	if not folder:
		fd.filters = PackedStringArray(["*.rez, *.ndat ; Plug-in data"])
	var chosen := func(p):
		_open_any(p)
		fd.queue_free()
	if folder:
		fd.dir_selected.connect(chosen)
	else:
		fd.file_selected.connect(chosen)
	fd.canceled.connect(fd.queue_free)
	add_child(fd)
	fd.popup_centered()


func _open_any(path: String) -> void:
	if path == "":
		return
	ed.open_path(path)
	_remember(path, path.get_file())
	selected_id = -1
	_load_types()
	_show_tool("changes")


func _popup_installed() -> void:
	_installed_menu.clear()
	var rows = JSON.parse_string(ed.installed())
	if not rows is Array or rows.is_empty():
		_installed_menu.add_item("No installed plug-ins", 0)
		_installed_menu.set_item_disabled(0, true)
	else:
		var i := 0
		for row in rows:
			_installed_menu.add_item(str(row.get("name", row.get("id", ""))), i)
			_installed_menu.set_item_metadata(i, str(row.get("id", "")))
			i += 1
	_installed_menu.position = Vector2i(80, 120)
	_installed_menu.popup()


func _on_installed(index: int) -> void:
	var id := str(_installed_menu.get_item_metadata(index))
	if id == "":
		return
	ed.open_installed(id)
	selected_id = -1
	_load_types()
	_show_tool("changes")


func _recents() -> Array:
	if not FileAccess.file_exists(RECENTS_PATH):
		return []
	var parsed = JSON.parse_string(FileAccess.get_file_as_string(RECENTS_PATH))
	return parsed if parsed is Array else []


func _remember(path: String, name: String) -> void:
	if path == "":
		return
	var rows: Array = []
	for row in _recents():
		if str(row.get("path", "")) != path:
			rows.append(row)
	rows.push_front({"path": path, "name": name if name != "" else path.get_file()})
	while rows.size() > 8:
		rows.pop_back()
	var f := FileAccess.open(RECENTS_PATH, FileAccess.WRITE)
	if f:
		f.store_string(JSON.stringify(rows))


func _type_named(fragment: String) -> String:
	for row in _types:
		if str(row.get("name", "")) == fragment or str(row.get("name", "")).contains(fragment):
			return str(row.get("type", ""))
	return ""


func _is_syst(ty: String) -> bool:
	return ty != "" and ty == _type_named("System")


func _first_system() -> int:
	var parsed = JSON.parse_string(ed.galaxy())
	if parsed is Dictionary:
		var systems: Array = parsed.get("systems", [])
		if not systems.is_empty():
			return int(systems[0].get("id", -1))
	return -1


func _unhandled_input(event: InputEvent) -> void:
	if not visible or ed == null or not event is InputEventKey or not event.pressed or event.echo:
		return
	var key := event as InputEventKey
	if key.keycode == KEY_ESCAPE:
		get_viewport().set_input_as_handled()
		_request_close()
		return
	if not key.ctrl_pressed and not key.meta_pressed:
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
		KEY_N:
			get_viewport().set_input_as_handled()
			if tool == "resources":
				_create_current()
		KEY_D:
			get_viewport().set_input_as_handled()
			_duplicate_current()
		KEY_F:
			get_viewport().set_input_as_handled()
			_type_search.grab_focus()
		KEY_R:
			get_viewport().set_input_as_handled()
			_test_run()
		KEY_O:
			get_viewport().set_input_as_handled()
			_pick_open(false)


# --- map canvases -------------------------------------------------------------

class GalaxyMap extends Control:
	signal moved(id: int, x: int, y: int)
	signal linked(a: int, b: int, on: bool)
	signal picked(id: int)
	var data := {}
	var _drag := -1
	var _drag_at := Vector2.ZERO
	var _link_from := -1

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

	func _gui_input(event: InputEvent) -> void:
		var systems: Array = data.get("systems", [])
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			var hit := _hit(event.position, systems)
			if event.pressed:
				if event.shift_pressed and hit >= 0 and _link_from >= 0:
					var other := int(systems[_link_from].get("id", -1))
					var id := int(systems[hit].get("id", -1))
					linked.emit(other, id, true)
					_link_from = -1
				elif hit >= 0:
					_drag = hit
					_drag_at = event.position
					_link_from = hit
				else:
					_link_from = -1
			elif _drag >= 0:
				var s: Dictionary = systems[_drag]
				var p := _from_screen(event.position)
				moved.emit(int(s.get("id", 0)), int(p.x), int(p.y))
				s["x"] = int(p.x)
				s["y"] = int(p.y)
				_drag = -1
				queue_redraw()
		elif event is InputEventMouseMotion and _drag >= 0 and event.button_mask & MOUSE_BUTTON_MASK_LEFT:
			var s: Dictionary = systems[_drag]
			var p := _from_screen(event.position)
			s["x"] = int(p.x)
			s["y"] = int(p.y)
			queue_redraw()
		elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_RIGHT:
			var hit := _hit(event.position, systems)
			if hit >= 0:
				picked.emit(int(systems[hit].get("id", -1)))

	func _draw() -> void:
		var systems: Array = data.get("systems", [])
		var bounds := _bounds(systems)
		for neb in data.get("nebulae", []):
			var a := _to_screen(float(neb.get("x", 0)), float(neb.get("y", 0)), bounds)
			var b := _to_screen(float(neb.get("x", 0)) + float(neb.get("w", 0)), float(neb.get("y", 0)) + float(neb.get("h", 0)), bounds)
			draw_rect(Rect2(a, b - a), Color(0.45, 0.35, 0.7, 0.18), true)
		var by_id := {}
		for s in systems:
			by_id[int(s.get("id", 0))] = s
		for s in systems:
			var p := _to_screen(float(s.get("x", 0)), float(s.get("y", 0)), bounds)
			for lid in s.get("links", []):
				if int(lid) <= int(s.get("id", 0)):
					continue
				if not by_id.has(int(lid)):
					continue
				var o: Dictionary = by_id[int(lid)]
				var q := _to_screen(float(o.get("x", 0)), float(o.get("y", 0)), bounds)
				draw_line(p, q, Color(1, 1, 1, 0.18), 1.0)
		for s in systems:
			var p := _to_screen(float(s.get("x", 0)), float(s.get("y", 0)), bounds)
			var c := Color(float(s.get("r", 0.6)), float(s.get("g", 0.6)), float(s.get("b", 0.6)))
			var radius := 4.5 if str(s.get("prov", "")) == "base" else 6.5
			draw_circle(p, radius, c)
			if str(s.get("prov", "")) != "base":
				draw_arc(p, radius + 3, 0, TAU, 16, EdTheme.AMBER, 1.5)
		draw_string(ThemeDB.fallback_font, Vector2(12, 22), "Drag a system. Shift-click two systems to link them. Right-click opens the system.", HORIZONTAL_ALIGNMENT_LEFT, -1, 12, EdTheme.SECONDARY)

	func _bounds(systems: Array) -> Rect2:
		if systems.is_empty():
			return Rect2(-100, -100, 200, 200)
		var minx := 1e9
		var miny := 1e9
		var maxx := -1e9
		var maxy := -1e9
		for s in systems:
			minx = minf(minx, float(s.get("x", 0)))
			miny = minf(miny, float(s.get("y", 0)))
			maxx = maxf(maxx, float(s.get("x", 0)))
			maxy = maxf(maxy, float(s.get("y", 0)))
		return Rect2(minx, miny, maxf(1.0, maxx - minx), maxf(1.0, maxy - miny))

	func _to_screen(x: float, y: float, bounds: Rect2) -> Vector2:
		var area := size - Vector2(48, 48)
		var sx := 24 + (x - bounds.position.x) / bounds.size.x * area.x
		var sy := 24 + (y - bounds.position.y) / bounds.size.y * area.y
		return Vector2(sx, sy)

	func _from_screen(p: Vector2) -> Vector2:
		var bounds := _bounds(data.get("systems", []))
		var area := size - Vector2(48, 48)
		if area.x < 1 or area.y < 1:
			return Vector2.ZERO
		var x := bounds.position.x + (p.x - 24) / area.x * bounds.size.x
		var y := bounds.position.y + (p.y - 24) / area.y * bounds.size.y
		return Vector2(x, y)

	func _hit(p: Vector2, systems: Array) -> int:
		var bounds := _bounds(systems)
		var best := -1
		var best_d := 14.0
		for i in systems.size():
			var s: Dictionary = systems[i]
			var d := p.distance_to(_to_screen(float(s.get("x", 0)), float(s.get("y", 0)), bounds))
			if d < best_d:
				best = i
				best_d = d
		return best


class SystemMap extends Control:
	signal moved(id: int, x: int, y: int)
	var info := {}
	var _drag := -1

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

	func _gui_input(event: InputEvent) -> void:
		var stellars: Array = info.get("stellars", [])
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if event.pressed:
				_drag = _hit(event.position, stellars)
			elif _drag >= 0:
				var sp: Dictionary = stellars[_drag]
				var p := _from(event.position)
				moved.emit(int(sp.get("id", 0)), int(p.x), int(p.y))
				sp["x"] = int(p.x)
				sp["y"] = int(p.y)
				_drag = -1
				queue_redraw()
		elif event is InputEventMouseMotion and _drag >= 0:
			var sp: Dictionary = stellars[_drag]
			var p := _from(event.position)
			sp["x"] = int(p.x)
			sp["y"] = int(p.y)
			queue_redraw()

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), Color(int(info.get("r", 0)) / 255.0, int(info.get("g", 0)) / 255.0, int(info.get("b", 0)) / 255.0, 0.35), true)
		draw_circle(size * 0.5, 3, EdTheme.AMBER)
		for sp in info.get("stellars", []):
			var p := _to(float(sp.get("x", 0)), float(sp.get("y", 0)))
			draw_circle(p, 7, EdTheme.TEXT)
			draw_string(ThemeDB.fallback_font, p + Vector2(10, 4), str(sp.get("name", "")), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, EdTheme.TEXT)

	func _to(x: float, y: float) -> Vector2:
		return size * 0.5 + Vector2(x, y) * 0.35

	func _from(p: Vector2) -> Vector2:
		return (p - size * 0.5) / 0.35

	func _hit(p: Vector2, stellars: Array) -> int:
		var best := -1
		var best_d := 16.0
		for i in stellars.size():
			var sp: Dictionary = stellars[i]
			var d := p.distance_to(_to(float(sp.get("x", 0)), float(sp.get("y", 0))))
			if d < best_d:
				best = i
				best_d = d
		return best


class StoryMap extends Control:
	signal picked(type_code: String, id: int)
	var data := {}

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_STOP

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			var nodes: Array = data.get("nodes", [])
			var scale := _scale()
			for n in nodes:
				var p := Vector2(float(n.get("x", 0)), float(n.get("y", 0))) * scale + Vector2(16, 16)
				if p.distance_to(event.position) < 18:
					picked.emit(str(n.get("type", "")), int(n.get("res", -1)))
					return

	func _draw() -> void:
		var nodes: Array = data.get("nodes", [])
		var by := {}
		var scale := _scale()
		for n in nodes:
			by[int(n.get("id", -1))] = n
		for e in data.get("edges", []):
			if not by.has(int(e.get("from", -1))) or not by.has(int(e.get("to", -1))):
				continue
			var a: Dictionary = by[int(e.get("from", -1))]
			var b: Dictionary = by[int(e.get("to", -1))]
			var p := Vector2(float(a.get("x", 0)), float(a.get("y", 0))) * scale + Vector2(16, 16)
			var q := Vector2(float(b.get("x", 0)), float(b.get("y", 0))) * scale + Vector2(16, 16)
			var col := EdTheme.AMBER if str(e.get("kind", "")) == "starts" else Color(1, 1, 1, 0.2)
			draw_line(p, q, col, 1.0)
		for n in nodes:
			var p := Vector2(float(n.get("x", 0)), float(n.get("y", 0))) * scale + Vector2(16, 16)
			var c := EdTheme.AMBER if bool(n.get("touched", false)) else (Color(0.55, 0.7, 0.95) if bool(n.get("cron", false)) else EdTheme.TEXT)
			if bool(n.get("unreachable", false)):
				c = EdTheme.BAD
			draw_rect(Rect2(p - Vector2(6, 6), Vector2(12, 12)), c, true)
		draw_string(ThemeDB.fallback_font, Vector2(12, size.y - 16), "%d missions and crons  ·  click a node to edit it" % nodes.size(), HORIZONTAL_ALIGNMENT_LEFT, -1, 12, EdTheme.SECONDARY)

	func _scale() -> float:
		var w := float(data.get("width", 1))
		var h := float(data.get("height", 1))
		if w < 1:
			w = 1
		if h < 1:
			h = 1
		return minf((size.x - 32) / w, (size.y - 32) / h)
