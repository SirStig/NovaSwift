# Headless check of galaxy-map mouse panning: a left drag pans (Apple DragGesture), a left
# click without a drag still plots, right drag and two-finger trackpad scroll pan. Run:
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/map_drag_selfcheck.gd
extends SceneTree

const GalaxyMap = preload("res://screens/GalaxyMap.gd")
const Controls = preload("res://Controls.gd")

var ok := true


func _init() -> void:
	_run()


func _check(label: String, cond: bool) -> void:
	print(("  ok   " if cond else "  FAIL ") + label)
	if not cond:
		ok = false


func _button(gm, pos: Vector2, idx: int, pressed: bool) -> void:
	var e := InputEventMouseButton.new()
	e.button_index = idx
	e.pressed = pressed
	e.position = pos
	gm._input(e)


func _motion(gm, pos: Vector2, rel: Vector2) -> void:
	var e := InputEventMouseMotion.new()
	e.position = pos
	e.relative = rel
	gm._input(e)


func _run() -> void:
	await process_frame
	Controls.register()
	var nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	var dir := OS.get_environment("NOVA_DATA_DIR")
	if dir == "" or not nova.load_game(dir):
		print("MAP DRAG SELFCHECK: SKIP (no data)")
		quit(0)
		return
	_check("make_world", nova.make_world(-1))
	var gm = GalaxyMap.new()
	root.add_child(gm)
	gm.setup(nova)
	gm.open()
	await process_frame
	await process_frame
	# Screen point at the middle of the starmap canvas.
	var mid: Vector2 = gm._canvas.get_global_rect().get_center()

	var c0: Vector2 = gm._center
	_button(gm, mid, MOUSE_BUTTON_LEFT, true)
	_motion(gm, mid + Vector2(30, 0), Vector2(30, 0))
	_motion(gm, mid + Vector2(60, 20), Vector2(30, 20))
	_check("left drag pans the chart", gm._center.distance_to(c0) > 1.0)
	var c1: Vector2 = gm._center
	var route_before = nova.nav_route() if nova.has_method("nav_route") else null
	_button(gm, mid + Vector2(60, 20), MOUSE_BUTTON_LEFT, false)
	_check("releasing a drag does not plot", (nova.nav_route() if nova.has_method("nav_route") else null) == route_before)
	_check("drag state cleared", not gm._left_down and not gm._left_dragged)

	_button(gm, mid, MOUSE_BUTTON_RIGHT, true)
	_motion(gm, mid + Vector2(-40, 0), Vector2(-40, 0))
	_button(gm, mid + Vector2(-40, 0), MOUSE_BUTTON_RIGHT, false)
	_check("right drag still pans", gm._center.distance_to(c1) > 1.0)

	var c2: Vector2 = gm._center
	var pan := InputEventPanGesture.new()
	pan.position = mid
	pan.delta = Vector2(3, 2)
	gm._input(pan)
	_check("two-finger scroll pans", gm._center.distance_to(c2) > 1.0)

	var z0: float = gm._zoom
	var mag := InputEventMagnifyGesture.new()
	mag.position = mid
	mag.factor = 1.2
	gm._input(mag)
	_check("pinch zooms", not is_equal_approx(gm._zoom, z0) or is_equal_approx(z0, gm._zmax()))

	# A click with no drag on the current system still goes through the plot path.
	var cur_screen: Vector2 = gm._to_screen(gm._info[gm._current]["pos"])
	var plotted := []
	var orig_left_press: Vector2
	_button(gm, gm._canvas.get_global_transform() * cur_screen, MOUSE_BUTTON_LEFT, true)
	orig_left_press = gm._left_press
	_button(gm, gm._canvas.get_global_transform() * cur_screen, MOUSE_BUTTON_LEFT, false)
	_check("plain click is treated as a click (no drag)", not gm._left_dragged and orig_left_press.distance_to(cur_screen) < 2.0)

	print("MAP DRAG SELFCHECK: " + ("PASS" if ok else "FAIL"))
	quit(0 if ok else 1)
