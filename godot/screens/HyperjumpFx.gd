# NOVA Swift — hyperjump visual (Godot).
#
# The engine flies the maneuver itself (brake -> turn -> spin-up tunnel, then the
# fire); this layer only reads `hyperjump_state()` and dresses it: speed streaks
# the original's fade to white once the jump's progress passes 55 (1.5 s, the Mac build), then the
# arrival boom flash that fades back out over 1.5 s -- exactly GameScene.stepJump `.engaged` / `.arrive`.
# The original draws NO speed streaks (the tunnel is only the ship's own position step and the parallax
# dust the starfield already shows), so none are drawn here. "Reduce flashing" caps the white at 0.45;
# Classic Preferences > Hyperspace Fx off skips the fade and flashes black for 0.1 s.
#
# With the `quickHyperjump` enhancement (Prefs gameplay/quick_hyperjump) the shared QuickHyperjump flies the
# turn and burst instead: hyperjump_state() reports phases 4 align / 5 accelerate / 6 flash plus the white
# level, streak opacity and stretch the frame asked for (GameScene.stepJump's `.align/.accelerate/.flash`),
# and the arrival fades in over jump_arrival_fade() (0.35 s) instead of the Mac's 1.5 s.

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
var _quick_streak: float = 0.0  # quickHyperjump streak opacity 0..1 (0 = none)
var _quick_stretch: float = 1.0 # ... and how far the lines are stretched along the bearing
var _arrive_len: float = -1.0   # arrival fade seconds from the bridge; <= 0 = the default look
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

	_quick_streak = 0.0
	_quick_stretch = 1.0
	if _phase == 0:
		_fade = 0.0
	elif _phase >= 4 and st.size() >= 7:
		# quickHyperjump: the white-out ramp is the shared frame's, capped by Reduce Flashing.
		_fade = st[4] * _cap()
		if not _no_fx():
			_quick_streak = st[5]
			_quick_stretch = st[6]
	elif st[2] > 0.5 and not _no_fx():
		_fade = minf(_cap(), _fade + delta / FADE_SECONDS * _cap())

	var fade_len: float = _arrive_len
	if fade_len <= 0.0:
		fade_len = ARRIVE_FADE_NO_FX if _no_fx() else ARRIVE_FADE
	_flash = maxf(0.0, _flash - delta / fade_len * _cap())
	var arrival: String = nova.take_jump_arrival()
	if arrival != "":
		_flash = _cap()
		_fade = 0.0
		_arrive_len = -1.0
		if nova.has_method("jump_arrival_fade"):
			var quick_len: float = float(nova.jump_arrival_fade())
			if quick_len > 0.0:
				_arrive_len = quick_len
		arrived.emit(arrival)

	var active := _phase != 0 or _flash > 0.0
	_canvas.visible = active
	if active:
		_canvas.queue_redraw()


func _on_draw() -> void:
	var size := _canvas.size
	if _quick_streak > 0.0:
		_draw_quick_streaks(size)
	var white := maxf(_fade, _flash)
	if white > 0.0:
		var c := Color.BLACK if _no_fx() else Color.WHITE
		c.a = white
		_canvas.draw_rect(Rect2(Vector2.ZERO, size), c)


## The quickHyperjump streak fan (GameScene.buildJumpOverlays): thin bright lines running along the outbound
## bearing, spread across the view, `_quick_stretch` times longer as the burst builds. Compass bearing on a
## north-up view: 0 = up, clockwise.
func _draw_quick_streaks(size: Vector2) -> void:
	var dir := Vector2(sin(_bearing), -cos(_bearing))
	var side := Vector2(-dir.y, dir.x)
	var center: Vector2 = size * 0.5
	var color := Color(0.8, 0.9, 1.0, clampf(_quick_streak * 0.7, 0.0, 1.0))
	for s in _streaks:
		var pos: Vector2 = s["pos"]
		var length: float = float(s["len"]) * 300.0 * _quick_stretch
		var off: Vector2 = side * ((pos.x - 0.5) * size.length()) + dir * ((pos.y - 0.5) * size.length())
		_canvas.draw_line(center + off - dir * length * 0.5, center + off + dir * length * 0.5, color, 1.5)
