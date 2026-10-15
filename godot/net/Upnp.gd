# NOVA Swift -- optional UPnP port mapping (opt-in: Host Game toggle, server flag --upnp).
#
# Asks the home router (an Internet Gateway Device) to forward UDP <port> (game) and <port + 1> (status queries)
# to this machine, using Godot's UPNP class. Discovery blocks for up to ~2 s, so it runs on a Thread; call poll()
# every frame. Many routers have UPnP off, and carrier-grade NAT (some ISPs, mobile hotspots) can't be forwarded
# at all: then `message` says so and the manual steps in the hosting guide (Multiplayer > Host Game > Hosting guide) apply. Mappings are removed on
# release() (and carry a lease of 1 h as a safety net if the game crashes).
#
# Loaded with preload() (no class_name), like Controls.gd.
extends RefCounted

const LEASE_SEC := 3600

signal finished(ok: bool, message: String)

var ok: bool = false
var message: String = ""
var external_ip: String = ""
var done: bool = false

var _thread: Thread = null
var _port: int = 0
var _upnp: UPNP = null
var _mapped: Array = []


## Begin discovery + mapping on a worker thread. Returns false when already running.
func start(port: int, description: String = "NovaSwift") -> bool:
	if _thread != null:
		return false
	_port = port
	done = false
	message = "Asking your router to open UDP %d..." % port
	_thread = Thread.new()
	_thread.start(_work.bind(port, description))
	return true


func is_running() -> bool:
	return _thread != null and not done


## Call every frame while running; emits `finished` once.
func poll() -> void:
	if _thread != null and _thread.is_started() and not _thread.is_alive():
		_thread.wait_to_finish()
		_thread = null
		done = true
		finished.emit(ok, message)


func _work(port: int, description: String) -> void:
	var u: UPNP = UPNP.new()
	var disc: int = u.discover(2000, 2, "InternetGatewayDevice")
	if disc != UPNP.UPNP_RESULT_SUCCESS or u.get_gateway() == null or not u.get_gateway().is_valid_gateway():
		message = "No UPnP router answered (UPnP may be off on your router). Forward UDP %d manually (Multiplayer > Host Game > Hosting guide)." % port
		return
	_upnp = u
	var failed: bool = false
	for p in [port, port + 1]:
		var r: int = u.add_port_mapping(p, p, description, "UDP", LEASE_SEC)
		if r == UPNP.UPNP_RESULT_SUCCESS:
			_mapped.append(p)
		elif p == port:
			failed = true
			message = "Your router refused to forward UDP %d (UPnP error %d). Forward it manually (Multiplayer > Host Game > Hosting guide)." % [p, r]
	if failed:
		return
	external_ip = u.query_external_address()
	ok = true
	message = "Router forwarded UDP %d%s." % [port, "; public address " + external_ip if external_ip != "" else ""]
	if _is_non_public(external_ip):
		message += " That address is not public: your ISP shares one address between customers (CGNAT), so friends can't reach you directly. Try Tailscale."


## Private (10/8, 172.16/12, 192.168/16) or CGNAT shared (100.64.0.0/10) IPv4 address: friends can't reach it directly.
static func _is_non_public(ip: String) -> bool:
	if ip.begins_with("10.") or ip.begins_with("192.168."):
		return true
	var parts: PackedStringArray = ip.split(".")
	if parts.size() != 4 or not parts[1].is_valid_int():
		return false
	var second: int = parts[1].to_int()
	if parts[0] == "172":
		return second >= 16 and second <= 31
	if parts[0] == "100":
		return second >= 64 and second <= 127
	return false


## Remove the mappings we added. Safe to call anytime (blocks briefly).
func release() -> void:
	if _thread != null and _thread.is_started():
		_thread.wait_to_finish()
		_thread = null
	if _upnp != null:
		for p in _mapped:
			_upnp.delete_port_mapping(int(p), "UDP")
	_mapped.clear()
	_upnp = null
	ok = false
