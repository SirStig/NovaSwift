# NOVA Swift — Godot frontend (vertical slice, milestone 3: HUD & flight).
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
# Swift is the single source of truth for game state: targeting, hostility,
# weapon readiness, fuel, sensor range are all engine calls (mirroring the
# Apple app's GameScene/GameHUDModel split) — this script only lays out pixels
# and does small numeric formatting over whatever the bridge returns, never its
# own game logic.
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

# Texture caches keyed by resource id: { id: { tex, fw, fh, cols, frames } }.
var _ship_tex := {}
var _spob_tex := {}

var _stars_near: PackedVector2Array
var _stars_far: PackedVector2Array
var _field := Vector2(4096, 4096)

# Edge-triggered keys (Tab/Q/E/Backspace act once per press, not held).
var _keys_down_last := {}

# Rolling message log: [{text, age}], newest first, oldest fades out.
var _log: Array = []
const LOG_MAX_LINES := 6
const LOG_LIFETIME := 6.0

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
# Radar/IFF relationship code (from NovaWorld.shipRelationships) -> blip color.
# 0 hostile, 1 neutral, 2 friendly/escort, 3 disabled, 4 self.
const RELATIONSHIP_COLORS := [
	Color(0.95, 0.25, 0.25),
	Color(0.35, 0.55, 0.95),
	Color(0.35, 0.9, 0.45),
	Color(0.55, 0.55, 0.6),
	COLOR_PLAYER,
]

const RADAR_CENTER_MARGIN := Vector2(120, 120)
const RADAR_PIXEL_RADIUS := 90.0
const RADAR_WORLD_RANGE := 4500.0   # matches the Apple app's own client-side radarRange

# WorldEvent case name -> message-log phrase. Only the narratively-interesting
# events surface here (matches GameHUDModel.post() on the Apple side); the
# per-frame combat/FX ones (weaponFired, shieldHit, explosion, ...) are left for
# a future sound/particle hookup, not this text log.
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

	if nova.is_landed():
		# Docked: the flight sim is paused (no set_intent/step) — only the
		# Trade Center + launch hotkeys and the message-log fade run. Mirrors
		# the Apple app's spaceport screens owning the frame while landed.
		_process_trade_hotkeys()
		_on_key_pressed(KEY_L, func(): _on_launch())
		_drain_events_to_log(delta)
		queue_redraw()
		return

	var left := Input.is_key_pressed(KEY_LEFT) or Input.is_key_pressed(KEY_A)
	var right := Input.is_key_pressed(KEY_RIGHT) or Input.is_key_pressed(KEY_D)
	var thrust := Input.is_key_pressed(KEY_UP) or Input.is_key_pressed(KEY_W)
	var reverse := Input.is_key_pressed(KEY_DOWN) or Input.is_key_pressed(KEY_S)
	var afterburner := Input.is_key_pressed(KEY_SHIFT)
	var fire_primary := Input.is_key_pressed(KEY_SPACE)
	var fire_secondary := Input.is_key_pressed(KEY_CTRL)

	nova.set_intent(left, right, thrust, reverse, afterburner, fire_primary, fire_secondary)
	nova.step(delta)

	_process_hotkeys()
	_drain_events_to_log(delta)
	_update_top_label()
	queue_redraw()


func _on_launch() -> void:
	if nova.launch():
		_push_log("Launched")


func _update_top_label() -> void:
	var hud: Label = $HUD
	var mode := "real data" if _has_data else "demo world (no data)"
	var ship_name := ""
	if _has_data:
		ship_name = nova.ship_type_name(nova.player_ship_type())
	hud.text = "NOVA Swift — Godot slice · %s%s · ships %d\n" % [
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
	var name: String = nova.nearest_landable_name()
	if nova.attempt_land():
		_trade_selected = 0
		_push_log("Docked at " + name)


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
	var name: String = nova.commodity_name(_trade_selected)
	var bought: int = nova.buy_commodity(_trade_selected, 1)
	if bought > 0:
		_push_log("Bought 1 ton " + name)


func _on_trade_sell() -> void:
	var name: String = nova.commodity_name(_trade_selected)
	var sold: int = nova.sell_commodity(_trade_selected, 1)
	if sold > 0:
		_push_log("Sold 1 ton " + name)


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

	for event_name in nova.drain_events():
		var msg: String = EVENT_MESSAGES.get(event_name, "")
		if msg != "":
			_push_log(msg)


func _draw() -> void:
	if nova == null:
		return

	var vp := get_viewport_rect().size

	if nova.is_landed():
		_draw_spaceport_placeholder(vp)
		_draw_message_log(vp)
		return

	var center := vp * 0.5
	var pw: Vector2 = nova.player_position()

	_draw_starfield(_stars_far, pw, 0.35, COLOR_STAR_FAR, 1.0, vp)
	_draw_starfield(_stars_near, pw, 0.7, COLOR_STAR_NEAR, 1.5, vp)

	if _has_data:
		_draw_bodies(center, pw)

	var target_id: int = nova.player_target_id()
	_draw_ships(center, pw, target_id)
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
		var entry = _sprite_entry(_spob_tex, spob_id, "spob")
		if entry != null:
			_draw_sprite(entry, pos, 0)
		else:
			var col: Color = BODY_COLORS[kind] if kind < BODY_COLORS.size() else BODY_COLORS[1]
			draw_circle(pos, max(radius, 6.0), col)
		i += 4
		n += 1


func _draw_ships(center: Vector2, pw: Vector2, target_id: int) -> void:
	var xf: PackedFloat32Array = nova.ship_transforms()          # [x, y, angle, kind] * N
	var sf: PackedInt32Array = nova.ship_sprite_frames()          # [shipType, frame] * N
	var ids: PackedInt32Array = nova.ship_ids()                   # entity id * N
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
		if target_id >= 0 and n < ids.size() and ids[n] == target_id:
			draw_arc(pos, SHIP_SIZE * 1.8, 0.0, TAU, 24, Color(1.0, 0.35, 0.3, 0.85), 1.5, true)
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

	var name: String = nova.secondary_weapon_name()
	var ammo: int = nova.secondary_weapon_ammo()
	var cooldown: float = nova.secondary_weapon_cooldown_fraction()
	var label := "%s - %d" % [name, ammo] if ammo >= 0 else name
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
	var name: String = nova.target_name()
	var hostile: bool = nova.target_is_hostile()
	var shield: float = nova.target_shield_fraction()
	var armor: float = nova.target_armor_fraction()
	var dist: float = nova.target_distance()

	var name_col := Color(0.95, 0.35, 0.3) if hostile else Color(0.55, 0.8, 1.0)
	draw_string(ThemeDB.fallback_font, pos, name,
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

	draw_circle(rc, RADAR_PIXEL_RADIUS, Color(0.08, 0.12, 0.1, 0.55))
	draw_arc(rc, RADAR_PIXEL_RADIUS, 0.0, TAU, 48, Color(0.4, 0.9, 0.5, 0.5), 1.0, true)

	var xf: PackedFloat32Array = nova.ship_transforms()
	var rel: PackedInt32Array = nova.ship_relationships()
	var i := 0
	var n := 0
	while i + 3 < xf.size():
		if n > 0:  # index 0 is the player; drawn as the fixed center dot below.
			var world_offset := Vector2(xf[i], xf[i + 1]) - pw
			var d := world_offset.length()
			if d <= sensor_range:
				var blip_offset := Vector2(world_offset.x, -world_offset.y) * (RADAR_PIXEL_RADIUS / sensor_range)
				var code: int = rel[n] if n < rel.size() else 1
				var col: Color = RELATIONSHIP_COLORS[code] if code < RELATIONSHIP_COLORS.size() else RELATIONSHIP_COLORS[1]
				draw_circle(rc + blip_offset, 2.5, col)
		i += 4
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
	var name: String = nova.nearest_landable_name()
	if name == "":
		return
	var ready: bool = nova.can_land_now()
	var text: String = ("Press L to land on " + name) if ready else ("Slow down to land on " + name)
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
		var name: String = nova.commodity_name(i)
		var price: int = nova.commodity_price(i)
		var held: int = nova.commodity_held(i)
		var selected := i == _trade_selected
		var col := Color(1.0, 0.95, 0.7, 1.0) if selected else Color(0.8, 0.85, 0.9, 0.85)
		var prefix := "> " if selected else "  "
		draw_string(ThemeDB.fallback_font, Vector2(origin.x, row_y),
			"%s%-16s %5d cr/ton   held %d" % [prefix, name, price, held],
			HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_FONT_SIZE, col)
		row_y += 22

	draw_string(ThemeDB.fallback_font, Vector2(origin.x, row_y + 20),
		"up/down select · B buy 1 ton · S sell 1 ton · L launch",
		HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_FONT_SIZE - 1, Color(0.6, 0.65, 0.7, 0.85))
