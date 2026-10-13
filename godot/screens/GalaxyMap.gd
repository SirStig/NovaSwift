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
#   F / L3             find a system by name (the original's Find: longest common prefix
#                      of the known systems' names; selects and centres, never plots)
#   M / Back / B / Esc close
#
# Nebulae (nëbu art, drawn the way the original's map does: only active ones the pilot
# has explored, added over the dark background) are always shown. The hypergate /
# wormhole spokes between systems appear in the picker below (the original) and, as an
# opt-in enhancement (Settings -> Video), on the plain map too.
#
# Gate picker (open_gate): landing on a hypergate the pilot may use opens this map in
# gate mode — the gate's destinations are marked with bold blue spokes from the current
# system, a click / A picks one and the bridge flies the transport (no fuel, no days).
#   Gamepad: left stick drives a cursor that snaps to nearby systems, D-pad hops
#   to the next system in that direction, right stick pans, LB/RB zoom, R3 recentre.
#   Mouse: wheel zooms, right/middle-drag pans.
#
# Opened by Main.gd; emits `closed` and `jump_requested`, and `message` for the log.

extends CanvasLayer

const Prefs = preload("res://Prefs.gd")
const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")
const ClassicDialog = preload("res://ui/classic/ClassicDialog.gd")

# Classic presentation (the default unless Prefs presentation/fullscreen_galaxy_map): the map
# sits inside its original dialog -- DLOG/DITL 2000 on PICT 8509, as the Apple GalaxyMapView's
# authenticChrome -- with the original's side panel (item 5), status bar (item 1) and the
# Done / Clear Route / Find / - / + buttons; zoom 0.5...2.0 stepped by 3/4 like the original.
const FRAME_PICT := 8509
const CLASSIC_ZOOM_MIN := 0.5
const CLASSIC_ZOOM_MAX := 2.0
const CLASSIC_ZOOM_DEFAULT := 1.0 / 0.5625
const THEME_LIGHT := Color(0.75, 0.75, 0.75)    # 0xC000: labels
const THEME_DIM := Color(0.25, 0.25, 0.25)      # 0x4000: the date

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
const COLOR_GATE_HYPER := Color(0.3, 0.85, 0.95, 0.85)
const COLOR_GATE_WORM := Color(0.78, 0.45, 1.0, 0.85)
const COLOR_GATE_ROUTE := Color(0.25, 0.62, 1.0)

var nova
var _canvas: Control
var _neb: Control                # nebula art, added over the background
var _find_box: PanelContainer
var _find_edit: LineEdit

var _framed := false             # inside the original dialog frame
var _frame: Control              # the ClassicDialog
var _clip: Control               # the starmap item's clipping rect inside the frame
var _side: Control
var _bar: Control
var _sys_text := {}
var _info_key := ""
var _minus: Control
var _plus: Control
var _clear: Control
var _hint: Label
var _gate := {}                  # gate picker state (empty = the plain map)
var _gate_dests := {}            # destination system id -> {gate, name, pos}
var _gate_links := PackedInt32Array()   # [a, b, wormhole] triples
var _nebulae: Array = []         # [{id, x, y, w, h, picts, full}]
var _tex := {}                   # PICT id -> Texture2D (or null)

var _ids := PackedInt32Array()
var _info := {}                  # id -> {pos: Vector2, vis: int, color: Color}
var _links := PackedInt32Array()
var _names := {}                 # id -> String ("" = unnamed)
var _marker := {}                # id -> Color: the Classic ring colour (bridge nav_marker_colors)
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
	var bg := ColorRect.new()
	bg.color = COLOR_BG
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)
	_neb = Control.new()
	_neb.set_anchors_preset(Control.PRESET_FULL_RECT)
	_neb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var add_mat := CanvasItemMaterial.new()
	add_mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD   # the original blends with addMax
	_neb.material = add_mat
	_neb.draw.connect(_draw_nebulae)
	add_child(_neb)
	_canvas = Control.new()
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_STOP
	_canvas.draw.connect(_on_draw)
	add_child(_canvas)
	_build_find_box()


func is_open() -> bool:
	return visible


func open() -> void:
	if nova == null or not nova.has_game():
		return
	nova.nav_refresh()
	_apply_mode()
	_reload()
	if _framed:
		_zoom = CLASSIC_ZOOM_DEFAULT
	_update_classic()
	_center = _info[_current]["pos"] if _info.has(_current) else Vector2.ZERO
	_cursor = _canvas.size * 0.5
	_hover = -1
	_pad_mode = _pad_connected()
	visible = true
	nova.sound_beep(3)   # the map window opens with snd 152 (0x0044b120)
	_canvas.queue_redraw()


## The hypergate picker: the map in gate mode (see the header). No-op unless the bridge
## has a gate picker open.
func open_gate() -> void:
	if nova == null or not nova.has_game():
		return
	var st = JSON.parse_string(nova.gate_picker_state())
	if not (st is Dictionary) or st.is_empty():
		return
	nova.nav_refresh()
	_apply_mode()
	_reload()
	_zoom = clampf(_zoom, _zmin(), _zmax())
	_gate = st
	_gate_dests.clear()
	for d in st["destinations"]:
		_gate_dests[int(d["system"])] = {"gate": int(d["gate"]), "name": str(d["name"]),
			"pos": Vector2(d["x"], d["y"])}
	_center = Vector2(st["hereX"], st["hereY"])
	_update_classic()
	_cursor = _canvas.size * 0.5
	_hover = -1
	_pad_mode = _pad_connected()
	visible = true
	nova.sound_beep(3)
	_canvas.queue_redraw()


func close() -> void:
	if not visible:
		return
	visible = false
	if not _gate.is_empty():
		nova.gate_picker_cancel()
		_gate = {}
	else:
		nova.nav_map_closed()   # closing re-syncs the route head (0x004a4fd0)
	_find_box.visible = false
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
	_marker.clear()
	var mk: PackedFloat32Array = nova.nav_marker_colors()
	var mi := 0
	while mi + 4 <= mk.size():
		_marker[int(mk[mi])] = Color(mk[mi + 1], mk[mi + 2], mk[mi + 3])
		mi += 4
	_links = nova.nav_links()
	_gate_links = nova.nav_gate_links() if bool(Prefs.get_value("map", "gate_links")) else PackedInt32Array()
	var neb = JSON.parse_string(nova.nav_nebulae(false))
	_nebulae = neb if neb is Array else []
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
	if not _gate.is_empty():
		# In gate mode only the gate's destinations can be picked.
		for id in _gate_dests:
			var dg := _to_screen(_gate_dests[id]["pos"]).distance_to(screen)
			if dg < best_d:
				best_d = dg
				best = id
		return best
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

	# Pan: the arrow keys or the right stick.
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

	_update_classic()
	if moved:
		_canvas.queue_redraw()


func _input(event: InputEvent) -> void:
	if not visible:
		return

	# The Find box owns the keyboard while it is up (Esc closes just the box).
	if _find_box.visible:
		if event.is_action_pressed("ui_cancel"):
			get_viewport().set_input_as_handled()
			_find_box.visible = false
			_canvas.queue_redraw()
		return

	# Closing (and the jump shortcut) first, so nothing leaks to the flight code.
	if event.is_action_pressed("map_close") or event.is_action_pressed("galaxy_map"):
		get_viewport().set_input_as_handled()
		close()
		return
	if event.is_action_pressed("hyperjump") and _gate.is_empty():
		get_viewport().set_input_as_handled()
		close()
		jump_requested.emit()
		return

	if event is InputEventMouseMotion:
		_pad_mode = false
		_cursor = _local(event.position)
		if _dragging:
			_center -= event.relative / (_zoom * _canvas_scale())
		_hover = _nearest(_cursor, MOUSE_RADIUS)
		_canvas.queue_redraw()
	elif event is InputEventMouseButton:
		_pad_mode = false
		var lp := _local(event.position)
		var inside := Rect2(Vector2.ZERO, _canvas.size).has_point(lp)
		if event.button_index == MOUSE_BUTTON_WHEEL_UP and event.pressed:
			_zoom_at(1.15, lp)
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN and event.pressed:
			_zoom_at(1.0 / 1.15, lp)
		elif event.button_index == MOUSE_BUTTON_RIGHT or event.button_index == MOUSE_BUTTON_MIDDLE:
			_dragging = event.pressed
		elif event.button_index == MOUSE_BUTTON_LEFT and event.pressed and inside:
			var id := _nearest(lp, MOUSE_RADIUS)
			if id != -1:
				_plot(id, event.shift_pressed)
	elif event is InputEventJoypadButton and event.pressed:
		match event.button_index:
			JOY_BUTTON_DPAD_LEFT: _step_direction(Vector2.LEFT)
			JOY_BUTTON_DPAD_RIGHT: _step_direction(Vector2.RIGHT)
			JOY_BUTTON_DPAD_UP: pass   # also "hyperjump", handled above
			JOY_BUTTON_DPAD_DOWN: _step_direction(Vector2.DOWN)

	if event.is_action_pressed("map_find") and _gate.is_empty():
		get_viewport().set_input_as_handled()
		open_find()
	elif event.is_action_pressed("map_zoom_in"):
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
	_zoom = clampf(_zoom * factor, _zmin(), _zmax())
	_center += before - _to_map(screen)   # keep the point under the cursor fixed
	_canvas.queue_redraw()


func _plot(id: int, extend: bool) -> void:
	if not _gate.is_empty():
		_pick_gate_destination(id)
		return
	if extend:
		nova.nav_shift_click(id)
	elif _auto_route:
		if not nova.nav_plot_course(id):
			message.emit("No route to that system")
	else:
		nova.nav_click(id)
	_reload_route()
	_canvas.queue_redraw()


# Gate mode: travel through the gate to the destination system `id`.
func _pick_gate_destination(id: int) -> void:
	if not _gate_dests.has(id):
		return
	if nova.gate_picker_choose(int(_gate_dests[id]["gate"])):
		visible = false
		_gate = {}
		_find_box.visible = false
		closed.emit()   # the bridge has already rebuilt the destination; Main resumes flight


# --- Find ------------------------------------------------------------------------

func _build_find_box() -> void:
	_find_box = PanelContainer.new()
	_find_box.visible = false
	_find_box.position = Vector2(20, 20)
	var box := HBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	var l := Label.new()
	l.text = "Find system:"
	box.add_child(l)
	_find_edit = LineEdit.new()
	_find_edit.custom_minimum_size = Vector2(260, 0)
	_find_edit.placeholder_text = "name…"
	_find_edit.text_submitted.connect(do_find)
	box.add_child(_find_edit)
	_find_box.add_child(box)
	add_child(_find_box)


func open_find() -> void:
	_find_edit.text = ""
	_find_box.visible = true
	_find_edit.grab_focus()
	if DisplayServer.has_feature(DisplayServer.FEATURE_VIRTUAL_KEYBOARD):
		DisplayServer.virtual_keyboard_show("")


## Run the original's Find on `query`: a hit selects the system (and plots a course there
## when auto-route is on) and centres the view; a miss just beeps. Returns the system id
## or -1.
func do_find(query: String) -> int:
	var id: int = nova.nav_find(query)
	_find_box.visible = false
	if id == -1:
		return -1
	if _auto_route:
		nova.nav_plot_course(id)
	_reload_route()
	if _info.has(id):
		_center = _info[id]["pos"]
	_canvas.queue_redraw()
	return id


func _system_label(id: int) -> String:
	var n: String = _names.get(id, "")
	return n if n != "" else "Unknown system"


# MARK: Drawing

func _pict_tex(id: int) -> Texture2D:
	if _tex.has(id):
		return _tex[id]
	var tex: Texture2D = null
	var info: PackedInt32Array = nova.pict_info(id)
	if info.size() >= 2 and info[0] > 0 and info[1] > 0:
		var bytes: PackedByteArray = nova.pict_rgba(id)
		if bytes.size() >= info[0] * info[1] * 4:
			tex = ImageTexture.create_from_image(
				Image.create_from_data(info[0], info[1], false, Image.FORMAT_RGBA8, bytes))
	_tex[id] = tex
	return tex


# Nebula art (0x004a51f0): each nebula is placed by its map-space box and drawn with the
# smallest of its seven zoom-level PICTs that is at least as wide or tall as the
# destination (the last one otherwise).
func _draw_nebulae() -> void:
	var view := Rect2(Vector2.ZERO, _neb.size)
	for neb in _nebulae:
		var tl := _to_screen(Vector2(neb["x"], neb["y"]))
		var rect := Rect2(tl.round(), (Vector2(neb["w"], neb["h"]) * _zoom).round())
		if not rect.intersects(view):
			continue
		var pick: Texture2D = null
		for pid in neb["picts"]:
			var t := _pict_tex(int(pid))
			if t == null:
				continue
			pick = t
			if rect.size.x <= t.get_width() or rect.size.y <= t.get_height():
				break
		if pick == null and int(neb["full"]) >= 0:
			pick = _pict_tex(int(neb["full"]))
		if pick != null:
			_neb.draw_texture_rect(pick, rect, false)


# --- Classic starmap (Apple GalaxyMapView.drawMap, non-fullscreen branch; orig 0x004a8100) ---

func _visited(id: int) -> bool:
	return _info.has(id) and int(_info[id]["vis"]) >= VIS_CHARTED


func _draw_classic(c: Control, size: Vector2) -> void:
	var view := Rect2(Vector2.ZERO, size).grow(60.0)
	var gate_mode := not _gate.is_empty()
	# Links: every one in theme grey 20000 (4000 in gate mode), 1 px; only those radiating
	# from a visited / charted system. The armed link is 0x009900.
	var w := (4000.0 if gate_mode else 20000.0) / 65535.0
	var grey := Color(w, w, w)
	var i := 0
	while i + 1 < _links.size():
		var a := _links[i]
		var b := _links[i + 1]
		i += 2
		if not (_visited(a) or _visited(b)):
			continue
		var pa := _to_screen(_info[a]["pos"])
		var pb := _to_screen(_info[b]["pos"])
		if not view.has_point(pa) and not view.has_point(pb):
			continue
		c.draw_line(pa, pb, grey, 1.0)
	if _armed and _route.size() > 0 and _info.has(_current) and _info.has(_route[0]):
		c.draw_line(_to_screen(_info[_current]["pos"]), _to_screen(_info[_route[0]]["pos"]), Color(0, 0x99 / 255.0, 0), 1.0)
	# Gate picker: spokes with +-45 degree barbs of 8 px, 3 px white for the selection, 2 px cyan.
	if gate_mode:
		var here := _to_screen(Vector2(_gate["hereX"], _gate["hereY"]))
		var sel := _hover if _hover != -1 else _selected
		for did in _gate_dests:
			var dp := _to_screen(_gate_dests[did]["pos"])
			var ang := (dp - here).angle()
			var col := Color.WHITE if did == sel else Color.CYAN
			var wd := 3.0 if did == sel else 2.0
			c.draw_line(here, dp, col, wd)
			for barb in [ang + PI * 3.0 / 4.0, ang - PI * 3.0 / 4.0]:
				c.draw_line(dp, dp + Vector2(cos(barb), sin(barb)) * 8.0, col, wd)
	elif _route.size() > 0 and _info.has(_current):
		# The plotted course: one solid 2 px green line.
		var pts := PackedVector2Array([_to_screen(_info[_current]["pos"])])
		for hop in _route:
			if not _info.has(hop):
				break
			pts.append(_to_screen(_info[hop]["pos"]))
		if pts.size() > 1:
			c.draw_polyline(pts, Color(0, 1, 0), 2.0)
	var font := ClassicTheme.body_font()
	var zoomed_in := 1.0 / _zoom <= 0.5
	var half := 6.0 if zoomed_in else 4.0
	var pen := 2.0 if zoomed_in else 1.0
	var show_labels := _zoom >= 1.0 / 1.1
	var selected := _selected
	for id in _ids:
		var p := _to_screen(_info[id]["pos"])
		if not view.has_point(p):
			continue
		var known := _visited(id)
		c.draw_circle(p, half, Color.BLACK)
		c.draw_arc(p, half - pen / 2.0, 0.0, TAU, 24, _marker.get(id, Color(0.25, 0.25, 0.25)), pen, true)
		if id == _current:
			c.draw_circle(p, 3.0 if zoomed_in else 2.0, Color.CYAN)
		if id == selected:
			# Eight 3 px strokes, 1 px in from each corner of the box (half-size 6, or 8 zoomed).
			var h := 8.0 if zoomed_in else 6.0
			var l := p.x - h
			var r := p.x + h
			var t := p.y - h
			var b := p.y + h
			var green := Color(0, 1, 0)
			for y in [t + 0.5, b + 0.5]:
				c.draw_line(Vector2(l + 1, y), Vector2(l + 4, y), green, 1.0)
				c.draw_line(Vector2(r - 1, y), Vector2(r - 4, y), green, 1.0)
			for x in [l + 0.5, r + 0.5]:
				c.draw_line(Vector2(x, t + 1), Vector2(x, t + 4), green, 1.0)
				c.draw_line(Vector2(x, b - 1), Vector2(x, b - 4), green, 1.0)
		# Geneva 9, white, pen at (x + 7, y + 4) on the baseline; explored / charted only.
		if known and _names.get(id, "") != "" and (show_labels or id == selected):
			c.draw_string(font, p + Vector2(7, 4), _names[id], HORIZONTAL_ALIGNMENT_LEFT, -1, 9, Color.WHITE)
	if _pad_mode:
		c.draw_arc(_cursor, 10.0, 0.0, TAU, 24, Color(0.4, 0.85, 1.0, 0.9), 1.0, true)


func _on_draw() -> void:
	var c := _canvas
	var size := c.size
	_neb.queue_redraw()
	if _framed:
		_draw_classic(c, size)
		return
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

	# Hypergate (cyan) and wormhole (violet) spokes: the opt-in enhancement.
	var gi := 0
	while gi + 2 < _gate_links.size():
		var ga := _gate_links[gi]
		var gb := _gate_links[gi + 1]
		var worm := _gate_links[gi + 2] != 0
		gi += 3
		if _info.has(ga) and _info.has(gb):
			c.draw_dashed_line(_to_screen(_info[ga]["pos"]), _to_screen(_info[gb]["pos"]),
				COLOR_GATE_WORM if worm else COLOR_GATE_HYPER, 1.3, 4.0)

	# Gate picker: bold blue spokes from here to each destination, a ring on each.
	if not _gate.is_empty():
		var here := _to_screen(Vector2(_gate["hereX"], _gate["hereY"]))
		for did in _gate_dests:
			var dp := _to_screen(_gate_dests[did]["pos"])
			c.draw_line(here, dp, COLOR_GATE_ROUTE, 3.0, true)
			c.draw_arc(dp, 9.0, 0.0, TAU, 24, COLOR_GATE_ROUTE, 2.0, true)
			if not _info.has(did):
				c.draw_circle(dp, 3.0, COLOR_GATE_ROUTE)
			if _zoom >= 0.5 or did == _hover:
				c.draw_string(ThemeDB.fallback_font, dp + Vector2(12.0, 4.0), str(_gate_dests[did]["name"]),
					HORIZONTAL_ALIGNMENT_LEFT, -1, ThemeDB.fallback_font_size - 2, COLOR_TEXT)

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

	if not _framed:
		_draw_panel(c, font, fs, size)


func _draw_panel(c: Control, font: Font, fs: int, size: Vector2) -> void:
	if not _gate.is_empty():
		_draw_gate_panel(c, font, fs, size)
		return
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

	var hint := ("L-stick cursor · D-pad next system · A plot · Y add hop · X auto-route · L3 find · D-pad ↑ jump · "
		+ "LB/RB zoom · R-stick pan · B close") if _pad_mode else (
		"Click plot · Shift+click add hop · J jump · T auto-route · F find · wheel zoom · right-drag pan · C center · M/Esc close")
	c.draw_string(font, Vector2(20, size.y - 16), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 2, COLOR_DIM)


# The gate picker's panel: the original's "select a destination" prompt (STR# 2002 #340)
# and the gate's name.
func _draw_gate_panel(c: Control, font: Font, fs: int, size: Vector2) -> void:
	var focus := _hover if _hover != -1 else -1
	var lines: Array = [str(_gate["name"]), str(_gate["prompt"])]
	if focus != -1:
		lines.append(str(_gate_dests[focus]["name"]))
	var h := lines.size() * (fs + 6) + 16
	var rect := Rect2(Vector2(20, size.y - h - 40), Vector2(430, h))
	c.draw_rect(rect, Color(0.04, 0.06, 0.1, 0.85))
	c.draw_rect(rect, Color(0.3, 0.45, 0.65, 0.6), false, 1.0)
	for n in lines.size():
		c.draw_string(font, rect.position + Vector2(10, 8 + (n + 1) * (fs + 6) - 4), lines[n],
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, COLOR_TEXT if n != 1 else COLOR_ROUTE)
	var hint := "Click / A pick a destination · wheel zoom · right-drag pan · Esc / B leave"
	c.draw_string(font, Vector2(20, size.y - 16), hint, HORIZONTAL_ALIGNMENT_LEFT, -1, fs - 2, COLOR_DIM)


# --- Classic frame -------------------------------------------------------------------------

func _zmin() -> float:
	return CLASSIC_ZOOM_MIN if _framed else ZOOM_MIN


func _zmax() -> float:
	return CLASSIC_ZOOM_MAX if _framed else ZOOM_MAX


## Build (or drop) the dialog frame for this opening, from the presentation setting.
func _apply_mode() -> void:
	ClassicTheme.setup(nova)
	var want: bool = ClassicTheme.has_data() and not Prefs.fullscreen_map() and ClassicTheme.pict(FRAME_PICT) != null
	if _frame != null:
		_neb.reparent(self, false)
		_canvas.reparent(self, false)
		_frame.queue_free()
		_frame = null
		_clip = null
	_framed = want
	if not want:
		_neb.set_anchors_preset(Control.PRESET_FULL_RECT)
		_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
		if _hint != null:
			_hint.visible = false
		return
	var me := self
	_frame = ClassicDialog.from_ditl(nova, 2000, {
		"frame_pict": FRAME_PICT, "default_item": 0, "cancel_item": 0,
		"actions": {0: me.close, 3: func(): me._step_zoom(0.75), 4: func(): me._step_zoom(1.0 / 0.75),
			7: func(): me._clear_route(), 9: func(): me.open_find()},
		"custom": {
			0: func(p, r): p.add_button(ClassicTheme.string_at(150, 5, "Done"), r, 0),
			3: func(p, r): me._minus = p.add_button("-", r, 3),
			4: func(p, r): me._plus = p.add_button("+", r, 4),
			7: func(p, r):
				me._clear = p.add_button(ClassicTheme.string_at(150, 49, "Clear Route"), r, 7)
				me._clear.refused.connect(func(): me.nova.sound_beep(4)),
			9: func(p, r): p.add_button(ClassicTheme.string_at(150, 60, "Find"), r, 9),
			2: func(p, r):
				me._clip = Control.new()
				me._clip.position = Vector2(r.position)
				me._clip.size = Vector2(r.size)
				me._clip.clip_contents = true
				p.add_child(me._clip),
			5: func(p, r): me._side = me._text_item(p, r, me._draw_side),
			1: func(p, r): me._bar = me._text_item(p, r, me._draw_bar),
		}})
	add_child(_frame)
	_neb.reparent(_clip, false)
	_canvas.reparent(_clip, false)
	_neb.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Pointer-only buttons: pad A plots on the map, so none of them may hold focus.
	for b in _frame.items.values():
		if b is BaseButton:
			b.focus_mode = Control.FOCUS_NONE
	_frame._focusables.clear()
	_frame.default_item = -1
	_info_key = ""
	# (the Classic frame has no help line under it: the original shows none)
	if _hint != null:
		_hint.visible = false


func _text_item(parent: Control, r: Rect2i, drawer: Callable) -> Control:
	var c := Control.new()
	c.position = Vector2(r.position)
	c.size = Vector2(r.size)
	c.clip_contents = true
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	c.draw.connect(drawer.bind(c))
	parent.add_child(c)
	return c


func _step_zoom(factor: float) -> void:
	_zoom_at(factor, _canvas.size * 0.5)
	_update_classic()


func _clear_route() -> void:
	if _route.size() == 0 or not _gate.is_empty():
		return
	nova.nav_clear_route()
	_reload_route()
	_canvas.queue_redraw()
	_update_classic()


## The system the info column describes: the selection, else the course's end, else here.
func _info_id() -> int:
	if _selected != -1:
		return _selected
	if _route.size() > 0:
		return _route[_route.size() - 1]
	return _current


## Refresh what the frame's text items and zoom / clear buttons show.
func _update_classic() -> void:
	if not _framed or _frame == null:
		return
	var id := _info_id()
	var key := "%d|%s|%s" % [id, _armed, _route.size()]
	if key != _info_key:
		_info_key = key
		var parsed = JSON.parse_string(nova.classic_map_info(id))
		_sys_text = parsed if parsed is Dictionary else {}
		_side.queue_redraw()
		_bar.queue_redraw()
	if _minus != null:
		_minus.disabled = _zoom <= CLASSIC_ZOOM_MIN + 0.0001
		_plus.disabled = _zoom >= CLASSIC_ZOOM_MAX - 0.0001
	if _clear != null:
		_clear.disabled = _route.size() == 0 or not _gate.is_empty()


func _qd(c: Control, text: String, x: float, y: float, color := Color.WHITE) -> float:
	var f := ClassicTheme.body_font()
	c.draw_string(f, Vector2(x, y), text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9, color)
	return f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x


## Item 5 (0x004a51f0): header and name, then Government, Legal Status, Goods, Services.
func _draw_side(c: Control) -> void:
	if _sys_text.is_empty():
		return
	var L: Dictionary = _sys_text["labels"]
	var level := int(_sys_text["level"])
	var gate_dest := not _gate.is_empty() and _gate_dests.has(_info_id())
	var header: String = L["destination"] if _armed else (L["current"] if _info_id() == _current
		else (L["gate"] if gate_dest else L["selected"]))
	_qd(c, header, 10, 12, THEME_LIGHT)
	_qd(c, str(_sys_text["name"]) if level >= 1 else str(L["unknown"]), 15, 26)
	if level < 1:
		return
	if not bool(_sys_text["usable"]):
		_qd(c, str(L["noPorts"]), 10, 75)
		return
	_qd(c, str(L["government"]), 10, 75, THEME_LIGHT)
	_qd(c, str(_sys_text["government"]), 15, 88)
	_qd(c, str(L["legalLabel"]), 10, 119, THEME_LIGHT)
	_qd(c, str(_sys_text["legal"]), 15, 132)
	_qd(c, str(L["goodsLabel"]), 10, 155, THEME_LIGHT)
	if level < 2:
		_qd(c, str(L["unknown"]), 15, 168)
	else:
		for i in _sys_text["goods"].size():
			_qd(c, str(_sys_text["goods"][i]), 15, 168 + 12 * i)
	_qd(c, str(L["servicesLabel"]), 10, 250, THEME_LIGHT)
	var tags: Array = _sys_text["services"]
	if level < 2:
		_qd(c, str(L["unknown"]), 15, 263)
	elif tags.is_empty():
		_qd(c, str(L["noServices"]), 15, 262)
	else:
		for i in tags.size():
			_qd(c, str(tags[i]), 15, 263 + 12 * i)


## Item 1: Ports (wrapping near the right edge), Navigation Hazards, the date; in the gate
## picker the "select a destination" prompt.
func _draw_bar(c: Control) -> void:
	if _sys_text.is_empty():
		return
	var L: Dictionary = _sys_text["labels"]
	var width := c.size.x
	var f := ClassicTheme.body_font()
	if not _gate.is_empty() and (_selected == -1 or _selected == _current):
		var prompt := str(L["gatePrompt"])
		_qd(c, prompt, (width - f.get_string_size(prompt, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x) / 2.0, 24, THEME_LIGHT)
		return
	var known := int(_sys_text["level"]) >= 1
	_qd(c, str(L["ports"]), 10, 12, THEME_LIGHT)
	if known:
		var names: Array = _sys_text["ports"]
		if names.is_empty():
			_qd(c, str(L["none"]), 45, 12)
		else:
			var pen := 45.0
			var y := 12.0
			var used := 0.0
			var sep := f.get_string_size(", ", HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x
			for i in names.size():
				var w := f.get_string_size(str(names[i]), HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x
				if width - 20.0 < w + 45.0 + used:
					pen = 45.0
					y = 24.0
					used = 0.0
				else:
					used += w
				_qd(c, str(names[i]), pen, y)
				pen += w
				if i < names.size() - 1:
					_qd(c, ", ", pen, y)
					pen += sep
					used += sep
	else:
		_qd(c, str(L["unknown"]), 45, 12)
	_qd(c, str(L["hazardsLabel"]), 10, 36, THEME_LIGHT)
	_qd(c, str(_sys_text["hazards"]) if known else str(L["unknown"]), 110, 36)
	var date := str(_sys_text["date"])
	_qd(c, date, width - f.get_string_size(date, HORIZONTAL_ALIGNMENT_LEFT, -1, 9).x - 5, 36, THEME_DIM)


## Viewport position -> the starmap canvas's own space (identity when full-screen).
func _local(p: Vector2) -> Vector2:
	return _canvas.get_global_transform().affine_inverse() * p


func _canvas_scale() -> float:
	return _canvas.get_global_transform().get_scale().x
