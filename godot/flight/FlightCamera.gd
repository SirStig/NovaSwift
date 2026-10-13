# The flight camera -- a line-for-line port of the Apple app's CameraRig.swift + GameScene's camera
# placement and screen shake (addShake / shakenCameraPosition).
#
# Views: "classic" is the original's camera exactly (north up, ship dead centre, no zoom) and the
# default. "look_ahead" drifts the view ahead of the ship along its flight path, "ship_up" turns the
# world with the ship so it always points up the screen, "chase" is the Apple 3D-tilt view; like Apple
# without live 3D hulls (which this frontend does not have) it falls back to ship_up (see
# CameraView.effective(live3D:)), so the tilt itself is not drawn.
#
# Engine space is y-up, Godot's screen y-down: the renderer flips y when it builds its world
# transform; here everything is engine-space (offset in world units, rotation = Apple's cameraRig.rotation,
# i.e. the clockwise angle the world appears turned on screen).
extends RefCounted

const VIEWS := ["classic", "look_ahead", "ship_up", "chase"]
const SHAKE_DURATION := 0.3
const SHAKE_FELT_DISTANCE := 900.0

var rotation := 0.0          # Apple CameraRig.rotation (radians)
var offset := Vector2.ZERO   # camera position minus the ship's, world units
var tilt := 0.0              # eased chase tilt (radians); informational, not drawn (no live 3D)
var shake_time := 0.0
var shake_mag := 0.0


static func effective_view(view: String) -> String:
	return "ship_up" if view == "chase" else view


static func rotates_with_ship(view: String) -> bool:
	return view == "ship_up" or view == "chase"


## Advance one frame. `heading` is the ship's render heading (radians clockwise from north),
## `view_size` the visible play area in world units.
func update(view: String, heading: float, velocity: Vector2, max_speed: float, view_size: Vector2,
		tilt_angle: float, dt: float) -> void:
	dt = clampf(dt, 0.0, 0.1)
	var eff := effective_view(view)
	var target_rot := -heading if rotates_with_ship(eff) else 0.0
	var dr := fmod(target_rot - rotation, TAU)
	if dr > PI:
		dr -= TAU
	if dr < -PI:
		dr += TAU
	rotation += dr * minf(1.0, dt * 7.0)
	rotation = fmod(rotation, TAU)

	var short_side := minf(view_size.x, view_size.y)
	var target := Vector2.ZERO
	if eff == "look_ahead":
		var lead := 0.3 * short_side
		var spd := velocity.length()
		var frac := minf(1.0, spd / max_speed) if max_speed > 0.0 else 0.0
		if spd > 1e-3:
			target = velocity / spd * lead * frac
	var follow := minf(1.0, dt * 2.5)
	offset += (target - offset) * follow
	if eff == "classic" and absf(offset.x) < 0.05 and absf(offset.y) < 0.05:
		offset = Vector2.ZERO
	if eff == "classic" and absf(rotation) < 1e-4:
		rotation = 0.0
	var target_tilt := tilt_angle if view == "chase" else 0.0
	tilt += (target_tilt - tilt) * minf(1.0, dt * 5.0)
	if absf(tilt - target_tilt) < 1e-4:
		tilt = target_tilt


## Jump straight to the target framing (a new system, a launch).
func snap(view: String, heading: float, view_size: Vector2, tilt_angle: float) -> void:
	rotation = 0.0
	offset = Vector2.ZERO
	tilt = 0.0
	for i in 40:
		update(view, heading, Vector2.ZERO, 0.0, view_size, tilt_angle, 0.1)


## Register a camera-shake impulse from an explosion at `at` (world), scaled by how close and big.
## Only felt within ~900 px; the caller gates it on the Screen Shake setting and Reduce Flashing.
func add_shake(at: Vector2, player_pos: Vector2, radius: float) -> void:
	var falloff := maxf(0.0, 1.0 - at.distance_to(player_pos) / SHAKE_FELT_DISTANCE)
	if falloff <= 0.0:
		return
	shake_mag = minf(8.0, maxf(shake_mag, (2.0 + radius * 0.12) * falloff))
	shake_time = SHAKE_DURATION


## The current shake displacement (world units), decaying each call; ZERO when nothing shakes.
func shake_offset(dt: float) -> Vector2:
	if shake_time <= 0.0:
		return Vector2.ZERO
	shake_time -= dt
	if shake_time <= 0.0:
		shake_mag = 0.0
		return Vector2.ZERO
	var m := shake_mag * (shake_time / SHAKE_DURATION)
	return Vector2(randf_range(-m, m), randf_range(-m, m))
