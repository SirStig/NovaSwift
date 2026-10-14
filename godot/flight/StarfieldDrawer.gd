# The star backdrop -- GameScene.buildOriginalStarfield / buildStarfield / updateMurkFog's star level.
#
# Classic and Enhanced draw the original's ambient field (0x0046ebf0): at most 20 opaque spïn-700
# stars at native size (count from the view height), each streaming past at (1 + Random(35)*0.01)x
# the world's scroll (0 extra when the Parallax Starfield preference is off), wrapped across the view,
# darkened by the system's murk and hidden while murk < 0. Nova Swift keeps the port's own dot field.
# Stars live in screen space: under a turned camera their offsets are turned with the world.
extends RefCounted

const Sprites = preload("res://flight/FlightSprites.gd")

const FIELD := Vector2(4096, 4096)
const COLOR_STAR_NEAR := Color(0.9, 0.9, 1.0, 0.9)
const COLOR_STAR_FAR := Color(0.7, 0.7, 0.85, 0.5)

var r                      # FlightRenderer
var stars_near: PackedVector2Array
var stars_far: PackedVector2Array
var _orig: Array = []      # [{base, factor, frame}]
var _orig_count := -1
var _orig_parallax := true


func setup(renderer) -> void:
	r = renderer
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x50FA
	for i in 220:
		stars_far.append(Vector2(rng.randf() * FIELD.x, rng.randf() * FIELD.y))
	for i in 140:
		stars_near.append(Vector2(rng.randf() * FIELD.x, rng.randf() * FIELD.y))


func _rebuild_original(vp: Vector2, count: int) -> void:
	_orig.clear()
	var e = r.sprites.entry(Sprites.STARFIELD, 0)
	var frames: int = e["frames"] if e != null else 1
	_orig_parallax = r.parallax_starfield
	for i in count:
		_orig.append({
			"base": Vector2(randf_range(-vp.x * 0.5, vp.x * 0.5), randf_range(-vp.y * 0.5, vp.y * 0.5)),
			"factor": r.nova.star_factor(randi() % 35, _orig_parallax),
			"frame": randi() % maxi(1, frames)})
	_orig_count = count


func draw(ci: CanvasItem, vp: Vector2, center: Vector2) -> void:
	ci.draw_set_transform_matrix(Transform2D.IDENTITY)   # screen space
	var cam: Vector2 = r.cam_base
	# The original's ambient stars are drawn by `draw_original_add` (an additive layer, see there); only
	# the plain dot field is drawn here.
	if not original_active():
		_draw_plain(ci, stars_far, cam, 0.35, COLOR_STAR_FAR, 1.0, vp)
		_draw_plain(ci, stars_near, cam, 0.7, COLOR_STAR_NEAR, 1.5, vp)
	ci.draw_set_transform_matrix(r.base_xf)


## Whether the original's spïn-700 starfield is what's drawn (Classic / Enhanced with game data).
func original_active() -> bool:
	return r.has_data and r.classic_world and r.sprites.entry(Sprites.STARFIELD, 0) != null


## The original's stars on the renderer's ADDITIVE layer: the system's BkgndColor is not black (nebula
## systems are tinted), and an opaque murk-darkened star sprite drawn normally came out DARKER than that
## background (dark specks). Added on top of the background a star can only lighten it, and with a black
## background (the original's) it is identical to the opaque blit.
func draw_original_add(ci: CanvasItem, vp: Vector2, center: Vector2) -> void:
	if not original_active():
		return
	ci.draw_set_transform_matrix(Transform2D.IDENTITY)   # screen space
	_draw_original(ci, vp, center, r.cam_base)
	ci.draw_set_transform_matrix(r.base_xf)


func _draw_original(ci: CanvasItem, vp: Vector2, center: Vector2, cam: Vector2) -> bool:
	var e = r.sprites.entry(Sprites.STARFIELD, 0)
	if e == null:
		return false
	var murk: int = r.nova.system_murk()
	if murk < 0:
		return true   # stars are hidden while murk < 0
	var count: int = r.nova.star_count(vp.y * r.zoom)
	if count != _orig_count or _orig_parallax != r.parallax_starfield:
		_rebuild_original(vp, count)
	var t := float(r.nova.star_tint(murk)) / 32.0
	var tint := Color(minf(1.0, t), minf(1.0, t), minf(1.0, t), 1.0)
	var span := Vector2(vp.x + 12.0, vp.y + 12.0)
	if r.cam.rotation != 0.0:
		span = Vector2.ONE * (vp.length() + 12.0)
	for st in _orig:
		var k: float = 1.0 + float(st["factor"])
		var b: Vector2 = st["base"]
		var p := Vector2(fposmod(b.x - cam.x * k + span.x * 0.5, span.x) - span.x * 0.5,
			fposmod(b.y + cam.y * k + span.y * 0.5, span.y) - span.y * 0.5)
		if r.cam.rotation != 0.0:
			p = p.rotated(r.cam.rotation)
		Sprites.draw(ci, e, center + p, int(st["frame"]), tint)
	return true


func _draw_plain(ci: CanvasItem, stars: PackedVector2Array, cam: Vector2, parallax: float,
		col: Color, radius: float, vp: Vector2) -> void:
	var offset := Vector2(fposmod(-cam.x * parallax, FIELD.x), fposmod(cam.y * parallax, FIELD.y))
	var rot: float = r.cam.rotation
	var center := vp * 0.5
	for s in stars:
		var p := Vector2(fposmod(s.x + offset.x, vp.x), fposmod(s.y + offset.y, vp.y))
		if rot != 0.0:
			p = center + (p - center).rotated(rot)
		# A 2-3 px dot: a quad batches with its neighbours; draw_circle tessellates a fan per star per frame.
		ci.draw_rect(Rect2(p.x - radius, p.y - radius, radius * 2.0, radius * 2.0), col)
