# Headless check for the macOS live-model path end to end: the bridge writes a small USDZ hull, opens it
# with the Apple app's own pipeline (NovaSwiftHD ModelLoader / MeshSimplifier / capTextures), exports it
# (HDFlight.swift LiveModelExport, "NVM2"), and flight/LiveHulls.gd builds the meshes and materials back.
# macOS only (the Linux bridge has no SceneKit); elsewhere it reports SKIP. Run:
#   godot --headless --path godot -s res://tests/live_model_probe_selfcheck.gd
extends SceneTree

const LiveHulls = preload("res://flight/LiveHulls.gd")

var fails := 0


func check(ok: bool, what: String) -> void:
	print(("  ok   " if ok else "  FAIL ") + what)
	if not ok:
		fails += 1


func _init() -> void:
	await process_frame
	var nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	if not nova.has_method("live_model_probe"):
		print("LIVE MODEL PROBE FAIL (bridge too old: rebuild with scripts/build-gdextension.sh)")
		quit(1)
		return
	var path := OS.get_cache_dir().path_join("live_model_probe.usdz")
	if not nova.live_model_probe_write(path):
		print("LIVE MODEL PROBE SKIP (no SceneKit in this bridge)")
		quit(0)
		return
	var lh = LiveHulls.new()
	root.add_child(lh)
	var full: PackedByteArray = nova.live_model_probe(path, 0, false)
	check(full.size() > 12 and full.decode_u32(0) == 0x4E564D32, "USDZ exported as NVM2 (%d bytes)" % full.size())
	var model: Node3D = lh._model_from_nvm2(full)
	check(model != null, "NVM2 read back")
	if model == null:
		_done(nova, lh)
		return
	var meshes: Array = model.find_children("*", "MeshInstance3D", true, false)
	check(meshes.size() == 3, "three parts (hull cone + two wings): %d" % meshes.size())
	var red := false
	var green := false
	var engine_tagged := 0
	var box := AABB()
	var first := true
	for mi in meshes:
		var m := (mi as MeshInstance3D).mesh.surface_get_material(0) as StandardMaterial3D
		if m != null and m.albedo_color.r > 0.9 and m.albedo_color.g < 0.1:
			red = true
			check(absf(m.metallic - 0.25) < 0.01 and absf(m.roughness - 0.6) < 0.01, "red wing keeps metalness 0.25 / roughness 0.6")
			check(str((mi as Node).get_meta("nova_layer", "")) == "engine", "the 'engine_pod' wing is tagged engine")
		if m != null and m.albedo_color.g > 0.9 and m.albedo_color.r < 0.1:
			green = true
			check(str((mi as Node).get_meta("nova_layer", "")) == "", "the plain wing has no effect layer")
		if str((mi as Node).get_meta("nova_layer", "")) == "engine":
			engine_tagged += 1
		var b: AABB = (mi as MeshInstance3D).get_aabb()
		box = b if first else box.merge(b)
		first = false
	check(red and green, "wing colours survive (red %s, green %s)" % [red, green])
	check(engine_tagged == 1, "exactly one engine part (%d)" % engine_tagged)
	# ModelLoader.normalized: widest horizontal extent spans -1...1, nose toward +Z.
	var half := maxf(box.size.x, box.size.z) * 0.5
	check(absf(half - 1.0) < 0.02, "normalised to radius 1 in XZ (%.3f)" % half)
	# The wings are the widest part, so the nose is short of 1; it still reaches further forward
	# (+Z) than the tail does backward.
	var cone_front := -INF
	var wing_back := INF
	for mi in meshes:
		var m := (mi as MeshInstance3D).mesh.surface_get_material(0) as StandardMaterial3D
		var bb: AABB = (mi as MeshInstance3D).get_aabb()
		var coloured := m != null and absf(m.albedo_color.r - m.albedo_color.g) > 0.5
		if coloured:
			wing_back = minf(wing_back, bb.position.z)
		else:
			cone_front = maxf(cone_front, bb.end.z)
	check(absf(cone_front - box.end.z) < 0.01 and wing_back < 0.0, "nose (the cone) toward +Z, wings behind (front %.2f, wings %.2f)" % [cone_front, wing_back])
	# Simple lighting: every lit material is Lambert.
	var simple_bytes: PackedByteArray = nova.live_model_probe(path, 0, true)
	var simple: Node3D = lh._model_from_nvm2(simple_bytes)
	var lambert := true
	if simple != null:
		for mi in simple.find_children("*", "MeshInstance3D", true, false):
			var m := (mi as MeshInstance3D).mesh.surface_get_material(0) as StandardMaterial3D
			if m != null and m.shading_mode != BaseMaterial3D.SHADING_MODE_UNSHADED \
					and m.specular_mode != BaseMaterial3D.SPECULAR_DISABLED:
				print("  info not Lambert: shading %d specular %d metallic %.2f" % [m.shading_mode, m.specular_mode, m.metallic])
				lambert = false
	check(simple != null and lambert, "simple lighting exports Lambert materials")
	if simple != null:
		simple.free()
	# Model detail Low simplifies (the cone has a smooth side worth merging).
	var low: Node3D = lh._model_from_nvm2(nova.live_model_probe(path, 3, false))
	check(low != null and _tris(low) <= _tris(model), "Low detail: %d -> %d triangles" % [_tris(model), _tris(low) if low != null else -1])
	if low != null:
		low.free()
	model.free()
	_done(nova, lh)


func _tris(n: Node) -> int:
	var t := 0
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		for s in mesh.get_surface_count():
			var idx = mesh.surface_get_arrays(s)[Mesh.ARRAY_INDEX]
			t += (idx as PackedInt32Array).size() / 3 if idx != null else 0
	return t


func _done(nova, lh) -> void:
	print("LIVE MODEL PROBE " + ("PASS" if fails == 0 else "FAIL (%d)" % fails))
	lh.queue_free()
	nova.queue_free()
	await process_frame
	quit(0 if fails == 0 else 1)
