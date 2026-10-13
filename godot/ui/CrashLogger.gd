# NOVA Swift -- the crash/error capture Logger (docs/GODOT_LAYER.md "Errors and crash reporting").
#
# Registered by Boot.gd (OS.add_logger, Godot 4.5+) before anything else loads, so even a script that fails to
# compile is recorded. Godot calls a Logger from ANY thread, so everything here is behind one mutex and this
# script depends on nothing else in the project (it must keep working when every game script is broken).
#
#  - a ring buffer of the last RING_MAX lines (print output, warnings, errors) with timestamps
#  - the same lines appended to user://logs/novaswift.log (rotated to novaswift.prev.log when over LOG_ROTATE_BYTES)
#  - error-storm detection: the same error STORM_COUNT times inside STORM_WINDOW_MS, or a SCRIPT error from a
#    per-frame callback (_process / _physics_process / _draw ...) FRAME_STORM_COUNT times inside the window.
#    A storm is parked in `_storm` for ErrorWatch.gd to pick up on the main thread (take_storm()).
#  - "recent errors" for the non-blocking toast (take_events()), errors only -- never warnings.
# Loaded with preload() (no class_name). All state is static; the instance only forwards Godot's callbacks.
extends Logger

const RING_MAX := 400
const LOG_PATH := "user://logs/novaswift.log"
const PREV_LOG_PATH := "user://logs/novaswift.prev.log"
const LOG_ROTATE_BYTES := 2 * 1024 * 1024
const LOG_SESSION_CAP_BYTES := 4 * 1024 * 1024
const EVENTS_MAX := 32

## The same error this many times within STORM_WINDOW_MS is a flood.
static var STORM_COUNT: int = 8
## A script error raised from a per-frame callback repeats at frame rate: it is a storm much sooner.
static var FRAME_STORM_COUNT: int = 3
static var STORM_WINDOW_MS: int = 1000
const FRAME_FUNCS: Array = ["_process", "_physics_process", "_draw", "_input", "_unhandled_input", "_notification"]

## Tests set this (>= 0) to drive the clock; -1 = real time.
static var clock_override: int = -1

static var _mutex: Mutex = Mutex.new()
static var _ring: Array = []              # [[msec, "E"/"W"/"I", text]]
static var _counts: Dictionary = {}       # key -> [window_start_msec, count]
static var _tripped: Dictionary = {}      # keys already reported as a storm
static var ignored: Dictionary = {}       # keys the player chose "Continue anyway" for
static var _storm: Dictionary = {}
static var _events: Array = []
static var _file: FileAccess = null
static var _file_bytes: int = 0
static var _in_log: bool = false
static var _started_msec: int = 0
static var installed: Logger = null


## Create and register the Logger (idempotent). Returns the instance.
static func install() -> Logger:
	if installed != null:
		return installed
	_started_msec = Time.get_ticks_msec()
	_open_file()
	var inst: Logger = new()
	installed = inst
	OS.add_logger(inst)
	return inst


static func _now() -> int:
	return clock_override if clock_override >= 0 else Time.get_ticks_msec()


static func _open_file() -> void:
	DirAccess.make_dir_recursive_absolute(ProjectSettings.globalize_path("user://logs"))
	if FileAccess.file_exists(LOG_PATH):
		var old: FileAccess = FileAccess.open(LOG_PATH, FileAccess.READ)
		if old != null:
			var big: bool = old.get_length() > LOG_ROTATE_BYTES
			old.close()
			if big:
				DirAccess.rename_absolute(ProjectSettings.globalize_path(LOG_PATH), ProjectSettings.globalize_path(PREV_LOG_PATH))
	# READ_WRITE keeps the previous session's tail; append by seeking to the end.
	var f: FileAccess = FileAccess.open(LOG_PATH, FileAccess.READ_WRITE if FileAccess.file_exists(LOG_PATH) else FileAccess.WRITE)
	if f == null:
		return
	f.seek_end()
	f.store_line("")
	f.store_line("=== NovaSwift session %s  (v%s, Godot %s, %s) ===" % [Time.get_datetime_string_from_system(), str(ProjectSettings.get_setting("application/config/version", "?")), str(Engine.get_version_info().get("string", "?")), OS.get_name()])
	f.flush()
	_file = f


static func _stamp(msec: int) -> String:
	return "%7.2f" % (float(msec - _started_msec) / 1000.0)


static func add_line(level: String, text: String) -> void:
	var t: String = text.strip_edges()
	if t == "":
		return
	_mutex.lock()
	if _in_log:
		_mutex.unlock()
		return
	_in_log = true
	var now: int = _now()
	_ring.append([now, level, t])
	if _ring.size() > RING_MAX:
		_ring.pop_front()
	if _file != null and _file_bytes < LOG_SESSION_CAP_BYTES:
		var line: String = "[%s] %s %s" % [_stamp(now), level, t]
		_file.store_line(line)
		_file.flush()
		_file_bytes += line.length() + 1
	_in_log = false
	_mutex.unlock()


## Last `n` lines as printable strings (oldest first).
static func recent_lines(n: int = 30) -> PackedStringArray:
	_mutex.lock()
	var out: PackedStringArray = PackedStringArray()
	var start: int = maxi(0, _ring.size() - n)
	for i in range(start, _ring.size()):
		var e: Array = _ring[i]
		out.append("[%s] %s %s" % [_stamp(int(e[0])), str(e[1]), str(e[2])])
	_mutex.unlock()
	return out


## The last `n` error-level lines (oldest first) -- the "why" for a failed boot.
static func recent_errors(n: int = 12) -> PackedStringArray:
	_mutex.lock()
	var out: PackedStringArray = PackedStringArray()
	for i in range(_ring.size() - 1, -1, -1):
		var e: Array = _ring[i]
		if str(e[1]) == "E":
			out.append("[%s] %s" % [_stamp(int(e[0])), str(e[2])])
			if out.size() >= n:
				break
	out.reverse()
	_mutex.unlock()
	return out


static func log_path_global() -> String:
	return ProjectSettings.globalize_path(LOG_PATH)


static func logs_dir_global() -> String:
	return ProjectSettings.globalize_path("user://logs")


## The dedupe key of an error: where it came from plus what it said.
static func error_key(file: String, line: int, function: String, text: String) -> String:
	return "%s:%d:%s:%s" % [file.get_file(), line, function, text.left(120)]


## Feed one error occurrence (called from _log_error; public so the self-check can drive it).
## Returns true when this occurrence tripped the storm detector.
static func note_error(file: String, line: int, function: String, text: String, is_script: bool, is_warning: bool, backtrace: String = "") -> bool:
	var level: String = "W" if is_warning else "E"
	add_line(level, "%s  (%s:%d @ %s)" % [text, file.get_file(), line, function])
	if is_warning:
		return false
	var key: String = error_key(file, line, function, text)
	_mutex.lock()
	if ignored.has(key):
		_mutex.unlock()
		return false
	var now: int = _now()
	var rec: Array = []
	if _counts.has(key):
		rec = _counts[key]
	if rec.is_empty() or now - int(rec[0]) > STORM_WINDOW_MS:
		rec = [now, 0]
	rec[1] = int(rec[1]) + 1
	_counts[key] = rec
	if _counts.size() > 256:
		_counts.clear()
		_counts[key] = rec
	var per_frame: bool = is_script and FRAME_FUNCS.has(function)
	var limit: int = FRAME_STORM_COUNT if per_frame else STORM_COUNT
	var tripped: bool = false
	if int(rec[1]) >= limit and not _tripped.has(key):
		_tripped[key] = true
		tripped = true
		_storm = {"key": key, "text": text, "file": file, "line": line, "function": function,
			"count": int(rec[1]), "script": is_script, "backtrace": backtrace}
	if not _tripped.has(key):
		_events.append({"key": key, "text": text, "file": file.get_file(), "line": line, "function": function, "backtrace": backtrace})
		if _events.size() > EVENTS_MAX:
			_events.pop_front()
	_mutex.unlock()
	return tripped


## The pending storm ({} if none); clears it.
static func take_storm() -> Dictionary:
	_mutex.lock()
	var s: Dictionary = _storm
	_storm = {}
	_mutex.unlock()
	return s


static func peek_storm() -> bool:
	_mutex.lock()
	var has: bool = not _storm.is_empty()
	_mutex.unlock()
	return has


## Non-storm errors since the last call (for the toast).
static func take_events() -> Array:
	_mutex.lock()
	var e: Array = _events
	_events = []
	_mutex.unlock()
	return e


## "Continue anyway": stop reporting this error for the rest of the session.
static func ignore_key(key: String) -> void:
	_mutex.lock()
	ignored[key] = true
	_mutex.unlock()


## Forget all counters and parked events (tests; Retry).
static func clear_all_state() -> void:
	_mutex.lock()
	_counts.clear()
	_tripped.clear()
	ignored.clear()
	_storm.clear()
	_events.clear()
	_mutex.unlock()


func _log_message(message: String, error: bool) -> void:
	add_line("E" if error else "I", message)


func _log_error(function: String, file: String, line: int, code: String, rationale: String,
		_editor_notify: bool, error_type: int, script_backtraces: Array) -> void:
	var text: String = rationale if rationale != "" else code
	var bt: String = ""
	if not script_backtraces.is_empty():
		var first: Object = script_backtraces[0] as Object
		if first != null and first.has_method("format"):
			bt = str(first.call("format"))
	note_error(file, line, function, text, error_type == Logger.ERROR_TYPE_SCRIPT,
		error_type == Logger.ERROR_TYPE_WARNING, bt)
