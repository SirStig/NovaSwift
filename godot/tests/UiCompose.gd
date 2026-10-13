# Headless layout preview: the dummy renderer draws nothing, so this walks a built Control
# tree and composes a PNG with Image.blend_rect from the real textures (frame PICTs, button
# art, item pictures), ColorRects and ReferenceRects at their true global rects. Text is not
# rendered: each Label becomes grey/white bars where its lines would sit, so layout, clipping
# and spacing can still be checked by eye.
extends RefCounted


## `size` is the logical viewport to preview. The headless window is tiny, so the real viewport
## rect may be taller / wider than `size`: draw on the real rect, then crop `size` from its centre.
static func compose(root_ctrl: Node, size: Vector2i, path: String, top_left := false) -> bool:
	var vp := Vector2i(root_ctrl.get_viewport().get_visible_rect().size)
	vp = Vector2i(maxi(vp.x, size.x), maxi(vp.y, size.y))
	var img := Image.create(vp.x, vp.y, false, Image.FORMAT_RGBA8)
	img.fill(Color(0.03, 0.03, 0.05, 1))
	_walk(root_ctrl, img, 1.0)
	var out := img.get_region(Rect2i(Vector2i.ZERO if top_left else (vp - size) / 2, size))
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
			var le: LineEdit = c
			var sb := le.get_theme_stylebox("normal")
			if sb is StyleBoxFlat:
				_flat(img, r, sb, sc)
				var col: Color = le.get_theme_color("font_color") if le.text != "" else le.get_theme_color("font_placeholder_color")
				_text_at(img, le.text if le.text != "" else le.placeholder_text, Rect2i(r.position + Vector2i(int(sb.get_margin(SIDE_LEFT) * sc), 0), r.size), le.get_theme_font("font"), float(le.get_theme_font_size("font_size")) * sc, col, 0)
			elif sb is StyleBoxEmpty:
				var col2: Color = le.get_theme_color("font_color") if le.text != "" else le.get_theme_color("font_placeholder_color")
				_text_at(img, le.text if le.text != "" else le.placeholder_text, r, le.get_theme_font("font"), float(le.get_theme_font_size("font_size")) * sc, col2, 0)
			else:
				_fill(img, r, Color(1, 1, 1, 1))
		elif c is Panel or c is PanelContainer:
			var psb := c.get_theme_stylebox("panel")
			if psb is StyleBoxFlat:
				_flat(img, r, psb, sc)
		elif c is HSlider:
			_slider_draw(img, c, r, sc)
		elif c is ProgressBar:
			var pb: ProgressBar = c
			var bgsb := pb.get_theme_stylebox("background")
			if bgsb is StyleBoxFlat:
				_flat(img, r, bgsb, sc)
			var fsb := pb.get_theme_stylebox("fill")
			if fsb is StyleBoxFlat and pb.value > pb.min_value:
				_flat(img, Rect2i(r.position, Vector2i(int(r.size.x * (pb.value - pb.min_value) / (pb.max_value - pb.min_value)), r.size.y)), fsb, sc)
		elif c is Button and not (c is TextureButton):
			_button_draw(img, c, r, sc)
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


# --- StyleBoxFlat / Button / slider drawing (the NovaSwift kit is StyleBox-based) -----------------

## A StyleBoxFlat: fill, rounded corners and border, composed into a temp image and blended.
static func _flat(img: Image, r: Rect2i, sb: StyleBox, sc: float) -> void:
	if not (sb is StyleBoxFlat) or r.size.x <= 0 or r.size.y <= 0:
		return
	var f: StyleBoxFlat = sb
	var w := r.size.x
	var h := r.size.y
	if f.bg_color.a <= 0.0 and f.border_width_left == 0:
		return
	var rad := mini(int(f.corner_radius_top_left * sc), mini(w, h) / 2)
	var bw := int(f.border_width_left * sc) if f.border_width_left > 0 else 0
	var tmp := Image.create(w, h, false, Image.FORMAT_RGBA8)
	tmp.fill(f.bg_color)
	if bw > 0:
		var bc := f.border_color
		for rect in [Rect2i(0, 0, w, bw), Rect2i(0, h - bw, w, bw), Rect2i(0, 0, bw, h), Rect2i(w - bw, 0, bw, h)]:
			tmp.fill_rect(rect, bc)
	if rad > 1:
		for cy in rad:
			for cx in rad:
				# distance from the arc centre for the top-left quadrant, mirrored to the others
				var d := Vector2(rad - cx - 0.5, rad - cy - 0.5).length()
				var a := clampf(rad - d + 0.5, 0.0, 1.0)
				var in_border := bw > 0 and d > rad - bw
				for q in 4:
					var px := cx if q & 1 == 0 else w - 1 - cx
					var py := cy if q & 2 == 0 else h - 1 - cy
					var base: Color = f.border_color if in_border else f.bg_color
					tmp.set_pixel(px, py, Color(base.r, base.g, base.b, base.a * a))
	_blend(img, tmp, r, 4)


static func _text_at(img: Image, text: String, r: Rect2i, font: Font, fs: float, col: Color, align: int) -> void:
	if text == "" or fs < 4:
		return
	var w := int(font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, int(fs)).x)
	w = mini(w, r.size.x)
	var x := r.position.x
	if align == 1:
		x += (r.size.x - w) / 2
	elif align == 2:
		x += r.size.x - w
	var yc := r.position.y + r.size.y / 2
	_fill(img, Rect2i(x, yc - int(fs * 0.3), w, maxi(2, int(fs * 0.52))), Color(col.r, col.g, col.b, 0.8 * col.a))


static func _button_draw(img: Image, c: Control, r: Rect2i, sc: float) -> void:
	var b: Button = c
	var st := "normal"
	if b.disabled:
		st = "disabled"
	elif b.button_pressed:
		st = "pressed"
	var sb := b.get_theme_stylebox(st)
	if sb is StyleBoxFlat:
		_flat(img, r, sb, sc)
	var ml := int(sb.get_margin(SIDE_LEFT) * sc) if sb != null else 0
	var mr := int(sb.get_margin(SIDE_RIGHT) * sc) if sb != null else 0
	var inner := Rect2i(r.position + Vector2i(ml, 0), Vector2i(maxi(1, r.size.x - ml - mr), r.size.y))
	var font := b.get_theme_font("font")
	var fs := float(b.get_theme_font_size("font_size")) * sc
	var col := b.get_theme_color("font_disabled_color") if b.disabled else (b.get_theme_color("font_pressed_color") if b.button_pressed else b.get_theme_color("font_color"))
	var icon: Texture2D = b.icon
	if b is CheckBox:
		icon = b.get_theme_icon("checked" if b.button_pressed else "unchecked")
	var tw := int(font.get_string_size(b.text, HORIZONTAL_ALIGNMENT_LEFT, -1, int(fs)).x) if b.text != "" else 0
	var iw := int(icon.get_width() * sc) if icon != null else 0
	var gap := int(b.get_theme_constant("h_separation") * sc) if (icon != null and b.text != "") else 0
	var total := iw + gap + tw
	var x := inner.position.x
	if b.alignment == HORIZONTAL_ALIGNMENT_CENTER:
		x += maxi(0, (inner.size.x - total) / 2)
	elif b.alignment == HORIZONTAL_ALIGNMENT_RIGHT:
		x += maxi(0, inner.size.x - total)
	if icon != null:
		var ic := b.get_theme_color("icon_pressed_color") if b.button_pressed else b.get_theme_color("icon_normal_color")
		var ii := icon.get_image()
		if ii != null:
			var tinted: Image = ii.duplicate()
			if tinted.is_compressed():
				tinted.decompress()
			tinted.convert(Image.FORMAT_RGBA8)
			if not (b is CheckBox) and ic != Color(1, 1, 1, 1):
				for yy in tinted.get_height():
					for xx in tinted.get_width():
						var pc := tinted.get_pixel(xx, yy)
						tinted.set_pixel(xx, yy, Color(pc.r * ic.r, pc.g * ic.g, pc.b * ic.b, pc.a * ic.a))
			_blend(img, tinted, Rect2i(Vector2i(x, r.position.y + (r.size.y - int(icon.get_height() * sc)) / 2), Vector2i(iw, int(icon.get_height() * sc))), 0)
	if b.text != "":
		_text_at(img, b.text, Rect2i(Vector2i(x + iw + gap, r.position.y), Vector2i(tw + 2, r.size.y)), font, fs, col, 0)
	if b is OptionButton:
		var arrow := b.get_theme_icon("arrow")
		if arrow != null:
			var am := int(b.get_theme_constant("arrow_margin") * sc)
			_blend(img, arrow.get_image(), Rect2i(Vector2i(r.end.x - mr - int(arrow.get_width() * sc) - am + int(mr * 0.5), r.position.y + (r.size.y - int(arrow.get_height() * sc)) / 2), Vector2i(int(arrow.get_width() * sc), int(arrow.get_height() * sc))), 0)
	if b.has_focus() and b.get_theme_stylebox("focus") is StyleBoxFlat:
		_flat(img, r, b.get_theme_stylebox("focus"), sc)


static func _slider_draw(img: Image, c: Control, r: Rect2i, sc: float) -> void:
	var s: HSlider = c
	var track := s.get_theme_stylebox("slider")
	var fill := s.get_theme_stylebox("grabber_area")
	var knob := s.get_theme_icon("grabber")
	var th := int(4 * sc)
	var tr := Rect2i(r.position + Vector2i(0, (r.size.y - th) / 2), Vector2i(r.size.x, th))
	var frac := 0.0 if s.max_value <= s.min_value else (s.value - s.min_value) / (s.max_value - s.min_value)
	if track is StyleBoxFlat:
		_flat(img, tr, track, sc)
	var kw := int(knob.get_width() * sc) if knob != null else 0
	var kx := r.position.x + int((r.size.x - kw) * frac)
	if fill is StyleBoxFlat:
		_flat(img, Rect2i(tr.position, Vector2i(kx - r.position.x + kw / 2, th)), fill, sc)
	if knob != null:
		_blend(img, knob.get_image(), Rect2i(Vector2i(kx, r.position.y + (r.size.y - int(knob.get_height() * sc)) / 2), Vector2i(kw, int(knob.get_height() * sc))), 0)
