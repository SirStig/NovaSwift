# Stellar bodies, rocks and floating cargo -- GameScene.buildPlanets / updateAnimatedStellars /
# syncAsteroids / makeFreeflightNode, plus the selection marks (updateSelectionBrackets /
# updateNavCursor).
#
#   * a stellar draws its sheet at the frame the bridge's StellarAnimator reports (animated spöb:
#     AnimDelay, Frame0Bias, Flags2 random/return-to-first, a lit hypergate); a destroyed stellar draws its
#     wrecked art (spöb "destroyed" sheet) when the data has one;
#   * murk (0x00438db0) mixes every stellar toward the backdrop colour by its distance from the player;
#   * the selected stellar wears the original's nav cursor (cicn 10000-10007: four corners that fly in from
#     256 px at 1800 px/s) in Classic, and a landable-blue / refused-red corner bracket in Nova Swift;
#   * a lit hypergate / live wormhole keeps its glow ring.
extends RefCounted

const Sprites = preload("res://flight/FlightSprites.gd")

const COLOR_ROCK := Color(0.45, 0.4, 0.36)
const BODY_COLORS := [
	Color(0.45, 0.7, 0.5), Color(0.6, 0.6, 0.65), Color(0.5, 0.75, 1.0),
	Color(0.8, 0.5, 1.0), Color(0.9, 0.35, 0.3),
]

var r                       # FlightRenderer
var cursor_zoom := 0.0
var _cursor_id := -1


func setup(renderer) -> void:
	r = renderer


func draw_bodies(ci: CanvasItem) -> void:
	# No jump-distance ring: neither the original nor the Apple app draws one.
	var xf: PackedFloat32Array = r.body_xf
	var ids: PackedInt32Array = r.body_ids
	var states: PackedFloat32Array = r.stellar_states
	var i := 0
	var n := 0
	while i + 3 < xf.size():
		var wpos := Vector2(xf[i], xf[i + 1])
		var pos: Vector2 = r.w2l(wpos)
		var radius: float = xf[i + 2]
		var kind := int(xf[i + 3])
		var spob_id: int = ids[n] if n < ids.size() else -1
		var frame := int(states[n * 3]) if n * 3 + 2 < states.size() else 0
		var destroyed: bool = n * 3 + 2 < states.size() and states[n * 3 + 1] > 0.5
		var fog: float = states[n * 3 + 2] if n * 3 + 2 < states.size() else 0.0
		var entry = null
		if destroyed:
			entry = r.sprites.entry(Sprites.SPOB_DESTROYED, spob_id)
		if entry == null:
			entry = r.sprites.entry(Sprites.SPOB, spob_id)
		if entry != null:
			Sprites.draw(ci, entry, pos, frame)
			if fog > 0.0:
				r.fog_world.append([entry, pos, frame, Color(r.background.r, r.background.g, r.background.b, 1.0), fog / 32.0])
		else:
			var col: Color = BODY_COLORS[kind] if kind < BODY_COLORS.size() else BODY_COLORS[1]
			ci.draw_circle(pos, maxf(radius, 6.0), col)
		if kind == 2 or kind == 3:
			if kind == 3 or r.nova.gate_is_open(spob_id):
				var glow := Color(0.3, 0.85, 0.98) if kind == 2 else Color(0.78, 0.45, 1.0)
				ci.draw_arc(pos, maxf(radius, 20.0) * 1.2, 0.0, TAU, 32, glow, 2.0, true)
		i += 4
		n += 1


func draw_asteroids(ci: CanvasItem) -> void:
	var xf: PackedFloat32Array = r.roid_xf
	var style: PackedInt32Array = r.roid_style
	var i := 0
	var n := 0
	while i + 3 < xf.size():
		var pos: Vector2 = r.w2l(Vector2(xf[i], xf[i + 1]))
		var radius: float = xf[i + 2]
		var roid_type: int = style[n * 2] if n * 2 + 1 < style.size() else -1
		var frame: int = style[n * 2 + 1] if n * 2 + 1 < style.size() else 0
		var entry = r.sprites.entry(Sprites.ASTEROID, roid_type) if roid_type >= 0 else null
		if entry != null:
			Sprites.draw(ci, entry, pos, frame)
		else:
			ci.draw_circle(pos, maxf(radius, 4.0), COLOR_ROCK)
		i += 4
		n += 1


## Jettisoned pods and a destroyed rock's resource boxes: spïn 500+n rotation sheets.
func draw_freeflight(ci: CanvasItem) -> void:
	var xf: PackedFloat32Array = r.box_xf
	var style: PackedInt32Array = r.box_style
	var n := 0
	while n * 2 + 1 < xf.size():
		var pos: Vector2 = r.w2l(Vector2(xf[n * 2], xf[n * 2 + 1]))
		var spin_id: int = style[n * 2] if n * 2 + 1 < style.size() else -1
		var frame: int = style[n * 2 + 1] if n * 2 + 1 < style.size() else 0
		var entry = r.sprites.entry(Sprites.WEAPON, spin_id) if spin_id >= 0 else null
		if entry != null:
			Sprites.draw(ci, entry, pos, frame % maxi(entry["frames"], 1))
		else:
			ci.draw_circle(pos, 3.0, Color(0.7, 0.7, 0.7))
		n += 1


# MARK: Selection (fx layer)

## The travel-selected stellar's mark. Classic: the original nav cursor; otherwise a corner bracket.
func draw_selection(ci: CanvasItem, dt: float) -> void:
	var sel: int = r.selected_spob
	if sel < 0:
		_cursor_id = -1
		return
	var idx: int = r.body_ids.find(sel)
	if idx < 0:
		return
	var wpos := Vector2(r.body_xf[idx * 4], r.body_xf[idx * 4 + 1])
	var radius: float = r.body_xf[idx * 4 + 2]
	var pos: Vector2 = r.w2l(wpos)
	var entry = r.sprites.entry(Sprites.SPOB, sel)
	var half: float = maxf(entry["fw"], entry["fh"]) * 0.5 if entry != null else 64.0
	if _cursor_id != sel:
		_cursor_id = sel
		cursor_zoom = 256.0
	else:
		cursor_zoom = maxf(0.0, cursor_zoom - 1800.0 * dt)
	var first = r.sprites.entry(Sprites.CICN, 10000)
	if r.classic_world and first != null:
		var base := 4 if r.nova.stellar_dominated_visual(sel) else 0
		var off := ceilf(half) + cursor_zoom + 16.0
		var corners := [Vector2(-off, -off), Vector2(off, -off), Vector2(off, off), Vector2(-off, off)]
		for k in 4:
			var e = r.sprites.entry(Sprites.CICN, 10000 + base + k)
			if e != null:
				Sprites.draw(ci, e, pos + corners[k], 0)
		return
	# Nova Swift: landable blue / refused red corner bracket, a slow lock-on pulse.
	var landable: bool = int(r.body_xf[idx * 4 + 3]) == 0
	var col := Color(0.35, 0.6, 1.0) if landable else Color(0.95, 0.3, 0.25)
	var pulse := 1.0 + 0.08 * (0.5 - 0.5 * cos(r.clock * TAU / 1.1))
	draw_bracket(ci, pos, (maxf(radius, half) * 2.0 + 18.0) * pulse, col)


## GameScene.bracketPath: four disconnected L-shaped corner marks around a `size`-wide square.
static func draw_bracket(ci: CanvasItem, pos: Vector2, size: float, col: Color) -> void:
	var half := size * 0.5
	var arm := maxf(4.0, size * 0.22)
	for sx in [-1.0, 1.0]:
		for sy in [-1.0, 1.0]:
			var corner: Vector2 = pos + Vector2(sx * half, sy * half)
			ci.draw_line(corner, corner - Vector2(sx * arm, 0.0), col, 2.0)
			ci.draw_line(corner, corner - Vector2(0.0, sy * arm), col, 2.0)
