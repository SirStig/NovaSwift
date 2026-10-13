extends SceneTree
# A REAL joypad A (Input.parse_input_event, full dispatch) over a Button presses it once. Run it WINDOWED:
# the 2026-10-13 "A highlights but never clicks" bug only showed in a real window (nested mouse event dropped).
var frames := 0
var b: Button
var presses := 0
func _initialize() -> void:
	var c := Control.new()
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(c)
	b = Button.new()
	b.text = "X"
	b.position = Vector2(200, 150)
	b.size = Vector2(120, 50)
	b.pressed.connect(func(): presses += 1)
	c.add_child(b)
func _joy(pressed: bool) -> void:
	var e := InputEventJoypadButton.new()
	e.device = 0
	e.button_index = JOY_BUTTON_A
	e.pressed = pressed
	Input.parse_input_event(e)
func _process(_d: float) -> bool:
	frames += 1
	var pc: Node = root.get_node("PadCursor")
	if frames == 4:
		pc.debug_move_to(b.position + b.size * 0.5)
	if frames == 6: _joy(true)
	if frames == 8: _joy(false)
	if frames == 12:
		print("REAL-A presses=", presses)
		print("pad_cursor_real_a_selfcheck: ", "PASS" if presses == 1 else "FAIL")
		quit()
	return false
