# NOVA Swift — 1 logical pixel = 1 screen point (autoload).
#
# The project's canvas_items stretch used to scale everything from a fixed
# 1280×720 base up to the window, so on a big desktop window the flight view,
# HUD and dialogs were all magnified to fill it. Neither the original nor the
# Apple app does that: a larger screen shows MORE of space, and the authentic
# UI stays near its native pixel size (dialogs grow only by
# ClassicUIGeometry.crispScale's reference-screen rule).
#
# So the logical viewport tracks the window's size in points: window pixels ÷
# the display's backing scale (2 on a Retina Mac, 1 on a Steam Deck / most Linux
# and Windows screens). The Deck's 1280×800 panel stays exactly 1280×800.

extends Node


func _ready() -> void:
	if DisplayServer.get_name() == "headless":
		return
	get_window().size_changed.connect(_apply)
	_apply()


func _apply() -> void:
	var win := get_window()
	var scale := maxf(1.0, DisplayServer.screen_get_scale(win.current_screen))
	win.content_scale_size = Vector2i((Vector2(win.size) / scale).round())
