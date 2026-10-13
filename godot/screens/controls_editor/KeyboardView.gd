# NOVA Swift — Controls Editor keyboard: procedurally drawn keycaps (no bitmap art) laid out from
# KeyboardLayouts, one focusable KeyCap per key so pad / Steam Deck focus navigation reaches every
# key (Godot's geometric focus search walks the grid). A cap shows its legend (top-left) and the bound
# action's short name (centre, auto-shrinking, max 2 lines), tinted by the action's category.
#
# Emits key_pressed(code) on click / A / Enter and key_hover(code, on) on mouse-over / focus.
extends Control

const T = preload("res://ui/novaswift/NovaTheme.gd")
const Layouts = preload("res://screens/controls_editor/KeyboardLayouts.gd")
const Model = preload("res://screens/controls_editor/EditorModel.gd")

signal key_pressed(code: int)
signal key_hover(code: int, on: bool)

const MARGIN := 4.0

var caps: Array = []
var preset := "full"
var board := Vector2(15, 5)

var _info: Dictionary = {}          # code -> {acts: Array, tint: Color, dot: bool}
var _pulse: Dictionary = {}         # code -> true  (action-first target keys)
var _highlight: Dictionary = {}     # code -> true  (row hover)
var _selected := -999
var _layout_keys: Array = []


class KeyCap extends Control:
	signal pressed
	const AMBER := Color(1.0, 0.7, 0.28)
	var code := -1
	var legend := ""
	var locked := false
	var rects: Array = []           # local Rect2s (one, or two for an L-shaped key)
	var unit := 48.0
	var acts: Array = []
	var tint := Color(0, 0, 0, 0)
	var dot := false
	var pulse := false
	var hl := false
	var sel := false
	var hot := false                # the physical key is down right now
	var hovered := false

	func _init() -> void:
		focus_mode = Control.FOCUS_ALL
		clip_contents = true        # nothing a cap draws can ever leave its own cell
		mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND

	func _notification(what: int) -> void:
		if what == NOTIFICATION_MOUSE_ENTER:
			hovered = true
			queue_redraw()
		elif what == NOTIFICATION_MOUSE_EXIT:
			hovered = false
			queue_redraw()
		elif what == NOTIFICATION_FOCUS_ENTER or what == NOTIFICATION_FOCUS_EXIT:
			queue_redraw()

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
			pressed.emit()
			accept_event()
		elif event.is_action_pressed("ui_accept"):
			pressed.emit()
			accept_event()

	func _short_text() -> String:
		if acts.is_empty():
			return ""
		var s: String = Model.short_label(str(acts[0]))
		if acts.size() > 1:
			s += " +%d" % (acts.size() - 1)
		return s

	func _draw() -> void:
		if rects.is_empty():
			return
		var gap := maxf(1.0, unit * 0.04)
		var bound := not acts.is_empty()
		var face_col := Color(0.165, 0.17, 0.19)
		if bound:
			face_col = Color(0.11, 0.115, 0.13).lerp(tint, 0.5)
		if locked:
			face_col = Color(0.10, 0.10, 0.11)
		var base_col := face_col.darkened(0.5)
		var rad := int(unit * 0.12)
		var faces: Array = []
		for r in rects:
			var cell: Rect2 = (r as Rect2).grow(-gap)
			draw_style_box(T.box(base_col, rad), cell)
			var face := Rect2(cell.position + Vector2(unit * 0.03, unit * 0.03), cell.size - Vector2(unit * 0.06, unit * 0.11))
			faces.append(face)
			draw_style_box(T.box(face_col, rad, face_col.lightened(0.25), 1), face)
		var f: Rect2 = faces[0]
		if locked:
			var x := f.position.x - f.size.y
			while x < f.end.x:
				var a := Vector2(clampf(x, f.position.x, f.end.x), f.end.y)
				var b := Vector2(clampf(x + f.size.y, f.position.x, f.end.x), f.position.y)
				draw_line(a, b, Color(1, 1, 1, 0.08), 1.0)
				x += maxf(5.0, unit * 0.18)
		var font := T.font("caption", "semibold")
		var lfs := int(clampf(unit * 0.21, 8.0, 13.0))
		var lcol := Color(1, 1, 1, 0.8 if bound else 0.5)
		if f.size.y < unit * 0.8:
			var sz := font.get_string_size(legend, HORIZONTAL_ALIGNMENT_LEFT, -1, lfs)
			draw_string(font, Vector2(f.position.x + (f.size.x - sz.x) * 0.5, f.position.y + (f.size.y + sz.y * 0.62) * 0.5),
				legend, HORIZONTAL_ALIGNMENT_LEFT, -1, lfs, Color(1, 1, 1, 0.95) if bound else lcol)
		else:
			draw_string(font, f.position + Vector2(unit * 0.08, lfs + unit * 0.02), legend,
				HORIZONTAL_ALIGNMENT_LEFT, f.size.x - 4.0, lfs, lcol)
			if bound:
				var text := _short_text()
				var big: Rect2 = faces[0]
				for fc in faces:
					var fcr: Rect2 = fc
					if fcr.size.x * fcr.size.y > big.size.x * big.size.y:
						big = fcr
				var top := big.position.y + lfs + unit * 0.06
				var avail := Rect2(Vector2(big.position.x + 3.0, top), Vector2(big.size.x - 6.0, big.end.y - top - 2.0))
				var afont := T.font("caption", "semibold")
				var fs := int(clampf(unit * 0.25, 9.0, 16.0))
				var sz2 := Vector2.ZERO
				while true:
					sz2 = afont.get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_CENTER, avail.size.x, fs, 2)
					if (sz2.y <= avail.size.y + 1.0 and sz2.x <= avail.size.x + 1.0) or fs <= 8:
						break
					fs -= 1
				var py := avail.position.y + (avail.size.y - sz2.y) * 0.5 + afont.get_ascent(fs)
				draw_multiline_string(afont, Vector2(avail.position.x, py), text, HORIZONTAL_ALIGNMENT_CENTER,
					avail.size.x, fs, 2, Color(1, 1, 1, 0.98))
		if dot:
			draw_circle(Vector2(f.end.x - unit * 0.13, f.end.y - unit * 0.13), maxf(2.0, unit * 0.06), Color(1, 1, 1, 0.7))
		# live press / row hover / selection / pulse / focus: all strokes and fills INSIDE the cap's face
		for fc in faces:
			var fr: Rect2 = fc
			if hot:
				draw_style_box(T.box(Color(1, 0.85, 0.4, 0.35), rad), fr)
			if hl:
				draw_style_box(T.box(Color(0, 0, 0, 0), rad, AMBER, 2), fr)
			if sel:
				draw_style_box(T.box(Color(1, 0.7, 0.28, 0.16), rad, AMBER, 3), fr)
			if pulse:
				var pa := 0.5 + 0.5 * sin(float(Time.get_ticks_msec()) / 160.0)
				draw_style_box(T.box(Color(1, 0.7, 0.28, 0.10 + 0.25 * pa), rad, Color(1, 0.8, 0.4, 0.4 + 0.6 * pa), 3), fr)
			if has_focus():
				draw_style_box(T.box(Color(1, 1, 1, 0.06), rad, Color(1, 1, 1, 0.95), 2), fr)
			elif hovered and not hl:
				draw_style_box(T.box(Color(1, 1, 1, 0.07), rad, Color(1, 1, 1, 0.5), 1), fr)


func _ready() -> void:
	resized.connect(_layout)
	set_layout(Model.preset())


func set_layout(p: String) -> void:
	preset = p
	var b: Dictionary = Layouts.build(p)
	_layout_keys = b.keys
	board = b.size
	for c in caps:
		remove_child(c)
		c.queue_free()
	caps.clear()
	for k in _layout_keys:
		var cap := KeyCap.new()
		cap.code = int(k.code)
		cap.legend = str(k.label)
		cap.locked = bool(k.get("locked", false))
		cap.set_meta("k", k)
		cap.pressed.connect(_on_cap_pressed.bind(cap))
		cap.mouse_entered.connect(func(): key_hover.emit(cap.code, true))
		cap.mouse_exited.connect(func(): key_hover.emit(cap.code, false))
		cap.focus_entered.connect(func(): key_hover.emit(cap.code, true))
		cap.focus_exited.connect(func(): key_hover.emit(cap.code, false))
		add_child(cap)
		caps.append(cap)
	_layout()
	_apply_info()


func _on_cap_pressed(cap: KeyCap) -> void:
	if cap.code >= 0:
		key_pressed.emit(cap.code)


func _layout() -> void:
	if caps.is_empty():
		return
	var avail := size - Vector2(MARGIN, MARGIN) * 2.0
	var u := maxf(8.0, minf(avail.x / board.x, avail.y / board.y))
	var origin := (size - board * u) * 0.5
	for cap in caps:
		var k: Dictionary = cap.get_meta("k")
		var rect := Rect2(origin + Vector2(float(k.x), float(k.y)) * u, Vector2(float(k.w), float(k.h)) * u)
		var rects: Array = [Rect2(Vector2.ZERO, rect.size)]
		var bounds := rect
		if k.has("ext"):
			var e: Rect2 = k.ext
			var er := Rect2(origin + e.position * u, e.size * u)
			bounds = bounds.merge(er)
			rects = [Rect2(rect.position - bounds.position, rect.size), Rect2(er.position - bounds.position, er.size)]
		cap.position = bounds.position
		cap.size = bounds.size
		cap.rects = rects
		cap.unit = u
		cap.queue_redraw()


## info: code -> {acts: Array, tint: Color, dot: bool}
func set_info(info: Dictionary) -> void:
	_info = info
	_apply_info()


func _apply_info() -> void:
	for cap in caps:
		var i: Dictionary = _info.get(cap.code, {})
		cap.acts = i.get("acts", [])
		cap.tint = i.get("tint", Color(0, 0, 0, 0))
		cap.dot = bool(i.get("dot", false))
		cap.pulse = _pulse.has(cap.code)
		cap.hl = _highlight.has(cap.code)
		cap.sel = cap.code == _selected
		if cap.locked:
			cap.tooltip_text = "fn is handled by the hardware; games cannot read it."
		elif cap.acts.is_empty():
			cap.tooltip_text = "%s - unbound%s" % [Model.key_name(cap.code), " (bound on another layer)" if cap.dot else ""]
		else:
			var names: Array = []
			for a in cap.acts:
				names.append(Model.label_of(str(a)))
			cap.tooltip_text = "%s - %s" % [Model.key_name(cap.code), ", ".join(names)]
		cap.queue_redraw()


func set_pulse(codes: Dictionary) -> void:
	_pulse = codes
	_apply_info()


func set_highlight(codes: Dictionary) -> void:
	_highlight = codes
	_apply_info()


func set_selected(code: int) -> void:
	_selected = code
	_apply_info()


func cap_for(code: int) -> Control:
	for c in caps:
		if c.code == code:
			return c
	return null


func has_code(code: int) -> bool:
	return cap_for(code) != null


func _process(_delta: float) -> void:
	if not is_visible_in_tree():
		return
	for cap in caps:
		var down: bool = cap.code >= 0 and Input.is_physical_key_pressed(cap.code as Key)
		if down != cap.hot:
			cap.hot = down
			cap.queue_redraw()
		elif cap.pulse:
			cap.queue_redraw()
