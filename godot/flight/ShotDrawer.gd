# Shots and beams -- GameScene.syncProjectiles / syncBeams / lightningPath / beamCoronaTexture.
#
#   * a shot with spïn art draws it untinted (translucent 0.45 for wëap Flags3 0x0002); a many-frame
#     sheet that does not spin is a rotation sheet indexed by the engine's heading frame, a spinning
#     shot animates on the engine's animFrame, a single frame points along travel;
#   * a shot with no art is the generic 9-px additive bolt;
#   * a weapon with smoke flags or a Trail leaves a puff at the shot's tail every frame: the original's
#     cicn smoke in Classic, soft embers in Nova Swift (and the Smoke Trails preference gates smoke);
#   * beams have no sprite art in stock data: the authored beamColor core fading to coronaColor IS their
#     look, baked once per colour pair into a 5-stop gradient bar and stretched muzzle to impact, additive;
#     a weapon with its own beam art stretches that instead; LiDensity > 0 draws a jagged lightning bolt,
#     re-seeded every frame.
extends RefCounted

const Sprites = preload("res://flight/FlightSprites.gd")

var r                       # FlightRenderer
var _corona_cache := {}
var _bolt_tex: ImageTexture


func setup(renderer) -> void:
	r = renderer
	_bolt_tex = _radial(16)


static func _radial(d: int) -> ImageTexture:
	var img := Image.create(d, d, false, Image.FORMAT_RGBA8)
	var c := (d - 1) * 0.5
	for y in d:
		for x in d:
			img.set_pixel(x, y, Color(1, 1, 1, clampf(1.0 - Vector2(x - c, y - c).length() / (d * 0.5), 0.0, 1.0)))
	return ImageTexture.create_from_image(img)


# MARK: Projectiles

## Per-frame: leave trails behind shots. Called from FlightRenderer.update (not from _draw).
func spawn_trails() -> void:
	var xf: PackedFloat32Array = r.shot_xf
	var ex: PackedFloat32Array = r.shot_extra
	var n := 0
	var i := 0
	while i + 2 < xf.size():
		var wid: int = int(ex[n * 3]) if n * 3 + 2 < ex.size() else -1
		if wid >= 128:
			var spec: PackedFloat32Array = r.weapon_visual(wid)
			if spec.size() >= 7:
				var smoke: bool = spec[1] > 0.5
				var trail: bool = spec[3] > 0.5
				if (smoke or trail) and (r.smoke_trails or not smoke):
					var facing := xf[i + 2]
					var tail := Vector2(xf[i], xf[i + 1]) - Vector2(sin(facing), cos(facing)) * 4.0
					var big: bool = spec[2] > 0.5
					if smoke and r.classic_particles and r.fx.spawn_smoke(tail, wid, big):
						pass
					elif smoke:
						r.fx.spawn_particles(tail, 1, Color(0.7, 0.7, 0.7), 12.0 if big else 8.0, 0.9 if big else 0.55,
							10.0 if big else 6.0, false, true, 2.5)
					else:
						r.fx.spawn_particles(tail, 1, Color(spec[4], spec[5], spec[6]), 10.0, 0.4, 4.0, true, false, 2.5)
		i += 3
		n += 1


func draw_projectiles(ci: CanvasItem) -> void:
	var base: Transform2D = r.base_xf
	var xf: PackedFloat32Array = r.shot_xf
	var style: PackedInt32Array = r.shot_style
	var ex: PackedFloat32Array = r.shot_extra
	var i := 0
	var n := 0
	while i + 2 < xf.size():
		var pos: Vector2 = r.w2l(Vector2(xf[i], xf[i + 1]))
		var facing: float = xf[i + 2]
		var s := n * 3
		var spin_id: int = style[s] if s + 2 < style.size() else -1
		var spins: bool = (style[s + 1] if s + 2 < style.size() else 0) != 0
		var translucent: bool = (style[s + 2] if s + 2 < style.size() else 0) != 0
		var tint := Color(1, 1, 1, 0.45 if translucent else 1.0)
		var entry = r.sprites.entry(Sprites.WEAPON, spin_id) if spin_id >= 0 else null
		if entry == null:
			# Generic bolt is drawn in the additive pass (see draw_bolts).
			pass
		else:
			var frames: int = entry["frames"]
			if frames >= 16 and not spins:
				var deg: float = ex[n * 3 + 2] if n * 3 + 2 < ex.size() else rad_to_deg(facing)
				var f := mini(maxi(int(floorf(fposmod(deg, 360.0) * frames / 360.0 + 1e-9)), 0), frames - 1)
				Sprites.draw(ci, entry, pos, f, tint)
				_fog(entry, pos, f, NAN, n, tint.a)
			else:
				var af: int = int(ex[n * 3 + 1]) if n * 3 + 1 < ex.size() else 0
				var frame := (af % maxi(frames, 1)) if spins else 0
				Sprites.draw_rotated(ci, base, entry, pos, frame, facing, tint)
				_fog(entry, pos, frame, facing, n, tint.a)
		i += 3
		n += 1


## Murk (GameScene.applyMurk on shots): a shot with its own art mixes toward the system backdrop colour by
## its distance from the player (`MurkFog.level / 32`); the generic additive bolt is left alone.
func _fog(entry: Dictionary, pos: Vector2, frame: int, angle: float, n: int, alpha: float) -> void:
	if n >= r.shot_fog.size():
		return
	var level: float = r.shot_fog[n]
	if level > 0.0:
		r.fog_shots.append([entry, pos, frame, Color(r.background.r, r.background.g, r.background.b, 1.0),
			level / 32.0 * alpha, angle])


## Shots with no authored art: the generic additive bolt.
func draw_bolts(ci: CanvasItem) -> void:
	var xf: PackedFloat32Array = r.shot_xf
	var style: PackedInt32Array = r.shot_style
	var i := 0
	var n := 0
	while i + 2 < xf.size():
		var s := n * 3
		var spin_id: int = style[s] if s + 2 < style.size() else -1
		if spin_id < 0 or r.sprites.entry(Sprites.WEAPON, spin_id) == null:
			var translucent: bool = (style[s + 2] if s + 2 < style.size() else 0) != 0
			var c := Color(1.0, 0.85, 0.4, 0.45 if translucent else 1.0)
			ci.draw_texture_rect(_bolt_tex, Rect2(r.w2l(Vector2(xf[i], xf[i + 1])) - Vector2(4.5, 4.5), Vector2(9, 9)), false, c)
		i += 3
		n += 1


# MARK: Beams

func _envelope(core_w: float, falloff: float, coreless: bool) -> Vector2:
	var cw := maxf(1.0, core_w)
	var f := clampf(falloff, 2.0, 16.0)
	var glow_half := cw * (0.25 + 2.0 / f)
	var height := cw + glow_half * 2.0
	var core_fraction := 0.12 if coreless else cw / height
	return Vector2(height, maxf(0.03, 0.5 - core_fraction / 2.0))   # (height, coreStart)


func _corona_texture(core: Color, corona: Color, core_start: float, coreless: bool) -> ImageTexture:
	var key := "%s|%s|%.3f|%s" % [core.to_html(false), corona.to_html(false), core_start, coreless]
	if _corona_cache.has(key):
		return _corona_cache[key]
	var h := 32
	var img := Image.create(4, h, false, Image.FORMAT_RGBA8)
	# Stops: transparent corona -> soft corona glow (half alpha, the Bible's "approximately half as bright")
	# -> core -> glow -> transparent.
	var clear := Color(corona.r, corona.g, corona.b, 0.0)
	var glow := Color(corona.r, corona.g, corona.b, 0.5)
	var mid := Color(corona.r, corona.g, corona.b, 0.5) if coreless else Color(core.r, core.g, core.b, 1.0)
	var stops := [[0.0, clear], [core_start, glow], [0.5, mid], [1.0 - core_start, glow], [1.0, clear]]
	for y in h:
		var t := (float(y) + 0.5) / float(h)
		var col: Color = stops[4][1]
		for k in 4:
			var a: Array = stops[k]
			var b: Array = stops[k + 1]
			if t >= a[0] and t <= b[0]:
				var span: float = maxf(b[0] - a[0], 1e-6)
				col = (a[1] as Color).lerp(b[1], (t - a[0]) / span)
				break
		for x in 4:
			img.set_pixel(x, y, col)
	var tex := ImageTexture.create_from_image(img)
	_corona_cache[key] = tex
	return tex


## Beams with their own art (normal blend) and lightning (additive); everything else is a corona bar.
func draw_beams_normal(ci: CanvasItem) -> void:
	var b: PackedFloat32Array = r.beams
	var i := 0
	var n := 0
	while i + 12 < b.size():
		var wid: int = r.beam_weapons[n] if n < r.beam_weapons.size() else -1
		var spec: PackedFloat32Array = r.weapon_visual(wid)
		var spin: int = int(spec[16]) if spec.size() > 16 else -1
		var art = r.sprites.entry(Sprites.WEAPON, spin) if spin >= 0 and not _is_lightning(spec) else null
		if art != null:
			var a: Vector2 = r.w2l(Vector2(b[i], b[i + 1]))
			var z: Vector2 = r.w2l(Vector2(b[i + 2], b[i + 3]))
			var len := maxf(1.0, a.distance_to(z))
			var width := maxf(2.0, b[i + 4] if b[i + 4] > 0.0 else 8.0)
			var idx: int = (int(r.clock * 15.0) % int(art["frames"])) if art["frames"] > 1 else 0
			ci.draw_set_transform_matrix(r.base_xf * Transform2D((z - a).angle(), a))
			ci.draw_texture_rect_region(art["tex"], Rect2(Vector2(0, -width * 0.5), Vector2(len, width)),
				Sprites.src(art, idx), Color(1, 1, 1, b[i + 5]))
			ci.draw_set_transform_matrix(r.base_xf)
		i += 13
		n += 1


static func _is_lightning(spec: PackedFloat32Array) -> bool:
	return spec.size() > 13 and spec[13] > 0.0


func draw_beams_add(ci: CanvasItem) -> void:
	var b: PackedFloat32Array = r.beams
	var i := 0
	var n := 0
	while i + 12 < b.size():
		var wid: int = r.beam_weapons[n] if n < r.beam_weapons.size() else -1
		var spec: PackedFloat32Array = r.weapon_visual(wid)
		var spin: int = int(spec[16]) if spec.size() > 16 else -1
		var lightning := _is_lightning(spec)
		var has_art: bool = spin >= 0 and not lightning and r.sprites.entry(Sprites.WEAPON, spin) != null
		if not has_art:
			var a: Vector2 = r.w2l(Vector2(b[i], b[i + 1]))
			var z: Vector2 = r.w2l(Vector2(b[i + 2], b[i + 3]))
			var len := maxf(1.0, a.distance_to(z))
			var coreless: bool = b[i + 4] <= 0.0
			var width := 8.0 if coreless else b[i + 4]
			var alpha: float = b[i + 5]
			var core := Color(b[i + 6], b[i + 7], b[i + 8])
			var corona := Color(b[i + 9], b[i + 10], b[i + 11])
			if lightning:
				_draw_lightning(ci, a, z, len, int(spec[13]), maxf(1.0, spec[14]), core, width, alpha)
			else:
				var env := _envelope(width, b[i + 12], coreless)
				var tex := _corona_texture(core, corona, env.y, coreless)
				ci.draw_set_transform_matrix(r.base_xf * Transform2D((z - a).angle(), a))
				ci.draw_texture_rect(tex, Rect2(Vector2(0, -env.x * 0.5), Vector2(len, env.x)), false, Color(1, 1, 1, alpha))
				ci.draw_set_transform_matrix(r.base_xf)
		i += 13
		n += 1


## GameScene.lightningPath: `density` zig-zags per 100 px, each kicked up to `amplitude` px perpendicular.
func _draw_lightning(ci: CanvasItem, a: Vector2, z: Vector2, length: float, density: int, amplitude: float,
		color: Color, width: float, alpha: float) -> void:
	var segments := maxi(2, int(length / 100.0 * density))
	var u := (z - a) / length
	var perp := Vector2(-u.y, u.x)
	var pts := PackedVector2Array([a])
	for s in range(1, segments):
		var t := float(s) / float(segments)
		pts.append(a.lerp(z, t) + perp * randf_range(-amplitude, amplitude))
	pts.append(z)
	var w := maxf(1.0, width)
	ci.draw_polyline(pts, Color(color.r, color.g, color.b, alpha * 0.35), w * 3.0, true)
	ci.draw_polyline(pts, Color(color.r, color.g, color.b, alpha), w, true)
