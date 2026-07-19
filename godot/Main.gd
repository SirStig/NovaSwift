# NOVA Swift — Godot vertical slice.
#
# Proves the full loop end-to-end on Linux/Windows/macOS:
#   Godot input -> Swift ControlIntent -> World.step -> Swift readback -> render.
#
# It builds a data-free demo world (a flyable ship + drifting hulls) so it runs
# with no EV Nova data, then each frame feeds keyboard input to the engine, ticks
# the real Newtonian simulation, and draws every ship the engine reports.
#
# Controls: arrows / WASD to fly (you swing the nose and keep drifting — that's
# the engine's real momentum), Shift = afterburner, Space = fire primary.
#
# See docs/GODOT_LAYER.md.

extends Node2D

var nova                     # NovaWorld (from the NovaSwiftGodot GDExtension)
var _stars_near: PackedVector2Array
var _stars_far: PackedVector2Array
var _field := Vector2(4096, 4096)

const SHIP_SIZE := 14.0
const COLOR_PLAYER := Color(0.55, 0.85, 1.0)
const COLOR_NPC := Color(0.95, 0.75, 0.35)
const COLOR_DISABLED := Color(0.5, 0.5, 0.55)
const COLOR_STAR_NEAR := Color(0.9, 0.9, 1.0, 0.9)
const COLOR_STAR_FAR := Color(0.7, 0.7, 0.85, 0.5)


func _ready() -> void:
	# The GDExtension registers `NovaWorld`; instantiate and build the demo world.
	if not ClassDB.class_exists("NovaWorld"):
		push_error("NovaWorld class not found — is godot/bin/ built? See scripts/build-gdextension.sh")
		return
	nova = ClassDB.instantiate("NovaWorld")
	add_child(nova)
	nova.make_demo_world()

	_seed_starfield()


func _seed_starfield() -> void:
	# Deterministic star positions across a large wrap field, two parallax layers.
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
	hud.text = "NOVA Swift — Godot slice (demo world, no data)\n" \
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

	# Draw every ship the engine reports: [x, y, angle, kind] * N, player first.
	var xf: PackedFloat32Array = nova.ship_transforms()
	var i := 0
	while i + 3 < xf.size():
		var world_pos := Vector2(xf[i], xf[i + 1])
		var angle := xf[i + 2]
		var kind := int(xf[i + 3])
		# Engine space is +y-up; Godot screen is +y-down, so flip y. Camera
		# follows the player by subtracting the player's world position.
		var screen := center + Vector2(world_pos.x - pw.x, -(world_pos.y - pw.y))
		_draw_ship(screen, angle, kind)
		i += 4


func _draw_starfield(stars: PackedVector2Array, pw: Vector2, parallax: float,
		col: Color, radius: float, vp: Vector2) -> void:
	# Scroll the field opposite the player's motion and wrap it across the screen.
	var offset := Vector2(
		fposmod(-pw.x * parallax, _field.x),
		fposmod(pw.y * parallax, _field.y))
	for s in stars:
		var p := Vector2(fposmod(s.x + offset.x, vp.x), fposmod(s.y + offset.y, vp.y))
		draw_circle(p, radius, col)


func _draw_ship(pos: Vector2, angle: float, kind: int) -> void:
	# Engine heading (sin, cos) in +y-up space -> screen direction with y flipped.
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
