# NOVA Swift -- dedicated server ("like Minecraft": a headless server you run, others join by address).
#
#   godot --headless --path godot -- --server [--port N] [--name "..."] [--password X] [--max-players N]
#                                     [--rules safe|full] [--config server.cfg] [--data DIR] [--no-lan]
#                                     [--no-stdin] [--log FILE]
#   (packaged:  ./NovaSwift --headless -- --server ...      scripts/run-dedicated-server.sh wraps both)
#
# Boot.gd hands over here before it ever builds Main (no menus, no flight scene, no audio). This node:
#   1. loads the game data (NOVA_DATA_DIR, --data, the data-setup folder, ... -- Prefs.find_data) into its own
#      NovaWorld, which the bridge needs to validate content and to be a session participant;
#   2. opens an ENet server (NetTransport.host) with has_local_player = false;
#   3. begins the bridge session as the HOST with peer id 1 and display name "[Server]" (net_begin(1, "[Server]",
#      true, rules)); it never calls make_world or step (a pilot-less host: no presence, not in anyone's roster). The server has no pilot, so it is never in a star system: it never becomes a system's
#      authority and is never "in my system" for anyone. Client-to-client simulation traffic is relayed by
#      NetTransport (the server is a hub); the session rules, chat log, kick/ban moderation and plug-in
#      manifest check live on the server's bridge session. If a bridge refuses a pilot-less net_begin (or is too
#      old for the net_* API) the server degrades to a plain relay: still joinable, chat works (K_CHAT), the
#      players' own bridges handle authority among themselves;
#   4. announces itself on the LAN and answers status queries (LanDiscovery);
#   5. prints a status line every 60 s and reads simple console commands from stdin:
#        status | players | kick <id|name> [reason] | ban <id|name> | say <text> | rules [safe|full] | quit
#      Commands are optional (stdin closed or --no-stdin simply disables them);
#   6. logs everything to user://logs/server.log (and Godot's own log), with timestamps.
#
# The password is compared as a SHA-256 hash and the game bytes are not encrypted: fine for friends and LANs,
# do not reuse a password that matters.
#
# Loaded at runtime by Boot.gd (never preload'ed there).
extends Node

const Proto = preload("res://net/NetProto.gd")
const Transport = preload("res://net/NetTransport.gd")
const Lan = preload("res://net/LanDiscovery.gd")
const Prefs = preload("res://Prefs.gd")
const Directory = preload("res://net/ServerDirectory.gd")
const Upnp = preload("res://net/Upnp.gd")

const STATUS_EVERY := 60.0

var opts: Dictionary = {}
var nova: Object = null
var transport: RefCounted = null
var lan: RefCounted = null
var log_path: String = "user://logs/server.log"
var _t: float = 0.0
var _events_in: float = 0.5
var _status_in: float = STATUS_EVERY
var _started_msec: int = 0
var _thread: Thread = null
var _mutex: Mutex = Mutex.new()
var _lines: PackedStringArray = PackedStringArray()
var _stdin_open: bool = false
var _quitting: bool = false
var _rules_name: String = "safe"
var _rules: Dictionary = {}


# --- option parsing (static: unit-tested) --------------------------------------------------------------

## Defaults < server.cfg < command line. Returns the final option dictionary.
static func parse_args(args: PackedStringArray, cfg_override: String = "") -> Dictionary:
	var o: Dictionary = {"port": Proto.DEFAULT_PORT, "name": "NovaSwift Server", "password": "", "max_players": 8,
		"rules": "safe", "lan": true, "stdin": true, "data": "", "log": "", "config": "", "custom_rules": {},
		"public": false, "upnp": false, "region": "global", "owner": "", "contact": "", "description": "", "address": "", "website": ""}
	var cli: Dictionary = {}
	var value_opts: Dictionary = {"--port": "port", "--name": "name", "--password": "password", "--max-players": "max_players",
		"--rules": "rules", "--config": "config", "--data": "data", "--log": "log", "--region": "region", "--owner": "owner",
		"--contact": "contact", "--description": "description", "--address": "address", "--website": "website"}
	var i: int = 0
	while i < args.size():
		var a: String = args[i]
		var val: String = ""
		var inline: bool = a.begins_with("--") and a.contains("=")
		if inline:
			val = a.substr(a.find("=") + 1)
			a = a.substr(0, a.find("="))
		if value_opts.has(a):
			if not inline:
				if i + 1 < args.size():
					i += 1
					val = args[i]
			var key: String = str(value_opts[a])
			if key == "port" or key == "max_players":
				cli[key] = val.to_int()
			elif key == "rules":
				cli[key] = val.to_lower()
			else:
				cli[key] = val
		elif a == "--no-lan":
			cli["lan"] = false
		elif a == "--no-stdin":
			cli["stdin"] = false
		elif a == "--public":
			cli["public"] = true
		elif a == "--upnp":
			cli["upnp"] = true
		i += 1
	var cfg_path: String = cfg_override if cfg_override != "" else str(cli.get("config", ""))
	if cfg_path == "":
		# net/server.cfg is an example: only an explicit --config or NOVA_SERVER_CONFIG is ever read.
		cfg_path = OS.get_environment("NOVA_SERVER_CONFIG")
	if cfg_path != "":
		o["config"] = cfg_path
		_apply_cfg(o, cfg_path)
	for k in cli:
		o[k] = cli[k]
	o["port"] = clampi(int(o["port"]), 1, 65535)
	o["max_players"] = clampi(int(o["max_players"]), 1, 32)
	o["name"] = Proto.clean_name(str(o["name"]), "NovaSwift Server")
	if not ["safe", "full", "custom"].has(str(o["rules"])):
		o["rules"] = "safe"
	return o


static func _apply_cfg(o: Dictionary, path: String) -> void:
	var c: ConfigFile = ConfigFile.new()
	var pwd: String = OS.get_environment("PWD")   # Godot changes directory to the project: resolve against the shell's
	if not path.is_absolute_path() and pwd != "" and not FileAccess.file_exists(path) and FileAccess.file_exists(pwd.path_join(path)):
		path = pwd.path_join(path)
	if c.load(path) != OK:
		o["config_error"] = "Couldn't read config file %s" % path
		return
	for k in ["port", "name", "password", "max_players", "rules", "lan", "stdin", "data", "log", "upnp", "region", "owner", "contact", "description", "address", "website"]:
		if c.has_section_key("server", k):
			o[k] = c.get_value("server", k)
	if c.has_section("rules"):
		var custom: Dictionary = Proto.rules_for_preset(str(c.get_value("rules", "base", "safe")))
		var map: Dictionary = {"pvp_damage_real": "pvp_damage_real", "death_real": "death_real", "friendly_fire": "friendly_fire",
			"allow_pvp": "allow_pvp", "allow_trade": "allow_trade", "carry_encounter": "carry_encounter"}
		for k in map:
			if c.has_section_key("rules", k):
				custom[map[k]] = bool(c.get_value("rules", k))
		if c.has_section_key("rules", "game_speed"):
			custom["game_speed_multiplier"] = float(c.get_value("rules", "game_speed"))
		o["custom_rules"] = custom
		if not c.has_section_key("server", "rules"):
			o["rules"] = "custom"


# --- run ----------------------------------------------------------------------------------------------------

func setup(options: Dictionary) -> void:
	opts = options


func start() -> void:
	_started_msec = Time.get_ticks_msec()
	if opts.is_empty():
		opts = parse_args(_all_args())
	if str(opts.get("log", "")) != "":
		log_path = str(opts["log"])
	_log("NOVA Swift dedicated server, game %s, protocol %d" % [Proto.game_version(), Proto.PROTO])
	if opts.has("config_error"):
		_log("WARNING: " + str(opts["config_error"]))
	_rules_name = str(opts["rules"])
	_rules = (opts["custom_rules"] as Dictionary) if _rules_name == "custom" and not (opts["custom_rules"] as Dictionary).is_empty() else Proto.rules_for_preset(_rules_name if _rules_name != "custom" else "safe")
	nova = _make_world()
	transport = Transport.new()
	transport.event.connect(_on_event)
	var err: int = transport.host(nova, {"port": int(opts["port"]), "max_players": int(opts["max_players"]),
		"name": str(opts["name"]), "display_name": "[Server]", "password": str(opts["password"]),
		"rules_json": JSON.stringify(_rules), "has_local_player": false})
	if err != OK:
		_log("FATAL: could not start the server on UDP port %d (%s)." % [int(opts["port"]), error_string(err)])
		_exit(3)
		return
	if not bool(transport.bridge_active):
		_log("WARNING: the engine bridge did not start a net session (old bridge, or no pilot-less host support); running as a plain relay.")
	lan = Lan.new()
	if bool(opts["lan"]):
		lan.start_announcing(_beacon, int(opts["port"]))
		if lan.last_error != "":
			_log("WARNING: " + str(lan.last_error))
	_log("Listening on UDP %d as \"%s\" (max %d players, rules: %s%s)." % [int(opts["port"]), str(opts["name"]),
		int(opts["max_players"]), _rules_name, ", password set" if str(opts["password"]) != "" else ""])
	_log("Players join with  <this machine's address>:%d  (forward UDP %d on your router for internet play). Type 'help' for commands." % [int(opts["port"]), int(opts["port"])])
	if bool(opts["upnp"]):
		_upnp = Upnp.new()
		_upnp.finished.connect(func(_ok: bool, msg: String) -> void:
			_log("UPnP: " + msg)
			if bool(opts["public"]):
				_print_public_entry(_upnp.external_ip))
		_upnp.start(int(opts["port"]), "NovaSwift server")
	elif bool(opts["public"]):
		_print_public_entry("")
	if bool(opts["stdin"]):
		_start_stdin()
	print_status()


var _upnp: RefCounted = null


## --public: print the directory entry to paste into servers/servers.json (NovaSwift-Plugins repo) and the PR link.
func _print_public_entry(detected_ip: String) -> void:
	var host: String = str(opts.get("address", ""))
	if host == "":
		host = detected_ip if detected_ip != "" and not detected_ip.begins_with("10.") and not detected_ip.begins_with("192.168.") else ""
	var plugins: Array = []
	if nova != null and transport != null and transport.bridge_active and nova.has_method("net_ready_manifest"):
		var m: Variant = JSON.parse_string(str(nova.net_ready_manifest()))
		if m is Dictionary and (m as Dictionary).get("plugins") is Array:
			plugins = (m as Dictionary)["plugins"]
	var entry: Dictionary = Directory.build_entry(opts, host, plugins, Time.get_date_string_from_system())
	_log("")
	_log("=== Public server entry ===")
	_log("Paste this into the \"servers\" array of servers/servers.json in https://github.com/SirStig/NovaSwift-Plugins and open a pull request:")
	for l in JSON.stringify(entry, "  ").split("\n"):
		_log(l)
	if host == "":
		_log("Fill in \"host\" with your public IP or DNS name (or pass --address HOST). Not sure of your IP? Search \"what is my IP\" from this network.")
	_log("Make sure UDP %d (game) and %d (status pings) reach this machine, and that the entry's plug-in list matches what you run." % [int(opts["port"]), int(opts["port"]) + 1])
	_log("How to list: " + Directory.PR_URL)
	_log("===========================")


static func _all_args() -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	var seen: bool = false
	for a in OS.get_cmdline_args():
		if a == "--server":
			seen = true
			continue
		if seen:
			out.append(a)
	if out.is_empty():
		for a in OS.get_cmdline_user_args():
			if a != "--server":
				out.append(a)
	return out


func _make_world() -> Object:
	if not ClassDB.class_exists("NovaWorld"):
		_log("WARNING: the engine bridge (NovaWorld) isn't loaded; running as a plain relay without game logic.")
		return null
	var w: Object = ClassDB.instantiate("NovaWorld")
	add_child(w as Node)
	var dir: String = ""
	var forced: String = str(opts.get("data", ""))
	if forced != "":
		if DirAccess.dir_exists_absolute(forced) and bool(w.call("load_game", forced)):
			dir = forced
	else:
		dir = Prefs.find_data(w)
	if dir == "":
		_log("ERROR: no EV Nova data found. Set NOVA_DATA_DIR, pass --data DIR, or run the game once to import it. Continuing as a plain relay.")
	else:
		_log("Game data: " + dir)
	return w


func _beacon() -> Dictionary:
	return {"name": str(opts["name"]), "players": transport.ready_count() if transport != null else 0, "max": int(opts["max_players"]),
		"ver": Proto.game_version(), "pw": str(opts["password"]) != "", "port": int(opts["port"]), "rules": _rules_name, "dedicated": true}


func _process(delta: float) -> void:
	_t += delta
	if transport != null:
		transport.poll(delta)
	if lan != null:
		lan.poll(delta)
	if _upnp != null:
		_upnp.poll()
	_status_in -= delta
	if _status_in <= 0.0:
		_status_in = STATUS_EVERY
		print_status()
	_events_in -= delta
	if _events_in <= 0.0:
		_events_in = 0.5
		_log_bridge_events()
	_mutex.lock()
	var pending: PackedStringArray = _lines.duplicate()
	_lines.clear()
	_mutex.unlock()
	for l in pending:
		run_command(l)


## The bridge's UI events (chat, trade, mismatches...) as log lines.
func _log_bridge_events() -> void:
	if nova == null or not transport.bridge_active or not nova.has_method("net_events"):
		return
	var v: Variant = JSON.parse_string(str(nova.net_events()))
	if not (v is Array):
		return
	for item in v:
		if item is Dictionary:
			var e: Dictionary = item
			_log("net: %s %s" % [str(e.get("type", "event")), str(e.get("text", e.get("message", e.get("name", ""))))])


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST or what == NOTIFICATION_PREDELETE:
		_shutdown()


func _shutdown() -> void:
	if _quitting:
		return
	_quitting = true
	if _upnp != null:
		_upnp.release()
	if transport != null:
		transport.close("The server shut down.", false)
	if lan != null:
		lan.stop()
	_log("Server stopped.")
	if _thread != null and _thread.is_alive():
		# The console thread is parked in a blocking stdin read and cannot be joined; destroying it crashes the
		# engine at shutdown. Everything is flushed and logged by now, so end the process directly.
		OS.kill(OS.get_process_id())


func _exit(code: int) -> void:
	_shutdown()
	get_tree().quit(code)


# --- console ------------------------------------------------------------------------------------------

func print_status() -> void:
	if transport == null:
		return
	var up: int = (Time.get_ticks_msec() - _started_msec) / 1000
	var names: PackedStringArray = PackedStringArray()
	for id in transport.peers:
		var info: Dictionary = transport.peers[id]
		if bool(info.get("ready", false)):
			names.append("%s#%d" % [str(info["name"]), int(id)])
	_log("status: %d/%d players [%s] | rules %s | uptime %dh%02dm | net %s" % [transport.ready_count(), int(opts["max_players"]),
		", ".join(names), _rules_name, up / 3600, (up / 60) % 60, "bridge" if transport.bridge_active else "relay"])


## One console line. Returns the reply text (also logged). Public so the selfcheck can drive it.
func run_command(line: String) -> String:
	var parts: PackedStringArray = line.strip_edges().split(" ", false, 1)
	if parts.is_empty():
		return ""
	var cmd: String = parts[0].to_lower()
	var rest: String = parts[1].strip_edges() if parts.size() > 1 else ""
	var reply: String = ""
	match cmd:
		"help", "?":
			reply = "commands: status | players | kick <id|name> [reason] | ban <id|name> | say <text> | rules [safe|full] | quit"
		"status":
			print_status()
			return ""
		"players", "list":
			var rows: PackedStringArray = PackedStringArray()
			for r in transport.roster():
				rows.append("#%d %s (%s)" % [int(r["id"]), str(r["name"]), ("%d ms" % int(r["rtt"])) if int(r["rtt"]) >= 0 else "-"])
			reply = "players: " + ("; ".join(rows) if rows.size() > 1 else "none online")
		"kick", "ban":
			var tok: PackedStringArray = rest.split(" ", false, 1)
			var id: int = transport.find_peer(tok[0]) if tok.size() > 0 else -1
			if id < 0:
				reply = "no such player"
			else:
				var why: String = tok[1] if tok.size() > 1 else "Removed by the server operator."
				reply = ("%s %d" % ["banned" if cmd == "ban" else "kicked", id]) if transport.kick(id, why, cmd == "ban") else "couldn't remove that player"
		"say":
			transport.send_chat(rest)
			reply = ""
		"rules":
			if rest == "":
				reply = "rules: %s %s" % [_rules_name, JSON.stringify(_rules)]
			elif rest == "safe" or rest == "full":
				_rules_name = rest
				_rules = Proto.rules_for_preset(rest)
				if nova != null and nova.has_method("net_set_rules"):
					nova.net_set_rules(JSON.stringify(_rules))
				reply = "rules set to %s" % rest
			else:
				reply = "usage: rules safe|full"
		"quit", "stop", "exit":
			_log("Shutting down on console request.")
			_exit(0)
			return ""
		_:
			reply = "unknown command '%s' (try 'help')" % cmd
	if reply != "":
		_log(reply)
	return reply


func _on_event(ev: Dictionary) -> void:
	match str(ev.get("type", "")):
		"peer_joined": _log("+ %s joined (#%d), %d/%d online." % [str(ev["name"]), int(ev["id"]), transport.ready_count(), int(opts["max_players"])])
		"peer_left": _log("- %s left (#%d: %s), %d online." % [str(ev["name"]), int(ev["id"]), str(ev.get("reason", "")), transport.ready_count()])
		"refused": _log("! refused %s: %s" % [str(ev.get("ip", "?")), str(ev["message"])])
		"chat": _log("<%s> %s" % [str(ev["name"]), str(ev["text"])])
		"error": _log("ERROR: " + str(ev["message"]))


# --- stdin thread -------------------------------------------------------------------------------------

func _start_stdin() -> void:
	_stdin_open = true
	_thread = Thread.new()
	_thread.start(_stdin_loop)


func _stdin_loop() -> void:
	var empties: int = 0
	while _stdin_open:
		var s: String = OS.read_string_from_stdin(1024)
		if s == "":
			empties += 1
			if empties > 20:
				return   # stdin is closed (service / nohup): console commands stay disabled
			OS.delay_msec(100)
			continue
		empties = 0
		_mutex.lock()
		_lines.append(s.strip_edges())
		_mutex.unlock()


func _log(text: String) -> void:
	var line: String = "[%s] %s" % [Time.get_datetime_string_from_system(false, true), text]
	print(line)
	DirAccess.make_dir_recursive_absolute(log_path.get_base_dir())
	var f: FileAccess = FileAccess.open(log_path, FileAccess.READ_WRITE) if FileAccess.file_exists(log_path) else FileAccess.open(log_path, FileAccess.WRITE)
	if f != null:
		f.seek_end()
		f.store_line(line)
		f.close()
