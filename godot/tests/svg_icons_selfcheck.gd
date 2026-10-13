# Headless check: every NovaSVG glyph parses and draws something; NovaIcons routes to it.
extends SceneTree

const SVG = preload("res://ui/novaswift/NovaSVG.gd")
const Icons = preload("res://ui/novaswift/NovaIcons.gd")


func _init() -> void:
	var bad := []
	for name in SVG.GLYPHS.keys():
		var img: Image = SVG.image(name, 32, Color(1, 0.7, 0.28))
		var lit := 0
		for y in 32:
			for x in 32:
				if img.get_pixel(x, y).a > 0.1:
					lit += 1
		if img.get_size() != Vector2i(32, 32) or lit < 8:
			bad.append("%s (lit=%d)" % [name, lit])
	if Icons.texture("terminal", 16).get_size() != Vector2(16, 16):
		bad.append("NovaIcons routing")
	if not bad.is_empty():
		push_error("svg_icons_selfcheck: FAIL " + ", ".join(bad))
		quit(1)
		return
	print("svg_icons_selfcheck: OK (%d glyphs)" % SVG.GLYPHS.size())
	quit(0)
