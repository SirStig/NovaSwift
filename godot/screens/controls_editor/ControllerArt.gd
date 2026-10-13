# NOVA Swift — Controls Editor controller art. Four original layouts (offset sticks, symmetric sticks,
# swapped face letters, wide handheld) in MILLIMETRES. Origin = the pad's centre, +y down. The shells
# are the same material: a darker chassis, a lighter top case, triggers and bumpers as their own parts.
# Face caps use one neutral letter (A bottom, B right, X left, Y top; the swapped layout exchanges
# them) so the picture matches the pad in the player's hands without vendor marks or coloured jewels.
# Bodies are cubic béziers sampled to polygons. Vector paths only, no bitmaps.
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
# Right half, top-centre to bottom-centre: start, then cubic segments (c1, c2, end).
# A flat shoulder, a tight horn, a grip that flares and tucks back to a higher centre valley.
const HALF := {
	"xbox": [Vector2(0, -40),
		Vector2(22, -40.5), Vector2(46, -42), Vector2(62, -40),
		Vector2(70, -38), Vector2(78, -28), Vector2(77, -16),
		Vector2(78, -4), Vector2(75, 14), Vector2(70, 30),
		Vector2(66, 44), Vector2(58, 56), Vector2(48, 56),
		Vector2(42, 54), Vector2(38, 46), Vector2(34, 38),
		Vector2(30, 32), Vector2(24, 26), Vector2(14, 24),
		Vector2(8, 23), Vector2(3, 22.5), Vector2(0, 22)],
	"playstation": [Vector2(0, -38),
		Vector2(24, -38.5), Vector2(50, -40), Vector2(66, -38),
		Vector2(74, -36), Vector2(82, -26), Vector2(80, -14),
		Vector2(82, -2), Vector2(78, 16), Vector2(72, 34),
		Vector2(66, 48), Vector2(56, 60), Vector2(46, 58),
		Vector2(40, 56), Vector2(36, 48), Vector2(32, 42),
		Vector2(28, 38), Vector2(20, 36), Vector2(10, 35),
		Vector2(5, 34.5), Vector2(2, 34), Vector2(0, 34)],
	"switch": [Vector2(0, -39),
		Vector2(20, -39.5), Vector2(42, -41), Vector2(58, -39),
		Vector2(66, -37), Vector2(74, -28), Vector2(74, -16),
		Vector2(75, -4), Vector2(72, 14), Vector2(66, 32),
		Vector2(60, 46), Vector2(52, 56), Vector2(44, 54),
		Vector2(38, 52), Vector2(34, 44), Vector2(30, 36),
		Vector2(26, 30), Vector2(20, 26), Vector2(12, 24),
		Vector2(6, 23.5), Vector2(2, 23), Vector2(0, 23)],
	"deck": [Vector2(0, -56),
		Vector2(36, -56.5), Vector2(88, -57), Vector2(116, -54),
		Vector2(128, -50), Vector2(144, -40), Vector2(148, -26),
		Vector2(150, -12), Vector2(148, 8), Vector2(144, 26),
		Vector2(140, 40), Vector2(132, 52), Vector2(118, 56),
		Vector2(110, 55), Vector2(102, 50), Vector2(94, 47),
		Vector2(64, 47), Vector2(32, 50), Vector2(14, 51),
		Vector2(6, 51.5), Vector2(2, 52), Vector2(0, 52)],
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


## Letter printed on a face cap. South/east/west/north, with the swapped layout exchanged.
static func face_mark(style: String, id: int) -> String:
	var swap := style == "switch"
	match id:
		JOY_BUTTON_A: return "B" if swap else "A"
		JOY_BUTTON_B: return "A" if swap else "B"
		JOY_BUTTON_X: return "Y" if swap else "X"
		JOY_BUTTON_Y: return "X" if swap else "Y"
	return ""


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


## Stadium (capsule) centred at `center`, long axis `angle` radians, outer length and thickness in mm.
static func _stadium(center: Vector2, length: float, thick: float, angle: float) -> PackedVector2Array:
	var dir := Vector2(cos(angle), sin(angle))
	var cap_r := thick * 0.5
	var hl := maxf(0.0, length * 0.5 - cap_r)
	var c0 := center - dir * hl
	var c1 := center + dir * hl
	var out := PackedVector2Array()
	var steps := 9
	for i in steps + 1:
		var a := angle - PI * 0.5 + PI * float(i) / float(steps)
		out.append(c1 + Vector2(cos(a), sin(a)) * cap_r)
	for i in steps + 1:
		var a := angle + PI * 0.5 + PI * float(i) / float(steps)
		out.append(c0 + Vector2(cos(a), sin(a)) * cap_r)
	return out


## Trigger or bumper: a stadium along the shoulder, outer end lifted. `above` is how far the
## stadium's centre sits over the body edge; the bumper covers the trigger's lower half.
static func _shoulder_poly(rg: PackedVector2Array, x0: float, x1: float, sgn: float, above: float, thick: float, tilt: float) -> PackedVector2Array:
	var mid := (x0 + x1) * 0.5 * sgn
	var angle := -tilt if sgn > 0.0 else PI + tilt
	return _stadium(Vector2(mid, top_y(rg, mid) - above), absf(x1 - x0), thick, angle)


## Inset a screen-clockwise outline by `dist` mm along the averaged inward normal.
static func _inset(poly: PackedVector2Array, dist: float) -> PackedVector2Array:
	var n := poly.size()
	var out := PackedVector2Array()
	for i in n:
		var prev: Vector2 = poly[(i - 1 + n) % n]
		var cur: Vector2 = poly[i]
		var nxt: Vector2 = poly[(i + 1) % n]
		var e1 := (cur - prev).normalized()
		var e2 := (nxt - cur).normalized()
		var n1 := Vector2(-e1.y, e1.x)
		var n2 := Vector2(-e2.y, e2.x)
		var nn := n1 + n2
		nn = n1 if nn.length() < 0.001 else nn.normalized()
		var miter := clampf(dist / maxf(0.45, nn.dot(n1)), 0.0, dist * 2.2)
		out.append(cur + nn * miter)
	return out


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
	# Triggers sit behind the bumpers; both are their own parts, not a smear along the outline.
	var bump: Vector2 = sp.bump
	var trig: Vector2 = sp.trig
	var tilt := 0.05 if style == "deck" else 0.22
	list.append(_ctl("lt", trigger_name(style, true), _shoulder_poly(rg, trig.x, trig.y, -1.0, 10.5, 11.5, tilt), false, "lt"))
	list.append(_ctl("rt", trigger_name(style, false), _shoulder_poly(rg, trig.x, trig.y, 1.0, 10.5, 11.5, tilt), false, "rt"))
	list.append(_ctl(JOY_BUTTON_LEFT_SHOULDER, button_name(style, JOY_BUTTON_LEFT_SHOULDER), _shoulder_poly(rg, bump.x, bump.y, -1.0, 3.0, 7.6, tilt * 0.8)))
	list.append(_ctl(JOY_BUTTON_RIGHT_SHOULDER, button_name(style, JOY_BUTTON_RIGHT_SHOULDER), _shoulder_poly(rg, bump.x, bump.y, 1.0, 3.0, 7.6, tilt * 0.8)))
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


## Chassis (darker, dropped a few mm) plus a lighter top case inset from the outline.
static func _body(ci: CanvasItem, rg: PackedVector2Array, top: Color, bottom: Color, px: float) -> void:
	var bb := _bbox(rg)
	var c := bb.get_center()
	var wall := _scaled(rg, c, 1.0, Vector2(0, 3.4))
	ci.draw_colored_polygon(_scaled(rg, c, 1.035, Vector2(0, 8.0)), Color(0, 0, 0, 0.55))
	_grad_poly(ci, wall, bottom.darkened(0.25), bottom.darkened(0.45))
	_grad_poly(ci, rg, top, bottom)
	ci.draw_polyline(_closed(rg), top.lightened(0.08), 1.5 * px, true)
	var inner := _inset(rg, 3.6)
	_grad_poly(ci, inner, top.lightened(0.1), bottom.lightened(0.16))
	ci.draw_polyline(_closed(inner), Color(0, 0, 0, 0.4), 1.25 * px, true)
	ci.draw_polyline(_closed(_inset(rg, 1.2)), Color(1, 1, 1, 0.14), 1.0 * px, true)
	var n := rg.size()
	for i in n:
		var a: Vector2 = rg[i]
		var b: Vector2 = rg[(i + 1) % n]
		var yy := (a.y + b.y) * 0.5
		if yy < bb.position.y + bb.size.y * 0.28:
			var t := clampf(1.0 - (yy - bb.position.y) / (bb.size.y * 0.28), 0.0, 1.0)
			ci.draw_line(a, b, Color(1, 1, 1, 0.06 + 0.34 * t), 2.0 * px, true)


## Domed cap. The highlight sits up-left; a crescent on the lower-right lip sells the curve.
static func _cap(ci: CanvasItem, c: Vector2, r: float, base: Color, px: float) -> void:
	ci.draw_circle(c, r, base.darkened(0.2))
	for i in 6:
		var k := 1.0 - float(i) * 0.13
		ci.draw_circle(c + Vector2(-r * 0.045, -r * 0.055) * float(i), r * k, base.lightened(0.045 * float(i)))
	ci.draw_circle(c + Vector2(-r * 0.28, -r * 0.32), r * 0.24, Color(1, 1, 1, 0.2))
	ci.draw_arc(c, r * 0.8, 3.5, 5.3, 14, Color(1, 1, 1, 0.3), 1.15 * px, true)


static func _well(ci: CanvasItem, c: Vector2, r: float, px: float) -> void:
	ci.draw_circle(c + Vector2(0, r * 0.14), r * 1.12, Color(0, 0, 0, 0.45))
	ci.draw_circle(c, r * 1.08, Color(0.03, 0.03, 0.035))
	ci.draw_arc(c, r * 1.02, 0.25, PI - 0.25, 18, Color(1, 1, 1, 0.16), 1.0 * px, true)


static func _stick(ci: CanvasItem, c: Vector2, r: float, well: float, s: Dictionary, px: float, outline: PackedVector2Array) -> void:
	ci.draw_circle(c + Vector2(0, 1.3), well + 0.8, Color(0, 0, 0, 0.5))
	ci.draw_circle(c, well, Color(0.025, 0.025, 0.03))
	ci.draw_arc(c, well - 0.7, 0.15, PI - 0.15, 22, Color(1, 1, 1, 0.2), 1.5 * px, true)
	ci.draw_arc(c, well - 0.55, PI + 0.15, TAU - 0.15, 20, Color(0, 0, 0, 0.7), 1.7 * px, true)
	var base := _fill(Color(0.17, 0.175, 0.19), s)
	_cap(ci, c, r, base, px)
	ci.draw_arc(c, r * 0.7, 0.0, TAU, 36, Color(1, 1, 1, 0.1), 0.7 * px, true)
	ci.draw_arc(c, r * 0.46, 0.0, TAU, 28, Color(0, 0, 0, 0.4), 0.85 * px, true)
	_edges(ci, outline, s, px)


static func _dpad(ci: CanvasItem, c: Vector2, cs: float, ctls: Dictionary, states: Dictionary, px: float) -> void:
	var recess := _rect_pts(c, Vector2(cs, cs) * 1.05, 3.4)
	ci.draw_colored_polygon(_scaled(recess, c, 1.0, Vector2(0, 1.1)), Color(0, 0, 0, 0.5))
	_grad_poly(ci, recess, Color(0.05, 0.05, 0.06), Color(0.11, 0.115, 0.13))
	ci.draw_polyline(_closed(recess), Color(1, 1, 1, 0.08), 0.8 * px, true)
	var w := cs * 0.32
	var cross := _cross_pts(c, cs * 0.9, w)
	ci.draw_colored_polygon(_scaled(cross, c, 1.0, Vector2(0, 0.9)), Color(0, 0, 0, 0.45))
	_grad_poly(ci, cross, Color(0.34, 0.345, 0.37), Color(0.16, 0.165, 0.18))
	ci.draw_polyline(_closed(cross), Color(1, 1, 1, 0.24), 1.0 * px, true)
	for id in [JOY_BUTTON_DPAD_UP, JOY_BUTTON_DPAD_DOWN, JOY_BUTTON_DPAD_LEFT, JOY_BUTTON_DPAD_RIGHT]:
		var s: Dictionary = states.get(id, {})
		if s.is_empty():
			continue
		var outline: PackedVector2Array = ctls[id].outline
		if s.has("tint") or s.get("live", false) or s.get("pulse", 0.0) > 0.0:
			ci.draw_colored_polygon(outline, Color(_fill(Color(0.2, 0.2, 0.22), s), 0.85))
		_edges(ci, outline, s, px)
	ci.draw_circle(c, w * 0.3, Color(0.08, 0.08, 0.09))
	ci.draw_arc(c, w * 0.3, PI * 1.15, PI * 1.9, 10, Color(1, 1, 1, 0.22), 0.8 * px, true)
	for d in [Vector2(0, -1), Vector2(0, 1), Vector2(-1, 0), Vector2(1, 0)]:
		var dv: Vector2 = d
		var perp := Vector2(-dv.y, dv.x)
		var tip: Vector2 = c + dv * (cs * 0.5 - 3.0)
		ci.draw_colored_polygon(PackedVector2Array([tip + dv * 1.5, tip - dv * 1.5 + perp * 1.9, tip - dv * 1.5 - perp * 1.9]),
			Color(1, 1, 1, 0.55))


static func _face(ci: CanvasItem, style: String, id: int, c: Vector2, r: float, s: Dictionary, px: float,
		outline: PackedVector2Array, texts: Array) -> void:
	var fill := _fill(Color(0.2, 0.205, 0.22), s)
	_well(ci, c, r, px)
	_cap(ci, c, r, fill, px)
	var letter := Color(0.1, 0.08, 0.04) if s.get("live", false) else Color(0.94, 0.95, 0.97)
	texts.append({"pos": c, "text": face_mark(style, id), "size": r * 1.35, "col": letter})
	_edges(ci, outline, s, px)


static func _small(ci: CanvasItem, c: Vector2, r: float, s: Dictionary, px: float, outline: PackedVector2Array) -> void:
	var base := _fill(Color(0.2, 0.205, 0.22), s)
	_well(ci, c, r, px)
	_cap(ci, c, r, base, px)
	_edges(ci, outline, s, px)


static func _shoulder(ci: CanvasItem, poly: PackedVector2Array, top: Color, bottom: Color, s: Dictionary, px: float) -> void:
	var hi := _fill(top, s)
	var lo := _fill(bottom, s)
	var wall := PackedVector2Array()
	for p in poly:
		wall.append(p + Vector2(0, 1.7))
	ci.draw_colored_polygon(wall, lo.darkened(0.3))
	_grad_poly(ci, poly, hi, lo)
	ci.draw_polyline(_closed(poly), Color(1, 1, 1, 0.32), 1.15 * px, true)
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
	var light := style == "playstation"
	var shell_top := Color(0.93, 0.94, 0.96) if light else Color(0.38, 0.39, 0.42)
	var shell_bot := Color(0.64, 0.66, 0.70) if light else Color(0.14, 0.145, 0.16)
	if style == "deck":
		shell_top = Color(0.32, 0.33, 0.36)
		shell_bot = Color(0.11, 0.115, 0.13)
	var trig_top := Color(0.78, 0.80, 0.84) if light else Color(0.24, 0.245, 0.27)
	var trig_bot := Color(0.55, 0.57, 0.61) if light else Color(0.11, 0.115, 0.13)
	var bump_top := Color(0.97, 0.97, 0.98) if light else Color(0.46, 0.47, 0.51)
	var bump_bot := Color(0.74, 0.76, 0.80) if light else Color(0.24, 0.25, 0.28)
	var ink := Color(0.16, 0.17, 0.19, 0.8) if light else Color(0.94, 0.95, 0.97, 0.82)
	for id in ["lt", "rt"]:
		var ts: Dictionary = st.get(id, {})
		_shoulder(ci, cs[id].outline, trig_top, trig_bot, ts, px)
		var tc: Color = Color(0.1, 0.08, 0.04) if ts.get("live", false) else ink
		texts.append({"pos": cs[id].c, "text": cs[id].name, "size": 3.6, "col": tc})
	for id2 in [JOY_BUTTON_LEFT_SHOULDER, JOY_BUTTON_RIGHT_SHOULDER]:
		var bs: Dictionary = st.get(id2, {})
		_shoulder(ci, cs[id2].outline, bump_top, bump_bot, bs, px)
		var bc: Color = Color(0.1, 0.08, 0.04) if bs.get("live", false) else ink
		texts.append({"pos": cs[id2].c, "text": cs[id2].name, "size": 3.3, "col": bc})
	_body(ci, rg, shell_top, shell_bot, px)
	# A shallow dish under each cluster, so the caps sit in the shell instead of on it.
	ci.draw_circle(sp.face, sp.fo + sp.fr + 2.4, Color(0, 0, 0, 0.16 if light else 0.22))
	ci.draw_circle(sp.dpad, sp.cross * 0.62, Color(0, 0, 0, 0.1))
	match style:
		"playstation":
			var tp := _rect_pts(Vector2(0, -14), Vector2(48, 28), 5.5)
			_grad_poly(ci, tp, Color(0.16, 0.17, 0.19), Color(0.08, 0.085, 0.1))
			ci.draw_polyline(_closed(tp), Color(1, 1, 1, 0.2), 1.0 * px, true)
			ci.draw_line(Vector2(-16, -14), Vector2(16, -14), Color(1, 1, 1, 0.06), 0.8 * px, true)
			_small(ci, sp.guide, 4.2, {}, px, PackedVector2Array([sp.guide, sp.guide]))
		"xbox":
			_small(ci, sp.guide, 5.0, {}, px, PackedVector2Array([sp.guide, sp.guide]))
			ci.draw_circle(sp.guide, 2.2, Color(0.08, 0.08, 0.09, 0.85))
		"switch":
			_small(ci, sp.guide, 4.2, {}, px, PackedVector2Array([sp.guide, sp.guide]))
			var cap := _rect_pts(Vector2(-13, -12), Vector2(7.5, 7.5), 1.6)
			_grad_poly(ci, cap, Color(0.28, 0.285, 0.31), Color(0.14, 0.145, 0.16))
			ci.draw_polyline(_closed(cap), Color(1, 1, 1, 0.28), 1.0 * px, true)
		"deck":
			var scr := _rect_pts(Vector2(0, -4), Vector2(150, 92), 4.5)
			var bez := _rect_pts(Vector2(0, -4), Vector2(158, 100), 7.0)
			ci.draw_colored_polygon(bez, Color(0.02, 0.022, 0.028))
			ci.draw_polyline(_closed(bez), Color(1, 1, 1, 0.16), 1.1 * px, true)
			_grad_poly(ci, scr, Color(0.08, 0.11, 0.16), Color(0.015, 0.02, 0.035))
			ci.draw_colored_polygon(PackedVector2Array([Vector2(-68, -46), Vector2(8, -46), Vector2(-28, 36), Vector2(-68, 36)]), Color(0.55, 0.7, 1.0, 0.07))
			ci.draw_polyline(_closed(scr), Color(1, 1, 1, 0.12), 0.8 * px, true)
			for tp2 in ["tl", "tr"]:
				var c2: Vector2 = cs[tp2].c
				ci.draw_circle(c2, 16.2, Color(0, 0, 0, 0.35))
				ci.draw_circle(c2, 15.0, Color(0.07, 0.075, 0.09))
				ci.draw_arc(c2, 14.2, 0.0, TAU, 40, Color(1, 1, 1, 0.14), 1.0 * px, true)
				ci.draw_arc(c2, 9.0, 0.4, PI - 0.4, 16, Color(1, 1, 1, 0.08), 0.7 * px, true)
			for gid in ["l4", "l5", "r4", "r5"]:
				var g: Dictionary = cs[gid]
				ci.draw_colored_polygon(g.outline, Color(0.1, 0.105, 0.12))
				ci.draw_polyline(_closed(g.outline), Color(1, 1, 1, 0.22), 1.0 * px, true)
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
