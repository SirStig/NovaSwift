# NOVA Swift — Controls Editor controller: the procedurally drawn pad (ControllerArt) centred in the
# view with Steam-"controller configuration" style callouts — a leader line from every control out to
# a label in the left / right margin naming its bound action (fixed stick / trigger roles greyed).
# Every bindable control is a focusable PadHit (Godot focus navigation reaches it; A activates).
# Pressing a physical button lights the matching control on the art, capturing or not.
extends Control

const T = preload("res://ui/novaswift/NovaTheme.gd")
const Art = preload("res://screens/controls_editor/ControllerArt.gd")
const Model = preload("res://screens/controls_editor/EditorModel.gd")
const Controls = preload("res://Controls.gd")

signal control_pressed(id: int)
signal control_hover(id: int, on: bool)

const AMBER := Color(1.0, 0.7, 0.28)

var style := "xbox"
var group := "Flight"
var hits: Dictionary = {}           # id -> PadHit
var lay: Dictionary = {}

var _pad: Dictionary = {}           # JoyButton -> Array of actions
var _pulse: Dictionary = {}
var _highlight: Dictionary = {}
var _selected: Variant = null
var _xf := Vector2.ONE              # art scale
var _origin := Vector2.ZERO
var _margin := 200.0
var _callouts: Array = []


class PadHit extends Button:
	var id: Variant = 0
	var kind := "circle"
	var bindable := true
	var acts: Array = []
	var tint := Color(0, 0, 0, 0)
	var pulse := false
	var hl := false
	var sel := false
	var live := false

	func _init() -> void:
		flat = true
		for s in ["normal", "hover", "pressed", "hover_pressed", "focus", "disabled"]:
			add_theme_stylebox_override(s, StyleBoxEmpty.new())
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	func _shape(grow: float, col: Color, fill: Color, bw: int) -> void:
		var r := Rect2(Vector2.ZERO, size).grow(grow)
		var rad := int(minf(r.size.x, r.size.y) * 0.5) if kind == "circle" else int(minf(r.size.x, r.size.y) * 0.3)
		draw_style_box(T.box(fill, rad, col, bw), r)

	func _draw() -> void:
		if not bindable:
			if is_hovered():
				_shape(0.0, Color(1, 1, 1, 0.25), Color(1, 1, 1, 0.04), 1)
			return
		if not acts.is_empty():
			_shape(2.0, Color(tint.r, tint.g, tint.b, 0.95), Color(0, 0, 0, 0), 3)
		if live:
			_shape(0.0, Color(1, 0.85, 0.4, 0.9), Color(1, 0.8, 0.3, 0.45), 2)
		if hl:
			_shape(4.0, AMBER, Color(0, 0, 0, 0), 2)
		if sel:
			_shape(5.0, AMBER, Color(1, 0.7, 0.28, 0.16), 3)
		if pulse:
			var a := 0.5 + 0.5 * sin(float(Time.get_ticks_msec()) / 160.0)
			_shape(5.0, Color(1, 0.8, 0.4, 0.4 + 0.6 * a), Color(1, 0.7, 0.28, 0.10 + 0.25 * a), 3)
		if has_focus():
			_shape(7.0, Color(1, 1, 1, 0.95), Color(1, 1, 1, 0.05), 2)
		elif is_hovered():
			_shape(3.0, Color(1, 1, 1, 0.55), Color(1, 1, 1, 0.06), 1)


func _ready() -> void:
	resized.connect(_layout)
	set_style(Model.pad_style())


func set_style(s: String) -> void:
	style = s
	lay = Art.layout(s)
	for h in hits.values():
		remove_child(h)
		h.queue_free()
	hits.clear()
	for c in lay.controls:
		var h := PadHit.new()
		h.id = c.id
		h.kind = str(c.kind)
		h.bindable = bool(c.bindable)
		h.set_meta("c", c)
		h.focus_mode = Control.FOCUS_ALL if h.bindable else Control.FOCUS_NONE
		if h.bindable:
			var cid: int = int(c.id)
			h.pressed.connect(func(): control_pressed.emit(cid))
			h.mouse_entered.connect(func(): control_hover.emit(cid, true))
			h.mouse_exited.connect(func(): control_hover.emit(cid, false))
			h.focus_entered.connect(func(): control_hover.emit(cid, true))
			h.focus_exited.connect(func(): control_hover.emit(cid, false))
		add_child(h)
		hits[c.id] = h
	_layout()
	_apply()


func set_group(g: String) -> void:
	group = g
	refresh()


## Re-read the group's pad bindings from Controls.
func refresh() -> void:
	_pad = Model.pad_map(group)
	_apply()


func set_pulse(ids: Dictionary) -> void:
	_pulse = ids
	_apply()


func set_highlight(ids: Dictionary) -> void:
	_highlight = ids
	_apply()


func set_selected(id: Variant) -> void:
	_selected = id
	_apply()


func _apply() -> void:
	for id in hits:
		var h: PadHit = hits[id]
		if h.bindable:
			h.acts = _pad.get(int(id), [])
			h.tint = Model.cat_color(str(h.acts[0])) if not h.acts.is_empty() else Color(0, 0, 0, 0)
			h.pulse = _pulse.has(int(id))
			h.hl = _highlight.has(int(id))
			h.sel = _selected != null and _selected == id
			var names: Array = []
			for a in h.acts:
				names.append(Model.label_of(str(a)))
			h.tooltip_text = "%s - %s" % [(h.get_meta("c") as Dictionary).name, ", ".join(names) if not names.is_empty() else "unbound"]
		else:
			var c: Dictionary = h.get_meta("c")
			h.tooltip_text = _fixed_text(c) if str(c.role) != "steam" else "%s - set in Steam Input (not bindable here)" % c.name
		h.queue_redraw()
	_build_callouts()
	queue_redraw()


func _fixed_text(c: Dictionary) -> String:
	var role := str(c.role)
	if role == "" or role == "steam":
		return ""
	return str((Art.FIXED_ROLES.get(group, {}) as Dictionary).get(role, ""))


func _layout() -> void:
	if lay.is_empty():
		return
	_margin = clampf(size.x * 0.21, 150.0, 270.0)
	var art_w := maxf(200.0, size.x - _margin * 2.0)
	var s := minf(art_w / Art.SIZE.x, (size.y - 16.0) / Art.SIZE.y)
	_xf = Vector2(s, s)
	_origin = Vector2((size.x - Art.SIZE.x * s) * 0.5, (size.y - Art.SIZE.y * s) * 0.5)
	for id in hits:
		var h: PadHit = hits[id]
		var c: Dictionary = h.get_meta("c")
		var sz: Vector2 = (c.size as Vector2) * s
		var pad := Vector2(6, 6)
		h.size = sz + pad
		h.position = _origin + (c.c as Vector2) * s - h.size * 0.5
	_build_callouts()
	queue_redraw()


func _tint_of(c: Dictionary) -> Color:
	var acts: Array = _pad.get(int(c.id), []) if c.bindable else []
	return Model.cat_color(str(acts[0])) if not acts.is_empty() else Color(1, 1, 1, 0.3)


func _build_callouts() -> void:
	_callouts.clear()
	if lay.is_empty():
		return
	for side in ["L", "R"]:
		var items: Array = []
		for c in lay.controls:
			if str(c.side) == side:
				items.append(c)
		items.sort_custom(func(a: Dictionary, b: Dictionary): return (a.c as Vector2).y < (b.c as Vector2).y \
			or ((a.c as Vector2).y == (b.c as Vector2).y and (a.c as Vector2).x < (b.c as Vector2).x))
		var n := items.size()
		if n == 0:
			continue
		var slot := minf(46.0, (size.y - 12.0) / float(n))
		var ys: Array = []
		for c in items:
			ys.append(_origin.y + (c.c as Vector2).y * _xf.y)
		# spread so labels never overlap: forward pass then pull back from the bottom edge
		for i in n:
			var lo: float = 8.0 + slot * 0.5 + slot * i if i == 0 else float(ys[i - 1]) + slot
			ys[i] = maxf(float(ys[i]), lo if i > 0 else 6.0 + slot * 0.5)
		var over: float = float(ys[n - 1]) - (size.y - 6.0 - slot * 0.5)
		if over > 0.0:
			for i in range(n - 1, -1, -1):
				var hi: float = size.y - 6.0 - slot * 0.5 if i == n - 1 else float(ys[i + 1]) - slot
				ys[i] = minf(float(ys[i]), hi)
		for i in n:
			var c: Dictionary = items[i]
			var cp: Vector2 = _origin + (c.c as Vector2) * _xf.x
			var rad := (c.size as Vector2) * _xf.x * 0.5
			var edge_x: float = (_margin - 14.0) if side == "L" else (size.x - _margin + 14.0)
			var tgt := Vector2(cp.x - rad.x * 0.8 if side == "L" else cp.x + rad.x * 0.8, cp.y)
			_callouts.append({"c": c, "side": side, "y": float(ys[i]), "edge": edge_x, "target": tgt, "slot": slot})


func _action_text(c: Dictionary) -> String:
	if bool(c.bindable):
		var acts: Array = _pad.get(int(c.id), [])
		if acts.is_empty():
			return ""
		var names: Array = []
		for a in acts:
			names.append(Model.label_of(str(a)))
		return " / ".join(names)
	return _fixed_text(c) if str(c.role) != "steam" else "Set in Steam Input"


func _draw() -> void:
	if lay.is_empty():
		return
	draw_set_transform(_origin, 0.0, _xf)
	Art.draw(self, style)
	draw_set_transform_matrix(Transform2D.IDENTITY)
	var f1 := T.font("caption", "semibold")
	var f2 := T.font("caption", "medium")
	for co in _callouts:
		var c: Dictionary = co.c
		var left: bool = co.side == "L"
		var bindable: bool = c.bindable
		var tint := _tint_of(c)
		var text := _action_text(c)
		var dim := not bindable or text == ""
		var ly: float = co.y
		var edge: float = co.edge
		var tgt: Vector2 = co.target
		var lcol := Color(tint.r, tint.g, tint.b, 0.55 if dim else 0.85)
		var knee := Vector2(edge + (14.0 if left else -14.0), ly)
		draw_polyline(PackedVector2Array([Vector2(edge, ly), knee, tgt]), lcol, 1.5, true)
		draw_circle(tgt, 3.0, lcol)
		var wmax := _margin - 22.0
		var align := HORIZONTAL_ALIGNMENT_RIGHT if left else HORIZONTAL_ALIGNMENT_LEFT
		var x0 := edge - wmax - 4.0 if left else edge + 6.0
		var name_col := Color(tint.r, tint.g, tint.b, 0.6 if dim else 1.0).lerp(Color.WHITE, 0.25)
		draw_string(f1, Vector2(x0, ly - 3.0), str(c.name), align, wmax, 12, name_col)
		var shown := text if text != "" else ("Unbound" if bindable else "")
		var fs := 13
		while fs > 9 and f2.get_string_size(shown, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > wmax:
			fs -= 1
		while shown.length() > 4 and f2.get_string_size(shown, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > wmax:
			shown = shown.substr(0, shown.length() - 2)
			if f2.get_string_size(shown + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x <= wmax:
				shown += "…"
				break
		draw_string(f2, Vector2(x0, ly + 12.0), shown, align, wmax, fs,
			Color(1, 1, 1, 0.38) if dim else Color(1, 1, 1, 0.96))
		# a stick's fixed role rides under its L3 / R3 line
		if bindable and str(c.role) in ["ls", "rs"]:
			var role := _fixed_text(c)
			if role != "":
				draw_string(f2, Vector2(x0, ly + 25.0), "Stick: " + role, align, wmax, 10, Color(1, 1, 1, 0.34))


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	var devs := Input.get_connected_joypads()
	for id in hits:
		var h: PadHit = hits[id]
		var on := false
		if typeof(id) == TYPE_INT:
			for d in devs:
				if Input.is_joy_button_pressed(d, int(id) as JoyButton):
					on = true
			if int(id) == JOY_BUTTON_LEFT_STICK or int(id) == JOY_BUTTON_RIGHT_STICK:
				var ax := JOY_AXIS_LEFT_X if int(id) == JOY_BUTTON_LEFT_STICK else JOY_AXIS_RIGHT_X
				for d in devs:
					if Vector2(Input.get_joy_axis(d, ax as JoyAxis), Input.get_joy_axis(d, (ax + 1) as JoyAxis)).length() > 0.45:
						on = true
		elif id == "lt" or id == "rt":
			var axis := JOY_AXIS_TRIGGER_LEFT if id == "lt" else JOY_AXIS_TRIGGER_RIGHT
			for d in devs:
				if Input.get_joy_axis(d, axis as JoyAxis) > 0.3:
					on = true
		if on != h.live:
			h.live = on
			h.queue_redraw()
		elif h.pulse:
			h.queue_redraw()
