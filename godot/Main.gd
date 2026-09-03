# NOVA Swift — Godot frontend.
#
# Drives the Swift engine through the NovaSwiftGodot GDExtension and renders the
# result. Two modes, chosen automatically at startup:
#
#   • Real data — if EV Nova data is found (NOVA_DATA_DIR env var, else the repo's
#     data/base/), it loads it, builds a real system via GameSession.makeWorld,
#     and renders actual hull, planet, shot, rock and explosion SPRITES decoded
#     by NovaSwiftKit.
#   • Demo — otherwise a data-free physics world: a ship you fly plus drifting
#     hulls, drawn as primitives. Runs with no data so the slice always works.
#
# Either way the loop is the same and it's the real engine:
#   Godot input -> Swift ControlIntent -> World.step -> Swift readback -> render.
#
# Swift is the single source of truth for game state: targeting, hostility,
# weapon readiness, fuel, sensor range, and now the whole combat entity set
# (shots, beams, rocks) are all engine calls (mirroring the Apple app's
# GameScene/GameHUDModel split) — this script only lays out pixels and does
# small numeric formatting over whatever the bridge returns, never its own game
# logic. The one thing it owns outright is the transient particle layer: the
# engine says "an explosion happened here, this big, playing this bööm", and
# how that looks on screen is the frontend's business.
#
# Timing note: nova.step() runs the engine's own fixed 30 Hz tick internally and
# hands back render-interpolated poses, so this script just forwards the display
# delta and draws whatever comes out. See NovaWorld.step.
#
# Controls: arrows/WASD fly, Shift burn, Space fire primary, Ctrl fire secondary,
# Tab nearest-hostile target, Backspace clear target, Q/E cycle secondary weapon,
# L land/launch. Docked: up/down select a commodity row, B buy 1 ton, S sell 1 ton.
# See docs/GODOT_LAYER.md.

extends Node2D

var nova                     # NovaWorld (from the NovaSwiftGodot GDExtension)
var _has_data := false

# Trade Center: selected commodity row while docked.
var _trade_selected := 0

# Decoded-sprite cache, keyed by Vector2i(kind, id) — see SPRITE_* below. Each
# entry is { tex, fw, fh, cols, frames, rate } or null for "this resource has no
# graphic", so a spriteless id is asked for once rather than every frame.
var _sprite_cache := {}

var _stars_near: PackedVector2Array
var _stars_far: PackedVector2Array
var _field := Vector2(4096, 4096)

# Edge-triggered keys (Tab/Q/E/Backspace act once per press, not held).
var _keys_down_last := {}

# Rolling message log: [{text, age}], newest first, oldest fades out.
var _log: Array = []
const LOG_MAX_LINES := 6
const LOG_LIFETIME := 6.0

# Live transient effects spawned from the bridge's effect drain — see _spawn_fx.
var _fx: Array = []
const FX_MAX := 160

# Per-frame snapshot of the bridge readbacks, filled once in _process and read
# by the several _draw passes that need them. Without this the ship table would
# be marshalled across the extension boundary three times a frame (ships, radar,
# visuals) for identical data.
var _ship_xf: PackedFloat32Array
var _ship_sf: PackedInt32Array
var _ship_ids: PackedInt32Array
var _ship_rel: PackedInt32Array
var _ship_vis: PackedFloat32Array
var _shot_xf: PackedFloat32Array
var _shot_style: PackedInt32Array
var _beams: PackedFloat32Array
var _roid_xf: PackedFloat32Array
var _roid_style: PackedInt32Array
var _background := Color(0.02, 0.02, 0.06)

const SHIP_SIZE := 14.0
const COLOR_PLAYER := Color(0.55, 0.85, 1.0)
const COLOR_NPC := Color(0.95, 0.75, 0.35)
const COLOR_DISABLED := Color(0.5, 0.5, 0.55)
const COLOR_STAR_NEAR := Color(0.9, 0.9, 1.0, 0.9)
const COLOR_STAR_FAR := Color(0.7, 0.7, 0.85, 0.5)
const COLOR_JUMP_RING := Color(0.3, 0.5, 0.7, 0.25)
const COLOR_SHOT := Color(1.0, 0.85, 0.4)
const COLOR_ROCK := Color(0.45, 0.4, 0.36)
# Body kind -> fallback circle color (0 landable, 1 planet, 2 hypergate, 3 wormhole, 4 deadly).
const BODY_COLORS := [
	Color(0.45, 0.7, 0.5),
	Color(0.6, 0.6, 0.65),
	Color(0.5, 0.75, 1.0),
	Color(0.8, 0.5, 1.0),
	Color(0.9, 0.35, 0.3),
]
# Radar/IFF relationship code (from NovaWorld.shipRelationships) -> blip color.
# 0 hostile, 1 neutral, 2 friendly/escort, 3 disabled, 4 self.
const RELATIONSHIP_COLORS := [
	Color(0.95, 0.25, 0.25),
	Color(0.35, 0.55, 0.95),
	Color(0.35, 0.9, 0.45),
	Color(0.55, 0.55, 0.6),
	COLOR_PLAYER,
]

# Sprite kinds — these MUST match the bridge's SpriteKind enum
# (godot/bridge/Sources/NovaSwiftGodot/NovaWorld.swift).
const SPRITE_SHIP := 0
const SPRITE_ENGINE_GLOW := 1
const SPRITE_SPOB := 5
const SPRITE_WEAPON := 7
const SPRITE_BOOM := 8
const SPRITE_ASTEROID := 9

# Effect kinds — these MUST match the `kind` column of the bridge's drainEffects.
const FX_EXPLOSION := 0
const FX_SHIELD_HIT := 1
const FX_ARMOR_HIT := 2
const FX_DEBRIS := 3
const FX_SHIP_DYING := 4
const FX_SHIP_DESTROYED := 5
const FX_MUZZLE := 6

# How long each effect kind stays on screen, in seconds. A bööm-backed explosion
# overrides its own entry with the authored frame count × frame duration.
const FX_LIFETIME := {
	FX_EXPLOSION: 0.55,
	FX_SHIELD_HIT: 0.30,
	FX_ARMOR_HIT: 0.30,
	FX_DEBRIS: 0.70,
	FX_SHIP_DYING: 0.80,
	FX_SHIP_DESTROYED: 1.10,
	FX_MUZZLE: 0.07,
}

const RADAR_CENTER_MARGIN := Vector2(120, 120)
const RADAR_PIXEL_RADIUS := 90.0
const RADAR_WORLD_RANGE := 4500.0   # matches the Apple app's own client-side radarRange

# WorldEvent case name -> message-log phrase. Only the narratively-interesting
# events surface here (matches GameHUDModel.post() on the Apple side); the
# per-frame combat/FX ones (weaponFired, shieldHit, explosion, ...) are drawn by
# the particle layer instead of being narrated.
const EVENT_MESSAGES := {
	"shipDestroyed": "Target destroyed",
	"shipDisabled": "Target disabled",
	"shipScanned": "Cargo scanned",
	"shipBoarded": "Boarding complete",
	"assistanceDelivered": "Assistance delivered",
	"shipLanded": "Docked",
	"shipLaunched": "Launched",
	"shipDepartedViaGate": "Ship departed via hypergate",
	"shipEmergedFromGate": "Ship emerged from hypergate",
}


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
	_refresh_background()


# The system's own sÿst.BkgndColor. Re-read whenever the world is rebuilt, not
# per frame — it only changes when the system does.
func _refresh_background() -> void:
	var rgb: PackedFloat32Array = nova.system_background_color()
	if rgb.size() >= 3 and (rgb[0] + rgb[1] + rgb[2]) > 0.0:
		_background = Color(rgb[0], rgb[1], rgb[2])
	else:
		# Pure black is what the demo world and most ordinary systems report;
		# lift it a hair so the starfield has something to sit against.
		_background = Color(0.02, 0.02, 0.06)


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

	var hud: Label = $HUD
	if nova.is_landed():
		# Docked: the flight sim is paused (no set_intent/step) — only the
		# Trade Center + launch hotkeys and the message-log fade run. Mirrors
		# the Apple app's spaceport screens owning the frame while landed. The
		# flight HUD label is a Control child, so it draws *over* this script's
		# _draw output and has to be hidden explicitly.
		hud.visible = false
		_process_trade_hotkeys()
		_on_key_pressed(KEY_L, func(): _on_launch())
		_drain_events_to_log(delta)
		queue_redraw()
		return

	hud.visible = true

	var left := Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_A)
	var right := Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_D)
	var thrust := Input.is_key_pressed(KEY_UP) or Input.is_key_pressed(KEY_W)
	var reverse := Input.is_key_pressed(KEY_DOWN) or Input.is_key_pressed(KEY_S)
	var afterburner := Input.is_key_pressed(KEY_SHIFT)
	var fire_primary := Input.is_key_pressed(KEY_SPACE)
	var fire_secondary := Input.is_key_pressed(KEY_CTRL)

	nova.set_intent(left, right, thrust, reverse, afterburner, fire_primary, fire_secondary)
	nova.step(delta)

	_snapshot_frame()
	_process_hotkeys()
	_drain_events_to_log(delta)
	_advance_fx(delta)
	_update_top_label()
	queue_redraw()


# Pull every per-frame table across the bridge exactly once.
func _snapshot_frame() -> void:
	_ship_xf = nova.ship_transforms()
	_ship_sf = nova.ship_sprite_frames()
	_ship_ids = nova.ship_ids()
	_ship_rel = nova.ship_relationships()
	_ship_vis = nova.ship_visuals()
	_shot_xf = nova.projectile_transforms()
	_shot_style = nova.projectile_styles()
	_beams = nova.beam_segments()
	_roid_xf = nova.asteroid_transforms()
	_roid_style = nova.asteroid_styles()


func _on_launch() -> void:
	if nova.launch():
		_fx.clear()
		_refresh_background()
		_push_log("Launched")


func _update_top_label() -> void:
	var hud: Label = $HUD
	var mode := "real data" if _has_data else "demo world (no data)"
	var ship_name := ""
	if _has_data:
		ship_name = nova.ship_type_name(nova.player_ship_type())
	hud.text = "NOVA Swift — Godot · %s%s · ships %d\n" % [
			mode, ("  ·  " + ship_name) if ship_name != "" else "", nova.ship_count(),
		] \
		+ "arrows/WASD fly · Shift burn · Space fire · Ctrl secondary · Tab target · Q/E switch weapon · L land"


# Tab / Backspace / Q / E fire once per keypress, not once per held frame — poll
# manually since the project has no InputMap actions defined for them.
func _process_hotkeys() -> void:
	_on_key_pressed(KEY_TAB, func(): nova.select_nearest_target(true))
	_on_key_pressed(KEY_BACKSPACE, func(): nova.clear_player_target())
	_on_key_pressed(KEY_Q, func(): _log_weapon_switch(nova.cycle_secondary_weapon(false)))
	_on_key_pressed(KEY_E, func(): _log_weapon_switch(nova.cycle_secondary_weapon(true)))
	_on_key_pressed(KEY_L, func(): _on_land())


func _on_land() -> void:
	var spob_name: String = nova.nearest_landable_name()
	if nova.attempt_land():
		_trade_selected = 0
		_fx.clear()
		_push_log("Docked at " + spob_name)


func _process_trade_hotkeys() -> void:
	var n: int = nova.commodity_count()
	if n <= 0:
		return
	_trade_selected = clampi(_trade_selected, 0, n - 1)
	_on_key_pressed(KEY_UP, func(): _trade_selected = clampi(_trade_selected - 1, 0, n - 1))
	_on_key_pressed(KEY_DOWN, func(): _trade_selected = clampi(_trade_selected + 1, 0, n - 1))
	_on_key_pressed(KEY_B, func(): _on_trade_buy())
	_on_key_pressed(KEY_S, func(): _on_trade_sell())


func _on_trade_buy() -> void:
	var goods: String = nova.commodity_name(_trade_selected)
	var bought: int = nova.buy_commodity(_trade_selected, 1)
	if bought > 0:
		_push_log("Bought 1 ton " + goods)


func _on_trade_sell() -> void:
	var goods: String = nova.commodity_name(_trade_selected)
	var sold: int = nova.sell_commodity(_trade_selected, 1)
	if sold > 0:
		_push_log("Sold 1 ton " + goods)


func _on_key_pressed(key: Key, action: Callable) -> void:
	var down := Input.is_key_pressed(key)
	if down and not _keys_down_last.get(key, false):
		action.call()
	_keys_down_last[key] = down


func _log_weapon_switch(new_name: String) -> void:
	if new_name != "":
		_push_log("Secondary: " + new_name)


func _push_log(text: String) -> void:
	_log.push_front({"text": text, "age": 0.0})
	if _log.size() > LOG_MAX_LINES:
		_log.resize(LOG_MAX_LINES)


func _drain_events_to_log(delta: float) -> void:
	for entry in _log:
		entry["age"] += delta
	_log = _log.filter(func(e): return e["age"] < LOG_LIFETIME)

	# drain_events() genuinely drains on the bridge side, so this is safe to call
	# on a frame where the sim didn't tick (docked) — it just comes back empty.
	for event_name in nova.drain_events():
		var msg: String = EVENT_MESSAGES.get(event_name, "")
		if msg != "":
			_push_log(msg)


# MARK: Transient effects
#
# The bridge reports what happened and where; the look is ours. Each drained row
# becomes one _fx entry that ages out on its own clock.

func _advance_fx(delta: float) -> void:
	for e in _fx:
		e["age"] += delta
	_fx = _fx.filter(func(e): return e["age"] < e["life"])

	var rows: PackedFloat32Array = nova.drain_effects()
	var stride: int = nova.effect_stride()
	var i := 0
	while i + stride <= rows.size():
		_spawn_fx(int(rows[i]), Vector2(rows[i + 1], rows[i + 2]),
			rows[i + 3], rows[i + 4], Color(rows[i + 5], rows[i + 6], rows[i + 7]))
		i += stride
	# A dense firefight can outrun the fade; drop the oldest rather than let the
	# list grow without bound.
	if _fx.size() > FX_MAX:
		_fx = _fx.slice(_fx.size() - FX_MAX)


func _spawn_fx(kind: int, pos: Vector2, p0: float, p1: float, col: Color) -> void:
	var life: float = FX_LIFETIME.get(kind, 0.4)
	var boom_id := -1
	var radius := 12.0

	match kind:
		FX_EXPLOSION:
			radius = maxf(p0, 8.0)
			boom_id = int(p1)
		FX_SHIP_DYING, FX_SHIP_DESTROYED:
			radius = 34.0 if kind == FX_SHIP_DESTROYED else 22.0
			boom_id = int(p0) if kind == FX_SHIP_DYING else -1
			col = Color(1.0, 0.8, 0.45)
		FX_SHIELD_HIT, FX_ARMOR_HIT:
			radius = 7.0
		FX_DEBRIS:
			radius = 3.0
		FX_MUZZLE:
			radius = 5.0

	var entry := {
		"kind": kind, "pos": pos, "age": 0.0, "life": life,
		"radius": radius, "color": col, "boom": -1, "dirs": PackedVector2Array(),
	}

	# A bööm-backed explosion plays its authored animation for its authored
	# duration instead of the generic flash.
	if boom_id >= 0:
		var sheet = _sprite_entry(SPRITE_BOOM, boom_id)
		if sheet != null:
			entry["boom"] = boom_id
			entry["life"] = maxf(0.1, sheet["frames"] * _boom_frame_seconds(sheet["rate"]))

	# Particle bursts scatter fixed directions chosen once at spawn, so a chunk
	# flies straight rather than jittering to a new random spot each frame.
	if kind == FX_DEBRIS or kind == FX_SHIELD_HIT or kind == FX_ARMOR_HIT:
		var count := clampi(int(p0), 4, 18) if kind == FX_DEBRIS else 7
		var dirs := PackedVector2Array()
		for n in count:
			var a := randf() * TAU
			dirs.append(Vector2(cos(a), sin(a)) * randf_range(0.4, 1.0))
		entry["dirs"] = dirs

	_fx.append(entry)


# bööm FrameAdvance R: fps = R/100 × 30, so one frame lasts 100/(30R) seconds.
func _boom_frame_seconds(rate: int) -> float:
	return 100.0 / (30.0 * float(rate)) if rate > 0 else 1.0 / 30.0


func _draw() -> void:
	if nova == null:
		return

	var vp := get_viewport_rect().size

	if nova.is_landed():
		_draw_spaceport_placeholder(vp)
		_draw_message_log(vp)
		return

	# The system's own background, not a hardcoded near-black — Nova's nebula
	# systems are visibly tinted and clearing wrong loses that entirely.
	draw_rect(Rect2(Vector2.ZERO, vp), _background)

	var center := vp * 0.5
	var pw: Vector2 = nova.player_position()

	_draw_starfield(_stars_far, pw, 0.35, COLOR_STAR_FAR, 1.0, vp)
	_draw_starfield(_stars_near, pw, 0.7, COLOR_STAR_NEAR, 1.5, vp)

	if _has_data:
		_draw_bodies(center, pw)
		_draw_asteroids(center, pw)

	var target_id: int = nova.player_target_id()
	# Beams under the hulls so a beam reads as coming *out* of the barrel;
	# shots and blasts over them so nothing hides an impact.
	_draw_beams(center, pw)
	_draw_ships(center, pw, target_id)
	_draw_projectiles(center, pw)
	_draw_effects(center, pw)

	_draw_status_bars(vp)
	_draw_weapon_readout(vp)
	_draw_target_panel(vp, target_id)
	_draw_land_prompt(vp)
	_draw_radar(vp, pw)
	_draw_message_log(vp)


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
		var entry = _sprite_entry(SPRITE_SPOB, spob_id)
		if entry != null:
			_draw_sprite(entry, pos, 0)
		else:
			var col: Color = BODY_COLORS[kind] if kind < BODY_COLORS.size() else BODY_COLORS[1]
			draw_circle(pos, maxf(radius, 6.0), col)
		i += 4
		n += 1


func _draw_asteroids(center: Vector2, pw: Vector2) -> void:
	var i := 0
	var n := 0
	while i + 3 < _roid_xf.size():
		var pos := _to_screen(Vector2(_roid_xf[i], _roid_xf[i + 1]), center, pw)
		var radius: float = _roid_xf[i + 2]
		var roid_type: int = _roid_style[n * 2] if n * 2 + 1 < _roid_style.size() else -1
		var frame: int = _roid_style[n * 2 + 1] if n * 2 + 1 < _roid_style.size() else 0
		var entry = _sprite_entry(SPRITE_ASTEROID, roid_type) if roid_type >= 0 else null
		if entry != null:
			# röid art is a pre-rotated sheet like a hull's: pick the frame.
			_draw_sprite(entry, pos, frame)
		else:
			draw_circle(pos, maxf(radius, 4.0), COLOR_ROCK)
		i += 4
		n += 1


func _draw_ships(center: Vector2, pw: Vector2, target_id: int) -> void:
	var i := 0
	var n := 0
	while i + 3 < _ship_xf.size():
		var pos := _to_screen(Vector2(_ship_xf[i], _ship_xf[i + 1]), center, pw)
		var angle: float = _ship_xf[i + 2]
		var kind := int(_ship_xf[i + 3])
		var ship_type: int = _ship_sf[n * 2] if n * 2 + 1 < _ship_sf.size() else -1
		var frame: int = _ship_sf[n * 2 + 1] if n * 2 + 1 < _ship_sf.size() else 0

		# [cloak, ionize, thrusting] per ship, same order as the transforms.
		var v := n * 3
		var cloak: float = _ship_vis[v] if v + 2 < _ship_vis.size() else 0.0
		var ionize: float = _ship_vis[v + 1] if v + 2 < _ship_vis.size() else 0.0
		var thrusting: bool = (_ship_vis[v + 2] if v + 2 < _ship_vis.size() else 0.0) > 0.5

		# A cloaking ship dissolves rather than popping out. Never quite zero —
		# the player's own hull staying faintly visible is how EV Nova draws it.
		var alpha := 1.0 - cloak * (0.92 if kind != 0 else 0.75)
		var tint := Color(1, 1, 1, alpha)
		if ionize > 0.02:
			# Ionization crackle: bleed the hull toward its charge colour.
			tint = tint.lerp(Color(0.55, 0.75, 1.0, alpha), minf(ionize, 0.8))

		var entry = _sprite_entry(SPRITE_SHIP, ship_type) if ship_type >= 0 else null
		if entry != null:
			# The exhaust overlay sits under the hull so the plume reads as
			# coming out from behind it.
			if thrusting:
				var glow = _sprite_entry(SPRITE_ENGINE_GLOW, ship_type)
				if glow != null:
					_draw_sprite(glow, pos, frame, tint)
				else:
					# No authored exhaust art — fall back to the synthetic plume,
					# sized off this hull's own frame so a freighter and a
					# fighter don't get the same flame.
					_draw_thruster_flame(pos, angle, alpha, entry["fw"] * 0.5)
			# EV Nova sprites are pre-rotated: pick the frame, don't rotate the texture.
			_draw_sprite(entry, pos, frame, tint)
		else:
			if thrusting:
				_draw_thruster_flame(pos, angle, alpha, SHIP_SIZE)
			_draw_ship_primitive(pos, angle, kind, alpha)

		if target_id >= 0 and n < _ship_ids.size() and _ship_ids[n] == target_id:
			draw_arc(pos, SHIP_SIZE * 1.8, 0.0, TAU, 24, Color(1.0, 0.35, 0.3, 0.85), 1.5, true)
		i += 4
		n += 1


func _draw_projectiles(center: Vector2, pw: Vector2) -> void:
	var i := 0
	var n := 0
	while i + 2 < _shot_xf.size():
		var pos := _to_screen(Vector2(_shot_xf[i], _shot_xf[i + 1]), center, pw)
		var facing: float = _shot_xf[i + 2]
		var s := n * 3
		var spin_id: int = _shot_style[s] if s + 2 < _shot_style.size() else -1
		var spins: bool = (_shot_style[s + 1] if s + 2 < _shot_style.size() else 0) != 0
		var translucent: bool = (_shot_style[s + 2] if s + 2 < _shot_style.size() else 0) != 0
		# wëap Flags3 0x0002: translucent shots draw at reduced opacity.
		var tint := Color(1, 1, 1, 0.45 if translucent else 1.0)

		var entry = _sprite_entry(SPRITE_WEAPON, spin_id) if spin_id >= 0 else null
		if entry == null:
			# No authored art — a small hot bolt, pointed along travel so a
			# volley still reads as directional.
			var dir := Vector2(sin(facing), -cos(facing))
			var col := COLOR_SHOT
			col.a = tint.a
			draw_line(pos - dir * 4.0, pos + dir * 4.0, col, 2.0, true)
			draw_circle(pos, 2.0, col)
		elif entry["frames"] >= 16 and not spins:
			# A many-frame sheet that doesn't spin is a rotation sheet: index it
			# by heading rather than rotating the texture (same rule the Apple
			# renderer uses, and the same 36-way bucketing hulls get).
			var count: int = entry["frames"]
			var a: float = fposmod(facing, TAU)
			_draw_sprite(entry, pos, int(round(a / TAU * count)) % count, tint)
		else:
			# A spinning mine animates its strip; a single-frame shot just points
			# where it flies. Godot's +rotation is clockwise on screen, which is
			# the same sense as the engine's compass heading, so `facing` is the
			# rotation directly.
			var frame := int(_effect_clock() * 15.0) % maxi(entry["frames"], 1) if spins else 0
			_draw_sprite_rotated(entry, pos, frame, facing, tint)
		i += 3
		n += 1


func _draw_beams(center: Vector2, pw: Vector2) -> void:
	# 13 floats per beam: x0 y0 x1 y1 width alpha r g b coronaR coronaG coronaB falloff.
	var i := 0
	while i + 12 < _beams.size():
		var a := _to_screen(Vector2(_beams[i], _beams[i + 1]), center, pw)
		var b := _to_screen(Vector2(_beams[i + 2], _beams[i + 3]), center, pw)
		var width: float = _beams[i + 4]
		var alpha: float = _beams[i + 5]
		var core := Color(_beams[i + 6], _beams[i + 7], _beams[i + 8], alpha)
		var corona := Color(_beams[i + 9], _beams[i + 10], _beams[i + 11], alpha)
		var falloff: float = _beams[i + 12]

		# BeamWidth 0 is a deliberate authoring choice meaning "corona only, no
		# centre beam" — give it real glow room instead of collapsing it to a
		# hairline. Real Nova beams ship no sprite art at all: this core→corona
		# gradient IS what makes two beam weapons look different, so draw the
		# halo first and the core over it rather than a single flat bar.
		var coreless := width <= 0.0
		var core_w := maxf(width, 1.0)
		var halo_w := core_w * (2.6 if coreless else 1.0 + 1.8 / maxf(falloff, 1.0))

		var halo := corona
		halo.a = alpha * (0.5 if coreless else 0.35)
		draw_line(a, b, halo, halo_w, true)
		if not coreless:
			draw_line(a, b, core, core_w, true)
		i += 13


func _draw_effects(center: Vector2, pw: Vector2) -> void:
	for e in _fx:
		var pos := _to_screen(e["pos"], center, pw)
		var t: float = clampf(e["age"] / maxf(e["life"], 0.001), 0.0, 1.0)
		var col: Color = e["color"]
		var kind: int = e["kind"]

		match kind:
			FX_DEBRIS, FX_SHIELD_HIT, FX_ARMOR_HIT:
				var reach: float = e["radius"] * 6.0
				var size: float = maxf(e["radius"] * (1.0 - t), 0.8)
				col.a = 1.0 - t
				for d in e["dirs"]:
					draw_circle(pos + Vector2(d.x, -d.y) * reach * t, size, col)
			FX_MUZZLE:
				col = Color(1.0, 0.95, 0.7, 1.0 - t)
				draw_circle(pos, e["radius"] * (1.0 - t * 0.5), col)
			_:
				# Explosion / death blast. Real bööm art when the data has it,
				# otherwise an expanding, fading ring of flame.
				var boom_id: int = e["boom"]
				var played := false
				if boom_id >= 0:
					var sheet = _sprite_entry(SPRITE_BOOM, boom_id)
					if sheet != null:
						var count: int = maxi(sheet["frames"], 1)
						var frame := mini(int(t * count), count - 1)
						_draw_sprite(sheet, pos, frame)
						played = true
				if not played:
					var r: float = e["radius"] * (0.4 + 1.6 * t)
					col.a = 1.0 - t
					draw_circle(pos, r, Color(col.r, col.g, col.b, col.a * 0.35))
					draw_arc(pos, r, 0.0, TAU, 24, col, maxf(2.0 * (1.0 - t), 0.5), true)


# A free-running clock for animations that loop rather than age out (spinning
# mines, animated beam art). Wall time, not sim time — these are decoration.
func _effect_clock() -> float:
	return float(Time.get_ticks_msec()) / 1000.0


# Return a cached { tex, fw, fh, cols, frames, rate } for one decoded sheet,
# building it on first use. Caches nulls too, so a spriteless id isn't
# re-queried every frame.
func _sprite_entry(kind: int, id: int):
	var key := Vector2i(kind, id)
	if _sprite_cache.has(key):
		return _sprite_cache[key]

	var info: PackedInt32Array = nova.sprite_info(kind, id)
	if info.size() < 7:
		_sprite_cache[key] = null
		return null
	var fw := info[0]
	var fh := info[1]
	var frames := info[2]
	var cols := info[3]
	var sw := info[5]
	var sh := info[6]
	var rate: int = info[7] if info.size() > 7 else 0
	if sw <= 0 or sh <= 0:
		_sprite_cache[key] = null
		return null

	var bytes: PackedByteArray = nova.sprite_rgba(kind, id)
	if bytes.size() < sw * sh * 4:
		_sprite_cache[key] = null
		return null

	var img := Image.create_from_data(sw, sh, false, Image.FORMAT_RGBA8, bytes)
	var entry := {
		"tex": ImageTexture.create_from_image(img),
		"fw": fw, "fh": fh, "cols": maxi(cols, 1), "frames": maxi(frames, 1), "rate": rate,
	}
	_sprite_cache[key] = entry
	return entry


func _sprite_src(entry: Dictionary, frame: int) -> Rect2:
	var fw: int = entry["fw"]
	var fh: int = entry["fh"]
	var cols: int = entry["cols"]
	var f: int = clampi(frame, 0, entry["frames"] - 1)
	return Rect2((f % cols) * fw, (f / cols) * fh, fw, fh)


func _draw_sprite(entry: Dictionary, pos: Vector2, frame: int,
		tint: Color = Color(1, 1, 1, 1)) -> void:
	var size := Vector2(entry["fw"], entry["fh"])
	draw_texture_rect_region(entry["tex"], Rect2(pos - size * 0.5, size),
		_sprite_src(entry, frame), tint)


# Same, but spun about its centre — for shot art that points along travel rather
# than shipping a pre-rotated sheet.
func _draw_sprite_rotated(entry: Dictionary, pos: Vector2, frame: int, spin_angle: float,
		tint: Color = Color(1, 1, 1, 1)) -> void:
	var size := Vector2(entry["fw"], entry["fh"])
	draw_set_transform(pos, spin_angle, Vector2.ONE)
	draw_texture_rect_region(entry["tex"], Rect2(-size * 0.5, size),
		_sprite_src(entry, frame), tint)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)


func _draw_starfield(stars: PackedVector2Array, pw: Vector2, parallax: float,
		col: Color, radius: float, vp: Vector2) -> void:
	var offset := Vector2(
		fposmod(-pw.x * parallax, _field.x),
		fposmod(pw.y * parallax, _field.y))
	for s in stars:
		var p := Vector2(fposmod(s.x + offset.x, vp.x), fposmod(s.y + offset.y, vp.y))
		draw_circle(p, radius, col)


func _draw_ship_primitive(pos: Vector2, angle: float, kind: int, alpha: float = 1.0) -> void:
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
	draw_colored_polygon(PackedVector2Array([nose, tail_l, tail_r]), col)


# Synthetic exhaust for hulls whose data ships no engine-glow art (and for the
# demo world's primitive ship): a short amber plume off the tail.
func _draw_thruster_flame(pos: Vector2, angle: float, alpha: float, radius: float) -> void:
	var r := maxf(radius, 4.0)
	var dir := Vector2(sin(angle), -cos(angle))
	var side := Vector2(dir.y, -dir.x)
	var tail := pos - dir * (r * 0.65)
	var flicker := randf_range(0.75, 1.15)
	var tip := tail - dir * (r * flicker)
	draw_colored_polygon(PackedVector2Array([
			tail + side * (r * 0.30),
			tail - side * (r * 0.30),
			tip,
		]), Color(1.0, 0.55, 0.18, 0.85 * alpha))
	draw_colored_polygon(PackedVector2Array([
			tail + side * (r * 0.14),
			tail - side * (r * 0.14),
			tail - dir * (r * 0.55 * flicker),
		]), Color(1.0, 0.95, 0.8, 0.9 * alpha))


# MARK: HUD — status bars, weapon readout, target panel, radar, message log.
# All values below come straight from bridge Callables (Swift's World/Ship
# state); this function only picks colors/positions and formats numbers.

const BAR_W := 170.0
const BAR_H := 14.0
const BAR_GAP := 6.0
const HUD_FONT_SIZE := 14

func _bar(pos: Vector2, frac: float, fill: Color, label: String) -> void:
	var bg := Color(0.15, 0.15, 0.18, 0.85)
	draw_rect(Rect2(pos, Vector2(BAR_W, BAR_H)), bg)
	draw_rect(Rect2(pos, Vector2(BAR_W * clampf(frac, 0.0, 1.0), BAR_H)), fill)
	draw_rect(Rect2(pos, Vector2(BAR_W, BAR_H)), Color(1, 1, 1, 0.25), false, 1.0)
	draw_string(ThemeDB.fallback_font, pos + Vector2(6, BAR_H - 3), label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_FONT_SIZE - 2, Color(1, 1, 1, 0.9))


func _draw_status_bars(vp: Vector2) -> void:
	var origin := Vector2(20, vp.y - 96)
	var shield: float = nova.player_shield_fraction()
	var armor: float = nova.player_armor_fraction()
	var fuel: float = nova.player_fuel_fraction()
	var jumps: int = nova.player_jumps_remaining()

	_bar(origin, shield, Color(0.35, 0.65, 1.0), "Shield %d%%" % int(round(shield * 100)))
	_bar(origin + Vector2(0, BAR_H + BAR_GAP), armor, Color(0.85, 0.65, 0.25), "Armor %d%%" % int(round(armor * 100)))
	_bar(origin + Vector2(0, (BAR_H + BAR_GAP) * 2), fuel, Color(0.4, 0.85, 0.5), "Fuel · %d jump%s" % [jumps, "" if jumps == 1 else "s"])


func _draw_weapon_readout(vp: Vector2) -> void:
	var pos := Vector2(vp.x * 0.5 - BAR_W * 0.5, vp.y - 40)
	if not nova.has_secondary_weapon():
		draw_string(ThemeDB.fallback_font, pos, "No Secondary Weapon",
			HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_FONT_SIZE, Color(0.7, 0.7, 0.75, 0.8))
		return

	var weapon_name: String = nova.secondary_weapon_name()
	var ammo: int = nova.secondary_weapon_ammo()
	var cooldown: float = nova.secondary_weapon_cooldown_fraction()
	var label := "%s - %d" % [weapon_name, ammo] if ammo >= 0 else weapon_name
	draw_string(ThemeDB.fallback_font, pos, label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_FONT_SIZE, Color(1, 0.9, 0.75, 0.95))
	# Ready/reload bar — full when ready to fire, drains as it just fired.
	var bar_pos := pos + Vector2(0, 6)
	draw_rect(Rect2(bar_pos, Vector2(BAR_W, 4)), Color(0.15, 0.15, 0.18, 0.85))
	draw_rect(Rect2(bar_pos, Vector2(BAR_W * (1.0 - cooldown), 4)), Color(1.0, 0.7, 0.3))


func _draw_target_panel(vp: Vector2, target_id: int) -> void:
	if target_id < 0:
		return
	var pos := Vector2(vp.x - BAR_W - 20, 130)
	var target: String = nova.target_name()
	var hostile: bool = nova.target_is_hostile()
	var shield: float = nova.target_shield_fraction()
	var armor: float = nova.target_armor_fraction()
	var dist: float = nova.target_distance()

	var name_col := Color(0.95, 0.35, 0.3) if hostile else Color(0.55, 0.8, 1.0)
	draw_string(ThemeDB.fallback_font, pos, target,
		HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_FONT_SIZE, name_col)
	draw_string(ThemeDB.fallback_font, pos + Vector2(0, 16), "%d m" % int(dist),
		HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_FONT_SIZE - 2, Color(0.8, 0.8, 0.85, 0.8))
	_bar(pos + Vector2(0, 24), shield, Color(0.35, 0.65, 1.0), "Shield %d%%" % int(round(shield * 100)))
	_bar(pos + Vector2(0, 24 + BAR_H + BAR_GAP), armor, Color(0.85, 0.65, 0.25), "Armor %d%%" % int(round(armor * 100)))


func _draw_radar(vp: Vector2, pw: Vector2) -> void:
	var rc := Vector2(vp.x - RADAR_CENTER_MARGIN.x, RADAR_CENTER_MARGIN.y)
	var sensor_range: float = nova.effective_sensor_range(RADAR_WORLD_RANGE)
	if sensor_range <= 0.0:
		sensor_range = RADAR_WORLD_RANGE
	var radar_scale := RADAR_PIXEL_RADIUS / sensor_range

	draw_circle(rc, RADAR_PIXEL_RADIUS, Color(0.08, 0.12, 0.1, 0.55))
	draw_arc(rc, RADAR_PIXEL_RADIUS, 0.0, TAU, 48, Color(0.4, 0.9, 0.5, 0.5), 1.0, true)

	# Stellars first and dimmer, so ship blips read on top of them — the same
	# ordering the original's radar uses.
	if _has_data:
		var bodies: PackedFloat32Array = nova.body_transforms()
		var i := 0
		while i + 3 < bodies.size():
			var off := Vector2(bodies[i], bodies[i + 1]) - pw
			if off.length() <= sensor_range:
				var kind := int(bodies[i + 3])
				var col: Color = BODY_COLORS[kind] if kind < BODY_COLORS.size() else BODY_COLORS[1]
				col.a = 0.55
				draw_circle(rc + Vector2(off.x, -off.y) * radar_scale, 4.0, col)
			i += 4

	var j := 0
	var n := 0
	while j + 3 < _ship_xf.size():
		if n > 0:  # index 0 is the player; drawn as the fixed center dot below.
			var world_offset := Vector2(_ship_xf[j], _ship_xf[j + 1]) - pw
			if world_offset.length() <= sensor_range:
				var blip_offset := Vector2(world_offset.x, -world_offset.y) * radar_scale
				var code: int = _ship_rel[n] if n < _ship_rel.size() else 1
				var col: Color = RELATIONSHIP_COLORS[code] if code < RELATIONSHIP_COLORS.size() else RELATIONSHIP_COLORS[1]
				draw_circle(rc + blip_offset, 2.5, col)
		j += 4
		n += 1

	draw_circle(rc, 3.0, COLOR_PLAYER)


func _draw_message_log(vp: Vector2) -> void:
	var pos := Vector2(20, vp.y - 220)
	for entry in _log:
		var t: float = entry["age"]
		var alpha := clampf(1.0 - (t / LOG_LIFETIME), 0.0, 1.0)
		draw_string(ThemeDB.fallback_font, pos, str(entry["text"]),
			HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_FONT_SIZE - 1, Color(0.9, 0.9, 0.85, alpha))
		pos.y -= 18


# In flight: prompt to land once a landable body is in reach, matching the
# Apple app's "Press L to land on X" / "Slow down to land on X" HUD text.
func _draw_land_prompt(vp: Vector2) -> void:
	var spob_name: String = nova.nearest_landable_name()
	if spob_name == "":
		return
	var ready: bool = nova.can_land_now()
	var text: String = ("Press L to land on " + spob_name) if ready else ("Slow down to land on " + spob_name)
	var col := Color(0.6, 1.0, 0.7, 0.95) if ready else Color(0.9, 0.8, 0.4, 0.9)
	var pos := Vector2(vp.x * 0.5, vp.y - 70)
	var w := ThemeDB.fallback_font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_FONT_SIZE).x
	draw_string(ThemeDB.fallback_font, pos - Vector2(w * 0.5, 0), text,
		HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_FONT_SIZE, col)


# Docked screen: a bare-bones Trade Center (real prices/credits/cargo via the
# bridge's PilotEconomy-backed calls) — the first working spaceport screen.
# Outfitter/shipyard/bar/mission-BBS are still open milestone-4 work; see
# docs/GODOT_LAYER.md.
func _draw_spaceport_placeholder(vp: Vector2) -> void:
	draw_rect(Rect2(Vector2.ZERO, vp), Color(0.05, 0.05, 0.08, 1.0))
	var origin := Vector2(60, 70)
	draw_string(ThemeDB.fallback_font, origin, "Trade Center",
		HORIZONTAL_ALIGNMENT_LEFT, -1, 26, Color(0.85, 0.9, 1.0, 1.0))

	var credits: int = nova.player_credits()
	var free: int = nova.cargo_free_tons()
	var cap: int = nova.cargo_capacity_tons()
	draw_string(ThemeDB.fallback_font, origin + Vector2(0, 28),
		"%d credits · cargo %d/%d tons free" % [credits, free, cap],
		HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_FONT_SIZE, Color(0.75, 0.8, 0.85, 0.9))

	var n: int = nova.commodity_count()
	var row_y := origin.y + 70
	if n <= 0:
		draw_string(ThemeDB.fallback_font, Vector2(origin.x, row_y), "No commodity exchange here.",
			HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_FONT_SIZE, Color(0.6, 0.6, 0.65, 0.9))
	for i in n:
		var goods: String = nova.commodity_name(i)
		var price: int = nova.commodity_price(i)
		var held: int = nova.commodity_held(i)
		var selected := i == _trade_selected
		var col := Color(1.0, 0.95, 0.7, 1.0) if selected else Color(0.8, 0.85, 0.9, 0.85)
		var prefix := "> " if selected else "  "
		draw_string(ThemeDB.fallback_font, Vector2(origin.x, row_y),
			"%s%-16s %5d cr/ton   held %d" % [prefix, goods, price, held],
			HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_FONT_SIZE, col)
		row_y += 22

	draw_string(ThemeDB.fallback_font, Vector2(origin.x, row_y + 20),
		"up/down select · B buy 1 ton · S sell 1 ton · L launch",
		HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_FONT_SIZE - 1, Color(0.6, 0.65, 0.7, 0.85))
