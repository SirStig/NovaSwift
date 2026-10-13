# NOVA Swift -- Godot action wheels: input state machine + radial overlay (mirrors the Apple app's
# GameControllerInput wheel block and UI/ActionWheelOverlay.swift). Data lives in ActionWheels.gd.
#
# HOLD a wheel's trigger (default LB / RB / Back): after HOLD_DELAY, or as soon as the right stick is pushed past 0.5
# AFTER the press (a stick already aiming at press time doesn't count, so tapping LB mid-aim stays a tap), the wheel
# opens. The right stick then picks a slot (slot 0 on top, clockwise; the pick is sticky); releasing the trigger uses
# it; never picking one cancels; pad B cancels and that press never reaches fire_secondary (Main suppresses it via
# `cancelled`). The left stick and triggers keep flying. While open the right-stick aim is suspended (Main) and, by
# default, the sim is paused (Prefs [wheels] pause) -- Main asks `pausing()`.
#
# A quick tap (release before HOLD_DELAY, no stick) fires the button's normal action(s) on release: Controls.register
# strips the trigger buttons off the Flight actions (Controls.wheel_taps) precisely so this node owns the press.
# Actions are fired with Input.action_press and released on the NEXT frame; the node runs at priority -100 so Main's
# is_action_just_pressed sees the press the same frame. `pause_menu` is only signalled (it is an event action).
# self_destruct latches (the original holds it five seconds) until ANY pad button press aborts it.
#
# Only live in plain flight: Main sets `live` each frame (the same gate that stands the PadCursor down). Losing it
# closes the wheel without firing.
extends CanvasLayer

const Controls = preload("res://Controls.gd")
const ActionWheels = preload("res://ActionWheels.gd")
const Prefs = preload("res://Prefs.gd")
const T = preload("res://ui/novaswift/NovaTheme.gd")
const Model = preload("res://screens/controls_editor/EditorModel.gd")
const Art = preload("res://screens/controls_editor/ControllerArt.gd")

## An action was chosen (tap or slot). Main acts on "pause_menu"; everything else is already pressed in InputMap.
signal fired(action: String)
## The open wheel was cancelled with pad B (Main keeps fire_secondary suppressed until B is released).
signal cancelled

const FADE_TIME := 0.12
const STICK_OPEN := 0.5

## Set by Main every frame it is in plain flight with the HUD.
var live := false
## Callables Main provides: () -> bool escort panel up; () -> float pixels the HUD reserves on the right;
## (Vector2 viewport) -> Rect2 a HUD rect to stay clear of.
var escort_panel_open: Callable = Callable()
var right_inset: Callable = Callable()
var avoid_rect: Callable = Callable()

var _down: Dictionary = {}          # trigger button -> true while physically held
var _hold: Dictionary = {}          # {wheel, button, start, aim_at_press, open, cancelled, selected}
var _pending: Array = []            # actions pressed last frame, released this one
var _latched := false               # self-destruct latched
var _view: Control
var _anim := 0.0
var _shown: Dictionary = {}         # the wheel the overlay draws (kept while it fades out)
var _shown_selected := -1
var _style_cache := ""


func _init() -> void:
	layer = 70
	process_priority = -100
	process_mode = Node.PROCESS_MODE_ALWAYS


func _ready() -> void:
	_view = Control.new()
	_view.set_anchors_preset(Control.PRESET_FULL_RECT)
	_view.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_view.draw.connect(_draw_wheel)
	add_child(_view)


# MARK: State -------------------------------------------------------------------------------------------------

func is_open() -> bool:
	return not _hold.is_empty() and bool(_hold["open"]) and not bool(_hold["cancelled"])


## Main skips the sim step while this is true.
func pausing() -> bool:
	return is_open() and ActionWheels.pause_while_open


func highlighted() -> int:
	return int(_hold["selected"]) if is_open() else -1


func open_wheel() -> Dictionary:
	return (_hold["wheel"] as Dictionary) if is_open() else {}


func _stick() -> Vector2:
	return Input.get_vector("aim_left", "aim_right", "aim_up", "aim_down", 0.0)


func _input(event: InputEvent) -> void:
	if not (event is InputEventJoypadButton):
		return
	var jb: InputEventJoypadButton = event
	var b: int = jb.button_index
	if jb.pressed:
		if _latched:   # any pad press aborts a latched wheel self-destruct
			_latched = false
			Input.action_release("self_destruct")
		if b == JOY_BUTTON_B and not _hold.is_empty() and bool(_hold["open"]) and not bool(_hold["cancelled"]):
			_hold["cancelled"] = true
			cancelled.emit()
			get_viewport().set_input_as_handled()
			return
		if _down.has(b):
			return
		_down[b] = true
		if live and _hold.is_empty():
			var w: Dictionary = ActionWheels.wheel_for(b)
			if not w.is_empty():
				_hold = {"wheel": w, "button": b, "start": Time.get_ticks_msec() / 1000.0,
					"aim_at_press": _stick().length() > STICK_OPEN, "open": false, "cancelled": false, "selected": -1}
	else:
		_down.erase(b)
		if not _hold.is_empty() and int(_hold["button"]) == b:
			_release()


func _release() -> void:
	var h: Dictionary = _hold
	_hold = {}
	if not bool(h["open"]):
		for a in Controls.wheel_taps.get(int(h["button"]), []):   # a tap: the button's own action, on release
			_fire(str(a))
	elif not bool(h["cancelled"]):
		var slots: Array = (h["wheel"] as Dictionary)["slots"]
		var i: int = int(h["selected"])
		if i >= 0 and i < slots.size():
			_fire(str(slots[i]))


func _fire(action: String) -> void:
	fired.emit(action)
	if action == "pause_menu" or not InputMap.has_action(action):
		return
	Input.action_press(action)
	if action == "self_destruct":
		_latched = true
	else:
		_pending.append(action)


func _process(delta: float) -> void:
	for a in _pending:
		Input.action_release(str(a))
	_pending.clear()
	if not _hold.is_empty():
		if not live:
			_hold = {}   # the HUD flight state went away (menu, dialog, map): close without firing
		elif not bool(_hold["open"]):
			var v: Vector2 = _stick()
			if v.length() <= STICK_OPEN:
				_hold["aim_at_press"] = false
			var held_for: float = Time.get_ticks_msec() / 1000.0 - float(_hold["start"])
			if held_for >= ActionWheels.HOLD_DELAY or (v.length() > STICK_OPEN and not bool(_hold["aim_at_press"])):
				_open_now()
		if is_open():
			var v2: Vector2 = _stick()
			var n: int = ((_hold["wheel"] as Dictionary)["slots"] as Array).size()
			var i: int = ActionWheels.slot_for_stick(v2, n, STICK_OPEN)
			if i >= 0 and i != int(_hold["selected"]):
				_hold["selected"] = i   # sticky: recentring keeps the pick
				_rumble()
	var target: float = 1.0 if is_open() else 0.0
	_anim = move_toward(_anim, target, delta / FADE_TIME)
	if is_open():
		_shown = _hold["wheel"]
		_shown_selected = int(_hold["selected"])
	_view.visible = _anim > 0.0
	if _view.visible:
		_view.queue_redraw()


func _open_now() -> void:
	_hold["open"] = true
	var w: Dictionary = _hold["wheel"]
	# While the Escort Commands panel is up, the wheel that holds it becomes the group picker.
	if "escort_panel" in (w["slots"] as Array) and escort_panel_open.is_valid() and bool(escort_panel_open.call()):
		_hold["wheel"] = ActionWheels.ESCORT_WHEEL
	_hold["selected"] = -1
	_shown_selected = -1
	_rumble()


func _rumble() -> void:
	var pads: Array = Input.get_connected_joypads()
	if not pads.is_empty():
		Input.start_joy_vibration(int(pads[0]), 0.0, 0.25, 0.03)


# MARK: Overlay -----------------------------------------------------------------------------------------------

func _pad_style() -> String:
	var s: String = str(Prefs.get_value("input", "ctl_pad_style"))
	if s == "playstation" or s == "switch" or s == "deck" or s == "xbox":
		return s
	var pads: Array = Input.get_connected_joypads()
	if pads.is_empty():
		return "xbox"
	var n: String = Input.get_joy_name(int(pads[0])).to_lower()
	if "playstation" in n or "dualsense" in n or "dualshock" in n or "ps5" in n or "ps4" in n:
		return "playstation"
	if "nintendo" in n or "switch" in n:
		return "switch"
	if "steam" in n:
		return "deck"
	return "xbox"


## Where the wheel sits and how big: low on the side of its trigger, ~32 px (scaled) from the edges, left of the
## HUD's right-hand bar and nudged up off any HUD rect.
func layout_for(wheel: Dictionary, vp: Vector2) -> Dictionary:
	var us: float = clampf(float(Prefs.get_value("interface", "ui_scale")), 0.8, 1.4)
	var radius: float = minf(190.0 * us, minf(vp.x, vp.y) * 0.30)
	var push: float = 10.0 * us
	var outer: float = radius + push
	var margin: float = 32.0 * us
	var right: bool = str(wheel.get("anchor", "left")) == "right"
	var inset: float = float(right_inset.call()) if right_inset.is_valid() else 0.0
	var cx: float = vp.x - inset - margin - outer if right else margin + outer
	var cy: float = vp.y - margin - outer
	if avoid_rect.is_valid():
		var r: Variant = avoid_rect.call(vp)
		if r is Rect2 and (r as Rect2).size != Vector2.ZERO:
			var rect: Rect2 = r
			var box := Rect2(Vector2(cx - outer, cy - outer), Vector2(outer * 2.0, outer * 2.0))
			if box.intersects(rect):
				cy = maxf(margin + outer, rect.position.y - outer - 8.0 * us)
	return {"center": Vector2(cx, cy), "radius": radius, "push": push, "scale": us}


func _wedge(c: Vector2, r0: float, r1: float, a0: float, a1: float) -> PackedVector2Array:
	var pts := PackedVector2Array()
	var steps: int = maxi(3, int(absf(a1 - a0) / 0.08))
	for k in steps + 1:
		var a: float = lerpf(a0, a1, float(k) / float(steps))
		pts.append(c + Vector2(cos(a), sin(a)) * r1)
	for k in steps + 1:
		var a2: float = lerpf(a1, a0, float(k) / float(steps))
		pts.append(c + Vector2(cos(a2), sin(a2)) * r0)
	return pts


func _draw_wheel() -> void:
	if _shown.is_empty() or _anim <= 0.0:
		return
	var cv: Control = _view
	var vp: Vector2 = cv.size
	var lay: Dictionary = layout_for(_shown, vp)
	var c: Vector2 = lay["center"]
	var radius: float = lay["radius"]
	var push: float = lay["push"]
	var us: float = lay["scale"]
	var slots: Array = _shown["slots"]
	var n: int = slots.size()
	if n == 0:
		return
	var alpha: float = _anim
	var sc: float = 0.9 + 0.1 * _anim
	cv.draw_set_transform(c * (1.0 - sc), 0.0, Vector2(sc, sc))
	var font: Font = ThemeDB.fallback_font
	var r0: float = radius * 0.38
	var step: float = TAU / float(n)
	var gap: float = 0.035
	# Backing disc
	cv.draw_circle(c, radius + 6.0 * us, Color(0.0, 0.0, 0.0, 0.42 * alpha))
	for i in n:
		var mid: float = float(i) * step - PI * 0.5
		var hot: bool = i == _shown_selected
		var off: Vector2 = Vector2(cos(mid), sin(mid)) * (push if hot else 0.0)
		var poly: PackedVector2Array = _wedge(c + off, r0, radius, mid - step * 0.5 + gap, mid + step * 0.5 - gap)
		var fill: Color = Color(T.ACCENT.r, T.ACCENT.g, T.ACCENT.b, 0.88 * alpha) if hot \
			else Color(0.07, 0.08, 0.10, 0.80 * alpha)
		cv.draw_colored_polygon(poly, fill)
		var edge: Color = Color(1, 1, 1, 0.55 * alpha) if hot else Color(1, 1, 1, 0.12 * alpha)
		var closed: PackedVector2Array = poly.duplicate()
		closed.append(poly[0])
		cv.draw_polyline(closed, edge, 1.5 * us, true)
		var action: String = str(slots[i])
		# Category stripe along the rim
		var cat: Color = Model.cat_color(action)
		cv.draw_arc(c + off, radius - 3.0 * us, mid - step * 0.5 + gap * 2.0, mid + step * 0.5 - gap * 2.0, 12,
			Color(cat.r, cat.g, cat.b, (1.0 if hot else 0.75) * alpha), 3.0 * us, true)
		# Glyph / short label at mid-radius
		var label: String = Model.short_label(action)
		var fs: int = int(round((13.0 if n <= 8 else 11.0) * us))
		var sz: Vector2 = font.get_string_size(label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		var lp: Vector2 = c + off + Vector2(cos(mid), sin(mid)) * (r0 + (radius - r0) * 0.52)
		var tc: Color = Color(0.05, 0.04, 0.02, alpha) if hot else Color(1, 1, 1, 0.92 * alpha)
		cv.draw_string(font, lp + Vector2(-sz.x * 0.5, sz.y * 0.3), label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, tc)
	# Hub
	cv.draw_circle(c, r0 - 4.0 * us, Color(0.03, 0.03, 0.04, 0.92 * alpha))
	cv.draw_arc(c, r0 - 4.0 * us, 0.0, TAU, 48, Color(1, 1, 1, 0.14 * alpha), 1.5 * us, true)
	var title: String = str(_shown.get("title", ""))
	var tfs: int = int(round(11.0 * us))
	var tsz: Vector2 = font.get_string_size(title, HORIZONTAL_ALIGNMENT_LEFT, -1, tfs)
	cv.draw_string(font, c + Vector2(-tsz.x * 0.5, -r0 * 0.45), title, HORIZONTAL_ALIGNMENT_LEFT, -1, tfs,
		Color(1, 1, 1, 0.55 * alpha))
	var pick: String = ""
	if _shown_selected >= 0 and _shown_selected < n:
		pick = str(Controls.ACTION_LABELS.get(str(slots[_shown_selected]), slots[_shown_selected]))
	var pfs: int = int(round(13.0 * us))
	var psz: Vector2 = font.get_string_size(pick, HORIZONTAL_ALIGNMENT_LEFT, -1, pfs)
	if psz.x > r0 * 1.7 and pick.length() > 4:   # long names: shrink to fit the hub
		pfs = maxi(8, int(round(float(pfs) * r0 * 1.7 / psz.x)))
		psz = font.get_string_size(pick, HORIZONTAL_ALIGNMENT_LEFT, -1, pfs)
	cv.draw_string(font, c + Vector2(-psz.x * 0.5, 4.0 * us), pick, HORIZONTAL_ALIGNMENT_LEFT, -1, pfs,
		Color(T.ACCENT.r, T.ACCENT.g, T.ACCENT.b, alpha))
	var h1: String = "Release to use"
	var h2: String = "%s cancel" % Art.button_name(_pad_style(), JOY_BUTTON_B)
	var hfs: int = int(round(9.0 * us))
	var s1: Vector2 = font.get_string_size(h1, HORIZONTAL_ALIGNMENT_LEFT, -1, hfs)
	var s2: Vector2 = font.get_string_size(h2, HORIZONTAL_ALIGNMENT_LEFT, -1, hfs)
	cv.draw_string(font, c + Vector2(-s1.x * 0.5, r0 * 0.5), h1, HORIZONTAL_ALIGNMENT_LEFT, -1, hfs, Color(1, 1, 1, 0.45 * alpha))
	cv.draw_string(font, c + Vector2(-s2.x * 0.5, r0 * 0.5 + 12.0 * us), h2, HORIZONTAL_ALIGNMENT_LEFT, -1, hfs, Color(1, 1, 1, 0.45 * alpha))
	cv.draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
