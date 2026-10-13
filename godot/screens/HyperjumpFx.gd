# NOVA Swift — hyperjump visual (Godot).
#
# The engine flies the maneuver itself (brake -> turn -> spin-up tunnel, then the
# fire); this layer only reads `hyperjump_state()` and dresses it: speed streaks
# along the bearing while the tunnel runs, the original's fade to white once the
# jump's progress passes 55, and a white flash that clears on arrival. Deliberately
# simple — fidelity polish (sound cues, reduced-flashing option) comes later.

extends CanvasLayer

signal arrived(system_name: String)

const FADE_SECONDS := 1.5       # the Mac's fade to white (GameScene .engaged)
const FLASH_DECAY := 1.0        # arrival flash fall-off, seconds
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


func _process(delta: float) -> void:
	if nova == null:
		return
	var st: PackedFloat32Array = nova.hyperjump_state()
	_phase = int(st[0])
	_progress = st[1]
	_bearing = st[3]

	if _phase == 0:
		_fade = 0.0
	elif st[2] > 0.5:
		_fade = minf(1.0, _fade + delta / FADE_SECONDS)

	_flash = maxf(0.0, _flash - delta / FLASH_DECAY)
	var arrival: String = nova.take_jump_arrival()
	if arrival != "":
		_flash = 1.0
		_fade = 0.0
		arrived.emit(arrival)

	if _phase == 2:
		for s in _streaks:
			var p: Vector2 = s["pos"]
			var dir := Vector2(sin(_bearing), -cos(_bearing))
			p -= dir * s["speed"] * clampf(_progress / 40.0, 0.05, 1.5) * delta
			s["pos"] = Vector2(fposmod(p.x, 1.0), fposmod(p.y, 1.0))

	var active := _phase != 0 or _flash > 0.0
	_canvas.visible = active
	if active:
		_canvas.queue_redraw()


func _on_draw() -> void:
	var size := _canvas.size
	if _phase == 2:
		var dir := Vector2(sin(_bearing), -cos(_bearing))
		var strength := clampf(_progress / 30.0, 0.05, 1.0)
		for s in _streaks:
			var a: Vector2 = Vector2(s["pos"].x * size.x, s["pos"].y * size.y)
			var b: Vector2 = a + dir * (8.0 + 160.0 * strength * s["len"])
			_canvas.draw_line(a, b, Color(0.85, 0.92, 1.0, 0.25 + 0.55 * strength), 1.5)
	var white := maxf(_fade, _flash)
	if white > 0.0:
		_canvas.draw_rect(Rect2(Vector2.ZERO, size), Color(1, 1, 1, white))
