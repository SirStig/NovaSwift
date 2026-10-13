# Pan / zoom base for the editor's map canvases (galaxy, star system, story graph).
# World -> screen is `w * zoom + pan`. Wheel or pinch zooms about the cursor, trackpad two-finger
# scroll / middle / right drag pans, and subclasses may start a pan from a left drag on empty space.
extends Control

const EdTheme = preload("res://editor/EditorTheme.gd")
const T = preload("res://ui/novaswift/NovaTheme.gd")

signal view_changed

var zoom := 1.0
var pan := Vector2.ZERO
var min_zoom := 0.02
var max_zoom := 8.0
var _panning := false
var _pan_button := 0
var _fitted := false
var _fit_rect := Rect2()


func _init() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP
	clip_contents = true
	focus_mode = Control.FOCUS_CLICK
	size_flags_horizontal = Control.SIZE_EXPAND_FILL
	size_flags_vertical = Control.SIZE_EXPAND_FILL


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED and not _fitted and size.x > 10 and size.y > 10:
		_fitted = true
		fit(content_rect())


## World-space bounds of everything drawn; subclasses override.
func content_rect() -> Rect2:
	return Rect2(-100, -100, 200, 200)


func to_screen(w: Vector2) -> Vector2:
	return w * zoom + pan


func to_world(s: Vector2) -> Vector2:
	return (s - pan) / zoom


func fit(rect: Rect2, margin := 48.0) -> void:
	if size.x < 10 or size.y < 10:
		_fitted = false
		return
	var r := rect
	if r.size.x < 1:
		r = r.grow_individual(50, 0, 50, 0)
	if r.size.y < 1:
		r = r.grow_individual(0, 50, 0, 50)
	var avail := size - Vector2(margin, margin) * 2
	zoom = clampf(minf(avail.x / r.size.x, avail.y / r.size.y), min_zoom, max_zoom)
	pan = size * 0.5 - r.get_center() * zoom
	queue_redraw()
	view_changed.emit()


func center_on(world: Vector2, min_zoom_level := 0.0) -> void:
	if min_zoom_level > 0.0 and zoom < min_zoom_level:
		zoom = min_zoom_level
	pan = size * 0.5 - world * zoom
	queue_redraw()
	view_changed.emit()


func zoom_by(factor: float, around: Vector2 = Vector2(-1, -1)) -> void:
	var at := around if around.x >= 0 else size * 0.5
	var before := to_world(at)
	zoom = clampf(zoom * factor, min_zoom, max_zoom)
	pan = at - before * zoom
	queue_redraw()
	view_changed.emit()


## Handles zoom / pan input. Returns true when the event was consumed.
func handle_view_input(event: InputEvent) -> bool:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.pressed and (mb.button_index == MOUSE_BUTTON_WHEEL_UP or mb.button_index == MOUSE_BUTTON_WHEEL_DOWN):
			var f := 1.12 if mb.button_index == MOUSE_BUTTON_WHEEL_UP else 1.0 / 1.12
			zoom_by(pow(f, maxf(1.0, mb.factor)) if mb.factor > 0 else f, mb.position)
			return true
		if mb.button_index == MOUSE_BUTTON_MIDDLE or mb.button_index == MOUSE_BUTTON_RIGHT:
			if mb.pressed:
				begin_pan(mb.button_index)
			elif _pan_button == mb.button_index:
				_end_pan()
			return true
		if mb.button_index == MOUSE_BUTTON_LEFT and not mb.pressed and _panning and _pan_button == MOUSE_BUTTON_LEFT:
			_end_pan()
			return true
	elif event is InputEventMouseMotion and _panning:
		pan += (event as InputEventMouseMotion).relative
		queue_redraw()
		view_changed.emit()
		return true
	elif event is InputEventPanGesture:
		pan -= (event as InputEventPanGesture).delta * 12.0
		queue_redraw()
		view_changed.emit()
		return true
	elif event is InputEventMagnifyGesture:
		var g := event as InputEventMagnifyGesture
		zoom_by(g.factor, g.position)
		return true
	return false


func begin_pan(button: int) -> void:
	_panning = true
	_pan_button = button
	mouse_default_cursor_shape = Control.CURSOR_DRAG


func _end_pan() -> void:
	_panning = false
	_pan_button = 0
	mouse_default_cursor_shape = Control.CURSOR_ARROW


# --- drawing helpers ------------------------------------------------------------------------------

func draw_backdrop(step_world := 100.0) -> void:
	draw_rect(Rect2(Vector2.ZERO, size), EdTheme.CANVAS, true)
	var step := step_world * zoom
	while step < 28.0:
		step *= 2.0
	while step > 160.0:
		step *= 0.5
	var origin := pan
	var c := Color(1, 1, 1, 0.035)
	var x := fposmod(origin.x, step)
	while x < size.x:
		draw_line(Vector2(x, 0), Vector2(x, size.y), c, 1.0)
		x += step
	var y := fposmod(origin.y, step)
	while y < size.y:
		draw_line(Vector2(0, y), Vector2(size.x, y), c, 1.0)
		y += step


func text(at: Vector2, s: String, px := 12, color: Color = EdTheme.TEXT, weight := "regular") -> void:
	draw_string(T.font("body", weight), at, s, HORIZONTAL_ALIGNMENT_LEFT, -1, px, color)


func text_width(s: String, px := 12, weight := "regular") -> float:
	return T.font("body", weight).get_string_size(s, HORIZONTAL_ALIGNMENT_LEFT, -1, px).x


## A rounded tooltip bubble with lines of text near `at` (kept on-screen).
func bubble(at: Vector2, lines: Array) -> void:
	if lines.is_empty():
		return
	var w := 0.0
	for i in lines.size():
		w = maxf(w, text_width(str(lines[i]), 13 if i == 0 else 11, "semibold" if i == 0 else "regular"))
	var h := 10.0 + 17.0 + 15.0 * (lines.size() - 1)
	var r := Rect2(at + Vector2(14, 12), Vector2(w + 20, h))
	if r.end.x > size.x - 6:
		r.position.x = at.x - 14 - r.size.x
	if r.end.y > size.y - 6:
		r.position.y = at.y - 12 - r.size.y
	draw_style_box(T.box(Color(0.14, 0.14, 0.15, 0.97), 7, Color(1, 1, 1, 0.16), 1), r)
	var y := r.position.y + 19
	for i in lines.size():
		text(Vector2(r.position.x + 10, y), str(lines[i]), 13 if i == 0 else 11, EdTheme.TEXT if i == 0 else EdTheme.SECONDARY, "semibold" if i == 0 else "regular")
		y += 17 if i == 0 else 15
