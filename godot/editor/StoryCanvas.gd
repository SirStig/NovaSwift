# Story graph canvas: missions and crons laid out by StoryGraph, edges by control bit
# (starts / enables / disables). Click selects, double-click opens, search dims non-matches.
extends "res://editor/EditorCanvas.gd"

signal selected(type_code: String, id: int, node: Dictionary)
signal opened(type_code: String, id: int)

const STARTS := Color(1.0, 0.7, 0.28, 0.75)
const ENABLES := Color(0.35, 0.85, 0.5, 0.35)
const DISABLES := Color(1.0, 0.35, 0.3, 0.35)

var data := {}
var highlight := ""
var only_touched := false
var selected_node := -1
var _by := {}
var _hover := -1


func set_data(d: Dictionary) -> void:
	data = d
	_by.clear()
	for n in data.get("nodes", []):
		_by[int(n.get("id", -1))] = n
	min_zoom = 0.005
	queue_redraw()


func content_rect() -> Rect2:
	return Rect2(0, 0, maxf(1.0, float(data.get("width", 1))), maxf(1.0, float(data.get("height", 1))))


func _pos(n: Dictionary) -> Vector2:
	return Vector2(float(n.get("x", 0)), float(n.get("y", 0)))


func _matches(n: Dictionary) -> bool:
	if only_touched and not bool(n.get("touched", false)):
		return false
	var q := highlight.strip_edges().to_lower()
	if q == "":
		return true
	return str(n.get("name", "")).to_lower().contains(q) or str(int(n.get("res", -1))) == q or str(n.get("story", "")).to_lower().contains(q)


func first_match() -> Dictionary:
	for n in data.get("nodes", []):
		if _matches(n):
			return n
	return {}


func focus_node(n: Dictionary) -> void:
	if n.is_empty():
		return
	selected_node = int(n.get("id", -1))
	center_on(_pos(n), 0.6)
	selected.emit(str(n.get("type", "")), int(n.get("res", -1)), n)


func _node_size() -> Vector2:
	return Vector2(clampf(110.0 * zoom, 6.0, 150.0), clampf(26.0 * zoom, 6.0, 26.0))


func _hit(p: Vector2) -> int:
	var half := _node_size() * 0.5 + Vector2(3, 3)
	for n in data.get("nodes", []):
		var s := to_screen(_pos(n))
		if absf(p.x - s.x) <= half.x and absf(p.y - s.y) <= half.y:
			return int(n.get("id", -1))
	return -1


func _gui_input(event: InputEvent) -> void:
	if handle_view_input(event):
		accept_event()
		return
	if event is InputEventMouseMotion:
		var h := _hit((event as InputEventMouseMotion).position)
		if h != _hover:
			_hover = h
			mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND if h >= 0 else Control.CURSOR_ARROW
			queue_redraw()
	elif event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT and (event as InputEventMouseButton).pressed:
		var mb := event as InputEventMouseButton
		var hit := _hit(mb.position)
		if hit >= 0:
			var n: Dictionary = _by[hit]
			if mb.double_click:
				opened.emit(str(n.get("type", "")), int(n.get("res", -1)))
				return
			selected_node = hit
			selected.emit(str(n.get("type", "")), int(n.get("res", -1)), n)
			queue_redraw()
		else:
			begin_pan(MOUSE_BUTTON_LEFT)


func _node_color(n: Dictionary) -> Color:
	if bool(n.get("unreachable", false)):
		return EdTheme.BAD
	if bool(n.get("touched", false)):
		return EdTheme.AMBER
	if bool(n.get("cron", false)):
		return Color(0.45, 0.65, 1.0)
	return Color(0.82, 0.82, 0.86)


func _draw() -> void:
	draw_backdrop(200.0)
	var ns := _node_size()
	var view := Rect2(Vector2(-ns.x, -ns.y), size + ns * 2)
	var any_filter := highlight.strip_edges() != "" or only_touched
	for e in data.get("edges", []):
		var fa := int(e.get("from", -1))
		var fb := int(e.get("to", -1))
		if not _by.has(fa) or not _by.has(fb):
			continue
		var a: Dictionary = _by[fa]
		var b: Dictionary = _by[fb]
		var p := to_screen(_pos(a))
		var q := to_screen(_pos(b))
		if not view.has_point(p) and not view.has_point(q):
			continue
		var kind := str(e.get("kind", ""))
		var col := STARTS if kind == "starts" else (DISABLES if kind == "disables" else ENABLES)
		var hot := fa == selected_node or fb == selected_node
		if any_filter and not (_matches(a) or _matches(b)):
			col.a *= 0.25
		if hot:
			col.a = 1.0
		draw_line(p, q, col, 2.0 if hot else 1.0, true)
	var show_text := ns.y >= 16.0
	for n in data.get("nodes", []):
		var p := to_screen(_pos(n))
		if not view.has_point(p):
			continue
		var nid := int(n.get("id", -1))
		var c := _node_color(n)
		var dim := any_filter and not _matches(n)
		var r := Rect2(p - ns * 0.5, ns)
		var radius := int(minf(6.0, ns.y * 0.3))
		if show_text:
			draw_style_box(T.box(Color(0.13, 0.13, 0.14, 0.35 if dim else 0.97), radius, Color(c.r, c.g, c.b, 0.25 if dim else 0.85), 1), r)
			draw_rect(Rect2(r.position + Vector2(1, 1), Vector2(3, r.size.y - 2)), Color(c.r, c.g, c.b, 0.3 if dim else 1.0), true)
			var label := str(n.get("name", "")).get_slice(";", 0)
			var max_w := r.size.x - 12
			var px := 11
			while label.length() > 3 and text_width(label, px) > max_w:
				label = label.left(label.length() - 2)
			text(r.position + Vector2(8, r.size.y * 0.5 + 4), label, px, Color(1, 1, 1, 0.3 if dim else 0.9))
		else:
			draw_rect(r, Color(c.r, c.g, c.b, 0.2 if dim else 0.95), true)
		if nid == selected_node:
			draw_style_box(T.box(Color(0, 0, 0, 0), radius + 2, Color.WHITE, 2), r.grow(3))
		elif nid == _hover:
			draw_style_box(T.box(Color(0, 0, 0, 0), radius + 2, Color(1, 1, 1, 0.5), 1), r.grow(2))
	if _hover >= 0:
		var h: Dictionary = _by[_hover]
		var kind := "Cron" if bool(h.get("cron", false)) else "Mission"
		var lines: Array = [str(h.get("name", "")).get_slice(";", 0), "%s #%d%s" % [kind, int(h.get("res", -1)), ("  ·  " + str(h.get("story", ""))) if str(h.get("story", "")) != "" else ""]]
		if bool(h.get("unreachable", false)):
			lines.append("Unreachable: nothing sets the bits it needs")
		elif bool(h.get("dead", false)):
			lines.append("Dead end: starts nothing")
		lines.append("Double-click to edit")
		bubble(to_screen(_pos(h)), lines)
