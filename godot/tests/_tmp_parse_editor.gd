extends SceneTree
func _init() -> void:
	for p in ["res://editor/EditorTheme.gd", "res://editor/EditorCanvas.gd", "res://editor/GalaxyCanvas.gd", "res://editor/SystemCanvas.gd", "res://editor/StoryCanvas.gd", "res://editor/Previews.gd"]:
		var s = load(p)
		print(p, " -> ", s != null and s.can_instantiate())
	var ET = load("res://editor/EditorTheme.gd")
	for n in ET.GLYPHS:
		var img: Image = ET.SVG.image(n, 24, Color.WHITE)
		var used := img.get_used_rect()
		if used.size.x < 4: print("EMPTY GLYPH ", n)
	quit()
