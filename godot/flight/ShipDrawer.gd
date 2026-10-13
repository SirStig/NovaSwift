# Ships -- GameScene.buildShip / makeNPCNode / syncNPCs / updateThruster / updateSelectionBrackets.
#
# Every hull is its shän layers, with the frame math and intensities the bridge computes per ship per display
# frame (NovaWorld.ship_layers; HullAnimConfig is the Apple HullAnim port):
#
#   base hull    set*framesPerSet + heading frame (set = bank direction / animation clock / key-carried),
#                wrapped by the sheet's frame count; multiplied by the përs / paint tint, shän BaseTransp and
#                the cloak fade; mixed toward the murk / ionize / gate-wash colour (fog layer);
#   alt layer    normal blend over the hull, its own set cycling on the animation clock;
#   engine glow  additive, while thrusting (low-pass flicker 0.6-0.85, 0.85-1.0 on the afterburner);
#   lights       additive, shän blink mode 1/2/3 intensity, hidden on a disabled hull when the shän says so;
#   weapon glow  additive, set to 1 on firing a ship-sprite weapon and decaying at WeapDecay;
#   shield       additive bubble (plug-in art), flared by a shield hit and decaying over 0.45 s.
# Draw bands (z): disabled hulks, then ships, then escorts, then the player.
extends RefCounted

const Sprites = preload("res://flight/FlightSprites.gd")
const StellarDrawer = preload("res://flight/StellarDrawer.gd")

const SHIP_SIZE := 14.0
const COLOR_PLAYER := Color(0.55, 0.85, 1.0)
const COLOR_NPC := Color(0.95, 0.75, 0.35)
const COLOR_DISABLED := Color(0.5, 0.5, 0.55)
const STRIDE := 26
# column indices in a ship_layers row
const C_SET := 0
const C_HEADING := 1
const C_FPS := 2
const C_ALT := 3
const C_LIGHT := 4
const C_WGLOW := 5
const C_SHIELD := 6
const C_ENGINE := 7
const C_DISABLED := 8
const C_BANK := 9
const C_OPACITY := 10
const C_TINT := 11          # 11..13
const C_FOG := 14
const C_BLEND := 15         # factor; 16..18 rgb
const C_GATE_HIDDEN := 19
const C_GATE_WHITE := 20
const C_THRUST := 22
const FACTION_COLORS := [
	Color(0.95, 0.3, 0.25), Color(0.95, 0.85, 0.25), Color(0.4, 0.9, 0.4), Color(0.55, 0.55, 0.55), COLOR_PLAYER]

var r                       # FlightRenderer
var order: PackedInt32Array = PackedInt32Array()
var reticle_zoom := 0.0
var _locked_id := -1
var launches := {}          # entity id -> age: a ship lifting off a planet grows in (0.08 -> 1 over 0.5 s, fades in 0.4 s)
var ghosts: Array = []      # landing ships shrinking into their stellar {type, frame, from, to, age}
const LAUNCH_GROW := 0.5
const LAUNCH_FADE := 0.4
const LAND_TIME := 0.5


func advance(dt: float) -> void:
	for k in launches.keys():
		launches[k] += dt
		if launches[k] >= LAUNCH_GROW:
			launches.erase(k)
	var keep: Array = []
	for g in ghosts:
		g["age"] += dt
		if g["age"] < LAND_TIME:
			keep.append(g)
	ghosts = keep


## (scale, alpha) of a launching ship's whole container (GameScene.applyEntrance(.launch)).
func _launch(n: int) -> Vector2:
	var id: int = r.ship_ids[n] if n < r.ship_ids.size() else -1
	if not launches.has(id):
		return Vector2.ONE
	var t: float = launches[id]
	return Vector2(lerpf(0.08, 1.0, minf(1.0, t / LAUNCH_GROW)), minf(1.0, t / LAUNCH_FADE))


## Draw `frame` of `e` at `pos`; when `scale` != 1 it scales about its centre (a launching ship).
func _put(ci: CanvasItem, e: Dictionary, pos: Vector2, frame: int, tint: Color, scale: float) -> void:
	if scale >= 0.999:
		Sprites.draw(ci, e, pos, frame, tint)
	else:
		ci.draw_set_transform_matrix(r.base_xf * Transform2D(0.0, Vector2(scale, scale), 0.0, pos))
		Sprites.draw(ci, e, Vector2.ZERO, frame, tint)
		ci.draw_set_transform_matrix(r.base_xf)


func setup(renderer) -> void:
	r = renderer


## Draw order by Apple's z bands: disabled hulks (6.5), ships (9), escorts (8.5 -> before ships), player (9.5).
func build_order() -> void:
	var disabled: Array = []
	var escorts: Array = []
	var ships: Array = []
	var n: int = r.ship_xf.size() / 4
	for k in range(1, n):
		var kind := int(r.ship_xf[k * 4 + 3])
		var rel: int = r.ship_rel[k] if k < r.ship_rel.size() else 1
		if kind == 2:
			disabled.append(k)
		elif rel == 2:
			escorts.append(k)
		else:
			ships.append(k)
	var out := PackedInt32Array()
	for k in disabled + escorts + ships:
		out.append(k)
	if n > 0:
		out.append(0)
	order = out


func _row(n: int) -> int:
	return n * STRIDE if (n + 1) * STRIDE <= r.ship_layers.size() else -1


func _alpha_of(n: int, kind: int) -> float:
	var v := n * 3
	var cloak: float = r.ship_vis[v] if v + 2 < r.ship_vis.size() else 0.0
	return 1.0 - cloak * (0.92 if kind != 0 else 0.75)


# MARK: Hulls (normal layer): synthetic plume, base hull, alt overlay

func draw_hulls(ci: CanvasItem) -> void:
	for n in order:
		var xf := n * 4
		var pos: Vector2 = r.w2l(Vector2(r.ship_xf[xf], r.ship_xf[xf + 1]))
		var angle: float = r.ship_xf[xf + 2]
		var kind := int(r.ship_xf[xf + 3])
		var ship_type: int = r.ship_sf[n * 2] if n * 2 + 1 < r.ship_sf.size() else -1
		var engine_frame: int = r.ship_sf[n * 2 + 1] if n * 2 + 1 < r.ship_sf.size() else 0
		var row := _row(n)
		var L: PackedFloat32Array = r.ship_layers
		if row >= 0 and L[row + C_GATE_HIDDEN] > 0.5:
			continue
		var lf := _launch(n)
		var alpha := _alpha_of(n, kind) * lf.y
		var entry = r.sprites.entry(Sprites.SHIP, ship_type) if ship_type >= 0 else null
		var thrusting: bool = (r.ship_vis[n * 3 + 2] if n * 3 + 2 < r.ship_vis.size() else 0.0) > 0.5
		if entry == null:
			if thrusting:
				_draw_thruster_flame(ci, pos, angle, alpha, SHIP_SIZE)
			_draw_primitive(ci, pos, angle, kind, alpha)
			continue
		var frame := engine_frame
		var hull_alpha := alpha
		var tint := Color(1, 1, 1, alpha)
		if row >= 0:
			frame = Sprites.wrap(int(L[row + C_SET]) * int(L[row + C_FPS]) + int(L[row + C_HEADING]), entry["frames"])
			hull_alpha = alpha * L[row + C_OPACITY]
			tint = Color(L[row + C_TINT], L[row + C_TINT + 1], L[row + C_TINT + 2], hull_alpha)
		# Nova Swift only: a hull with no authored exhaust art gets the synthetic plume.
		if thrusting and not r.classic_world and r.engine_glow \
				and r.sprites.entry(Sprites.ENGINE_GLOW, ship_type) == null:
			_draw_thruster_flame(ci, pos, angle, alpha, entry["fw"] * 0.5)
		_put(ci, entry, pos, frame, tint, lf.x)
		if row >= 0:
			var alt = r.sprites.entry(Sprites.ALT, ship_type)
			if alt != null:
				var af := Sprites.wrap(int(L[row + C_ALT]) * int(L[row + C_FPS]) + int(L[row + C_HEADING]), alt["frames"])
				_put(ci, alt, pos, af, Color(1, 1, 1, alpha), lf.x)
			# One blend slot: murk, overwritten by ionization when stronger, or the gate wash.
			var f: float = L[row + C_BLEND]
			if f > 0.0 and lf.x >= 0.999:
				r.fog_ships.append([entry, pos, frame,
					Color(L[row + C_BLEND + 1], L[row + C_BLEND + 2], L[row + C_BLEND + 3], 1.0), f * hull_alpha])


## Landing ships (GameScene.landNode): move into the stellar, shrink to 0.05 and fade over 0.5 s.
func draw_ghosts(ci: CanvasItem) -> void:
	for g in ghosts:
		var e = r.sprites.entry(Sprites.SHIP, g["type"])
		if e == null:
			continue
		var t: float = g["age"] / LAND_TIME
		var pos: Vector2 = r.w2l((g["from"] as Vector2).lerp(g["to"], t))
		var sc := lerpf(1.0, 0.05, t)
		ci.draw_set_transform_matrix(r.base_xf * Transform2D(0.0, Vector2(sc, sc), 0.0, pos))
		Sprites.draw(ci, e, Vector2.ZERO, g["frame"], Color(1, 1, 1, 1.0 - t))
		ci.draw_set_transform_matrix(r.base_xf)


# MARK: Overlays (additive layer): engine glow, running lights, weapon glow, shield

func draw_glows(ci: CanvasItem) -> void:
	var L: PackedFloat32Array = r.ship_layers
	for n in order:
		var row := _row(n)
		if row < 0 or L[row + C_GATE_HIDDEN] > 0.5:
			continue
		var xf := n * 4
		var kind := int(r.ship_xf[xf + 3])
		var ship_type: int = r.ship_sf[n * 2] if n * 2 + 1 < r.ship_sf.size() else -1
		if ship_type < 0:
			continue
		var pos: Vector2 = r.w2l(Vector2(r.ship_xf[xf], r.ship_xf[xf + 1]))
		var lf := _launch(n)
		var alpha := _alpha_of(n, kind) * lf.y
		var base := int(L[row + C_SET]) * int(L[row + C_FPS]) + int(L[row + C_HEADING])
		var heading := int(L[row + C_HEADING])
		var a: float = L[row + C_ENGINE]
		if a > 0.0 and r.engine_glow:
			var e = r.sprites.entry(Sprites.ENGINE_GLOW, ship_type)
			if e != null:
				_put(ci, e, pos, Sprites.wrap(base, e["frames"]), Color(1, 1, 1, a * alpha), lf.x)
		a = L[row + C_LIGHT]
		if a > 0.0 and r.running_lights:
			var e2 = r.sprites.entry(Sprites.LIGHTS, ship_type)
			if e2 != null:
				_put(ci, e2, pos, Sprites.wrap(base, e2["frames"]), Color(1, 1, 1, a * alpha), lf.x)
		a = L[row + C_WGLOW]
		if a > 0.0 and r.weapon_effects:
			var e3 = r.sprites.entry(Sprites.WEAPON_GLOW, ship_type)
			if e3 != null:
				_put(ci, e3, pos, Sprites.wrap(base, e3["frames"]), Color(1, 1, 1, a * alpha), lf.x)
		a = L[row + C_SHIELD]
		if a > 0.0:
			var e4 = r.sprites.entry(Sprites.SHIELD, ship_type)
			if e4 != null:
				# The bubble has one frame per heading; keep it turned with the hull.
				var sf := Sprites.wrap(heading, e4["frames"]) if e4["frames"] > 1 else 0
				_put(ci, e4, pos, sf, Color(1, 1, 1, a * alpha), lf.x)


# MARK: Target reticle / brackets (fx layer)

func draw_target(ci: CanvasItem, dt: float) -> void:
	var t: PackedFloat32Array = r.target_reticle
	if t.size() < 4:
		_locked_id = -1
		return
	var tid: int = r.target_id
	var is_new := _locked_id != tid
	_locked_id = tid
	var pos: Vector2 = r.w2l(Vector2(t[0], t[1]))
	var radius: float = t[2]
	var ship_type := -1
	var idx: int = r.ship_ids.find(tid)
	if idx >= 0 and idx * 2 + 1 < r.ship_sf.size():
		ship_type = r.ship_sf[idx * 2]
	var e = r.sprites.entry(Sprites.SHIP, ship_type) if ship_type >= 0 else null
	if e != null:
		radius = maxf(e["fw"], e["fh"]) * 0.5
	var cls := int(t[3])
	var first = r.sprites.entry(Sprites.CICN, 10008)
	if r.classic_world and first != null:
		# The original's reticle (0x0042ede0): four corner cicns from 10008 + 4*class, flying in from 256 px.
		if is_new:
			reticle_zoom = 256.0
		else:
			reticle_zoom = maxf(0.0, reticle_zoom - 1800.0 * dt)
		var off := ceilf(radius) + reticle_zoom + 16.0
		var corners := [Vector2(-off, -off), Vector2(off, -off), Vector2(off, off), Vector2(-off, off)]
		for k in 4:
			var ce = r.sprites.entry(Sprites.CICN, 10008 + cls * 4 + k)
			if ce != null:
				Sprites.draw(ci, ce, pos + corners[k], 0)
		return
	# Nova Swift: faction-coloured corner brackets with a lock-on pulse.
	var col: Color = FACTION_COLORS[cls] if cls < FACTION_COLORS.size() else FACTION_COLORS[1]
	var pulse := 1.0 + 0.08 * (0.5 - 0.5 * cos(r.clock * TAU / 1.1))
	StellarDrawer.draw_bracket(ci, pos, (radius * 2.0 + 14.0) * pulse, col)


# MARK: Primitives (demo world / spriteless hulls)

func _draw_primitive(ci: CanvasItem, pos: Vector2, angle: float, kind: int, alpha: float) -> void:
	var dir := Vector2(sin(angle), -cos(angle))
	var side := Vector2(dir.y, -dir.x)
	var nose := pos + dir * SHIP_SIZE
	var tail_l := pos - dir * (SHIP_SIZE * 0.7) + side * (SHIP_SIZE * 0.62)
	var tail_r := pos - dir * (SHIP_SIZE * 0.7) - side * (SHIP_SIZE * 0.62)
	var col := COLOR_NPC
	if kind == 0:
		col = COLOR_PLAYER
	elif kind == 2:
		col = COLOR_DISABLED
	col.a = alpha
	ci.draw_colored_polygon(PackedVector2Array([nose, tail_l, tail_r]), col)


## Synthetic exhaust for hulls with no engine-glow art in Nova Swift mode, and for the demo ship.
func _draw_thruster_flame(ci: CanvasItem, pos: Vector2, angle: float, alpha: float, radius: float) -> void:
	var rr := maxf(radius, 4.0)
	var dir := Vector2(sin(angle), -cos(angle))
	var side := Vector2(dir.y, -dir.x)
	var tail := pos - dir * (rr * 0.65)
	var flicker := randf_range(0.75, 1.15)
	var tip := tail - dir * (rr * flicker)
	ci.draw_colored_polygon(PackedVector2Array([tail + side * (rr * 0.30), tail - side * (rr * 0.30), tip]),
		Color(1.0, 0.55, 0.18, 0.85 * alpha))
	ci.draw_colored_polygon(PackedVector2Array([tail + side * (rr * 0.14), tail - side * (rr * 0.14),
		tail - dir * (rr * 0.55 * flicker)]), Color(1.0, 0.95, 0.8, 0.9 * alpha))
