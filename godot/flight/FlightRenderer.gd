# The flight view's renderer. Main.gd orchestrates (input, sim step, HUD); everything that puts the world
# on screen lives here and in the drawers beside it:
#
#   FlightSprites     decoded-sprite cache (hulls, overlays, stellars, boom sheets, cicn art)
#   FlightCamera      CameraRig port: classic / look-ahead / ship-up (chase) views, shake
#   StarfieldDrawer   the original's ambient field (or the Nova Swift dot field)
#   StellarDrawer     stellars (animated / destroyed / murk), rocks, cargo, nav cursor
#   ShipDrawer        shän layers per ship, target reticle
#   ShotDrawer        shots + trails, beams (corona, art, lightning)
#   EffectsDrawer     explosions, death sequences, particles, flashes, smoke, hit sparks
#
# Layers are stacked Node2Ds (each with one blend mode) in the Apple scene's z order:
#   world(mix) fog(fill) hulls(mix) hull-fog(fill) glows(add) shots(mix) fx-add(add) beams(add) fx(mix)
# Per frame Main calls frame(delta) after stepping the sim: it snapshots the bridge readbacks ONCE, moves the
# camera, advances the effects and queues a redraw. Nothing here decides game state.
#
# Performance: every sprite is a cached ImageTexture region (no per-frame Image work), texture runs
# batch inside a layer, and the bridge readbacks are packed arrays read once per frame.
extends Node2D

const Prefs = preload("res://Prefs.gd")
const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")
const Layer = preload("res://flight/FlightLayer.gd")
const Sprites = preload("res://flight/FlightSprites.gd")
const Camera = preload("res://flight/FlightCamera.gd")
const Starfield = preload("res://flight/StarfieldDrawer.gd")
const Stellars = preload("res://flight/StellarDrawer.gd")
const Ships = preload("res://flight/ShipDrawer.gd")
const Shots = preload("res://flight/ShotDrawer.gd")
const Effects = preload("res://flight/EffectsDrawer.gd")

var nova
var has_data := false
var active := true                    # false while a menu / the spaceport owns the screen
var clock := 0.0                      # wall-clock-ish seconds for decoration (spins, pulses)

var sprites := Sprites.new()
var cam := Camera.new()
var starfield := Starfield.new()
var stellars := Stellars.new()
var ships := Ships.new()
var shots := Shots.new()
var fx := Effects.new()

# Settings (refreshed from Prefs; see refresh_settings).
var classic_world := true             # Classic presentation: the original's reticle, field, particles
var classic_particles := true
var engine_glow := true
var running_lights := true
var weapon_effects := true
var smoke_trails := true
var parallax_starfield := true
var screen_shake := false
var reduce_flashing := false
var camera_view := "classic"
var chase_tilt := 30.0
var zoom := 1.0

# Frame state.
var background := Color(0.02, 0.02, 0.06)
var base_xf := Transform2D.IDENTITY   # engine-local (y flipped by w2l) -> screen
var cam_base := Vector2.ZERO          # camera position before shake (engine space)
var cam_pos := Vector2.ZERO           # camera position incl. shake
var play_ctr := Vector2.ZERO
var play_bar := 0.0                   # width the Classic status bar reserves
var selected_spob := -1
var target_id := -1
var fog_world: Array = []
var fog_ships: Array = []

# Per-frame snapshot of the bridge readbacks.
var ship_xf: PackedFloat32Array
var ship_sf: PackedInt32Array
var ship_ids: PackedInt32Array
var ship_rel: PackedInt32Array
var ship_vis: PackedFloat32Array
var ship_layers: PackedFloat32Array
var shot_xf: PackedFloat32Array
var shot_style: PackedInt32Array
var shot_extra: PackedFloat32Array
var beams: PackedFloat32Array
var beam_weapons: PackedInt32Array
var roid_xf: PackedFloat32Array
var roid_style: PackedInt32Array
var box_xf: PackedFloat32Array
var box_style: PackedInt32Array
var body_xf: PackedFloat32Array
var body_ids: PackedInt32Array
var stellar_states: PackedFloat32Array
var target_reticle: PackedFloat32Array

var _layers: Array = []
var _weapon_cache := {}
var _frame_dt := 0.016
var _settings_age := 999


func setup(world: Object) -> void:
	nova = world
	sprites.setup(world)
	starfield.setup(self)
	stellars.setup(self)
	ships.setup(self)
	shots.setup(self)
	fx.setup(self)
	show_behind_parent = true      # the world draws under Main's HUD
	_add_layer("mix", _draw_world)
	_add_layer("fill", _draw_fog_world)
	_add_layer("mix", _draw_hulls)
	_add_layer("fill", _draw_fog_ships)
	_add_layer("add", _draw_glows)
	_add_layer("mix", _draw_shots)
	_add_layer("add", _draw_fx_add)
	_add_layer("add", _draw_beams)
	_add_layer("mix", _draw_fx)
	refresh_settings()


func _add_layer(mode: String, fn: Callable) -> void:
	var l := Layer.new()
	l.setup(mode, fn)
	add_child(l)
	_layers.append(l)


## Pull the presentation settings: the Classic Preferences window's flags (Smoke Trails, Engine Glows, Running
## Lights, Weapon Effects, Parallax, Ship Animations) and the Graphics page's camera / accessibility options.
func refresh_settings() -> void:
	classic_world = has_data and ClassicTheme.classic("hud")
	classic_particles = classic_world or not has_data
	engine_glow = bool(Prefs.get_value("classic", "engine_glow"))
	running_lights = bool(Prefs.get_value("classic", "running_lights"))
	weapon_effects = bool(Prefs.get_value("classic", "weapon_effects"))
	smoke_trails = bool(Prefs.get_value("classic", "smoke_trails"))
	parallax_starfield = bool(Prefs.get_value("classic", "parallax_starfield"))
	screen_shake = bool(Prefs.get_value("graphics", "screen_shake"))
	reduce_flashing = bool(Prefs.get_value("graphics", "reduce_flashing"))
	camera_view = Camera.VIEWS[clampi(int(Prefs.get_value("graphics", "camera_view")), 0, Camera.VIEWS.size() - 1)]
	chase_tilt = float(Prefs.get_value("graphics", "chase_tilt"))
	zoom = clampf(float(Prefs.get_value("graphics", "camera_zoom")), 0.5, 3.0)
	if nova != null:
		nova.set_flight_options(bool(Prefs.get_value("classic", "ship_animations")), reduce_flashing)


## The system was rebuilt (launch, jump arrival, new pilot): drop transient state and snap the camera.
func reset_world() -> void:
	fx.clear()
	sprites.clear()
	_weapon_cache.clear()
	ships.reticle_zoom = 0.0
	ships.launches.clear()
	ships.ghosts.clear()
	stellars.cursor_zoom = 0.0
	refresh_background()
	var vp := get_viewport_rect().size
	cam.snap(camera_view, nova.player_angle(), vp * zoom, deg_to_rad(chase_tilt))


func refresh_background() -> void:
	var rgb: PackedFloat32Array = nova.system_background_color()
	if rgb.size() >= 3 and (rgb[0] + rgb[1] + rgb[2]) > 0.0:
		background = Color(rgb[0], rgb[1], rgb[2])
	else:
		background = Color(0.02, 0.02, 0.06)   # pure black lifted a hair so the starfield has something to sit on


# MARK: Coordinates

## Engine (y-up) world position -> the layers' local space (y-down, camera-relative).
func w2l(p: Vector2) -> Vector2:
	return Vector2(p.x - cam_pos.x, -(p.y - cam_pos.y))


func world_to_screen(p: Vector2) -> Vector2:
	return base_xf * w2l(p)


func screen_to_world(s: Vector2) -> Vector2:
	var l := base_xf.affine_inverse() * s
	return Vector2(l.x + cam_pos.x, cam_pos.y - l.y)


## The centre of the flight view: the middle of the play area. With the Classic status bar up the original
## never lets the play area run under the sidebar, so the world is centred in the part left of it.
func play_center(vp: Vector2) -> Vector2:
	return Vector2((vp.x - play_bar) * 0.5, vp.y * 0.5)


func shake(at: Vector2, radius: float) -> void:
	if screen_shake and not reduce_flashing:
		cam.add_shake(at, nova.player_position(), radius)


func weapon_visual(id: int) -> PackedFloat32Array:
	if id < 128:
		return PackedFloat32Array()
	if not _weapon_cache.has(id):
		_weapon_cache[id] = nova.weapon_visual(id)
	return _weapon_cache[id]


# MARK: Per-frame

## Call once per displayed frame after nova.step(). `vp_bar` is the width the Classic HUD reserves.
func frame(delta: float, bar_width: float, advance_sim_effects: bool = true) -> void:
	_frame_dt = delta
	clock += delta
	_settings_age += 1
	if _settings_age >= 30:
		_settings_age = 0
		refresh_settings()
	play_bar = bar_width
	var vp := get_viewport_rect().size
	play_ctr = play_center(vp)
	_snapshot()
	var pw: Vector2 = nova.player_position()
	var vel: Vector2 = nova.player_velocity()
	var heading: float = nova.player_angle()
	cam.update(camera_view, heading, vel, nova.player_max_speed(), vp * zoom, deg_to_rad(chase_tilt), delta)
	cam_base = pw + cam.offset
	cam_pos = cam_base
	if screen_shake and not reduce_flashing:
		cam_pos += cam.shake_offset(delta)
	else:
		cam.shake_time = 0.0
	base_xf = Transform2D(cam.rotation, play_ctr).scaled_local(Vector2(1.0 / zoom, 1.0 / zoom))
	if advance_sim_effects:
		fx.advance(delta)
		ships.advance(delta)
		shots.spawn_trails()
	ships.build_order()
	fog_world.clear()
	fog_ships.clear()
	for l in _layers:
		l.queue_redraw()
	queue_redraw()


func _snapshot() -> void:
	ship_xf = nova.ship_transforms()
	ship_sf = nova.ship_sprite_frames()
	ship_ids = nova.ship_ids()
	ship_rel = nova.ship_relationships()
	ship_vis = nova.ship_visuals()
	ship_layers = nova.ship_layers()
	shot_xf = nova.projectile_transforms()
	shot_style = nova.projectile_styles()
	shot_extra = nova.projectile_extra()
	beams = nova.beam_segments()
	beam_weapons = nova.beam_weapons()
	roid_xf = nova.asteroid_transforms()
	roid_style = nova.asteroid_styles()
	box_xf = nova.freeflight_transforms()
	box_style = nova.freeflight_styles()
	body_xf = nova.body_transforms()
	body_ids = nova.body_spob_ids()
	stellar_states = nova.stellar_states()
	target_reticle = nova.target_reticle()
	target_id = nova.player_target_id()
	selected_spob = nova.selected_stellar_id() if has_data else -1


# MARK: Layers

func set_active(on: bool) -> void:
	if on != active:
		active = on
		for l in _layers:
			l.queue_redraw()
		queue_redraw()


func _ready_to_draw() -> bool:
	return nova != null and active


func _draw() -> void:
	if not _ready_to_draw():
		return
	# The system's own sÿst.BkgndColor, not a hardcoded near-black: nebula systems are visibly tinted.
	draw_rect(Rect2(Vector2.ZERO, get_viewport_rect().size), background)


func _draw_world(ci: CanvasItem) -> void:
	if not _ready_to_draw():
		return
	ci.draw_set_transform_matrix(base_xf)
	starfield.draw(ci, get_viewport_rect().size, play_ctr)
	if has_data:
		stellars.draw_bodies(ci)
		stellars.draw_asteroids(ci)
		stellars.draw_freeflight(ci)
	shots.draw_beams_normal(ci)


func _draw_fog_world(ci: CanvasItem) -> void:
	_draw_fog(ci, fog_world)


func _draw_hulls(ci: CanvasItem) -> void:
	if not _ready_to_draw():
		return
	ci.draw_set_transform_matrix(base_xf)
	ships.draw_hulls(ci)
	ships.draw_ghosts(ci)


func _draw_fog_ships(ci: CanvasItem) -> void:
	_draw_fog(ci, fog_ships)


func _draw_fog(ci: CanvasItem, list: Array) -> void:
	if not _ready_to_draw():
		return
	ci.draw_set_transform_matrix(base_xf)
	for f in list:
		var c: Color = f[3]
		var e: Dictionary = f[0]
		var size := Vector2(e["fw"], e["fh"])
		ci.draw_texture_rect_region(e["tex"], Rect2(f[1] - size * 0.5, size), Sprites.src(e, f[2]),
			Color(c.r, c.g, c.b, clampf(f[4], 0.0, 1.0)))


func _draw_glows(ci: CanvasItem) -> void:
	if not _ready_to_draw():
		return
	ci.draw_set_transform_matrix(base_xf)
	ships.draw_glows(ci)


func _draw_shots(ci: CanvasItem) -> void:
	if not _ready_to_draw():
		return
	ci.draw_set_transform_matrix(base_xf)
	shots.draw_projectiles(ci)
	fx.draw_normal(ci)


func _draw_fx_add(ci: CanvasItem) -> void:
	if not _ready_to_draw():
		return
	ci.draw_set_transform_matrix(base_xf)
	shots.draw_bolts(ci)
	fx.draw_add(ci)


func _draw_beams(ci: CanvasItem) -> void:
	if not _ready_to_draw():
		return
	ci.draw_set_transform_matrix(base_xf)
	shots.draw_beams_add(ci)


func _draw_fx(ci: CanvasItem) -> void:
	if not _ready_to_draw():
		return
	ci.draw_set_transform_matrix(base_xf)
	stellars.draw_selection(ci, _frame_dt)
	ships.draw_target(ci, _frame_dt)
