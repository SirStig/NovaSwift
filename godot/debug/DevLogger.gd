# NOVA Swift — captures Godot's own log (print / push_warning / push_error / engine errors)
# for the dev console and bug reports. Godot calls these from any thread, so lines are only
# queued here (under a mutex) and DevTools.gd drains them on the main thread into the Swift
# ring buffer (NovaDebug.log_append) next to the engine's own `Logging` output.
extends Logger

const MAX_PENDING := 2000

var _mutex := Mutex.new()
var _pending: Array = []


func _log_message(message: String, error: bool) -> void:
	_push("error" if error else "info", message)


func _log_error(function: String, file: String, line: int, code: String, rationale: String,
		_editor_notify: bool, error_type: int, _script_backtraces: Array) -> void:
	var level := "warning" if error_type == Logger.ERROR_TYPE_WARNING else "error"
	var text := rationale if rationale != "" else code
	_push(level, "%s  (%s:%d @ %s)" % [text, file.get_file(), line, function])


func _push(level: String, text: String) -> void:
	text = text.strip_edges()
	if text == "":
		return
	_mutex.lock()
	if _pending.size() < MAX_PENDING:
		_pending.append([level, text])
	_mutex.unlock()


## Everything queued since the last call, as [[level, text]].
func drain() -> Array:
	_mutex.lock()
	var out := _pending
	_pending = []
	_mutex.unlock()
	return out
