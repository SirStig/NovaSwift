# Headless performance benchmark for the flight view: launch from a planet, hyperjump arrival, and N
# frames of steady flight in a busy system, with the time split into bridge calls (per method) and
# GDScript drawing (per layer). Headless has no GPU, so this measures CPU only: bridge marshalling,
# sprite decode / texture creation, and the GDScript draw loops (the draw_* commands are recorded, not
# rasterised). It also counts draw commands per layer, a proxy for the GPU's batch count.
#   NOVA_DATA_DIR=$PWD/data/base NOVA_PILOTS_DIR=/some/scratch godot --headless --path godot -s res://tests/perf_bench.gd
# Prints a PERF table; exit 0 always (it is a measurement, not a pass/fail check).
extends SceneTree

const FlightRenderer = preload("res://flight/FlightRenderer.gd")

var nova
var fr: Node2D
var layer_ms: Array = []
var _prewarm := OS.get_environment("PERF_PREWARM") != "0"
var layer_names: Array = ["world", "fogW", "hulls", "fogS", "glows", "shots", "fxAdd", "beams", "fx"]


func _init() -> void:
	_run()


func _ms(t0: int) -> float:
	return float(Time.get_ticks_usec() - t0) / 1000.0


func _j(t: String):
	return JSON.parse_string(t)


## Wrap each layer's draw callable so the time spent inside it is accumulated.
func _instrument() -> void:
	layer_ms.clear()
	var i := 0
	for l in fr._layers:
		layer_ms.append(0.0)
		var orig: Callable = l.draw_fn
		var idx := i
		l.draw_fn = func(ci: CanvasItem) -> void:
			var t0 := Time.get_ticks_usec()
			orig.call(ci)
			layer_ms[idx] += float(Time.get_ticks_usec() - t0) / 1000.0
		i += 1


func _layer_sum() -> float:
	var s := 0.0
	for v in layer_ms:
		s += v
	return s


func _reset_layer_ms() -> void:
	for i in layer_ms.size():
		layer_ms[i] = 0.0


## One displayed frame: sim step + renderer frame, then let the engine run the layers' _draw.
func _frame(dt: float) -> Dictionary:
	var t0 := Time.get_ticks_usec()
	nova.set_intent(false, false, true, false, false, false, false)
	nova.step(dt)
	var t_step := _ms(t0)
	var t1 := Time.get_ticks_usec()
	fr.frame(dt, 0.0, true)
	var t_frame := _ms(t1)
	_reset_layer_ms()
	var t2 := Time.get_ticks_usec()
	await process_frame
	var t_draw_wall := _ms(t2)
	return {"step": t_step, "frame": t_frame, "draw": _layer_sum(), "wall": t_draw_wall}


func _stats(label: String, xs: Array) -> void:
	if xs.is_empty():
		return
	var s := xs.duplicate()
	s.sort()
	var sum := 0.0
	for v in s:
		sum += v
	print("  %-34s avg %7.3f  p50 %7.3f  p95 %7.3f  max %8.3f ms  (n=%d)" % [label, sum / s.size(),
		s[s.size() / 2], s[int(s.size() * 0.95)], s[s.size() - 1], s.size()])


func _first_frames(label: String, n: int) -> void:
	var out: Array = []
	for i in n:
		var r: Dictionary = await _frame(1.0 / 60.0)
		out.append(float(r["frame"]) + float(r["step"]) + float(r["draw"]))
	var parts := []
	for v in out:
		parts.append("%.1f" % v)
	print("  %-34s first %d frames (step+frame+draw ms): %s" % [label, n, ", ".join(parts)])


func _run() -> void:
	nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	var data := OS.get_environment("NOVA_DATA_DIR")
	if data == "":
		data = ProjectSettings.globalize_path("res://") + "../data/base"
	var dir := OS.get_user_data_dir() + "/perf_bench"
	var t := Time.get_ticks_usec()
	if not nova.load_game(data):
		print("PERF: no data at ", data)
		quit(0)
		return
	print("load_game               %8.1f ms" % _ms(t))
	print("prewarm: ", _prewarm, "   bridge: ", "release" if nova.has_method("prewarm_target") else "old")
	var scen = _j(nova.pilot_scenarios())
	var pid: String = nova.pilot_create(dir, int(scen[0].id), "Perf", true, "", "")
	t = Time.get_ticks_usec()
	nova.make_world(-1)
	print("make_world(start)       %8.1f ms" % _ms(t))

	fr = FlightRenderer.new()
	root.add_child(fr)
	fr.setup(nova)
	fr.has_data = true
	_instrument()
	t = Time.get_ticks_usec()
	fr.reset_world()
	print("reset_world             %8.1f ms" % _ms(t))
	await _first_frames("first frames after load", 6)

	# -- (a) launch from a planet -----------------------------------------------------------------
	print("== launch ==")
	for rep in 3:
		var lands: PackedInt32Array = nova.debug_land_targets()
		if lands.is_empty():
			print("  no landable stellar")
			break
		nova.debug_dock_at(lands[0])
		# A docked player spends seconds in the spaceport: the renderer warms the launch system meanwhile.
		for i in 60:
			if _prewarm:
				fr.prewarm_step(4.0)
			await process_frame
		t = Time.get_ticks_usec()
		nova.launch()
		var t_launch := _ms(t)
		t = Time.get_ticks_usec()
		fr.reset_world()
		var t_reset := _ms(t)
		print("  launch #%d: nova.launch %.1f ms, renderer.reset_world %.1f ms" % [rep + 1, t_launch, t_reset])
		await _first_frames("after launch #%d" % [rep + 1], 5)

	# -- (b) hyperjump arrival ----------------------------------------------------------------------
	print("== hyperjump ==")
	for rep in 3:
		nova.nav_refresh()
		var start: int = nova.nav_current_system()
		var links: PackedInt32Array = nova.nav_links()
		var dest := -1
		for i in range(0, links.size(), 2):
			if links[i] == start:
				dest = links[i + 1]
				break
			if links[i + 1] == start:
				dest = links[i]
				break
		if dest < 0 or not nova.nav_click(dest):
			print("  no link")
			break
		var worst := 0.0
		var ticks := 0
		var arrived := false
		var arrive_ms := 0.0
		while ticks < 9000 and not arrived:
			nova.set_intent(false, false, true, false, false, false, false)
			if ticks % 15 == 0 and not nova.hyperjump_active():
				nova.begin_hyperjump()
			var t0 := Time.get_ticks_usec()
			nova.step(1.0 / 30.0)
			var dt := _ms(t0)
			if _prewarm and nova.hyperjump_active():
				fr.prewarm_step(3.0)
			await process_frame   # the maneuver takes seconds of wall time in the game
			worst = maxf(worst, dt)
			ticks += 1
			if nova.take_jump_arrival() != "":
				arrived = true
				arrive_ms = dt
		print("  jump #%d: arrival step %.1f ms (worst step %.1f ms) after %d ticks" % [rep + 1, arrive_ms, worst, ticks])
		t = Time.get_ticks_usec()
		fr.reset_world()
		print("    renderer.reset_world %.1f ms" % _ms(t))
		await _first_frames("after jump #%d" % [rep + 1], 5)

	# -- (c) steady flight in a busy system -----------------------------------------------------------
	print("== steady flight ==")
	var best := -1
	var best_score := -1
	var rows: PackedFloat32Array = nova.nav_systems()
	var stride: int = nova.nav_stride()
	var ids := []
	for i in range(0, rows.size() - stride + 1, stride):
		ids.append(int(rows[i]))
	for sid in ids:
		nova.make_world(sid)
		for i in 3:
			nova.step(1.0 / 30.0)
		var score: int = nova.asteroid_transforms().size() / 4 + nova.ship_count() * 4
		if score > best_score:
			best_score = score
			best = sid
	nova.make_world(best)
	fr.reset_world()
	for i in 90:
		nova.step(1.0 / 30.0)
	print("  system %d (%s): %d ships, %d asteroids, %d projectiles, %d stellars" % [best, nova.nav_system_name(best),
		nova.ship_count(), nova.asteroid_transforms().size() / 4, nova.projectile_transforms().size() / 4,
		nova.body_transforms().size() / 4])
	await _first_frames("warm-up", 30)

	var steps: Array = []
	var frames: Array = []
	var draws: Array = []
	var walls: Array = []
	var per_layer: Array = []
	for i in layer_names.size():
		per_layer.append(0.0)
	var N := 240
	for i in N:
		var r: Dictionary = await _frame(1.0 / 60.0)
		steps.append(r["step"])
		frames.append(r["frame"])
		draws.append(r["draw"])
		walls.append(r["wall"])
		for k in layer_ms.size():
			per_layer[k] += layer_ms[k]
	_stats("nova.step (sim + bridge hooks)", steps)
	_stats("renderer.frame (snapshot+camera)", frames)
	_stats("GDScript draw (all layers)", draws)
	_stats("process_frame wall", walls)
	var line := "  draw ms/frame by layer:"
	for k in layer_names.size():
		line += "  %s %.2f" % [layer_names[k], per_layer[k] / N]
	print(line)

	# bridge readbacks, one by one
	print("  bridge readbacks (avg us over 300 calls):")
	var calls := ["ship_transforms", "ship_sprite_frames", "ship_ids", "ship_relationships", "ship_visuals",
		"ship_layers", "projectile_transforms", "projectile_styles", "projectile_extra", "beam_segments",
		"beam_weapons", "asteroid_transforms", "asteroid_styles", "freeflight_transforms", "freeflight_styles",
		"body_transforms", "body_spob_ids", "stellar_states", "target_reticle", "player_target_id",
		"selected_stellar_id", "player_position", "player_velocity", "player_angle", "player_max_speed"]
	var total_us := 0.0
	for c in calls:
		var t0 := Time.get_ticks_usec()
		for k in 300:
			nova.call(c)
		var us := float(Time.get_ticks_usec() - t0) / 300.0
		total_us += us
		print("    %-26s %8.1f us" % [c, us])
	print("    %-26s %8.1f us  (%.3f ms)" % ["TOTAL snapshot", total_us, total_us / 1000.0])
	var nsteps := 300
	var t0 := Time.get_ticks_usec()
	for k in nsteps:
		nova.step(1.0 / 30.0)
	print("  pure nova.step(1/30) avg %.3f ms" % (_ms(t0) / nsteps))

	# draw command estimate
	var cmds := {"hulls": fr.ship_ids.size(), "asteroids": fr.roid_xf.size() / 4, "shots": fr.shot_xf.size() / 4,
		"stellars": fr.body_xf.size() / 4, "starfield(classic)": fr.nova.star_count(648.0), "starfield(plain)": 360}
	print("  entities drawn/frame (immediate draw_* each, x layers): ", cmds)
	print("  sprite cache entries: ", fr.sprites._cache.size())

	nova.pilot_delete(dir, pid)
	print("PERF DONE")
	quit(0)
