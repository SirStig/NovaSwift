# NOVA Swift — the in-flight route mini map (Godot).
#
# The original redraws a small star map in the top-left corner when a hyperspace link is
# stepped (`\`), the route is re-armed (H), a hop arrives with a route left, or a zoom key
# is pressed: full for 118 ticks, fading over the next 32 (60 Hz), gone at 150; the zoom
# keys work for 500 ticks (0x00439bb0, 0x0044b120). Mirrors the Apple app's
# `routeMapShownAt` / `routeMapUnitsPerPixel` (GameContainerView): a square a quarter of the
# view wide (at least 200), zoom x4/3 out up to 2.0 and x0.75 in down to 0.5 units/pixel.
# Only presentation lives here — the systems, links and route come from the bridge.

extends CanvasLayer

const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")

const SHOW_FULL_TICKS := 118.0
const SHOW_FADE_END := 150.0
const ZOOM_WINDOW_TICKS := 500.0
const UPP_DEFAULT := 0.5625
const UPP_OUT_LIMIT := 2.0       # zoom out only while at or below this
const UPP_IN_LIMIT := 0.5        # zoom in only while above this

var nova
var units_per_pixel := UPP_DEFAULT
var _shown_at_ms := -1
var _canvas: Control
var _pos := {}                   # system id -> Vector2 (map units)
var _color := {}                 # system id -> Color
var _links := PackedInt32Array()
var _route := PackedInt32Array()
var _armed := false
var _current := -1


func setup(world) -> void:
	nova = world
	ClassicTheme.setup(world)   # the cölr palette (the frame is its FloatingMap colour)
	layer = 6
	visible = false
	_canvas = Control.new()
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_on_draw)
	add_child(_canvas)


## Ticks (60 Hz) since the map was last raised; -1 when it isn't up.
func ticks() -> float:
	if _shown_at_ms < 0:
		return -1.0
	return float(Time.get_ticks_msec() - _shown_at_ms) * 0.06


func is_up() -> bool:
	var t := ticks()
	return t >= 0.0 and t < SHOW_FADE_END


## Raise the map (or restart its timer) and re-read the system/route snapshot.
func show_map() -> void:
	_reload()
	_shown_at_ms = Time.get_ticks_msec()
	visible = true
	_canvas.queue_redraw()


func hide_map() -> void:
	_shown_at_ms = -1
	visible = false


## Zoom a step while the window is open. `out` = zoom out. Returns whether it changed
## (the original then sounds snd 150).
func zoom(out: bool) -> bool:
	var t := ticks()
	if t < 0.0 or t > ZOOM_WINDOW_TICKS:
		return false
	if out and units_per_pixel <= UPP_OUT_LIMIT:
		units_per_pixel *= 4.0 / 3.0
	elif not out and units_per_pixel > UPP_IN_LIMIT:
		units_per_pixel *= 0.75
	else:
		return false
	show_map()
	return true


func _reload() -> void:
	nova.nav_refresh()
	_current = nova.nav_current_system()
	var rows: PackedFloat32Array = nova.nav_systems()
	var stride: int = nova.nav_stride()
	_pos.clear()
	_color.clear()
	var i := 0
	while i + stride <= rows.size():
		var id := int(rows[i])
		_pos[id] = Vector2(rows[i + 1], rows[i + 2])
		_color[id] = Color(rows[i + 4], rows[i + 5], rows[i + 6])
		i += stride
	_links = nova.nav_links()
	_route = nova.nav_route()
	_armed = nova.nav_route_armed()


func _process(_delta: float) -> void:
	if not visible:
		return
	if not is_up():
		hide_map()
		return
	_canvas.queue_redraw()


func _on_draw() -> void:
	var t := ticks()
	if t < 0.0 or not _pos.has(_current):
		return
	var alpha: float = 1.0 if t < SHOW_FULL_TICKS else maxf(0.0, 1.0 - (t - SHOW_FULL_TICKS) / (SHOW_FADE_END - SHOW_FULL_TICKS))
	var vp := get_viewport().get_visible_rect().size
	var side: float = maxf(200.0, roundf(vp.x * 0.25))
	var rect := Rect2(Vector2.ZERO, Vector2(side, side))
	_canvas.draw_rect(rect, Color(0.0, 0.0, 0.0, 0.6 * alpha))
	# The floating map's frame is drawn in the cölr FloatingMap colour (0x00735658), as Apple's mini map.
	var frame: Color = ClassicTheme.palette().get("floatingMap", Color(1.0, 0.72, 0.28, 0.25))
	frame.a *= alpha
	_canvas.draw_rect(rect, frame, false, 1.0)
	var scale := 1.0 / units_per_pixel
	var origin: Vector2 = _pos[_current]
	var mid := Vector2(side, side) * 0.5
	var inside := rect.grow(-3.0)
	# Hyperspace links.
	var i := 0
	while i + 2 <= _links.size():
		var a := int(_links[i])
		var b := int(_links[i + 1])
		i += 2
		if not (_pos.has(a) and _pos.has(b)):
			continue
		var pa: Vector2 = mid + (_pos[a] - origin) * scale
		var pb: Vector2 = mid + (_pos[b] - origin) * scale
		if inside.has_point(pa) or inside.has_point(pb):
			_canvas.draw_line(pa, pb, Color(1, 1, 1, 0.18 * alpha), 1.0)
	# The plotted route from the current system.
	var prev: Vector2 = mid
	for h in _route:
		if not _pos.has(int(h)):
			break
		var p: Vector2 = mid + (_pos[int(h)] - origin) * scale
		_canvas.draw_line(prev, p, Color(0.3, 0.95, 0.4, alpha), 2.0)
		prev = p
	# Systems.
	for id in _pos:
		var p: Vector2 = mid + (_pos[id] - origin) * scale
		if not inside.has_point(p):
			continue
		var col: Color = _color.get(id, Color(0.6, 0.6, 0.6))
		var r := 2.5
		if int(id) == _current:
			col = Color(1.0, 0.7, 0.28)
			r = 4.0
		elif _armed and _route.size() > 0 and int(id) == int(_route[0]):
			col = Color(0.3, 0.95, 0.4)
			r = 4.0
		_canvas.draw_circle(p, r, Color(col.r, col.g, col.b, alpha))
