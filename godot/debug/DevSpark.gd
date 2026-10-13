# NOVA Swift -- a tiny rolling sparkline for the Tools tab's metric tiles.
extends Control

var values := PackedFloat32Array()
var color := Color(0.35, 0.95, 0.5)
var cap := 60
var floor_zero := true


func _init() -> void:
	custom_minimum_size = Vector2(0, 22)
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func push(v: float) -> void:
	values.append(v)
	if values.size() > cap:
		values.remove_at(0)
	queue_redraw()


func _draw() -> void:
	var n := values.size()
	if n < 2:
		return
	var lo := 0.0 if floor_zero else values[0]
	var hi := 0.001
	for v in values:
		hi = maxf(hi, v)
		if not floor_zero:
			lo = minf(lo, v)
	var span := maxf(hi - lo, 0.001)
	var pts := PackedVector2Array()
	for i in n:
		var x := size.x * float(i) / float(cap - 1)
		var y := size.y - 2.0 - (size.y - 4.0) * (values[i] - lo) / span
		pts.append(Vector2(x, y))
	var fill := PackedVector2Array(pts)
	fill.append(Vector2(pts[n - 1].x, size.y))
	fill.append(Vector2(pts[0].x, size.y))
	draw_colored_polygon(fill, Color(color.r, color.g, color.b, 0.14))
	draw_polyline(pts, color, 1.5, true)
