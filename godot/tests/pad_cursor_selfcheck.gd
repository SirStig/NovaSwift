# Headless check of the gamepad UI cursor (ui/PadCursor.gd): the synthesised mouse hover lands on the right
# Control (viewport -> window coordinate conversion), pad A over a Button presses it and is consumed, A over
# empty space is NOT consumed (so ui_accept still falls through), the right-stick wheel scrolls a
# ScrollContainer under the pointer, suppression stands the cursor down, and the left stick is lifted off the
# ui_* focus actions while the cursor is available (and restored after). Run:
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/pad_cursor_selfcheck.gd
extends SceneTree

var ok := true
var presses := 0


func _init() -> void:
	_run()


func _check(label: String, cond: bool) -> void:
	print(("  ok   " if cond else "  FAIL ") + label)
	if not cond:
		ok = false


func _left_stick_in_nav() -> int:
	var n := 0
	for a in ["ui_up", "ui_down", "ui_left", "ui_right"]:
		for e in InputMap.action_get_events(a):
			if e is InputEventJoypadMotion and ((e as InputEventJoypadMotion).axis == JOY_AXIS_LEFT_X \
					or (e as InputEventJoypadMotion).axis == JOY_AXIS_LEFT_Y):
				n += 1
	return n


func _run() -> void:
	await process_frame
	var pc: Node = root.get_node_or_null("PadCursor")
	_check("PadCursor autoload present", pc != null)
	if pc == null:
		quit(1)
		return

	var holder := Control.new()
	holder.set_anchors_preset(Control.PRESET_FULL_RECT)
	holder.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(holder)
	var btn := Button.new()
	btn.text = "Press me"
	btn.position = Vector2(100, 100)
	btn.size = Vector2(200, 60)
	btn.pressed.connect(func(): presses += 1)
	holder.add_child(btn)
	var sc := ScrollContainer.new()
	sc.position = Vector2(100, 300)
	sc.size = Vector2(300, 200)
	holder.add_child(sc)
	var box := VBoxContainer.new()
	box.custom_minimum_size = Vector2(280, 0)
	sc.add_child(box)
	for i in 40:
		var l := Label.new()
		l.text = "Row %d" % i
		l.custom_minimum_size = Vector2(0, 30)
		box.add_child(l)
	await process_frame
	await process_frame

	# Hover: pointer at the button's centre -> that button is the hovered control.
	pc.debug_move_to(Vector2(200, 130))
	await process_frame
	_check("hover lands on the Button", root.gui_get_hovered_control() == btn)

	# Click: A press over the button is consumed; release completes the press.
	var eaten: bool = pc.debug_press_a(true)
	await process_frame
	var eaten_up: bool = pc.debug_press_a(false)
	await process_frame
	_check("A over a Button is consumed", eaten)
	_check("A release is consumed too", eaten_up)
	_check("Button.pressed fired once", presses == 1)

	# Empty space: A is not consumed (falls through to ui_accept).
	pc.debug_move_to(Vector2(900, 600))
	await process_frame
	_check("nothing hovered over empty space", root.gui_get_hovered_control() == null)
	_check("A over empty space is NOT consumed", not pc.debug_press_a(true))
	pc.debug_press_a(false)
	_check("no extra press", presses == 1)

	# Scroll: wheel events at the pointer scroll the container.
	pc.debug_move_to(Vector2(250, 400))
	await process_frame
	var before: int = sc.scroll_vertical
	pc.debug_scroll(true, 3)
	await process_frame
	await process_frame
	_check("wheel scrolls the ScrollContainer", sc.scroll_vertical > before)

	# Suppression.
	pc.last_was_pad = true
	pc.assume_pad = true
	await process_frame
	_check("active when available", pc.is_active())
	_check("left stick lifted off ui_* nav", _left_stick_in_nav() == 0)
	pc.suppress("flight")
	await process_frame
	_check("suppress('flight') deactivates", not pc.is_active())
	_check("left stick nav restored when suppressed", _left_stick_in_nav() > 0)
	_check("A is not consumed while suppressed", not pc.debug_press_a(true))
	pc.debug_press_a(false)
	pc.release("flight")
	await process_frame
	_check("release re-activates", pc.is_active())

	# A real mouse move hides the cursor (last input wins).
	var mm := InputEventMouseMotion.new()
	mm.position = Vector2(700, 200)
	mm.relative = Vector2(30, 0)
	pc.handle_event(mm)
	_check("real mouse motion hides the pad cursor", not pc.is_active())

	print("pad_cursor_selfcheck: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
