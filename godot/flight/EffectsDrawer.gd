# Transient combat effects -- the Apple app's "Effects pipeline" (GameScene: spawnExplosion,
# spawnHitSpray, spawnAreaBlast, spawnParticles, spawnFlash, spawnSmokePuff, spawnDisableFlash,
# beginNPCDeathSequence / beginPlayerDeathSequence), driven by the bridge's drainEffects rows.
#
# The bridge reports what happened and where (kinds below); the look is the Apple Classic path's:
#   * explosions: the bööm sprite animation, additive, scaled to max(radius*0.3, 5) px across, at
#     most 32 live (the original's pool), plus a spark accent and a short under-glow flash;
#   * Classic particles are the original's SWParticles: one opaque 1-px point, no drag or size change,
#     alpha 1 until the last 32 ticks of life; the Nova Swift look keeps soft additive embers;
#   * a dying hull is nine staggered bursts 0.2 s apart (+-22 px, radius 32 + 4i) then a final 96-px
#     blast, the same schedule as the bridge's DeathBurstSounds;
#   * smoke puffs are the original's cicn 1000/1008 sets (pool of 64);
#   * "Reduce flashing" removes particles, the spark accents and flashes (Apple: spawnParticles guard).
extends RefCounted

const Sprites = preload("res://flight/FlightSprites.gd")

# drainEffects kinds -- MUST match the bridge (NovaWorld.collectEvents).
const FX_EXPLOSION := 0
const FX_SHIELD_HIT := 1
const FX_ARMOR_HIT := 2
const FX_DEBRIS := 3
const FX_SHIP_DYING := 4
const FX_SHIP_DESTROYED := 5
const FX_MUZZLE := 6
const FX_DISABLED := 7
const FX_AREA_BLAST := 8

const EXPLOSION_POOL := 32          # OriginalRendering.explosionPoolSize
const SMOKE_POOL := 64              # OriginalRendering.smokePoolSize
const PARTICLE_CAP := 2500          # a GDScript-side cap (the original's pool is 100000)
const RAW_CALL_SECONDS := 0.021     # OriginalClock.rawCallSeconds
const BURSTS := 9
const BURST_INTERVAL := 0.2
const BURST_JITTER := 22.0

var r                       # FlightRenderer
var booms: Array = []       # {pos, id, age, dur, scale, rot}
var flashes: Array = []     # {pos, age, dur, d0, d1, color}
var particles: Array = []   # {pos, vel, age, life, size0, size1, alpha0, drag, color, add, classic}
var smokes: Array = []      # {pos, age, life, frames: Array of cicn ids base}
var rings: Array = []       # disable flashes {pos, age}
var deaths: Array = []      # {pos, boom, age, fired, final, player}
var delayed: Array = []     # area-blast puffs waiting to start {pos, boom, delay, diameter}
var _flash_tex: ImageTexture
var _clock := 0.0


func setup(renderer) -> void:
	r = renderer
	_flash_tex = _radial_texture(16)


func clear() -> void:
	booms.clear(); flashes.clear(); particles.clear(); smokes.clear()
	rings.clear(); deaths.clear(); delayed.clear()


static func _radial_texture(d: int) -> ImageTexture:
	var img := Image.create(d, d, false, Image.FORMAT_RGBA8)
	var c := (d - 1) * 0.5
	for y in d:
		for x in d:
			var dist := Vector2(x - c, y - c).length() / (d * 0.5)
			img.set_pixel(x, y, Color(1, 1, 1, clampf(1.0 - dist, 0.0, 1.0)))
	return ImageTexture.create_from_image(img)


# MARK: Advance + drain

func advance(dt: float) -> void:
	_clock += dt
	_age_all(dt)
	var rows: PackedFloat32Array = r.nova.drain_effects()
	var stride: int = r.nova.effect_stride()
	var i := 0
	while i + stride <= rows.size():
		_spawn_row(int(rows[i]), Vector2(rows[i + 1], rows[i + 2]), rows[i + 3], rows[i + 4],
			Color(rows[i + 5], rows[i + 6], rows[i + 7]))
		i += stride


func _age_all(dt: float) -> void:
	var keep: Array = []
	for b in booms:
		b["age"] += dt
		if int(b["age"] / b["dur"]) < b["frames"]:
			keep.append(b)
	booms = keep
	keep = []
	for f in flashes:
		f["age"] += dt
		if f["age"] < f["dur"]:
			keep.append(f)
	flashes = keep
	keep = []
	for p in particles:
		p["age"] += dt
		if p["age"] >= p["life"]:
			continue
		var v: Vector2 = p["vel"]
		if not p["classic"]:
			v *= maxf(0.0, 1.0 - p["drag"] * dt)
			p["vel"] = v
		p["pos"] = p["pos"] + v * dt
		keep.append(p)
	particles = keep
	keep = []
	for s in smokes:
		s["age"] += dt
		if s["age"] < s["life"]:
			keep.append(s)
	smokes = keep
	keep = []
	for g in rings:
		g["age"] += dt
		if g["age"] < 0.3:
			keep.append(g)
	rings = keep
	# Area-blast puffs start late.
	keep = []
	for d in delayed:
		d["delay"] -= dt
		if d["delay"] <= 0.0:
			_spawn_boom(d["pos"], d["boom"], d["diameter"])
		else:
			keep.append(d)
	delayed = keep
	# Death sequences: nine staggered bursts, then the big final blast.
	keep = []
	for s in deaths:
		s["age"] += dt
		while s["fired"] < BURSTS and s["age"] >= s["fired"] * BURST_INTERVAL:
			var i: int = s["fired"]
			var at: Vector2 = s["pos"] + Vector2(randf_range(-BURST_JITTER, BURST_JITTER),
				randf_range(-BURST_JITTER, BURST_JITTER))
			spawn_explosion(at, 32.0 + i * 4.0, s["boom"])
			r.shake(at, 60.0)
			s["fired"] = i + 1
		if not s["final"] and s["age"] >= BURSTS * BURST_INTERVAL:
			spawn_explosion(s["pos"], 96.0, s["boom"])
			r.shake(s["pos"], 110.0)
			s["final"] = true
		if not s["final"]:
			keep.append(s)
	deaths = keep


func _spawn_row(kind: int, pos: Vector2, p0: float, p1: float, col: Color) -> void:
	match kind:
		FX_EXPLOSION:
			spawn_explosion(pos, maxf(p0, 0.0), int(p1))
			r.shake(pos, p0)
		FX_SHIELD_HIT:
			spawn_hit_spray(pos, int(p0), true)
		FX_ARMOR_HIT:
			spawn_hit_spray(pos, int(p0), false)
		FX_DEBRIS:
			spawn_particles(pos, mini(int(p0), 20), col, 70.0, 0.7, 4.0, false, false, 2.0)
		FX_SHIP_DYING:
			deaths.append({"pos": pos, "boom": int(p0), "age": 0.0, "fired": 0, "final": false, "player": p1 > 0.5})
		FX_DISABLED:
			rings.append({"pos": pos, "age": 0.0})
		FX_AREA_BLAST:
			spawn_area_blast(pos, int(p0))
		_:
			pass   # kinds 5 (destroyed) and 6 (muzzle): the Apple app draws nothing for them


# MARK: Spawners (Apple names)

## GameScene.spawnExplosion: the bööm sprite when it resolves, always a spark accent and under-glow.
func spawn_explosion(at: Vector2, radius: float, boom_id: int) -> void:
	var played := false
	if boom_id >= 0:
		played = _spawn_boom(at, boom_id, maxf(radius * 0.3, 5.0))
	spawn_particles(at, 10 if played else 6, Color(1.0, 0.85, 0.5), maxf(60.0, radius * 6.0), 0.5,
		maxf(3.0, radius * 0.18), true, false, 1.5)
	var glow := maxf(10.0, radius * 0.6)
	if played:
		spawn_flash(at, glow * 0.7, glow * 1.4, Color(1.0, 0.8, 0.45), 0.18)
	else:
		spawn_flash(at, glow, glow * 2.2, Color(1.0, 0.75, 0.35), 0.35)


func _spawn_boom(at: Vector2, boom_id: int, diameter: float) -> bool:
	var sheet = r.sprites.entry(Sprites.BOOM, boom_id)
	if sheet == null or booms.size() >= EXPLOSION_POOL:
		return sheet != null
	var rate: int = sheet["rate"]
	var dur := 100.0 / (30.0 * float(rate)) if rate > 0 else 1.0 / 30.0
	var base := float(maxi(sheet["fw"], sheet["fh"]))
	booms.append({"pos": at, "id": boom_id, "age": 0.0, "dur": maxf(0.01, dur), "frames": sheet["frames"],
		"scale": maxf(0.2, diameter / maxf(base, 1.0)), "rot": fmod(_clock, TAU)})
	return true


## GameScene.spawnHitSpray: the weapon's own hit particles, else a generic spray.
func spawn_hit_spray(at: Vector2, weapon_id: int, on_shield: bool) -> void:
	var spec: PackedFloat32Array = r.weapon_visual(weapon_id)
	if spec.size() >= 13 and spec[7] > 0.0:
		var col := Color(spec[10], spec[11], spec[12])
		spawn_particles(at, int(spec[7]), col, spec[8] * 0.01 / RAW_CALL_SECONDS,
			spec[9] * 1.125 * RAW_CALL_SECONDS, 1.0, true, false, 1.5)
		return
	var c := Color(0.5, 0.75, 1.0) if on_shield else Color(1.0, 0.7, 0.35)
	spawn_particles(at, 5 if on_shield else 7, c, 90.0, 0.3, 3.0, true, false, 1.5)


## Shot_SpawnAreaImpactEffects (0x004211d0): scattered small booms starting a few ticks late.
func spawn_area_blast(at: Vector2, b: int) -> void:
	var bd := float(b)
	for n in int(bd * 0.04):
		_queue_puff(at, 129, int(bd * 0.5), bd * 0.25, 8, 4, bd)
	for n in int(bd * 0.16):
		_queue_puff(at, 128, b, bd * 0.5, 16, 8, bd)


func _queue_puff(at: Vector2, boom: int, spread: int, shift: float, delay_range: int, delay_base: int, bd: float) -> void:
	var dx := float(randi() % maxi(1, spread)) - shift
	var dy := float(randi() % maxi(1, spread)) - shift
	var delay := float(randi() % maxi(1, delay_range) + delay_base) / 30.0
	delayed.append({"pos": at + Vector2(dx, dy), "boom": boom, "delay": delay, "diameter": maxf(bd * 0.3, 5.0)})


func spawn_flash(at: Vector2, start_r: float, end_r: float, color: Color, duration: float) -> void:
	if r.reduce_flashing:
		return
	flashes.append({"pos": at, "age": 0.0, "dur": duration, "d0": start_r * 2.0, "d1": end_r * 2.0, "color": color})


## GameScene.spawnParticles. Classic = the original's 1-px SWParticle; otherwise sized embers.
func spawn_particles(at: Vector2, count: int, color: Color, speed: float, life: float, size: float,
		additive: bool, grow: bool, drag: float = 1.5) -> void:
	if count <= 0 or r.reduce_flashing:
		return
	var classic: bool = r.classic_particles
	var n := mini(count, PARTICLE_CAP - particles.size())
	for k in maxi(n, 0):
		var dir := randf() * TAU
		var spd := speed if classic else speed * randf_range(0.4, 1.0)
		var s0 := 1.0 if classic else size * randf_range(0.7, 1.2)
		particles.append({
			"pos": at, "vel": Vector2(cos(dir), sin(dir)) * spd, "age": 0.0,
			"life": life if classic else life * randf_range(0.6, 1.0),
			"size0": s0, "size1": s0 if classic else (s0 * 2.4 if grow else s0 * 0.4),
			"alpha0": 1.0 if classic else (1.0 if additive else 0.85),
			"drag": 0.0 if classic else drag, "color": color,
			"add": additive and not classic, "classic": classic})


## GameScene.spawnSmokePuff: the original's cicn smoke (set from the weapon's SmokeSet, else 1000 small /
## 1008 big). False when the art is missing (the caller falls back to particles).
func spawn_smoke(at: Vector2, weapon_id: int, big: bool) -> bool:
	if smokes.size() >= SMOKE_POOL:
		return true
	var spec: PackedFloat32Array = r.weapon_visual(weapon_id)
	var set_n: int = int(spec[15]) if spec.size() > 15 else -1
	var base := 1000 + 8 * set_n if set_n >= 0 else (1008 if big else 1000)
	if r.sprites.entry(Sprites.CICN, base) == null or r.sprites.entry(Sprites.CICN, base + 7) == null:
		return false
	smokes.append({"pos": at, "age": 0.0, "life": 0.9 if big else 0.55, "base": base})
	return true


# MARK: Draw

## Additive layer: boom sprites, flashes, ember particles, disable rings.
func draw_add(ci: CanvasItem) -> void:
	var base: Transform2D = r.base_xf
	for b in booms:
		var e = r.sprites.entry(Sprites.BOOM, b["id"])
		if e == null:
			continue
		var idx := mini(int(b["age"] / b["dur"]), e["frames"] - 1)
		var sz := Vector2(e["fw"], e["fh"]) * b["scale"]
		ci.draw_set_transform_matrix(base * Transform2D(b["rot"], r.w2l(b["pos"])))
		ci.draw_texture_rect_region(e["tex"], Rect2(-sz * 0.5, sz), Sprites.src(e, idx), Color.WHITE)
	ci.draw_set_transform_matrix(base)
	for f in flashes:
		var t := clampf(f["age"] / f["dur"], 0.0, 1.0)
		var d := lerpf(f["d0"], f["d1"], t)
		var c: Color = f["color"]
		c.a = 1.0 - t
		ci.draw_texture_rect(_flash_tex, Rect2(r.w2l(f["pos"]) - Vector2(d, d) * 0.5, Vector2(d, d)), false, c)
	for p in particles:
		if not p["add"]:
			continue
		var t2: float = p["age"] / p["life"]
		var c2: Color = p["color"]
		c2.a = p["alpha0"] * (1.0 - t2)
		ci.draw_circle(r.w2l(p["pos"]), maxf(lerpf(p["size0"], p["size1"], t2) * 0.5, 0.5), c2)
	for g in rings:
		var t3: float = g["age"] / 0.3
		ci.draw_arc(r.w2l(g["pos"]), 14.0 * (1.0 + t3), 0.0, TAU, 24, Color(0.6, 0.8, 1.0, 0.9 * (1.0 - t3)), 2.0, true)


## Normal layer: the original's 1-px particles, non-additive embers, smoke puffs.
func draw_normal(ci: CanvasItem) -> void:
	for s in smokes:
		var idx := mini(7, int(s["age"] / s["life"] * 8.0))
		var e = r.sprites.entry(Sprites.CICN, s["base"] + idx)
		if e != null:
			Sprites.draw(ci, e, r.w2l(s["pos"]), 0)
	for p in particles:
		if p["add"]:
			continue
		var c: Color = p["color"]
		if p["classic"]:
			var ticks_left := ceili((p["life"] - p["age"]) * 30.0)
			c.a = 0.0 if ticks_left <= 1 else (1.0 if ticks_left > 32 else float(ticks_left) / 32.0)
			if c.a > 0.0:
				ci.draw_rect(Rect2(r.w2l(p["pos"]).floor(), Vector2.ONE), c)
		else:
			var t: float = p["age"] / p["life"]
			c.a = p["alpha0"] * (1.0 - t)
			ci.draw_circle(r.w2l(p["pos"]), maxf(lerpf(p["size0"], p["size1"], t) * 0.5, 0.5), c)
