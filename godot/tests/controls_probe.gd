extends SceneTree
func _init() -> void:
	_run()
func _run() -> void:
	await process_frame
	var nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	nova.load_game(OS.get_environment("NOVA_DATA_DIR"))
	nova.make_world(-1)
	var t: PackedInt32Array = nova.debug_land_targets()
	print("targets ", t)
	for id in t:
		if nova.debug_dock_at(id):
			var l = JSON.parse_string(nova.outfitter_list())
			var names := []
			for o in l:
				names.append("%d:%s:%s" % [o.id, o.name, o.canBuy])
			print(id, " ", names)
	quit()
