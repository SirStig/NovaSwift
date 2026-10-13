# NOVA Swift — Controls Editor controller: the procedurally drawn pad (ControllerArt, millimetres)
# centred in the view with Steam-"controller configuration" style callouts: every control gets a label in
# the left / right margin (side by the control's x, sorted by y, spread with a minimum spacing) joined by
# an elbow leader — horizontal from the label to a column just outside the body, then one straight
# segment to the control — so leaders never cross. Bound controls are tinted by their action's category
# on their own shape; focus / selection are strokes on that same shape.
#
# Every bindable control has an invisible focusable Hit (Godot focus navigation reaches it; A activates;
# the mouse hit-tests the control's real outline). Pressing a physical button lights it on the art.
extends Control

const T = preload("res://ui/novaswift/NovaTheme.gd")
const Art = preload("res://screens/controls_editor/ControllerArt.gd")
const Model = preload("res://screens/controls_editor/EditorModel.gd")
const Controls = preload("res://Controls.gd")

signal control_pressed(id: int)
signal control_hover(id: int, on: bool)

## The pad's body takes this share of the view width (the rest is callout margin).
const PAD_SHARE := 0.60

var style := "xbox"
var group := "Flight"
var hits: Dictionary = {}           # id -> Hit
var lay: Dictionary = {}
var callouts: Array = []            # {c, side, y, line: PackedVector2Array, edge, text_w}

var _pad: Dictionary = {}           # JoyButton -> Array of actions
var _pulse: Dictionary = {}
var _highlight: Dictionary = {}
var _selected: Variant = null
var _focus_id: Variant = null
var _hover_id: Variant = null
var _live: Dictionary = {}
var _s := 1.0                       # px per mm
var _origin := Vector2.ZERO


class Hit extends Control:
	signal pressed
	var id: Variant = 0
	var poly: PackedVector2Array = PackedVector2Array()   # local px outline

	func _init() -> void:
		focus_mode = Control.FOCUS_ALL
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	func _has_point(p: Vector2) -> bool:
		return poly.size() >= 3 and Geometry2D.is_point_in_polygon(p, poly)

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			pressed.emit()
			accept_event()
		elif event.is_action_pressed("ui_accept"):
			pressed.emit()
			accept_event()


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
		var h := Hit.new()
		h.id = c.id
		h.set_meta("c", c)
		if bool(c.bindable):
			h.focus_mode = Control.FOCUS_ALL
			var cid: int = int(c.id)
			h.pressed.connect(func(): control_pressed.emit(cid))
			h.mouse_entered.connect(func(): _set_hover(cid, true))
			h.mouse_exited.connect(func(): _set_hover(cid, false))
			h.focus_entered.connect(func(): _set_focus(cid, true))
			h.focus_exited.connect(func(): _set_focus(cid, false))
		else:
			h.focus_mode = Control.FOCUS_NONE
			h.mouse_entered.connect(queue_redraw)
		add_child(h)
		hits[c.id] = h
	_layout()
	_apply()


func _set_hover(id: int, on: bool) -> void:
	_hover_id = id if on else null
	control_hover.emit(id, on)
	queue_redraw()


func _set_focus(id: int, on: bool) -> void:
	_focus_id = id if on else (null if _focus_id == id else _focus_id)
	control_hover.emit(id, on)
	queue_redraw()


func set_group(g: String) -> void:
	group = g
	refresh()


## Re-read the group's pad bindings from Controls.
func refresh() -> void:
	_pad = Model.pad_map(group)
	_apply()


func set_pulse(ids: Dictionary) -> void:
	_pulse = ids
	queue_redraw()


func set_highlight(ids: Dictionary) -> void:
	_highlight = ids
	queue_redraw()


func set_selected(id: Variant) -> void:
	_selected = id
	queue_redraw()


func _apply() -> void:
	for id in hits:
		var h: Hit = hits[id]
		var c: Dictionary = h.get_meta("c")
		if bool(c.bindable):
			var acts: Array = _pad.get(int(id), [])
			var names: Array = []
			for a in acts:
				names.append(Model.label_of(str(a)))
			h.tooltip_text = "%s - %s" % [c.name, ", ".join(names) if not names.is_empty() else "unbound"]
		else:
			h.tooltip_text = _fixed_text(c) if str(c.role) != "steam" else "%s - set in Steam Input (not bindable here)" % c.name
	_build_callouts()
	queue_redraw()


func _fixed_text(c: Dictionary) -> String:
	var role := str(c.role)
	if role == "" or role == "steam":
		return ""
	return str((Art.FIXED_ROLES.get(group, {}) as Dictionary).get(role, ""))


# --- layout --------------------------------------------------------------------------------------

func _layout() -> void:
	if lay.is_empty() or size.x < 10.0:
		return
	var body: Rect2 = lay.body
	var ext: Rect2 = lay.extent
	_s = minf(PAD_SHARE * size.x / body.size.x, (size.y - 16.0) / ext.size.y)
	_origin = Vector2(size.x * 0.5, size.y * 0.5) - Vector2(0.0, ext.get_center().y * _s)
	for id in hits:
		var h: Hit = hits[id]
		var c: Dictionary = h.get_meta("c")
		var bb: Rect2 = c.bbox
		h.position = _origin + bb.position * _s
		h.size = bb.size * _s
		var pp := PackedVector2Array()
		for p in c.outline:
			pp.append((p - bb.position) * _s)
		h.poly = pp
	_build_callouts()
	queue_redraw()


## The body's rectangle in view pixels.
func pad_rect_px() -> Rect2:
	var body: Rect2 = lay.body
	return Rect2(_origin + body.position * _s, body.size * _s)


static func _legs_cross(a: Vector2, b: Vector2, c: Vector2, d: Vector2) -> bool:
	var o1 := (b - a).cross(c - a)
	var o2 := (b - a).cross(d - a)
	var o3 := (d - c).cross(a - c)
	var o4 := (d - c).cross(b - c)
	return o1 * o2 < 0.0 and o3 * o4 < 0.0


func _tint_of(c: Dictionary) -> Color:
	var acts: Array = _pad.get(int(c.id), []) if bool(c.bindable) else []
	return Model.cat_color(str(acts[0])) if not acts.is_empty() else Color(1, 1, 1, 0.3)


func _build_callouts() -> void:
	callouts.clear()
	if lay.is_empty() or size.x < 10.0:
		return
	var pr := pad_rect_px()
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
		var slot := minf(40.0, (size.y - 12.0) / float(n))
		var lo := 8.0 + slot * 0.5
		var hi := size.y - 8.0 - slot * 0.5
		var ys: Array = []
		for c in items:
			ys.append(clampf(_origin.y + (c.c as Vector2).y * _s, lo, hi))
		for i in range(1, n):
			ys[i] = maxf(float(ys[i]), float(ys[i - 1]) + slot)
		if float(ys[n - 1]) > hi:
			ys[n - 1] = hi
			for i in range(n - 2, -1, -1):
				ys[i] = minf(float(ys[i]), float(ys[i + 1]) - slot)
		var xc := pr.position.x - 16.0 if side == "L" else pr.end.x + 16.0
		# Untangle: while two diagonal legs (label slot -> control) cross, swap their label slots. Swapping the
		# endpoints of a crossing pair strictly shortens the total length, so this terminates with no crossings.
		var anchors: Array = []
		for c in items:
			anchors.append(_origin + (c.c as Vector2) * _s)
		for _pass in 400:
			var swapped := false
			for i in n:
				for j in range(i + 1, n):
					if _legs_cross(Vector2(xc, float(ys[i])), anchors[i], Vector2(xc, float(ys[j])), anchors[j]):
						var t: float = ys[i]
						ys[i] = ys[j]
						ys[j] = t
						swapped = true
			if not swapped:
				break
		var edge := xc - 28.0 if side == "L" else xc + 28.0
		for i in n:
			var c: Dictionary = items[i]
			var anchor: Vector2 = _origin + (c.c as Vector2) * _s
			var ly: float = ys[i]
			var line := PackedVector2Array([Vector2(edge, ly), Vector2(xc, ly), anchor])
			var tw := (edge - 10.0) if side == "L" else (size.x - edge - 10.0)
			callouts.append({"c": c, "side": side, "y": ly, "line": line, "edge": edge, "text_w": maxf(40.0, tw)})


# --- drawing -------------------------------------------------------------------------------------

func _states() -> Dictionary:
	var st: Dictionary = {}
	var pulse := 0.5 + 0.5 * sin(float(Time.get_ticks_msec()) / 160.0)
	for id in hits:
		var h: Hit = hits[id]
		var c: Dictionary = h.get_meta("c")
		var s: Dictionary = {}
		if bool(c.bindable):
			var acts: Array = _pad.get(int(id), [])
			if not acts.is_empty():
				s["tint"] = Model.cat_color(str(acts[0]))
			if _pulse.has(int(id)):
				s["pulse"] = pulse
			if _highlight.has(int(id)):
				s["hover"] = true
			if _selected != null and _selected == id:
				s["sel"] = true
			if _focus_id != null and _focus_id == id:
				s["focus"] = true
			if _hover_id != null and _hover_id == id:
				s["hover"] = true
		if _live.get(id, false):
			s["live"] = true
		if not s.is_empty():
			st[id] = s
	return st


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
	var texts: Array = []
	draw_set_transform(_origin, 0.0, Vector2(_s, _s))
	Art.draw(self, style, _states(), 1.0 / _s, texts)
	draw_set_transform_matrix(Transform2D.IDENTITY)
	var bold := T.font("body", "bold")
	for t in texts:
		var fs := int(maxf(8.0, float(t.size) * _s))
		var w := bold.get_string_size(str(t.text), HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		var p: Vector2 = _origin + (t.pos as Vector2) * _s
		draw_string(bold, p + Vector2(-w.x * 0.5, fs * 0.35), str(t.text), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, t.col)
	var f1 := T.font("caption", "semibold")
	var f2 := T.font("caption", "medium")
	for co in callouts:
		var c: Dictionary = co.c
		var left: bool = co.side == "L"
		var bindable: bool = c.bindable
		var tint := _tint_of(c)
		var text := _action_text(c)
		var dim := not bindable or text == ""
		var line: PackedVector2Array = co.line
		var lcol := Color(tint.r, tint.g, tint.b, 0.5 if dim else 0.85)
		draw_polyline(line, lcol, 1.5, true)
		draw_circle(line[2], 3.0, lcol)
		var wmax: float = co.text_w
		var align := HORIZONTAL_ALIGNMENT_RIGHT if left else HORIZONTAL_ALIGNMENT_LEFT
		var x0: float = (co.edge - wmax - 4.0) if left else (co.edge + 6.0)
		var ly: float = co.y
		var name_col := Color(tint.r, tint.g, tint.b, 0.6 if dim else 1.0).lerp(Color.WHITE, 0.25)
		draw_string(f1, Vector2(x0, ly - 3.0), str(c.name), align, wmax, 12, name_col)
		var shown := text if text != "" else ("Unbound" if bindable else "")
		var fs2 := 13
		while fs2 > 9 and f2.get_string_size(shown, HORIZONTAL_ALIGNMENT_LEFT, -1, fs2).x > wmax:
			fs2 -= 1
		while shown.length() > 4 and f2.get_string_size(shown, HORIZONTAL_ALIGNMENT_LEFT, -1, fs2).x > wmax:
			shown = shown.substr(0, shown.length() - 2)
			if f2.get_string_size(shown + "…", HORIZONTAL_ALIGNMENT_LEFT, -1, fs2).x <= wmax:
				shown += "…"
				break
		draw_string(f2, Vector2(x0, ly + 12.0), shown, align, wmax, fs2,
			Color(1, 1, 1, 0.38) if dim else Color(1, 1, 1, 0.96))
		if bindable and str(c.role) in ["ls", "rs"]:
			var role := _fixed_text(c)
			if role != "":
				draw_string(f2, Vector2(x0, ly + 24.0), "Stick: " + role, align, wmax, 10, Color(1, 1, 1, 0.34))


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	var devs := Input.get_connected_joypads()
	var changed_any := not _pulse.is_empty()
	for id in hits:
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
		if on != bool(_live.get(id, false)):
			_live[id] = on
			changed_any = true
	if changed_any:
		queue_redraw()
