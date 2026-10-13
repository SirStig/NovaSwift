# NOVA Swift — galaxy map screen (Godot).
#
# A pannable, zoomable hyperspace chart drawn entirely in code. The bridge owns
# everything that is game state — which systems the pilot may see (fog of war),
# links, government colors, route rules, fuel — so this file only lays out pixels
# and turns input into bridge calls (nav_click / nav_shift_click / nav_plot_course):
#
#   click / A          plot — arms a jump to a linked system (the original's rule)
#   Shift+click / Y    add a hop to the route (extends from its tail)
#   T / X              toggle auto-route: a plot then lays the fewest-jumps course
#                      to any system (the `autoRoutePlotting` ENHANCEMENT, off by
#                      default — the original has no pathfinding)
#   J / D-pad up       close the map and engage the hyperdrive
#   M / Back / B / Esc close
#   Gamepad: left stick drives a cursor that snaps to nearby systems, D-pad hops
#   to the next system in that direction, right stick pans, LB/RB zoom, R3 recentre.
#   Mouse: wheel zooms, right/middle-drag pans.
#
# Opened by Main.gd; emits `closed` and `jump_requested`, and `message` for the log.

extends CanvasLayer

signal closed
signal jump_requested
signal message(text: String)

# nav_systems() row layout — see NovaWorld.navSystems.
const VIS_ADJACENT := 1
const VIS_CHARTED := 2
const VIS_EXPLORED := 3

const SNAP_RADIUS := 34.0
const MOUSE_RADIUS := 14.0
const CURSOR_SPEED := 700.0
const PAN_SPEED := 600.0
const EDGE_PAN := 70.0
const ZOOM_MIN := 0.12
const ZOOM_MAX := 4.0

const COLOR_BG := Color(0.01, 0.015, 0.03, 0.96)
const COLOR_LINK := Color(1, 1, 1, 0.16)
const COLOR_LINK_NEAR := Color(0.3, 0.95, 0.4, 0.55)
const COLOR_ROUTE := Color(0.3, 0.95, 0.4)
const COLOR_ROUTE_WARN := Color(1.0, 0.4, 0.32)
const COLOR_CURRENT := Color(1.0, 0.7, 0.28)
const COLOR_ADJACENT := Color(0.42, 0.42, 0.42)
const COLOR_TEXT := Color(0.85, 0.9, 1.0)
const COLOR_DIM := Color(0.6, 0.65, 0.75)

var nova
var _canvas: Control

var _ids := PackedInt32Array()
var _info := {}                  # id -> {pos: Vector2, vis: int, color: Color}
var _links := PackedInt32Array()
var _names := {}                 # id -> String ("" = unnamed)
var _current := -1
var _route := PackedInt32Array()
var _armed := false
var _selected := -1

var _center := Vector2.ZERO      # map coordinate at the middle of the screen
var _zoom := 0.8
var _cursor := Vector2.ZERO      # screen space
var _hover := -1
var _pad_mode := false           # the pad last moved the cursor (drives hint text)
var _auto_route := false
var _dragging := false
var _jumps := 0
var _max_hops := 1


func setup(world) -> void:
	nova = world
	layer = 10
	visible = false
	_canvas = Control.new()
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.draw.connect(_on_draw)
	add_child(_canvas)


func is_open() -> bool:
	return visible


func open() -> void:
	if nova == null or not nova.has_game():
		return
	nova.nav_refresh()
	_reload()
	_center = _info[_current]["pos"] if _info.has(_current) else Vector2.ZERO
	_cursor = _canvas.size * 0.5
	_hover = -1
	_pad_mode = _pad_connected()
	visible = true
	nova.sound_beep(3)   # the map window opens with snd 152 (0x0044b120)
	_canvas.queue_redraw()


func close() -> void:
	if not visible:
		return
	visible = false
	nova.sound_beep(1)   # and returns with snd 150
	closed.emit()


static func _pad_connected() -> bool:
	return not Input.get_connected_joypads().is_empty()


# Pull the (rarely changing) map tables across the bridge once per open and after
# every plot, not per frame.
func _reload() -> void:
	_current = nova.nav_current_system()
	var rows: PackedFloat32Array = nova.nav_systems()
	var stride: int = nova.nav_stride()
	_ids = PackedInt32Array()
	_info.clear()
	_names.clear()
	var i := 0
	while i + stride <= rows.size():
		var id := int(rows[i])
		_ids.append(id)
		_info[id] = {
			"pos": Vector2(rows[i + 1], rows[i + 2]),
			"vis": int(rows[i + 3]),
			"color": Color(rows[i + 4], rows[i + 5], rows[i + 6]),
		}
		_names[id] = nova.nav_system_name(id)
		i += stride
	_links = nova.nav_links()
	_reload_route()


func _reload_route() -> void:
	_route = nova.nav_route()
	_armed = nova.nav_route_armed()
	_selected = nova.nav_selected()
	_jumps = nova.player_jumps_remaining()
	_max_hops = nova.nav_max_jump_hops()


func _to_screen(p: Vector2) -> Vector2:
	return _canvas.size * 0.5 + (p - _center) * _zoom


func _to_map(p: Vector2) -> Vector2:
	return (p - _canvas.size * 0.5) / _zoom + _center


func _nearest(screen: Vector2, radius: float) -> int:
	var best := -1
	var best_d := radius
	for id in _ids:
		var d := _to_screen(_info[id]["pos"]).distance_to(screen)
		if d < best_d:
			best_d = d
			best = id
	return best


func _process(delta: float) -> void:
	if not visible:
		return
	var moved := false

	# Pan: arrows/WASD or the right stick.
	var pan := Input.get_vector("map_pan_left", "map_pan_right", "map_pan_up", "map_pan_down", 0.2)
	if pan != Vector2.ZERO:
		_center += pan * PAN_SPEED * delta / _zoom
		moved = true

	# Stick cursor with magnetic snapping.
	var v := Input.get_vector("map_cursor_left", "map_cursor_right", "map_cursor_up", "map_cursor_down", 0.2)
	if v != Vector2.ZERO:
		_pad_mode = true
		_cursor += v * CURSOR_SPEED * delta
		var size := _canvas.size
		if _cursor.x < EDGE_PAN and v.x < 0.0 or _cursor.x > size.x - EDGE_PAN and v.x > 0.0:
			_center.x += v.x * PAN_SPEED * delta / _zoom
		if _cursor.y < EDGE_PAN and v.y < 0.0 or _cursor.y > size.y - EDGE_PAN and v.y > 0.0:
			_center.y += v.y * PAN_SPEED * delta / _zoom
		_cursor = _cursor.clamp(Vector2.ZERO, size)
		moved = true
	if _pad_mode:
		var near := _nearest(_cursor, SNAP_RADIUS)
		if near != -1:
			# Weak pull while the stick is held (so it can leave), strong at rest.
			var pull := 3.0 if v != Vector2.ZERO else 14.0
			_cursor = _cursor.lerp(_to_screen(_info[near]["pos"]), clampf(pull * delta, 0.0, 1.0))
		if near != _hover:
			moved = true
		_hover = near

	if moved:
		_canvas.queue_redraw()


func _input(event: InputEvent) -> void:
	if not visible:
		return

	# Closing (and the jump shortcut) first, so nothing leaks to the flight code.
	if event.is_action_pressed("map_close") or event.is_action_pressed("galaxy_map"):
		get_viewport().set_input_as_handled()
		close()
		return
	if event.is_action_pressed("hyperjump"):
		get_viewport().set_input_as_handled()
		close()
		jump_requested.emit()
		return

	if event is InputEventMouseMotion:
		_pad_mode = false
		_cursor = event.position
		if _dragging:
			_center -= event.relative / _zoom
		_hover = _nearest(_cursor, MOUSE_RADIUS)
		_canvas.queue_redraw()
	elif event is InputEventMouseButton:
		_pad_mode = false
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom_at(1.15, event.position)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom_at(1.0 / 1.15, event.position)
		elif event.button_index == MOUSE_BUTTON_RIGHT or event.button_index == MOUSE_BUTTON_MIDDLE:
			_dragging = event.pressed
		elif event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			var id := _nearest(event.position, MOUSE_RADIUS)
			if id != -1:
				_plot(id, event.shift_pressed)
	elif event is InputEventJoypadButton and event.pressed:
		match event.button_index:
			JOY_BUTTON_DPAD_LEFT: _step_direction(Vector2.LEFT)
			JOY_BUTTON_DPAD_RIGHT: _step_direction(Vector2.RIGHT)
			JOY_BUTTON_DPAD_UP: pass   # also "hyperjump", handled above
			JOY_BUTTON_DPAD_DOWN: _step_direction(Vector2.DOWN)

	if event.is_action_pressed("map_zoom_in"):
		_zoom_at(1.25, _canvas.size * 0.5)
	elif event.is_action_pressed("map_zoom_out"):
		_zoom_at(0.8, _canvas.size * 0.5)
	elif event.is_action_pressed("map_center"):
		_center = _info[_current]["pos"] if _info.has(_current) else _center
		_canvas.queue_redraw()
	elif event.is_action_pressed("map_auto_route"):
		_auto_route = not _auto_route
		message.emit("Auto-route plotting " + ("on" if _auto_route else "off"))
		_canvas.queue_redraw()
	elif event.is_action_pressed("map_select"):
		var target := _hover if _hover != -1 else _nearest(_cursor, SNAP_RADIUS)
		if target != -1:
			_plot(target, false)
	elif event.is_action_pressed("map_extend"):
		var target2 := _hover if _hover != -1 else _nearest(_cursor, SNAP_RADIUS)
		if target2 != -1:
			_plot(target2, true)


# D-pad: move the cursor to the nearest system roughly in that direction.
func _step_direction(dir: Vector2) -> void:
	_pad_mode = true
	var from_id := _hover if _hover != -1 else _nearest(_cursor, 1.0e9)
	if from_id == -1:
		return
	var from_pos: Vector2 = _info[from_id]["pos"]
	var best := -1
	var best_score := INF
	for id in _ids:
		if id == from_id:
			continue
		var d: Vector2 = _info[id]["pos"] - from_pos
		var dist := d.length()
		if dist < 0.001 or d.normalized().dot(dir) < 0.5:
			continue
		# Prefer near systems that sit close to the requested axis.
		var score := dist * (2.0 - d.normalized().dot(dir))
		if score < best_score:
			best_score = score
			best = id
	if best == -1:
		return
	_hover = best
	var p := _to_screen(_info[best]["pos"])
	_cursor = p
	var size := _canvas.size
	if p.x < EDGE_PAN or p.y < EDGE_PAN or p.x > size.x - EDGE_PAN or p.y > size.y - EDGE_PAN:
		_center = _info[best]["pos"]
		_cursor = size * 0.5
	_canvas.queue_redraw()


func _zoom_at(factor: float, screen: Vector2) -> void:
	var before := _to_map(screen)
	_zoom = clampf(_zoom * factor, ZOOM_MIN, ZOOM_MAX)
	_center += before - _to_map(screen)   # keep the point under the cursor fixed
	_canvas.queue_redraw()


func _plot(id: int, extend: bool) -> void:
	if extend:
		nova.nav_shift_click(id)
	elif _auto_route:
		if not nova.nav_plot_course(id):
			message.emit("No route to that system")
	else:
		nova.nav_click(id)
	_reload_route()
	_canvas.queue_redraw()


func _system_label(id: int) -> String:
	var n: String = _names.get(id, "")
	return n if n != "" else "Unknown system"


# MARK: Drawing

func _on_draw() -> void:
	var c := _canvas
	var size := c.size
	c.draw_rect(Rect2(Vector2.ZERO, size), COLOR_BG)
	var font := ThemeDB.fallback_font
	var fs := ThemeDB.fallback_font_size
	var view := Rect2(Vector2.ZERO, size).grow(60.0)

	# Links, with the current system's own links picked out.
	var i := 0
	while i + 1 < _links.size():
		var a := _links[i]
		var b := _links[i + 1]
		i += 2
		var pa := _to_screen(_info[a]["pos"])
		var pb := _to_screen(_info[b]["pos"])
		if not view.has_point(pa) and not view.has_point(pb):
			continue
		c.draw_line(pa, pb, COLOR_LINK_NEAR if a == _current or b == _current else COLOR_LINK, 1.0, true)

	# Route: green while the fuel lasts, red past it.
	if _route.size() > 0 and _info.has(_current):
		var prev := _to_screen(_info[_current]["pos"])
		var reach := _jumps * _max_hops
		for n in _route.size():
			var hop := _route[n]
			if not _info.has(hop):
				break
			var p := _to_screen(_info[hop]["pos"])
			var col := COLOR_ROUTE if n < reach else COLOR_ROUTE_WARN
			if n > 0 or not _armed:
				col.a = 0.75
			c.draw_line(prev, p, col, 3.0 if n == 0 and _armed else 2.0, true)
			prev = p

	# Systems.
	var route_set := {}
	for hop in _route:
		route_set[hop] = true
	for id in _ids:
		var info: Dictionary = _info[id]
		var p := _to_screen(info["pos"])
		if not view.has_point(p):
			continue
		var vis: int = info["vis"]
		var col: Color = info["color"]
		var radius := clampf(4.0 * _zoom + 2.0, 3.0, 9.0)
		if vis == VIS_ADJACENT:
			col = COLOR_ADJACENT
			radius *= 0.7
		elif vis == VIS_CHARTED:
			col = col.darkened(0.35)
		c.draw_circle(p, radius, col)
		if id == _current:
			c.draw_arc(p, radius + 5.0, 0.0, TAU, 32, COLOR_CURRENT, 2.0, true)
		if route_set.has(id):
			c.draw_arc(p, radius + 3.0, 0.0, TAU, 24, COLOR_ROUTE, 1.5, true)
		if id == _selected:
			c.draw_arc(p, radius + 8.0, 0.0, TAU, 32, Color.WHITE, 1.5, true)
		if id == _hover:
			c.draw_arc(p, radius + 11.0, 0.0, TAU, 32, Color(0.4, 0.85, 1.0), 2.0, true)
		# Names: always for the current/route/hovered, the rest once zoomed in.
		var named: bool = _names.get(id, "") != ""
		if named and (_zoom >= 0.7 or id == _current or id == _hover or id == _selected or route_set.has(id)):
			c.draw_string(font, p + Vector2(radius + 5.0, 4.0), _names[id], HORIZONTAL_ALIGNMENT_LEFT,
				-1, fs - 2, COLOR_TEXT if vis == VIS_EXPLORED else COLOR_DIM)

	# Cursor reticle (pad / mouse).
	if _pad_mode:
		c.draw_arc(_cursor, 10.0, 0.0, TAU, 24, Color(0.4, 0.85, 1.0, 0.9), 1.5, true)
		c.draw_line(_cursor + Vector2(-16, 0), _cursor + Vector2(-6, 0), Color(0.4, 0.85, 1.0), 1.5)
		c.draw_line(_cursor + Vector2(16, 0), _cursor + Vector2(6, 0), Color(0.4, 0.85, 1.0), 1.5)

	_draw_panel(c, font, fs, size)


func _draw_panel(c: Control, font: Font, fs: int, size: Vector2) -> void:
	var focus := _hover if _hover != -1 else (_selected if _selected != -1 else _current)
	var lines: Array = []
	lines.append(("Current: " + _system_label(_current)) if focus == _current
		else _system_label(focus))
	if focus != -1:
		var gov: String = nova.nav_system_government(focus) if _names.get(focus, "") != "" else ""
		lines.append(gov if gov != "" else ("Independent" if _names.get(focus, "") != "" else "Unexplored"))
	var route_text := "No course plotted"
	if _route.size() > 0:
		var dest := _route[_route.size() - 1]
		route_text = "Course: %d jump%s to %s%s" % [_route.size(), "" if _route.size() == 1 else "s",
			_system_label(dest), "" if _armed else "  (not armed — plot a linked system)"]
	lines.append(route_text)
	lines.append("Fuel: %d jump%s%s" % [_jumps, "" if _jumps == 1 else "s",
		"   ·   multi-jump x%d" % _max_hops if _max_hops > 1 else ""])
	if _auto_route:
		lines.append("Auto-route plotting ON (enhancement)")

	var h := lines.size() * (fs + 6) + 16
	var rect := Rect2(Vector2(20, size.y - h - 40), Vector2(430, h))
	c.draw_rect(rect, Color(0.04, 0.06, 0.1, 0.85))
	c.draw_rect(rect, Color(0.3, 0.45, 0.65, 0.6), false, 1.0)
	for n in lines.size():
		c.draw_string(font, rect.position + Vector2(10, 8 + (n + 1) * (fs + 6) - 4), lines[n],
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, COLOR_TEXT if n < 2 else COLOR_DIM)

	var hint := ("L-stick cursor · D-pad next system · A plot · Y add hop · X auto-route · D-pad ↑ jump · "
		+ "LB/RB zoom · R-stick pan · B close") if _pad_mode else (
		"Click plot · Shift+click add hop · J jump · T auto-route · wheel zoom · right-drag pan · C center · M/Esc close")
	c.draw_string(font, Vector2(20, size.y - 16), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 2, COLOR_DIM)
