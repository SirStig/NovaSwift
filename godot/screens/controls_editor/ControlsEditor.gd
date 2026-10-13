# NOVA Swift — Controls Editor (Godot): the visual replacement for Settings -> Controls' per-action
# rebind rows (docs/CONTROLS_EDITOR.md). A NovaSwift settings screen, not an original dialog.
#
#   Keyboard tab    a rendered keyboard (Full / TKL / 75% / 65% / 60% / Mac laptop, ISO toggle) with a
#                   Base · Shift · Alt layer selector; bound keys are tinted by action category.
#   Controller tab  a procedurally drawn pad (Xbox / PlayStation / Switch Pro / Steam Deck) with
#                   callout labels; pressing a physical button lights it on the art.
#   Group selector  Flight · Docked · Galaxy map — a key may be reused across groups (Controls.GROUPS).
#
# Two ways to bind, always available: DEVICE FIRST (click / A a key or pad button -> the bar under the
# art lists what it does and offers Assign / Unbind) and ACTION FIRST (pick a row in the list -> its
# key / button pulses; click a key / button on the art or press the physical one. Esc cancels, an
# unanswered capture ends after 6 s, as the old list did). Conflicts swap exactly as Controls.rebind.
#
# Everything is a focusable Control: arrows / d-pad / stick walk the keycaps and the list, A / Enter
# activates, B / Esc backs out (cancel capture -> clear selection -> close), LB / RB flip the tabs.
extends CanvasLayer

const T = preload("res://ui/novaswift/NovaTheme.gd")
const NC = preload("res://ui/novaswift/NovaControls.gd")
const Alert = preload("res://ui/novaswift/NovaAlert.gd")
const Controls = preload("res://Controls.gd")
const Prefs = preload("res://Prefs.gd")
const Model = preload("res://screens/controls_editor/EditorModel.gd")
const Layouts = preload("res://screens/controls_editor/KeyboardLayouts.gd")
const KeyboardView = preload("res://screens/controls_editor/KeyboardView.gd")
const ControllerView = preload("res://screens/controls_editor/ControllerView.gd")
const Art = preload("res://screens/controls_editor/ControllerArt.gd")

signal closed
signal changed

const CAPTURE_TIMEOUT := 6.0
const AMBER := T.AMBER

var tab := 0                        # 0 keyboard, 1 controller
var group := "Flight"
var layer := 0                      # index into Model.LAYERS
var rows: Dictionary = {}           # action -> Button
var kb: Control
var pad: Control
var sel_action := ""                # action-first selection ("" = none)
var armed := false                  # waiting for a physical input / a click on the art
var sel_input: Variant = null       # device-first selection: key code or JoyButton (int) or null

var _root: Control
var _tab_seg: HBoxContainer
var _group_seg: HBoxContainer
var _layer_seg: HBoxContainer
var _opts_kb: Control
var _opts_pad: Control
var _preset_opt: OptionButton
var _iso_chip: Button
var _style_opt: OptionButton
var _kb_box: Control
var _strip: VBoxContainer
var _strip_flow: HFlowContainer
var _bar: HBoxContainer
var _bar_label: Label
var _assign_opt: OptionButton
var _unbind_btn: Button
var _status: Label
var _list: VBoxContainer
var _search := ""
var _capture_serial := 0
var _bar_actions: Array = []
var _conflicts: Dictionary = {}


func setup() -> void:
	layer = 80
	group = "Flight"
	_build()
	_refresh_all()
	var first: Control = (_tab_seg.get_meta("buttons") as Array)[0]
	first.grab_focus.call_deferred()


# --- construction ----------------------------------------------------------------------------

func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.theme = T.theme()
	add_child(_root)
	var bg := ColorRect.new()
	bg.color = Color(0.055, 0.058, 0.07)
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(bg)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for s in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + s, 18)
	_root.add_child(margin)
	var main := VBoxContainer.new()
	main.add_theme_constant_override("separation", 10)
	margin.add_child(main)

	# header
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 14)
	main.add_child(head)
	NC.label(head, "Controls Editor", "heading", "bold", AMBER)
	_tab_seg = NC.segmented(head, ["Keyboard", "Controller"], 0, _on_tab)
	_tab_seg.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_tab_seg.custom_minimum_size = Vector2(280, 0)
	NC.hspacer(head)
	var reset := NC.button("Reset to Defaults", "bordered", _reset_confirm, "arrow.counterclockwise")
	head.add_child(reset)
	var done := NC.button("Done", "primary", close)
	head.add_child(done)

	# options
	var opts := HBoxContainer.new()
	opts.add_theme_constant_override("separation", 12)
	main.add_child(opts)
	NC.label(opts, "Context", "caption", "semibold", T.SECONDARY)
	_group_seg = NC.segmented(opts, Model.GROUP_NAMES, 0, _on_group)
	_group_seg.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_group_seg.custom_minimum_size = Vector2(300, 0)
	var vsep := ColorRect.new()
	vsep.color = Color(1, 1, 1, 0.12)
	vsep.custom_minimum_size = Vector2(1, 22)
	opts.add_child(vsep)
	_opts_kb = HBoxContainer.new()
	_opts_kb.add_theme_constant_override("separation", 10)
	opts.add_child(_opts_kb)
	NC.label(_opts_kb, "Layer", "caption", "semibold", T.SECONDARY)
	_layer_seg = NC.segmented(_opts_kb, ["Base", "Shift", "Alt"], 0, _on_layer)
	_layer_seg.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	_layer_seg.custom_minimum_size = Vector2(210, 0)
	NC.label(_opts_kb, "Size", "caption", "semibold", T.SECONDARY)
	var preset_names: Array = ["Auto (%s)" % Model.PRESET_NAMES[Model.PRESETS.find(_auto_preset())]]
	preset_names.append_array(Model.PRESET_NAMES)
	var cur_p := str(Prefs.get_value("input", "ctl_preset"))
	_preset_opt = NC.option_chip(preset_names, Model.PRESETS.find(cur_p) + 1 if cur_p in Model.PRESETS else 0, _on_preset)
	_opts_kb.add_child(_preset_opt)
	_iso_chip = NC.chip(_opts_kb, "ISO", Model.iso(), _on_iso)
	_opts_pad = HBoxContainer.new()
	_opts_pad.add_theme_constant_override("separation", 10)
	opts.add_child(_opts_pad)
	NC.label(_opts_pad, "Style", "caption", "semibold", T.SECONDARY)
	var style_names: Array = ["Auto (%s)" % Model.PAD_STYLE_NAMES[Model.PAD_STYLES.find(Model.detect_pad_style())]]
	style_names.append_array(Model.PAD_STYLE_NAMES)
	var cur_s := str(Prefs.get_value("input", "ctl_pad_style"))
	_style_opt = NC.option_chip(style_names, Model.PAD_STYLES.find(cur_s) + 1 if cur_s in Model.PAD_STYLES else 0, _on_style)
	_opts_pad.add_child(_style_opt)

	# body: device column + action list
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	main.add_child(body)
	var left := VBoxContainer.new()
	left.add_theme_constant_override("separation", 8)
	left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(left)
	var holder := PanelContainer.new()
	holder.add_theme_stylebox_override("panel", T.box(Color(0.075, 0.08, 0.095), 18, Color(1, 1, 1, 0.08), 1, Vector2(6, 6)))
	holder.size_flags_vertical = Control.SIZE_EXPAND_FILL
	holder.custom_minimum_size = Vector2(0, 260)
	left.add_child(holder)
	var stack := Control.new()
	holder.add_child(stack)
	kb = KeyboardView.new()
	kb.set_anchors_preset(Control.PRESET_FULL_RECT)
	kb.key_pressed.connect(_on_key)
	kb.key_hover.connect(_on_key_hover)
	stack.add_child(kb)
	pad = ControllerView.new()
	pad.set_anchors_preset(Control.PRESET_FULL_RECT)
	pad.control_pressed.connect(_on_pad_control)
	pad.control_hover.connect(_on_pad_hover)
	stack.add_child(pad)
	_kb_box = kb

	_strip = VBoxContainer.new()
	_strip.add_theme_constant_override("separation", 4)
	left.add_child(_strip)
	NC.label(_strip, "Off-keyboard bindings - keys this size does not have", "caption", "semibold", T.SECONDARY)
	_strip_flow = HFlowContainer.new()
	_strip_flow.add_theme_constant_override("h_separation", 6)
	_strip_flow.add_theme_constant_override("v_separation", 4)
	_strip.add_child(_strip_flow)

	_bar = HBoxContainer.new()
	_bar.add_theme_constant_override("separation", 10)
	left.add_child(_bar)
	_bar_label = NC.label(_bar, "", "body", "medium")
	_bar_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bar_label.clip_text = true
	_assign_opt = NC.option_chip(["Assign action..."], 0, _on_assign)
	_assign_opt.custom_minimum_size = Vector2(230, 0)
	_bar.add_child(_assign_opt)
	_unbind_btn = NC.button("Unbind", "bordered", _on_unbind)
	_bar.add_child(_unbind_btn)

	var legend := HBoxContainer.new()
	legend.add_theme_constant_override("separation", 14)
	left.add_child(legend)
	for cid in Model.CATEGORY_ORDER:
		var sw := ColorRect.new()
		sw.color = Model.CATEGORIES[cid][1]
		sw.custom_minimum_size = Vector2(12, 12)
		sw.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		var h := HBoxContainer.new()
		h.add_theme_constant_override("separation", 5)
		h.add_child(sw)
		NC.label(h, str(Model.CATEGORIES[cid][0]), "caption", "regular", T.SECONDARY)
		legend.add_child(h)
	_status = NC.label(left, "", "caption", "regular", Color(1.0, 0.75, 0.4), true)

	var right := PanelContainer.new()
	right.custom_minimum_size = Vector2(340, 0)
	right.add_theme_stylebox_override("panel", T.box(Color(1, 1, 1, 0.04), 14, Color(1, 1, 1, 0.08), 1, Vector2(10, 10)))
	body.add_child(right)
	var rv := VBoxContainer.new()
	rv.add_theme_constant_override("separation", 8)
	right.add_child(rv)
	NC.search_field(rv, "Search actions", "", _on_search)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.follow_focus = true
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	rv.add_child(scroll)
	_list = VBoxContainer.new()
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_list.add_theme_constant_override("separation", 3)
	scroll.add_child(_list)

	pad.set_style(Model.pad_style())
	kb.set_layout(Model.preset(), Model.iso())
	_apply_tab()


static func _auto_preset() -> String:
	return "mac" if OS.get_name() == "macOS" else "full"


# --- public (tests / Settings) -------------------------------------------------------------------

func close() -> void:
	_cancel_capture()
	Prefs.save()
	closed.emit()
	queue_free()


func set_tab(i: int) -> void:
	tab = i
	NC.segmented_select(_tab_seg, i)
	_cancel_capture()
	_apply_tab()
	_refresh_all()


func set_group(g: String) -> void:
	group = g
	NC.segmented_select(_group_seg, Model.GROUP_NAMES.find(g))
	_cancel_capture()
	sel_input = null
	_build_list()
	_refresh_all()


func set_layer(i: int) -> void:
	layer = i
	NC.segmented_select(_layer_seg, i)
	if armed:
		_arm(sel_action)
	sel_input = null
	_refresh_all()


func current_field() -> String:
	return "buttons" if tab == 1 else str(Model.LAYER_FIELDS[layer])


func chip_text(action: String) -> String:
	if tab == 1:
		var parts: Array[String] = []
		for b in Controls.effective(action).get("buttons", []):
			parts.append(Art.button_name(pad.style, int(b)))
		return " / ".join(parts) if not parts.is_empty() else "-"
	var spec := Controls.effective(action)
	var ps: Array[String] = []
	for k in spec.get("keys", []):
		ps.append(Model.key_name(int(k)))
	for k in spec.get("shift_keys", []):
		ps.append("Shift+" + Model.key_name(int(k)))
	for k in spec.get("alt_keys", []):
		ps.append("Alt+" + Model.key_name(int(k)))
	return " / ".join(ps) if not ps.is_empty() else "-"


# --- tabs / pickers ------------------------------------------------------------------------------

func _on_tab(i: int) -> void:
	tab = i
	_cancel_capture()
	sel_input = null
	_apply_tab()
	_refresh_all()


func _apply_tab() -> void:
	kb.visible = tab == 0
	pad.visible = tab == 1
	_opts_kb.visible = tab == 0
	_opts_pad.visible = tab == 1
	_strip.visible = false
	if tab == 1:
		pad.set_group(group)


func _on_group(i: int) -> void:
	group = Model.GROUP_NAMES[i]
	_cancel_capture()
	sel_input = null
	pad.set_group(group)
	_build_list()
	_refresh_all()


func _on_layer(i: int) -> void:
	layer = i
	if armed:
		_arm(sel_action)
	sel_input = null
	_refresh_all()


func _on_preset(i: int) -> void:
	Prefs.set_value("input", "ctl_preset", "auto" if i == 0 else Model.PRESETS[i - 1])
	kb.set_layout(Model.preset(), Model.iso())
	_refresh_all()


func _on_iso() -> void:
	Prefs.set_value("input", "ctl_iso", _iso_chip.button_pressed)
	kb.set_layout(Model.preset(), Model.iso())
	_refresh_all()


func _on_style(i: int) -> void:
	Prefs.set_value("input", "ctl_pad_style", "auto" if i == 0 else Model.PAD_STYLES[i - 1])
	pad.set_style(Model.pad_style())
	pad.set_group(group)
	_refresh_all()


# --- action list ---------------------------------------------------------------------------------

func _on_search(t: String) -> void:
	_search = t.strip_edges().to_lower()
	_build_list()
	_refresh_all()


func _build_list() -> void:
	for c in _list.get_children():
		_list.remove_child(c)
		c.queue_free()
	rows.clear()
	var by_cat: Dictionary = {}
	for action in Controls.GROUPS.get(group, []):
		if _search != "" and not Model.label_of(action).to_lower().contains(_search) \
				and not chip_text(action).to_lower().contains(_search):
			continue
		var cat := Model.category_of(action)
		var l: Array = by_cat.get(cat, [])
		l.append(action)
		by_cat[cat] = l
	for cid in Model.CATEGORY_ORDER:
		if not by_cat.has(cid):
			continue
		var hdr := NC.label(_list, str(Model.CATEGORIES[cid][0]).to_upper(), "caption", "bold", Model.CATEGORIES[cid][1])
		hdr.add_theme_constant_override("line_spacing", 0)
		for action in by_cat[cid]:
			_list.add_child(_make_row(str(action)))


func _make_row(action: String) -> Button:
	var b := Button.new()
	b.text = Model.label_of(action)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.clip_text = true
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = Vector2(0, 34)
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	T.style_text(b, "body", "regular", T.WHITE, 14)
	var chip := Label.new()
	chip.name = "Chip"
	chip.set_anchors_preset(Control.PRESET_FULL_RECT)
	chip.offset_right = -10
	chip.offset_left = 150
	chip.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	chip.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	chip.clip_text = true
	T.style_text(chip, "caption", "semibold", T.WHITE)
	b.add_child(chip)
	b.pressed.connect(_on_row.bind(action))
	b.mouse_entered.connect(_hover_action.bind(action, true))
	b.mouse_exited.connect(_hover_action.bind(action, false))
	b.focus_entered.connect(_hover_action.bind(action, true))
	b.focus_exited.connect(_hover_action.bind(action, false))
	rows[action] = b
	_style_row(action)
	return b


func _style_row(action: String) -> void:
	var b: Button = rows.get(action)
	if b == null:
		return
	var cat := Model.cat_color(action)
	var bound := chip_text(action) != "-"
	var conflict := _conflicts.has(action)
	var selected := action == sel_action
	var bg := Color(1, 1, 1, 0.05)
	if selected:
		bg = Color(1.0, 0.7, 0.28, 0.22)
	elif bool(b.get_meta("hl", false)):
		bg = Color(1, 1, 1, 0.14)
	var border := Color(cat.r, cat.g, cat.b, 0.9)
	var mk := func(col: Color) -> StyleBoxFlat:
		var sb := T.box(col, 7, Color(1, 0.7, 0.28, 0.9) if selected else Color(0, 0, 0, 0), 2 if selected else 0, Vector2(12, 4))
		sb.border_width_left = 4
		sb.border_color = border if not selected else AMBER
		sb.content_margin_left = 14
		return sb
	b.add_theme_stylebox_override("normal", mk.call(bg))
	b.add_theme_stylebox_override("hover", mk.call(Color(1, 1, 1, 0.13)))
	b.add_theme_stylebox_override("pressed", mk.call(Color(1, 1, 1, 0.2)))
	b.add_theme_stylebox_override("focus", mk.call(Color(1, 1, 1, 0.12)))
	var fc := T.WHITE
	if conflict:
		fc = T.RED
	elif not bound:
		fc = Color(1, 1, 1, 0.5)
	for st in ["font_color", "font_hover_color", "font_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(st, fc)
	var chip: Label = b.get_node("Chip")
	chip.text = ("Press a key..." if tab == 0 else "Press a button...") if (selected and armed) else chip_text(action)
	chip.add_theme_color_override("font_color", AMBER if (selected and armed) else (T.RED if conflict else (Color(1, 1, 1, 0.35) if not bound else Color(1, 1, 1, 0.85))))


# --- selection / capture (action first) -----------------------------------------------------------

func _on_row(action: String) -> void:
	if action == sel_action:
		_cancel_capture()
		sel_action = ""
		_refresh_all()
		return
	if tab == 0:
		var f := Model.field_of(action)
		layer = Model.layer_of_field(f)
		NC.segmented_select(_layer_seg, layer)
	sel_input = null
	_arm(action)
	_refresh_all()


func _arm(action: String) -> void:
	sel_action = action
	armed = true
	_capture_serial += 1
	_status.text = ("Waiting for a key - click one on the keyboard or press it. Esc cancels."
		if tab == 0 else "Waiting for a button - click one on the pad or press it. Esc cancels.")
	var serial := _capture_serial
	get_tree().create_timer(CAPTURE_TIMEOUT).timeout.connect(func():
		if _capture_serial == serial and armed:
			_cancel_capture()
			_refresh_all())


func _cancel_capture() -> void:
	if not armed and sel_action == "":
		return
	armed = false
	sel_action = ""
	_capture_serial += 1
	_status.text = ""
	_restyle_rows()
	_update_pulse()


## Feed an event to the capture. Public so a test can drive it (parse_input_event is not
## delivered headless). Returns true if the event was consumed.
func capture_event(event: InputEvent) -> bool:
	if not armed:
		return false
	var field := current_field()
	var code := -1
	if field == "buttons":
		if event is InputEventKey and event.pressed and event.physical_keycode == KEY_ESCAPE:
			_cancel_capture()
			_refresh_all()
			return true
		if event is InputEventJoypadButton and event.pressed:
			code = event.button_index
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_ESCAPE:
			_cancel_capture()
			_refresh_all()
			return true
		code = event.physical_keycode
	if code < 0:
		return false
	_commit(sel_action, field, code)
	return true


func _commit(action: String, field: String, code: int) -> void:
	var swapped := Model.assign(action, field, code)
	armed = false
	sel_action = ""
	_capture_serial += 1
	if swapped != "":
		_status.text = "Swapped with \"%s\"." % Model.label_of(swapped)
	else:
		_status.text = ""
	changed.emit()
	_refresh_all()


func _input(event: InputEvent) -> void:
	if not armed:
		return
	if event is InputEventKey or (event is InputEventJoypadButton and tab == 1):
		if capture_event(event):
			get_viewport().set_input_as_handled()
		elif event.is_pressed():
			# Anything else pressed while waiting is swallowed so it can't also
			# navigate or activate the focused control.
			get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if not _root.visible:
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		if armed:
			_cancel_capture()
			_refresh_all()
		elif sel_input != null:
			_set_sel_input(null)
		else:
			close()
		return
	if event is InputEventJoypadButton and event.pressed and not armed:
		if event.button_index == JOY_BUTTON_LEFT_SHOULDER and tab == 1:
			set_tab(0)
			get_viewport().set_input_as_handled()
		elif event.button_index == JOY_BUTTON_RIGHT_SHOULDER and tab == 0:
			set_tab(1)
			get_viewport().set_input_as_handled()


# --- device first ---------------------------------------------------------------------------------

func _on_key(code: int) -> void:
	if armed:
		_commit(sel_action, current_field(), code)
	else:
		_set_sel_input(null if sel_input == code else code)


func _on_pad_control(id: int) -> void:
	if armed:
		_commit(sel_action, "buttons", id)
	else:
		_set_sel_input(null if sel_input == id else id)


func _set_sel_input(v: Variant) -> void:
	sel_input = v
	_refresh_all()


func _acts_on(v: Variant) -> Array:
	if v == null:
		return []
	if tab == 1:
		return Model.pad_map(group).get(int(v), [])
	return Model.key_map(group, current_field()).get(int(v), [])


func _update_bar() -> void:
	var has := sel_input != null
	_assign_opt.visible = has
	_unbind_btn.visible = has
	if not has:
		_bar_label.text = "Click a %s to see what it does, or pick an action on the right and then a %s." % \
			(["key", "key"] if tab == 0 else ["button", "button"])
		_bar_actions = []
		return
	var nm: String = Model.key_name(int(sel_input)) if tab == 0 else Art.button_name(pad.style, int(sel_input))
	if tab == 0 and layer > 0:
		nm = Model.LAYERS[layer] + "+" + nm
	var acts := _acts_on(sel_input)
	var names: Array = []
	for a in acts:
		names.append(Model.label_of(str(a)))
	_bar_label.text = "%s  -  %s" % [nm, ", ".join(names) if not names.is_empty() else "unbound"]
	_unbind_btn.disabled = acts.is_empty()
	_assign_opt.clear()
	_assign_opt.add_item("Assign action...", 0)
	_bar_actions = [""]
	var i := 1
	for a in Controls.GROUPS.get(group, []):
		_assign_opt.add_item(Model.label_of(str(a)), i)
		_bar_actions.append(str(a))
		i += 1
	_assign_opt.select(0)


func _on_assign(i: int) -> void:
	if i <= 0 or i >= _bar_actions.size() or sel_input == null:
		return
	var swapped := Model.assign(str(_bar_actions[i]), current_field(), int(sel_input))
	_status.text = ("Swapped with \"%s\"." % Model.label_of(swapped)) if swapped != "" else ""
	changed.emit()
	_refresh_all()


func _on_unbind() -> void:
	if sel_input == null:
		return
	for a in _acts_on(sel_input):
		Model.unbind(str(a), current_field(), int(sel_input))
	_status.text = ""
	changed.emit()
	_refresh_all()


# --- hover links ----------------------------------------------------------------------------------

func _hover_action(action: String, on: bool) -> void:
	var codes: Dictionary = {}
	if on:
		for c in Controls.effective(action).get(current_field(), []):
			codes[int(c)] = true
	if tab == 0:
		kb.set_highlight(codes)
	else:
		pad.set_highlight(codes)


func _on_key_hover(code: int, on: bool) -> void:
	for a in rows:
		rows[a].set_meta("hl", false)
	if on:
		for a in Model.key_map(group, current_field()).get(code, []):
			if rows.has(a):
				rows[a].set_meta("hl", true)
	_restyle_rows()


func _on_pad_hover(id: int, on: bool) -> void:
	for a in rows:
		rows[a].set_meta("hl", false)
	if on:
		for a in Model.pad_map(group).get(id, []):
			if rows.has(a):
				rows[a].set_meta("hl", true)
	_restyle_rows()


# --- refresh ---------------------------------------------------------------------------------------

func _restyle_rows() -> void:
	for a in rows:
		_style_row(a)


func _update_pulse() -> void:
	var codes: Dictionary = {}
	if armed and sel_action != "":
		for c in Controls.effective(sel_action).get(current_field(), []):
			codes[int(c)] = true
	kb.set_pulse(codes if tab == 0 else {})
	pad.set_pulse(codes if tab == 1 else {})


func _refresh_all() -> void:
	var field := current_field()
	_conflicts = Model.conflicts(group, field)
	if rows.is_empty():
		_build_list()
	_restyle_rows()
	# keyboard art
	var km := Model.key_map(group, str(Model.LAYER_FIELDS[layer]))
	var dots := Model.other_layer_codes(group, str(Model.LAYER_FIELDS[layer]))
	var info: Dictionary = {}
	for code in km:
		info[code] = {"acts": km[code], "tint": Model.cat_color(str(km[code][0])), "dot": dots.has(code)}
	for code in dots:
		if not info.has(code):
			info[code] = {"acts": [], "tint": Color(0, 0, 0, 0), "dot": true}
	kb.set_info(info)
	kb.set_selected(int(sel_input) if (sel_input != null and tab == 0) else -999)
	pad.refresh()
	pad.set_selected(sel_input if tab == 1 else null)
	_update_pulse()
	_update_bar()
	_build_strip()


## Actions of this group + layer bound to keys the chosen size does not draw.
func off_keyboard() -> Array:
	var have := Layouts.codes(Model.preset(), Model.iso())
	var out: Array = []
	var field := str(Model.LAYER_FIELDS[layer])
	for action in Controls.GROUPS.get(group, []):
		for c in Controls.effective(action).get(field, []):
			if not have.has(int(c)):
				out.append([str(action), int(c)])
	return out


func _build_strip() -> void:
	for c in _strip_flow.get_children():
		_strip_flow.remove_child(c)
		c.queue_free()
	var off := off_keyboard() if tab == 0 else []
	_strip.visible = not off.is_empty()
	for e in off:
		var action: String = e[0]
		var b := NC.button("%s: %s" % [Model.label_of(action), Model.key_name(int(e[1]))], "bordered")
		var col := Model.cat_color(action)
		b.add_theme_stylebox_override("normal", T.box(Color(col.r, col.g, col.b, 0.28), 7, Color(col.r, col.g, col.b, 0.6), 1, Vector2(10, 4)))
		b.pressed.connect(_on_row.bind(action))
		_strip_flow.add_child(b)


func _reset_confirm() -> void:
	Alert.show(self, {"title": "Reset every key and pad binding to its default?", "buttons": [
		{"title": "Cancel", "role": "cancel"},
		{"title": "Reset", "role": "destructive", "cb": _reset_now}]})


func _reset_now() -> void:
	# Bindings only: the modern-layout toggle stays as set, so the defaults restored are the layout in force.
	Prefs.reset_bindings()
	Controls.register()
	_cancel_capture()
	sel_input = null
	_status.text = "Bindings restored to their defaults."
	changed.emit()
	_refresh_all()
