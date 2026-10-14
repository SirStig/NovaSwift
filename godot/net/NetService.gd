# NOVA Swift -- the multiplayer service (autoload "NetService"). INERT until a session starts: with no
# transport its _process returns immediately and it owns no nodes.
#
# What it does:
#   * owns the NetTransport (host / join / leave) and the LanDiscovery for the app, and pumps both every frame
#     (so the net stays alive under any screen, including the pause menu, which freezes the sim);
#   * turns transport + bridge events into UI: chat log, toasts, the player roster, last_error for the hub;
#   * creates the in-game NetOverlay (chat feed / entry / player list / toasts) while a session is up, and
#     opens chat on T (modern key layout: /). While the chat box is open the flight actions are released every
#     frame so typing "z" does not fire the afterburner;
#   * is the one place screens/multiplayer/MultiplayerHub.gd calls into.
#
# Every bridge call is guarded with has_method(): on a bridge built before the net_* API, hosting/joining and
# chat still work (transport chat), they just carry no simulation (docs/MULTIPLAYER.md "Godot").
#
# project.godot: NetService="*res://net/NetService.gd".
extends Node

const Proto = preload("res://net/NetProto.gd")
const Transport = preload("res://net/NetTransport.gd")
const Lan = preload("res://net/LanDiscovery.gd")
const NetPrefs = preload("res://net/NetPrefs.gd")
const Upnp = preload("res://net/Upnp.gd")
const Overlay = preload("res://screens/multiplayer/NetOverlay.gd")

signal session_changed
## Every UI-level event (transport + bridge), already normalised: {type, ...}. The hub listens.
signal ui_event(ev: Dictionary)

var nova: Object = null
var transport: RefCounted = null
var lan: RefCounted = null
var overlay: CanvasLayer = null
## True while the Multiplayer hub is up (it owns the keyboard; the chat hotkey stands down).
var hub_open: bool = false
var chat_log: Array = []        # [{name, text, system}], newest last, at most 100
var players: Array = []         # [{id, name, system_id?, ship?, in_my_system?, is_authority?, rtt?}]
var net_info: Dictionary = {}   # the last net_state()
var last_error: String = ""
var last_error_code: String = ""
var last_error_detail: Dictionary = {}

var _events_in: float = 0.0
var _state_in: float = 0.0
var _lan_listening: bool = false


func _ready() -> void:
	process_priority = -100   # before Main: the chat box can release the flight actions first
	set_process_unhandled_key_input(true)
	lan = Lan.new()


func bind(nova_obj: Object) -> void:
	nova = nova_obj


# --- queries ---------------------------------------------------------------------------------------------

func is_active() -> bool:
	return transport != null and transport.is_active()


func is_connected_to_session() -> bool:
	return transport != null and transport.is_connected_to_session()


func is_hosting() -> bool:
	return is_active() and transport.mode == "server"


func has_bridge_api() -> bool:
	return nova != null and nova.has_method("net_begin")


func local_id() -> int:
	return transport.local_id if transport != null else 0


func status_text() -> String:
	if transport == null or not transport.is_active():
		return "Not in a game"
	match transport.state:
		"connecting": return "Connecting to %s..." % transport.address
		"handshaking": return "Joining %s..." % transport.address
		"connected":
			if transport.mode == "server":
				return "Hosting \"%s\" on port %d - %d/%d players" % [transport.server_name, transport.port, transport.ready_count() + 1, transport.max_players]
			return "Connected to \"%s\" (%s)" % [transport.server_name, transport.address]
	return "Not in a game"


# --- host / join / leave -------------------------------------------------------------------------------------

## opts: {name, max, port, password, lan, rules (Dictionary snake_case), display_name}. Returns OK or an Error.
func host_game(opts: Dictionary) -> int:
	_reset_session()
	var t: RefCounted = Transport.new()
	t.event.connect(_on_transport_event)
	transport = t
	var rules: Dictionary = opts.get("rules", Proto.rules_for_preset("safe"))
	var disp: String = Proto.clean_name(str(opts.get("display_name", NetPrefs.display_name())))
	var err: int = t.host(nova, {"port": int(opts.get("port", Proto.DEFAULT_PORT)), "max_players": int(opts.get("max", 4)),
		"name": str(opts.get("name", "")) if str(opts.get("name", "")) != "" else disp + "'s game",
		"display_name": disp, "password": str(opts.get("password", "")), "rules_json": JSON.stringify(rules), "has_local_player": true})
	if err != OK:
		transport = null
		return err
	if bool(opts.get("lan", true)):
		lan.start_announcing(_beacon, int(opts.get("port", Proto.DEFAULT_PORT)))
	_host_rules_name = Proto.preset_of(rules)
	if bool(opts.get("upnp", false)):
		upnp = Upnp.new()
		upnp.finished.connect(func(_ok: bool, msg: String) -> void:
			_system_line("UPnP: " + msg)
			_toast(msg, "info" if _ok else "warning"))
		upnp.start(int(opts.get("port", Proto.DEFAULT_PORT)), "NovaSwift")
	_session_started()
	return OK


## Optional router port mapping for the hosted game (Host Game > "Open the port on my router"); null when off.
var upnp: RefCounted = null


var _host_rules_name: String = "safe"


func _beacon() -> Dictionary:
	if transport == null or transport.mode != "server":
		return {}
	return {"name": transport.server_name, "players": transport.ready_count() + 1, "max": transport.max_players, "ver": Proto.game_version(),
		"pw": transport.password != "", "port": transport.port, "rules": _host_rules_name, "dedicated": false}


func join_game(host: String, port: int, pw: String = "", display_name: String = "") -> int:
	_reset_session()
	var t: RefCounted = Transport.new()
	t.event.connect(_on_transport_event)
	transport = t
	var disp: String = Proto.clean_name(display_name if display_name != "" else NetPrefs.display_name())
	var err: int = t.join(nova, host, port, disp, pw)
	if err != OK:
		transport = null
		return err
	_pending_join = {"host": host, "port": port, "pw": pw}
	session_changed.emit()
	return OK


var _pending_join: Dictionary = {}


func leave() -> void:
	if transport != null:
		transport.close("")
	_after_close()


func kick(id: int, ban: bool = false) -> void:
	if transport != null:
		transport.kick(id, "Removed by the host.", ban)


func send_chat(text: String) -> void:
	if transport != null:
		transport.send_chat(text)


func set_rules(rules: Dictionary) -> void:
	_host_rules_name = Proto.preset_of(rules)
	if transport != null:
		transport.rules_json = JSON.stringify(rules)
	if nova != null and nova.has_method("net_set_rules"):
		nova.net_set_rules(JSON.stringify(rules))


func start_lan_browser() -> bool:
	if not _lan_listening:
		_lan_listening = lan.start_listening()
	return _lan_listening


func stop_lan_browser() -> void:
	if not is_hosting() and lan != null:
		lan.stop()
	_lan_listening = false


func _reset_session() -> void:
	if transport != null:
		transport.close("", false)
	transport = null
	players.clear()
	chat_log.clear()
	net_info = {}
	last_error = ""
	last_error_code = ""
	last_error_detail = {}


func _session_started() -> void:
	if overlay == null:
		overlay = Overlay.new()
		overlay.chat_submitted.connect(send_chat)
		add_child(overlay)
	_events_in = 0.0
	_state_in = 0.0
	session_changed.emit()


func _after_close() -> void:
	if upnp != null:
		upnp.release()
		upnp = null
	if lan != null and lan.is_announcing():
		lan.stop_announcing()
	if overlay != null:
		overlay.queue_free()
		overlay = null
	players.clear()
	net_info = {}
	session_changed.emit()


# --- events ----------------------------------------------------------------------------------------------------

func _on_transport_event(ev: Dictionary) -> void:
	var kind: String = str(ev.get("type", ""))
	match kind:
		"connected":
			if not _pending_join.is_empty():
				NetPrefs.add_recent(str(_pending_join["host"]), int(_pending_join["port"]))
			_session_started()
			_system_line("Connected to %s." % str(ev.get("server_name", "the server")))
			if not bool(ev.get("bridge", false)):
				_system_line("This build's engine bridge has no multiplayer support yet: chat only.")
		"hosting":
			if not bool(ev.get("bridge", false)):
				_system_line("Hosting without simulation sync (engine bridge has no multiplayer support yet): chat only.")
		"peer_joined":
			_toast("%s joined" % str(ev["name"]), "good")
			_system_line("%s joined." % str(ev["name"]))
		"peer_left":
			_toast("%s left" % str(ev["name"]))
			_system_line("%s left." % str(ev["name"]))
		"chat":
			_chat_line(str(ev["name"]), str(ev["text"]))
		"rejected", "timeout", "error":
			_set_error(str(ev.get("message", "Connection failed.")), str(ev.get("code", kind)), ev.get("detail", {}) as Dictionary if ev.get("detail", {}) is Dictionary else {})
			_toast(last_error, "error")
			transport = null
			_after_close()
		"kicked":
			_set_error(str(ev.get("reason", "You were removed from the game.")), "kicked", {})
			_toast("Removed from the game: " + last_error, "error")
			transport = null
			_after_close()
		"disconnected":
			var why: String = str(ev.get("reason", ""))
			if transport != null and transport.mode == "none" and why != "" and why != "Left the game.":
				_set_error(why, "disconnected", {})
				_toast(why, "error")
			if transport == null or transport.mode == "none":
				transport = null
				_after_close()
	ui_event.emit(ev)


func _set_error(msg: String, code: String, detail: Dictionary) -> void:
	last_error = msg
	last_error_code = code
	last_error_detail = detail


func _toast(text: String, kind: String = "info") -> void:
	if overlay != null:
		overlay.toast(text, kind)


func _system_line(text: String) -> void:
	_push_chat("", text, true)


func _chat_line(from_name: String, text: String) -> void:
	_push_chat(from_name, text, false)


func _push_chat(from_name: String, text: String, system: bool) -> void:
	chat_log.append({"name": from_name, "text": text, "system": system})
	while chat_log.size() > 100:
		chat_log.pop_front()
	if overlay != null:
		overlay.add_chat(from_name, text, system)


## One bridge net_events() item. Types: player_joined/player_left (the transport already toasts these), chat,
## rules_changed, trade, ncb_bits, kicked, version_mismatch, plugin_mismatch.
func _on_bridge_event(e: Dictionary) -> void:
	var kind: String = str(e.get("type", e.get("kind", "")))
	match kind:
		"chat":
			_chat_line(str(e.get("name", "?")), str(e.get("text", "")))
		"rules_changed":
			_toast("The host changed the session rules.")
			_system_line("Session rules changed.")
		"trade":
			if str(e.get("kind", "")) in ["invite", "offer", "request", ""]:
				if overlay != null:
					overlay.show_trade_offer(str(e.get("name", e.get("from_name", "A player"))))
		"kicked":
			_toast("You were kicked from the game.", "error")
		"version_mismatch":
			_set_error("Game version mismatch: " + str(e.get("message", "update NovaSwift to match the host.")), "version", e)
			_toast(last_error, "error")
		"plugin_mismatch":
			_set_error(_plugin_mismatch_text(e), "plugins", e)
			_toast("Plug-ins don't match the host's.", "error")
	ui_event.emit({"type": "bridge_" + kind, "event": e})


static func _plugin_mismatch_text(e: Dictionary) -> String:
	var parts: PackedStringArray = PackedStringArray()
	for key in ["missing", "extra", "wrong_version"]:
		var arr: Variant = e.get(key, [])
		if arr is Array and not (arr as Array).is_empty():
			var names: PackedStringArray = PackedStringArray()
			for x in arr:
				names.append(str((x as Dictionary).get("name", x)) if x is Dictionary else str(x))
			var label: String = {"missing": "Install", "extra": "Disable", "wrong_version": "Update"}[key]
			parts.append("%s: %s" % [label, ", ".join(names)])
	return "Your plug-ins don't match. " + "; ".join(parts) if not parts.is_empty() else "Your enabled plug-ins don't match the host's."


# --- per frame ---------------------------------------------------------------------------------------------------

func _process(delta: float) -> void:
	if lan != null and (_lan_listening or lan.is_announcing() or not lan.pings.is_empty()):
		lan.poll(delta)
	if upnp != null:
		upnp.poll()
	if transport == null:
		return
	if overlay != null and overlay.chat_open:
		for a in InputMap.get_actions():
			Input.action_release(a)   # typing must not fly the ship
	transport.poll(delta)
	if transport == null or not transport.is_connected_to_session():
		return
	_events_in -= delta
	if _events_in <= 0.0:
		_events_in = 0.2
		_poll_bridge_events()
	_state_in -= delta
	if _state_in <= 0.0:
		_state_in = 0.5
		_poll_state()


func _poll_bridge_events() -> void:
	if not transport.bridge_active or nova == null or not nova.has_method("net_events"):
		return
	var v: Variant = JSON.parse_string(str(nova.net_events()))
	if v is Array:
		for item in v:
			if item is Dictionary:
				_on_bridge_event(item)


func _poll_state() -> void:
	var rows: Array = []
	if transport.bridge_active and nova != null and nova.has_method("net_state"):
		var v: Variant = JSON.parse_string(str(nova.net_state()))
		if v is Dictionary:
			net_info = v
			for p in (v.get("players", []) as Array):
				if p is Dictionary:
					rows.append(p)
			for er in (v.get("errors", []) as Array):
				_toast(str(er), "error")
	if rows.is_empty():
		rows = transport.roster()
	else:
		var rtts: Dictionary = {}
		for r in transport.roster():
			rtts[int((r as Dictionary)["id"])] = int((r as Dictionary)["rtt"])
		for r in rows:
			(r as Dictionary)["rtt"] = rtts.get(int((r as Dictionary).get("id", -1)), -1)
	players = rows
	if overlay != null:
		overlay.set_players(players, transport.local_id)


func chat_key() -> int:
	var Controls: Script = load("res://Controls.gd") as Script
	var modern: bool = Controls != null and str(Controls.get("layout")) == "modern"
	return KEY_SLASH if modern else KEY_T


func _unhandled_key_input(event: InputEvent) -> void:
	if overlay == null or hub_open or not is_connected_to_session():
		return
	var k: InputEventKey = event as InputEventKey
	if k == null or not k.pressed or k.echo or overlay.chat_open:
		return
	if k.keycode == chat_key() and not k.ctrl_pressed and not k.alt_pressed and not k.meta_pressed:
		get_viewport().set_input_as_handled()
		overlay.open_chat()


func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and transport != null:
		transport.close("", false)
