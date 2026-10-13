extends Node2D

const Art = preload("res://screens/controls_editor/ControllerArt.gd")

var _shots: Array = []

func _ready() -> void:
	for st in ["xbox", "playstation", "switch", "deck"]:
		var rg: PackedVector2Array = Art.ring(st)
		var tris := Geometry2D.triangulate_polygon(rg)
		print(st, " ring pts ", rg.size(), " tri idx ", tris.size(), " area ", _area(rg))
	var scr: PackedVector2Array = Art._rect_pts(Vector2(0, -4), Vector2(150, 92), 4.5)
	print("screen pts ", scr.size(), " tri ", Geometry2D.triangulate_polygon(scr).size(), " area ", _area(scr), " p0 ", scr[0], " pmid ", scr[scr.size() / 2])
	RenderingServer.set_default_clear_color(Color(0.055, 0.058, 0.065))
	get_window().size = Vector2i(1400, 900)
	await get_tree().process_frame
	var styles := ["xbox", "playstation", "switch", "deck"]
	for i in styles.size():
		_shots = [styles[i]]
		queue_redraw()
		await RenderingServer.frame_post_draw
		await get_tree().process_frame
		var img := get_viewport().get_texture().get_image()
		var win := get_window().size
		if i == 0:
			print("tex ", img.get_size(), " win ", win)
		# The framebuffer is retina-scaled; the art was drawn in window points.
		if img.get_width() != win.x:
			img.resize(win.x, win.y, Image.INTERPOLATE_BILINEAR)
		var ext: Rect2 = Art.layout(styles[i]).extent
		var s := 3.4 if styles[i] != "deck" else 2.4
		# Chassis shadow hangs below the outline; leave room for it.
		var pad := 36
		var r := Rect2i(Vector2i(4, 4), Vector2i(int(ext.size.x * s) + pad * 2, int(ext.size.y * s) + pad * 2 + 28))
		r = r.intersection(Rect2i(Vector2i.ZERO, img.get_size()))
		img.get_region(r).save_png("/tmp/pad-%s.png" % styles[i])
		print("saved ", styles[i], " extent ", ext, " crop ", r.size)
	get_tree().quit()


func _area(p: PackedVector2Array) -> float:
	var a := 0.0
	var n := p.size()
	for i in n:
		var q: Vector2 = p[(i + 1) % n]
		a += p[i].x * q.y - q.x * p[i].y
	return a * 0.5


func _draw() -> void:
	if _shots.is_empty():
		return
	var font := ThemeDB.fallback_font
	var st: String = _shots[0]
	var s := 3.4 if st != "deck" else 2.4
	var ext: Rect2 = Art.layout(st).extent
	var xf := Vector2(40 - ext.position.x * s, 40 - ext.position.y * s)
	draw_set_transform(xf, 0.0, Vector2(s, s))
	var texts: Array = []
	Art.draw(self, st, {}, 1.0 / s, texts)
	draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	for t in texts:
		var fs := int(maxf(8.0, float(t.size) * s))
		var pos: Vector2 = xf + (t.pos as Vector2) * s
		var w := font.get_string_size(str(t.text), HORIZONTAL_ALIGNMENT_LEFT, -1, fs)
		draw_string(font, pos + Vector2(-w.x * 0.5, fs * 0.35), str(t.text), HORIZONTAL_ALIGNMENT_LEFT, -1, fs, t.col)
