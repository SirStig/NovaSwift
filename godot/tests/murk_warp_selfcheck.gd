# Headless check of F1 (murk: per-sprite distance fog on stellars, ships and shots; star level) and F2
# (NPC hyperspace warp-in / warp-out and gate fade vs the Apple scene). Run:
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/murk_warp_selfcheck.gd
# Apple reference: GameScene.updateMurkFog / applyMurk (shots, hulls, stellars), warpOutNode (a departing ship
# just vanishes), applyEntrance(.warpIn) (nothing), applyGateFade (hidden + white wash from the AI record).
extends SceneTree

const Renderer = preload("res://flight/FlightRenderer.gd")

var nova
var rend
var _fails: int = 0


func _ok(cond: bool, what: String) -> void:
	print(("PASS " if cond else "FAIL ") + what)
	if not cond:
		_fails += 1


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	await process_frame
	nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	var data: String = OS.get_environment("NOVA_DATA_DIR")
	if data == "":
		data = ProjectSettings.globalize_path("res://") + "../data/base"
	_ok(nova.load_game(data), "load_game")
	var holder := Node2D.new()
	root.add_child(holder)

	# --- F1: find a system with murk and fly in it ------------------------------------------------
	var murky: int = -1
	var ids: PackedInt32Array = nova.debug_system_ids()
	for id in ids:
		if nova.make_world(id) and nova.system_murk() > 0:
			murky = id
			break
	if murky < 0:
		print("  note no murky system in this data set; murk checks skipped")
	else:
		rend = Renderer.new()
		holder.add_child(rend)
		rend.has_data = true
		rend.setup(nova)
		rend.reset_world()
		for i in 5:
			nova.step(1.0 / 30.0)
		var fired: bool = false
		for i in 60:
			nova.set_intent(false, false, false, false, false, true, false)
			nova.step(1.0 / 30.0)
			rend.frame(1.0 / 30.0, 0.0, true)
			if nova.projectile_transforms().size() >= 3:
				fired = true
				break
		if fired and nova.has_method("projectile_fog"):
			var fog: PackedFloat32Array = nova.projectile_fog()
			var shots: int = nova.projectile_transforms().size() / 3
			_ok(fog.size() == shots or fog.is_empty(), "projectile_fog has one level per shot (or none: effective murk 0)")
			var in_range: bool = true
			for f in fog:
				if f < 0.0 or f > 31.0:
					in_range = false
			_ok(in_range, "shot fog levels stay in 0...31")
			# Far from the player the level rises with distance^2 (MurkFog.level): shoot, then teleport away.
		elif not nova.has_method("projectile_fog"):
			print("  note bridge without projectile_fog (rebuild the bridge); shot fog checks skipped")
		var states: PackedFloat32Array = nova.stellar_states()
		var any_fog: bool = false
		var i2: int = 2
		while i2 < states.size():
			if states[i2] > 0.0:
				any_fog = true
			i2 += 3
		print("  info stellar rows carry fog levels (any > 0 here: %s)" % str(any_fog))
		_ok(states.size() % 3 == 0, "stellar_states rows are [frame, destroyed, fog]")
		var tint: int = nova.star_tint(nova.system_murk())
		_ok(tint >= 2 and tint <= 29, "star tint level is within 2...29 for murk > 0 (%d)" % tint)
		_ok(nova.star_tint(-5) >= 0, "star_tint accepts a negative murk (stars are hidden by the drawer)")
		rend.queue_free()

	# --- F2: warp effects equal the Apple scene's (none), gate fade is hidden + white -------------------
	_ok(nova.make_world(-1), "make_world for the warp checks")
	rend = Renderer.new()
	holder.add_child(rend)
	rend.has_data = true
	rend.setup(nova)
	rend.reset_world()
	for i in 3:
		nova.step(1.0 / 30.0)
		rend.frame(1.0 / 30.0, 0.0, true)
	var before: int = nova.ship_count()
	var spawned: int = nova.debug_spawn_arrival(nova.player_ship_type(), 0)
	_ok(spawned >= 0 and nova.ship_count() == before + 1, "a hyperspace arrival adds a ship")
	var stride: int = nova.ship_layer_stride()
	var layers: PackedFloat32Array = nova.ship_layers()
	var sids: PackedInt32Array = nova.ship_ids()
	var n: int = sids.find(spawned)
	_ok(n >= 0 and (n + 1) * stride <= layers.size(), "the arrival has a layer row")
	if n >= 0 and (n + 1) * stride <= layers.size():
		_ok(layers[n * stride + 19] == 0.0 and layers[n * stride + 20] == 0.0,
			"warp-in draws no gate fade (not hidden, no white wash): the original draws nothing for a jump arrival")
	var fx_text: String = FileAccess.get_file_as_string("res://flight/EffectsDrawer.gd")
	_ok(not fx_text.contains("FX_WARP") and not fx_text.to_lower().contains("warp_out") and not fx_text.to_lower().contains("warpin"),
		"EffectsDrawer has no warp-in / warp-out effect (Apple warpOutNode just removes the node)")
	var ship_text: String = FileAccess.get_file_as_string("res://flight/ShipDrawer.gd")
	_ok(ship_text.contains("C_GATE_HIDDEN") and ship_text.contains("C_BLEND"),
		"ShipDrawer honours the gate-hidden column and the white wash through the blend slot (applyGateFade)")
	# A ship that jumps away is gone from the next snapshot: no ghost, nothing left drawing.
	var gone: bool = false
	for i in 600:
		nova.step(1.0 / 30.0)
		if nova.ship_ids().find(spawned) < 0:
			gone = true
			break
	print("  info arrival NPC left the system within 20 s of sim: %s (depends on its AI)" % str(gone))
	_ok(rend.ships.ghosts.is_empty(), "no warp ghost is ever queued (only landings shrink into a stellar)")
	print("murk_warp_selfcheck: %d failure(s)" % _fails)
	quit(1 if _fails > 0 else 0)
