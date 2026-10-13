# Headless self-check for pilot create -> save -> list -> load -> delete through
# the bridge. Run:
#   NOVA_DATA_DIR=data/base godot --headless --path godot -s res://tests/pilot_selfcheck.gd
# Optional PILOT_CHECK_DIR picks the pilot directory (default: a temp dir).
extends SceneTree


func _init() -> void:
	var nova = ClassDB.instantiate("NovaWorld")
	var data := OS.get_environment("NOVA_DATA_DIR")
	if data == "":
		data = ProjectSettings.globalize_path("res://") + "../data/base"
	var dir := OS.get_environment("PILOT_CHECK_DIR")
	if dir == "":
		dir = OS.get_user_data_dir() + "/pilot_selfcheck"
	var ok := true
	ok = _check("load_game", nova.load_game(data)) and ok
	var scen = JSON.parse_string(nova.pilot_scenarios())
	print("scenarios: ", scen)
	ok = _check("has scenarios", scen is Array and scen.size() > 0) and ok
	var name_: String = nova.pilot_random_name()
	var id: String = nova.pilot_create(dir, int(scen[0].id), name_, true, "", "")
	print("created ", name_, " id=", id)
	ok = _check("create", id != "") and ok
	ok = _check("make_world", nova.make_world(-1)) and ok
	var credits: int = nova.player_credits()
	ok = _check("autosave launch writes", nova.pilot_autosave("launch")) and ok
	ok = _check("autosave jump skipped (not an original save point)", not nova.pilot_autosave("jump")) and ok
	var list = JSON.parse_string(nova.pilot_list(dir))
	print("list: ", list)
	ok = _check("listed", list.size() >= 1 and list[0].name == name_) and ok

	# Fresh world instance = a relaunch: load the pilot from disk.
	var nova2 = ClassDB.instantiate("NovaWorld")
	nova2.load_game(data)
	ok = _check("load", nova2.pilot_load(dir, id)) and ok
	ok = _check("make_world after load", nova2.make_world(-1)) and ok
	ok = _check("name round-trips", nova2.pilot_name() == name_) and ok
	ok = _check("credits round-trip", nova2.player_credits() == credits) and ok
	ok = _check("ship round-trips", nova2.player_ship_type() == nova.player_ship_type()) and ok
	ok = _check("delete", nova2.pilot_delete(dir, id)) and ok
	list = JSON.parse_string(nova.pilot_list(dir))
	ok = _check("gone", list.size() == 0) and ok
	print("PILOT SELFCHECK ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)


func _check(label: String, cond: bool) -> bool:
	print(("  ok   " if cond else "  FAIL ") + label)
	return cond
