# NOVA Swift — the Preferences "Brightness" arrows (STR# 139, steps 0-6).
#
# The original sets a display gamma of step x 10 + 70 percent (0x00416100; 100 at the default
# step 3). The Apple app approximates it as a veil over everything (RootView.brightnessVeil):
# below 100 a black overlay of opacity 1 - gamma, above 100 a white one added over the picture
# at (gamma - 1) / 2. Same here: one full-screen ColorRect on a top CanvasLayer that never takes
# input, re-read from Prefs whenever the step changes (the Preferences dialog saves it live).
extends CanvasLayer

const Prefs = preload("res://Prefs.gd")

const MAX_STEP := 6

var _rect: ColorRect
var _step := -1


func _ready() -> void:
	layer = 127
	process_mode = Node.PROCESS_MODE_ALWAYS
	_rect = ColorRect.new()
	_rect.name = "Veil"
	_rect.set_anchors_preset(Control.PRESET_FULL_RECT)
	_rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_rect)
	_apply()


func _process(_delta: float) -> void:
	var step: int = clampi(int(Prefs.get_value("classic", "brightness_step")), 0, MAX_STEP)
	if step != _step:
		_apply()


## The veil's colour for a brightness step (also the unit-test seam): rgba, alpha 0 = no veil.
static func veil_for_step(step: int) -> Color:
	var gamma: float = float(clampi(step, 0, MAX_STEP) * 10 + 70) / 100.0
	if gamma < 1.0:
		return Color(0, 0, 0, 1.0 - gamma)
	if gamma > 1.0:
		return Color(1, 1, 1, (gamma - 1.0) * 0.5)
	return Color(0, 0, 0, 0)


func _apply() -> void:
	_step = clampi(int(Prefs.get_value("classic", "brightness_step")), 0, MAX_STEP)
	var c: Color = veil_for_step(_step)
	_rect.color = c
	_rect.visible = c.a > 0.0
	var mat: CanvasItemMaterial = null
	if c.r > 0.5 and c.a > 0.0:   # the white veil adds light (SwiftUI .plusLighter)
		mat = CanvasItemMaterial.new()
		mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_rect.material = mat
