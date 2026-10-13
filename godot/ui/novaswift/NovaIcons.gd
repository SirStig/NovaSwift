# NOVA Swift — NovaSwift UI kit: vector glyphs standing in for the Apple app's SF Symbols.
#
# Godot has no SF Symbols, so every symbol the Apple screens use is redrawn here as a few strokes
# and fills on a 24 x 24 grid and rasterised (4x supersampled) into an ImageTexture of any size and
# colour. Textures work with Button.icon / TextureRect, so they also compose in the headless
# preview (tests/UiCompose.gd), unlike custom _draw.
#
#   Icons.texture("trash", 16, Color.RED)      -> ImageTexture
#   Icons.image("checkmark.bold", 16, Color.BLACK) -> Image
#   Icons.has("trash")
#
# Ops (24-grid coordinates):  ["L", width, [x, y, x, y, ...]] round-capped polyline ·
# ["P", [x, y, ...]] filled polygon · ["C", cx, cy, r, width] ring (width 0 = disc) ·
# ["R", x, y, w, h, radius, width] rounded rectangle (width 0 = filled) ·
# ["A", cx, cy, r, from_deg, to_deg, width] arc. An op name starting with "-" erases instead.
extends RefCounted

const SVG = preload("res://ui/novaswift/NovaSVG.gd")

const GLYPHS := {
	"chevron.right": [["L", 2.2, [9, 5, 16, 12, 9, 19]]],
	"chevron.left": [["L", 2.2, [15, 5, 8, 12, 15, 19]]],
	"chevron.down": [["L", 2.2, [5, 9, 12, 16, 19, 9]]],
	"chevron.up": [["L", 2.2, [5, 15, 12, 8, 19, 15]]],
	"chevron.up.chevron.down": [["L", 2.0, [7, 10, 12, 5, 17, 10]], ["L", 2.0, [7, 14, 12, 19, 17, 14]]],
	"checkmark": [["L", 2.4, [5, 12.5, 10, 17.5, 19, 7]]],
	"checkmark.bold": [["L", 3.4, [5, 12.5, 10, 17.5, 19, 7]]],
	"xmark": [["L", 2.4, [6, 6, 18, 18]], ["L", 2.4, [18, 6, 6, 18]]],
	"plus": [["L", 2.4, [12, 5, 12, 19]], ["L", 2.4, [5, 12, 19, 12]]],
	"minus": [["L", 2.4, [5, 12, 19, 12]]],
	"trash": [["L", 2.0, [4, 7, 20, 7]], ["L", 2.0, [9, 7, 9, 4, 15, 4, 15, 7]],
		["L", 2.0, [6, 7, 7, 20, 17, 20, 18, 7]], ["L", 1.8, [10, 11, 10, 16]], ["L", 1.8, [14, 11, 14, 16]]],
	"magnifyingglass": [["C", 10.5, 10.5, 6.5, 2.2], ["L", 2.4, [15.5, 15.5, 20.5, 20.5]]],
	"arrow.clockwise": [["A", 12, 12, 7.5, -50, 250, 2.2], ["P", [15, 1.5, 21, 6.5, 14, 8.5]]],
	"arrow.counterclockwise": [["A", 12, 12, 7.5, -70, 230, 2.2], ["P", [9, 1.5, 3, 6.5, 10, 8.5]]],
	"square.and.arrow.down": [["L", 2.0, [12, 3.5, 12, 15]], ["L", 2.0, [7.5, 10.5, 12, 15, 16.5, 10.5]],
		["L", 2.0, [5, 13, 5, 20, 19, 20, 19, 13]]],
	"plus.square.on.square": [["R", 3, 9, 12, 12, 2.5, 2.0], ["L", 2.0, [9, 5.5, 9, 3, 18.5, 3, 21, 5.5, 21, 15, 18, 15]],
		["L", 1.8, [9, 12, 9, 18]], ["L", 1.8, [6, 15, 12, 15]]],
	"play.fill": [["P", [7, 4, 20, 12, 7, 20]]],
	"play.circle.fill": [["C", 12, 12, 10, 0], ["-P", [10, 7.5, 17, 12, 10, 16.5]]],
	"info.circle": [["C", 12, 12, 9.5, 2.0], ["L", 2.0, [12, 11, 12, 17]], ["C", 12, 7.6, 1.2, 0]],
	"pencil": [["L", 2.0, [5, 19, 5.8, 15, 15.5, 5.3, 18.7, 8.5, 9, 18.2, 5, 19]]],
	"gearshape.fill": [["C", 12, 12, 7, 0], ["L", 3.6, [12, 3, 12, 6]], ["L", 3.6, [12, 18, 12, 21]],
		["L", 3.6, [3, 12, 6, 12]], ["L", 3.6, [18, 12, 21, 12]], ["L", 3.6, [5.6, 5.6, 7.7, 7.7]],
		["L", 3.6, [16.3, 16.3, 18.4, 18.4]], ["L", 3.6, [5.6, 18.4, 7.7, 16.3]], ["L", 3.6, [16.3, 7.7, 18.4, 5.6]],
		["-C", 12, 12, 2.8, 0]],
	"ladybug": [["C", 12, 13.5, 6.5, 0], ["C", 12, 6.5, 3, 0], ["-L", 1.2, [12, 8, 12, 20]],
		["L", 1.8, [3, 11, 6.5, 12]], ["L", 1.8, [21, 11, 17.5, 12]], ["L", 1.8, [3.5, 18, 6.8, 16]],
		["L", 1.8, [20.5, 18, 17.2, 16]]],
	"map.fill": [["P", [3, 6, 8.5, 4, 8.5, 18, 3, 20]], ["P", [9.7, 4, 14.3, 6, 14.3, 20, 9.7, 18]],
		["P", [15.5, 6, 21, 4, 21, 18, 15.5, 20]]],
	"person.crop.circle": [["C", 12, 12, 10, 1.8], ["C", 12, 10, 3.2, 0], ["A", 12, 19.5, 6.5, 205, 335, 2.0]],
	"list.bullet.clipboard": [["R", 5, 4.5, 14, 17, 2.5, 2.0], ["R", 9, 2.5, 6, 4, 1.5, 0],
		["L", 1.8, [8.5, 11, 15.5, 11]], ["L", 1.8, [8.5, 15, 15.5, 15]]],
	"point.3.connected": [["C", 12, 5.5, 2.4, 0], ["C", 5.5, 18, 2.4, 0], ["C", 18.5, 18, 2.4, 0],
		["L", 1.6, [12, 8, 6, 15.8]], ["L", 1.6, [12, 8, 18, 15.8]], ["L", 1.6, [8, 18, 16, 18]]],
	"fullscreen": [["L", 2.0, [4, 4, 10.5, 10.5]], ["L", 2.0, [4, 4, 4, 9.5]], ["L", 2.0, [4, 4, 9.5, 4]],
		["L", 2.0, [20, 20, 13.5, 13.5]], ["L", 2.0, [20, 20, 20, 14.5]], ["L", 2.0, [20, 20, 14.5, 20]]],
	"door.exit": [["L", 2.0, [10, 4, 5, 4, 5, 20, 10, 20]], ["L", 2.0, [10, 12, 20, 12]], ["L", 2.0, [16, 8, 20, 12, 16, 16]]],
	"folder": [["L", 2.0, [3, 7, 3, 19, 21, 19, 21, 9, 11.5, 9, 9.5, 6, 3, 6, 3, 7]]],
	"person.2.fill": [["C", 8.5, 8, 3.4, 0], ["C", 16.5, 9, 2.8, 0], ["L", 3.4, [3.5, 18.5, 4.5, 15.5, 8.5, 14.5, 12.5, 15.5, 13.5, 18.5]],
		["L", 2.8, [15, 15, 18, 15, 20.5, 17.5]]],
	"sparkles": [["P", [10, 3, 12, 9, 18, 11, 12, 13, 10, 19, 8, 13, 2, 11, 8, 9]], ["P", [18.5, 3, 19.5, 6, 22.5, 7, 19.5, 8, 18.5, 11, 17.5, 8, 14.5, 7, 17.5, 6]]],
	"gamecontroller": [["R", 2.5, 7.5, 19, 10.5, 5, 2.0], ["L", 1.8, [8, 10.5, 8, 15]], ["L", 1.8, [5.8, 12.8, 10.2, 12.8]],
		["C", 15.5, 11.5, 1.1, 0], ["C", 18, 14, 1.1, 0]],
	"wand.and.stars": [["L", 2.4, [4.5, 19.5, 15, 9]], ["P", [17.5, 2.5, 18.5, 5.5, 21.5, 6.5, 18.5, 7.5, 17.5, 10.5, 16.5, 7.5, 13.5, 6.5, 16.5, 5.5]]],
	"dpad": [["L", 1.8, [9, 3, 15, 3, 15, 9, 21, 9, 21, 15, 15, 15, 15, 21, 9, 21, 9, 15, 3, 15, 3, 9, 9, 9, 9, 3]]],
	"speaker.wave.2": [["P", [3, 9, 7.5, 9, 12.5, 5, 12.5, 19, 7.5, 15, 3, 15]], ["A", 13, 12, 5, -50, 50, 1.9], ["A", 13, 12, 9, -50, 50, 1.9]],
	"accessibility": [["C", 12, 12, 9.5, 1.8], ["C", 12, 7.3, 1.3, 0], ["L", 1.9, [7, 10, 17, 10]], ["L", 1.9, [12, 10, 12, 14]],
		["L", 1.9, [12, 14, 9.5, 18]], ["L", 1.9, [12, 14, 14.5, 18]]],
	"externaldrive": [["R", 3, 12, 18, 8, 3, 2.0], ["L", 2.0, [7, 16, 7.2, 16]], ["C", 8.5, 8, 3.4, 1.8], ["C", 14.5, 8, 4.2, 1.8]],
	"lifepreserver": [["C", 12, 12, 9.5, 2.0], ["C", 12, 12, 4, 2.0], ["L", 2.6, [5.3, 5.3, 9.2, 9.2]], ["L", 2.6, [14.8, 14.8, 18.7, 18.7]],
		["L", 2.6, [5.3, 18.7, 9.2, 14.8]], ["L", 2.6, [14.8, 9.2, 18.7, 5.3]]],
	"hammer": [["L", 3.0, [4.5, 19.5, 13, 11]], ["P", [11, 4, 18, 3.5, 21, 7, 20, 11, 15, 10]]],
	"keyboard": [["R", 2, 6.5, 20, 11, 2.5, 2.0], ["L", 2.2, [6, 10, 6.1, 10]], ["L", 2.2, [10, 10, 10.1, 10]], ["L", 2.2, [14, 10, 14.1, 10]],
		["L", 2.2, [18, 10, 18.1, 10]], ["L", 1.8, [8, 14.5, 16, 14.5]]],
	"macwindow": [["R", 3, 4.5, 18, 15, 2.5, 2.0], ["L", 1.8, [3, 8.5, 21, 8.5]]],
	"arrow.down.circle.fill": [["C", 12, 12, 10, 0], ["-L", 2.0, [12, 6.5, 12, 15.5]], ["-L", 2.0, [8, 12, 12, 16, 16, 12]]],
	"puzzlepiece.extension": [["R", 4, 9, 13, 11, 2.0, 2.0], ["C", 10.5, 6.5, 2.4, 2.0], ["C", 19, 14.5, 2.4, 2.0]],
	"graduationcap": [["P", [12, 4.5, 22.5, 10, 12, 15.5, 1.5, 10]], ["L", 2.0, [6, 13, 6, 17, 12, 20, 18, 17, 18, 13]]],
	"exclamationmark.triangle.fill": [["P", [12, 3, 22.5, 20.5, 1.5, 20.5]], ["-L", 2.0, [12, 9, 12, 14]], ["-C", 12, 17.2, 1.2, 0]],
	"wifi.slash": [["A", 12, 18, 4, 225, 315, 2.0], ["A", 12, 18, 8.5, 225, 315, 2.0], ["A", 12, 18, 13, 225, 315, 2.0], ["L", 2.0, [4, 4, 20, 20]]],
	"dice": [["R", 4, 4, 16, 16, 3.5, 2.0], ["C", 9, 9, 1.4, 0], ["C", 15, 15, 1.4, 0], ["C", 12, 12, 1.4, 0]],
	"doc.on.doc": [["R", 8.5, 3.5, 12, 14, 2.0, 1.9], ["R", 3.5, 7.5, 12, 14, 2.0, 1.9]],
	"clock.arrow.circlepath": [["C", 12, 12, 9, 1.8], ["L", 1.9, [12, 7, 12, 12.5, 15.5, 14.5]]],
	"arrow.uturn.backward.circle": [["C", 12, 12, 10, 1.8], ["L", 1.9, [8.5, 10, 14, 10, 16, 12, 14, 15, 9, 15]], ["L", 1.9, [8.5, 10, 10.5, 8]], ["L", 1.9, [8.5, 10, 10.5, 12]]],
	"checkmark.circle.fill": [["C", 12, 12, 10, 0], ["-L", 2.2, [7.5, 12.3, 10.8, 15.5, 16.5, 9]]],
	"arrow.right": [["L", 2.0, [4, 12, 20, 12]], ["L", 2.0, [14, 6, 20, 12, 14, 18]]],
	"shippingbox": [["P", [12, 3, 21, 7.5, 12, 12, 3, 7.5]], ["L", 1.8, [3, 8, 3, 17, 12, 21.5, 21, 17, 21, 8]], ["L", 1.8, [12, 12, 12, 21.5]]],
	"photo": [["R", 3, 5, 18, 14, 2.5, 2.0], ["C", 8.5, 10, 1.7, 0], ["L", 1.9, [4, 17.5, 9, 13.5, 13, 16.5, 16.5, 13, 20, 16.5]]],
	"slider.horizontal.3": [["L", 1.9, [3, 7, 21, 7]], ["L", 1.9, [3, 12, 21, 12]], ["L", 1.9, [3, 17, 21, 17]], ["C", 8, 7, 2.2, 0], ["C", 16, 12, 2.2, 0], ["C", 10, 17, 2.2, 0]],
	"rectangle.on.rectangle": [["R", 7, 3.5, 13.5, 10.5, 2.0, 1.8], ["R", 3.5, 9.5, 13.5, 10.5, 2.0, 1.8]],
	"sparkles.tv": [["R", 2.5, 4.5, 19, 13, 2.5, 1.9], ["L", 1.9, [8, 20.5, 16, 20.5]], ["P", [12, 7, 13, 10.4, 16.4, 11.4, 13, 12.4, 12, 15.8, 11, 12.4, 7.6, 11.4, 11, 10.4]]],
	"star": [["P", [12, 3, 14.6, 9, 21, 9.5, 16, 14, 17.6, 20.5, 12, 17, 6.4, 20.5, 8, 14, 3, 9.5, 9.4, 9]]],
}

static var _cache := {}


static func has(name: String) -> bool:
	return SVG.has(name) or GLYPHS.has(name)


static func texture(name: String, px := 16, color := Color.WHITE) -> Texture2D:
	if SVG.has(name):
		return SVG.texture(name, px, color)
	return ImageTexture.create_from_image(image(name, px, color))


## The glyph rasterised at `px` x `px`: the SVG version (NovaSVG.gd) when one exists, else the
## stroke ops below (4x supersampled). Unknown names draw a small square.
static func image(name: String, px := 16, color := Color.WHITE) -> Image:
	if SVG.has(name):
		return SVG.image(name, px, color)
	var key := "%s/%d" % [name, px]
	var cov: Image
	if _cache.has(key):
		cov = _cache[key]
	else:
		cov = _rasterise(GLYPHS.get(name, [["R", 6, 6, 12, 12, 2, 2.0]]), px)
		_cache[key] = cov
	var out := Image.create(px, px, false, Image.FORMAT_RGBA8)
	for y in px:
		for x in px:
			var a: float = cov.get_pixel(x, y).a
			if a > 0.0:
				out.set_pixel(x, y, Color(color.r, color.g, color.b, color.a * a))
	return out


static func _rasterise(ops: Array, px: int) -> Image:
	var ss := 4
	var n := px * ss
	var k := 24.0 / float(n)
	var hi := PackedByteArray()
	hi.resize(n * n)
	hi.fill(0)
	for op in ops:
		var kind: String = op[0]
		var erase := kind.begins_with("-")
		if erase:
			kind = kind.substr(1)
		var poly := PackedVector2Array()
		if kind == "P":
			var pts: Array = op[1]
			for i in range(0, pts.size(), 2):
				poly.append(Vector2(pts[i], pts[i + 1]))
		var val := 0 if erase else 1
		for y in n:
			for x in n:
				var p := Vector2((x + 0.5) * k, (y + 0.5) * k)
				if _hit(kind, op, poly, p):
					hi[y * n + x] = val
	var img := Image.create(px, px, false, Image.FORMAT_RGBA8)
	for y in px:
		for x in px:
			var s := 0
			for yy in ss:
				for xx in ss:
					s += hi[(y * ss + yy) * n + x * ss + xx]
			if s > 0:
				img.set_pixel(x, y, Color(1, 1, 1, float(s) / float(ss * ss)))
	return img


static func _hit(kind: String, op: Array, poly: PackedVector2Array, p: Vector2) -> bool:
	match kind:
		"P":
			return Geometry2D.is_point_in_polygon(p, poly)
		"L":
			var w: float = op[1]
			var pts: Array = op[2]
			for i in range(0, pts.size() - 2, 2):
				var a := Vector2(pts[i], pts[i + 1])
				var b := Vector2(pts[i + 2], pts[i + 3])
				if Geometry2D.get_closest_point_to_segment(p, a, b).distance_to(p) <= w * 0.5:
					return true
			return false
		"C":
			var d := p.distance_to(Vector2(op[1], op[2]))
			var r: float = op[3]
			var w: float = op[4]
			return d <= r if w <= 0.0 else absf(d - r) <= w * 0.5
		"A":
			var c := Vector2(op[1], op[2])
			var r: float = op[3]
			var w: float = op[6]
			var d := p.distance_to(c)
			if absf(d - r) > w * 0.5:
				return false
			var ang := rad_to_deg((p - c).angle())
			var a0: float = op[4]
			var a1: float = op[5]
			var rel := fposmod(ang - a0, 360.0)
			return rel <= fposmod(a1 - a0, 360.0)
		"R":
			var pos := Vector2(op[1], op[2])
			var size := Vector2(op[3], op[4])
			var rad: float = op[5]
			var w: float = op[6]
			var q := (p - (pos + size * 0.5)).abs() - (size * 0.5 - Vector2(rad, rad))
			var sd := Vector2(maxf(q.x, 0.0), maxf(q.y, 0.0)).length() + minf(maxf(q.x, q.y), 0.0) - rad
			return sd <= 0.0 if w <= 0.0 else (sd <= 0.0 and sd >= -w)
	return false
