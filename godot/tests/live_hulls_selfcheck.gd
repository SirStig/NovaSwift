# Headless check for flight/LiveHulls.gd (the Apple live-hull port): fit to the classic footprint, heading,
# view turn, bank easing and roll, screen placement and the chase pitch, with a generated glTF hull and
# a mock renderer (no game data needed). Run:
#   godot --headless --path godot -s res://tests/live_hulls_selfcheck.gd
extends SceneTree

const LiveHulls = preload("res://flight/LiveHulls.gd")

class MockNova:
	var path := ""
	var banks := true
	var pending := 0
	var asked := 0
	var effects: Array = []
	func ship_model_json(_t: int) -> String:
		asked += 1
		if pending > 0:
			pending -= 1
			return "{\"pending\":true}"
		return JSON.stringify({"ext": "glb", "path": path, "hides": true, "fit": 1.0, "pitch": 38,
			"bankRoll": 30, "exposure": 1, "banks": banks, "framesPerSet": 36,
			"overlayLayers": ["engine", "lights"], "effects": effects,
			"layerNames": {"engine": ["engine", "thruster", "exhaust"], "lights": ["light", "beacon", "nav_"],
				"weapons": ["weapon", "muzzle"]}})
	func live_hull_ceiling() -> int:
		return 3
	func sprite_info(_k: int, _t: int) -> PackedInt32Array:
		return PackedInt32Array([64, 64, 36, 6, 0, 384, 384, 0])
	func sprite_rgba(_k: int, _t: int) -> PackedByteArray:
		# every frame: an opaque 40 x 20 box centred in the 64 x 64 cell
		var b := PackedByteArray()
		b.resize(384 * 384 * 4)
		for f in 36:
			var ox := (f % 6) * 64
			var oy := (f / 6) * 64
			for y in range(22, 42):
				for x in range(12, 52):
					b[((oy + y) * 384 + ox + x) * 4 + 3] = 255
		return b

class MockShips:
	var order := PackedInt32Array([0])
	var bands := {0: 3}
	func _launch(_n: int) -> Vector2: return Vector2.ONE
	func _alpha_of(_n: int, _k: int) -> float: return 1.0

class MockCam:
	var rotation := 0.0
	var tilt := 0.0

class MockR:
	var live_3d := true
	var engine_glow := true
	var running_lights := true
	var weapon_effects := true
	var nova
	var ships = MockShips.new()
	var cam = MockCam.new()
	var zoom := 1.0
	var render_zoom := 1.0
	var base_xf := Transform2D.IDENTITY
	var ship_xf := PackedFloat32Array([0, 0, 0, 1])
	var ship_sf := PackedInt32Array([200, 0])
	var ship_ids := PackedInt32Array([7])
	var ship_layers := PackedFloat32Array()
	func get_viewport_rect() -> Rect2: return Rect2(0, 0, 800, 600)
	func world_to_screen(p: Vector2) -> Vector2: return Vector2(400 + p.x, 300 - p.y)
	func world_to_render(p: Vector2) -> Vector2: return Vector2(400 + p.x, 300 - p.y)

var fails := 0

func check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails += 1

func _init() -> void:
	# A hull 2 long (nose +Z, glTF forward), 1 wide, 0.3 tall; a marker block on the nose.
	var root := Node3D.new()
	var body := MeshInstance3D.new()
	var bm := BoxMesh.new(); bm.size = Vector3(1, 0.3, 2)
	body.mesh = bm
	root.add_child(body); body.owner = root
	var nose := MeshInstance3D.new()
	var nm := BoxMesh.new(); nm.size = Vector3(0.2, 0.2, 0.2)
	nose.mesh = nm; nose.position = Vector3(0, 0, 1.1)
	nose.name = "EngineNozzle"
	root.add_child(nose); nose.owner = root
	var doc := GLTFDocument.new(); var st := GLTFState.new()
	doc.append_from_scene(root, st)
	var path := OS.get_cache_dir().path_join("live_hull_check.glb")
	check(doc.write_to_filesystem(st, path) == OK, "wrote test glb")
	var r := MockR.new()
	r.nova = MockNova.new(); r.nova.path = path
	r.ship_layers.resize(26)
	r.ship_layers[2] = 36
	var lh = LiveHulls.new()
	get_root().add_child(lh)
	lh.setup(r)
	lh.sync(0.016)
	check(lh.covers(0), "ship 0 drawn as a live hull")
	var first_mesh: MeshInstance3D = (lh._hulls[7]["holder"] as Node).find_children("*", "MeshInstance3D", true, false)[0]
	check(first_mesh.layers & (1 << 19) != 0 and first_mesh.layers & 1 != 0, "player hull: band-3 layer and rig-1 light layer")
	check(lh._band_shown.has(3) and not lh._band_shown.has(2), "player band layer drawn, ships band idle")
	var t = lh._templates.get(200)
	check(t != null, "template loaded")
	if t == null:
		quit(1); return
	# Fit: heading 0 at pitch 38 the silhouette is 1 wide by (2.2*sin38 + 0.3*cos38)-ish tall in normalised
	# units (normalised: widest XZ = 2.2 -> radius 1). The classic extent is 40 px for every sample.
	var k: float = float(t["frame_h"]) / (2.0 * float(t["ortho"]))
	print("  info ortho %.3f  points per unit %.2f" % [t["ortho"], k])
	var hull: Dictionary = lh._hulls[7]
	var holder: Node3D = hull["holder"]
	# Project the nose marker to the screen: camera right/up give screen x / y (up).
	var cb: Basis = lh.cam.transform.basis
	var nose_world: Vector3 = _nose_pos(holder)
	var sx := nose_world.dot(cb.x); var sy := nose_world.dot(cb.y)
	check(sy > 5.0 and absf(sx) < 2.0, "heading 0: nose points up the screen (%.1f, %.1f)" % [sx, sy])
	# The longest silhouette side should match the classic 40 px extent on average over samples.
	r.ship_xf[2] = PI * 0.5
	lh.sync(0.016)
	nose_world = _nose_pos(holder)
	sx = nose_world.dot(cb.x); sy = nose_world.dot(cb.y)
	check(sx > 5.0 and absf(sy) < 2.0, "heading 90 (clockwise): nose points right (%.1f, %.1f)" % [sx, sy])
	check(absf(sx - 20.0) < 3.5, "nose sits ~half the 40 px classic extent out (%.1f)" % sx)
	# View rotation: ship_up turns the world by -heading, so the hull points up again.
	r.cam.rotation = -PI * 0.5
	lh.sync(0.016)
	nose_world = _nose_pos(holder)
	check(nose_world.dot(cb.y) > 5.0, "ship-up view: hull turned with the view")
	r.cam.rotation = 0.0
	# Bank: eases toward +1 (left turn) at 12/s and rolls about the long axis.
	r.ship_layers[9] = 1.0
	for i in 30:
		lh.sync(0.016)
	var bank: float = float(hull["bank"])
	check(bank > 0.95, "bank eased to a left turn (%.2f)" % bank)
	var roll: Node3D = hull["roll"]
	check(absf(roll.rotation.z + deg_to_rad(30.0) * bank) < 0.001, "roll = -bank * 30 deg")
	r.ship_layers[8] = 1.0   # disabled
	for i in 30:
		lh.sync(0.016)
	check(absf(float(hull["bank"])) < 0.05, "a hulk levels out")
	r.ship_layers[8] = 0.0
	r.nova.banks = false
	lh.drop_templates()
	for i in 30:
		lh.sync(0.016)
	check(absf(float(lh._hulls[7]["bank"])) < 0.001, "non-banking hull never rolls")
	# Placement: a ship 100 right / 50 up of the view centre lands there on the camera plane.
	r.ship_xf[0] = 100; r.ship_xf[1] = 50; r.ship_xf[2] = 0
	lh.sync(0.016)
	var hp: Vector3 = (lh._hulls[7]["holder"] as Node3D).position
	check(absf(hp.dot(cb.x) - 100) < 0.01 and absf(hp.dot(cb.y) - 50) < 0.01, "placed at its screen offset")
	# Chase: tilt 30 deg lowers the camera to 38 - 15 = 23 deg.
	r.cam.tilt = deg_to_rad(30.0)
	lh.sync(0.016)
	check(absf(lh._view_pitch - 23.0) < 0.001, "chase lowers the hull camera by half the tilt")
	# liveViewStretch: the layer is drawn 1/cos(tilt) taller, so a hull 50 up sits at 50*cos(tilt) in it.
	var hp2: Vector3 = (lh._hulls[7]["holder"] as Node3D).position
	check(absf(hp2.dot(lh.cam.transform.basis.y) - 50.0 * cos(deg_to_rad(30.0))) < 0.01, "chase stretch keeps hulls in place")
	var cpos: Vector3 = lh.cam.transform.origin.normalized()
	check(absf(rad_to_deg(asin(cpos.y)) - 23.0) < 0.01, "camera elevation follows")
	r.live_3d = false
	lh.sync(0.016)
	check(not lh.covers(0), "live 3D off: back to sprites")
	r.live_3d = true
	r.cam.tilt = 0.0
	_extra_checks(lh, r, path)
	await process_frame   # the renderer needs to be inside the tree for its viewport
	_tilt_checks()
	print("LIVE HULLS CHECK " + ("PASS" if fails == 0 else "FAIL (%d)" % fails))
	lh.drop_templates()
	lh.queue_free()
	root.free()
	await process_frame
	await process_frame
	quit(0 if fails == 0 else 1)

func _nose_pos(holder: Node3D) -> Vector3:
	# The nose marker's centre in stage space: walk down to the second MeshInstance3D.
	var found: Array = []
	_find(holder, holder.transform, found)
	var best := Vector3.ZERO
	for f in found:
		if (f[0] as MeshInstance3D).mesh.get_aabb().size.x < 0.5:
			best = (f[1] as Transform3D).origin
	return best

func _find(n: Node, xf: Transform3D, out: Array) -> void:
	if n is MeshInstance3D:
		out.append([n, xf])
	for c in n.get_children():
		var cx := xf * (c as Node3D).transform if c is Node3D else xf
		_find(c, cx, out)


func _extra_checks(lh, r, path: String) -> void:
	# Effect layers: the nose is named for the engine layer, and the hull has a classic engine
	# overlay, so it is dark at rest and lights with the engine-glow alpha; the classic engine
	# overlay is replaced, the lights overlay (no model content) still draws.
	lh.drop_templates()
	r.ship_xf = PackedFloat32Array([0, 0, 0, 1])
	r.nova.effects = [{"layer": "lights", "at": [0.3, 0.1, -0.5], "radius": 0.06, "color": [1, 0, 0]}]
	lh.sync(0.016)
	check(lh.hides_layer(200, "engine"), "engine overlay replaced by the mesh's own engine part")
	check(lh.hides_layer(200, "lights"), "lights overlay replaced by the pack's lights emitter")
	check(not lh.hides_layer(200, "weapons"), "weapons overlay (no model content) still draws")
	var hull: Dictionary = lh._hulls[7]
	var glows: Array = hull["glows"]
	check(glows.size() >= 2, "glow parts collected (%d)" % glows.size())
	r.ship_layers[7] = 0.0
	lh.sync(0.016)
	var eng = null
	var light = null
	for g in glows:
		if str(g["layer"]) == "engine" and not bool(g["emitter"]):
			eng = g
		if str(g["layer"]) == "lights" and bool(g["emitter"]):
			light = g
	check(eng != null and not (eng["material"] as StandardMaterial3D).emission_enabled, "engine part dark at rest")
	r.ship_layers[7] = 0.8
	lh.sync(0.016)
	check(eng != null and (eng["material"] as StandardMaterial3D).emission_enabled \
			and absf((eng["material"] as StandardMaterial3D).emission_energy_multiplier - 0.8) < 0.001, "engine part lights with its alpha")
	r.ship_layers[4] = 0.0
	lh.sync(0.016)
	check(light != null and not (light["node"] as Node3D).visible, "lights emitter off with running lights off")
	r.ship_layers[4] = 1.0
	lh.sync(0.016)
	check(light != null and (light["node"] as Node3D).visible, "lights emitter on with running lights")
	r.ship_layers[7] = 0.0
	r.ship_layers[4] = 0.0
	r.nova.effects = []
	# Pending: a model still being prepared is asked for again after 0.5 s, not every frame.
	lh.drop_templates()
	r.nova.pending = 1
	r.nova.asked = 0
	lh.sync(0.1)
	lh.sync(0.1)
	check(r.nova.asked == 1 and not lh.covers(0), "pending model: sprite meanwhile, no re-ask inside 0.5 s")
	for i in 5:
		lh.sync(0.1)
	check(lh.covers(0), "pending model drawn once ready")
	# Builds per frame and the budget: 5 ships, ceiling 3 from the bridge, 2 new hulls a frame.
	lh.drop_templates()
	lh.budget = null
	r.ship_xf = PackedFloat32Array()
	r.ship_sf = PackedInt32Array()
	r.ship_ids = PackedInt32Array()
	r.ship_layers = PackedFloat32Array()
	for i in 5:
		r.ship_xf.append_array(PackedFloat32Array([i * 40, 0, 0, 1]))
		r.ship_sf.append_array(PackedInt32Array([200, 0]))
		r.ship_ids.append(10 + i)
	r.ship_layers.resize(26 * 5)
	r.ships.order = PackedInt32Array([0, 1, 2, 3, 4])
	lh.sync(0.016)
	check(lh._hulls.size() == 2, "at most two new hulls a frame (%d)" % lh._hulls.size())
	lh.sync(0.016)
	check(lh._hulls.size() == 3 and lh.covers(0) and not lh.covers(4), "budget ceiling 3, player first")
	# Slow frames shed a quarter of what's drawing (at least one).
	for i in 30:
		lh.sync(0.05)
	check(lh.budget.allowed < 3, "slow frames shed live hulls (allowed %d)" % lh.budget.allowed)
	# Simplifier: Low detail merges a dense sphere's vertices.
	var sphere := SphereMesh.new()
	sphere.radial_segments = 64
	sphere.rings = 32
	var arrays: Array = sphere.get_mesh_arrays()
	var dense := (arrays[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	var out: Array = lh._cluster(arrays, Transform3D.IDENTITY, 1.0 / 8.0, 16.0)   # Low-ish grid on a unit sphere
	var kept := (out[Mesh.ARRAY_INDEX] as PackedInt32Array).size() / 3
	check(kept < dense and kept > 50, "simplifier: %d -> %d triangles" % [dense, kept])
	# NVM2: one triangle, one material with an engine tag, read back.
	var b := PackedByteArray()
	var put_u := func(v: int): var t := PackedByteArray(); t.resize(4); t.encode_u32(0, v); b.append_array(t)
	var put_f := func(v: float): var t := PackedByteArray(); t.resize(4); t.encode_float(0, v); b.append_array(t)
	put_u.call(0x4E564D32); put_u.call(0); put_u.call(1)
	put_u.call(3); put_u.call(1)
	for v in [0, 0, 0, 1, 0, 0, 0, 0, 1]: put_f.call(float(v))
	for v in [0, 1, 0, 0, 1, 0, 0, 1, 0]: put_f.call(float(v))
	put_u.call(1)
	put_u.call(1)   # engine
	for v in [0.5, 0.25, 1.0, 1.0]: put_f.call(v)
	put_u.call(0xFFFFFFFF); put_f.call(0.7); put_u.call(0xFFFFFFFF); put_f.call(0.3); put_u.call(0xFFFFFFFF)
	for v in [0.0, 0.0, 0.0]: put_f.call(v)
	put_u.call(0xFFFFFFFF); put_u.call(0xFFFFFFFF); put_u.call(0); put_u.call(1); put_f.call(1.0)
	put_u.call(2); put_u.call(1)   # metal from blue, roughness from green (a packed ORM map)
	put_u.call(3); put_u.call(0); put_u.call(1); put_u.call(2)
	var model: Node3D = lh._model_from_nvm2(b)
	var mi: MeshInstance3D = model.get_child(0) if model != null and model.get_child_count() > 0 else null
	check(mi != null and str(mi.get_meta("nova_layer", "")) == "engine", "NVM2: geometry read with its layer tag")
	if mi != null:
		var m := mi.mesh.surface_get_material(0) as StandardMaterial3D
		check(m != null and absf(m.metallic - 0.7) < 0.001 and absf(m.roughness - 0.3) < 0.001 \
				and m.cull_mode == BaseMaterial3D.CULL_DISABLED and absf(m.albedo_color.g - 0.25) < 0.001 \
				and m.metallic_texture_channel == BaseMaterial3D.TEXTURE_CHANNEL_BLUE \
				and m.roughness_texture_channel == BaseMaterial3D.TEXTURE_CHANNEL_GREEN, "NVM2: material fields")
	check(lh._model_from_nvm2(b.slice(0, b.size() - 6)) == null, "NVM2: a truncated dump is refused")
	var bad := b.duplicate()
	bad.encode_u32(bad.size() - 4, 7)   # last index past the 3 vertices
	check(lh._model_from_nvm2(bad) == null, "NVM2: an index past the vertices is refused")
	# glTF: a model that reaches outside its folder is not opened.
	var evil := OS.get_cache_dir().path_join("evil_hull.gltf")
	var ef := FileAccess.open(evil, FileAccess.WRITE)
	ef.store_string(JSON.stringify({"asset": {"version": "2.0"}, "buffers": [{"uri": "../../../../etc/passwd", "byteLength": 4}]}))
	ef.close()
	check(not lh._gltf_refs_contained(evil), "glTF: a '../' buffer URI is refused")
	var good := OS.get_cache_dir().path_join("live_hull_check.glb")
	check(lh._gltf_refs_contained(good), "glTF: a self-contained .glb is accepted")
	if model != null:
		model.free()


## FlightRenderer's chase tilt against CameraTilt.project/unproject (CameraRig.swift).
func _tilt_checks() -> void:
	var FR = load("res://flight/FlightRenderer.gd")
	get_root().size = Vector2i(1280, 800)   # headless starts at 0 x 0
	var fr = FR.new()
	get_root().add_child(fr)
	var vp: Vector2 = fr.get_viewport_rect().size
	fr.play_ctr = vp * 0.5
	fr.cam.tilt = deg_to_rad(30.0)
	var a := deg_to_rad(30.0)
	var k2 := 2.0 * 1.2
	fr.tilt_overscan = (k2 + sin(a)) / (k2 * cos(a))
	var worst := 0.0
	for pt in [Vector2(10, 20), Vector2(-200, 150), Vector2(300, -250), vp * 0.5]:
		var seen: Vector2 = fr._tilt_project(pt)
		worst = maxf(worst, (fr._tilt_unproject(seen) - pt).length())
	check(worst < 0.01, "tilt: unproject inverts project (%.4f px)" % worst)
	# Apple's formula on the overscanned scene, by hand, for one point 100 up of centre.
	var h: float = vp.y * fr.tilt_overscan
	var d := 1.2 * h
	var p: Vector2 = Vector2(0, 100) * float(fr.tilt_overscan)
	var k: float = d / (d + p.y * sin(a))
	var want := Vector2(fr.play_ctr.x, fr.play_ctr.y - p.y * cos(a) * k)
	var got: Vector2 = fr._tilt_project(fr.play_ctr + Vector2(0, -100))
	check((got - want).length() < 0.01, "tilt: matches CameraTilt.project (%.2f, %.2f)" % [got.x, got.y])
	var up_d: float = fr.play_ctr.y - fr._tilt_project(fr.play_ctr + Vector2(0, -100)).y
	var down_d: float = fr._tilt_project(fr.play_ctr + Vector2(0, 100)).y - fr.play_ctr.y
	check(up_d < down_d, "tilt: the top recedes (%.1f up vs %.1f down)" % [up_d, down_d])
	fr.queue_free()
