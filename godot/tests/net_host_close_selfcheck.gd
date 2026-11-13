# Host-close selfcheck: a player in this process joins a host running in a separate process, the host closes the game,
# and the player must be told why ("The host closed the game.") rather than just losing the connection.
#   godot --headless --path godot -s res://tests/net_host_close_selfcheck.gd
extends SceneTree

const Prefs = preload("res://Prefs.gd")

const PORT := 53993
var ok_all: bool = true


func _init() -> void:
	_run.call_deferred()


func _check(label: String, cond: bool) -> void:
	print(("  ok   " if cond else "  FAIL ") + label)
	if not cond:
		ok_all = false


func _pump(seconds: float, until: Callable = Callable()) -> bool:
	var n: int = int(seconds / 0.02)
	for i in n:
		if until.is_valid() and until.call():
			return true
		await create_timer(0.02).timeout
	return false


func _run() -> void:
	await process_frame
	Prefs.path = OS.get_user_data_dir() + "/net_host_close_settings.cfg"
	DirAccess.remove_absolute(Prefs.path)
	Prefs.load_all()
	var svc: Node = (load("res://net/NetService.gd") as GDScript).new()
	root.add_child(svc)
	var helper: int = OS.create_process(OS.get_executable_path(), ["--headless", "--path", ProjectSettings.globalize_path("res://"),
		"-s", "res://tests/net_host_close_helper.gd", "--", str(PORT)])
	_check("helper host process started", helper > 0)
	await _pump(3.0)
	svc.join_game("127.0.0.1", PORT, "", "Tester")
	await _pump(15.0, func(): return svc.is_connected_to_session())
	_check("joined the other process's game", svc.is_connected_to_session())
	await _pump(10.0, func(): return not svc.is_active())
	await _pump(1.0)
	_check("the player was told the host closed the game", svc.last_error_code == "kicked" and svc.last_error.find("host closed") >= 0)
	OS.kill(helper)
	svc.queue_free()
	await process_frame
	print("NET HOST CLOSE: " + ("PASS" if ok_all else "FAIL"))
	quit(0 if ok_all else 1)
