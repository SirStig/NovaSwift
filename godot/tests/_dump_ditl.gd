extends SceneTree
func _init() -> void:
	var nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	nova.load_game(OS.get_environment("NOVA_DATA_DIR"))
	for id in [1000,1001,1002,1004,1005,1006,1007,1008,1009,1011,1012,1013,1015,1016,1017,1019,1022,1023]:
		var d = JSON.parse_string(nova.classic_dialog(id))
		if not (d is Dictionary) or d.is_empty():
			print("== ", id, " none"); continue
		print("== ", id, " ", d.w, "x", d.h, " design ", d.designW, "x", d.designH, " title=", d.title)
		for it in d.items:
			print("  ", it.i, " ", it.kind, " (", it.l, ",", it.t, ",", it.r, ",", it.b, ") res=", it.res, " en=", it.enabled, " '", str(it.text).left(40).replace("\n"," "), "'")
	quit()
