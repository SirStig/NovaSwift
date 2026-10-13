# NOVA Swift -- a vector-drawn on/off switch for the debug suite (toggle Button subclass, so it
# keeps `toggled`, `button_pressed`, `set_pressed_no_signal` and focus like any other button).
extends Button

var on_color := Color(0.35, 0.95, 0.5)


func _init() -> void:
	toggle_mode = true
	focus_mode = Control.FOCUS_ALL
	custom_minimum_size = Vector2(40, 24)
	size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var e := StyleBoxEmpty.new()
	toggled.connect(func(_on: bool): queue_redraw())
	for s in ["normal", "hover", "pressed", "hover_pressed", "disabled", "focus"]:
		add_theme_stylebox_override(s, e)


func _draw() -> void:
	var w := 38.0
	var h := 22.0
	var o := Vector2((size.x - w) * 0.5, (size.y - h) * 0.5)
	var sb := StyleBoxFlat.new()
	sb.set_corner_radius_all(11)
	sb.anti_aliasing = true
	if button_pressed:
		sb.bg_color = on_color.darkened(0.15) if is_hovered() else on_color.darkened(0.3)
		sb.border_color = on_color
	else:
		sb.bg_color = Color(1, 1, 1, 0.2) if is_hovered() else Color(1, 1, 1, 0.12)
		sb.border_color = Color(1, 1, 1, 0.18)
	sb.set_border_width_all(1)
	draw_style_box(sb, Rect2(o, Vector2(w, h)))
	var kx := o.x + (w - 11.0 if button_pressed else 11.0)
	draw_circle(Vector2(kx, o.y + h * 0.5), 8.0, Color(1, 1, 1, 1.0) if button_pressed else Color(1, 1, 1, 0.75), true, -1.0, true)
	if has_focus():
		var ring := StyleBoxFlat.new()
		ring.bg_color = Color(0, 0, 0, 0)
		ring.border_color = Color(0.55, 1.0, 0.7)
		ring.set_border_width_all(2)
		ring.set_corner_radius_all(14)
		ring.anti_aliasing = true
		draw_style_box(ring, Rect2(o - Vector2(3, 3), Vector2(w + 6, h + 6)))


func _notification(what: int) -> void:
	if what == NOTIFICATION_MOUSE_ENTER or what == NOTIFICATION_MOUSE_EXIT or what == NOTIFICATION_FOCUS_ENTER \
			or what == NOTIFICATION_FOCUS_EXIT:
		queue_redraw()
