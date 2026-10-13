# NOVA Swift -- crash/error report helpers shared by Boot, the ErrorScreen and Settings > Support.
# Depends only on CrashLogger.gd (no game scripts, no kit, no bridge), so it works when everything else is
# broken. Loaded with preload() (no class_name). All static.
extends RefCounted

const CrashLogger = preload("res://ui/CrashLogger.gd")

const ISSUES_URL := "https://github.com/SirStig/NovaSwift/issues/new"
## GitHub rejects very long query strings; stay comfortably under ~8 KB.
const MAX_URL_LENGTH := 6500
const ISSUE_LOG_LINES := 30
const REPORT_DIR := "user://reports"


static func version() -> String:
	return str(ProjectSettings.get_setting("application/config/version", "?"))


static func renderer_name() -> String:
	var method: String = str(RenderingServer.get_current_rendering_method())
	if DisplayServer.get_name() == "headless":
		return method + " (headless)"
	return "%s / %s" % [method, RenderingServer.get_video_adapter_name()]


## "NovaSwift 0.7.0 · Godot 4.7.2 · macOS 15.1 · arm64 · gl_compatibility / Apple M2"
static func system_info() -> String:
	return "NovaSwift %s · Godot %s · %s %s · %s · %s" % [version(),
		str(Engine.get_version_info().get("string", "?")), OS.get_name(), OS.get_version(),
		Engine.get_architecture_name(), renderer_name()]


## Replace the user's home directory and account name with `~` so a pasted report never carries it.
static func sanitize(text: String) -> String:
	var out: String = text
	for env in ["HOME", "USERPROFILE"]:
		var h: String = OS.get_environment(env)
		if h.length() > 2:
			out = out.replace(h, "~")
			out = out.replace(h.replace("\\", "/"), "~")
	var re_unix: RegEx = RegEx.new()
	re_unix.compile("(/Users|/home)/[^/\\s\"')]+")
	out = re_unix.sub(out, "~", true)
	var re_win: RegEx = RegEx.new()
	re_win.compile("(?i)[A-Z]:[\\\\/]+Users[\\\\/]+[^\\\\/\\s\"')]+")
	out = re_win.sub(out, "~", true)
	return out


## The multi-line text of a report (also what "Copy details" copies).
static func report_text(summary: String, detail: String, lines: PackedStringArray) -> String:
	var t: String = "%s\n\n%s\n" % [system_info(), summary]
	if detail.strip_edges() != "":
		t += "\n--- details ---\n%s\n" % detail
	if not lines.is_empty():
		t += "\n--- recent log ---\n%s\n" % "\n".join(lines)
	return sanitize(t)


static func _url(title: String, body: String) -> String:
	return "%s?title=%s&body=%s" % [ISSUES_URL, title.uri_encode(), body.uri_encode()]


## A prefilled GitHub "new issue" link. Drops the oldest log lines, then truncates, until the URL fits `max_len`.
static func build_issue_url(title: String, summary: String, lines: PackedStringArray, max_len: int = MAX_URL_LENGTH) -> String:
	var t: String = sanitize(title).left(120)
	var head: String = "**What happened**\n(please describe what you were doing)\n\n**Error**\n```\n%s\n```\n\n**System**\n%s\n" % [sanitize(summary).left(600), sanitize(system_info())]
	var kept: Array = []
	for l in lines.slice(maxi(0, lines.size() - ISSUE_LOG_LINES)):
		kept.append(sanitize(str(l)).left(240))
	while true:
		var body: String = head
		if not kept.is_empty():
			body += "\n**Recent log**\n```\n%s\n```\n" % "\n".join(PackedStringArray(kept))
		var url: String = _url(t, body)
		if url.length() <= max_len:
			return url
		if kept.is_empty():
			break
		kept.pop_front()
	# Even the bare head is too long: shorten the error text hard.
	var short_head: String = "**Error**\n```\n%s\n```\n\n**System**\n%s\n" % [sanitize(summary).left(200), sanitize(system_info())]
	var u: String = _url(t.left(60), short_head)
	if u.length() > max_len:
		u = _url(t.left(60), sanitize(system_info()).left(200))
	return u


static func open_issue(title: String, summary: String) -> void:
	OS.shell_open(build_issue_url(title, summary, CrashLogger.recent_lines(ISSUE_LOG_LINES)))


static func open_logs_folder() -> void:
	var dir: String = CrashLogger.logs_dir_global()
	DirAccess.make_dir_recursive_absolute(dir)
	OS.shell_show_in_file_manager(dir, true)


static func _read_text(path: String) -> String:
	var f: FileAccess = FileAccess.open(path, FileAccess.READ)
	if f == null:
		return ""
	var s: String = f.get_as_text()
	f.close()
	return s


## The newest existing pilot save recorded in settings.cfg [pilots] recent, or "".
static func active_pilot_path() -> String:
	var cfg: ConfigFile = ConfigFile.new()
	if cfg.load("user://settings.cfg") != OK:
		return ""
	var v: Variant = cfg.get_value("pilots", "recent", [])
	if v is Array:
		for p in (v as Array):
			var s: String = str(p)
			if s != "" and FileAccess.file_exists(s):
				return s
	return ""


## Zip report.txt + the logs + settings.cfg + the active pilot into user://reports and return
## {ok, path (absolute), error}. `extra_pilot` (optional) overrides the pilot detection.
static func save_bundle(summary: String, detail: String, extra_pilot: String = "") -> Dictionary:
	var dir: String = ProjectSettings.globalize_path(REPORT_DIR)
	DirAccess.make_dir_recursive_absolute(dir)
	var stamp: String = Time.get_datetime_string_from_system().replace(":", "-").replace("T", "_")
	var path: String = dir.path_join("NovaSwift-crash-%s.zip" % stamp)
	var zip: ZIPPacker = ZIPPacker.new()
	if zip.open(path) != OK:
		return {"ok": false, "path": "", "error": "Couldn't write " + sanitize(path)}
	var files: Dictionary = {}
	files["report.txt"] = report_text(summary, detail, CrashLogger.recent_lines(CrashLogger.RING_MAX)).to_utf8_buffer()
	files["novaswift.log"] = sanitize(_read_text(CrashLogger.LOG_PATH)).to_utf8_buffer()
	var godot_log: String = _read_text("user://logs/godot.log")
	if godot_log != "":
		files["godot.log"] = sanitize(godot_log).to_utf8_buffer()
	var prefs: String = _read_text("user://settings.cfg")
	if prefs != "":
		files["settings.cfg"] = sanitize(prefs).to_utf8_buffer()
	var pilot: String = extra_pilot if extra_pilot != "" else active_pilot_path()
	if pilot != "" and FileAccess.file_exists(pilot):
		var pf: FileAccess = FileAccess.open(pilot, FileAccess.READ)
		if pf != null:
			files["pilot/" + pilot.get_file()] = pf.get_buffer(pf.get_length())
			pf.close()
	for name in files:
		zip.start_file(str(name))
		zip.write_file(files[name] as PackedByteArray)
		zip.close_file()
	zip.close()
	return {"ok": true, "path": path, "error": ""}
