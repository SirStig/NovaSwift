# NOVA Swift — Controls Editor controller art: four procedurally drawn pads (Xbox Series, DualSense,
# Switch Pro, Steam Deck) in MILLIMETRES, built from the real proportions (Xbox ~153 x 105, DualSense
# ~160 x 106, Switch Pro ~152 x 106, Deck ~298 x 117 with a 7" screen). Origin = the pad's centre,
# +y down. Bodies are smooth cubic béziers (sampled to polygons) with grips that flare down and out;
# bumpers and triggers hug the top contour and tuck behind the body. Vector paths only, no bitmaps.
#
# layout(style) -> {"body": Rect2, "extent": Rect2, "controls": [ {id, name, kind, c, outline, bbox,
#                   bindable, role, side} ]}   (all mm; id = JoyButton int or a String)
# draw(ci, style, states, px, texts) draws the art in mm space (the caller maps mm -> screen with
#   draw_set_transform); `states` = id -> {tint, live, pulse, sel, focus, hover}; `px` = mm per screen
#   pixel (so strokes stay a constant pixel width); glyph jobs go into `texts` (drawn by the caller at
#   screen scale so text stays crisp).
#
# Loaded with preload() (no class_name), like Controls.gd.
extends RefCounted

const T = preload("res://ui/novaswift/NovaTheme.gd")

# Right half of each body outline: start point, then cubic segments (c1, c2, end) top-centre -> bottom-centre.
const HALF := {
	"xbox": [Vector2(0, -38), Vector2(24, -39.5), Vector2(50, -41), Vector2(66, -33), Vector2(74, -28), Vector2(77, -12), Vector2(75, 6),
		Vector2(74, 20), Vector2(72, 40), Vector2(66, 56), Vector2(63, 64), Vector2(55, 68), Vector2(48, 66), Vector2(41, 64), Vector2(38, 56), Vector2(35, 46),
		Vector2(32, 34), Vector2(27, 25), Vector2(14, 24), Vector2(8, 24), Vector2(4, 24), Vector2(0, 24)],
	"playstation": [Vector2(0, -36), Vector2(30, -38), Vector2(56, -40), Vector2(70, -32), Vector2(79, -26), Vector2(80, -10), Vector2(78, 8),
		Vector2(76, 26), Vector2(74, 44), Vector2(70, 56), Vector2(67, 64), Vector2(56, 69), Vector2(49, 66), Vector2(42, 63), Vector2(40, 55), Vector2(37, 46),
		Vector2(34, 44), Vector2(30, 38), Vector2(20, 38), Vector2(12, 38), Vector2(5, 38), Vector2(0, 38)],
	"switch": [Vector2(0, -38), Vector2(26, -39), Vector2(52, -40), Vector2(67, -32), Vector2(75, -27), Vector2(76, -10), Vector2(74, 8),
		Vector2(73, 24), Vector2(72, 42), Vector2(66, 57), Vector2(62, 67), Vector2(52, 70), Vector2(46, 66), Vector2(40, 62), Vector2(38, 54), Vector2(35, 45),
		Vector2(31, 32), Vector2(27, 26), Vector2(14, 25), Vector2(8, 25), Vector2(4, 25), Vector2(0, 25)],
	"deck": [Vector2(0, -57), Vector2(50, -57.5), Vector2(110, -56), Vector2(132, -50), Vector2(144, -46), Vector2(149, -34), Vector2(149, -18),
		Vector2(149, 0), Vector2(148, 24), Vector2(144, 40), Vector2(141, 52), Vector2(133, 58), Vector2(120, 58), Vector2(108, 58), Vector2(96, 52), Vector2(80, 52),
		Vector2(50, 52), Vector2(25, 53), Vector2(0, 53)],
}

# Control placements (mm from the pad centre) and sizes. Bumper / trigger x ranges are |x|.
const SPEC := {
	"xbox": {"ls": Vector2(-41, -14), "rs": Vector2(19, 11), "dpad": Vector2(-19, 11), "face": Vector2(41, -14), "fo": 10.5, "fr": 6.0,
		"back": Vector2(-12.5, -14), "start": Vector2(12.5, -14), "guide": Vector2(0, -28), "stick": 10.0, "well": 13.0, "cross": 25.0,
		"bump": Vector2(28, 64), "trig": Vector2(34, 60)},
	"playstation": {"ls": Vector2(-21, 17), "rs": Vector2(21, 17), "dpad": Vector2(-41, -8), "face": Vector2(41, -8), "fo": 10.0, "fr": 5.8,
		"back": Vector2(-31, -29), "start": Vector2(31, -29), "guide": Vector2(0, 10), "stick": 9.5, "well": 12.0, "cross": 25.0,
		"bump": Vector2(26, 62), "trig": Vector2(30, 58)},
	"switch": {"ls": Vector2(-41, -15), "rs": Vector2(21, 12), "dpad": Vector2(-21, 12), "face": Vector2(41, -15), "fo": 10.5, "fr": 6.0,
		"back": Vector2(-13, -25), "start": Vector2(13, -25), "guide": Vector2(13, -12), "stick": 10.0, "well": 13.0, "cross": 24.0,
		"bump": Vector2(28, 62), "trig": Vector2(32, 58)},
	"deck": {"ls": Vector2(-112, -26), "rs": Vector2(112, 6), "dpad": Vector2(-112, 8), "face": Vector2(112, -26), "fo": 9.5, "fr": 5.5,
		"back": Vector2(-89, -14), "start": Vector2(89, -14), "guide": Vector2(-89, 9), "stick": 9.5, "well": 12.0, "cross": 22.0,
		"bump": Vector2(92, 134), "trig": Vector2(98, 128)},
}

const FIXED_ROLES := {
	"Flight": {"lt": "Reverse / brake", "rt": "Thrust", "ls": "Steer / Thrust", "rs": "Aim"},
	"Docked": {"lt": "", "rt": "", "ls": "Move focus", "rs": ""},
	"Galaxy map": {"lt": "", "rt": "", "ls": "Cursor", "rs": "Pan"},
}

## Every JoyButton the editor can bind (same on all styles).
const BINDABLE := [JOY_BUTTON_A, JOY_BUTTON_B, JOY_BUTTON_X, JOY_BUTTON_Y, JOY_BUTTON_LEFT_SHOULDER,
	JOY_BUTTON_RIGHT_SHOULDER, JOY_BUTTON_LEFT_STICK, JOY_BUTTON_RIGHT_STICK, JOY_BUTTON_BACK, JOY_BUTTON_START,
	JOY_BUTTON_DPAD_UP, JOY_BUTTON_DPAD_DOWN, JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_RIGHT]

static var _rings: Dictionary = {}
static var _layouts: Dictionary = {}


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


## A fixed analog input of an action (Controls axes pair) named for the style: "Left stick up", "RT"...
static func axis_name(style: String, axis: int, sign_v: float) -> String:
	match axis:
		JOY_AXIS_TRIGGER_RIGHT: return trigger_name(style, false)
		JOY_AXIS_TRIGGER_LEFT: return trigger_name(style, true)
		JOY_AXIS_LEFT_X: return "L-stick " + ("left" if sign_v < 0.0 else "right")
		JOY_AXIS_LEFT_Y: return "L-stick " + ("up" if sign_v < 0.0 else "down")
		JOY_AXIS_RIGHT_X: return "R-stick " + ("left" if sign_v < 0.0 else "right")
		JOY_AXIS_RIGHT_Y: return "R-stick " + ("up" if sign_v < 0.0 else "down")
	return ""


# --- geometry ------------------------------------------------------------------------------

static func _sample_half(half: Array) -> Array:
	var out: Array = []
	var p0: Vector2 = half[0]
	out.append(p0)
	var i := 1
	while i + 2 < half.size():
		var c1: Vector2 = half[i]
		var c2: Vector2 = half[i + 1]
		var e: Vector2 = half[i + 2]
		for k in range(1, 13):
			var t := float(k) / 12.0
			var u := 1.0 - t
			out.append(u * u * u * p0 + 3.0 * u * u * t * c1 + 3.0 * u * t * t * c2 + t * t * t * e)
		p0 = e
		i += 3
	return out


## The closed body outline polygon (mm), clockwise from the top centre.
static func ring(style: String) -> PackedVector2Array:
	if _rings.has(style):
		return _rings[style]
	var right: Array = _sample_half(HALF[style])
	var pts := PackedVector2Array()
	for p in right:
		pts.append(p)
	for i in range(right.size() - 2, 0, -1):
		var v: Vector2 = right[i]
		pts.append(Vector2(-v.x, v.y))
	_rings[style] = pts
	return pts


## y of the body's top edge at x (the smallest y the outline reaches there).
static func top_y(rg: PackedVector2Array, x: float) -> float:
	var best := 1e9
	var n := rg.size()
	for i in n:
		var a: Vector2 = rg[i]
		var b: Vector2 = rg[(i + 1) % n]
		if (a.x <= x and x <= b.x) or (b.x <= x and x <= a.x):
			if absf(b.x - a.x) < 0.0001:
				best = minf(best, minf(a.y, b.y))
			else:
				best = minf(best, a.y + (b.y - a.y) * (x - a.x) / (b.x - a.x))
	return best


## A band hugging the top contour between |x| in [x0, x1] (mirrored by `sgn`), `rise` mm above the edge,
## tucked `tuck` mm below it (the body is drawn over the tucked part).
static func _band(rg: PackedVector2Array, x0: float, x1: float, sgn: float, rise: float, tuck: float) -> PackedVector2Array:
	var up: Array = []
	var down: Array = []
	var n := 16
	for k in n + 1:
		var t := float(k) / float(n)
		var x := lerpf(x0, x1, t) * sgn
		var ty := top_y(rg, x)
		var bulge := 0.4 + 0.6 * sqrt(sin(PI * t))
		up.append(Vector2(x, ty - rise * bulge))
		down.append(Vector2(x, ty + tuck))
	var poly := PackedVector2Array()
	for p in up:
		poly.append(p)
	for i in range(down.size() - 1, -1, -1):
		poly.append(down[i])
	return poly


static func _circle_pts(c: Vector2, r: float, n := 40) -> PackedVector2Array:
	var out := PackedVector2Array()
	for i in n:
		var a := TAU * float(i) / float(n)
		out.append(c + Vector2(cos(a), sin(a)) * r)
	return out


static func _rect_pts(c: Vector2, sz: Vector2, rad: float) -> PackedVector2Array:
	var out := PackedVector2Array()
	var h := sz * 0.5 - Vector2(rad, rad)
	for q in 4:
		var cc: Vector2 = c + Vector2(h.x if q == 0 or q == 3 else -h.x, h.y if q < 2 else -h.y)
		var a0: float = float([0.0, 0.5, 1.0, 1.5][q]) * PI
		for k in 7:
			var a: float = a0 + float(k) / 6.0 * PI * 0.5
			out.append(cc + Vector2(cos(a), sin(a)) * rad)
	return out


static func _bbox(poly: PackedVector2Array) -> Rect2:
	var r := Rect2(poly[0], Vector2.ZERO)
	for p in poly:
		r = r.expand(p)
	return r


static func _ctl(id: Variant, nm: String, outline: PackedVector2Array, bindable := true, role := "", kind := "poly") -> Dictionary:
	var bb := _bbox(outline)
	var c := bb.get_center()
	return {"id": id, "name": nm, "kind": kind, "c": c, "outline": outline, "bbox": bb, "bindable": bindable,
		"role": role, "side": "L" if c.x < 0.0 else "R"}


static func _cross_pts(c: Vector2, size_v: float, w: float) -> PackedVector2Array:
	var a := size_v * 0.5
	var b := w * 0.5
	return PackedVector2Array([c + Vector2(-b, -a), c + Vector2(b, -a), c + Vector2(b, -b), c + Vector2(a, -b), c + Vector2(a, b), c + Vector2(b, b),
		c + Vector2(b, a), c + Vector2(-b, a), c + Vector2(-b, b), c + Vector2(-a, b), c + Vector2(-a, -b), c + Vector2(-b, -b)])


static func layout(style: String) -> Dictionary:
	if _layouts.has(style):
		return _layouts[style]
	var sp: Dictionary = SPEC[style]
	var rg := ring(style)
	var body := _bbox(rg)
	var list: Array = []
	# triggers + bumpers hugging the top contour
	var bump: Vector2 = sp.bump
	var trig: Vector2 = sp.trig
	var trig_rise := 15.0 if style != "deck" else 13.0
	list.append(_ctl("lt", trigger_name(style, true), _band(rg, trig.x, trig.y, -1.0, trig_rise, 5.0), false, "lt"))
	list.append(_ctl("rt", trigger_name(style, false), _band(rg, trig.x, trig.y, 1.0, trig_rise, 5.0), false, "rt"))
	list.append(_ctl(JOY_BUTTON_LEFT_SHOULDER, button_name(style, JOY_BUTTON_LEFT_SHOULDER), _band(rg, bump.x, bump.y, -1.0, 7.5, 6.0)))
	list.append(_ctl(JOY_BUTTON_RIGHT_SHOULDER, button_name(style, JOY_BUTTON_RIGHT_SHOULDER), _band(rg, bump.x, bump.y, 1.0, 7.5, 6.0)))
	var sr: float = sp.stick
	list.append(_ctl(JOY_BUTTON_LEFT_STICK, "L3", _circle_pts(sp.ls, sr), true, "ls", "circle"))
	list.append(_ctl(JOY_BUTTON_RIGHT_STICK, "R3", _circle_pts(sp.rs, sr), true, "rs", "circle"))
	# d-pad arms (the cross itself is drawn once; each arm tints inside it)
	var dc: Vector2 = sp.dpad
	var cs: float = sp.cross
	var w: float = cs * 0.34
	var a := cs * 0.5
	var b := w * 0.5
	list.append(_ctl(JOY_BUTTON_DPAD_UP, "D-pad up", PackedVector2Array([dc + Vector2(-b, -a), dc + Vector2(b, -a), dc + Vector2(b, -b), dc + Vector2(-b, -b)])))
	list.append(_ctl(JOY_BUTTON_DPAD_DOWN, "D-pad down", PackedVector2Array([dc + Vector2(-b, b), dc + Vector2(b, b), dc + Vector2(b, a), dc + Vector2(-b, a)])))
	list.append(_ctl(JOY_BUTTON_DPAD_LEFT, "D-pad left", PackedVector2Array([dc + Vector2(-a, -b), dc + Vector2(-b, -b), dc + Vector2(-b, b), dc + Vector2(-a, b)])))
	list.append(_ctl(JOY_BUTTON_DPAD_RIGHT, "D-pad right", PackedVector2Array([dc + Vector2(b, -b), dc + Vector2(a, -b), dc + Vector2(a, b), dc + Vector2(b, b)])))
	var fc: Vector2 = sp.face
	var fo: float = sp.fo
	var fr: float = sp.fr
	list.append(_ctl(JOY_BUTTON_A, button_name(style, JOY_BUTTON_A), _circle_pts(fc + Vector2(0, fo), fr), true, "", "circle"))
	list.append(_ctl(JOY_BUTTON_B, button_name(style, JOY_BUTTON_B), _circle_pts(fc + Vector2(fo, 0), fr), true, "", "circle"))
	list.append(_ctl(JOY_BUTTON_X, button_name(style, JOY_BUTTON_X), _circle_pts(fc + Vector2(-fo, 0), fr), true, "", "circle"))
	list.append(_ctl(JOY_BUTTON_Y, button_name(style, JOY_BUTTON_Y), _circle_pts(fc + Vector2(0, -fo), fr), true, "", "circle"))
	list.append(_ctl(JOY_BUTTON_BACK, button_name(style, JOY_BUTTON_BACK), _circle_pts(sp.back, 3.6, 24), true, "", "circle"))
	list.append(_ctl(JOY_BUTTON_START, button_name(style, JOY_BUTTON_START), _circle_pts(sp.start, 3.6, 24), true, "", "circle"))
	if style == "deck":
		list.append(_ctl("l4", "L4 (back grip)", _rect_pts(Vector2(-151.5, -10), Vector2(5, 16), 2.0), false, "steam"))
		list.append(_ctl("l5", "L5 (back grip)", _rect_pts(Vector2(-151.5, 14), Vector2(5, 16), 2.0), false, "steam"))
		list.append(_ctl("r4", "R4 (back grip)", _rect_pts(Vector2(151.5, -10), Vector2(5, 16), 2.0), false, "steam"))
		list.append(_ctl("r5", "R5 (back grip)", _rect_pts(Vector2(151.5, 14), Vector2(5, 16), 2.0), false, "steam"))
		list.append(_ctl("tl", "Left trackpad", _circle_pts(Vector2(-88, 36), 15.0), false, "steam", "circle"))
		list.append(_ctl("tr", "Right trackpad", _circle_pts(Vector2(88, 36), 15.0), false, "steam", "circle"))
	var ext := body
	for c in list:
		ext = ext.merge(c.bbox)
	var out := {"body": body, "extent": ext, "controls": list}
	_layouts[style] = out
	return out


# --- drawing -------------------------------------------------------------------------------

static func _closed(p: PackedVector2Array) -> PackedVector2Array:
	var q := p.duplicate()
	q.append(p[0])
	return q


static func _fill(base: Color, s: Dictionary) -> Color:
	var col := base
	if s.has("tint"):
		col = base.lerp(s.tint, 0.5)
	if s.get("pulse", 0.0) > 0.0:
		col = col.lerp(Color(1.0, 0.7, 0.28), 0.55 * float(s.pulse))
	if s.get("live", false):
		col = Color(1.0, 0.82, 0.35)
	return col


## Edge strokes on a control's own outline: category tint, selection, focus, hover.
static func _edges(ci: CanvasItem, outline: PackedVector2Array, s: Dictionary, px: float) -> void:
	var cl := _closed(outline)
	if s.has("tint"):
		ci.draw_polyline(cl, Color(s.tint.r, s.tint.g, s.tint.b, 0.95), 2.0 * px, true)
	if s.get("sel", false):
		ci.draw_colored_polygon(outline, Color(1.0, 0.7, 0.28, 0.2))
		ci.draw_polyline(cl, Color(1.0, 0.72, 0.3), 3.0 * px, true)
	if s.get("pulse", 0.0) > 0.0:
		ci.draw_polyline(cl, Color(1.0, 0.8, 0.4, 0.4 + 0.6 * float(s.pulse)), 3.0 * px, true)
	if s.get("focus", false):
		ci.draw_polyline(cl, Color(1, 1, 1, 0.97), 2.5 * px, true)
	elif s.get("hover", false):
		ci.draw_polyline(cl, Color(1, 1, 1, 0.6), 1.5 * px, true)


static func _grad_poly(ci: CanvasItem, poly: PackedVector2Array, top: Color, bottom: Color) -> void:
	var ymin := 1e9
	var ymax := -1e9
	for p in poly:
		ymin = minf(ymin, p.y)
		ymax = maxf(ymax, p.y)
	var cols := PackedColorArray()
	for p in poly:
		cols.append(top.lerp(bottom, clampf((p.y - ymin) / maxf(0.001, ymax - ymin), 0.0, 1.0)))
	ci.draw_polygon(poly, cols)


static func _scaled(poly: PackedVector2Array, c: Vector2, k: float, off: Vector2) -> PackedVector2Array:
	var out := PackedVector2Array()
	for p in poly:
		out.append(c + (p - c) * k + off)
	return out


static func _body(ci: CanvasItem, rg: PackedVector2Array, base: Color, px: float) -> void:
	var bb := _bbox(rg)
	var c := bb.get_center()
	# soft drop shadow under the whole pad
	ci.draw_colored_polygon(_scaled(rg, c, 1.04, Vector2(0, 5.5)), Color(0, 0, 0, 0.16))
	ci.draw_colored_polygon(_scaled(rg, c, 1.015, Vector2(0, 3.0)), Color(0, 0, 0, 0.26))
	# outer shell: vertical gradient, darker toward the bottom
	_grad_poly(ci, rg, base.lightened(0.04), base.darkened(0.55))
	# inner face: lighter, so the bottom rim reads as an inner shadow
	var inner := _scaled(rg, c, 0.955, Vector2(0, -1.4))
	_grad_poly(ci, inner, base.lightened(0.16), base.darkened(0.06))
	ci.draw_polyline(_closed(rg), base.lightened(0.05), 1.0 * px, true)
	# soft rim highlight along the top edge
	var n := rg.size()
	for i in n:
		var a: Vector2 = rg[i]
		var b: Vector2 = rg[(i + 1) % n]
		var yy := (a.y + b.y) * 0.5
		if yy < c.y - bb.size.y * 0.06:
			var t := clampf(1.0 - (yy - bb.position.y) / (bb.size.y * 0.5), 0.0, 1.0)
			ci.draw_line(a + Vector2(0, 0.9), b + Vector2(0, 0.9), Color(1, 1, 1, 0.10 + 0.32 * t), 2.2 * px, true)


static func _stick(ci: CanvasItem, c: Vector2, r: float, well: float, s: Dictionary, px: float, outline: PackedVector2Array) -> void:
	# recessed well: dark ring with a lit lower lip
	ci.draw_circle(c, well + 1.6, Color(0, 0, 0, 0.35))
	ci.draw_circle(c, well, Color(0.02, 0.02, 0.025))
	ci.draw_arc(c, well - 0.4, PI * 0.05, PI * 0.95, 24, Color(1, 1, 1, 0.13), 1.2 * px, true)
	ci.draw_arc(c, well - 0.4, PI * 1.05, PI * 1.95, 24, Color(0, 0, 0, 0.6), 1.2 * px, true)
	# cap: concave dish - dark centre, lighter rim, top-left highlight
	var base := _fill(Color(0.19, 0.195, 0.215), s)
	ci.draw_circle(c, r, base)
	for i in 5:
		var k := 1.0 - float(i) * 0.17
		ci.draw_circle(c + Vector2(0, 0.25 * float(i)), r * k, base.darkened(0.08 * float(i + 1)).lerp(base.lightened(0.05), 0.0))
	ci.draw_arc(c, r * 0.9, 0.0, TAU, 40, Color(1, 1, 1, 0.16), 0.9 * px, true)       # grip ring
	ci.draw_arc(c, r * 0.58, 0.0, TAU, 32, Color(1, 1, 1, 0.06), 0.8 * px, true)
	ci.draw_arc(c, r * 0.82, PI * 1.05, PI * 1.55, 14, Color(1, 1, 1, 0.34), 1.6 * px, true)
	_edges(ci, outline, s, px)


static func _dpad(ci: CanvasItem, c: Vector2, cs: float, ctls: Dictionary, states: Dictionary, px: float) -> void:
	var w := cs * 0.34
	var cross := _cross_pts(c, cs, w)
	ci.draw_colored_polygon(_scaled(cross, c, 1.1, Vector2(0, 1.2)), Color(0, 0, 0, 0.45))
	_grad_poly(ci, cross, Color(0.21, 0.215, 0.235), Color(0.10, 0.10, 0.115))
	ci.draw_polyline(_closed(cross), Color(1, 1, 1, 0.2), 1.0 * px, true)
	# embossed centre dish and arrowheads
	ci.draw_circle(c, w * 0.34, Color(0, 0, 0, 0.35))
	ci.draw_arc(c, w * 0.34, PI * 1.1, PI * 1.9, 12, Color(1, 1, 1, 0.14), 1.0 * px, true)
	for d in [Vector2(0, -1), Vector2(0, 1), Vector2(-1, 0), Vector2(1, 0)]:
		var dv: Vector2 = d
		var perp := Vector2(-dv.y, dv.x)
		var tip := c + dv * (cs * 0.5 - 2.6)
		ci.draw_colored_polygon(PackedVector2Array([tip + dv * 1.4, tip - dv * 1.6 + perp * 2.0, tip - dv * 1.6 - perp * 2.0]),
			Color(1, 1, 1, 0.28))
	for id in [JOY_BUTTON_DPAD_UP, JOY_BUTTON_DPAD_DOWN, JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_RIGHT]:
		var s: Dictionary = states.get(id, {})
		if s.is_empty():
			continue
		var outline: PackedVector2Array = ctls[id].outline
		if s.has("tint") or s.get("live", false) or s.get("pulse", 0.0) > 0.0:
			ci.draw_colored_polygon(outline, Color(_fill(Color(0.2, 0.2, 0.22), s), 0.85))
		_edges(ci, outline, s, px)


static func _face(ci: CanvasItem, style: String, id: int, c: Vector2, r: float, s: Dictionary, px: float,
		outline: PackedVector2Array, texts: Array) -> void:
	var fill := Color(0.15, 0.15, 0.17)
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
			fill = Color(0.74, 0.74, 0.77)
			col = Color(0.1, 0.1, 0.12)
	fill = _fill(fill, s)
	ci.draw_circle(c + Vector2(0, 0.9), r + 0.7, Color(0, 0, 0, 0.5))
	# domed: stacked discs, lighter and shifted toward the light
	for i in 6:
		var k := 1.0 - float(i) * 0.13
		ci.draw_circle(c + Vector2(-0.12, -0.16) * float(i), r * k, fill.lightened(0.045 * float(i)))
	ci.draw_arc(c, r, 0.0, TAU, 32, Color(1, 1, 1, 0.22), 1.0 * px, true)
	ci.draw_arc(c, r * 0.8, PI * 1.1, PI * 1.5, 10, Color(1, 1, 1, 0.3), 1.4 * px, true)
	if style == "playstation":
		var k2 := r * 0.42
		var w := 1.5 * px * 1.0
		match id:
			JOY_BUTTON_A:
				ci.draw_line(c + Vector2(-k2, -k2), c + Vector2(k2, k2), col, w + 0.5, true)
				ci.draw_line(c + Vector2(-k2, k2), c + Vector2(k2, -k2), col, w + 0.5, true)
			JOY_BUTTON_B:
				ci.draw_arc(c, k2 * 1.15, 0.0, TAU, 24, col, w + 0.5, true)
			JOY_BUTTON_X:
				ci.draw_rect(Rect2(c - Vector2(k2, k2), Vector2(k2, k2) * 2.0), col, false, w + 0.5)
			JOY_BUTTON_Y:
				ci.draw_polyline(PackedVector2Array([c + Vector2(0, -k2 * 1.25), c + Vector2(k2 * 1.2, k2 * 0.85),
					c + Vector2(-k2 * 1.2, k2 * 0.85), c + Vector2(0, -k2 * 1.25)]), col, w + 0.5, true)
	else:
		texts.append({"pos": c, "text": button_name(style, id), "size": r * 1.25, "col": col})
	_edges(ci, outline, s, px)


static func _small(ci: CanvasItem, c: Vector2, r: float, s: Dictionary, px: float, outline: PackedVector2Array) -> void:
	ci.draw_circle(c + Vector2(0, 0.6), r + 0.5, Color(0, 0, 0, 0.45))
	var base := _fill(Color(0.22, 0.225, 0.25), s)
	ci.draw_circle(c, r, base)
	ci.draw_circle(c + Vector2(-0.1, -0.15), r * 0.72, base.lightened(0.08))
	ci.draw_arc(c, r, 0.0, TAU, 20, Color(1, 1, 1, 0.26), 0.9 * px, true)
	_edges(ci, outline, s, px)


static func _shoulder(ci: CanvasItem, poly: PackedVector2Array, base: Color, s: Dictionary, px: float) -> void:
	var fill := _fill(base, s)
	_grad_poly(ci, poly, fill.lightened(0.12), fill.darkened(0.2))
	ci.draw_polyline(_closed(poly), Color(1, 1, 1, 0.22), 1.0 * px, true)
	_edges(ci, poly, s, px)


## The art. `ci` already maps mm to the screen (draw_set_transform); `px` = mm per screen pixel.
static func draw(ci: CanvasItem, style: String, states: Dictionary, px: float, texts: Array) -> void:
	var lay := layout(style)
	var sp: Dictionary = SPEC[style]
	var rg := ring(style)
	var cs: Dictionary = {}
	for e in lay.controls:
		cs[e.id] = e
	var st: Dictionary = states
	var body_col := Color(0.20, 0.21, 0.24)
	if style == "switch":
		body_col = Color(0.15, 0.155, 0.175)
	elif style == "deck":
		body_col = Color(0.17, 0.18, 0.2)
	# triggers (furthest back), then bumpers, then the body over their tucked edges
	for id in ["lt", "rt"]:
		_shoulder(ci, cs[id].outline, Color(0.13, 0.135, 0.15), st.get(id, {}), px)
	for id2 in [JOY_BUTTON_LEFT_SHOULDER, JOY_BUTTON_RIGHT_SHOULDER]:
		_shoulder(ci, cs[id2].outline, Color(0.25, 0.26, 0.29), st.get(id2, {}), px)
	_body(ci, rg, body_col, px)
	# style details
	match style:
		"playstation":
			var tp := _rect_pts(Vector2(0, -24), Vector2(50, 25), 7.0)
			_grad_poly(ci, tp, Color(0.13, 0.135, 0.15), Color(0.09, 0.09, 0.105))
			ci.draw_polyline(_closed(tp), Color(1, 1, 1, 0.16), 1.0 * px, true)
			ci.draw_line(Vector2(0, -34), Vector2(0, -15), Color(1, 1, 1, 0.05), 1.0 * px, true)
			_small(ci, sp.guide, 4.4, {}, px, PackedVector2Array([sp.guide, sp.guide]))
		"xbox":
			_small(ci, sp.guide, 6.2, {}, px, PackedVector2Array([sp.guide, sp.guide]))
		"switch":
			_small(ci, sp.guide, 4.4, {}, px, PackedVector2Array([sp.guide, sp.guide]))
			var cap := _rect_pts(Vector2(-13, -12), Vector2(8, 8), 1.2)
			ci.draw_colored_polygon(cap, Color(0.22, 0.225, 0.25))
			ci.draw_polyline(_closed(cap), Color(1, 1, 1, 0.22), 1.0 * px, true)
		"deck":
			var scr := _rect_pts(Vector2(0, -2), Vector2(155, 97), 5.5)
			var bez := _rect_pts(Vector2(0, -2), Vector2(161, 103), 8.0)
			ci.draw_colored_polygon(bez, Color(0.025, 0.027, 0.032))
			ci.draw_polyline(_closed(bez), Color(1, 1, 1, 0.12), 1.0 * px, true)
			_grad_poly(ci, scr, Color(0.07, 0.085, 0.12), Color(0.02, 0.025, 0.04))
			ci.draw_colored_polygon(PackedVector2Array([Vector2(-70, -46), Vector2(-5, -46), Vector2(-35, 40), Vector2(-70, 40)]), Color(0.4, 0.55, 0.9, 0.06))
			ci.draw_polyline(_closed(scr), Color(1, 1, 1, 0.1), 0.8 * px, true)
			texts.append({"pos": Vector2(0, -2), "text": "Steam Deck", "size": 11.0, "col": Color(1, 1, 1, 0.12)})
			for tp2 in ["tl", "tr"]:
				var t2: Dictionary = cs[tp2]
				var c2: Vector2 = t2.c
				ci.draw_circle(c2, 15.8, Color(0, 0, 0, 0.4))
				ci.draw_circle(c2, 15.0, Color(0.09, 0.095, 0.11))
				ci.draw_arc(c2, 15.0, 0.0, TAU, 32, Color(1, 1, 1, 0.16), 1.0 * px, true)
				ci.draw_arc(c2, 10.0, 0.0, TAU, 28, Color(1, 1, 1, 0.06), 0.8 * px, true)
			for gid in ["l4", "l5", "r4", "r5"]:
				var g: Dictionary = cs[gid]
				ci.draw_colored_polygon(g.outline, Color(0.11, 0.115, 0.13))
				ci.draw_polyline(_closed(g.outline), Color(1, 1, 1, 0.2), 1.0 * px, true)
	_stick(ci, sp.ls, sp.stick, sp.well, st.get(JOY_BUTTON_LEFT_STICK, {}), px, cs[JOY_BUTTON_LEFT_STICK].outline)
	_stick(ci, sp.rs, sp.stick, sp.well, st.get(JOY_BUTTON_RIGHT_STICK, {}), px, cs[JOY_BUTTON_RIGHT_STICK].outline)
	_dpad(ci, sp.dpad, sp.cross, cs, st, px)
	for fid in [JOY_BUTTON_A, JOY_BUTTON_B, JOY_BUTTON_X, JOY_BUTTON_Y]:
		var fc: Dictionary = cs[fid]
		_face(ci, style, fid, fc.c, sp.fr, st.get(fid, {}), px, fc.outline, texts)
	for sid in [JOY_BUTTON_BACK, JOY_BUTTON_START]:
		var sc: Dictionary = cs[sid]
		_small(ci, sc.c, 3.6, st.get(sid, {}), px, sc.outline)
		var cc: Vector2 = sc.c
		if style == "switch":
			ci.draw_line(cc + Vector2(-1.5, 0), cc + Vector2(1.5, 0), Color(1, 1, 1, 0.85), 0.9, true)
			if sid == JOY_BUTTON_START:
				ci.draw_line(cc + Vector2(0, -1.5), cc + Vector2(0, 1.5), Color(1, 1, 1, 0.85), 0.9, true)
		elif sid == JOY_BUTTON_BACK:
			ci.draw_rect(Rect2(cc - Vector2(1.5, 1.2), Vector2(2.4, 2.4)), Color(1, 1, 1, 0.8), false, 0.5)
		else:
			for i in 3:
				ci.draw_line(cc + Vector2(-1.6, -1.3 + 1.3 * float(i)), cc + Vector2(1.6, -1.3 + 1.3 * float(i)), Color(1, 1, 1, 0.8), 0.5, true)
