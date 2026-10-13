# NOVA Swift updater -- file-level install machinery (no networking, no UI, no GDExtension).
#
#   extract(archive, dest)        .zip (ZIPReader) / .tar.gz (system `tar`) into an empty staging dir
#   payload_root(staging)         the folder holding the files (descends one wrapper folder, e.g. NovaSwift/)
#   missing_required(root, list)  required files that are absent or empty
#   apply(install, payload, opts) per-file swap with a backup folder and a journal; rolls back on any failure
#   rollback(install)             put the backed-up files back (also used to recover a crashed swap)
#   state                         user://update/state.json -- the updater's note to the next game start
#
# The swap works file by file, not by renaming the install folder: it only needs the install folder itself to
# be writable (a read-only parent, a launcher whose cwd is the folder, or a Windows indexer holding the folder
# open would all break a directory rename). Each replaced file is first MOVED to <install>/.update_bak/<rel>,
# then the new file is moved in; the journal lists both sets so a rollback (or a recovery after a crash) is
# exact and idempotent. Files in the install folder that the new package does not contain are left alone.
# Loaded with preload() (no class_name).
extends RefCounted

const UpdateConfig = preload("res://updater/UpdateConfig.gd")
const UpdateManifest = preload("res://updater/UpdateManifest.gd")

const JOURNAL := "journal.json"
const STATE_PATH := "user://update/state.json"


# --- small file helpers ------------------------------------------------------------------------

static func abs_path(p: String) -> String:
	return ProjectSettings.globalize_path(p) if p.begins_with("user://") or p.begins_with("res://") else p


static func remove_tree(path: String) -> void:
	var p: String = abs_path(path)
	if p.length() < 6 or p == "/" or p.ends_with(":/") or p.ends_with(":\\"):
		return    # never recurse from a root
	var parent: DirAccess = DirAccess.open(p.get_base_dir())
	if parent != null and parent.is_link(p):
		DirAccess.remove_absolute(p)      # a symlink: remove the link itself, never what it points at
		return
	if FileAccess.file_exists(p):
		DirAccess.remove_absolute(p)
		return
	var d: DirAccess = DirAccess.open(p)
	if d == null:
		return
	d.include_hidden = true
	for sub in d.get_directories():
		remove_tree(p.path_join(sub))
	for f in d.get_files():
		DirAccess.remove_absolute(p.path_join(f))
	DirAccess.remove_absolute(p)


## Copy a file in 4 MiB steps, keeping the unix permission bits (the exec bit matters). Returns an Error.
static func copy_file(src: String, dst: String) -> int:
	var a: FileAccess = FileAccess.open(src, FileAccess.READ)
	if a == null:
		return FileAccess.get_open_error()
	DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
	var b: FileAccess = FileAccess.open(dst, FileAccess.WRITE)
	if b == null:
		a.close()
		return FileAccess.get_open_error()
	while a.get_position() < a.get_length():
		b.store_buffer(a.get_buffer(4194304))
	var werr: int = b.get_error()
	b.close()
	a.close()
	if werr != OK:
		DirAccess.remove_absolute(dst)
		return werr
	if OS.get_name() != "Windows":
		FileAccess.set_unix_permissions(dst, FileAccess.get_unix_permissions(src))
	return OK


## Rename, falling back to copy + delete across filesystems. `retries` x 250 ms for transient locks (Windows).
static func move_file(src: String, dst: String, retries: int = 0) -> int:
	DirAccess.make_dir_recursive_absolute(dst.get_base_dir())
	var err: int = FAILED
	for attempt in retries + 1:
		err = DirAccess.rename_absolute(src, dst)
		if err != OK:
			if FileAccess.file_exists(dst):
				DirAccess.remove_absolute(dst)
			err = DirAccess.rename_absolute(src, dst)
		if err == OK:
			return OK
		if attempt < retries:
			OS.delay_msec(250)
	if copy_file(src, dst) == OK:
		DirAccess.remove_absolute(src)
		return OK
	return err


## All files under `root` as relative paths ("a/b.txt"), sorted.
static func list_files(root: String) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	_walk(root, "", out)
	out.sort()
	return out


static func _walk(root: String, rel: String, out: PackedStringArray) -> void:
	var d: DirAccess = DirAccess.open(root.path_join(rel) if rel != "" else root)
	if d == null:
		return
	d.include_hidden = true
	for f in d.get_files():
		out.append(f if rel == "" else rel + "/" + f)
	for sub in d.get_directories():
		_walk(root, sub if rel == "" else rel + "/" + sub, out)


# --- extraction --------------------------------------------------------------------------------

## Extract `archive` (.zip or .tar.gz / .tgz) into `dest`. Blocking: run it on a Thread. {ok, error}.
static func extract(archive: String, dest: String) -> Dictionary:
	DirAccess.make_dir_recursive_absolute(dest)
	var lower: String = archive.to_lower()
	if lower.ends_with(".zip"):
		return _extract_zip(archive, dest)
	if lower.ends_with(".tar.gz") or lower.ends_with(".tgz"):
		return _extract_tar(archive, dest)
	return {"ok": false, "error": "Unknown update archive type."}


static func _extract_zip(archive: String, dest: String) -> Dictionary:
	var z: ZIPReader = ZIPReader.new()
	if z.open(archive) != OK:
		return {"ok": false, "error": "The update archive could not be opened."}
	for entry in z.get_files():
		var e: String = str(entry)
		var is_dir: bool = e.ends_with("/")
		var clean: String = e.rstrip("/")
		if clean == "":
			continue
		if not UpdateManifest.safe_rel(clean):
			z.close()
			return {"ok": false, "error": "The update archive contains an unsafe path and was rejected."}
		var target: String = dest.path_join(clean)
		if is_dir:
			DirAccess.make_dir_recursive_absolute(target)
			continue
		DirAccess.make_dir_recursive_absolute(target.get_base_dir())
		var f: FileAccess = FileAccess.open(target, FileAccess.WRITE)
		if f == null:
			z.close()
			return {"ok": false, "error": "Could not write %s (is the disk full?)." % clean}
		f.store_buffer(z.read_file(e))
		var werr: int = f.get_error()
		f.close()
		if werr != OK:
			z.close()
			return {"ok": false, "error": "Could not write %s (is the disk full?)." % clean}
	z.close()
	return {"ok": true, "error": ""}


static func _extract_tar(archive: String, dest: String) -> Dictionary:
	if OS.get_name() == "Windows":
		return {"ok": false, "error": "tar archives are not used on Windows."}
	var out: Array = []
	var code: int = OS.execute("tar", ["-xzf", archive, "-C", dest, "--no-same-owner"], out, true)
	if code != 0:
		return {"ok": false, "error": "Unpacking the update failed (tar exit code %d)." % code}
	# GNU tar already refuses ".." members and strips leading "/"; verify nothing escaped by walking dest.
	for rel in list_files(dest):
		if not UpdateManifest.safe_rel(rel):
			return {"ok": false, "error": "The update archive contains an unsafe path and was rejected."}
	return {"ok": true, "error": ""}


## The folder that actually holds the package files: `staging`, or its only child folder (NovaSwift/).
static func payload_root(staging: String) -> String:
	var d: DirAccess = DirAccess.open(staging)
	if d == null:
		return staging
	d.include_hidden = true
	var dirs: PackedStringArray = d.get_directories()
	var files: PackedStringArray = d.get_files()
	if dirs.size() == 1 and files.is_empty():
		return staging.path_join(dirs[0])
	return staging


## Required files (relative) that are missing or empty under `root`.
static func missing_required(root: String, required: Array) -> PackedStringArray:
	var out: PackedStringArray = PackedStringArray()
	for r in required:
		var p: String = root.path_join(str(r))
		var f: FileAccess = FileAccess.open(p, FileAccess.READ) if FileAccess.file_exists(p) else null
		if f == null or f.get_length() == 0:
			out.append(str(r))
		if f != null:
			f.close()
	return out


# --- swap + rollback ---------------------------------------------------------------------------

static func backup_dir(install: String) -> String:
	return install.path_join(UpdateConfig.BACKUP_DIRNAME)


static func _write_json(path: String, data: Dictionary) -> void:
	var f: FileAccess = FileAccess.open(path, FileAccess.WRITE)
	if f != null:
		f.store_string(JSON.stringify(data))
		f.close()


static func _read_json(path: String) -> Dictionary:
	if not FileAccess.file_exists(path):
		return {}
	var v: Variant = JSON.parse_string(FileAccess.get_file_as_string(path))
	return v if v is Dictionary else {}


## Replace the install folder's files with the payload's. opts: retries (int, per file), progress (Callable
## (done, total)), fail_after (int, tests: inject a failure after N files were installed).
## Returns {ok, error, rolled_back}. On failure everything is restored before returning.
static func apply(install: String, payload: String, opts: Dictionary = {}) -> Dictionary:
	var retries: int = int(opts.get("retries", 0))
	var fail_after: int = int(opts.get("fail_after", -1))
	var progress: Callable = opts.get("progress", Callable())
	var backup: String = backup_dir(install)
	recover(install)                      # a crashed earlier swap is undone first
	remove_tree(backup)
	DirAccess.make_dir_recursive_absolute(backup)
	var rels: PackedStringArray = list_files(payload)
	if rels.is_empty():
		return {"ok": false, "error": "The update contained no files.", "rolled_back": false}
	var replaced: Array = []
	var added: Array = []
	for rel in rels:
		if UpdateConfig.PRESERVE.has(rel.get_slice("/", 0)):
			continue
		if FileAccess.file_exists(install.path_join(rel)):
			replaced.append(rel)
		else:
			added.append(rel)
	var plan: Array = replaced + added
	_write_json(backup.path_join(JOURNAL), {"state": "swapping", "replaced": replaced, "added": added})
	var total: int = plan.size() * 2
	var done: int = 0
	for rel in replaced:
		var e1: int = move_file(install.path_join(rel), backup.path_join(rel), retries)
		if e1 != OK:
			return _fail(install, "Could not set aside %s (error %d). Is the game still running?" % [rel, e1])
		done += 1
		if progress.is_valid():
			progress.call(done, total)
	var installed: int = 0
	for rel in plan:
		if fail_after >= 0 and installed >= fail_after:
			return _fail(install, "Simulated failure after %d files." % installed)
		var e2: int = move_file(payload.path_join(rel), install.path_join(rel), retries)
		if e2 != OK:
			return _fail(install, "Could not install %s (error %d)." % [rel, e2])
		installed += 1
		done += 1
		if progress.is_valid():
			progress.call(done, total)
	_write_json(backup.path_join(JOURNAL), {"state": "done", "replaced": replaced, "added": added})
	return {"ok": true, "error": "", "rolled_back": false}


static func _fail(install: String, message: String) -> Dictionary:
	var rolled: bool = rollback(install)
	return {"ok": false, "error": message, "rolled_back": rolled}


## Undo an unfinished swap from the journal. Idempotent. Removes the backup folder when it succeeded.
static func rollback(install: String) -> bool:
	var backup: String = backup_dir(install)
	var j: Dictionary = _read_json(backup.path_join(JOURNAL))
	if j.is_empty():
		return false
	var ok: bool = true
	for rel in j.get("added", []):
		var p: String = install.path_join(str(rel))
		if FileAccess.file_exists(p) and not FileAccess.file_exists(backup.path_join(str(rel))):
			DirAccess.remove_absolute(p)
	for rel in j.get("replaced", []):
		var b: String = backup.path_join(str(rel))
		if FileAccess.file_exists(b):
			var p2: String = install.path_join(str(rel))
			if FileAccess.file_exists(p2):
				DirAccess.remove_absolute(p2)
			if move_file(b, p2, 4) != OK:
				ok = false
	if ok:
		remove_tree(backup)
	return ok


## If a previous swap died half-way (journal still says "swapping"), roll it back. True if it did.
static func recover(install: String) -> bool:
	var j: Dictionary = _read_json(backup_dir(install).path_join(JOURNAL))
	if str(j.get("state", "")) == "swapping":
		return rollback(install)
	return false


## True while a journal says a swap is unfinished (the backup folder is then the only copy of some files).
static func is_swapping(install: String) -> bool:
	return str(_read_json(backup_dir(install).path_join(JOURNAL)).get("state", "")) == "swapping"


## Delete the backup of a swap that completed (the new game started fine).
static func discard_backup(install: String) -> void:
	remove_tree(backup_dir(install))


# --- updater -> game note ----------------------------------------------------------------------

static func write_state(state: Dictionary) -> void:
	DirAccess.make_dir_recursive_absolute(abs_path("user://update"))
	_write_json(abs_path(STATE_PATH), state)


static func read_state() -> Dictionary:
	return _read_json(abs_path(STATE_PATH))


static func clear_state() -> void:
	DirAccess.remove_absolute(abs_path(STATE_PATH))
