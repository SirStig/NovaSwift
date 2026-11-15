# Live 3D hulls for ships whose graphics pack says `kind: model` and `live`.
#
# The Apple app's live hull, rebuilt in Godot (Sources/NovaSwiftHD/LiveHull.swift, LiveHullLayer, and
# ModelStage.swift; GameScene.syncLiveHull and LiveHullBudget). Every hull is posed the way the classic
# frames were shot: a fixed orthographic camera looking down at 38 degrees (the pack's `pitch`), a key
# light at the upper left, a cool fill, a rim light from behind and a dark environment for metal
# reflections, all fixed to the screen. The ship turns under the camera and banks with its turns. As in
# LiveHullLayer, one scene draws every hull: each sits at its ship's screen offset on the camera's plane,
# spaced in depth by draw order, so ten ships cost one 3D pass.
#
# Where a model comes from:
# - USDZ and the other SceneKit formats (macOS): the bridge prepares it with the Apple app's own code
#   (load, fit and light level from HDAssetPipeline.liveCalibration, MeshSimplifier and texture cap for
#   the model-detail setting) and hands over the posed geometry with materials, textures and effect-layer
#   tags ("NVM2", HDFlight.swift). The Linux bridge has no SceneKit, so those ships stay on their sprite.
# - glTF/glb (every platform): Godot opens it; this file normalises, poses, fits, simplifies and caps
#   textures the same way.
#
# Effect layers (ModelStage.setPass(.hull(baked:))): parts named for a layer (engine / lights / weapons) and
# the pack's emitters glow always, unless the hull has a classic overlay for that layer. Then they are dark
# on the hull and light with that overlay's own alpha (engine glow, running lights, weapon glow), which is
# what the Apple app's baked overlay sheet shows; the classic overlay sprite for that layer is not drawn.
#
# The 2D hull is hidden for a ship while its mesh is on screen. Launch grow stays on the sprite, because
# the mesh has no shrink animation.
extends Node

const Prefs = preload("res://Prefs.gd")
const NVM2 := 0x4E564D32
const STAGE_PITCH := 38.0                 # ModelStage.pitchDegrees default
const BANK_DEGREES := 30.0                # ModelStage.bankDegrees default
const DEPTH_SPACING := 600.0              # LiveHullLayer.depthSpacing
const MAX_DEPTH_SLOTS := 64               # LiveHullLayer.maxDepthSlots
const CAMERA_DISTANCE := DEPTH_SPACING * (MAX_DEPTH_SLOTS + 2)
const KEY_LIGHT := Vector3(-0.75, 0.85, 0.65)
const FIT_POINT_BUDGET := 20000           # vertices sampled when fitting a model to its classic footprint
const BUILDS_PER_FRAME := 2               # GameScene.liveBuildsPerFrame
const PENDING_RETRY := 0.5                # GameScene.syncLiveHull: ask again for a model still loading
# HDAssetPipeline.matchBrightness: passes, and the clamp on the total. Apple clamps at 3x; Godot's
# Compatibility renderer has no reflections without a sky background, so a metal hull can need more.
# Scaling a hull's albedo brightens its diffuse and metal reflectance but not its plain specular, so
# a dark hull converges more slowly than Apple's light scaling: two more passes.
const MATCH_PASSES := 5
const MATCH_MIN := 0.5
const MATCH_MAX := 8.0
const MATCH_FRAMES := 2                   # frames between asking for a render and reading it back
const LAYERS := ["engine", "lights", "weapons"]
# Render layers: 1-16 are light rigs (a light lights a hull sharing its bit), 17-20 the four z bands
# (each band's camera sees only its own hulls). See ShipDrawer.bands.
const RIG_LAYERS := 16
const BAND_BIT := 16
const BANDS := 4
# GameSettings.ModelDetail per menu index: [grid cells for the simplifier (0 = untouched), texture cap].
const MODEL_DETAIL := [[0, 1024], [96, 1024], [56, 512], [32, 512]]

# ShipDrawer layer-row columns this file reads.
const STRIDE := 26
const C_FPS := 2
const C_LIGHT := 4
const C_WGLOW := 5
const C_ENGINE := 7
const C_DISABLED := 8
const C_BANK := 9
const C_GATE_HIDDEN := 19


## LiveHullBudget (Sources/NovaSwiftKit/LiveHullBudget.swift): how many live hulls draw right now,
## shed when frames run slow and grown back one at a time while they're steady.
class Budget:
	const WINDOW := 1.0
	const SLOW_RATIO := 1.2
	const STEADY_RATIO := 1.05
	const WINDOWS_TO_GROW := 3
	var ceiling := 0
	var allowed := 0
	var _elapsed := 0.0
	var _frames := 0
	var _steady := 0

	func _init(c: int) -> void:
		ceiling = maxi(0, c)
		allowed = ceiling

	func frame(seconds: float, target: float, in_use: int) -> void:
		if seconds <= 0.0 or seconds >= 0.5:
			return   # a hitch (load, jump) isn't a frame rate
		_elapsed += seconds
		_frames += 1
		if _elapsed < WINDOW:
			return
		var average := _elapsed / float(_frames)
		var goal := target if target > 0.0 else 1.0 / 60.0
		_elapsed = 0.0
		_frames = 0
		if average > goal * SLOW_RATIO:
			_steady = 0
			# Shed a quarter of what's drawing (at least one), from what's in use.
			if in_use > 0:
				allowed = maxi(0, mini(allowed, in_use) - maxi(1, in_use / 4))
		elif average <= goal * STEADY_RATIO:
			_steady += 1
			if _steady >= WINDOWS_TO_GROW and allowed < ceiling:
				allowed += 1
				_steady = 0
		else:
			_steady = 0


var r
var vp: SubViewport              # band 2 (ships); owns the shared 3D world
var cam: Camera3D
var _vps: Array = []              # one SubViewport per band, all on vp's World3D
var _cams: Array = []
var _band_shown := {}             # band -> true while a hull of that band is drawn this frame
var stage: Node3D
var budget: Budget
var _sky: PanoramaSkyMaterial
var _view_pitch := STAGE_PITCH
var _rigs := {}               # rig signature -> render layer (1...20) lit by that rig
var _templates := {}          # ship type -> template Dictionary, or null (no live model)
var _retry := {}              # ship type -> seconds until a still-loading model is asked for again
var _hulls := {}              # ship id -> hull Dictionary (see _hull_for)
var _shown := {}              # ship index -> true while the mesh is the hull this frame
var _ready_view := false
var _stretch := 1.0
var _model_detail := 0
var _simple := false
var _glow_tex: Texture2D
var _plume_tex: Texture2D
var _env: Environment
# Light matching (HDAssetPipeline.calibrateLive): ship type -> template waiting for its measurement,
# the queue of those types, and the one being measured.
var _matching := {}
var _match_queue: Array = []
var _match: Dictionary = {}
var _match_vp: SubViewport
var _match_cam: Camera3D
var _match_root: Node3D


func setup(renderer) -> void:
	r = renderer


## Graphics settings the templates are built with (apple/model_detail, apple/live_lighting). A change
## drops every template, as HDGraphics does when the model detail changes.
func configure(model_detail: int, simple_lighting: bool) -> void:
	var d := clampi(model_detail, 0, MODEL_DETAIL.size() - 1)
	if d != _model_detail or simple_lighting != _simple:
		_model_detail = d
		_simple = simple_lighting
		drop_templates()
	if _sky != null:
		_sky.energy_multiplier = 0.0 if _simple else 0.5


func drop_templates() -> void:
	for k in _hulls:
		(_hulls[k]["holder"] as Node).queue_free()
	for k in _templates:
		var t = _templates[k]
		if t != null:
			((t as Dictionary)["proto"] as Node).queue_free()
	for k in _matching:
		((_matching[k] as Dictionary)["proto"] as Node).queue_free()
	_hulls.clear()
	_templates.clear()
	_retry.clear()
	_shown.clear()
	_matching.clear()
	_match_queue.clear()
	_end_match()


func covers(index: int) -> bool:
	return bool(_shown.get(index, false))


## Whether a drawn mesh replaces this ship's classic overlay for `layer` ("engine", "lights",
## "weapons"): the model has parts or emitters for it. A layer the model says nothing about keeps its
## classic overlay over the mesh.
func hides_layer(ship_type: int, layer: String) -> bool:
	var t = _templates.get(ship_type)
	return t != null and (t["present"] as Dictionary).has(layer)


## The alt (animated) overlay is the hull's own art, so a pack that hides classic overlays hides it.
func hides_alt(ship_type: int) -> bool:
	var t = _templates.get(ship_type)
	return t != null and bool(t.get("hides", false))


## Pose this frame's ships. `frame_dt` is the real frame time (the budget's input); `running` false
## while the sim is paused (banks hold still).
func sync(frame_dt: float = 0.0, running: bool = true) -> void:
	_shown.clear()
	_band_shown.clear()
	if r == null or not r.live_3d or r.nova == null:
		_hide_all()
		for v in _vps:
			(v as SubViewport).render_target_update_mode = SubViewport.UPDATE_DISABLED
		return
	if not r.nova.has_method("ship_model_json"):
		return
	_ensure_view()
	_match_step()
	if budget == null:
		budget = Budget.new(_ceiling())
	for t in _retry.keys():
		_retry[t] = float(_retry[t]) - frame_dt
	# GameScene.liveViewPitch: the chase view lays the camera back by half its tilt.
	_set_view_pitch(STAGE_PITCH - rad_to_deg(r.cam.tilt) * 0.5)
	var view: Vector2 = r.get_viewport_rect().size
	var cb: Basis = cam.transform.basis
	var stretch := 1.0 / cos(r.cam.tilt) if r.cam.tilt > 0.0001 else 1.0
	_stretch = stretch
	var n: int = r.ship_xf.size() / 4
	var depth := {}
	var order: PackedInt32Array = r.ships.order if r.ships != null else PackedInt32Array()
	for k in order.size():
		depth[order[k]] = k
	var seen := {}
	var in_use := 0
	var built := 0
	var ease_k := clampf(frame_dt * 12.0, 0.0, 1.0) if running else 0.0
	# Player first (index 0), so a full budget doesn't trade hulls back and forth between frames.
	for i in n:
		var type: int = r.ship_sf[i * 2] if i * 2 < r.ship_sf.size() else -1
		if type < 0:
			continue
		var xf := i * 4
		var row := i * STRIDE
		var has_row: bool = row + STRIDE <= r.ship_layers.size()
		# A ship inside a gate draws neither sprite nor mesh.
		if has_row and r.ship_layers[row + C_GATE_HIDDEN] > 0.5:
			continue
		var launch: Vector2 = r.ships._launch(i) if r.ships != null else Vector2.ONE
		if launch.x < 0.999:
			continue
		var kind := int(r.ship_xf[xf + 3])
		var alpha: float = (r.ships._alpha_of(i, kind) if r.ships != null else 1.0) * launch.y
		if alpha <= 0.001:
			continue
		var id: int = r.ship_ids[i] if i < r.ship_ids.size() else -1 - i
		if in_use >= budget.allowed:
			continue   # no room: the sprite draws (its hull, if any, is given back below)
		var hull = _hulls.get(id)
		if hull != null and int(hull["type"]) != type:
			(hull["holder"] as Node).queue_free()
			_hulls.erase(id)
			hull = null
		if hull == null:
			if built >= BUILDS_PER_FRAME:
				continue
			var info = _template(type, i)
			if info == null:
				continue
			hull = _hull_for(id, type, info)
			built += 1
		var tpl: Dictionary = _templates[type]
		seen[id] = true
		in_use += 1
		# Bank: banking hulls only, never a hulk (GameScene.liveBank), eased over ~0.1 s.
		var target := 0.0
		if bool(tpl["banks"]) and has_row and r.ship_layers[row + C_DISABLED] < 0.5:
			target = clampf(r.ship_layers[row + C_BANK], -1.0, 1.0)
		hull["bank"] = float(hull["bank"]) + (target - float(hull["bank"])) * ease_k
		# ModelStage.pose: yaw = pi - heading, where heading is the on-screen heading (world heading plus
		# the view's turn), clockwise from screen-up; roll = -bank * bankRoll.
		var heading: float = r.ship_xf[xf + 2] + r.cam.rotation
		(hull["pivot"] as Node3D).rotation = Vector3(0.0, PI - heading, 0.0)
		(hull["roll"] as Node3D).rotation = Vector3(0.0, 0.0, -float(hull["bank"]) * deg_to_rad(float(tpl["bank_deg"])))
		# LiveHullLayer.place: at the ship's screen offset on the camera's plane, a depth slot per draw
		# position, scaled so the model covers the classic frame's points.
		# Drawn (pre-tilt) position: the hull layer is warped with the rest of the world.
		var s: Vector2 = r.world_to_render(Vector2(r.ship_xf[xf], r.ship_xf[xf + 1]))
		# GameScene.liveViewStretch: under the chase tilt the layer is stretched by 1/cos(tilt) so the
		# perspective doesn't flatten the hulls; positions are divided back so they stay put.
		var off := Vector2(s.x - view.x * 0.5, (view.y * 0.5 - s.y) / stretch)
		var slot := float(clampi(int(depth.get(i, 0)), 0, MAX_DEPTH_SLOTS))
		var holder: Node3D = hull["holder"]
		holder.position = cb.x * off.x + cb.y * off.y + cb.z * (slot * DEPTH_SPACING)
		var k: float = float(tpl["frame_h"]) / (2.0 * float(tpl["ortho"])) / maxf(0.05, r.render_zoom)
		# A hull with its own stage (its own pitch) keeps that pitch whatever the shared camera does:
		# under an orthographic camera, leaning the model by the difference about the screen's
		# horizontal axis is the same picture.
		var lean := 0.0
		if not bool(tpl["shared"]):
			lean = deg_to_rad(float(tpl["pitch"]) - _view_pitch)
		holder.basis = Basis(Vector3.RIGHT, lean).scaled(Vector3.ONE * k) if absf(lean) > 0.0001 \
				else Basis.IDENTITY.scaled(Vector3.ONE * k)
		_apply_layers(hull, row, has_row)
		var band := clampi(int(r.ships.bands.get(i, 2)) if r.ships != null else 2, 0, BANDS - 1)
		if int(hull["band"]) != band:
			hull["band"] = band
			_set_layers(holder, int(tpl["mask"]) | (1 << (BAND_BIT + band)))
		_band_shown[band] = true
		_set_alpha(holder, alpha)
		holder.visible = true
		_shown[i] = true
	for id in _hulls.keys():
		if not seen.has(id):
			# LiveHullLayer.endFrame: a hull not placed this frame leaves the layer.
			(_hulls[id]["holder"] as Node).queue_free()
			_hulls.erase(id)
	budget.frame(frame_dt, _frame_target(), in_use)
	for b in _vps.size():
		(_vps[b] as SubViewport).render_target_update_mode = SubViewport.UPDATE_ALWAYS if _band_shown.has(b) \
				else SubViewport.UPDATE_DISABLED


## Draw one z band's hulls (ShipDrawer calls this just before that band's sprites).
func draw_band(ci: CanvasItem, band: int) -> void:
	if not _band_shown.has(band) or band >= _vps.size():
		return
	var tex := (_vps[band] as SubViewport).get_texture()
	if tex == null:
		return
	var size: Vector2 = r.get_viewport_rect().size
	ci.draw_set_transform_matrix(Transform2D.IDENTITY)
	# Stretched about the view's centre by liveViewStretch (1 when flat).
	var h := size.y * _stretch
	ci.draw_texture_rect(tex, Rect2(Vector2(0.0, (size.y - h) * 0.5), Vector2(size.x, h)), false)
	ci.draw_set_transform_matrix(r.base_xf)


# MARK: Budget

## HDGraphics.liveCeiling: the bridge answers on a Mac (Apple GPU or not, memory); elsewhere the
## LiveHullBudget.ceiling rule for a non-Apple GPU: 2 on an integrated one, 6 on a discrete one.
func _ceiling() -> int:
	if r.nova.has_method("live_hull_ceiling"):
		var c := int(r.nova.live_hull_ceiling())
		if c >= 0:
			return c
	var t := RenderingServer.get_video_adapter_type()
	if t == RenderingDevice.DEVICE_TYPE_DISCRETE_GPU:
		return 6
	if t == RenderingDevice.DEVICE_TYPE_INTEGRATED_GPU or t == RenderingDevice.DEVICE_TYPE_CPU:
		return 2
	# The Compatibility (OpenGL) renderer can't tell, so go by the adapter's name: discrete GeForce /
	# Radeon RX / Arc cards get 6; Intel graphics, AMD APUs (the Steam Deck's "AMD Custom GPU"),
	# software renderers and anything unrecognised get 2, and the budget grows from there if it can.
	var name := RenderingServer.get_video_adapter_name().to_lower()
	for k in ["geforce", "quadro", "rtx", "radeon rx", "radeon pro", "arc a", "arc b"]:
		if name.contains(k):
			return 6
	return 2


## The frame time the player asked for (graphics/frame_rate_cap), or 0 when uncapped (then 1/60).
func _frame_target() -> float:
	var cap := str(Prefs.get_value("graphics", "frame_rate_cap"))
	if cap.begins_with("fps"):
		var fps := cap.substr(3).to_int()
		if fps > 0:
			return 1.0 / float(fps)
	return 0.0


# MARK: Effect layers

## ModelStage.setPass(.hull(baked:)) plus the overlay sheets on top: a layer with a classic overlay
## lights with that overlay's alpha this frame; every other layer stays as the template built it.
func _apply_layers(hull: Dictionary, row: int, has_row: bool) -> void:
	var glows: Array = hull["glows"]
	if glows.is_empty():
		return
	var alpha := {"engine": 0.0, "lights": 0.0, "weapons": 0.0}
	if has_row:
		if r.engine_glow:
			alpha["engine"] = clampf(r.ship_layers[row + C_ENGINE], 0.0, 1.0)
		if r.running_lights:
			alpha["lights"] = clampf(r.ship_layers[row + C_LIGHT], 0.0, 1.0)
		if r.weapon_effects:
			alpha["weapons"] = clampf(r.ship_layers[row + C_WGLOW], 0.0, 1.0)
	for g in glows:
		var a: float = alpha.get(str(g["layer"]), 0.0)
		var m: StandardMaterial3D = g["material"]
		if bool(g["emitter"]):
			(g["node"] as Node3D).visible = a > 0.01
			m.albedo_color = Color(g["color"]) * a
		else:
			m.emission_enabled = a > 0.01
			m.emission_energy_multiplier = a


# MARK: Stage

func _ensure_view() -> void:
	var size := Vector2i(r.get_viewport_rect().size)
	size = Vector2i(maxi(2, size.x), maxi(2, size.y))
	if _ready_view:
		for b in _vps.size():
			if (_vps[b] as SubViewport).size != size:
				(_vps[b] as SubViewport).size = size
			(_cams[b] as Camera3D).size = float(size.y)
		return
	for b in BANDS:
		var v := SubViewport.new()
		v.transparent_bg = true
		v.render_target_update_mode = SubViewport.UPDATE_DISABLED
		v.size = size
		if b == 0:
			v.own_world_3d = true
		else:
			v.world_3d = (_vps[0] as SubViewport).world_3d
		add_child(v)
		var c := Camera3D.new()
		c.projection = Camera3D.PROJECTION_ORTHOGONAL
		c.near = 1.0
		c.far = CAMERA_DISTANCE * 2.0
		c.size = float(size.y)        # one world unit is one point of the viewport
		c.cull_mask = 1 << (BAND_BIT + b)
		c.current = true
		v.add_child(c)
		_vps.append(v)
		_cams.append(c)
	vp = _vps[2]
	cam = _cams[2]
	stage = Node3D.new()
	(_vps[0] as SubViewport).add_child(stage)
	var env := WorldEnvironment.new()
	_env = _environment()
	env.environment = _env
	stage.add_child(env)
	_rig(KEY_LIGHT)                 # the shared rig is render layer 1
	_glow_tex = ImageTexture.create_from_image(_glow_image())
	_plume_tex = ImageTexture.create_from_image(_plume_image())
	_ready_view = true
	_aim_camera()


func _set_view_pitch(p: float) -> void:
	if absf(p - _view_pitch) < 0.0001:
		return
	_view_pitch = p
	_aim_camera()


## LiveHullLayer.aimCamera: back along the pitch, looking at the origin.
func _aim_camera() -> void:
	var p := deg_to_rad(_view_pitch)
	var pos := Vector3(0.0, sin(p), cos(p)) * CAMERA_DISTANCE
	for c in _cams:
		(c as Camera3D).transform = Transform3D(_look_basis(-pos), pos)


## ModelStage.world: a screen-space direction (x right, y up, z toward the viewer) in stage space. The
## lights use the stage's own pitch, so they stay put while a chase view lowers the camera.
static func _screen_dir(v: Vector3, pitch_deg: float) -> Vector3:
	var p := deg_to_rad(pitch_deg)
	var right := Vector3(1, 0, 0)
	var toward := Vector3(0, sin(p), cos(p))
	var up := Vector3(0, cos(p), -sin(p))
	return (right * v.x + up * v.y + toward * v.z).normalized()


static func _look_basis(dir: Vector3) -> Basis:
	var d := dir.normalized()
	var up := Vector3.UP if absf(d.dot(Vector3.UP)) < 0.999 else Vector3.BACK
	return Basis.looking_at(d, up)


## ModelStage.addLights for one key-light direction: key (warm, upper left), fill (cool, lower right),
## rim (from behind), on its own render layer so it lights only its own hulls. The light level (exposure
## times LiveHullCalibration.lightScale) rides on each hull's materials instead, as LiveHullLayer does
## with its per-material `novaLight`, so rigs only differ by direction. Godot draws at most 8
## directional lights, so there are two rigs at most (6 lights); a third direction uses the default.
const MAX_RIGS := 2


func _rig(key: Vector3) -> int:
	var sig := "%.4f,%.4f,%.4f" % [key.x, key.y, key.z]
	if _rigs.has(sig):
		return int(_rigs[sig])
	var layer := _rigs.size() + 1
	if layer > mini(RIG_LAYERS, MAX_RIGS):
		return 1
	_rigs[sig] = layer
	_add_lights(stage, key, 1 << (layer - 1))
	return layer


## ModelStage.addLights: key, fill and rim at fixed screen directions. SceneKit intensity 1000 is a
## light of energy 1.
static func _add_lights(parent: Node3D, key: Vector3, mask: int) -> void:
	var specs := [
		[key, 2.1, Color(1.0, 0.97, 0.92)],
		[Vector3(0.8, -0.4, 0.4), 0.16, Color(0.55, 0.65, 0.85)],
		[Vector3(0.2, 0.6, -1.0), 0.65, Color(0.85, 0.9, 1.0)],
	]
	for spec in specs:
		var l := DirectionalLight3D.new()
		var from: Vector3 = _screen_dir(spec[0], STAGE_PITCH)
		l.transform = Transform3D(_look_basis(-from), from * 100.0)
		l.light_energy = float(spec[1])
		l.light_color = spec[2]
		l.shadow_enabled = false
		l.light_cull_mask = mask
		parent.add_child(l)


## Dim ambient and the stage's reflection map (ModelStage.environmentImage): near-black space with a soft
## warm glow toward the key light and a faint cool band, enough for metals to read as metal. Simple
## lighting turns the reflections off (HDGraphics simpleLighting: lightingEnvironment.intensity = 0).
func _environment() -> Environment:
	var e := Environment.new()
	e.background_mode = Environment.BG_CLEAR_COLOR
	e.ambient_light_source = Environment.AMBIENT_SOURCE_COLOR
	e.ambient_light_color = Color(0.6, 0.65, 0.8)
	e.ambient_light_energy = 0.025
	e.reflected_light_source = Environment.REFLECTION_SOURCE_SKY
	e.tonemap_mode = Environment.TONE_MAPPER_LINEAR
	_sky = PanoramaSkyMaterial.new()
	_sky.panorama = ImageTexture.create_from_image(_space_panorama())
	_sky.energy_multiplier = 0.0 if _simple else 0.5
	var sky := Sky.new()
	sky.sky_material = _sky
	e.sky = sky
	return e


static func _space_panorama() -> Image:
	var w := 256
	var h := 128
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	var sun := Vector3(-0.6, 0.7, 0.4).normalized()
	for y in h:
		for x in w:
			var u := float(x) / float(w)
			var v := float(y) / float(h)
			var lat := (0.5 - v) * PI
			var lon := (u - 0.5) * TAU
			var dir := Vector3(cos(lat) * sin(lon), sin(lat), cos(lat) * cos(lon))
			var glow := pow(maxf(0.0, dir.dot(sun)), 6.0) * 1.6
			var band := exp(-pow(lat / 0.25, 2.0)) * 0.08
			img.set_pixel(x, y, Color(minf(1.0, 0.02 + glow + band * 0.6),
				minf(1.0, 0.025 + glow * 0.9 + band * 0.7), minf(1.0, 0.04 + glow * 0.8 + band), 1.0))
	return img


## ModelStage.glowImage: a soft round glow (white, multiplied by the emitter colour).
static func _glow_image() -> Image:
	var size := 64
	var img := Image.create(size, size, false, Image.FORMAT_RGBA8)
	for y in size:
		for x in size:
			var dx := (float(x) + 0.5) / float(size) * 2.0 - 1.0
			var dy := (float(y) + 0.5) / float(size) * 2.0 - 1.0
			var d := sqrt(dx * dx + dy * dy)
			var core := maxf(0.0, 1.0 - d / 0.22)
			var halo := pow(maxf(0.0, 1.0 - d), 2.2)
			var v := minf(1.0, core + halo * 0.85)
			img.set_pixel(x, y, Color(v, v, v, v))
	return img


## ModelStage.plumeImage: an exhaust flame, brightest at the nozzle end (bottom row), tapering toward
## the tail (top).
static func _plume_image() -> Image:
	var w := 32
	var h := 128
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	for y in h:
		var t := float(y) / float(h - 1)
		var along := pow(t, 1.6)
		var half_width := 0.18 + 0.32 * t
		for x in w:
			var u := absf((float(x) + 0.5) / float(w) * 2.0 - 1.0)
			var across := maxf(0.0, 1.0 - pow(u / half_width, 2.0))
			var v := minf(1.0, along * across * 1.3)
			img.set_pixel(x, y, Color(v, v, v, v))
	return img


# MARK: Hulls

## holder (place, scale) -> pivot (heading) -> roll (bank) -> the template's model in roll space.
## Parts and emitters whose layer has a classic overlay get their own material, lit per frame.
func _hull_for(id: int, type: int, info: Dictionary) -> Dictionary:
	var holder := Node3D.new()
	var pivot := Node3D.new()
	var roll := Node3D.new()
	holder.add_child(pivot)
	pivot.add_child(roll)
	var model := (info["proto"] as Node3D).duplicate() as Node3D
	roll.add_child(model)
	stage.add_child(holder)
	var glows: Array = []
	_collect_glows(model, info["overlay"] as Dictionary, glows)
	var hull := {"holder": holder, "pivot": pivot, "roll": roll, "type": type, "bank": 0.0, "glows": glows,
		"band": -1}
	_hulls[id] = hull
	return hull


func _collect_glows(node: Node, overlay: Dictionary, out: Array) -> void:
	var layer := str(node.get_meta("nova_layer", ""))
	if not layer.is_empty() and overlay.has(layer):
		if node.has_meta("nova_emitter"):
			var mi := node as MeshInstance3D
			var m := ((mi.mesh as PrimitiveMesh).material as StandardMaterial3D).duplicate() as StandardMaterial3D
			mi.material_override = m
			out.append({"layer": layer, "emitter": true, "node": mi, "material": m, "color": m.albedo_color})
		elif node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
			var mi := node as MeshInstance3D
			for s in mi.mesh.get_surface_count():
				var src := mi.get_active_material(s) as StandardMaterial3D
				if src == null:
					continue
				var m := _glow_material(src)
				mi.set_surface_override_material(s, m)
				out.append({"layer": layer, "emitter": false, "node": mi, "material": m})
	for c in node.get_children():
		_collect_glows(c, overlay, out)


## A part of an overlaid layer: the hull's material with its glow switched off at rest
## (ModelStage.unlit), and as its glow the part's emission or, failing that, its colour
## (ModelStage.glowOnly), turned up by the overlay's alpha each frame.
static func _glow_material(src: StandardMaterial3D) -> StandardMaterial3D:
	var m := src.duplicate() as StandardMaterial3D
	var has_emission := src.emission_enabled and (src.emission.r + src.emission.g + src.emission.b > 0.01 \
			or src.emission_texture != null)
	if not has_emission:
		m.emission = src.albedo_color
		m.emission_texture = src.albedo_texture
	m.emission_enabled = false
	m.emission_energy_multiplier = 0.0
	return m


func _hide_all() -> void:
	for id in _hulls:
		(_hulls[id]["holder"] as Node3D).visible = false


func _template(type: int, index: int):
	if _templates.has(type):
		return _templates[type]
	if _matching.has(type) or float(_retry.get(type, 0.0)) > 0.0:
		return null
	var raw: String = r.nova.ship_model_json(type)
	var parsed = JSON.parse_string(raw)
	if typeof(parsed) == TYPE_DICTIONARY and bool((parsed as Dictionary).get("pending", false)):
		_retry[type] = PENDING_RETRY   # still being prepared: ask again shortly
		return null
	_retry.erase(type)
	var t = _load_template(type, index, parsed)
	if t != null and bool(t["match"]):
		# Drawn as the classic sprite until its light is matched (a few frames).
		_matching[type] = t
		_match_queue.append(type)
		return null
	_templates[type] = t
	return t


func _load_template(type: int, index: int, parsed):
	if typeof(parsed) != TYPE_DICTIONARY:
		return null
	var ext := str(parsed.get("ext", "")).to_lower()
	var model: Node3D = null
	var ortho := 0.0
	var light_scale := 1.0
	var info: PackedInt32Array = r.nova.sprite_info(0, type)
	var frame_w := float(info[0]) if info.size() > 1 and info[0] > 0 else 64.0
	var frame_h := float(info[1]) if info.size() > 1 and info[1] > 0 else 64.0
	var pitch := float(parsed.get("pitch", STAGE_PITCH))
	var present := {}
	for l in parsed.get("layersPresent", []):
		present[str(l)] = true
	if ext == "nvm":
		# Prepared by the bridge with the Apple pipeline: already posed in roll space, fitted and
		# light-matched (LiveHullCalibration).
		model = _model_from_nvm2(r.nova.ship_model_mesh(type))
		ortho = float(parsed.get("ortho", 0.0))
		light_scale = float(parsed.get("lightScale", 1.0))
	elif ext == "glb" or ext == "gltf":
		var visual := _load_gltf(str(parsed.get("path", "")))
		if visual != null:
			model = _posed_gltf(visual, parsed, present)
	if model == null:
		return null
	_add_emitters(model, parsed.get("effects", []), present)
	if ortho <= 0.0:
		var fps := int(parsed.get("framesPerSet", 0))
		if fps <= 0:
			var row := index * STRIDE
			fps = int(r.ship_layers[row + C_FPS]) if row + STRIDE <= r.ship_layers.size() else 36
		ortho = _fit(model, type, info, maxi(1, fps), pitch, float(parsed.get("fit", 1.0)), frame_w, frame_h)
	var exposure := float(parsed.get("exposure", 1.0))
	var light: Array = parsed.get("light", [])
	var has_light := light.size() == 3
	var key := Vector3(float(light[0]), float(light[1]), float(light[2])) if has_light else KEY_LIGHT
	# LiveHullLayer.canShare: the default pitch, key light and exposure, and no atmosphere.
	var shared := absf(pitch - STAGE_PITCH) < 0.001 and not has_light and absf(exposure - 1.0) < 0.0001 \
			and not bool(parsed.get("atmosphere", false))
	var mask := 1 << (_rig(key) - 1)
	_set_layers(model, mask)
	# A model the pack doesn't give its own exposure is light-matched to its classic art here, in the
	# renderer that draws it (the bridge's lightScale was measured in SceneKit); headless can't render.
	var light_match := bool(parsed.get("matchLight", false)) and DisplayServer.get_name() != "headless"
	_scale_light(model, exposure * (1.0 if light_match else light_scale))
	var overlay := {}
	for l in parsed.get("overlayLayers", []):
		overlay[str(l)] = true
	# Layers the model draws itself while the hull has a classic overlay for them.
	var replaced := {}
	for l in present:
		if overlay.has(l):
			replaced[l] = true
	return {
		"proto": model,
		"hides": bool(parsed.get("hides", true)),
		"banks": bool(parsed.get("banks", false)),
		"bank_deg": float(parsed.get("bankRoll", BANK_DEGREES)),
		"pitch": pitch,
		"shared": shared,
		"ortho": ortho,
		"frame_h": frame_h,
		"overlay": overlay,
		"present": replaced,
		"mask": mask,
		"key": key,
		"frame_w": frame_w,
		"match": light_match,
	}


# MARK: Light matching

## HDAssetPipeline.matchBrightness, in Godot: the hull at the classic sheet's eight sampled headings,
## under its own rig, measured like ClassicFootprint.tones and its light scaled until the median and
## upper-quartile tones match the classic art. One hull type at a time, a render every MATCH_FRAMES.
func _match_step() -> void:
	if _match.is_empty():
		while not _match_queue.is_empty() and _match.is_empty():
			_begin_match(int(_match_queue.pop_front()))
		return
	_match["wait"] = int(_match["wait"]) - 1
	if int(_match["wait"]) > 0:
		return
	var got := _rendered_tones()
	var t: Dictionary = _match["tones"]
	var total := float(_match["total"])
	if got.is_empty() or float(got["mid"]) <= 0.01:
		_finish_match()
		return
	var ratio := (float(t["mid"]) / float(got["mid"]) + float(t["high"]) / maxf(float(got["high"]), 0.01)) * 0.5
	var k := clampf(total * ratio, MATCH_MIN, MATCH_MAX) / total
	_match["pass"] = int(_match["pass"]) + 1
	if absf(k - 1.0) < 0.04 or int(_match["pass"]) >= MATCH_PASSES:
		if absf(k - 1.0) >= 0.04 and _match_root.get_child_count() > 0:
			_scale_light(_match_root.get_child(_match_root.get_child_count() - 1), k)
		_finish_match()
		return
	# The copies share the template's meshes (Node.duplicate), so scaling one scales the template too.
	if _match_root.get_child_count() > 0:
		_scale_light(_match_root.get_child(_match_root.get_child_count() - 1), k)
	_match["total"] = total * k
	_match["wait"] = MATCH_FRAMES
	_match_vp.render_target_update_mode = SubViewport.UPDATE_ONCE


func _begin_match(type: int) -> void:
	if not _matching.has(type):
		return
	var tpl: Dictionary = _matching[type]
	var raw: PackedFloat32Array = r.nova.ship_classic_tones(type) if r.nova.has_method("ship_classic_tones") \
			else PackedFloat32Array()
	if raw.size() < 4:
		_publish(type, tpl)          # nothing to match against: as the bridge prepared it
		return
	var fps := maxf(1.0, raw[2])
	var headings: Array = []
	for i in range(3, raw.size()):
		headings.append(raw[i] * TAU / fps)
	_ensure_match_view()
	var fw := maxf(1.0, float(tpl["frame_w"]))
	var fh := maxf(1.0, float(tpl["frame_h"]))
	var ortho := float(tpl["ortho"])
	# HDAssetPipeline measures at 2x; a small hull keeps that, a big one is measured at 1x.
	var sc := 2.0 if fh <= 64.0 else 1.0
	_match_vp.size = Vector2i(int(fw * sc) * headings.size(), int(fh * sc))
	_match_cam.size = 2.0 * ortho
	var p := deg_to_rad(float(tpl["pitch"]))
	var pos := Vector3(0.0, sin(p), cos(p)) * 50.0
	_match_cam.transform = Transform3D(_look_basis(-pos), pos)
	_add_lights(_match_root, tpl["key"], 0xFFFFF)
	var cell := 2.0 * ortho * fw / fh
	for i in headings.size():
		var pivot := Node3D.new()
		pivot.position = Vector3((float(i) + 0.5 - float(headings.size()) * 0.5) * cell, 0.0, 0.0)
		pivot.rotation = Vector3(0.0, PI - float(headings[i]), 0.0)
		var copy := (tpl["proto"] as Node3D).duplicate() as Node3D
		_hide_emitters(copy)
		pivot.add_child(copy)
		_match_root.add_child(pivot)
	_match = {"type": type, "tones": {"mid": raw[0], "high": raw[1]}, "total": 1.0, "pass": 0,
		"wait": MATCH_FRAMES}
	_match_vp.render_target_update_mode = SubViewport.UPDATE_ONCE


func _ensure_match_view() -> void:
	if _match_vp != null:
		return
	_match_vp = SubViewport.new()
	_match_vp.own_world_3d = true
	_match_vp.transparent_bg = true
	_match_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED
	add_child(_match_vp)
	var env := WorldEnvironment.new()
	env.environment = _env
	_match_vp.add_child(env)
	_match_cam = Camera3D.new()
	_match_cam.projection = Camera3D.PROJECTION_ORTHOGONAL
	_match_cam.keep_aspect = Camera3D.KEEP_HEIGHT
	_match_cam.near = 1.0
	_match_cam.far = 100.0
	_match_cam.current = true
	_match_vp.add_child(_match_cam)
	_match_root = Node3D.new()
	_match_vp.add_child(_match_root)


## The hull pass (ModelStage.setPass(.hull)): emitters are their overlay's, not the hull's tones.
static func _hide_emitters(node: Node) -> void:
	if node.has_meta("nova_emitter") and node is Node3D:
		(node as Node3D).visible = false
	for c in node.get_children():
		_hide_emitters(c)


## ClassicFootprint.tones over the readback: luma of every pixel more than 200/255 opaque.
func _rendered_tones() -> Dictionary:
	var tex := _match_vp.get_texture() if _match_vp != null else null
	var img: Image = tex.get_image() if tex != null else null
	if img == null or img.is_empty():
		return {}
	if img.get_format() != Image.FORMAT_RGBA8:
		img.convert(Image.FORMAT_RGBA8)
	var data := img.get_data()
	var hist := PackedInt32Array()
	hist.resize(256)
	var total := 0
	for i in range(0, data.size() - 3, 4):
		if data[i + 3] <= 200:
			continue
		hist[(int(data[i]) * 54 + int(data[i + 1]) * 183 + int(data[i + 2]) * 19) >> 8] += 1
		total += 1
	if total == 0:
		return {}
	return {"mid": _percentile(hist, total, 0.5), "high": _percentile(hist, total, 0.75)}


static func _percentile(hist: PackedInt32Array, total: int, q: float) -> float:
	var seen := 0
	for v in hist.size():
		seen += hist[v]
		if float(seen) >= q * float(total):
			return float(v) / 255.0
	return 1.0


## The template's meshes already carry the scale (shared with the measured copies).
func _finish_match() -> void:
	var type := int(_match["type"])
	var tpl = _matching.get(type)
	_end_match()
	if tpl != null:
		_publish(type, tpl)


func _end_match() -> void:
	_match = {}
	if _match_root != null:
		for c in _match_root.get_children():
			c.queue_free()
	if _match_vp != null:
		_match_vp.render_target_update_mode = SubViewport.UPDATE_DISABLED


func _publish(type: int, tpl: Dictionary) -> void:
	_matching.erase(type)
	_templates[type] = tpl


# MARK: glTF

func _load_gltf(path: String) -> Node3D:
	if path.is_empty() or not FileAccess.file_exists(path) or not _gltf_refs_contained(path):
		return null
	var doc := GLTFDocument.new()
	var state := GLTFState.new()
	if doc.append_from_file(path, state) != OK:
		return null
	return doc.generate_scene(state) as Node3D


## ModelLoader.normalized, then ModelStage's `upright` inside `yawed`, so the result is in roll space like
## the bridge's models; then the model-detail and lighting passes HDGraphics applies to a live model.
func _posed_gltf(visual: Node3D, parsed: Dictionary, present: Dictionary) -> Node3D:
	var norm := _normalized(visual)
	if norm == null:
		return null
	var upright := Node3D.new()
	upright.basis = _upright(parsed)
	upright.add_child(norm)
	var yawed := Node3D.new()
	yawed.basis = Basis(Vector3.UP, deg_to_rad(float(parsed.get("yaw", 0.0))))
	yawed.add_child(upright)
	var names: Dictionary = parsed.get("layerNames", {})
	_classify(yawed, yawed, names, present)
	var detail: Array = MODEL_DETAIL[_model_detail]
	if int(detail[0]) > 0:
		_simplify(yawed, int(detail[0]))
	_prepare_materials(yawed, int(detail[1]))
	return yawed


## A pack's glTF may only reference files beside it: its buffer and image URIs must be embedded
## (data:) or plain relative names with no "..", no absolute path and no URL scheme. Otherwise Godot
## would read whatever local file the model names.
static func _gltf_refs_contained(path: String) -> bool:
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var json_text := ""
	if path.get_extension().to_lower() == "glb":
		if f.get_length() < 20 or f.get_32() != 0x46546C67:
			return false
		f.get_32()
		f.get_32()
		var chunk_len := int(f.get_32())
		if f.get_32() != 0x4E4F534A or chunk_len <= 0 or chunk_len > f.get_length() - 20:
			return false
		json_text = f.get_buffer(chunk_len).get_string_from_utf8()
	else:
		if f.get_length() > 64 << 20:
			return false
		json_text = f.get_as_text()
	var doc = JSON.parse_string(json_text)
	if typeof(doc) != TYPE_DICTIONARY:
		return false
	for key in ["buffers", "images"]:
		var list = (doc as Dictionary).get(key, [])
		if typeof(list) != TYPE_ARRAY:
			return false
		for item in list:
			if typeof(item) != TYPE_DICTIONARY or not (item as Dictionary).has("uri"):
				continue
			var uri := str((item as Dictionary)["uri"])
			if uri.begins_with("data:"):
				continue
			var plain := uri.uri_decode()
			if plain.is_absolute_path() or plain.contains("..") or plain.contains(":") or plain.begins_with("/") \
					or plain.begins_with("\\"):
				return false
	return true


## ModelLoader.normalized: centred on its bounds, scaled so its widest horizontal (XZ) extent is 2 units.
func _normalized(visual: Node3D) -> Node3D:
	var found := _merge(visual, visual.transform)
	if found.is_empty():
		return null
	var box: AABB = found["box"]
	var half := maxf(box.size.x, box.size.z) * 0.5
	if half <= 0.0:
		return null
	var content := Node3D.new()
	content.add_child(visual)
	content.position = -(box.position + box.size * 0.5)
	var holder := Node3D.new()
	holder.add_child(content)
	holder.scale = Vector3.ONE / half
	return holder


## ModelStage: the 3x3 `orientation` (rows map model axes; Basis takes columns), else the Euler `rotate`
## (X applied first, then Y, then Z), else a tilt about X.
func _upright(parsed: Dictionary) -> Basis:
	var o: Array = parsed.get("orientation", [])
	var rot: Array = parsed.get("rotate", [])
	if o.size() == 9:
		return Basis(
			Vector3(float(o[0]), float(o[3]), float(o[6])),
			Vector3(float(o[1]), float(o[4]), float(o[7])),
			Vector3(float(o[2]), float(o[5]), float(o[8])))
	if rot.size() == 3:
		return Basis(Vector3.BACK, deg_to_rad(float(rot[2]))) \
				* Basis(Vector3.UP, deg_to_rad(float(rot[1]))) \
				* Basis(Vector3.RIGHT, deg_to_rad(float(rot[0])))
	return Basis(Vector3.RIGHT, deg_to_rad(float(parsed.get("tilt", 0.0))))


## ModelStage.prepareEffects' classify: a part belongs to the first layer whose name substrings
## (the pack's `layers`, else engine/thruster/exhaust, light/beacon/nav_, weapon/muzzle) appear in its
## material or node names up to the model root.
func _classify(node: Node, root: Node, names: Dictionary, present: Dictionary) -> void:
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var found: Array = []
		var m := (node as MeshInstance3D).mesh
		for s in m.get_surface_count():
			var mat := m.surface_get_material(s)
			if mat != null and not mat.resource_name.is_empty():
				found.append(mat.resource_name.to_lower())
		var n: Node = node
		while n != null and n != root:
			found.append(str(n.name).to_lower())
			n = n.get_parent()
		for layer in LAYERS:
			var keys: Array = names.get(layer, [])
			var hit := false
			for nm in found:
				for k in keys:
					if str(nm).contains(str(k)):
						hit = true
			if hit:
				node.set_meta("nova_layer", layer)
				present[layer] = true
				break
	for c in node.get_children():
		_classify(c, root, names, present)


## MeshSimplifier (vertex clustering): the model's space is cut into `cells` cubes across its widest
## side; corners in one cube that face the same octant and sit in the same patch of their texture merge
## into their average, and triangles that collapse go. Materials are kept per surface.
func _simplify(root: Node3D, cells: int) -> void:
	var found := _merge(root, Transform3D.IDENTITY)
	if found.is_empty():
		return
	var box: AABB = found["box"]
	var extent := maxf(box.size.x, maxf(box.size.y, box.size.z))
	if cells <= 0 or extent <= 0.0:
		return
	_simplify_walk(root, Transform3D.IDENTITY, extent / float(cells), float(cells * 2), root)


func _simplify_walk(node: Node, parent: Transform3D, cell: float, uv_cells: float, root: Node) -> void:
	var xf := parent
	if node is Node3D and node != root:
		xf = parent * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null:
		var mi := node as MeshInstance3D
		var out := ArrayMesh.new()
		for s in mi.mesh.get_surface_count():
			if mi.mesh.surface_get_primitive_type(s) != Mesh.PRIMITIVE_TRIANGLES:
				continue
			var a: Array = mi.mesh.surface_get_arrays(s)
			var simplified := _cluster(a, xf, cell, uv_cells)
			out.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, simplified)
			out.surface_set_material(out.get_surface_count() - 1, mi.get_active_material(s))
		if out.get_surface_count() > 0:
			mi.mesh = out
	for c in node.get_children():
		_simplify_walk(c, xf, cell, uv_cells, root)


static func _cluster(a: Array, xf: Transform3D, cell: float, uv_cells: float) -> Array:
	var verts: PackedVector3Array = a[Mesh.ARRAY_VERTEX]
	var norms: PackedVector3Array = a[Mesh.ARRAY_NORMAL] if a[Mesh.ARRAY_NORMAL] != null else PackedVector3Array()
	var uvs: PackedVector2Array = a[Mesh.ARRAY_TEX_UV] if a[Mesh.ARRAY_TEX_UV] != null else PackedVector2Array()
	var idx: PackedInt32Array = a[Mesh.ARRAY_INDEX] if a[Mesh.ARRAY_INDEX] != null else PackedInt32Array()
	if idx.is_empty():
		idx.resize(verts.size())
		for i in verts.size():
			idx[i] = i
	var has_n := norms.size() == verts.size()
	var has_uv := uvs.size() == verts.size()
	var index := {}
	var acc_p := PackedVector3Array()
	var acc_n := PackedVector3Array()
	var acc_uv := PackedVector2Array()
	var members := PackedFloat32Array()
	var out_idx := PackedInt32Array()
	var tri := [0, 0, 0]
	var t := 0
	while t + 2 < idx.size():
		for v in 3:
			var vi := idx[t + v]
			var w: Vector3 = xf * verts[vi]
			var key := [floori(w.x / cell), floori(w.y / cell), floori(w.z / cell), 0, 0, 0]
			if has_n:
				var nn := norms[vi]
				key[5] = (1 if nn.x < 0 else 0) | (2 if nn.y < 0 else 0) | (4 if nn.z < 0 else 0)
			if has_uv:
				key[3] = floori(uvs[vi].x * uv_cells)
				key[4] = floori(uvs[vi].y * uv_cells)
			var id: int
			if index.has(key):
				id = int(index[key])
				acc_p[id] += verts[vi]
				if has_n:
					acc_n[id] += norms[vi]
				if has_uv:
					acc_uv[id] += uvs[vi]
				members[id] += 1.0
			else:
				id = members.size()
				index[key] = id
				acc_p.append(verts[vi])
				acc_n.append(norms[vi] if has_n else Vector3.UP)
				acc_uv.append(uvs[vi] if has_uv else Vector2.ZERO)
				members.append(1.0)
			tri[v] = id
		# Triangles that collapsed to a line or a point go.
		if tri[0] != tri[1] and tri[1] != tri[2] and tri[0] != tri[2]:
			out_idx.append(tri[0])
			out_idx.append(tri[1])
			out_idx.append(tri[2])
		t += 3
	if out_idx.is_empty():
		out_idx = PackedInt32Array([0, 0, 0])
	for i in members.size():
		var k := members[i]
		acc_p[i] /= k
		acc_n[i] = (acc_n[i] / k).normalized() if acc_n[i].length() > 0.000001 else Vector3.UP
		acc_uv[i] /= k
	var arrays: Array = []
	arrays.resize(Mesh.ARRAY_MAX)
	arrays[Mesh.ARRAY_VERTEX] = acc_p
	if has_n:
		arrays[Mesh.ARRAY_NORMAL] = acc_n
	if has_uv:
		arrays[Mesh.ARRAY_TEX_UV] = acc_uv
	arrays[Mesh.ARRAY_INDEX] = out_idx
	return arrays


## LiveModelCache.capTextures at the model-detail size, and simple lighting's Lambert materials.
func _prepare_materials(root: Node, max_pixels: int) -> void:
	if root is MeshInstance3D and (root as MeshInstance3D).mesh != null:
		var mi := root as MeshInstance3D
		for s in mi.mesh.get_surface_count():
			var src := mi.get_active_material(s) as BaseMaterial3D
			if src == null:
				continue
			var m := src.duplicate() as BaseMaterial3D
			for p in [BaseMaterial3D.TEXTURE_ALBEDO, BaseMaterial3D.TEXTURE_NORMAL, BaseMaterial3D.TEXTURE_METALLIC,
					BaseMaterial3D.TEXTURE_ROUGHNESS, BaseMaterial3D.TEXTURE_EMISSION,
					BaseMaterial3D.TEXTURE_AMBIENT_OCCLUSION]:
				var tex := m.get_texture(p)
				if tex == null:
					continue
				var img := tex.get_image()
				if img == null or maxi(img.get_width(), img.get_height()) <= max_pixels:
					continue
				var k := float(max_pixels) / float(maxi(img.get_width(), img.get_height()))
				if img.is_compressed():
					img.decompress()
				img.resize(maxi(1, int(img.get_width() * k)), maxi(1, int(img.get_height() * k)), Image.INTERPOLATE_LANCZOS)
				m.set_texture(p, ImageTexture.create_from_image(img))
			if _simple and m.shading_mode != BaseMaterial3D.SHADING_MODE_UNSHADED:
				m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
				m.metallic = 0.0
			mi.set_surface_override_material(s, null)
			mi.mesh.surface_set_material(s, m)
	for c in root.get_children():
		_prepare_materials(c, max_pixels)


# MARK: Bridge models (NVM2)

## HDFlight.swift LiveModelExport: textures, then geometries in roll space with per-element materials
## and effect-layer tags.
func _model_from_nvm2(bytes: PackedByteArray) -> Node3D:
	if bytes.size() < 12 or bytes.decode_u32(0) != NVM2:
		return null
	var o := 4
	var tex_count := int(bytes.decode_u32(o))
	var geo_count := int(bytes.decode_u32(o + 4))
	o += 8
	var textures: Array = []
	for t in tex_count:
		if o + 4 > bytes.size():
			return null
		var n := int(bytes.decode_u32(o))
		o += 4
		if o + n > bytes.size():
			return null
		var img := Image.new()
		var tex: Texture2D = null
		if img.load_png_from_buffer(bytes.slice(o, o + n)) == OK:
			tex = ImageTexture.create_from_image(img)
		textures.append(tex)
		o += n
	var root := Node3D.new()
	for g in geo_count:
		if o + 8 > bytes.size():
			return null
		var vc := int(bytes.decode_u32(o))
		var flags := int(bytes.decode_u32(o + 4))
		o += 8
		var has_n := flags & 1 != 0
		var has_uv := flags & 2 != 0
		var need := vc * 12 + (vc * 12 if has_n else 0) + (vc * 8 if has_uv else 0)
		if vc <= 0 or o + need > bytes.size():
			return null
		var verts := PackedVector3Array()
		verts.resize(vc)
		for i in vc:
			verts[i] = Vector3(bytes.decode_float(o), bytes.decode_float(o + 4), bytes.decode_float(o + 8))
			o += 12
		var norms := PackedVector3Array()
		if has_n:
			norms.resize(vc)
			for i in vc:
				norms[i] = Vector3(bytes.decode_float(o), bytes.decode_float(o + 4), bytes.decode_float(o + 8))
				o += 12
		var uvs := PackedVector2Array()
		if has_uv:
			uvs.resize(vc)
			for i in vc:
				uvs[i] = Vector2(bytes.decode_float(o), bytes.decode_float(o + 4))
				o += 8
		if o + 4 > bytes.size():
			return null
		var elements := int(bytes.decode_u32(o))
		o += 4
		var mesh := ArrayMesh.new()
		var layer := ""
		for e in elements:
			if o + 4 + 76 > bytes.size():
				return null
			var layer_i := int(bytes.decode_u32(o))
			o += 4
			if layer_i >= 1 and layer_i <= 3:
				layer = LAYERS[layer_i - 1]
			var mat := _nvm2_material(bytes, o, textures)
			o += 76
			var ic := int(bytes.decode_u32(o))
			o += 4
			if o + ic * 4 > bytes.size():
				return null
			if ic % 3 != 0:
				return null
			var idx := PackedInt32Array()
			idx.resize(ic)
			for i in ic:
				var v := int(bytes.decode_u32(o))
				if v >= vc:
					return null   # never from the bridge; refuse rather than hand Godot a bad mesh
				idx[i] = v
				o += 4
			var arrays: Array = []
			arrays.resize(Mesh.ARRAY_MAX)
			arrays[Mesh.ARRAY_VERTEX] = verts
			if has_n:
				arrays[Mesh.ARRAY_NORMAL] = norms
			if has_uv:
				arrays[Mesh.ARRAY_TEX_UV] = uvs
			arrays[Mesh.ARRAY_INDEX] = idx
			mesh.add_surface_from_arrays(Mesh.PRIMITIVE_TRIANGLES, arrays)
			mesh.surface_set_material(mesh.get_surface_count() - 1, mat)
		if mesh.get_surface_count() == 0:
			continue
		var mi := MeshInstance3D.new()
		mi.mesh = mesh
		if not layer.is_empty():
			mi.set_meta("nova_layer", layer)
		root.add_child(mi)
	return root if root.get_child_count() > 0 else null


## One LiveModelExport material block (76 bytes): diffuse rgba, diffuse tex, metalness, metal tex,
## roughness, rough tex, emission rgb, emission tex, normal tex, lighting model, double sided, opacity,
## then which channel of the metal and rough textures holds the value (packed ORM maps: blue, green).
static func _nvm2_material(b: PackedByteArray, o: int, textures: Array) -> StandardMaterial3D:
	var m := StandardMaterial3D.new()
	m.albedo_color = Color(b.decode_float(o), b.decode_float(o + 4), b.decode_float(o + 8), b.decode_float(o + 12))
	m.albedo_texture = _tex(textures, b.decode_s32(o + 16))
	m.metallic = b.decode_float(o + 20)
	m.metallic_texture = _tex(textures, b.decode_s32(o + 24))
	m.roughness = b.decode_float(o + 28)
	m.roughness_texture = _tex(textures, b.decode_s32(o + 32))
	m.metallic_texture_channel = clampi(int(b.decode_u32(o + 68)), 0, 3) as BaseMaterial3D.TextureChannel
	m.roughness_texture_channel = clampi(int(b.decode_u32(o + 72)), 0, 3) as BaseMaterial3D.TextureChannel
	var e := Color(b.decode_float(o + 36), b.decode_float(o + 40), b.decode_float(o + 44))
	var etex := _tex(textures, b.decode_s32(o + 48))
	if e.r + e.g + e.b > 0.001 or etex != null:
		m.emission_enabled = true
		m.emission = e if etex == null else Color.WHITE
		m.emission_texture = etex
	var ntex := _tex(textures, b.decode_s32(o + 52))
	if ntex != null:
		m.normal_enabled = true
		m.normal_texture = ntex
	match int(b.decode_u32(o + 56)):
		1:   # Blinn / Phong: no metal, a mid gloss
			m.metallic = 0.0
			m.roughness = 0.45
		2:   # Lambert: diffuse only
			m.metallic = 0.0
			m.specular_mode = BaseMaterial3D.SPECULAR_DISABLED
		3:   # constant
			m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED if b.decode_u32(o + 60) != 0 else BaseMaterial3D.CULL_BACK
	var opacity := b.decode_float(o + 64)
	if opacity < 0.999:
		m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
		m.albedo_color.a *= opacity
	return m


static func _tex(textures: Array, i: int) -> Texture2D:
	return textures[i] if i >= 0 and i < textures.size() else null


# MARK: Emitters

## ModelStage.addEmitters: a soft billboard glow at each point (radius `r`, colour), and for engines an
## exhaust plume lying flat behind the nozzle along the ship's tail (-Z). Coordinates are roll space.
func _add_emitters(model: Node3D, effects: Array, present: Dictionary) -> void:
	for fx in effects:
		if typeof(fx) != TYPE_DICTIONARY:
			continue
		var at: Array = fx.get("at", [])
		if at.size() != 3:
			continue
		var layer := str(fx.get("layer", "engine"))
		var rad := float(fx.get("radius", 0.06))
		var c: Array = fx.get("color", [0.55, 0.78, 1.0])
		var col := Color(float(c[0]), float(c[1]), float(c[2])) if c.size() == 3 else Color(0.55, 0.78, 1.0)
		var pos := Vector3(float(at[0]), float(at[1]), float(at[2]))
		present[layer] = true
		var glow := _emitter_mesh(Vector2(rad * 3.6, rad * 3.6), _glow_tex, col, true)
		glow.position = pos
		glow.set_meta("nova_layer", layer)
		glow.set_meta("nova_emitter", true)
		model.add_child(glow)
		if layer == "engine":
			var length := rad * 9.0
			var width := rad * 2.2
			var plume := _emitter_mesh(Vector2(width, length), _plume_tex, col, false)
			plume.rotation = Vector3(-PI * 0.5, 0.0, 0.0)   # flat, facing up; its +Y now runs toward the tail
			plume.position = Vector3(pos.x, pos.y, pos.z - length * 0.5 + rad * 0.4)
			plume.set_meta("nova_layer", layer)
			plume.set_meta("nova_emitter", true)
			model.add_child(plume)


static func _emitter_mesh(size: Vector2, tex: Texture2D, col: Color, billboard: bool) -> MeshInstance3D:
	var q := QuadMesh.new()
	q.size = size
	var m := StandardMaterial3D.new()
	m.shading_mode = BaseMaterial3D.SHADING_MODE_UNSHADED
	m.blend_mode = BaseMaterial3D.BLEND_MODE_ADD
	m.transparency = BaseMaterial3D.TRANSPARENCY_ALPHA
	m.depth_draw_mode = BaseMaterial3D.DEPTH_DRAW_DISABLED
	m.cull_mode = BaseMaterial3D.CULL_DISABLED
	m.albedo_texture = tex
	m.albedo_color = col
	if billboard:
		m.billboard_mode = BaseMaterial3D.BILLBOARD_ENABLED
	q.material = m
	var mi := MeshInstance3D.new()
	mi.mesh = q
	return mi


# MARK: Fit (glTF; bridge models arrive fitted)

## ModelBaker.fit: the orthographic scale at which the model's silhouette, seen from the hull's stage
## camera at a few headings of the level set, covers the classic frames' opaque extents (times `fit`).
## Frame height H shows 2 * ortho units, so a silhouette of `units` covers units * H / (2 * ortho) pixels.
## Emitters (additive glow) are not part of the silhouette.
func _fit(model: Node3D, type: int, info: PackedInt32Array, fps: int, pitch: float, fit: float,
		frame_w: float, frame_h: float) -> float:
	var frames := int(info[2]) if info.size() > 2 else fps
	var samples: Array = []
	for f in [0, fps / 4, fps / 2, 3 * fps / 4]:
		if f < frames and not samples.has(f):
			samples.append(f)
	samples.sort()
	var classic := _classic_extents(type, info, samples)
	var target := minf(frame_w, frame_h) * 0.9
	if not classic.is_empty():
		var sum := 0.0
		for f in classic:
			sum += float(classic[f])
		target = sum / float(classic.size())
	var points := PackedVector3Array()
	_collect_points(model, Transform3D.IDENTITY, points, _vertex_stride(model), model)
	var p := deg_to_rad(pitch)
	var up := Vector3(0.0, cos(p), -sin(p))
	var scales: Array = []
	for f in samples:
		if points.is_empty():
			break
		var heading := float(f) * TAU / float(fps)
		var yaw := Basis(Vector3.UP, PI - heading)
		var lo := Vector2(INF, INF)
		var hi := Vector2(-INF, -INF)
		for v in points:
			var w: Vector3 = yaw * v
			var c := Vector2(w.x, w.dot(up))
			lo = Vector2(minf(lo.x, c.x), minf(lo.y, c.y))
			hi = Vector2(maxf(hi.x, c.x), maxf(hi.y, c.y))
		var units := maxf(hi.x - lo.x, hi.y - lo.y)
		var wanted := float(classic.get(f, target)) * fit
		if units > 0.0 and wanted > 0.0:
			scales.append(units * frame_h / (2.0 * wanted))
	if scales.is_empty():
		return frame_h / maxf(0.001, target * fit)
	var total := 0.0
	for s in scales:
		total += float(s)
	return total / float(scales.size())


## ClassicFootprint.extents: per frame, the larger side of the opaque pixels' bounding box.
func _classic_extents(type: int, info: PackedInt32Array, frames: Array) -> Dictionary:
	var out := {}
	if info.size() < 7:
		return out
	var fw := int(info[0])
	var fh := int(info[1])
	var cols := maxi(1, int(info[3]))
	var sw := int(info[5])
	var bytes: PackedByteArray = r.nova.sprite_rgba(0, type)
	if fw <= 0 or fh <= 0 or bytes.size() < sw * int(info[6]) * 4:
		return out
	for f in frames:
		var ox := (int(f) % cols) * fw
		var oy := (int(f) / cols) * fh
		var min_x := fw
		var min_y := fh
		var max_x := -1
		var max_y := -1
		for y in fh:
			var row := (oy + y) * sw
			for x in fw:
				if bytes[(row + ox + x) * 4 + 3] > 0:
					min_x = mini(min_x, x)
					max_x = maxi(max_x, x)
					min_y = mini(min_y, y)
					max_y = maxi(max_y, y)
		if max_x >= 0:
			out[f] = float(maxi(max_x - min_x + 1, max_y - min_y + 1))
	return out


func _vertex_stride(node: Node) -> int:
	return maxi(1, _vertex_count(node) / FIT_POINT_BUDGET)


func _vertex_count(node: Node) -> int:
	var n := 0
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null and not node.has_meta("nova_emitter"):
		var m: Mesh = (node as MeshInstance3D).mesh
		for s in m.get_surface_count():
			var a: Array = m.surface_get_arrays(s)
			n += (a[Mesh.ARRAY_VERTEX] as PackedVector3Array).size()
	for c in node.get_children():
		n += _vertex_count(c)
	return n


## Vertices in `root` space, every `stride`-th one; emitters left out.
func _collect_points(node: Node, parent: Transform3D, out: PackedVector3Array, stride: int, root: Node) -> void:
	var xf := parent
	if node is Node3D and node != root:
		xf = parent * (node as Node3D).transform
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null and not node.has_meta("nova_emitter"):
		var m: Mesh = (node as MeshInstance3D).mesh
		for s in m.get_surface_count():
			var verts: PackedVector3Array = m.surface_get_arrays(s)[Mesh.ARRAY_VERTEX]
			var i := 0
			while i < verts.size():
				out.append(xf * verts[i])
				i += stride
	for c in node.get_children():
		_collect_points(c, xf, out, stride, root)


## The hull's light level on its lit materials (LiveHull.sharedFragment's `novaLight`): the lit colour is
## scaled, emission is not (Apple divides emission back out of the same multiply).
func _scale_light(node: Node, k: float, seen: Dictionary = {}) -> void:
	if absf(k - 1.0) < 0.001:
		return
	if node is MeshInstance3D and (node as MeshInstance3D).mesh != null and not node.has_meta("nova_emitter") \
			and not seen.has((node as MeshInstance3D).mesh):
		var mi := node as MeshInstance3D
		seen[mi.mesh] = true   # a mesh shared by two instances is scaled once
		for s in mi.mesh.get_surface_count():
			var src := mi.get_active_material(s) as BaseMaterial3D
			if src == null or src.shading_mode == BaseMaterial3D.SHADING_MODE_UNSHADED:
				continue
			var m := src.duplicate() as BaseMaterial3D
			# A light scale is linear; albedo_color is sRGB, so scale it in linear space (for a
			# diffuse surface, and a metal's reflectance, that is the same as brightening the lights).
			var c := m.albedo_color
			var l := c.srgb_to_linear()
			m.albedo_color = Color(l.r * k, l.g * k, l.b * k, c.a).linear_to_srgb()
			m.albedo_color.a = c.a
			mi.mesh.surface_set_material(s, m)
	for c in node.get_children():
		_scale_light(c, k, seen)


func _set_layers(node: Node, mask: int) -> void:
	if node is VisualInstance3D:
		(node as VisualInstance3D).layers = mask
	for c in node.get_children():
		_set_layers(c, mask)


## AABB is a value, so the walk returns the merged box instead of writing through a parameter.
func _merge(node: Node, xform: Transform3D) -> Dictionary:
	var box := AABB()
	var any := false
	if node is MeshInstance3D and not node.has_meta("nova_emitter"):
		box = xform * (node as MeshInstance3D).get_aabb()
		any = true
	for child in node.get_children():
		var next := xform
		if child is Node3D:
			next = xform * (child as Node3D).transform
		var sub: Dictionary = _merge(child, next)
		if sub.is_empty():
			continue
		var b: AABB = sub["box"]
		box = b if not any else box.merge(b)
		any = true
	if not any:
		return {}
	return {"box": box}


func _set_alpha(node: Node, alpha: float) -> void:
	var t := clampf(1.0 - alpha, 0.0, 1.0)
	if node is GeometryInstance3D:
		(node as GeometryInstance3D).transparency = t
	for child in node.get_children():
		_set_alpha(child, alpha)
