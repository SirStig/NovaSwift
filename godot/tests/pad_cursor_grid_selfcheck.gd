extends SceneTree
const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")
# The pad cursor's hover highlight follows it across a 3x3 grid without taking focus; A over empty space presses nothing (the 2026-10-13
# "stuck selected on one control" bug). Run windowed too: a Retina window has a 2x final transform.
var frames := 0
var buttons: Array = []
var presses: Array = []
var root_ctl: Control
var bad := 0
func _initialize() -> void:
	root_ctl = Control.new()
	root_ctl.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(root_ctl)
func _process(_d: float) -> bool:
	frames += 1
	var pc: Node = root.get_node("PadCursor")
	if frames == 3:
		var vp: Vector2 = root.get_visible_rect().size
		for i in 9:
			var b := Button.new()
			b.text = str(i)
			b.name = "B%d" % i
			b.size = Vector2(80, 40)
			b.position = Vector2(vp.x * (0.15 + 0.35 * (i % 3)), vp.y * (0.15 + 0.35 * (i / 3)))
			b.pressed.connect(func(): presses.append(i))
			root_ctl.add_child(b)
			buttons.append(b)
		buttons[0].grab_focus()
	if frames >= 6 and frames < 15:
		var b: Button = buttons[frames - 6]
		pc.debug_move_to(b.position + b.size * 0.5)
		# Hover never grabs focus (focus_entered handlers select / switch tabs / start editing); it lifts any
		# focus and marks the hovered control for the focus highlight instead.
		var fo: Control = root.gui_get_focus_owner()
		if fo != null and fo != b:
			bad += 1
			print("FAIL hover left focus on ", fo, " at ", frames - 6)

	if frames >= 7 and frames < 16:
		# Hover lands a frame later (Godot updates the hovered control when it processes the motion).
		var hb: Button = buttons[frames - 7]
		if not is_same(ClassicTheme.pad_hover, hb):
			bad += 1
			print("FAIL hover highlight not on button ", frames - 7, " got ", ClassicTheme.pad_hover)
	if frames == 16:
		pc.debug_move_to(Vector2(5, 5))
		if root.gui_get_focus_owner() != null:
			bad += 1; print("FAIL focus kept over empty space")
		pc.debug_press_a(true); pc.debug_press_a(false)
	if frames == 18:
		if not presses.is_empty():
			bad += 1; print("FAIL A over empty space pressed ", presses)
		var b4: Button = buttons[4]
		pc.debug_move_to(b4.position + b4.size * 0.5)
		pc.debug_press_a(true); pc.debug_press_a(false)
	if frames == 20:
		if presses != [4]:
			bad += 1; print("FAIL expected [4] got ", presses)
		print("GRID PROBE: ", "PASS" if bad == 0 else "FAIL")
		quit()
	return false
