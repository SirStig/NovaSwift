# Headless layout preview: the dummy renderer draws nothing, so this walks a built Control
# tree and composes a PNG with Image.blend_rect from the real textures (frame PICTs, button
# art, item pictures), ColorRects and ReferenceRects at their true global rects. Text is not
# rendered: each Label becomes grey/white bars where its lines would sit, so layout, clipping
# and spacing can still be checked by eye.
extends RefCounted


## `size` is the logical viewport to preview. The headless window is tiny, so the real viewport
## rect may be taller / wider than `size`: draw on the real rect, then crop `size` from its centre.
static func compose(root_ctrl: Node, size: Vector2i, path: String) -> bool:
	var vp := Vector2i(root_ctrl.get_viewport().get_visible_rect().size)
	vp = Vector2i(maxi(vp.x, size.x), maxi(vp.y, size.y))
	var img := Image.create(vp.x, vp.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.03, 0.03, 0.05, 1))
	_walk(root_ctrl, img, 1.0)
	var out := img.get_region(Rect2i((vp - size) / 2, size))
	return out.save_png(path) == OK


static func _blend(img: Image, src: Image, r: Rect2i, mode := 0) -> void:
	if r.size.x <= 0 or r.size.y <= 0 or src == null or src.is_empty():
		return
	var s: Image = src.duplicate()
	if s.is_compressed():
		s.decompress()
	s.convert(Image.FORMAT_RGBA8)
	var at := r.position
	if mode == 0:       # stretch
		s.resize(r.size.x, r.size.y, Image.INTERPOLATE_NEAREST)
	elif mode == 1:     # native size
		s.resize(maxi(1, int(round(s.get_width() * _k))), maxi(1, int(round(s.get_height() * _k))), Image.INTERPOLATE_NEAREST)
	elif mode == 2 or mode == 3:   # aspect fit (2) / cover (3)
		var kx: float = float(r.size.x) / float(s.get_width())
		var ky: float = float(r.size.y) / float(s.get_height())
		var k: float = minf(kx, ky) if mode == 2 else maxf(kx, ky)
		s.resize(maxi(1, int(s.get_width() * k)), maxi(1, int(s.get_height() * k)), Image.INTERPOLATE_NEAREST)
		at = r.position + (r.size - s.get_size()) / 2
	var clip := Rect2i(Vector2i.ZERO, img.get_size()).intersection(Rect2i(at, s.get_size()))
	if clip.size.x <= 0:
		return
	img.blend_rect(s, Rect2i(clip.position - at, clip.size), clip.position)


static var _k := 1.0


static func _fill(img: Image, r: Rect2i, c: Color) -> void:
	var clip := Rect2i(Vector2i.ZERO, img.get_size()).intersection(r)
	if clip.size.x <= 0 or clip.size.y <= 0:
		return
	var s := Image.create(clip.size.x, clip.size.y, false, Image.FORMAT_RGBA8)
	s.fill(c)
	img.blend_rect(s, Rect2i(Vector2i.ZERO, clip.size), clip.position)


static func _grect(c: Control) -> Rect2i:
	var xf := c.get_global_transform()
	var p := xf.origin
	var sc := xf.get_scale()
	return Rect2i(Vector2i(p.round()), Vector2i((c.size * sc).round()))


static func _walk(n: Node, img: Image, _unused: float) -> void:
	if n is CanvasItem and not n.visible:
		return
	if n is Control:
		var c: Control = n
		var r := _grect(c)
		var sc := c.get_global_transform().get_scale().x
		_k = sc
		if c is ColorRect:
			_fill(img, r, c.color)
		elif c is TextureRect:
			if c.texture != null:
				var m := 0
				match c.stretch_mode:
					TextureRect.STRETCH_KEEP, TextureRect.STRETCH_KEEP_CENTERED: m = 1
					TextureRect.STRETCH_KEEP_ASPECT, TextureRect.STRETCH_KEEP_ASPECT_CENTERED: m = 2
					TextureRect.STRETCH_KEEP_ASPECT_COVERED: m = 3
				_blend(img, c.texture.get_image(), r, m)
		elif c is TextureButton:
			var t: Texture2D = c.texture_disabled if c.disabled and c.texture_disabled != null else c.texture_normal
			if t != null:
				_blend(img, t.get_image(), r, 0)
			var lab = c.get("label")
			if lab != null and str(lab) != "":
				_bars(img, str(lab), r, 12.0 * sc, Color(1, 1, 1, 0.55 if c.disabled else 0.95), true)
			if c.has_focus():
				img.fill_rect(Rect2i(r.position, Vector2i(r.size.x, 1)), Color(1, 0.78, 0.35))
		elif c is ReferenceRect:
			var col: Color = c.border_color
			var w := maxi(1, int(c.border_width * sc))
			_fill(img, Rect2i(r.position, Vector2i(r.size.x, w)), col)
			_fill(img, Rect2i(r.position + Vector2i(0, r.size.y - w), Vector2i(r.size.x, w)), col)
			_fill(img, Rect2i(r.position, Vector2i(w, r.size.y)), col)
			_fill(img, Rect2i(r.position + Vector2i(r.size.x - w, 0), Vector2i(w, r.size.y)), col)
		elif c is LineEdit:
			_fill(img, r, Color(1, 1, 1, 1))
		elif c is Label:
			_bars(img, c.text, r, float(c.get_theme_font_size("font_size")) * sc, c.get_theme_color("font_color"), c.horizontal_alignment == HORIZONTAL_ALIGNMENT_CENTER, c.horizontal_alignment == HORIZONTAL_ALIGNMENT_RIGHT)
		if c is ScrollContainer or (c.clip_contents and c.get_child_count() > 0 and not (c is Label)):
			# children are clipped to this control in the real thing
			var sub := Image.create(img.get_width(), img.get_height(), false, Image.FORMAT_RGBA8)
			for ch in n.get_children():
				_walk(ch, sub, 1.0)
			var clip := Rect2i(Vector2i.ZERO, img.get_size()).intersection(r)
			if clip.size.x > 0 and clip.size.y > 0:
				img.blend_rect(sub, clip, clip.position)
			return
	for ch in n.get_children():
		_walk(ch, img, 1.0)


static func _bars(img: Image, text: String, r: Rect2i, fs: float, col: Color, center := false, right := false) -> void:
	if text == "" or fs < 4:
		return
	var cw := fs * 0.52
	var per_line := maxi(1, int(r.size.x / cw))
	var y := r.position.y + int(fs * 0.25)
	var lines: PackedStringArray = text.split("\n")
	var shown := 0
	for ln in lines:
		var rem := ln.length()
		if rem == 0:
			y += int(fs + 2)
			continue
		while rem > 0 and y + fs <= r.end.y + 2:
			var take := mini(rem, per_line)
			var w := int(take * cw)
			var x := r.position.x
			if center:
				x += (r.size.x - w) / 2
			elif right:
				x += r.size.x - w
			_fill(img, Rect2i(x, y + int(fs * 0.25), w, maxi(2, int(fs * 0.45))), Color(col.r, col.g, col.b, 0.8))
			rem -= take
			y += int(fs + 2)
			shown += 1
		if y + fs > r.end.y + 2:
			break
