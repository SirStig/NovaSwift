# Headless check of the Controls Editor: every grouped action is reachable on the keyboard (or in the
# off-keyboard strip) for each size preset, every pad button has a hit target on each controller style,
# focus is wired, capture / assign / unbind / swap work. Run:
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/controls_editor_selfcheck.gd
extends SceneTree

const Controls = preload("res://Controls.gd")
const Prefs = preload("res://Prefs.gd")
const Editor = preload("res://screens/controls_editor/ControlsEditor.gd")
const Model = preload("res://screens/controls_editor/EditorModel.gd")
const Layouts = preload("res://screens/controls_editor/KeyboardLayouts.gd")
const Art = preload("res://screens/controls_editor/ControllerArt.gd")

var ok := true


func _init() -> void:
	_run()


func _check(label: String, cond: bool) -> void:
	print(("  ok   " if cond else "  FAIL ") + label)
	if not cond:
		ok = false


func _key(code: int) -> InputEventKey:
	var e := InputEventKey.new()
	e.physical_keycode = code as Key
	e.pressed = true
	return e


func _seg_hit(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> bool:
	var o1 := (b - a).cross(c - a)
	var o2 := (b - a).cross(d - a)
	var o3 := (d - c).cross(a - c)
	var o4 := (d - c).cross(b - c)
	return o1 * o2 < 0.0 and o3 * o4 < 0.0


func _size_to(ed: Node, w: int, h: int) -> void:
	var r: Control = ed._root
	r.set_anchors_and_offsets_preset(Control.PRESET_TOP_LEFT)
	r.size = Vector2(w, h)
	await process_frame
	await process_frame
	await process_frame


func _geometry(ed: Node) -> void:
	# --- keyboard: Full at 1470 wide
	for dims in [Vector2i(1470, 1000), Vector2i(1470, 923)]:
		await _size_to(ed, dims.x, dims.y)
		ed.set_tab(0)
		ed.set_group("Flight")
		Prefs.set_value("input", "ctl_preset", "full")
		ed.kb.set_layout("full")
		await process_frame
		await process_frame
		var tag := "%dx%d" % [dims.x, dims.y]
		var min_w := 1e9
		var bounds := Rect2()
		var first := true
		var inside := true
		var clipped := true
		for cap in ed.kb.caps:
			min_w = minf(min_w, cap.size.x)
			var cr := Rect2(cap.position, cap.size)
			bounds = cr if first else bounds.merge(cr)
			first = false
			clipped = clipped and cap.clip_contents
			for r in cap.rects:
				if not Rect2(Vector2.ZERO, cap.size).grow(2.0).encloses(r):
					inside = false
		_check("%s: every Full keycap >= 40 px wide (min %.1f)" % [tag, min_w], min_w >= 40.0)
		_check("%s: cap highlight/tint rects stay inside the cap (clipped)" % tag, inside and clipped)
		var kbr := Rect2(Vector2.ZERO, ed.kb.size)
		_check("%s: board inside the canvas" % tag, kbr.grow(1.0).encloses(bounds))
		var fill_w: float = bounds.size.x / ed.kb.size.x
		var fill_h: float = bounds.size.y / ed.kb.size.y
		_check("%s: board fits canvas (width %.0f%% / height %.0f%%)" % [tag, fill_w * 100.0, fill_h * 100.0], fill_w > 0.9 or fill_h > 0.9)
		var unit: float = ed.kb.caps[0].unit
		_check("%s: 1u = %.1f px" % [tag, unit], unit >= 40.0)
		# caps never overlap their neighbours
		var overlap := 0
		var rects: Array = []
		for cap in ed.kb.caps:
			rects.append(Rect2(cap.position, cap.size).grow(-1.5))
		for i in rects.size():
			for j in range(i + 1, rects.size()):
				if (rects[i] as Rect2).intersects(rects[j]):
					overlap += 1
		_check("%s: no keycap overlaps another" % tag, overlap == 0)
	# --- controller: pad share of the canvas, hit outlines, callout leaders
	ed.set_tab(1)
	for dims in [Vector2i(1470, 1000), Vector2i(1280, 800)]:
		await _size_to(ed, dims.x, dims.y)
		for st in Model.PAD_STYLES:
			ed.pad.set_style(st)
			ed.pad.set_group("Flight")
			await process_frame
			var pr: Rect2 = ed.pad.pad_rect_px()
			var share: float = pr.size.x / ed.pad.size.x
			var tag2 := "%s @ %dx%d" % [st, dims.x, dims.y]
			_check("%s: pad is %.0f%% of the canvas width" % [tag2, share * 100.0], share >= 0.55 and share <= 0.70)
			_check("%s: pad inside the canvas" % tag2, Rect2(Vector2.ZERO, ed.pad.size).encloses(pr))
			var bad := 0
			for id in ed.pad.hits:
				var h: Control = ed.pad.hits[id]
				for p in h.poly:
					if not Rect2(Vector2.ZERO, h.size).grow(2.0).has_point(p):
						bad += 1
			_check("%s: control outlines fit their hit rects" % tag2, bad == 0)
			var cross := 0
			var cos: Array = ed.pad.callouts
			for i in cos.size():
				for j in range(i + 1, cos.size()):
					var la: PackedVector2Array = cos[i].line
					var lb: PackedVector2Array = cos[j].line
					for u in range(la.size() - 1):
						for v in range(lb.size() - 1):
							if _seg_hit(la[u], la[u + 1], lb[v], lb[v + 1]):
								cross += 1
			_check("%s: %d callout leaders, none cross" % [tag2, cos.size()], cross == 0 and cos.size() >= 16)
			var off := 0
			for co in cos:
				var ly: float = co.y
				if ly < 0.0 or ly > ed.pad.size.y:
					off += 1
			_check("%s: callout labels inside the canvas" % tag2, off == 0)
	await _size_to(ed, 1470, 1000)
	# fixed roles on the controller tab (item: no "-" for turn / thrust)
	ed.set_tab(1)
	for a in ["turn_left", "turn_right", "thrust", "reverse"]:
		_check("%s shows its fixed role on the pad tab (%s)" % [a, ed.chip_text(a)], ed.chip_text(a) != "-" and ed.chip_fixed_only(a))
	ed.set_tab(0)


func _run() -> void:
	Prefs.path = "user://_ce_selfcheck.cfg"
	Prefs.load_all()
	Controls.reset_defaults()
	Controls.register()
	var ed: Node = Editor.new()
	root.add_child(ed)
	ed.setup()
	await process_frame
	await process_frame
	_check("action rows listed (%d)" % ed.rows.size(), ed.rows.size() >= 40)
	await _geometry(ed)
	# every action of every group: on the keyboard or the off-keyboard strip, per preset and layer
	for preset in Model.PRESETS:
		Prefs.set_value("input", "ctl_preset", preset)
		ed.kb.set_layout(preset)
		ed.set_tab(0)
		for g in Model.GROUP_NAMES:
			ed.set_group(g)
			for li in 3:
				ed.set_kb_layer(li)
				var field: String = Model.LAYER_FIELDS[li]
				var have := Layouts.codes(preset)
				var off: Array = ed.off_keyboard()
				var bad := 0
				for action in Controls.GROUPS[g]:
					for c in Controls.effective(action).get(field, []):
						var in_off := false
						for e in off:
							if e[0] == action and e[1] == c:
								in_off = true
						if not have.has(int(c)) and not in_off:
							bad += 1
						if have.has(int(c)) and ed.kb.cap_for(int(c)) == null:
							bad += 1
				_check("%s / %s / %s: all bindings placed" % [preset, g, Model.LAYERS[li]], bad == 0)
	ed.set_kb_layer(0)
	ed.set_group("Flight")
	Prefs.set_value("input", "ctl_preset", "compact")
	ed.kb.set_layout("compact")
	_check("compact lacks the numpad / nav cluster", not Layouts.codes("compact").has(KEY_KP_ENTER) and not Layouts.codes("compact").has(KEY_HOME))
	_check("tkl lacks the numpad but has arrows", not Layouts.codes("tkl").has(KEY_KP_ENTER) and Layouts.codes("tkl").has(KEY_LEFT))
	# pad styles: a hit target for every bindable button
	ed.set_tab(1)
	for st in Model.PAD_STYLES:
		ed.pad.set_style(st)
		var missing := 0
		for b in Art.BINDABLE:
			if not ed.pad.hits.has(b) or not (ed.pad.hits[b] as Control).focus_mode == Control.FOCUS_ALL:
				missing += 1
		_check("%s: hit targets for all %d bindable buttons" % [st, Art.BINDABLE.size()], missing == 0)
	for g in Model.GROUP_NAMES:
		for action in Controls.GROUPS[g]:
			for b in Controls.effective(action).get("buttons", []):
				if not ed.pad.hits.has(int(b)):
					_check("pad button %d of %s has a target" % [b, action], false)
	# capture: key, swap, Esc, pad
	ed.set_tab(0)
	ed.set_group("Flight")
	ed._on_row("land")
	_check("selecting an action arms capture", ed.armed and ed.sel_action == "land")
	_check("capture consumes a key", ed.capture_event(_key(KEY_H)))
	_check("land is now H", Controls.effective("land").keys == [KEY_H])
	ed._on_row("galaxy_map")
	ed.capture_event(_key(KEY_H))
	_check("conflict swaps", Controls.effective("galaxy_map").keys == [KEY_H] and Controls.effective("land").keys == [KEY_M])
	ed._on_row("hyperjump")
	ed.capture_event(_key(KEY_ESCAPE))
	_check("Esc cancels", Controls.effective("hyperjump").keys == [KEY_J] and not ed.armed)
	# device first: click a key, assign, unbind
	ed._on_key(KEY_F)
	_check("click selects the key", ed.sel_input == KEY_F)
	ed._bar_actions = [""]
	ed._on_unbind()
	_check("unbind clears escort_attack", (Controls.effective("escort_attack").keys as Array).is_empty())
	ed._on_key(KEY_F)
	ed._on_key(KEY_F)
	ed._update_bar()
	ed._on_assign(ed._bar_actions.find("escort_attack"))
	_check("assign rebinds", Controls.effective("escort_attack").keys == [KEY_F])
	# modifier layer field follows the action
	ed._on_row("target_prev")
	_check("layer follows the action's field", ed.kb_layer == 1 and ed.current_field() == "shift_keys")
	ed.capture_event(_key(KEY_T))
	_check("shift layer rebind", Controls.effective("target_prev").shift_keys == [KEY_T])
	# pad capture
	ed.set_tab(1)
	ed._on_row("fire_primary")
	var jb := InputEventJoypadButton.new()
	jb.button_index = JOY_BUTTON_RIGHT_SHOULDER
	jb.pressed = true
	_check("pad capture", ed.capture_event(jb) and Controls.effective("fire_primary").buttons == [JOY_BUTTON_RIGHT_SHOULDER])
	ed._reset_now()
	_check("reset restores defaults", Controls.effective("land").keys == [KEY_L])
	DirAccess.remove_absolute(ProjectSettings.globalize_path("user://_ce_selfcheck.cfg"))
	print("controls editor selfcheck: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
