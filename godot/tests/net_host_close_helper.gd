# Helper for net_host_close_selfcheck.gd (not a self-check of its own): a separate host process that waits for one
# player, then closes the game the way a host does, so the goodbye has to cross a real process boundary.
#   godot --headless --path godot -s res://tests/net_host_close_helper.gd -- <port>
extends SceneTree

const Transport = preload("res://net/NetTransport.gd")


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	var port: int = int(OS.get_cmdline_user_args()[0])
	var srv: RefCounted = Transport.new()
	srv.host(null, {"port": port, "max_players": 4, "name": "close-test", "display_name": "[Server]", "has_local_player": false})
	var waited: float = 0.0
	var ready_for: float = 0.0
	while waited < 30.0:
		srv.poll(0.02)
		if srv.ready_count() > 0:
			ready_for += 0.02
			if ready_for > 1.0:
				break
		waited += 0.02
		await create_timer(0.02).timeout
	srv.close()   # the host closes the game: every player is told
	quit(0)
