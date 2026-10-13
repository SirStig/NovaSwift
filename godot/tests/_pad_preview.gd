extends Node2D

const Art = preload("res://screens/controls_editor/ControllerArt.gd")

var _style := ""
var _s := 2.0
var _xf := Vector2.ZERO


func _ready() -> void:
	RenderingServer.set_default_clear_color(Color(0.055, 0.058, 0.065))
	get_window().size = Vector2i(1800, 1200)
	await get_tree().process_frame
	await get_tree().process_frame
	var vis := get_viewport().get_visible_rect().size
	print("visible ", vis, " win ", get_window().size)
	for st in ["xbox", "playstation", "switch", "deck"]:
		var ext: Rect2 = Art.layout(st).extent
		var margin := 48.0
		_s = minf((vis.x - margin * 2.0) / ext.size.x, (vis.y - margin * 2.0) / ext.size.y)
		_xf = Vector2(margin, margin) - ext.position * _s
		_style = st
		queue_redraw()
		await RenderingServer.frame_post_draw
		await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		var pr := img.get_width() / vis.x
		var r := Rect2i(Vector2i(int((margin - 20.0) * pr), int((margin - 20.0) * pr)),
			Vector2i(int((ext.size.x * _s + 40.0) * pr), int((ext.size.y * _s + 56.0) * pr)))
		r = r.intersection(Rect2i(Vector2i.ZERO, img.get_size()))
		var shot := img.get_region(r)
		if pr > 1.1:
			shot.resize(maxi(1, int(shot.get_width() / pr)), maxi(1, int(shot.get_height() / pr)), Image.INTERPOLATE_BILINEAR)
		shot.save_png("/tmp/pad-%s.png" % st)
		print("saved ", st, " s ", snapped(_s, 0.01), " shot ", shot.get_size(), " pr ", snapped(pr, 0.01))
	get_tree().quit()


func _draw() -> void:
	if _style == "":
		return
	var font := ThemeDB.fallback_font
	draw_set_transform(_xf, 0.0, Vector2(_s, _s))
	var texts: Array = []
	Art.draw(self, _style, {}, 1.0 / _s, texts)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	for t in texts:
		var fs := int(maxf(8.0, float(t.size) * _s))
		var pos: Vector2 = _xf + (t.pos as Vector2) * _s
		var w := font.get_string_size(str(t.text), HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		draw_string(font, pos + Vector2(-w.x * 0.5, fs * 0.35), str(t.text), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, t.col)
