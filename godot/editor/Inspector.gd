# Resource inspector for the Plugin Editor: header (name, chips, actions), diff against the base
# game, then the editor for the resource's kind — schema form (grouped cards, slot tables,
# resource pickers, flag grids), text, sprite / picture preview, sound, or raw bytes.
# Every edit goes straight to NovaEditor (one undo step each) and emits `edited`.
extends VBoxContainer

const EdTheme = preload("res://editor/EditorTheme.gd")
const T = preload("res://ui/novaswift/NovaTheme.gd")
const Previews = preload("res://editor/Previews.gd")

signal edited
signal navigate(type_code: String, id: int)
signal command(what: String)
signal message(text: String, bad: bool)

const LABEL_W := 180.0

var ed: Object
var type_code := ""
var res_id := -1
var info := {}
var scroller: ScrollContainer
var _values := {}
var _changed_keys := {}
var _sections := {}
var _picker: PopupPanel
var _picker_search: LineEdit
var _picker_list: ItemList
var _picker_type := ""
var _picker_cb: Callable
var _refs_box: VBoxContainer
var _anim_timer: Timer
var _player: AudioStreamPlayer
var _wave: Control
var _name_field: LineEdit


func _init() -> void:
	add_theme_constant_override("separation", 12)
	size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _process(_delta: float) -> void:
	if _player != null and is_instance_valid(_player) and _wave != null and is_instance_valid(_wave):
		if _player.playing and _player.stream != null:
			var length := _player.stream.get_length()
			_wave.set("progress", _player.get_playback_position() / maxf(0.001, length))
			_wave.queue_redraw()
		elif float(_wave.get("progress")) >= 0.0:
			_wave.set("progress", -1.0)
			_wave.queue_redraw()


func clear() -> void:
	for c in get_children():
		remove_child(c)
		c.queue_free()
	_sections.clear()
	_refs_box = null
	_player = null
	_wave = null
	_name_field = null
	if _anim_timer != null and is_instance_valid(_anim_timer):
		_anim_timer.queue_free()
	_anim_timer = null


func focus_name() -> void:
	if _name_field != null and is_instance_valid(_name_field):
		_name_field.grab_focus()
		_name_field.select_all()


func show_resource(editor: Object, ty: String, id: int) -> void:
	ed = editor
	type_code = ty
	res_id = id
	clear()
	var parsed: Variant = JSON.parse_string(ed.inspect(ty, id)) if ed != null else null
	info = parsed if parsed is Dictionary else {}
	if info.is_empty():
		add_child(EdTheme.empty_state("square.dashed", "Not in the merged game", "Resource #%d of this type doesn't exist in the base data or this plug-in." % id))
		return
	_values = info.get("values", {})
	_changed_keys.clear()
	for d in info.get("diff", []):
		_changed_keys[str(d.get("key", ""))] = true
	_header()
	var diff: Array = info.get("diff", [])
	if not diff.is_empty():
		_diff_card(diff)
	var kind := str(info.get("kind", "form"))
	if kind == "form" or kind == "text":
		_previews_card()
	match kind:
		"form":
			_form()
			_raw_card(true)
		"text":
			_text_editor()
		"graphic":
			_graphic()
		"sound":
			_sound()
		_:
			_raw_card(false)
	_references_card()


# --- header -------------------------------------------------------------------------------------

func _header() -> void:
	var card := EdTheme.card(16)
	add_child(card)
	var body := EdTheme.card_body(card)
	var top := EdTheme.hbox(14)
	body.add_child(top)
	var badge := PanelContainer.new()
	var prov := str(info.get("prov", "base"))
	var pc := EdTheme.prov_color(prov) if prov != "base" else EdTheme.AMBER
	badge.add_theme_stylebox_override("panel", T.box(Color(pc.r, pc.g, pc.b, 0.14), 10, Color(pc.r, pc.g, pc.b, 0.3), 1, Vector2(10, 10)))
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	badge.add_child(EdTheme.icon_rect(EdTheme.type_icon(type_code, str(info.get("kind", ""))), 24, pc))
	top.add_child(badge)

	var col := EdTheme.vbox(6)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	top.add_child(col)
	_name_field = LineEdit.new()
	_name_field.text = str(info.get("name", ""))
	_name_field.placeholder_text = "Untitled"
	_name_field.tooltip_text = "Resource name — press Return to rename"
	T.style_text(_name_field, "body", "semibold", EdTheme.TEXT, 20)
	_name_field.add_theme_stylebox_override("normal", T.box(Color(0, 0, 0, 0), 6, Color(0, 0, 0, 0), 0, Vector2(6, 2)))
	_name_field.add_theme_stylebox_override("focus", T.box(T.FIELD_BG, 6, EdTheme.AMBER, 1, Vector2(6, 2)))
	_name_field.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var commit_name := func(t: String) -> void:
		if t == str(info.get("name", "")):
			return
		ed.rename(type_code, res_id, t)
		info["name"] = t
		_after_edit("Renamed")
	_name_field.text_submitted.connect(func(t: String) -> void:
		commit_name.call(t)
		_name_field.release_focus())
	_name_field.focus_exited.connect(func() -> void: commit_name.call(_name_field.text))
	col.add_child(_name_field)
	var chips := EdTheme.hbox(6)
	chips.add_child(EdTheme.chip(str(info.get("typeName", type_code)), EdTheme.SECONDARY))
	chips.add_child(EdTheme.chip("#%d" % int(info.get("id", 0)), EdTheme.SECONDARY, "number"))
	var plabel := EdTheme.prov_label(prov)
	if prov == "plugin" and str(info.get("plugin", "")) != "":
		plabel = "From " + str(info.get("plugin", ""))
	chips.add_child(EdTheme.chip(plabel, EdTheme.prov_color(prov) if prov != "base" else EdTheme.TERTIARY))
	chips.add_child(EdTheme.chip("%d bytes" % int(info.get("bytes", 0)), EdTheme.TERTIARY))
	chips.add_child(EdTheme.spacer())
	col.add_child(chips)

	var actions := EdTheme.hbox(2)
	actions.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	top.add_child(actions)
	actions.add_child(EdTheme.icon_button("doc.on.doc", "Duplicate  (⌘D)", func() -> void: command.emit("duplicate")))
	actions.add_child(EdTheme.icon_button("number", "Change ID…", func() -> void: command.emit("renumber")))
	if prov == "override":
		actions.add_child(EdTheme.icon_button("arrow.counterclockwise", "Revert to the base game", func() -> void: command.emit("revert"), EdTheme.AMBER))
	if bool(info.get("inPlugin", false)) and prov == "new":
		actions.add_child(EdTheme.icon_button("trash", "Delete from this plug-in", func() -> void: command.emit("delete"), EdTheme.BAD))
	if prov == "base" or prov == "plugin":
		var hint := EdTheme.wrap_label("Editing this resource copies it into your plug-in as an override. The base game is never changed.", 12, EdTheme.TERTIARY)
		body.add_child(hint)


func _diff_card(diff: Array) -> void:
	var card := EdTheme.card(14, Color(EdTheme.AMBER.r, EdTheme.AMBER.g, EdTheme.AMBER.b, 0.06), Color(EdTheme.AMBER.r, EdTheme.AMBER.g, EdTheme.AMBER.b, 0.25))
	add_child(card)
	var body := EdTheme.card_body(card)
	var head := EdTheme.hbox(8)
	head.add_child(EdTheme.icon_rect("arrow.triangle.branch", 14, EdTheme.AMBER))
	head.add_child(EdTheme.label("%d change%s from the base game" % [diff.size(), "" if diff.size() == 1 else "s"], 13, EdTheme.AMBER, "semibold"))
	body.add_child(head)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 12)
	grid.add_theme_constant_override("v_separation", 4)
	body.add_child(grid)
	for d in diff.slice(0, 24):
		var l := EdTheme.label(str(d.get("label", d.get("key", ""))), 12, EdTheme.SECONDARY)
		l.custom_minimum_size.x = 180
		grid.add_child(l)
		var old := EdTheme.label(str(d.get("old", "")), 12, EdTheme.TERTIARY)
		old.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		old.custom_minimum_size.x = 80
		grid.add_child(old)
		grid.add_child(EdTheme.icon_rect("arrow.right", 12, EdTheme.TERTIARY))
		var nv := EdTheme.label(str(d.get("new", "")), 12, EdTheme.TEXT, "semibold")
		nv.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		nv.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(nv)
	if diff.size() > 24:
		body.add_child(EdTheme.label("+%d more" % (diff.size() - 24), 11, EdTheme.TERTIARY))


# --- form ---------------------------------------------------------------------------------------

func _form() -> void:
	var fields: Array = info.get("fields", [])
	var order: Array = info.get("groups", [])
	var by_group := {}
	for f in fields:
		var g := str(f.get("group", ""))
		if not by_group.has(g):
			by_group[g] = []
			if not order.has(g):
				order.append(g)
		(by_group[g] as Array).append(f)
	var groups: Array = []
	for g in order:
		if by_group.has(g):
			groups.append(g)
	# Jump bar
	if groups.size() > 3:
		var flow := HFlowContainer.new()
		flow.add_theme_constant_override("h_separation", 6)
		flow.add_theme_constant_override("v_separation", 6)
		add_child(flow)
		for g in groups:
			var n_changed := 0
			for f in by_group[g]:
				if _changed_keys.has(str(f.get("key", ""))):
					n_changed += 1
			var b := EdTheme.button(str(g) + ("  •" if n_changed > 0 else ""), _jump_to.bind(str(g)), "plain")
			if n_changed > 0:
				b.add_theme_color_override("font_color", EdTheme.AMBER)
				b.add_theme_color_override("font_hover_color", EdTheme.AMBER)
			flow.add_child(b)
	for g in groups:
		_group_card(str(g), by_group[g])


func _jump_to(group: String) -> void:
	if scroller == null or not _sections.has(group):
		return
	var target: Control = _sections[group]
	if target.has_meta("collapsed") and bool(target.get_meta("collapsed")):
		var toggle: Callable = target.get_meta("toggle")
		toggle.call()
	await get_tree().process_frame
	scroller.scroll_vertical = int(target.position.y + position.y - 8)


func _group_card(group: String, fields: Array) -> void:
	var card := EdTheme.card(14)
	add_child(card)
	_sections[group] = card
	var body := EdTheme.card_body(card)
	body.add_theme_constant_override("separation", 6)
	var collapsed := group == "Reserved"
	var head := EdTheme.button(group, Callable(), "ghost", "chevron.right" if collapsed else "chevron.down")
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	T.style_text(head, "caption", "semibold", EdTheme.SECONDARY, 12)
	head.add_theme_stylebox_override("normal", T.empty())
	head.add_theme_stylebox_override("hover", T.empty())
	head.add_theme_stylebox_override("pressed", T.empty())
	body.add_child(head)
	var content := EdTheme.vbox(6)
	content.visible = not collapsed
	body.add_child(content)
	var toggle := func() -> void:
		content.visible = not content.visible
		card.set_meta("collapsed", not content.visible)
		EdTheme.set_icon(head, "chevron.down" if content.visible else "chevron.right", EdTheme.SECONDARY, 13)
	EdTheme.set_icon(head, "chevron.right" if collapsed else "chevron.down", EdTheme.SECONDARY, 13)
	card.set_meta("collapsed", collapsed)
	card.set_meta("toggle", toggle)
	head.pressed.connect(toggle)

	var i := 0
	while i < fields.size():
		var f: Dictionary = fields[i]
		var count := int(f.get("count", 1))
		var value: Variant = _values.get(str(f.get("key", "")), {})
		if count > 1 and value is Dictionary and str((value as Dictionary).get("t", "")) == "array":
			var table: Array = [f]
			var j := i + 1
			while j < fields.size() and int(fields[j].get("count", 1)) == count and not (str(fields[j].get("kind", "")) == "ref" and str(f.get("kind", "")) == "ref"):
				var vj: Variant = _values.get(str(fields[j].get("key", "")), {})
				if not (vj is Dictionary and str((vj as Dictionary).get("t", "")) == "array"):
					break
				table.append(fields[j])
				j += 1
			_slot_table(content, table, count)
			i = j
			continue
		_field_row(content, f)
		i += 1


func _field_label(f: Dictionary) -> Control:
	var h := EdTheme.hbox(6)
	h.custom_minimum_size.x = LABEL_W
	h.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var key := str(f.get("key", ""))
	var dot := ColorRect.new()
	dot.custom_minimum_size = Vector2(5, 5)
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.color = EdTheme.AMBER if _changed_keys.has(key) else Color(0, 0, 0, 0)
	dot.tooltip_text = "Changed from the base game" if _changed_keys.has(key) else ""
	h.add_child(dot)
	var l := EdTheme.label(str(f.get("label", key)), 13, EdTheme.TEXT if _changed_keys.has(key) else EdTheme.SECONDARY)
	l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.mouse_filter = Control.MOUSE_FILTER_STOP
	var help := str(f.get("help", ""))
	l.tooltip_text = (str(f.get("label", key)) + "\n" + help) if help != "" else str(f.get("label", key))
	h.add_child(l)
	if help != "":
		var i := EdTheme.icon_rect("info.circle", 12, EdTheme.TERTIARY)
		i.mouse_filter = Control.MOUSE_FILTER_STOP
		i.tooltip_text = help
		h.add_child(i)
	return h


func _field_row(parent: VBoxContainer, f: Dictionary) -> void:
	var key := str(f.get("key", ""))
	var kind := str(f.get("kind", "int"))
	var value: Variant = _values.get(key, {})
	var v: Dictionary = value if value is Dictionary else {}
	if kind == "flags":
		var row := EdTheme.vbox(4)
		parent.add_child(row)
		row.add_child(_field_label(f))
		row.add_child(_flags_grid(f, v))
		return
	var row := EdTheme.hbox(10)
	row.custom_minimum_size.y = 30
	parent.add_child(row)
	row.add_child(_field_label(f))
	var editor := _editor_for(f, v, Callable(self, "_commit").bind(key))
	editor.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(editor)


## One editor control for a single (non-array) value. `commit(value_dict)` writes it.
func _editor_for(f: Dictionary, v: Dictionary, commit: Callable) -> Control:
	var kind := str(f.get("kind", "int"))
	match kind:
		"enum":
			return _enum_editor(f, v, commit)
		"ref":
			return _ref_picker(str(f.get("ref", "")), int(f.get("refBase", 0)), int(v.get("v", -1)), commit, f.get("options", []))
		"color":
			return _color_editor(v, commit)
		"cstring", "pstring", "str":
			return _text_field(str(v.get("v", "")), func(t: String) -> void: commit.call({"t": "str", "v": t}), "")
		"ncb":
			var e := _text_field(str(v.get("v", "")), func(t: String) -> void: commit.call({"t": "str", "v": t}), "e.g.  b120 & !b121  or  b5 b6 !b7")
			e.add_theme_font_override("font", EdTheme.mono())
			return e
		"point":
			var h := EdTheme.hbox(6)
			var cur := {"t": "point", "x": int(v.get("x", 0)), "y": int(v.get("y", 0))}
			for axis in ["x", "y"]:
				h.add_child(EdTheme.label(axis.to_upper(), 11, EdTheme.TERTIARY))
				var s := EdTheme.spin(int(cur[axis]))
				s.value_changed.connect(func(n: float) -> void:
					cur[axis] = int(n)
					commit.call(cur.duplicate()))
				h.add_child(s)
			h.add_child(EdTheme.spacer())
			return h
		"rect":
			var h := EdTheme.hbox(6)
			var cur := {"t": "rect", "top": int(v.get("top", 0)), "left": int(v.get("left", 0)), "bottom": int(v.get("bottom", 0)), "right": int(v.get("right", 0))}
			for part in ["top", "left", "bottom", "right"]:
				h.add_child(EdTheme.label(str(part).capitalize(), 11, EdTheme.TERTIARY))
				var s := EdTheme.spin(int(cur[part]))
				s.custom_minimum_size.x = 84
				s.value_changed.connect(func(n: float) -> void:
					cur[part] = int(n)
					commit.call(cur.duplicate()))
				h.add_child(s)
			return h
		"mask64":
			var e := _text_field(str(v.get("v", "0x0")), func(t: String) -> void: commit.call({"t": "u64", "v": t}), "0x0")
			e.add_theme_font_override("font", EdTheme.mono())
			return e
		"blob":
			var l := EdTheme.label(str(v.get("hex", "")) if str(v.get("hex", "")) != "" else "(%d bytes)" % int(v.get("n", 0)), 11, EdTheme.TERTIARY)
			l.add_theme_font_override("font", EdTheme.mono())
			l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			return l
	return _int_editor(f, v, commit)


func _int_editor(f: Dictionary, v: Dictionary, commit: Callable) -> Control:
	var h := EdTheme.hbox(8)
	var n := int(v.get("v", 0))
	var s := EdTheme.spin(n, int(f.get("min", -2147483648)), int(f.get("max", 2147483647)))
	h.add_child(s)
	var options: Array = f.get("options", [])
	if int(f.get("count", 1)) > 1:
		s.custom_minimum_size.x = 88
		s.value_changed.connect(func(x: float) -> void: commit.call({"t": "int", "v": int(x)}))
		return h
	var hint := EdTheme.label("", 12, EdTheme.TERTIARY)
	hint.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	hint.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var update_hint := func(x: int) -> void:
		hint.text = ""
		for opt in options:
			if _in_range(x, opt):
				hint.text = str(opt.get("label", ""))
	update_hint.call(n)
	s.value_changed.connect(func(x: float) -> void:
		update_hint.call(int(x))
		commit.call({"t": "int", "v": int(x)}))
	if not options.is_empty():
		var mb := MenuButton.new()
		mb.flat = false
		mb.tooltip_text = "Special values"
		EdTheme.set_icon(mb, "chevron.down", EdTheme.SECONDARY, 12)
		mb.add_theme_stylebox_override("normal", T.box(T.BORDERED_BG, 6, Color(0, 0, 0, 0), 0, Vector2(6, 4)))
		mb.add_theme_stylebox_override("hover", T.box(Color(1, 1, 1, 0.2), 6, Color(0, 0, 0, 0), 0, Vector2(6, 4)))
		var pm := mb.get_popup()
		for opt in options:
			pm.add_item("%s  (%d)" % [str(opt.get("label", "")), int(opt.get("start", 0))])
			pm.set_item_metadata(pm.item_count - 1, int(opt.get("start", 0)))
		pm.index_pressed.connect(func(i: int) -> void: s.value = int(pm.get_item_metadata(i)))
		h.add_child(mb)
	h.add_child(hint)
	h.add_child(EdTheme.spacer())
	return h


func _in_range(x: int, opt: Dictionary) -> bool:
	var a := float(opt.get("start", 0))
	var b := float(opt.get("end", a))
	return float(x) >= minf(a, b) and float(x) <= maxf(a, b)


func _flags_grid(f: Dictionary, v: Dictionary) -> Control:
	var key := str(f.get("key", ""))
	var grid := GridContainer.new()
	grid.columns = 2
	grid.add_theme_constant_override("h_separation", 18)
	grid.add_theme_constant_override("v_separation", 2)
	var m := EdTheme.margin(grid, 12, 0, 0, 4)
	var state := {"bits": int(v.get("v", 0))}
	for flag in f.get("flags", []):
		var mask := int(flag.get("mask", 0))
		var c := CheckBox.new()
		c.text = str(flag.get("label", ""))
		c.tooltip_text = "%s  (0x%04X)" % [str(flag.get("label", "")), mask]
		c.button_pressed = (int(state["bits"]) & mask) != 0
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		c.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		c.custom_minimum_size.x = 260
		c.toggled.connect(func(on: bool) -> void:
			var cur := int(state["bits"])
			cur = (cur | mask) if on else (cur & ~mask)
			state["bits"] = cur
			_commit({"t": "int", "v": cur}, key))
		grid.add_child(c)
	return m


func _enum_editor(f: Dictionary, v: Dictionary, commit: Callable) -> Control:
	var h := EdTheme.hbox(8)
	var n := int(v.get("v", 0))
	var options: Array = f.get("options", [])
	var menu := OptionButton.new()
	menu.fit_to_longest_item = false
	menu.custom_minimum_size.x = 150
	menu.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var chosen := -1
	for i in options.size():
		var opt: Dictionary = options[i]
		var wide := float(opt.get("end", opt.get("start", 0))) != float(opt.get("start", 0))
		menu.add_item(str(opt.get("label", "")) if wide else "%s  (%d)" % [str(opt.get("label", "")), int(opt.get("start", 0))])
		menu.set_item_metadata(i, i)
		if chosen < 0 and _in_range(n, opt):
			chosen = i
	menu.add_item("Custom value…")
	menu.set_item_metadata(options.size(), -1)
	menu.select(chosen if chosen >= 0 else options.size())
	h.add_child(menu)
	var sub := EdTheme.hbox(6)
	sub.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(sub)
	var build_sub := func(opt_index: int, value: int) -> void:
		for c in sub.get_children():
			c.queue_free()
		if opt_index < 0:
			var s := EdTheme.spin(value, -2147483648, 2147483647)
			s.value_changed.connect(func(x: float) -> void: commit.call({"t": "int", "v": int(x)}))
			sub.add_child(s)
			return
		var opt: Dictionary = options[opt_index]
		var start := int(opt.get("start", 0))
		var end := int(opt.get("end", start))
		if end == start:
			return
		var ref := str(opt.get("ref", ""))
		if ref != "":
			# Ranged reference: value = start + (resource id - 128).
			sub.add_child(_ref_picker(ref, start - 128, value if _in_range(value, opt) else -1, commit, []))
		else:
			var s := EdTheme.spin(clampi(value, mini(start, end), maxi(start, end)), mini(start, end), maxi(start, end))
			s.value_changed.connect(func(x: float) -> void: commit.call({"t": "int", "v": int(x)}))
			sub.add_child(s)
	build_sub.call(chosen if chosen >= 0 else -1, n)
	var cur := {"n": n}
	menu.item_selected.connect(func(i: int) -> void:
		var oi := int(menu.get_item_metadata(i))
		if oi < 0:
			build_sub.call(-1, int(cur["n"]))
			return
		var opt: Dictionary = options[oi]
		var nv := int(opt.get("start", 0))
		cur["n"] = nv
		commit.call({"t": "int", "v": nv})
		build_sub.call(oi, nv))
	return h


## A button that shows the referenced resource and opens a searchable picker; plus a jump arrow.
## Stored value = resource id - `base`; -1 (or anything with no resource) shows as None.
func _ref_picker(ref_type: String, base: int, value: int, commit: Callable, options: Array) -> Control:
	var h := EdTheme.hbox(4)
	var b := EdTheme.button("", Callable(), "plain")
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	b.custom_minimum_size.x = 150
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.add_theme_stylebox_override("normal", T.box(T.MENU_CHIP_BG, 6, T.MENU_CHIP_BORDER, 1, Vector2(9, 4)))
	b.add_theme_stylebox_override("hover", T.box(Color(0.15, 0.15, 0.15), 6, T.MENU_CHIP_BORDER, 1, Vector2(9, 4)))
	h.add_child(b)
	var jump := EdTheme.icon_button("arrow.right", "Open the referenced resource", Callable(), EdTheme.SECONDARY)
	h.add_child(jump)
	var state := {"v": value}
	var refresh := func() -> void:
		var v := int(state["v"])
		var rid := v + base
		var nm := ""
		var special := ""
		for opt in options:
			if _in_range(v, opt) and str(opt.get("ref", "")) == "":
				special = str(opt.get("label", ""))
		if special == "" and ed != null and ref_type != "":
			var parsed: Variant = JSON.parse_string(ed.inspect(ref_type, rid)) if rid >= 128 else null
			if parsed is Dictionary and not (parsed as Dictionary).is_empty():
				nm = str((parsed as Dictionary).get("name", ""))
				if nm == "":
					nm = "Untitled"
		if special != "":
			b.text = special
			b.add_theme_color_override("font_color", EdTheme.SECONDARY)
			EdTheme.set_icon(b, "circle.dashed", EdTheme.TERTIARY, 14)
		elif nm != "":
			b.text = "%s   #%d" % [nm, rid]
			b.add_theme_color_override("font_color", EdTheme.TEXT)
			EdTheme.set_icon(b, EdTheme.type_icon(ref_type), EdTheme.AMBER, 14)
		else:
			b.text = "None" if v < 0 else "Missing #%d" % rid
			b.add_theme_color_override("font_color", EdTheme.TERTIARY if v < 0 else EdTheme.BAD)
			EdTheme.set_icon(b, "circle.dashed", EdTheme.TERTIARY, 14)
		jump.disabled = nm == ""
	refresh.call()
	b.pressed.connect(func() -> void:
		open_picker(ref_type, int(state["v"]) + base, b, func(rid: int) -> void:
			state["v"] = rid - base if rid >= 0 else -1
			refresh.call()
			commit.call({"t": "int", "v": int(state["v"])})))
	jump.pressed.connect(func() -> void: navigate.emit(ref_type, int(state["v"]) + base))
	return h


func _color_editor(v: Dictionary, commit: Callable) -> Control:
	var h := EdTheme.hbox(8)
	var picker := ColorPickerButton.new()
	picker.color = Color8(int(v.get("r", 0)), int(v.get("g", 0)), int(v.get("b", 0)))
	picker.edit_alpha = false
	picker.custom_minimum_size = Vector2(56, 26)
	h.add_child(picker)
	var hex := EdTheme.label("#" + picker.color.to_html(false).to_upper(), 12, EdTheme.SECONDARY)
	hex.add_theme_font_override("font", EdTheme.mono())
	h.add_child(hex)
	picker.popup_closed.connect(func() -> void:
		var c := picker.color
		hex.text = "#" + c.to_html(false).to_upper()
		commit.call({"t": "color", "r": int(round(c.r * 255)), "g": int(round(c.g * 255)), "b": int(round(c.b * 255))}))
	h.add_child(EdTheme.spacer())
	return h


## LineEdit that commits on Return or when focus leaves (only if the text changed).
func _text_field(text: String, commit: Callable, placeholder: String) -> LineEdit:
	var e := EdTheme.field(placeholder)
	e.text = text
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var state := {"last": text}
	var go := func(t: String) -> void:
		if t == str(state["last"]):
			return
		state["last"] = t
		commit.call(t)
	e.text_submitted.connect(func(t: String) -> void:
		go.call(t)
		e.release_focus())
	e.focus_exited.connect(func() -> void: go.call(e.text))
	return e


## Parallel arrays of the same length (weapon / count / ammo) as one table, a row per slot.
func _slot_table(parent: VBoxContainer, fields: Array, count: int) -> void:
	var grid := GridContainer.new()
	grid.columns = fields.size() + 1
	grid.add_theme_constant_override("h_separation", 8)
	grid.add_theme_constant_override("v_separation", 4)
	parent.add_child(grid)
	grid.add_child(EdTheme.caps("Slot"))
	for f in fields:
		var l := _field_label(f)
		l.custom_minimum_size.x = 0
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		grid.add_child(l)
	var shown := mini(count, 32)
	for slot in shown:
		var sl := EdTheme.label(str(slot + 1), 12, EdTheme.TERTIARY)
		sl.custom_minimum_size.x = 34
		grid.add_child(sl)
		for f in fields:
			var key := str(f.get("key", ""))
			var arr: Dictionary = _values.get(key, {})
			var items: Array = arr.get("v", [])
			var cell: Dictionary = items[slot] if slot < items.size() and items[slot] is Dictionary else {"t": "int", "v": 0}
			var commit := func(value: Dictionary, k: String = key, idx: int = slot) -> void:
				_commit_element(k, idx, value)
			var c := _editor_for(f, cell, commit)
			c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			grid.add_child(c)
	if count > shown:
		parent.add_child(EdTheme.label("+%d more slots (edit in Raw bytes)" % (count - shown), 11, EdTheme.TERTIARY))


func _commit(value: Dictionary, key: String) -> void:
	if ed == null:
		return
	var st: Variant = JSON.parse_string(ed.set_field(type_code, res_id, key, JSON.stringify(value)))
	_values[key] = value
	var err := str((st as Dictionary).get("error", "")) if st is Dictionary else ""
	if err != "":
		message.emit(err, true)
	_after_edit("")


func _commit_element(key: String, index: int, value: Dictionary) -> void:
	if ed == null:
		return
	var st: Variant = JSON.parse_string(ed.set_field_element(type_code, res_id, key, index, JSON.stringify(value)))
	var arr: Dictionary = _values.get(key, {})
	var items: Array = arr.get("v", [])
	if index < items.size():
		items[index] = value
	var err := str((st as Dictionary).get("error", "")) if st is Dictionary else ""
	if err != "":
		message.emit(err, true)
	_after_edit("")


func _after_edit(note: String) -> void:
	if info.get("prov", "") == "base" or info.get("prov", "") == "plugin":
		info["prov"] = "override"
	edited.emit()
	if note != "":
		message.emit(note, false)


# --- resource picker ----------------------------------------------------------------------------

func open_picker(ref_type: String, current_id: int, anchor: Control, cb: Callable) -> void:
	if _picker == null or not is_instance_valid(_picker):
		_picker = PopupPanel.new()
		_picker.size = Vector2i(380, 420)
		var v := EdTheme.vbox(8)
		_picker.add_child(v)
		_picker_search = EdTheme.field("Search by name or ID", "magnifyingglass")
		v.add_child(_picker_search)
		_picker_list = ItemList.new()
		_picker_list.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_picker_list.custom_minimum_size = Vector2(360, 320)
		v.add_child(_picker_list)
		var foot := EdTheme.hbox(6)
		v.add_child(foot)
		foot.add_child(EdTheme.button("None", func() -> void:
			_picker.hide()
			_picker_cb.call(-1), "plain", "circle.dashed"))
		foot.add_child(EdTheme.spacer())
		foot.add_child(EdTheme.label("Return picks the first match", 11, EdTheme.TERTIARY))
		_picker_search.text_changed.connect(func(_t: String) -> void: _fill_picker(-1))
		_picker_search.text_submitted.connect(func(_t: String) -> void:
			if _picker_list.item_count > 0:
				_pick(0))
		_picker_list.item_activated.connect(_pick)
		_picker_list.item_clicked.connect(func(i: int, _at: Vector2, _b: int) -> void: _pick(i))
		add_child(_picker)
	_picker_type = ref_type
	_picker_cb = cb
	_picker.title = "Choose " + ref_type
	_picker_search.text = ""
	_fill_picker(current_id)
	var vp := get_viewport()
	var at := (anchor.global_position if vp.gui_embed_subwindows else anchor.get_screen_position()) + Vector2(0, anchor.size.y + 4)
	var room := vp.get_visible_rect().size
	at.x = clampf(at.x, 8, maxf(8, room.x - 388))
	if at.y + 420 > room.y - 8:
		at.y = maxf(8, at.y - anchor.size.y - 428)
	_picker.popup(Rect2i(Vector2i(at), Vector2i(380, 420)))
	_picker_search.grab_focus()


func _fill_picker(current_id: int) -> void:
	_picker_list.clear()
	if ed == null:
		return
	var parsed: Variant = JSON.parse_string(ed.browse(_picker_type, _picker_search.text))
	if not parsed is Array:
		return
	var icon := EdTheme.icon(EdTheme.type_icon(_picker_type), 14, EdTheme.SECONDARY)
	for row in parsed:
		var rid := int(row.get("id", 0))
		var i := _picker_list.add_item("%s" % str(row.get("name", "")), icon)
		_picker_list.set_item_metadata(i, rid)
		_picker_list.set_item_tooltip(i, "#%d" % rid)
		var prov := str(row.get("prov", ""))
		if prov != "base":
			_picker_list.set_item_custom_fg_color(i, EdTheme.prov_color(prov))
		_picker_list.set_item_text(i, "#%d   %s" % [rid, str(row.get("name", ""))])
		if rid == current_id:
			_picker_list.select(i)
			_picker_list.ensure_current_is_visible()


func _pick(i: int) -> void:
	var rid := int(_picker_list.get_item_metadata(i))
	_picker.hide()
	if _picker_cb.is_valid():
		_picker_cb.call(rid)


# --- text ---------------------------------------------------------------------------------------

func _text_editor() -> void:
	var text: Dictionary = info.get("text", {})
	var mode := str(text.get("mode", "plain"))
	if mode == "list":
		_string_list(text.get("strings", []))
		return
	var card := EdTheme.card(14)
	add_child(card)
	var body := EdTheme.card_body(card)
	var head := EdTheme.hbox(8)
	body.add_child(head)
	head.add_child(EdTheme.caps("Description" if mode == "desc" else "Text"))
	head.add_child(EdTheme.spacer())
	var counter := EdTheme.label("", 11, EdTheme.TERTIARY)
	head.add_child(counter)
	var edit := TextEdit.new()
	edit.custom_minimum_size = Vector2(0, 300)
	edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
	edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	edit.text = str(text.get("text", ""))
	body.add_child(edit)
	var count := func() -> void: counter.text = "%d characters" % edit.text.length()
	count.call()
	edit.text_changed.connect(count)
	var state := {"text": edit.text}
	if mode != "desc":
		edit.focus_exited.connect(func() -> void:
			if edit.text == str(state["text"]):
				return
			state["text"] = edit.text
			ed.set_text(type_code, res_id, JSON.stringify({"text": edit.text}))
			_after_edit("Text saved to the document"))
		body.add_child(EdTheme.label("Changes are applied when you click outside the text.", 11, EdTheme.TERTIARY))
		return
	# dësc: picture, movie, flags
	var flags := int(text.get("flags", 0))
	var meta := {"picture": int(text.get("picture", 0)), "movie": str(text.get("movie", "")), "flags": flags}
	var push := func() -> void:
		state["text"] = edit.text
		ed.set_text(type_code, res_id, JSON.stringify({"text": edit.text, "picture": int(meta["picture"]), "movie": str(meta["movie"]), "flags": int(meta["flags"])}))
		_after_edit("Description saved to the document")
	edit.focus_exited.connect(func() -> void:
		if edit.text != str(state["text"]):
			push.call())
	var opts := EdTheme.card(14)
	add_child(opts)
	var ob := EdTheme.card_body(opts)
	ob.add_child(EdTheme.caps("Presentation"))
	var row := EdTheme.hbox(10)
	ob.add_child(row)
	var pl := EdTheme.label("Picture", 13, EdTheme.SECONDARY)
	pl.custom_minimum_size.x = LABEL_W
	row.add_child(pl)
	var pic := int(meta["picture"])
	row.add_child(_ref_picker("PICT", 0, pic if pic > 0 else -1, func(v: Dictionary) -> void:
		meta["picture"] = maxi(0, int(v.get("v", 0)))
		push.call(), []))
	var row2 := EdTheme.hbox(10)
	ob.add_child(row2)
	var ml := EdTheme.label("Movie file", 13, EdTheme.SECONDARY)
	ml.custom_minimum_size.x = LABEL_W
	row2.add_child(ml)
	row2.add_child(_text_field(str(meta["movie"]), func(t: String) -> void:
		meta["movie"] = t
		push.call(), "QuickTime movie name"))
	var grid := HFlowContainer.new()
	grid.add_theme_constant_override("h_separation", 18)
	ob.add_child(EdTheme.margin(grid, 0, 2, 0, 0))
	for pair in [[1, "Show movie after text"], [2, "Double-size movie"], [4, "Cinematic letterbox"]]:
		var c := CheckBox.new()
		var mask := int(pair[0])
		c.text = str(pair[1])
		c.button_pressed = (flags & mask) != 0
		c.toggled.connect(func(on: bool) -> void:
			var f := int(meta["flags"])
			meta["flags"] = (f | mask) if on else (f & ~mask)
			push.call())
		grid.add_child(c)


func _string_list(strings: Array) -> void:
	var card := EdTheme.card(14)
	add_child(card)
	var body := EdTheme.card_body(card)
	var head := EdTheme.hbox(8)
	body.add_child(head)
	head.add_child(EdTheme.caps("%d strings" % strings.size()))
	head.add_child(EdTheme.spacer())
	var cur: Array = strings.duplicate()
	var rows := EdTheme.vbox(4)
	body.add_child(rows)
	var push := func() -> void:
		ed.set_text(type_code, res_id, JSON.stringify({"strings": cur}))
		_after_edit("")
	var rebuild := func(rebuild_ref: Callable) -> void:
		for c in rows.get_children():
			c.queue_free()
		for i in cur.size():
			var r := EdTheme.hbox(8)
			var n := EdTheme.label(str(i + 1), 12, EdTheme.TERTIARY)
			n.custom_minimum_size.x = 30
			n.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			r.add_child(n)
			var e := _text_field(str(cur[i]).replace("\n", "\\n"), func(t: String) -> void:
				cur[i] = t.replace("\\n", "\n")
				push.call(), "Empty string")
			r.add_child(e)
			r.add_child(EdTheme.icon_button("minus", "Remove string %d" % (i + 1), func() -> void:
				cur.remove_at(i)
				push.call()
				rebuild_ref.call(rebuild_ref), EdTheme.TERTIARY))
			rows.add_child(r)
	rebuild.call(rebuild)
	var foot := EdTheme.hbox(8)
	body.add_child(foot)
	foot.add_child(EdTheme.button("Add String", func() -> void:
		cur.append("")
		push.call()
		rebuild.call(rebuild), "plain", "plus"))
	foot.add_child(EdTheme.spacer())
	foot.add_child(EdTheme.label("A line break inside a string is written \\n.", 11, EdTheme.TERTIARY))


# --- graphics & sound ---------------------------------------------------------------------------

func _graphic() -> void:
	var parsed: Variant = JSON.parse_string(ed.graphic_info(type_code, res_id))
	var meta: Dictionary = parsed if parsed is Dictionary else {}
	var card := EdTheme.card(14)
	add_child(card)
	var body := EdTheme.card_body(card)
	if str(meta.get("error", "")) != "" or int(meta.get("frames", 0)) == 0 and not bool(meta.get("png", false)):
		body.add_child(EdTheme.empty_state("photo", "Can't preview this graphic", str(meta.get("error", "The bytes didn't decode as an image."))))
		_raw_card(true)
		return
	var view := Previews.GraphicView.new()
	var frames := int(meta.get("frames", 1))
	var state := {"frame": 0}
	var load_frame := func() -> void:
		var bytes: PackedByteArray = ed.graphic_frame(type_code, res_id, int(state["frame"]))
		if bytes.is_empty():
			return
		var image := Image.new()
		if bool(meta.get("png", false)):
			image.load_png_from_buffer(bytes)
		else:
			image = Image.create_from_data(int(meta.get("w", 1)), int(meta.get("h", 1)), false, Image.FORMAT_RGBA8, bytes)
		view.set_texture(ImageTexture.create_from_image(image))
	var tools := EdTheme.hbox(6)
	body.add_child(tools)
	var size_text := "PNG" if bool(meta.get("png", false)) else "%d × %d" % [int(meta.get("w", 0)), int(meta.get("h", 0))]
	tools.add_child(EdTheme.chip(size_text, EdTheme.SECONDARY, "photo"))
	if frames > 1:
		tools.add_child(EdTheme.chip("%d frames" % frames, EdTheme.SECONDARY, "film"))
	tools.add_child(EdTheme.spacer())
	for z in [[0, "Fit"], [1, "1×"], [2, "2×"], [4, "4×"]]:
		var zb := EdTheme.button(str(z[1]), func() -> void:
			view.scale_mode = int(z[0])
			view.set_texture(view.texture), "ghost")
		tools.add_child(zb)
	body.add_child(view)
	load_frame.call()
	if frames > 1:
		var row := EdTheme.hbox(10)
		body.add_child(row)
		var play := EdTheme.icon_button("play.fill", "Play / pause", Callable(), EdTheme.AMBER, "plain")
		row.add_child(play)
		var slider := HSlider.new()
		slider.min_value = 0
		slider.max_value = frames - 1
		slider.step = 1
		slider.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		slider.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		row.add_child(slider)
		var fl := EdTheme.label("1 / %d" % frames, 12, EdTheme.SECONDARY)
		fl.custom_minimum_size.x = 70
		row.add_child(fl)
		slider.value_changed.connect(func(x: float) -> void:
			state["frame"] = int(x)
			fl.text = "%d / %d" % [int(x) + 1, frames]
			load_frame.call())
		_anim_timer = Timer.new()
		_anim_timer.wait_time = 1.0 / 12.0
		add_child(_anim_timer)
		_anim_timer.timeout.connect(func() -> void: slider.value = (int(slider.value) + 1) % frames)
		play.pressed.connect(func() -> void:
			if _anim_timer.is_stopped():
				_anim_timer.start()
				EdTheme.set_icon(play, "pause.fill", EdTheme.AMBER, 16)
			else:
				_anim_timer.stop()
				EdTheme.set_icon(play, "play.fill", EdTheme.AMBER, 16))
	body.add_child(EdTheme.wrap_label("Replacing artwork (PNG import) is available in the macOS editor; here you can preview frames and edit the record around it.", 11, EdTheme.TERTIARY))


func _sound() -> void:
	var parsed: Variant = JSON.parse_string(ed.sound_info(type_code, res_id))
	var meta: Dictionary = parsed if parsed is Dictionary else {}
	var card := EdTheme.card(14)
	add_child(card)
	var body := EdTheme.card_body(card)
	if str(meta.get("error", "")) != "":
		body.add_child(EdTheme.empty_state("speaker.wave.2", "Can't decode this sound", str(meta.get("error", ""))))
		return
	var pcm: PackedByteArray = ed.sound_pcm(type_code, res_id)
	var row := EdTheme.hbox(8)
	body.add_child(row)
	_player = AudioStreamPlayer.new()
	add_child(_player)
	var play := EdTheme.button("Play", Callable(), "accent", "play.fill")
	row.add_child(play)
	row.add_child(EdTheme.chip("%.2f s" % float(meta.get("seconds", 0)), EdTheme.SECONDARY, "clock"))
	row.add_child(EdTheme.chip("%d Hz" % int(meta.get("rate", 0)), EdTheme.SECONDARY))
	row.add_child(EdTheme.chip("%d samples" % int(meta.get("frames", 0)), EdTheme.TERTIARY))
	var wave := Previews.Waveform.new()
	wave.set_pcm(pcm)
	_wave = wave
	body.add_child(wave)
	var player := _player
	play.pressed.connect(func() -> void:
		if player.playing:
			player.stop()
			play.text = "Play"
			EdTheme.set_icon(play, "play.fill", EdTheme.INK)
			return
		if pcm.is_empty():
			return
		var wav := AudioStreamWAV.new()
		wav.format = AudioStreamWAV.FORMAT_16_BITS
		wav.mix_rate = int(meta.get("rate", 22050))
		wav.stereo = false
		wav.data = pcm
		player.stream = wav
		player.play()
		play.text = "Stop"
		EdTheme.set_icon(play, "stop.fill", EdTheme.INK))
	player.finished.connect(func() -> void:
		play.text = "Play"
		EdTheme.set_icon(play, "play.fill", EdTheme.INK))


# --- art previews -------------------------------------------------------------------------------

const _ART := ["rlëD", "rlë8", "PICT", "cicn", "ppat"]
const _FIELD_NAMES := {"type": "Graphic", "graphic": "Graphic", "Shan": "Sprite", "custPicID": "Landing Picture", "Target Pict": "Target Picture", "Shipyard Pict": "Shipyard Picture", "Outfitter Pict": "Outfitter Picture", "graphicIndex": "Graphic"}


## Art this record draws with, found through the reference graph (companions + fields):
## shïp -> shän -> base / glow / light sprites, target & shipyard PICTs; spöb / wëap -> spïn ->
## sprite; oütf -> outfitter PICT; dësc -> picture; përs / düde -> their ships' sprites.
func _collect_art(ty: String, id: int, label: String, depth: int, out: Array, seen: Dictionary) -> void:
	if out.size() >= 8 or depth > 3 or id < 0:
		return
	var key := "%s#%d" % [ty, id]
	if seen.has(key):
		return
	seen[key] = true
	if ty in _ART:
		out.append({"type": ty, "id": id, "label": label if label != "" else "Sprite"})
		return
	if ty == "spïn":
		var sp: Variant = JSON.parse_string(ed.inspect("spïn", id))
		if sp is Dictionary:
			var vals: Dictionary = (sp as Dictionary).get("values", {})
			var sid := int((vals.get("spriteID", {}) as Dictionary).get("v", -1))
			var probe: Variant = JSON.parse_string(ed.inspect("rlëD", sid))
			var sty := "rlëD" if probe is Dictionary and not (probe as Dictionary).is_empty() else "PICT"
			_collect_art(sty, sid, label, depth + 1, out, seen)
		return
	if ty not in ["shïp", "shän", "spöb", "wëap", "oütf", "përs", "düde", "flët", "gövt", "bööm", "röid", "nëbu", "jünk", "chär"] and depth > 0:
		return
	var parsed: Variant = JSON.parse_string(ed.references(ty, id))
	if not parsed is Dictionary:
		return
	for u in (parsed as Dictionary).get("uses", []):
		var uty := str(u.get("type", ""))
		var field := str(u.get("field", ""))
		if field.to_lower().contains("mask"):
			continue
		# Name art by the field that points at it ("Base Sprite", "Shipyard Pict"); when we came
		# through a person / fleet, prefix the ship's name. shän passes the prefix down unchanged.
		var prefix := label if ty in ["shïp", "shän"] else ""
		var nice := label if uty == "shän" else ((prefix + " · " if prefix != "" else "") + str(_FIELD_NAMES.get(field, field.capitalize())))
		if uty == "shän" or uty == "spïn" or uty in _ART:
			_collect_art(uty, int(u.get("id", -1)), nice, depth + 1, out, seen)
		elif depth == 0 and uty == "shïp" and ty in ["përs", "düde", "flët"]:
			_collect_art(uty, int(u.get("id", -1)), str(u.get("name", "Ship")), depth + 1, out, seen)
	if ty == "dësc":
		var pic := int((info.get("text", {}) as Dictionary).get("picture", 0))
		if pic > 0:
			_collect_art("PICT", pic, "Picture", depth + 1, out, seen)


func _previews_card() -> void:
	if ed == null:
		return
	var art: Array = []
	_collect_art(type_code, res_id, "", 0, art, {})
	if art.is_empty():
		return
	var card := EdTheme.card(14)
	add_child(card)
	var body := EdTheme.card_body(card)
	var head := EdTheme.hbox(8)
	head.add_child(EdTheme.icon_rect("photo", 14, EdTheme.SECONDARY))
	head.add_child(EdTheme.label("Artwork", 12, EdTheme.SECONDARY, "semibold"))
	head.add_child(EdTheme.spacer())
	head.add_child(EdTheme.label("Click a tile to open it", 11, EdTheme.TERTIARY))
	body.add_child(head)
	var flow := HFlowContainer.new()
	flow.add_theme_constant_override("h_separation", 10)
	flow.add_theme_constant_override("v_separation", 10)
	body.add_child(flow)
	var animated := false
	for a in art:
		var aty := str(a.get("type", ""))
		var aid := int(a.get("id", -1))
		var gi: Variant = JSON.parse_string(ed.graphic_info(aty, aid))
		var meta: Dictionary = gi if gi is Dictionary else {}
		var frames := int(meta.get("frames", 0))
		if frames == 0 and not bool(meta.get("png", false)):
			continue
		var tile := EdTheme.row_button(func() -> void: navigate.emit(aty, aid))
		tile.add_theme_stylebox_override("normal", T.box(Color(0, 0, 0, 0.25), 10, EdTheme.CARD_LINE, 1))
		tile.add_theme_stylebox_override("hover", T.box(EdTheme.SELECT, 10, Color(EdTheme.AMBER.r, EdTheme.AMBER.g, EdTheme.AMBER.b, 0.4), 1))
		tile.tooltip_text = "%s #%d  ·  %s" % [aty, aid, "%d frames" % frames if frames > 1 else "%d × %d" % [int(meta.get("w", 0)), int(meta.get("h", 0))]]
		var v := EdTheme.vbox(4)
		var view := Previews.GraphicView.new()
		view.custom_minimum_size = Vector2(150, 130)
		view.size_flags_horizontal = Control.SIZE_FILL
		view.fixed = true
		v.add_child(view)
		var cap := EdTheme.label(str(a.get("label", aty)), 11, EdTheme.TEXT, "medium")
		cap.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		cap.custom_minimum_size.x = 150
		cap.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
		v.add_child(cap)
		var sub := EdTheme.label("%s #%d" % [aty, aid], 10, EdTheme.TERTIARY)
		sub.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		v.add_child(sub)
		EdTheme.fill_row(tile, v, 6, 6)
		flow.add_child(tile)
		var tex := _frame_texture(aty, aid, meta, 0)
		view.set_texture(tex)
		# Spin the first multi-frame sprite (ship rotations, stellar turns) so it reads as alive.
		if frames > 1 and not animated:
			animated = true
			var cache: Array = []
			for f in mini(frames, 72):
				cache.append(null)
			cache[0] = tex
			var st := {"f": 0}
			var timer := Timer.new()
			timer.wait_time = 1.0 / 12.0
			timer.autostart = true
			tile.add_child(timer)
			var n := mini(frames, 72)
			timer.timeout.connect(func() -> void:
				st["f"] = (int(st["f"]) + 1) % n
				var fi := int(st["f"])
				if cache[fi] == null:
					cache[fi] = _frame_texture(aty, aid, meta, fi)
				view.set_texture(cache[fi]))


func _frame_texture(ty: String, id: int, meta: Dictionary, frame: int) -> Texture2D:
	var bytes: PackedByteArray = ed.graphic_frame(ty, id, frame)
	if bytes.is_empty():
		return null
	var image: Image
	if bool(meta.get("png", false)):
		image = Image.new()
		if image.load_png_from_buffer(bytes) != OK:
			return null
	else:
		var w := int(meta.get("w", 1))
		var h := int(meta.get("h", 1))
		if bytes.size() != w * h * 4:
			return null
		image = Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, bytes)
	return ImageTexture.create_from_image(image)


# --- raw bytes & references ---------------------------------------------------------------------

func _raw_card(collapsed: bool) -> void:
	var card := EdTheme.card(14)
	add_child(card)
	var body := EdTheme.card_body(card)
	var head := EdTheme.button("Raw bytes", Callable(), "ghost")
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	T.style_text(head, "caption", "semibold", EdTheme.SECONDARY, 12)
	EdTheme.set_icon(head, "chevron.right" if collapsed else "chevron.down", EdTheme.SECONDARY, 13)
	head.add_theme_stylebox_override("normal", T.empty())
	head.add_theme_stylebox_override("hover", T.empty())
	body.add_child(head)
	var content := EdTheme.vbox(8)
	content.visible = not collapsed
	body.add_child(content)
	var built := {"done": false}
	var build := func() -> void:
		if bool(built["done"]):
			return
		built["done"] = true
		var editable := bool(info.get("hexEditable", false))
		if str(info.get("kind", "")) == "raw":
			content.add_child(EdTheme.wrap_label("This type has no structured editor yet. Edit its bytes directly — two hex digits per byte, spaces ignored.", 12, EdTheme.SECONDARY))
		var edit := TextEdit.new()
		edit.custom_minimum_size = Vector2(0, 180)
		edit.wrap_mode = TextEdit.LINE_WRAPPING_BOUNDARY
		edit.text = str(info.get("hex", ""))
		edit.editable = editable
		edit.add_theme_font_override("font", EdTheme.mono())
		edit.add_theme_font_size_override("font_size", 12)
		content.add_child(edit)
		var foot := EdTheme.hbox(8)
		content.add_child(foot)
		foot.add_child(EdTheme.label("%d bytes" % int(info.get("bytes", 0)), 11, EdTheme.TERTIARY))
		foot.add_child(EdTheme.spacer())
		if editable:
			foot.add_child(EdTheme.button("Apply Bytes", func() -> void:
				var st: Variant = JSON.parse_string(ed.set_hex(type_code, res_id, edit.text))
				var err := str((st as Dictionary).get("error", "")) if st is Dictionary else ""
				if err != "":
					message.emit(err, true)
					return
				_after_edit("Bytes applied")
				show_resource(ed, type_code, res_id), "plain", "checkmark"))
		else:
			foot.add_child(EdTheme.label("Too large to edit as hex here.", 11, EdTheme.TERTIARY))
	if not collapsed:
		build.call()
	head.pressed.connect(func() -> void:
		build.call()
		content.visible = not content.visible
		EdTheme.set_icon(head, "chevron.down" if content.visible else "chevron.right", EdTheme.SECONDARY, 13))


func _references_card() -> void:
	var card := EdTheme.card(14)
	add_child(card)
	var body := EdTheme.card_body(card)
	var head := EdTheme.button("References", Callable(), "ghost")
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	T.style_text(head, "caption", "semibold", EdTheme.SECONDARY, 12)
	EdTheme.set_icon(head, "chevron.right", EdTheme.SECONDARY, 13)
	head.add_theme_stylebox_override("normal", T.empty())
	head.add_theme_stylebox_override("hover", T.empty())
	head.tooltip_text = "What this resource points at, and what points at it"
	body.add_child(head)
	_refs_box = EdTheme.vbox(4)
	_refs_box.visible = false
	body.add_child(_refs_box)
	var box := _refs_box
	head.pressed.connect(func() -> void:
		box.visible = not box.visible
		EdTheme.set_icon(head, "chevron.down" if box.visible else "chevron.right", EdTheme.SECONDARY, 13)
		if box.visible and box.get_child_count() == 0:
			_fill_refs(box))


func _fill_refs(box: VBoxContainer) -> void:
	var parsed: Variant = JSON.parse_string(ed.references(type_code, res_id))
	if not parsed is Dictionary:
		return
	for heading in [["Uses", "uses", "arrow.right"], ["Used by", "usedBy", "arrow.counterclockwise"]]:
		var rows: Array = (parsed as Dictionary).get(heading[1], [])
		box.add_child(EdTheme.caps("%s  ·  %d" % [heading[0], rows.size()]))
		if rows.is_empty():
			box.add_child(EdTheme.label("Nothing", 12, EdTheme.TERTIARY))
		for row in rows.slice(0, 200):
			var ty := str(row.get("type", ""))
			var rid := int(row.get("id", -1))
			var b := EdTheme.row_button(func() -> void: navigate.emit(ty, rid))
			var h := EdTheme.hbox(8)
			h.add_child(EdTheme.icon_rect(EdTheme.type_icon(ty), 14, EdTheme.SECONDARY))
			var l := EdTheme.label("%s" % str(row.get("name", "")), 13)
			l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			l.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
			h.add_child(l)
			h.add_child(EdTheme.label("%s #%d" % [ty, rid], 11, EdTheme.TERTIARY))
			h.add_child(EdTheme.chip(str(row.get("field", "")), EdTheme.TERTIARY))
			EdTheme.fill_row(b, h, 8, 4)
			box.add_child(b)
