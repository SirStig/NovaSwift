# NOVA Swift — hyperjump visual (Godot).
#
# The engine flies the maneuver itself (brake -> turn -> spin-up tunnel, then the
# fire); this layer only reads `hyperjump_state()` and dresses it: speed streaks
# the original's fade to white once the jump's progress passes 55 (1.5 s, the Mac build), then the
# arrival boom flash that fades back out over 1.5 s -- exactly GameScene.stepJump `.engaged` / `.arrive`.
# The original draws NO speed streaks (the tunnel is only the ship's own position step and the parallax
# dust the starfield already shows), so none are drawn here. "Reduce flashing" caps the white at 0.45;
# Classic Preferences > Hyperspace Fx off skips the fade and flashes black for 0.1 s.

extends CanvasLayer

signal arrived(system_name: String)

const FADE_SECONDS := 1.5       # the Mac's fade to white (GameScene .engaged)
const ARRIVE_FADE := 1.5        # arrival flash fall-off (jumpArriveFade, Mac look)
const ARRIVE_FADE_NO_FX := 0.1
const Prefs = preload("res://Prefs.gd")
const STREAKS := 90

var nova
var _canvas: Control
var _phase := 0
var _progress := 0.0
var _fade := 0.0                # 0..1 white overlay while the jump charges
var _flash := 0.0               # 0..1 white after arrival
var _bearing := 0.0
var _streaks: Array = []        # {pos: Vector2 (0..1), speed: float, len: float}


func setup(world) -> void:
	nova = world
	layer = 20
	_canvas = Control.new()
	_canvas.set_anchors_preset(Control.PRESET_FULL_RECT)
	_canvas.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.draw.connect(_on_draw)
	add_child(_canvas)
	var rng := RandomNumberGenerator.new()
	rng.seed = 0xFA57
	for i in STREAKS:
		_streaks.append({
			"pos": Vector2(rng.randf(), rng.randf()),
			"speed": rng.randf_range(0.6, 1.6),
			"len": rng.randf_range(0.5, 1.0),
		})


## Reduce flashing caps the white at 0.45 (Apple `cap`).
func _cap() -> float:
	return 0.45 if bool(Prefs.get_value("graphics", "reduce_flashing")) else 1.0


## Classic Preferences "Hyperspace Fx" off = the original's noHyperspaceEffects.
func _no_fx() -> bool:
	return not bool(Prefs.get_value("classic", "hyperspace_effects"))


func _process(delta: float) -> void:
	if nova == null:
		return
	var st: PackedFloat32Array = nova.hyperjump_state()
	_phase = int(st[0])
	_progress = st[1]
	_bearing = st[3]

	if _phase == 0:
		_fade = 0.0
	elif st[2] > 0.5 and not _no_fx():
		_fade = minf(_cap(), _fade + delta / FADE_SECONDS * _cap())

	_flash = maxf(0.0, _flash - delta / (ARRIVE_FADE_NO_FX if _no_fx() else ARRIVE_FADE) * _cap())
	var arrival: String = nova.take_jump_arrival()
	if arrival != "":
		_flash = _cap()
		_fade = 0.0
		arrived.emit(arrival)

	var active := _phase != 0 or _flash > 0.0
	_canvas.visible = active
	if active:
		_canvas.queue_redraw()


func _on_draw() -> void:
	var size := _canvas.size
	var white := maxf(_fade, _flash)
	if white > 0.0:
		var c := Color.BLACK if _no_fx() else Color.WHITE
		c.a = white
		_canvas.draw_rect(Rect2(Vector2.ZERO, size), c)
