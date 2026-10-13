# Galaxy map canvas: every sÿst at its map position, hyperlinks, nebulae. Select / drag systems,
# link mode toggles a hyperlink between two clicked systems, double-click opens the system.
extends "res://editor/EditorCanvas.gd"

signal selected(id: int)
signal opened(id: int)
signal moved(id: int, x: int, y: int)
signal link_toggled(a: int, b: int, link: bool)

var data := {}
var mode := "select"            # "select" | "link"
var selected_id := -1
var highlight := ""             # name filter; matches are drawn bright, the rest dimmed

var _by_id := {}
var _hover := -1
var _drag := -1
var _drag_from := Vector2.ZERO
var _drag_moved := false
var _link_from := -1
var _mouse := Vector2.ZERO


func set_data(d: Dictionary) -> void:
	data = d
	_by_id.clear()
	var systems: Array = data.get("systems", [])
	for i in systems.size():
		_by_id[int(systems[i].get("id", -1))] = i
	queue_redraw()


func system(id: int) -> Dictionary:
	if not _by_id.has(id):
		return {}
	var systems: Array = data.get("systems", [])
	return systems[int(_by_id[id])]


func content_rect() -> Rect2:
	var systems: Array = data.get("systems", [])
	if systems.is_empty():
		return Rect2(-200, -200, 400, 400)
	var r := Rect2(_pos(systems[0]), Vector2.ZERO)
	for s in systems:
		r = r.expand(_pos(s))
	return r


func set_mode(m: String) -> void:
	mode = m
	_link_from = -1
	queue_redraw()


func focus_system(id: int) -> void:
	var s := system(id)
	if s.is_empty():
		return
	selected_id = id
	center_on(_pos(s), 1.6)


func _pos(s: Dictionary) -> Vector2:
	return Vector2(float(s.get("x", 0)), float(s.get("y", 0)))


func _hit(p: Vector2) -> int:
	var best := -1
	var best_d := 12.0
	for s in data.get("systems", []):
		var d := p.distance_to(to_screen(_pos(s)))
		if d < best_d:
			best_d = d
			best = int(s.get("id", -1))
	return best


func _gui_input(event: InputEvent) -> void:
	if handle_view_input(event):
		_hover = -1
		accept_event()
		return
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_mouse = mm.position
		if _drag >= 0 and mm.button_mask & MOUSE_BUTTON_MASK_LEFT:
			if not _drag_moved and mm.position.distance_to(_drag_from) < 4.0:
				return
			_drag_moved = true
			var s := system(_drag)
			var w := to_world(mm.position)
			s["x"] = int(round(w.x))
			s["y"] = int(round(w.y))
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
			grab_focus()
			if mb.double_click and hit >= 0:
				opened.emit(hit)
				return
			if mode == "link":
				if hit < 0:
					_link_from = -1
				elif _link_from < 0:
					_link_from = hit
				elif hit != _link_from:
					var linked: bool = (system(_link_from).get("links", []) as Array).has(float(hit)) or (system(_link_from).get("links", []) as Array).has(hit)
					link_toggled.emit(_link_from, hit, not linked)
					_link_from = hit if mb.shift_pressed else -1
				queue_redraw()
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
				var s := system(_drag)
				moved.emit(_drag, int(s.get("x", 0)), int(s.get("y", 0)))
			_drag = -1
			_drag_moved = false
			mouse_default_cursor_shape = Control.CURSOR_ARROW


func _unhandled_key_input(event: InputEvent) -> void:
	if not visible or not has_focus():
		return
	var k := event as InputEventKey
	if k != null and k.pressed and k.keycode == KEY_ESCAPE and _link_from >= 0:
		_link_from = -1
		queue_redraw()
		get_viewport().set_input_as_handled()


func _draw() -> void:
	draw_backdrop(50.0)
	var systems: Array = data.get("systems", [])
	var q := highlight.strip_edges().to_lower()

	for neb in data.get("nebulae", []):
		var a := to_screen(Vector2(float(neb.get("x", 0)), float(neb.get("y", 0))))
		var b := to_screen(Vector2(float(neb.get("x", 0)) + float(neb.get("w", 0)), float(neb.get("y", 0)) + float(neb.get("h", 0))))
		var r := Rect2(a, b - a).abs()
		draw_style_box(T.box(Color(0.55, 0.4, 0.85, 0.10), int(minf(40.0, r.size.x * 0.2)), Color(0.65, 0.5, 0.95, 0.22), 1), r)
		if zoom > 0.35:
			text(r.position + Vector2(8, 16), str(neb.get("name", "")), 11, Color(0.75, 0.65, 1.0, 0.7))

	var sel := system(selected_id)
	var sel_links: Array = sel.get("links", []) if not sel.is_empty() else []
	for s in systems:
		var p := to_screen(_pos(s))
		var sid := int(s.get("id", 0))
		for lid in s.get("links", []):
			var other := int(lid)
			if other <= sid or not _by_id.has(other):
				continue
			var o: Dictionary = systems[int(_by_id[other])]
			var hot := sid == selected_id or other == selected_id
			draw_line(p, to_screen(_pos(o)), Color(1.0, 0.75, 0.35, 0.7) if hot else Color(1, 1, 1, 0.13), 2.0 if hot else 1.0, true)

	if mode == "link" and _link_from >= 0:
		var from := system(_link_from)
		if not from.is_empty():
			var a := to_screen(_pos(from))
			var target := _mouse
			if _hover >= 0 and _hover != _link_from:
				target = to_screen(_pos(system(_hover)))
			draw_dashed_line(a, target, EdTheme.AMBER, 2.0, 8.0, true, true)

	var labels := zoom >= 1.1
	for s in systems:
		var p := to_screen(_pos(s))
		if p.x < -40 or p.y < -40 or p.x > size.x + 40 or p.y > size.y + 40:
			continue
		var sid := int(s.get("id", 0))
		var c := Color(float(s.get("r", 0.6)), float(s.get("g", 0.6)), float(s.get("b", 0.6)))
		var nm := str(s.get("name", ""))
		var match_q := q == "" or nm.to_lower().contains(q) or str(sid) == q
		if not match_q:
			c = Color(c.r, c.g, c.b, 0.18)
		var prov := str(s.get("prov", "base"))
		var radius := clampf(3.0 + zoom * 1.5, 3.5, 7.0)
		draw_circle(p, radius + 1.5, Color(0, 0, 0, 0.6))
		draw_circle(p, radius, c)
		if prov != "base":
			draw_arc(p, radius + 3.5, 0, TAU, 24, EdTheme.prov_color(prov), 1.6, true)
		if sid == selected_id or sid == _link_from:
			draw_arc(p, radius + 6.0, 0, TAU, 28, EdTheme.AMBER if sid == _link_from else Color.WHITE, 2.0, true)
		elif sid == _hover:
			draw_arc(p, radius + 5.0, 0, TAU, 28, Color(1, 1, 1, 0.5), 1.5, true)
		if (labels or sid == selected_id or (q != "" and match_q)) and match_q:
			text(p + Vector2(radius + 5, 4), nm, 11 if sid != selected_id else 12, EdTheme.TEXT if sid == selected_id else Color(1, 1, 1, 0.72), "semibold" if sid == selected_id else "regular")

	if _hover >= 0 and _drag < 0:
		var h := system(_hover)
		var links: Array = h.get("links", [])
		var lines: Array = ["%s" % str(h.get("name", "")), "System #%d  ·  %d links  ·  %d stellars" % [_hover, links.size(), int(h.get("spobs", 0))]]
		if mode == "link" and _link_from >= 0 and _hover != _link_from:
			lines.append("Click to %s" % ("unlink" if links.has(float(_link_from)) or links.has(_link_from) else "link"))
		elif mode == "select":
			lines.append("Drag to move  ·  double-click to open")
		bubble(to_screen(_pos(h)), lines)
