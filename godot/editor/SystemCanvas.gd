# Star-system canvas: the system's stellars around its centre, distance rings, drag to move,
# double-click opens the stellar's record.
extends "res://editor/EditorCanvas.gd"

signal selected(id: int)
signal opened(id: int)
signal moved(id: int, x: int, y: int)

var info := {}
var selected_id := -1
var _hover := -1
var _drag := -1
var _drag_from := Vector2.ZERO
var _drag_moved := false


func set_info(d: Dictionary) -> void:
	info = d
	queue_redraw()


func content_rect() -> Rect2:
	var r := Rect2(-600, -600, 1200, 1200)
	for sp in info.get("stellars", []):
		r = r.expand(_pos(sp) * 1.15)
	return r


func _pos(sp: Dictionary) -> Vector2:
	return Vector2(float(sp.get("x", 0)), float(sp.get("y", 0)))


func _stellar(id: int) -> Dictionary:
	for sp in info.get("stellars", []):
		if int(sp.get("id", -1)) == id:
			return sp
	return {}


func _hit(p: Vector2) -> int:
	var best := -1
	var best_d := 16.0
	for sp in info.get("stellars", []):
		var d := p.distance_to(to_screen(_pos(sp)))
		if d < best_d:
			best_d = d
			best = int(sp.get("id", -1))
	return best


func _gui_input(event: InputEvent) -> void:
	if handle_view_input(event):
		accept_event()
		return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		if _drag >= 0 and mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			if not _drag_moved and mm.position.distance_to(_drag_from) < 4.0:
				return
			_drag_moved = true
			var sp := _stellar(_drag)
			var w := to_world(mm.position)
			sp["x"] = int(round(w.x))
			sp["y"] = int(round(w.y))
			mouse_default_cursor_shape = Control.CURSOR_MOVE
		else:
			var h := _hit(mm.position)
			if h != _hover:
				_hover = h
				mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if h >= 0 else Control.CURSOR_ARROW
		queue_redraw()
	elif event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		var hit := _hit(mb.position)
		if mb.pressed:
			if mb.double_click and hit >= 0:
				opened.emit(hit)
				return
			if hit >= 0:
				selected_id = hit
				selected.emit(hit)
				_drag = hit
				_drag_from = mb.position
				_drag_moved = false
			else:
				begin_pan(MOUSE_BUTTON_LEFT)
			queue_redraw()
		else:
			if _drag >= 0 and _drag_moved:
				var sp := _stellar(_drag)
				moved.emit(_drag, int(sp.get("x", 0)), int(sp.get("y", 0)))
			_drag = -1
			_drag_moved = false
			mouse_default_cursor_shape = Control.CURSOR_ARROW


func _draw() -> void:
	draw_rect(Rect2(Vector2.ZERO, size), EdTheme.CANVAS, true)
	var tint := Color(int(info.get("r", 0)) / 255.0, int(info.get("g", 0)) / 255.0, int(info.get("b", 0)) / 255.0)
	if tint != Color.BLACK:
		draw_rect(Rect2(Vector2.ZERO, size), Color(tint.r, tint.g, tint.b, 0.25), true)
	var c := to_screen(Vector2.ZERO)
	for ring in [250, 500, 1000, 1500, 2000, 3000]:
		var rr := float(ring) * zoom
		if rr < 18 or rr > size.length():
			continue
		draw_arc(c, rr, 0, TAU, 96, Color(1, 1, 1, 0.07), 1.0, true)
		text(c + Vector2(rr + 4, -4), str(ring), 10, Color(1, 1, 1, 0.25))
	draw_line(c + Vector2(-10, 0), c + Vector2(10, 0), Color(1, 1, 1, 0.3), 1.0)
	draw_line(c + Vector2(0, -10), c + Vector2(0, 10), Color(1, 1, 1, 0.3), 1.0)

	for sp in info.get("stellars", []):
		var p := to_screen(_pos(sp))
		var sid := int(sp.get("id", -1))
		var r := 9.0
		draw_circle(p, r + 2, Color(0, 0, 0, 0.6))
		draw_circle(p, r, Color(0.55, 0.7, 0.95) if int(sp.get("govt", -1)) < 0 else Color(0.85, 0.85, 0.9))
		draw_circle(p - Vector2(3, 3), r * 0.35, Color(1, 1, 1, 0.35))
		if sid == selected_id:
			draw_arc(p, r + 5, 0, TAU, 32, EdTheme.AMBER, 2.0, true)
		elif sid == _hover:
			draw_arc(p, r + 5, 0, TAU, 32, Color(1, 1, 1, 0.5), 1.5, true)
		text(p + Vector2(r + 7, 4), str(sp.get("name", "")), 12, EdTheme.TEXT, "semibold" if sid == selected_id else "regular")

	if _hover >= 0 and _drag < 0:
		var h := _stellar(_hover)
		bubble(to_screen(_pos(h)), [str(h.get("name", "")), "Stellar #%d  ·  (%d, %d)" % [_hover, int(h.get("x", 0)), int(h.get("y", 0))], "Drag to move  ·  double-click to edit"])
