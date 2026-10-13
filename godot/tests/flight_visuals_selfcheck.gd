# Headless check for the flight visual fidelity pass (godot/flight/): per-ship shän layer state from the
# bridge (thrust -> engine glow, turning -> bank, fire -> weapon glow), NPC hyperspace arrival kinematics
# (no interpolation jump, over-speed braking to zero), stellar states, the death sequence (9 staggered bursts +
# the final blast), camera views, and a composed PNG of a hull with its layers. Run:
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/flight_visuals_selfcheck.gd
extends SceneTree

const Renderer = preload("res://flight/FlightRenderer.gd")
const Camera = preload("res://flight/FlightCamera.gd")
const Prefs = preload("res://Prefs.gd")
const Sprites = preload("res://flight/FlightSprites.gd")

var nova
var ok := true
var rend


func _init() -> void:
	_run()


func _check(label: String, cond: bool) -> bool:
	print(("  ok   " if cond else "  FAIL ") + label)
	if not cond:
		ok = false
	return cond


func _col(n: int, c: int) -> float:
	var L: PackedFloat32Array = nova.ship_layers()
	var stride: int = nova.ship_layer_stride()
	return L[n * stride + c] if (n + 1) * stride <= L.size() else NAN


func _run() -> void:
	await process_frame
	nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	var data := OS.get_environment("NOVA_DATA_DIR")
	if data == "":
		data = ProjectSettings.globalize_path("res://") + "../data/base"
	_check("load_game", nova.load_game(data))
	_check("make_world", nova.make_world(-1))
	var holder := Node2D.new()
	root.add_child(holder)
	rend = Renderer.new()
	holder.add_child(rend)
	rend.has_data = true
	rend.setup(nova)
	rend.reset_world()
	_check("layer stride is 26", nova.ship_layer_stride() == 26)

	for i in 5:
		nova.step(1.0 / 30.0)
		rend.frame(1.0 / 30.0, 0.0, true)
	_check("layer rows cover every ship", nova.ship_layers().size() == nova.ship_count() * 26)
	_check("idle player: no engine glow", _col(0, 7) == 0.0)

	# Thrust -> engine glow (low-pass flicker settles inside 0.6-1.0).
	var peak := 0.0
	for i in 40:
		nova.set_intent(false, false, true, false, false, false, false)
		nova.step(1.0 / 30.0)
		peak = maxf(peak, _col(0, 7))
	_check("thrust lights the engine glow (%.2f)" % peak, peak > 0.3)
	_check("thrust level reported", _col(0, 22) >= 1.0)

	# Turning -> bank sign (and the hull's set when its shän banks).
	var bank := 0.0
	for i in 20:
		nova.set_intent(true, false, false, false, false, false, false)
		nova.step(1.0 / 30.0)
		bank = maxf(bank, absf(_col(0, 9)))
	_check("turning reports a bank direction", bank == 1.0)
	nova.set_intent(false, false, false, false, false, false, false)

	# Running lights evolve with the blink clock for the player's hull (steady on or blinking).
	var lights_seen := false
	for i in 90:
		nova.step(1.0 / 30.0)
		lights_seen = lights_seen or _col(0, 4) > 0.0
	print("  info running lights seen on this hull: ", lights_seen)

	# Fire -> weapon glow, when the hull's weapon uses the ship sprite.
	var glow_seen := false
	var any_ship_sprite := false
	for id in range(128, 400):
		var wv: PackedFloat32Array = nova.weapon_visual(id)
		if wv.size() > 0 and wv[0] > 0.5:
			any_ship_sprite = true
			break
	for i in 30:
		nova.set_intent(false, false, false, false, false, true, false)
		nova.step(1.0 / 30.0)
		glow_seen = glow_seen or _col(0, 5) > 0.0
	nova.set_intent(false, false, false, false, false, false, false)
	print("  info weapon glow seen (hull-dependent): ", glow_seen, "  data has ship-sprite weapons: ", any_ship_sprite)

	_test_arrival()
	_test_stellars()
	_test_death_sequence()
	_test_camera()
	_test_compose()
	print("FLIGHT VISUALS SELFCHECK ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


# A hyperspace jump-in: the engine's own arrival kinematics. The ship appears AT its spawn point on the first
# drawn frame (no interpolation from elsewhere), brakes from jump-in speed to nothing over the over-speed
# column, and never teleports between frames.
func _test_arrival() -> void:
	var pp: Vector2 = nova.player_position()
	var before: int = nova.ship_count()
	var ship_type: int = nova.player_ship_type()
	var id: int = nova.debug_spawn_arrival(ship_type, 0)
	_check("arrival NPC added", id >= 0 and nova.ship_count() == before + 1)
	if id < 0:
		return
	var spawn_ok := false
	var max_jump := 0.0
	var prev := Vector2.INF
	var over0 := -1.0
	var over_end := 1.0
	for i in 120:
		nova.step(1.0 / 60.0)
		var ids: PackedInt32Array = nova.ship_ids()
		var n := ids.find(id)
		if n < 0:
			break
		var xf: PackedFloat32Array = nova.ship_transforms()
		var p := Vector2(xf[n * 4], xf[n * 4 + 1])
		if i == 0:
			spawn_ok = p.distance_to(pp + 500.0 * Vector2(sin(nova.player_angle()), cos(nova.player_angle()))) < 120.0
			over0 = _col(n, 24)
		if prev != Vector2.INF:
			max_jump = maxf(max_jump, p.distance_to(prev))
		prev = p
		over_end = _col(n, 24)
	_check("first drawn frame is at the spawn point (no interpolation jump)", spawn_ok)
	_check("jump-in over-speed reported at arrival (%.0f px/s)" % over0, over0 > 0.0)
	_check("over-speed brakes to zero", over_end == 0.0)
	_check("no teleport frame-to-frame (max step %.0f px)" % max_jump, max_jump < 400.0)


func _test_stellars() -> void:
	var bodies: PackedFloat32Array = nova.body_transforms()
	var st: PackedFloat32Array = nova.stellar_states()
	_check("stellar states: [frame, destroyed, fog] per body", st.size() == (bodies.size() / 4) * 3)
	# A destroyed stellar reports its flag.
	var ids: PackedInt32Array = nova.body_spob_ids()
	if ids.size() > 0:
		var e = rend.sprites.entry(Sprites.SPOB_DESTROYED, ids[0])
		print("  info destroyed art for first stellar: ", e != null)


func _test_death_sequence() -> void:
	var fx = rend.fx
	var base: int = fx.death_bursts
	fx._spawn_row(4, Vector2(100, 100), -1.0, 0.0, Color.WHITE)
	var n_at_start: int = fx.deaths.size()
	var t := 0.0
	var counts: Array = []
	while t < 2.2:
		fx._age_all(0.05)
		t += 0.05
		counts.append(fx.death_bursts - base)
	_check("death sequence queued", n_at_start == 1)
	_check("nine staggered bursts then the final blast = 10 (%d)" % (fx.death_bursts - base), fx.death_bursts - base == 10)
	_check("bursts are staggered, not simultaneous", counts[3] < counts[12] and counts[3] <= 2)
	_check("sequence cleaned up", fx.deaths.is_empty())
	fx.clear()


func _test_camera() -> void:
	var c = Camera.new()
	for i in 60:
		c.update("classic", 1.0, Vector2(300, 0), 400.0, Vector2(1280, 720), 0.5, 0.05)
	_check("classic camera: no rotation, no offset", c.rotation == 0.0 and c.offset == Vector2.ZERO)
	for i in 60:
		c.update("ship_up", 1.0, Vector2.ZERO, 400.0, Vector2(1280, 720), 0.5, 0.05)
	_check("ship-up turns the world by -heading (%.2f)" % c.rotation, absf(c.rotation + 1.0) < 0.01)
	var d = Camera.new()
	for i in 80:
		d.update("look_ahead", 0.0, Vector2(400, 0), 400.0, Vector2(1280, 720), 0.5, 0.05)
	_check("look-ahead leads along the flight path (%.0f px)" % d.offset.x, d.offset.x > 100.0 and absf(d.offset.y) < 1.0)
	var e = Camera.new()
	e.add_shake(Vector2(10, 0), Vector2.ZERO, 60.0)
	_check("shake decays", e.shake_offset(0.01).length() > 0.0 and e.shake_offset(1.0) == Vector2.ZERO)
	# The renderer's transform follows the Settings choice.
	var saved = Prefs.get_value("graphics", "camera_view")
	Prefs.set_value("graphics", "camera_view", 2)
	rend.refresh_settings()
	for i in 30:
		nova.set_intent(true, false, false, false, false, false, false)
		nova.step(1.0 / 30.0)
		rend.frame(1.0 / 30.0, 0.0, true)
	nova.set_intent(false, false, false, false, false, false, false)
	_check("ship-up view rotates the renderer's world transform", absf(rend.base_xf.get_rotation()) > 0.05)
	Prefs.set_value("graphics", "camera_view", 0)
	rend.refresh_settings()
	Prefs.set_value("graphics", "camera_view", saved)
	rend.refresh_settings()


# Compose the player's hull with its engine glow / lights / weapon glow into a PNG.
func _test_compose() -> void:
	var t: int = nova.player_ship_type()
	var canvas := Image.create(300, 150, false, Image.FORMAT_RGBA8)
	canvas.fill(Color(0.02, 0.02, 0.05))
	var x := 10
	for kind in [Sprites.SHIP, Sprites.ENGINE_GLOW, Sprites.LIGHTS, Sprites.WEAPON_GLOW, Sprites.SHIELD]:
		var e = rend.sprites.entry(kind, t)
		if e == null:
			continue
		var src: Image = e["tex"].get_image()
		var r: Rect2 = Sprites.src(e, 9)
		var piece := src.get_region(Rect2i(r))
		canvas.blend_rect(piece, Rect2i(Vector2i.ZERO, piece.get_size()), Vector2i(x, 40))
		x += int(r.size.x) + 8
		if x > 280:
			break
	var path := ProjectSettings.globalize_path("res://") + "../build/flight_layers_compose.png"
	DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	_check("composed hull + layers PNG", canvas.save_png(path) == OK)
	print("  info composed: ", path)
