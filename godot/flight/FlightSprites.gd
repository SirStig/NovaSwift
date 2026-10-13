# Decoded-sprite cache shared by the flight drawers (godot/flight/).
#
# Keyed by Vector2i(kind, id) -- the bridge's SpriteKind enum (NovaWorld.swift) -- each entry is
# { tex, fw, fh, cols, frames, rate } or null for "this resource has no graphic" (asked for once,
# not every frame). `cicn` art (reticle, nav cursor, smoke) is cached the same way under
# kind CICN. Textures are built once from the bridge's RGBA bytes; nothing here touches pixels
# per frame.
extends RefCounted

# Sprite kinds -- MUST match the bridge's SpriteKind enum.
const SHIP := 0
const ENGINE_GLOW := 1
const SHIELD := 2
const LIGHTS := 3
const WEAPON_GLOW := 4
const SPOB := 5
const SPOB_DESTROYED := 6
const WEAPON := 7
const BOOM := 8
const ASTEROID := 9
const STARFIELD := 10
const ALT := 11          # not a bridge kind: the shän alt layer (served by the bridge as kind 11)
const CICN := 100        # not a bridge kind: bridge cicn_info / cicn_rgba

var nova
var _cache := {}
## Keys (Vector2i(kind, id)) whose lookup found no graphic -- read by tests/plugins_load_selfcheck.gd.
var misses: Dictionary = {}
var _gen := 0                       # world-rebuild counter: entries are evicted after MAX_IDLE_GENERATIONS unused rebuilds
var _mlist: Array = []              # the queued manifest, in the bridge's decode order (Vector2i(kind, id))
var _mpos := 0                      # next _mlist index to build
const MAX_IDLE_GENERATIONS := 4


func setup(world: Object) -> void:
	nova = world


## Drop everything (a different data set / plug-in set was loaded). A world rebuild does NOT call this:
## sprite art is keyed by resource id, so it stays valid across launches and jumps and rebuilding it is the
## launch / arrival hitch (a decode + RGBA copy + texture upload per sprite, on the main thread).
func clear() -> void:
	_cache.clear()
	_mlist.clear()
	_mpos = 0


## A world was rebuilt: age the cache and evict what the last few systems did not use (bounds VRAM on a long
## session). Manifest entries are re-stamped by queue_manifest, so the live system's art is always kept.
func new_generation() -> void:
	_gen += 1
	var drop: Array = []
	for key in _cache.keys():
		if int(key.x) == CICN:
			continue
		var e = _cache[key]
		if e != null and int(e.get("gen", _gen)) < _gen - MAX_IDLE_GENERATIONS:
			drop.append(key)
	for key in drop:
		_cache.erase(key)
		misses.erase(key)


## Queue the sprites a system needs (the bridge's flat [kind, id, kind, id ...] manifest) so they are built
## before the first frame that draws them.
func queue_manifest(manifest: PackedInt32Array) -> void:
	_mlist.clear()
	_mpos = 0
	var i := 0
	while i + 1 < manifest.size():
		var key := Vector2i(manifest[i], manifest[i + 1])
		_mlist.append(key)
		if _cache.has(key):
			var e = _cache[key]
			if e != null:
				e["gen"] = _gen
		i += 2


## Build queued sprites, but only the first `limit` manifest entries (the bridge's background decode has
## finished those, so the bridge call is a cache hit), until `budget_ms` of wall time is spent
## (<= 0: no limit). Returns how many entries remain.
func pump(budget_ms: float, limit: int) -> int:
	var t0 := Time.get_ticks_usec()
	var end: int = mini(limit, _mlist.size())
	while _mpos < end:
		var key: Vector2i = _mlist[_mpos]
		_mpos += 1
		if not _cache.has(key):
			entry(key.x, key.y)
		if budget_ms > 0.0 and float(Time.get_ticks_usec() - t0) / 1000.0 >= budget_ms:
			break
	return _mlist.size() - _mpos


func pending() -> int:
	return _mlist.size() - _mpos


func entry(kind: int, id: int):
	var key := Vector2i(kind, id)
	if _cache.has(key):
		return _cache[key]
	var e = _build(kind, id)
	if e != null:
		e["gen"] = _gen
	_cache[key] = e
	if e == null:
		misses[key] = true
	return e


func _build(kind: int, id: int):
	if kind == CICN:
		var ci: PackedInt32Array = nova.cicn_info(id)
		if ci.size() < 2 or ci[0] <= 0 or ci[1] <= 0:
			return null
		var cbytes: PackedByteArray = nova.cicn_rgba(id)
		if cbytes.size() < ci[0] * ci[1] * 4:
			return null
		var cimg := Image.create_from_data(ci[0], ci[1], false, Image.FORMAT_RGBA8, cbytes)
		return {"tex": ImageTexture.create_from_image(cimg), "fw": ci[0], "fh": ci[1], "cols": 1, "frames": 1, "rate": 0}
	var info: PackedInt32Array = nova.sprite_info(kind, id)
	if info.size() < 7:
		return null
	var fw := info[0]
	var fh := info[1]
	var frames := info[2]
	var cols := info[3]
	var sw := info[5]
	var sh := info[6]
	var rate: int = info[7] if info.size() > 7 else 0
	if sw <= 0 or sh <= 0:
		return null
	var bytes: PackedByteArray = nova.sprite_rgba(kind, id)
	if bytes.size() < sw * sh * 4:
		return null
	var img := Image.create_from_data(sw, sh, false, Image.FORMAT_RGBA8, bytes)
	return {"tex": ImageTexture.create_from_image(img), "fw": fw, "fh": fh, "cols": maxi(cols, 1),
		"frames": maxi(frames, 1), "rate": rate}


static func src(e: Dictionary, frame: int) -> Rect2:
	var fw: int = e["fw"]
	var fh: int = e["fh"]
	var cols: int = e["cols"]
	var f: int = clampi(frame, 0, e["frames"] - 1)
	return Rect2((f % cols) * fw, (f / cols) * fh, fw, fh)


## The original's Sprite_SetCurrentFrame wrap: negative -> 0, then modulo the sheet's count.
static func wrap(index: int, count: int) -> int:
	return 0 if count <= 0 else maxi(0, index) % count


## Draw frame `frame` of `e` centred at `pos` (in the canvas item's current transform).
static func draw(ci: CanvasItem, e: Dictionary, pos: Vector2, frame: int, tint: Color = Color.WHITE) -> void:
	var size := Vector2(e["fw"], e["fh"])
	ci.draw_texture_rect_region(e["tex"], Rect2(pos - size * 0.5, size), src(e, frame), tint)


## Same, spun about its centre by `angle` (radians, clockwise on screen). `base` is the layer's
## world transform, restored afterwards.
static func draw_rotated(ci: CanvasItem, base: Transform2D, e: Dictionary, pos: Vector2, frame: int,
		angle: float, tint: Color = Color.WHITE) -> void:
	var size := Vector2(e["fw"], e["fh"])
	ci.draw_set_transform_matrix(base * Transform2D(angle, pos))
	ci.draw_texture_rect_region(e["tex"], Rect2(-size * 0.5, size), src(e, frame), tint)
	ci.draw_set_transform_matrix(base)
