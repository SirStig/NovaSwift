# NOVA Swift — gamepad UI cursor (autoload "PadCursor").
#
# The Godot twin of the Apple app's stick-driven cursor (app/NovaSwift/Input/ControllerCursor.swift,
# docs/CONTROLS.md "The UI cursor"): the left stick moves a drawn pointer anywhere on screen, A clicks, the
# right stick scrolls, B backs out (ui_cancel, wired in Controls.gd) and the d-pad still walks focus. It works
# by SYNTHESISING MOUSE EVENTS (Input.parse_input_event), so every Button hover style, ItemList, slider drag and
# custom `_gui_input` in the frontend responds with no per-screen code.
#
#   PadCursor.suppress("flight") / PadCursor.release("flight")   owners that need the pad for themselves
#   PadCursor.set_suppressed(reason, on)                          the same, as one call
#   PadCursor.is_active()      enabled + pad connected + last input was the pad + nobody suppressing
#   PadCursor.cursor_position()  the pointer in viewport coordinates
#
# Suppression owners: Main.gd ("flight" while flying with the HUD, A fires weapons there; "intro" while a new
# pilot's intro plays), PadKeyboard ("keyboard" while open), GalaxyMap via Main ("map": it has its own cursor).
# Last input wins: a real mouse move (> 2 px) or any key hides the pointer; the next stick motion shows it again
# at the last mouse position (else the focused control's centre).
#
# Coordinates: the project stretches with canvas_items + aspect expand, so the pointer lives in VIEWPORT
# coordinates and parse_input_event wants WINDOW coordinates: window = get_viewport().get_final_transform() * pos
# (the viewport then maps it back with the inverse, landing on the same control).
#
# Settings (Prefs [input]): pad_cursor (bool, default on), cursor_speed (0.4-2.0, default 1.0).
extends CanvasLayer

const Prefs = preload("res://Prefs.gd")
const Controls = preload("res://Controls.gd")

const LAYER := 400                    # above PadKeyboard (200) and every screen
const SPEED_VIEWPORT_HEIGHTS := 1.1   # full-tilt speed, in viewport heights per second
const MAGNET_SLOW := 0.45             # speed factor while over something clickable
const GLIDE_TIME := 0.1               # d-pad focus change: pointer glides to the focused control
const SCROLL_MIN_HZ := 6.0
const SCROLL_MAX_HZ := 18.0
const AMBER := Color(1.0, 0.78, 0.35)
const SYNTH_WINDOW_MS := 150          # our own events echo back through _input within this long

signal activated(on: bool)

## Treat a pad as connected even when the OS reports none (tests, remote play).
var assume_pad := false
## The last input event came from a pad (or a stick pushed past the dead zone); flipped by mouse / keys.
var last_was_pad := false

var _reasons := {}
var _enabled := true
var _speed := 1.0
var _pos := Vector2.ZERO               # viewport coordinates
var _have_pos := false
var _seed_mouse := Vector2.ZERO        # last real mouse position
var _seed_mouse_known := false
var _alpha := 0.0
var _press := 0.0                      # 0..1 press animation
var _a_held := false
var _glide_t := -1.0
var _glide_from := Vector2.ZERO
var _glide_to := Vector2.ZERO
var _scroll_acc := Vector2.ZERO
var _last_synth_ms := -10000
var _last_click_frame := -10
var _over_clickable := false
var _stripped: Array = []              # [[action, InputEvent]] left-stick events removed from ui_*
var _pointer: Control

const _NAV_ACTIONS := ["ui_up", "ui_down", "ui_left", "ui_right"]


class Pointer extends Control:
	var owner_cursor: Node

	func _draw() -> void:
		if owner_cursor == null:
			return
		owner_cursor.draw_pointer(self)


func _ready() -> void:
	layer = LAYER
	process_mode = Node.PROCESS_MODE_ALWAYS
	_pointer = Pointer.new()
	(_pointer as Pointer).owner_cursor = self
	_pointer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_pointer.size = Vector2.ZERO
	add_child(_pointer)
	_read_prefs()
	Prefs.hub.changed.connect(func(section: String, _key: String):
		if section == "input":
			_read_prefs())
	get_viewport().gui_focus_changed.connect(_on_focus_changed)
	var kb: Node = get_node_or_null("/root/PadKeyboard")
	if kb != null:
		kb.opened.connect(func(_le): suppress("keyboard"))
		kb.closed.connect(func(_c): release("keyboard"))


func _exit_tree() -> void:
	_restore_stick_nav()


func _read_prefs() -> void:
	_enabled = bool(Prefs.get_value("input", "pad_cursor"))
	_speed = clampf(float(Prefs.get_value("input", "cursor_speed")), 0.4, 2.0)


# --- public API ------------------------------------------------------------------------------------------

func suppress(reason: String) -> void:
	_reasons[reason] = true


func release(reason: String) -> void:
	_reasons.erase(reason)


func set_suppressed(reason: String, on: bool) -> void:
	if on:
		_reasons[reason] = true
	else:
		_reasons.erase(reason)


func is_suppressed() -> bool:
	return not _reasons.is_empty()


## The cursor system can run at all (setting on, a pad present, nobody suppressing). The left stick then no
## longer moves focus, whether or not the pointer is currently showing.
func available() -> bool:
	return _enabled and _reasons.is_empty() and (assume_pad or Controls.pad_connected())


func is_active() -> bool:
	return available() and last_was_pad


func cursor_position() -> Vector2:
	return _pos


## True for the mouse events this node synthesised (so PadKeyboard / theme trackers don't read them as a mouse).
func is_synthetic(event: InputEvent) -> bool:
	if not (event is InputEventMouse):
		return false
	if Time.get_ticks_msec() - _last_synth_ms > SYNTH_WINDOW_MS:
		return false
	return (event as InputEventMouse).position.distance_to(_pos) < 1.5


# --- input -----------------------------------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if handle_event(event):
		get_viewport().set_input_as_handled()


## Folds one event in; returns true when it must be consumed (pad A over a clickable control).
func handle_event(event: InputEvent) -> bool:
	if is_synthetic(event):
		return false
	if event is InputEventMouseMotion:
		var mm := event as InputEventMouseMotion
		_seed_mouse = mm.position
		_seed_mouse_known = true
		if mm.relative.length() > 2.0:
			_pad_left()
	elif event is InputEventMouseButton or event is InputEventScreenTouch:
		if event is InputEventMouseButton:
			_seed_mouse = (event as InputEventMouseButton).position
			_seed_mouse_known = true
		_pad_left()
	elif event is InputEventKey:
		if (event as InputEventKey).pressed:
			_pad_left()
	elif event is InputEventJoypadButton and (event as InputEventJoypadButton).pressed:
		last_was_pad = true
	if not (event is InputEventJoypadButton):
		return false
	var jb := event as InputEventJoypadButton
	if jb.button_index != JOY_BUTTON_A:
		return false
	if jb.pressed:
		if not is_active() or not _have_pos or _alpha < 0.2:
			return false
		var target: Control = _clickable_at()
		if target == null:
			return false
		_a_held = true
		_send_button(MOUSE_BUTTON_LEFT, true)
		return true
	if _a_held:
		_a_held = false
		_send_button(MOUSE_BUTTON_LEFT, false)
		return true
	return false


func _pad_left() -> void:
	if last_was_pad:
		last_was_pad = false
		_have_pos = false   # re-seed from the mouse / focus on the next stick motion
	if _a_held:
		_a_held = false
		_send_button(MOUSE_BUTTON_LEFT, false)


# --- per frame -------------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	var avail: bool = available()
	if avail:
		_strip_stick_nav()
	else:
		_restore_stick_nav()
	var left := _stick(JOY_AXIS_LEFT_X, JOY_AXIS_LEFT_Y)
	var dz: float = clampf(Controls.stick_deadzone, 0.05, 0.6)
	if avail and not last_was_pad and left.length() > dz:
		last_was_pad = true
	var active: bool = avail and last_was_pad
	if active and not _have_pos:
		_seed_position()
	var target_alpha := 1.0 if active else 0.0
	_alpha = move_toward(_alpha, target_alpha, delta * 8.0)
	if not active:
		_scroll_acc = Vector2.ZERO
		if _a_held:
			_a_held = false
			_send_button(MOUSE_BUTTON_LEFT, false)
		_press = move_toward(_press, 0.0, delta * 8.0)
		_pointer.visible = _alpha > 0.01
		if _pointer.visible:
			_pointer.queue_redraw()
		return

	var vp := get_viewport().get_visible_rect().size
	var moved := false
	if left.length() > dz:
		_glide_t = -1.0
		var mag: float = clampf((left.length() - dz) / maxf(1.0 - dz, 0.001), 0.0, 1.0)
		var speed := vp.y * SPEED_VIEWPORT_HEIGHTS * _speed * pow(mag, 2.0)
		if _over_clickable:
			speed *= MAGNET_SLOW
		var next := (_pos + left.normalized() * speed * delta).clamp(Vector2.ZERO, vp)
		if next != _pos:
			var rel := next - _pos
			_pos = next
			_send_motion(rel)
			moved = true
	elif _glide_t >= 0.0:
		_glide_t += delta
		var k := clampf(_glide_t / GLIDE_TIME, 0.0, 1.0)
		k = 1.0 - pow(1.0 - k, 3.0)
		var next2 := _glide_from.lerp(_glide_to, k)
		var rel2 := next2 - _pos
		_pos = next2
		if rel2 != Vector2.ZERO:
			_send_motion(rel2)
			moved = true
		if _glide_t >= GLIDE_TIME:
			_glide_t = -1.0
	_update_hover(moved)

	# Right stick -> wheel events at the pointer.
	var right := _stick(JOY_AXIS_RIGHT_X, JOY_AXIS_RIGHT_Y)
	if right.length() > dz:
		var rmag: float = clampf((right.length() - dz) / maxf(1.0 - dz, 0.001), 0.0, 1.0)
		var hz := lerpf(SCROLL_MIN_HZ, SCROLL_MAX_HZ, rmag)
		_scroll_acc += Vector2(signf(right.x) if absf(right.x) > absf(right.y) * 0.6 else 0.0,
				signf(right.y) if absf(right.y) > absf(right.x) * 0.6 else 0.0) * hz * delta
		while absf(_scroll_acc.y) >= 1.0:
			_send_wheel(MOUSE_BUTTON_WHEEL_DOWN if _scroll_acc.y > 0.0 else MOUSE_BUTTON_WHEEL_UP)
			_scroll_acc.y -= signf(_scroll_acc.y)
		while absf(_scroll_acc.x) >= 1.0:
			_send_wheel(MOUSE_BUTTON_WHEEL_RIGHT if _scroll_acc.x > 0.0 else MOUSE_BUTTON_WHEEL_LEFT)
			_scroll_acc.x -= signf(_scroll_acc.x)
	else:
		_scroll_acc = Vector2.ZERO

	_press = move_toward(_press, 1.0 if _a_held else 0.0, delta * (14.0 if _a_held else 7.0))
	_pointer.visible = true
	_pointer.position = _pos
	_pointer.queue_redraw()


func _stick(ax: int, ay: int) -> Vector2:
	var best := Vector2.ZERO
	for dev in Input.get_connected_joypads():
		var v := Vector2(Input.get_joy_axis(dev, ax), Input.get_joy_axis(dev, ay))
		if v.length() > best.length():
			best = v
	return best


func _seed_position() -> void:
	var vp := get_viewport().get_visible_rect().size
	var fo: Control = get_viewport().gui_get_focus_owner()
	if _seed_mouse_known and Rect2(Vector2.ZERO, vp).has_point(_seed_mouse):
		_pos = _seed_mouse
	elif fo != null and fo.is_visible_in_tree():
		_pos = _control_center(fo)
	else:
		_pos = vp * 0.5
	_have_pos = true
	_glide_t = -1.0
	_pointer.position = _pos
	activated.emit(true)


func _control_center(c: Control) -> Vector2:
	var vp := get_viewport().get_visible_rect().size
	var p: Vector2 = c.get_global_transform_with_canvas() * (c.size * 0.5)
	return p.clamp(Vector2.ZERO, vp)


func _on_focus_changed(c: Control) -> void:
	if c == null or not is_active() or not _have_pos:
		return
	if Engine.get_process_frames() - _last_click_frame <= 1:
		return   # focus moved because WE clicked: stay where the click was
	if not c.is_visible_in_tree():
		return
	_glide_from = _pos
	_glide_to = _control_center(c)
	_glide_t = 0.0


# --- synthesised events ----------------------------------------------------------------------------------

func _window_pos(p: Vector2) -> Vector2:
	return get_viewport().get_final_transform() * p


func _send_motion(rel: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	var w := _window_pos(_pos)
	e.position = w
	e.global_position = w
	e.relative = get_viewport().get_final_transform().basis_xform(rel)
	e.button_mask = MOUSE_BUTTON_MASK_LEFT if _a_held else 0
	_last_synth_ms = Time.get_ticks_msec()
	Input.parse_input_event(e)
	Input.flush_buffered_events()


func _send_button(button: int, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	var w := _window_pos(_pos)
	e.position = w
	e.global_position = w
	e.button_index = button
	e.pressed = pressed
	e.button_mask = MOUSE_BUTTON_MASK_LEFT if pressed and button == MOUSE_BUTTON_LEFT else 0
	e.double_click = false
	_last_synth_ms = Time.get_ticks_msec()
	_last_click_frame = Engine.get_process_frames()
	Input.parse_input_event(e)
	Input.flush_buffered_events()


func _send_wheel(button: int) -> void:
	_send_button(button, true)
	_send_button(button, false)
	_last_click_frame = -10


## Re-sends a zero-motion event when idle so hover state follows UI that changed under a resting pointer.
func _update_hover(moved: bool) -> void:
	if not moved and Engine.get_process_frames() % 20 == 0:
		_send_motion(Vector2.ZERO)
	_over_clickable = _clickable_at() != null


# --- hit testing -----------------------------------------------------------------------------------------

## The clickable Control under the pointer (a live button, field, list, slider, scroll bar, tab bar... or a
## scripted STOP control with its own `_gui_input`), or null over empty space.
func _clickable_at() -> Control:
	var c: Control = get_viewport().gui_get_hovered_control()
	if _popup_at():
		return c if c != null else _pointer   # an open dropdown list: everything in it is clickable
	while c != null:
		if is_clickable(c):
			return c
		c = c.get_parent() as Control
	return null


func _popup_at() -> bool:
	for w in get_tree().root.get_children():
		if w is PopupMenu and (w as Window).visible:
			if Rect2(Vector2((w as Window).position), Vector2((w as Window).size)).has_point(_window_pos(_pos)):
				return true
	return false


static func is_clickable(c: Control) -> bool:
	if not c.is_visible_in_tree() or c.mouse_filter == Control.MOUSE_FILTER_IGNORE:
		return false
	if c is BaseButton:
		return not (c as BaseButton).disabled
	if c is LineEdit:
		return (c as LineEdit).editable
	if c is TextEdit:
		return (c as TextEdit).editable
	if c is ItemList or c is Tree or c is Slider or c is ScrollBar or c is TabBar or c is SpinBox \
			or c is ColorPicker or c is TabContainer or c is MenuBar:
		return true
	if c.get_script() != null and c.mouse_filter == Control.MOUSE_FILTER_STOP \
			and (c.has_method("_gui_input") or c.has_meta("pad_clickable")):
		return true
	return c.has_meta("pad_clickable")


# --- left stick must not also walk focus -----------------------------------------------------------------

func _strip_stick_nav() -> void:
	if not _stripped.is_empty():
		return
	for a in _NAV_ACTIONS:
		if not InputMap.has_action(a):
			continue
		for ev in InputMap.action_get_events(a):
			if ev is InputEventJoypadMotion and ((ev as InputEventJoypadMotion).axis == JOY_AXIS_LEFT_X \
					or (ev as InputEventJoypadMotion).axis == JOY_AXIS_LEFT_Y):
				_stripped.append([a, ev])
	for pair in _stripped:
		InputMap.action_erase_event(pair[0], pair[1])


func _restore_stick_nav() -> void:
	for pair in _stripped:
		if not InputMap.action_has_event(pair[0], pair[1]):
			InputMap.action_add_event(pair[0], pair[1])
	_stripped.clear()


# --- drawing ---------------------------------------------------------------------------------------------

const _ARROW := [Vector2(0, 0), Vector2(0, 17), Vector2(4.4, 13.1), Vector2(7.2, 19.6),
	Vector2(10.0, 18.4), Vector2(7.3, 12.2), Vector2(12.8, 12.2)]


func draw_pointer(ci: CanvasItem) -> void:
	if _alpha <= 0.01:
		return
	var s: float = clampf(get_viewport().get_visible_rect().size.y / 720.0, 1.0, 2.6)
	s *= lerpf(1.0, 0.88, _press)
	var a := _alpha
	# Soft glow around the tip, contracting when pressed.
	var cen := Vector2(1.5, 2.5) * s
	var ring := lerpf(15.0, 10.0, _press) * s
	for i in 4:
		var r := ring + (3 - i) * 2.4 * s
		ci.draw_circle(cen, r, Color(AMBER.r, AMBER.g, AMBER.b, a * (0.035 + 0.02 * i)))
	ci.draw_arc(cen, ring, 0.0, TAU, 40, Color(AMBER.r, AMBER.g, AMBER.b, a * (0.55 + 0.35 * _press)), 1.6 * s, true)
	# Arrow: dark outline, cream fill.
	var pts := PackedVector2Array()
	for p in _ARROW:
		pts.append((p as Vector2) * s)
	var closed: PackedVector2Array = pts.duplicate()
	closed.append(pts[0])
	ci.draw_colored_polygon(pts, Color(1.0, 0.96, 0.86, a))
	ci.draw_polyline(closed, Color(0.04, 0.04, 0.07, a), 2.6 * s, true)


# --- testing hooks ---------------------------------------------------------------------------------------

## Put the pointer at viewport position `p` (active, shown) and deliver the hover.
func debug_move_to(p: Vector2) -> void:
	assume_pad = true
	last_was_pad = true
	_have_pos = true
	_alpha = 1.0
	var rel := p - _pos
	_pos = p
	_glide_t = -1.0
	_send_motion(rel)
	_over_clickable = _clickable_at() != null


## Press / release pad A through the real handler; returns whether the event would be consumed.
func debug_press_a(pressed := true) -> bool:
	var e := InputEventJoypadButton.new()
	e.button_index = JOY_BUTTON_A
	e.pressed = pressed
	return handle_event(e)


func debug_scroll(down := true, times := 1) -> void:
	for i in times:
		_send_wheel(MOUSE_BUTTON_WHEEL_DOWN if down else MOUSE_BUTTON_WHEEL_UP)
