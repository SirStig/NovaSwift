# NOVA Swift — time-sliced search for likely EV Nova installs (used by the Data Setup wizard): folders
# holding Nova Data files or a Nova Files folder, and zips named like the game. Call step() every frame
# until `done`; results accumulate in `found` ([{path, label, kind}], kind = files | install | zip).
extends RefCounted

const Prefs = preload("res://Prefs.gd")
const Importer = preload("res://DataImporter.gd")

var found: Array = []        # [{path, label, kind}]  kind: files | install | zip
var done := false
var visited := 0
var max_visited := 6000
var _queue: Array = []       # [{path, depth}]
var _seen := {}

func _init(roots: Array = []) -> void:
	var home := Prefs.user_home()
	var list: Array = roots
	if list.is_empty():
		list = default_roots()
	for r in list:
		if r is Dictionary:
			_queue.append(r)
		else:
			_queue.append({"path": str(r), "depth": 3})
	if home == "" and _queue.is_empty():
		done = true

static func default_roots() -> Array:
	var home := Prefs.user_home()
	var out: Array = []
	if home != "":
		out.append({"path": home, "depth": 1})
		for sub in ["Downloads", "Documents", "Desktop", "Games", "EV Nova", "Escape Velocity"]:
			out.append({"path": home.path_join(sub), "depth": 4})
		out.append({"path": home.path_join(".wine/drive_c"), "depth": 4})
		out.append({"path": home.path_join(".local/share/Steam/steamapps/compatdata"), "depth": 1})
	for base in ["/run/media", "/media", "/mnt", "/Volumes"]:
		out.append({"path": base, "depth": 4})
	if OS.get_name() == "Windows":
		for env in ["ProgramFiles", "ProgramFiles(x86)"]:
			var pf := OS.get_environment(env).replace("\\", "/")
			if pf != "":
				out.append({"path": pf, "depth": 3})
		for d in DirAccess.get_drive_count():
			out.append({"path": DirAccess.get_drive_name(d) + "/", "depth": 2})
	return out

## Process up to `budget` directories. True while more remain.
func step(budget := 24) -> bool:
	var n := 0
	while n < budget and not _queue.is_empty() and visited < max_visited:
		var item: Dictionary = _queue.pop_front()
		_visit(str(item["path"]), int(item["depth"]))
		n += 1
	if _queue.is_empty() or visited >= max_visited:
		done = true
	return not done

func _visit(path: String, depth: int) -> void:
	if _seen.has(path):
		return
	_seen[path] = true
	visited += 1
	var kind := Importer.looks_like_install(path)
	if kind != "":
		found.append({"path": path, "label": path, "kind": kind})
		return
	var d := DirAccess.open(path)
	if d == null:
		return
	d.list_dir_begin()
	var name := d.get_next()
	var subs: Array = []
	while name != "":
		var low := name.to_lower()
		if d.current_is_dir():
			if depth > 0 and not name.begins_with(".") and not Importer.SKIP_DIRS.has(low):
				subs.append(path.path_join(name))
		elif low.ends_with(".zip") and (low.contains("nova") or low.contains("ev ")):
			found.append({"path": path.path_join(name), "label": path.path_join(name), "kind": "zip"})
		name = d.get_next()
	d.list_dir_end()
	for s in subs:
		_queue.append({"path": s, "depth": depth - 1})


