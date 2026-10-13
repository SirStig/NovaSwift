# NOVA Swift updater -- "updater mode" detection and the hand-off to it.
#
# The same executable doubles as the installer. The running game copies its own executable + .pck into
# user://update/run/ and starts that copy as
#
#   <copy> -- --updater --install-dir <dir> --staging <dir> --pid <game pid> --relaunch <launcher path>
#             [--from <version>] [--to <version>] [--wait <seconds>]
#
# (everything after "--" is a user arg, so the engine never interprets it). Main.gd checks
# UpdaterMode.requested() first thing and, in that case, shows the small updater window
# (UpdaterScene.gd) INSTEAD of building any game: no NovaWorld, no bridge class is instantiated, and the
# copy lives outside the install folder so nothing it needs is locked by the swap. The GDExtension libraries
# are not beside the copy, so the engine logs a failed extension load there -- non-fatal by design.
# Loaded with preload() (no class_name).
extends RefCounted

const UpdateConfig = preload("res://updater/UpdateConfig.gd")
const UpdateInstall = preload("res://updater/UpdateInstall.gd")

const RUN_DIR := "user://update/run"


## Parsed options when `args` ask for updater mode, else {}. Both --key value and --key=value are accepted.
static func parse_args(args: PackedStringArray) -> Dictionary:
	if not args.has("--updater"):
		return {}
	var opts: Dictionary = {"install_dir": "", "staging": "", "pid": 0, "relaunch": "", "from": "", "to": "", "wait": 30}
	var names: Dictionary = {"--install-dir": "install_dir", "--staging": "staging", "--pid": "pid",
		"--relaunch": "relaunch", "--from": "from", "--to": "to", "--wait": "wait"}
	var i: int = 0
	while i < args.size():
		var a: String = args[i]
		var key: String = a
		var val: String = ""
		var has_val: bool = false
		var eq: int = a.find("=")
		if a.begins_with("--") and eq > 0:
			key = a.substr(0, eq)
			val = a.substr(eq + 1)
			has_val = true
		elif i + 1 < args.size():
			val = args[i + 1]
			has_val = true
		if names.has(key) and has_val:
			var field: String = str(names[key])
			if field == "pid" or field == "wait":
				opts[field] = int(val)
			else:
				opts[field] = val
			i += 1 if eq > 0 else 2
		else:
			i += 1
	if str(opts["install_dir"]) == "" or str(opts["staging"]) == "":
		return {}
	return opts


static func cmdline() -> PackedStringArray:
	var all: PackedStringArray = OS.get_cmdline_args()
	if all.has("--updater"):
		return all
	return OS.get_cmdline_user_args()


## Options of this process if it was started in updater mode, else {}.
static func requested() -> Dictionary:
	return parse_args(cmdline())


## Is process `pid` still running? (Godot can only poll its own children, so ask the OS.)
static func pid_alive(pid: int) -> bool:
	if pid <= 0:
		return false
	if OS.get_name() == "Windows":
		var out: Array = []
		if OS.execute("tasklist", ["/FI", "PID eq %d" % pid, "/NH", "/FO", "CSV"], out, true) != 0:
			return false
		return str(out[0] if out.size() > 0 else "").contains(",\"%d\"" % pid)
	var stat: String = "/proc/%d/stat" % pid
	if FileAccess.file_exists(stat):
		var text: String = FileAccess.get_file_as_string(stat)
		var close: int = text.rfind(")")
		if close >= 0 and text.length() > close + 2:
			return text[close + 2] != "Z" and text[close + 2] != "X"      # zombie / dead = gone
		return true
	if DirAccess.dir_exists_absolute("/proc"):
		return false                  # procfs exists but has no such pid
	var sink: Array = []
	return OS.execute("kill", ["-0", str(pid)], sink, true) == 0


## Copy the running game into user://update/run and start it in updater mode. {ok, error, pid}.
## The caller quits the game right after a successful return.
static func launch(install_dir: String, staging: String, relaunch: String, from_v: String, to_v: String) -> Dictionary:
	var run: String = ProjectSettings.globalize_path(RUN_DIR)
	UpdateInstall.remove_tree(run)
	DirAccess.make_dir_recursive_absolute(run)
	var exe: String = OS.get_executable_path()
	var exe_copy: String = run.path_join(exe.get_file())
	if UpdateInstall.copy_file(exe, exe_copy) != OK:
		return {"ok": false, "error": "Could not prepare the updater (disk full or read-only?).", "pid": 0}
	var pck: String = exe.get_basename() + ".pck"
	if FileAccess.file_exists(pck):
		if UpdateInstall.copy_file(pck, run.path_join(exe_copy.get_file().get_basename() + ".pck")) != OK:
			return {"ok": false, "error": "Could not prepare the updater (disk full?).", "pid": 0}
	if OS.get_name() != "Windows":
		FileAccess.set_unix_permissions(exe_copy, 0x1ED)    # 0755
	var args: PackedStringArray = PackedStringArray(["--", "--updater", "--install-dir", install_dir,
		"--staging", staging, "--pid", str(OS.get_process_id()), "--relaunch", relaunch,
		"--from", from_v, "--to", to_v])
	var pid: int = OS.create_process(exe_copy, args)
	if pid <= 0:
		return {"ok": false, "error": "Could not start the updater.", "pid": 0}
	return {"ok": true, "error": "", "pid": pid}


## The file the updater starts after the swap: the package's launcher script / exe inside the install dir.
static func relaunch_target(install_dir: String, launcher_rel: String) -> String:
	var p: String = install_dir.path_join(launcher_rel)
	if FileAccess.file_exists(p):
		return p
	return OS.get_executable_path()      # fall back to the executable (same path after the swap)
