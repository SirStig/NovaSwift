# NOVA Swift — Controls Editor controller art: four procedurally drawn pad silhouettes (Xbox,
# PlayStation, Nintendo Switch Pro, Steam Deck) in a 1000 x 640 design space. Vector paths only —
# Catmull-Rom body outlines with grips, vertex-gradient shading, stick wells, a d-pad cross,
# coloured face buttons, bumpers and triggers. No vendor bitmaps or logos.
#
# layout(style)  -> {"size": Vector2, "controls": [ {id, name, kind, c, size, side, bindable, role} ]}
#   id is a JoyButton (bindable) or a String ("lt" "rt" "ls" "rs" "l4"...), `role` a fixed-role key.
# draw(ci, style) draws the static art with `ci` (a CanvasItem whose transform maps design space).
#
# Loaded with preload() (no class_name), like Controls.gd.
extends RefCounted

const T = preload("res://ui/novaswift/NovaTheme.gd")

const SIZE := Vector2(1000, 640)

const BODY_XBOX := [Vector2(0, 150), Vector2(120, 140), Vector2(250, 150), Vector2(330, 175), Vector2(380, 230),
	Vector2(415, 320), Vector2(445, 420), Vector2(450, 490), Vector2(425, 540), Vector2(375, 552), Vector2(335, 520),
	Vector2(300, 460), Vector2(260, 420), Vector2(190, 405), Vector2(90, 400), Vector2(0, 402)]
const BODY_PS := [Vector2(0, 168), Vector2(110, 152), Vector2(230, 156), Vector2(310, 176), Vector2(365, 222),
	Vector2(400, 300), Vector2(425, 400), Vector2(440, 480), Vector2(425, 540), Vector2(385, 562), Vector2(345, 536),
	Vector2(320, 480), Vector2(285, 432), Vector2(215, 408), Vector2(110, 400), Vector2(0, 398)]
const BODY_SWITCH := [Vector2(0, 155), Vector2(130, 148), Vector2(260, 155), Vector2(335, 180), Vector2(385, 235),
	Vector2(418, 320), Vector2(440, 410), Vector2(443, 490), Vector2(420, 538), Vector2(375, 548), Vector2(338, 520),
	Vector2(305, 462), Vector2(265, 425), Vector2(190, 408), Vector2(90, 402), Vector2(0, 404)]

const FIXED_ROLES := {
	"Flight": {"lt": "Reverse / brake", "rt": "Thrust", "ls": "Steer / Thrust", "rs": "Aim"},
	"Docked": {"lt": "", "rt": "", "ls": "Move focus", "rs": ""},
	"Galaxy map": {"lt": "", "rt": "", "ls": "Cursor", "rs": "Pan"},
}


static func style_index(style: String) -> int:
	return maxi(0, ["xbox", "playstation", "switch", "deck"].find(style))


# --- control names per style ---------------------------------------------------------------

static func button_name(style: String, id: int) -> String:
	match id:
		JOY_BUTTON_A: return {"xbox": "A", "playstation": "Cross", "switch": "B", "deck": "A"}[style]
		JOY_BUTTON_B: return {"xbox": "B", "playstation": "Circle", "switch": "A", "deck": "B"}[style]
		JOY_BUTTON_X: return {"xbox": "X", "playstation": "Square", "switch": "Y", "deck": "X"}[style]
		JOY_BUTTON_Y: return {"xbox": "Y", "playstation": "Triangle", "switch": "X", "deck": "Y"}[style]
		JOY_BUTTON_LEFT_SHOULDER: return {"xbox": "LB", "playstation": "L1", "switch": "L", "deck": "L1"}[style]
		JOY_BUTTON_RIGHT_SHOULDER: return {"xbox": "RB", "playstation": "R1", "switch": "R", "deck": "R1"}[style]
		JOY_BUTTON_LEFT_STICK: return "L3"
		JOY_BUTTON_RIGHT_STICK: return "R3"
		JOY_BUTTON_BACK: return {"xbox": "View", "playstation": "Create", "switch": "Minus", "deck": "View"}[style]
		JOY_BUTTON_START: return {"xbox": "Menu", "playstation": "Options", "switch": "Plus", "deck": "Menu"}[style]
		JOY_BUTTON_DPAD_UP: return "D-pad up"
		JOY_BUTTON_DPAD_DOWN: return "D-pad down"
		JOY_BUTTON_DPAD_LEFT: return "D-pad left"
		JOY_BUTTON_DPAD_RIGHT: return "D-pad right"
	return "Button %d" % id


static func trigger_name(style: String, left: bool) -> String:
	match style:
		"xbox": return "LT" if left else "RT"
		"switch": return "ZL" if left else "ZR"
	return "L2" if left else "R2"


## Every JoyButton the editor can bind (same on all styles).
const BINDABLE := [JOY_BUTTON_A, JOY_BUTTON_B, JOY_BUTTON_X, JOY_BUTTON_Y, JOY_BUTTON_LEFT_SHOULDER,
	JOY_BUTTON_RIGHT_SHOULDER, JOY_BUTTON_LEFT_STICK, JOY_BUTTON_RIGHT_STICK, JOY_BUTTON_BACK, JOY_BUTTON_START,
	JOY_BUTTON_DPAD_UP, JOY_BUTTON_DPAD_DOWN, JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_RIGHT]


# --- layout --------------------------------------------------------------------------------

static func _ctl(id: Variant, nm: String, kind: String, c: Vector2, sz: Vector2, bindable := true, role := "") -> Dictionary:
	return {"id": id, "name": nm, "kind": kind, "c": c, "size": sz,
		"side": "L" if c.x < SIZE.x * 0.5 else "R", "bindable": bindable, "role": role}


static func layout(style: String) -> Dictionary:
	var list: Array = []
	var s := style
	var lstick := Vector2.ZERO
	var rstick := Vector2.ZERO
	var dpad := Vector2.ZERO
	var face := Vector2.ZERO
	var fo := 40.0
	var back := Vector2.ZERO
	var start := Vector2.ZERO
	var l1 := Vector2(350, 122)
	var l2 := Vector2(350, 68)
	var shoulder := Vector2(170, 34)
	match style:
		"xbox":
			lstick = Vector2(345, 255); rstick = Vector2(575, 365); dpad = Vector2(425, 365)
			face = Vector2(655, 255); back = Vector2(450, 255); start = Vector2(550, 255)
		"playstation":
			l1 = Vector2(320, 128); l2 = Vector2(320, 72); shoulder = Vector2(160, 30)
			lstick = Vector2(385, 395); rstick = Vector2(615, 395); dpad = Vector2(300, 270)
			face = Vector2(700, 270); back = Vector2(420, 205); start = Vector2(580, 205)
		"switch":
			lstick = Vector2(330, 255); rstick = Vector2(590, 380); dpad = Vector2(410, 380)
			face = Vector2(670, 255); back = Vector2(440, 215); start = Vector2(560, 215)
		"deck":
			l1 = Vector2(165, 120); l2 = Vector2(165, 72); shoulder = Vector2(190, 30)
			lstick = Vector2(170, 230); rstick = Vector2(830, 330); dpad = Vector2(170, 335)
			face = Vector2(830, 230); fo = 38.0; back = Vector2(255, 262); start = Vector2(745, 262)
	var r_l2 := Vector2(SIZE.x - l2.x, l2.y)
	var r_l1 := Vector2(SIZE.x - l1.x, l1.y)
	list.append(_ctl("lt", trigger_name(s, true), "rrect", l2, Vector2(shoulder.x * 0.7, 54), false, "lt"))
	list.append(_ctl("rt", trigger_name(s, false), "rrect", r_l2, Vector2(shoulder.x * 0.7, 54), false, "rt"))
	list.append(_ctl(JOY_BUTTON_LEFT_SHOULDER, button_name(s, JOY_BUTTON_LEFT_SHOULDER), "rrect", l1, shoulder))
	list.append(_ctl(JOY_BUTTON_RIGHT_SHOULDER, button_name(s, JOY_BUTTON_RIGHT_SHOULDER), "rrect", r_l1, shoulder))
	list.append(_ctl(JOY_BUTTON_LEFT_STICK, "L3", "circle", lstick, Vector2(92, 92), true, "ls"))
	list.append(_ctl(JOY_BUTTON_RIGHT_STICK, "R3", "circle", rstick, Vector2(92, 92), true, "rs"))
	var dsz := Vector2(38, 38)
	list.append(_ctl(JOY_BUTTON_DPAD_UP, "D-pad up", "rrect", dpad + Vector2(0, -36), dsz))
	list.append(_ctl(JOY_BUTTON_DPAD_DOWN, "D-pad down", "rrect", dpad + Vector2(0, 36), dsz))
	list.append(_ctl(JOY_BUTTON_DPAD_LEFT, "D-pad left", "rrect", dpad + Vector2(-36, 0), dsz))
	list.append(_ctl(JOY_BUTTON_DPAD_RIGHT, "D-pad right", "rrect", dpad + Vector2(36, 0), dsz))
	var fsz := Vector2(42, 42)
	list.append(_ctl(JOY_BUTTON_A, button_name(s, JOY_BUTTON_A), "circle", face + Vector2(0, fo), fsz))
	list.append(_ctl(JOY_BUTTON_B, button_name(s, JOY_BUTTON_B), "circle", face + Vector2(fo, 0), fsz))
	list.append(_ctl(JOY_BUTTON_X, button_name(s, JOY_BUTTON_X), "circle", face + Vector2(-fo, 0), fsz))
	list.append(_ctl(JOY_BUTTON_Y, button_name(s, JOY_BUTTON_Y), "circle", face + Vector2(0, -fo), fsz))
	list.append(_ctl(JOY_BUTTON_BACK, button_name(s, JOY_BUTTON_BACK), "circle", back, Vector2(28, 28)))
	list.append(_ctl(JOY_BUTTON_START, button_name(s, JOY_BUTTON_START), "circle", start, Vector2(28, 28)))
	if style == "deck":
		list.append(_ctl("l4", "L4 (back grip)", "rrect", Vector2(46, 270), Vector2(28, 56), false, "steam"))
		list.append(_ctl("l5", "L5 (back grip)", "rrect", Vector2(46, 340), Vector2(28, 56), false, "steam"))
		list.append(_ctl("r4", "R4 (back grip)", "rrect", Vector2(954, 270), Vector2(28, 56), false, "steam"))
		list.append(_ctl("r5", "R5 (back grip)", "rrect", Vector2(954, 340), Vector2(28, 56), false, "steam"))
		list.append(_ctl("tl", "Left trackpad", "circle", Vector2(240, 425), Vector2(84, 84), false, "steam"))
		list.append(_ctl("tr", "Right trackpad", "circle", Vector2(760, 425), Vector2(84, 84), false, "steam"))
	return {"size": SIZE, "controls": list}


# --- drawing -------------------------------------------------------------------------------

static func _spline(pts: Array, seg := 8) -> PackedVector2Array:
	var out := PackedVector2Array()
	var n := pts.size()
	for i in n:
		var p0: Vector2 = pts[(i - 1 + n) % n]
		var p1: Vector2 = pts[i]
		var p2: Vector2 = pts[(i + 1) % n]
		var p3: Vector2 = pts[(i + 2) % n]
		for j in seg:
			var t := float(j) / float(seg)
			var t2 := t * t
			var t3 := t2 * t
			out.append(0.5 * ((2.0 * p1) + (-p0 + p2) * t + (2.0 * p0 - 5.0 * p1 + 4.0 * p2 - p3) * t2
				+ (-p0 + 3.0 * p1 - 3.0 * p2 + p3) * t3))
	return out


## Right half (top-centre -> bottom-centre) mirrored about x = 500 into a closed ring.
static func _ring(half: Array) -> PackedVector2Array:
	var pts: Array = []
	for p in half:
		var v: Vector2 = p
		pts.append(Vector2(500.0 + v.x, v.y))
	for i in range(half.size() - 2, 0, -1):
		var v2: Vector2 = half[i]
		pts.append(Vector2(500.0 - v2.x, v2.y))
	return _spline(pts, 8)


static func _shaded(ci: CanvasItem, ring: PackedVector2Array, base: Color, lift := 0.12) -> void:
	var sh := PackedVector2Array()
	for p in ring:
		sh.append(p + Vector2(0, 12))
	ci.draw_colored_polygon(sh, Color(0, 0, 0, 0.38))
	ci.draw_colored_polygon(ring, base.darkened(0.45))
	var c := Vector2.ZERO
	var ymin := 1e9
	var ymax := -1e9
	for p in ring:
		c += p
		ymin = minf(ymin, p.y)
		ymax = maxf(ymax, p.y)
	c /= float(ring.size())
	var inner := PackedVector2Array()
	var cols := PackedColorArray()
	for p in ring:
		var q := c + (p - c) * 0.965 + Vector2(0, -3)
		inner.append(q)
		var t := clampf((p.y - ymin) / maxf(1.0, ymax - ymin), 0.0, 1.0)
		cols.append(base.lightened(lift * (1.0 - t)).darkened(0.1 * t))
	ci.draw_polygon(inner, cols)
	var closed := ring.duplicate()
	closed.append(ring[0])
	ci.draw_polyline(closed, base.lightened(0.28), 2.0, true)


static func _rrect(ci: CanvasItem, c: Vector2, sz: Vector2, rad: int, col: Color, border := Color(0, 0, 0, 0)) -> void:
	var r := Rect2(c - sz * 0.5, sz)
	ci.draw_style_box(T.box(col, rad, border, 2 if border.a > 0.0 else 0), r)


static func _well(ci: CanvasItem, c: Vector2, r: float) -> void:
	ci.draw_circle(c + Vector2(0, 3), r + 12.0, Color(0, 0, 0, 0.35))
	ci.draw_circle(c, r + 12.0, Color(0.03, 0.03, 0.035))
	ci.draw_arc(c, r + 12.0, 0.0, TAU, 40, Color(1, 1, 1, 0.14), 2.0, true)
	ci.draw_circle(c, r, Color(0.17, 0.17, 0.19))
	ci.draw_circle(c + Vector2(0, -2), r * 0.82, Color(0.23, 0.23, 0.26))
	ci.draw_arc(c, r * 0.62, 0.0, TAU, 32, Color(0.09, 0.09, 0.1), 3.0, true)
	ci.draw_arc(c, r * 0.9, PI * 1.05, PI * 1.55, 14, Color(1, 1, 1, 0.22), 2.5, true)


static func _dpad(ci: CanvasItem, c: Vector2) -> void:
	ci.draw_circle(c, 62.0, Color(0, 0, 0, 0.25))
	var col := Color(0.12, 0.12, 0.14)
	_rrect(ci, c + Vector2(0, 3), Vector2(40, 112), 8, Color(0, 0, 0, 0.4))
	_rrect(ci, c + Vector2(0, 3), Vector2(112, 40), 8, Color(0, 0, 0, 0.4))
	_rrect(ci, c, Vector2(40, 112), 8, col, Color(1, 1, 1, 0.18))
	_rrect(ci, c, Vector2(112, 40), 8, col, Color(1, 1, 1, 0.18))
	_rrect(ci, c, Vector2(36, 36), 4, col)
	for d in [Vector2(0, -1), Vector2(0, 1), Vector2(-1, 0), Vector2(1, 0)]:
		var dv: Vector2 = d
		var tip := c + dv * 44.0
		var perp := Vector2(-dv.y, dv.x)
		ci.draw_colored_polygon(PackedVector2Array([tip + dv * 4.0, tip - dv * 8.0 + perp * 8.0, tip - dv * 8.0 - perp * 8.0]),
			Color(1, 1, 1, 0.28))


static func _small_btn(ci: CanvasItem, c: Vector2, r: float) -> void:
	ci.draw_circle(c + Vector2(0, 2), r + 1.0, Color(0, 0, 0, 0.4))
	ci.draw_circle(c, r, Color(0.2, 0.2, 0.22))
	ci.draw_arc(c, r, 0.0, TAU, 20, Color(1, 1, 1, 0.25), 1.5, true)


static func _glyph(ci: CanvasItem, c: Vector2, text: String, size: int, col: Color) -> void:
	var f := T.font("body", "bold")
	var w := f.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, size)
	ci.draw_string(f, c + Vector2(-w.x * 0.5, size * 0.36), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


static func _face(ci: CanvasItem, c: Vector2, style: String, id: int) -> void:
	var r := 21.0
	var fill := Color(0.14, 0.14, 0.16)
	var rim := Color(1, 1, 1, 0.22)
	var col := Color(1, 1, 1, 0.9)
	var xbox_cols := {JOY_BUTTON_A: Color(0.36, 0.78, 0.38), JOY_BUTTON_B: Color(0.92, 0.32, 0.30),
		JOY_BUTTON_X: Color(0.30, 0.55, 0.95), JOY_BUTTON_Y: Color(0.96, 0.78, 0.22)}
	var ps_cols := {JOY_BUTTON_A: Color(0.45, 0.62, 1.0), JOY_BUTTON_B: Color(1.0, 0.42, 0.42),
		JOY_BUTTON_X: Color(1.0, 0.55, 0.78), JOY_BUTTON_Y: Color(0.40, 0.88, 0.62)}
	match style:
		"xbox", "deck":
			col = xbox_cols[id]
			if style == "deck":
				col = col.lerp(Color.WHITE, 0.25)
		"playstation":
			col = ps_cols[id]
		"switch":
			fill = Color(0.78, 0.78, 0.8)
			col = Color(0.12, 0.12, 0.14)
			rim = Color(1, 1, 1, 0.6)
	ci.draw_circle(c + Vector2(0, 3), r + 1.0, Color(0, 0, 0, 0.45))
	ci.draw_circle(c, r, fill)
	ci.draw_circle(c + Vector2(0, -2), r * 0.82, fill.lightened(0.07))
	ci.draw_arc(c, r, 0.0, TAU, 28, rim, 2.0, true)
	if style == "playstation":
		var k := r * 0.42
		match id:
			JOY_BUTTON_A:
				ci.draw_line(c + Vector2(-k, -k), c + Vector2(k, k), col, 3.0, true)
				ci.draw_line(c + Vector2(-k, k), c + Vector2(k, -k), col, 3.0, true)
			JOY_BUTTON_B:
				ci.draw_arc(c, k * 1.1, 0.0, TAU, 24, col, 3.0, true)
			JOY_BUTTON_X:
				ci.draw_rect(Rect2(c - Vector2(k, k), Vector2(k, k) * 2.0), col, false, 3.0)
			JOY_BUTTON_Y:
				var tri := PackedVector2Array([c + Vector2(0, -k * 1.25), c + Vector2(k * 1.2, k * 0.85),
					c + Vector2(-k * 1.2, k * 0.85), c + Vector2(0, -k * 1.25)])
				ci.draw_polyline(tri, col, 3.0, true)
	else:
		_glyph(ci, c, button_name(style, id), 20, col)


static func _pill(ci: CanvasItem, c: Vector2, sz: Vector2, col: Color, rad := 12) -> void:
	_rrect(ci, c + Vector2(0, 3), sz, rad, Color(0, 0, 0, 0.4))
	_rrect(ci, c, sz, rad, col, Color(1, 1, 1, 0.2))


## The static art. `ci` must already map design space (draw_set_transform) to the screen.
static func draw(ci: CanvasItem, style: String) -> void:
	var lay := layout(style)
	var cs: Dictionary = {}
	for e in lay.controls:
		cs[e.id] = e
	var body_col := Color(0.20, 0.21, 0.24)
	var bump_col := Color(0.26, 0.27, 0.30)
	var trig_col := Color(0.15, 0.155, 0.175)
	# triggers + bumpers sit behind / above the body edge
	for id in ["lt", "rt"]:
		var t: Dictionary = cs[id]
		_pill(ci, t.c, t.size, trig_col, 16)
		ci.draw_arc(t.c + Vector2(0, 8), t.size.x * 0.42, PI * 1.1, PI * 1.9, 16, Color(1, 1, 1, 0.12), 3.0, true)
	match style:
		"xbox", "playstation", "switch":
			var half: Array = BODY_XBOX if style == "xbox" else (BODY_PS if style == "playstation" else BODY_SWITCH)
			if style == "switch":
				body_col = Color(0.15, 0.15, 0.17)
			_shaded(ci, _ring(half), body_col)
			if style == "playstation":
				ci.draw_style_box(T.box(Color(0.12, 0.125, 0.14), 26, Color(1, 1, 1, 0.14), 2),
					Rect2(Vector2(385, 192), Vector2(230, 128)))
				ci.draw_line(Vector2(500, 200), Vector2(500, 312), Color(1, 1, 1, 0.07), 2.0)
				_small_btn(ci, Vector2(500, 408), 14.0)
			else:
				_small_btn(ci, Vector2(500, 212 if style == "xbox" else 270), 17.0)
				if style == "switch":
					ci.draw_rect(Rect2(Vector2(432, 258), Vector2(20, 20)), Color(0.2, 0.2, 0.22), true)
		"deck":
			var body := PackedVector2Array()
			for p in _spline([Vector2(70, 160), Vector2(160, 138), Vector2(500, 132), Vector2(840, 138), Vector2(930, 160),
					Vector2(968, 250), Vector2(965, 380), Vector2(930, 470), Vector2(860, 500), Vector2(780, 482),
					Vector2(700, 470), Vector2(500, 466), Vector2(300, 470), Vector2(220, 482), Vector2(140, 500),
					Vector2(70, 470), Vector2(35, 380), Vector2(32, 250)], 10):
				body.append(p)
			_shaded(ci, body, Color(0.17, 0.18, 0.2), 0.10)
			# screen
			ci.draw_style_box(T.box(Color(0, 0, 0, 0.5), 22), Rect2(Vector2(286, 186), Vector2(428, 268)))
			ci.draw_style_box(T.box(Color(0.03, 0.035, 0.05), 20, Color(1, 1, 1, 0.16), 2), Rect2(Vector2(290, 180), Vector2(420, 262)))
			var sheen := PackedVector2Array([Vector2(300, 190), Vector2(520, 190), Vector2(420, 430), Vector2(300, 430)])
			ci.draw_colored_polygon(sheen, Color(0.35, 0.5, 0.8, 0.07))
			_glyph(ci, Vector2(500, 312), "Steam Deck", 24, Color(1, 1, 1, 0.12))
			for tp in ["tl", "tr"]:
				var t2: Dictionary = cs[tp]
				ci.draw_circle(t2.c, 42.0, Color(0.1, 0.1, 0.115))
				ci.draw_arc(t2.c, 42.0, 0.0, TAU, 32, Color(1, 1, 1, 0.16), 2.0, true)
				ci.draw_arc(t2.c, 30.0, 0.0, TAU, 28, Color(1, 1, 1, 0.06), 1.5, true)
			for gid in ["l4", "l5", "r4", "r5"]:
				var g: Dictionary = cs[gid]
				_pill(ci, g.c, g.size, Color(0.12, 0.125, 0.14), 10)
	# bumpers on top
	for id2 in [JOY_BUTTON_LEFT_SHOULDER, JOY_BUTTON_RIGHT_SHOULDER]:
		var b: Dictionary = cs[id2]
		_pill(ci, b.c, b.size, bump_col, 14)
		ci.draw_line(b.c + Vector2(-b.size.x * 0.4, -4), b.c + Vector2(b.size.x * 0.4, -4), Color(1, 1, 1, 0.12), 2.0, true)
	_well(ci, cs[JOY_BUTTON_LEFT_STICK].c, 38.0)
	_well(ci, cs[JOY_BUTTON_RIGHT_STICK].c, 38.0)
	var dc: Vector2 = (cs[JOY_BUTTON_DPAD_UP].c + cs[JOY_BUTTON_DPAD_DOWN].c) * 0.5
	_dpad(ci, dc)
	for fid in [JOY_BUTTON_A, JOY_BUTTON_B, JOY_BUTTON_X, JOY_BUTTON_Y]:
		_face(ci, cs[fid].c, style, fid)
	_small_btn(ci, cs[JOY_BUTTON_BACK].c, 12.0)
	_small_btn(ci, cs[JOY_BUTTON_START].c, 12.0)
	# Back / Start icons
	var bc: Vector2 = cs[JOY_BUTTON_BACK].c
	var sc: Vector2 = cs[JOY_BUTTON_START].c
	if style == "switch":
		ci.draw_line(bc + Vector2(-5, 0), bc + Vector2(5, 0), Color(1, 1, 1, 0.8), 2.0, true)
		ci.draw_line(sc + Vector2(-5, 0), sc + Vector2(5, 0), Color(1, 1, 1, 0.8), 2.0, true)
		ci.draw_line(sc + Vector2(0, -5), sc + Vector2(0, 5), Color(1, 1, 1, 0.8), 2.0, true)
	else:
		ci.draw_rect(Rect2(bc - Vector2(5, 4), Vector2(8, 8)), Color(1, 1, 1, 0.75), false, 1.5)
		for i in 3:
			ci.draw_line(sc + Vector2(-5, -4.0 + 4.0 * i), sc + Vector2(5, -4.0 + 4.0 * i), Color(1, 1, 1, 0.75), 1.5, true)
