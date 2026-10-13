extends SceneTree
const E = preload("res://screens/controls_editor/ControlsEditor.gd")
func _init() -> void:
	var e = E.new()
	root.add_child(e)
	e.setup()
	await process_frame
	await process_frame
	print("rows ", e.rows.size())
	e.set_tab(1)
	await process_frame
	quit()
