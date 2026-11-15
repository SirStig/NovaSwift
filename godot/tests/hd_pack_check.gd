# HD pack check for pack authors: every hull in a pack's live 3D models, built exactly the way the game
# builds it (flight/LiveHulls.gd, with the light matching the Apple app does), then checked and drawn
# beside its classic sprite. Needs a GPU, so it runs windowed, not headless. Run it with
#   scripts/hd-pack-check.sh <pack.nsx | folder of packs or plug-ins>
# which stages the pack and sets:
#   NOVA_DATA_DIR      the base game data
#   NOVA_PLUGINS_DIR   folder holding the pack(s) under test
#   NOVA_HDCHECK_OUT   folder for the report (report.txt) and contact sheet(s) (sheet-N.png)
# One line per model (ship types sharing a model are listed together), then `HDCHECK: PASS|WARN|FAIL`.
#   FAIL  the model doesn't load or builds nothing
#   WARN  most triangles face inward (flipped normals or winding), no normals (flat, unlit-looking),
#         or the light match hit its limit: much darker or brighter than the classic art, so set the
#         pack's `exposure` for that model
extends SceneTree

const LiveHulls = preload("res://flight/LiveHulls.gd")
const MAX_TYPE := 2048
const CELL := 160
const PER_SHEET := 24
const WAIT_MS := 240000


class Host:
	var nova
	var ship_layers := PackedFloat32Array()


var lines: PackedStringArray = []
var fails := 0
var warns := 0


func say(s: String) -> void:
	print(s)
	lines.append(s)


func _init() -> void:
	await process_frame
	var out := OS.get_environment("NOVA_HDCHECK_OUT")
	if out.is_empty():
		out = OS.get_cache_dir().path_join("hd-pack-check")
	DirAccess.make_dir_recursive_absolute(out)
	if DisplayServer.get_name() == "headless":
		print("HDCHECK: FAIL (needs a GPU: run without --headless)")
		quit(2)
		return
	var nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	nova.set_hd_options(false, true, 0, 0, false)
	if not nova.load_game(OS.get_environment("NOVA_DATA_DIR")):
		print("HDCHECK: FAIL (game data didn't load from NOVA_DATA_DIR)")
		quit(2)
		return
	nova.set_hd_options(false, true, 0, 0, false)
	var lh = LiveHulls.new()
	root.add_child(lh)
	var host := Host.new()
	host.nova = nova
	lh.r = host
	lh.stage = Node3D.new()
	lh.add_child(lh.stage)
	lh._env = lh._environment()

	var types: Array = []
	for t in MAX_TYPE:
		if nova.ship_model_json(t) != "":
			types.append(t)
	say("%d ship types have a live 3D model" % types.size())
	if types.is_empty():
		say("HDCHECK: FAIL (no live models: is the pack in NOVA_PLUGINS_DIR, and do its sprite ids match ships?)")
		_write(out)
		quit(1)
		return

	# Build every template through the game's own path (load, fit, light match).
	var built := {}
	var gone := {}
	var t0 := Time.get_ticks_msec()
	while built.size() + gone.size() < types.size() and Time.get_ticks_msec() - t0 < WAIT_MS:
		for t in types:
			if built.has(t) or gone.has(t):
				continue
			var p = JSON.parse_string(nova.ship_model_json(t))
			if typeof(p) == TYPE_DICTIONARY and bool((p as Dictionary).get("pending", false)):
				continue
			if typeof(p) != TYPE_DICTIONARY:
				gone[t] = true   # unavailable: failed to load
				continue
			var tpl = lh._template(t, 0)
			if tpl != null:
				built[t] = tpl
			elif not lh._matching.has(t) and float(lh._retry.get(t, 0.0)) <= 0.0:
				gone[t] = true
		for k in lh._retry.keys():
			lh._retry[k] = float(lh._retry[k]) - 0.05
		lh._match_step()
		await process_frame
	say("built in %.1f s" % ((Time.get_ticks_msec() - t0) / 1000.0))

	# One report line per model: types sharing a prepared model are grouped.
	var groups := {}
	var order: Array = []
	for t in types:
		var key := "missing:%d" % t
		if built.has(t):
			var proto: Node3D = built[t]["proto"]
			key = "%d|%.4f" % [_tris(proto), float(built[t]["ortho"])]
		if not groups.has(key):
			groups[key] = []
			order.append(key)
		(groups[key] as Array).append(t)
	var sheet_types: Array = []
	for key in order:
		var ts: Array = groups[key]
		var t: int = ts[0]
		var names := ", ".join(PackedStringArray(ts.slice(0, 6).map(func(x): return "%d %s" % [x, nova.ship_type_name(x)]))) \
				+ (" +%d more" % (ts.size() - 6) if ts.size() > 6 else "")
		if not built.has(t):
			fails += 1
			say("FAIL  %s: the model didn't load (see the log for the loader's error)" % names)
			continue
		var tpl: Dictionary = built[t]
		var proto: Node3D = tpl["proto"]
		var notes: PackedStringArray = []
		var tris := _tris(proto)
		if tris == 0:
			fails += 1
			say("FAIL  %s: the model built no triangles" % names)
			continue
		var facing := _outward(proto)
		if facing.y == 0:
			notes.append("no normals: it will look flat")
		elif facing.x * 2 < facing.y:
			notes.append("%d%% of triangles face inward: flipped normals or winding" % (100 - facing.x * 100 / facing.y))
		var light := float(tpl.get("light", 1.0))
		if bool(tpl.get("match", false)) and (light >= LiveHulls.MATCH_MAX - 0.01 or light <= LiveHulls.MATCH_MIN + 0.01):
			notes.append("light match hit its limit (%.2fx): set an exposure for this model" % light)
		var head := "WARN " if not notes.is_empty() else "ok   "
		if not notes.is_empty():
			warns += 1
		say("%s %s: %d triangles, light %s%s" % [head, names, tris,
			("matched %.2fx" % light) if bool(tpl.get("match", false)) else "set by the pack",
			("; " + "; ".join(notes)) if not notes.is_empty() else ""])
		sheet_types.append(t)

	await _sheets(nova, lh, built, sheet_types, out)
	var verdict := "FAIL" if fails > 0 else ("WARN" if warns > 0 else "PASS")
	say("HDCHECK: %s (%d models, %d warnings, %d failures) report and sheets in %s" % [verdict, order.size(), warns, fails, out])
	_write(out)
	quit(1 if fails > 0 else 0)


func _write(out: String) -> void:
	var f := FileAccess.open(out.path_join("report.txt"), FileAccess.WRITE)
	if f != null:
		f.store_string("\n".join(lines) + "\n")


static func _tris(n: Node) -> int:
	var t := 0
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		if (mi as Node).has_meta("nova_emitter"):
			continue
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		for s in mesh.get_surface_count():
			var idx = mesh.surface_get_arrays(s)[Mesh.ARRAY_INDEX]
			t += (idx as PackedInt32Array).size() / 3 if idx != null else 0
	return t


## x: triangles facing outward for Godot (clockwise front face: (b - a) x (c - a) against the stored
## normal), y: triangles with normals measured. Sampled, so a huge hull stays quick.
static func _outward(n: Node) -> Vector2i:
	var good := 0
	var seen := 0
	for mi in n.find_children("*", "MeshInstance3D", true, false):
		if (mi as Node).has_meta("nova_emitter"):
			continue
		var mesh: Mesh = (mi as MeshInstance3D).mesh
		for s in mesh.get_surface_count():
			var arr: Array = mesh.surface_get_arrays(s)
			var nr = arr[Mesh.ARRAY_NORMAL]
			var ix = arr[Mesh.ARRAY_INDEX]
			if nr == null or ix == null or (nr as PackedVector3Array).is_empty():
				continue
			var vx: PackedVector3Array = arr[Mesh.ARRAY_VERTEX]
			var idx: PackedInt32Array = ix
			var step := maxi(3, (idx.size() / 3 / 4000) * 3)
			for k in range(0, idx.size() - 2, step):
				var fn: Vector3 = (vx[idx[k + 1]] - vx[idx[k]]).cross(vx[idx[k + 2]] - vx[idx[k]])
				if fn.length() < 1e-12:
					continue
				seen += 1
				if fn.dot((nr as PackedVector3Array)[idx[k]]) < 0.0:
					good += 1
	return Vector2i(good, seen)


## Contact sheets: each model at the game's pitch (nose up) over its classic frame 0.
func _sheets(nova, lh, built: Dictionary, types: Array, out: String) -> void:
	var page := 0
	for start in range(0, types.size(), PER_SHEET):
		var chunk: Array = types.slice(start, start + PER_SHEET)
		var vps: Array = []
		for t in chunk:
			var tpl: Dictionary = built[t]
			var v := SubViewport.new()
			v.size = Vector2i(CELL, CELL)
			v.own_world_3d = true
			v.transparent_bg = true
			v.render_target_update_mode = SubViewport.UPDATE_ONCE
			root.add_child(v)
			var env := WorldEnvironment.new()
			env.environment = lh._env
			v.add_child(env)
			var st := Node3D.new()
			v.add_child(st)
			LiveHulls._add_lights(st, tpl["key"], 0xFFFFF)
			var pivot := Node3D.new()
			pivot.rotation = Vector3(0, PI, 0)
			var copy := (tpl["proto"] as Node3D).duplicate() as Node3D
			LiveHulls._hide_emitters(copy)
			pivot.add_child(copy)
			st.add_child(pivot)
			var c := Camera3D.new()
			c.projection = Camera3D.PROJECTION_ORTHOGONAL
			c.size = 2.0 * float(tpl["ortho"])
			var a := deg_to_rad(float(tpl["pitch"]))
			var pos := Vector3(0, sin(a), cos(a)) * 50.0
			c.transform = Transform3D(LiveHulls._look_basis(-pos), pos)
			c.current = true
			v.add_child(c)
			vps.append(v)
		for i in 3:
			await process_frame
		await RenderingServer.frame_post_draw
		var cols := mini(8, chunk.size())
		var rows := int(ceil(chunk.size() / float(cols)))
		var sheet := Image.create(CELL * cols, CELL * 2 * rows, false, Image.FORMAT_RGBA8)
		sheet.fill(Color(0.02, 0.02, 0.04, 1))
		for i in chunk.size():
			var t: int = chunk[i]
			var ox := (i % cols) * CELL
			var oy := (i / cols) * CELL * 2
			var img: Image = (vps[i] as SubViewport).get_texture().get_image()
			if img != null and not img.is_empty():
				img.convert(Image.FORMAT_RGBA8)
				sheet.blend_rect(img, Rect2i(0, 0, CELL, CELL), Vector2i(ox, oy))
			var info: PackedInt32Array = nova.sprite_info(0, t)
			if info.size() >= 7 and info[0] > 0 and info[1] > 0:
				var whole := Image.create_from_data(info[5], info[6], false, Image.FORMAT_RGBA8, nova.sprite_rgba(0, t))
				var f0 := whole.get_region(Rect2i(0, 0, info[0], info[1]))
				var sc := float(CELL) / float(maxi(info[0], info[1]))
				f0.resize(maxi(1, int(info[0] * sc)), maxi(1, int(info[1] * sc)), Image.INTERPOLATE_NEAREST)
				sheet.blend_rect(f0, Rect2i(Vector2i.ZERO, f0.get_size()),
					Vector2i(ox + (CELL - f0.get_width()) / 2, oy + CELL + (CELL - f0.get_height()) / 2))
		var path := out.path_join("sheet-%d.png" % page)
		sheet.save_png(path)
		say("sheet %s: 3D (top) over classic (bottom), ship types %s" % [path, ", ".join(PackedStringArray(chunk.map(func(x): return str(x))))])
		for v in vps:
			(v as Node).queue_free()
		page += 1
