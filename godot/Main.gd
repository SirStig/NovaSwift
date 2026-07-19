# NOVA Swift — Godot frontend (vertical slice, milestone 2).
#
# Drives the Swift engine through the NovaSwiftGodot GDExtension and renders the
# result. Two modes, chosen automatically at startup:
#
#   • Real data — if EV Nova data is found (NOVA_DATA_DIR env var, else the repo's
#     data/base/), it loads it, builds a real system via GameSession.makeWorld,
#     and renders actual hull + planet SPRITES decoded by NovaSwiftKit.
#   • Demo — otherwise a data-free physics world: a ship you fly plus drifting
#     hulls, drawn as primitives. Runs with no data so the slice always works.
#
# Either way the loop is the same and it's the real engine:
#   Godot input -> Swift ControlIntent -> World.step -> Swift readback -> render.
#
# Controls: arrows / WASD fly (real Newtonian momentum), Shift burn, Space fire.
# See docs/GODOT_LAYER.md.

extends Node2D

var nova                     # NovaWorld (from the NovaSwiftGodot GDExtension)
var _has_data := false

# Texture caches keyed by resource id: { id: { tex, fw, fh, cols, frames } }.
var _ship_tex := {}
var _spob_tex := {}

var _stars_near: PackedVector2Array
var _stars_far: PackedVector2Array
var _field := Vector2(4096, 4096)

const SHIP_SIZE := 14.0
const COLOR_PLAYER := Color(0.55, 0.85, 1.0)
const COLOR_NPC := Color(0.95, 0.75, 0.35)
const COLOR_DISABLED := Color(0.5, 0.5, 0.55)
const COLOR_STAR_NEAR := Color(0.9, 0.9, 1.0, 0.9)
const COLOR_STAR_FAR := Color(0.7, 0.7, 0.85, 0.5)
const COLOR_JUMP_RING := Color(0.3, 0.5, 0.7, 0.25)
# Body kind -> fallback circle color (0 landable, 1 planet, 2 hypergate, 3 wormhole, 4 deadly).
const BODY_COLORS := [
	Color(0.45, 0.7, 0.5),
	Color(0.6, 0.6, 0.65),
	Color(0.5, 0.75, 1.0),
	Color(0.8, 0.5, 1.0),
	Color(0.9, 0.35, 0.3),
]


func _ready() -> void:
	if not ClassDB.class_exists("NovaWorld"):
		push_error("NovaWorld class not found — is godot/bin/ built? See scripts/build-gdextension.sh")
		return
	nova = ClassDB.instantiate("NovaWorld")
	add_child(nova)

	_start_world()
	_seed_starfield()


func _start_world() -> void:
	var data_dir := OS.get_environment("NOVA_DATA_DIR")
	if data_dir == "":
		# The repo's git-ignored data dir, where players drop their own EV Nova data.
		data_dir = ProjectSettings.globalize_path("res://") + "../data/base"

	if nova.load_game(data_dir) and nova.make_world(-1):
		_has_data = true
		print("NOVA Swift: loaded data from ", data_dir)
	else:
		nova.make_demo_world()
		_has_data = false
		print("NOVA Swift: no data at ", data_dir, " — running demo world")


func _seed_starfield() -> void:
	var rng := RandomNumberGenerator.new()
	rng.seed = 0x50FA
	_stars_near = PackedVector2Array()
	_stars_far = PackedVector2Array()
	for i in 220:
		_stars_far.append(Vector2(rng.randf() * _field.x, rng.randf() * _field.y))
	for i in 140:
		_stars_near.append(Vector2(rng.randf() * _field.x, rng.randf() * _field.y))


func _process(delta: float) -> void:
	if nova == null:
		return

	var left := Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_A)
	var right := Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_D)
	var thrust := Input.is_key_pressed(KEY_UP) or Input.is_key_pressed(KEY_W)
	var reverse := Input.is_key_pressed(KEY_DOWN) or Input.is_key_pressed(KEY_S)
	var afterburner := Input.is_key_pressed(KEY_SHIFT)
	var fire := Input.is_key_pressed(KEY_SPACE)

	nova.set_intent(left, right, thrust, reverse, afterburner, fire, false)
	nova.step(delta)

	_update_hud()
	queue_redraw()


func _update_hud() -> void:
	var hud: Label = $HUD
	var vel: Vector2 = nova.player_velocity()
	var mode := "real data" if _has_data else "demo world (no data)"
	var ship_name := ""
	if _has_data:
		ship_name = nova.ship_type_name(nova.player_ship_type())
	hud.text = "NOVA Swift — Godot slice · %s%s\n" % [mode, ("  ·  " + ship_name) if ship_name != "" else ""] \
		+ "shield %d%%   armor %d%%   speed %d px/s   ships %d\n" % [
			int(round(nova.player_shield_fraction() * 100.0)),
			int(round(nova.player_armor_fraction() * 100.0)),
			int(round(vel.length())),
			nova.ship_count(),
		] \
		+ "arrows/WASD fly · Shift burn · Space fire"


func _draw() -> void:
	if nova == null:
		return

	var vp := get_viewport_rect().size
	var center := vp * 0.5
	var pw: Vector2 = nova.player_position()

	_draw_starfield(_stars_far, pw, 0.35, COLOR_STAR_FAR, 1.0, vp)
	_draw_starfield(_stars_near, pw, 0.7, COLOR_STAR_NEAR, 1.5, vp)

	if _has_data:
		_draw_bodies(center, pw)

	_draw_ships(center, pw)


func _to_screen(world_pos: Vector2, center: Vector2, pw: Vector2) -> Vector2:
	# Engine space is +y-up; Godot screen is +y-down, so flip y. Camera follows
	# the player by subtracting the player's world position.
	return center + Vector2(world_pos.x - pw.x, -(world_pos.y - pw.y))


func _draw_bodies(center: Vector2, pw: Vector2) -> void:
	# Jump-radius ring, centered on the system origin.
	var jr: float = nova.jump_radius()
	if jr > 0.0:
		draw_arc(_to_screen(Vector2.ZERO, center, pw), jr, 0.0, TAU, 96, COLOR_JUMP_RING, 2.0, true)

	var xf: PackedFloat32Array = nova.body_transforms()
	var ids: PackedInt32Array = nova.body_spob_ids()
	var i := 0
	var n := 0
	while i + 3 < xf.size():
		var pos := _to_screen(Vector2(xf[i], xf[i + 1]), center, pw)
		var radius: float = xf[i + 2]
		var kind := int(xf[i + 3])
		var spob_id: int = ids[n] if n < ids.size() else -1
		var entry = _sprite_entry(_spob_tex, spob_id, "spob")
		if entry != null:
			_draw_sprite(entry, pos, 0)
		else:
			var col: Color = BODY_COLORS[kind] if kind < BODY_COLORS.size() else BODY_COLORS[1]
			draw_circle(pos, max(radius, 6.0), col)
		i += 4
		n += 1


func _draw_ships(center: Vector2, pw: Vector2) -> void:
	var xf: PackedFloat32Array = nova.ship_transforms()          # [x, y, angle, kind] * N
	var sf: PackedInt32Array = nova.ship_sprite_frames()          # [shipType, frame] * N
	var i := 0
	var n := 0
	while i + 3 < xf.size():
		var pos := _to_screen(Vector2(xf[i], xf[i + 1]), center, pw)
		var angle: float = xf[i + 2]
		var kind := int(xf[i + 3])
		var ship_type: int = sf[n * 2] if n * 2 + 1 < sf.size() else -1
		var frame: int = sf[n * 2 + 1] if n * 2 + 1 < sf.size() else 0
		var entry = _sprite_entry(_ship_tex, ship_type, "ship") if ship_type >= 0 else null
		if entry != null:
			# EV Nova sprites are pre-rotated: pick the frame, don't rotate the texture.
			_draw_sprite(entry, pos, frame)
		else:
			_draw_ship_primitive(pos, angle, kind)
		i += 4
		n += 1


# Return a cached { tex, fw, fh, cols, frames } for a resource id, building it on
# first use. Caches nulls too, so a spriteless id isn't re-queried every frame.
func _sprite_entry(cache: Dictionary, id: int, which: String):
	if cache.has(id):
		return cache[id]
	var info: PackedInt32Array
	var bytes: PackedByteArray
	if which == "ship":
		info = nova.ship_sprite_info(id)
		bytes = nova.ship_sprite_rgba(id)
	else:
		info = nova.spob_sprite_info(id)
		bytes = nova.spob_sprite_rgba(id)

	if info.size() < 7:
		cache[id] = null
		return null
	var fw := info[0]
	var fh := info[1]
	var frames := info[2]
	var cols := info[3]
	var sw := info[5]
	var sh := info[6]
	if bytes.size() < sw * sh * 4 or sw <= 0 or sh <= 0:
		cache[id] = null
		return null

	var img := Image.create_from_data(sw, sh, false, Image.FORMAT_RGBA8, bytes)
	var entry := {
		"tex": ImageTexture.create_from_image(img),
		"fw": fw, "fh": fh, "cols": max(cols, 1), "frames": max(frames, 1),
	}
	cache[id] = entry
	return entry


func _draw_sprite(entry: Dictionary, pos: Vector2, frame: int) -> void:
	var fw: int = entry["fw"]
	var fh: int = entry["fh"]
	var cols: int = entry["cols"]
	var f: int = clampi(frame, 0, entry["frames"] - 1)
	var col := f % cols
	var row := f / cols
	var src := Rect2(col * fw, row * fh, fw, fh)
	var dst := Rect2(pos - Vector2(fw, fh) * 0.5, Vector2(fw, fh))
	draw_texture_rect_region(entry["tex"], dst, src)


func _draw_starfield(stars: PackedVector2Array, pw: Vector2, parallax: float,
		col: Color, radius: float, vp: Vector2) -> void:
	var offset := Vector2(
		fposmod(-pw.x * parallax, _field.x),
		fposmod(pw.y * parallax, _field.y))
	for s in stars:
		var p := Vector2(fposmod(s.x + offset.x, vp.x), fposmod(s.y + offset.y, vp.y))
		draw_circle(p, radius, col)


func _draw_ship_primitive(pos: Vector2, angle: float, kind: int) -> void:
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
	draw_colored_polygon(PackedVector2Array([nose, tail_l, tail_r]), col)
