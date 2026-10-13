# Media previews for the inspector: a checkerboard sprite viewer with zoom and frame playback,
# and a sound waveform with a playhead.
extends RefCounted

const EdTheme = preload("res://editor/EditorTheme.gd")


class GraphicView extends Control:
	var texture: Texture2D
	var scale_mode := 0      # 0 = fit, else integer zoom
	var fixed := false       # keep the given minimum size (thumbnail tiles)

	func _init() -> void:
		custom_minimum_size = Vector2(0, 260)
		size_flags_horizontal = Control.SIZE_EXPAND_FILL
		clip_contents = true
		texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST

	func set_texture(t: Texture2D) -> void:
		texture = t
		if t != null and not fixed:
			var want := float(t.get_height()) * (1.0 if scale_mode == 0 else float(scale_mode)) + 32.0
			custom_minimum_size.y = clampf(want, 160.0, 640.0)
		queue_redraw()

	func _draw() -> void:
		var cell := 8.0 if fixed else 10.0
		var y := 0.0
		var row := 0
		while y < size.y:
			var x := cell if row % 2 == 1 else 0.0
			draw_rect(Rect2(0, y, size.x, cell), Color(0.16, 0.16, 0.17), true)
			while x < size.x:
				draw_rect(Rect2(x, y, cell, cell), Color(0.21, 0.21, 0.22), true)
				x += cell * 2
			y += cell
			row += 1
		if texture == null:
			return
		var ts := Vector2(texture.get_size())
		var k := 1.0
		if scale_mode == 0:
			var pad := 8.0 if fixed else 24.0
			k = minf((size.x - pad) / maxf(1.0, ts.x), (size.y - pad) / maxf(1.0, ts.y))
			if k >= 1.0:
				k = floorf(k)
		else:
			k = float(scale_mode)
		var ds := ts * k
		draw_texture_rect(texture, Rect2((size - ds) * 0.5, ds), false)


class Waveform extends Control:
	var peaks := PackedFloat32Array()
	var progress := -1.0

	func _init() -> void:
		custom_minimum_size = Vector2(0, 96)
		size_flags_horizontal = Control.SIZE_EXPAND_FILL

	## pcm: 16-bit little-endian mono.
	func set_pcm(pcm: PackedByteArray) -> void:
		peaks.clear()
		var n := pcm.size() / 2
		if n <= 0:
			queue_redraw()
			return
		var cols := 400
		var per := maxi(1, n / cols)
		var i := 0
		while i < n:
			var hi := 0.0
			var end := mini(n, i + per)
			var j := i
			while j < end:
				var v := absf(float(pcm.decode_s16(j * 2)) / 32768.0)
				if v > hi:
					hi = v
				j += maxi(1, per / 64)
			peaks.append(hi)
			i += per
		queue_redraw()

	func _draw() -> void:
		draw_style_box(EdTheme.T.box(Color(0, 0, 0, 0.3), 8, Color(1, 1, 1, 0.07), 1), Rect2(Vector2.ZERO, size))
		if peaks.is_empty():
			return
		var mid := size.y * 0.5
		var w := size.x - 16
		var step := w / float(peaks.size())
		for i in peaks.size():
			var x := 8 + i * step
			var h := maxf(1.0, peaks[i] * (size.y * 0.42))
			var played := progress >= 0 and float(i) / float(peaks.size()) <= progress
			draw_line(Vector2(x, mid - h), Vector2(x, mid + h), EdTheme.AMBER if played else Color(1, 1, 1, 0.45), maxf(1.0, step * 0.6))
		if progress >= 0:
			var px := 8 + w * progress
			draw_line(Vector2(px, 4), Vector2(px, size.y - 4), Color.WHITE, 1.5)
