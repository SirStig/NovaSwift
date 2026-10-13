# Headless self-check for the plug-in editor (NovaEditor + the Godot shell).
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/plugin_editor_selfcheck.gd
extends SceneTree

const Prefs = preload("res://Prefs.gd")
const Shell = preload("res://screens/Shell.gd")
const PluginEditor = preload("res://editor/PluginEditor.gd")

var ok := true


func _init() -> void:
	Prefs.path = OS.get_user_data_dir() + "/editor_selfcheck.cfg"
	DirAccess.remove_absolute(Prefs.path)
	Prefs.load_all()
	Prefs.set_value("presentation", "modern_menu", true)
	if not ClassDB.class_exists("NovaEditor") or not ClassDB.class_exists("NovaWorld"):
		push_error("FAIL NovaEditor/NovaWorld missing — rebuild the GDExtension")
		quit(1)
		return
	var nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	var data := OS.get_environment("NOVA_DATA_DIR")
	if data == "":
		data = ProjectSettings.globalize_path("res://") + "../data/base"
	if DirAccess.dir_exists_absolute(data):
		nova.load_game(data)

	var ed = ClassDB.instantiate("NovaEditor")
	ed.attach(nova)
	ed.new_document()
	var st = JSON.parse_string(ed.status())
	_ok(st is Dictionary and st.dirty == false and st.canUndo == false, "new document is clean")
	var types: Array = JSON.parse_string(ed.types())
	_ok(types.size() > 8, "schema type list (%d)" % types.size())
	var has_system := false
	var form := ""
	for row in types:
		if str(row.get("name", "")) == "System":
			has_system = true
		if form == "" and str(row.get("kind", "")) == "form":
			form = str(row.get("type", ""))
	_ok(has_system, "System is a named type")

	var made = JSON.parse_string(ed.create("STR#", "Greetings"))
	_ok(made is Dictionary and made.ok == true, "create STR# (%s)" % str(made))
	var sid := int(made.get("id", -1))
	ed.set_text("STR#", sid, JSON.stringify({"strings": ["Alpha", "Beta"]}))
	var insp = JSON.parse_string(ed.inspect("STR#", sid))
	var strings: Array = insp.get("text", {}).get("strings", [])
	_ok(strings == ["Alpha", "Beta"], "text round-trip %s" % str(strings))
	var dirty = JSON.parse_string(ed.status())
	_ok(dirty.dirty == true and dirty.canUndo == true, "edit is dirty and undoable")
	ed.undo()
	ed.undo()
	var clean = JSON.parse_string(ed.status())
	_ok(clean.dirty == false and clean.canUndo == false, "two undos return to clean")

	if form != "":
		var made_form = JSON.parse_string(ed.create(form, "Probe"))
		_ok(made_form.ok == true, "create form %s" % form)
		var fid := int(made_form.id)
		var form_info = JSON.parse_string(ed.inspect(form, fid))
		var key := ""
		for field in form_info.get("fields", []):
			if str(field.get("kind", "")) == "int" and int(field.get("count", 1)) <= 1:
				key = str(field.get("key", ""))
				break
		_ok(key != "" and form_info.get("fields", []).size() > 0, "form schema has fields (%s)" % key)
		if key != "":
			ed.set_field(form, fid, key, JSON.stringify({"t": "int", "v": 7}))
			var again = JSON.parse_string(ed.inspect(form, fid))
			var value = again.get("values", {}).get(key, {})
			_ok(int(value.get("v", -1)) == 7, "set field %s -> %s" % [key, str(value)])
			ed.undo()

	ed.set_plugin_info("Selfcheck Plug-in", "Suite", "1", "notes")
	var path := OS.get_user_data_dir() + "/editor_selfcheck.rez"
	DirAccess.remove_absolute(path)
	var saved = JSON.parse_string(ed.save_as(path, false))
	_ok(saved.dirty == false and str(saved.path) == path, "save as (%s) err=%s" % [saved.path, saved.error])
	ed.new_document()
	var opened = JSON.parse_string(ed.open_path(path))
	_ok(str(opened.name) == "Selfcheck Plug-in" and opened.dirty == false, "reopen saved plug-in (%s)" % str(opened.name))

	# Shell: the button opens the editor over a hidden menu and close brings the menu back.
	var shell = Shell.new()
	root.add_child(shell)
	shell.setup(nova, null)
	if nova.has_method("load_game") and DirAccess.dir_exists_absolute(data):
		shell.start()
		await process_frame
		await process_frame
		_ok(shell.main_menu != null, "menu is up")
		shell.main_menu.plugin_editor.emit()
		await process_frame
		await process_frame
		_ok(shell.plugin_editor != null and shell.in_menu() and not shell.main_menu.visible, "editor replaces the menu")
		var texts := []
		for b in shell.plugin_editor.find_children("*", "Button", true, false):
			texts.append(b.text)
		for name in ["Close", "File", "Save", "Undo", "Redo", "Test Run", "Changes", "Resources", "Galaxy Map", "Star System", "Story & Bits", "Validation", "Project & Export", "Bundle Files"]:
			_ok(texts.has(name), "editor has %s" % name)
		shell.plugin_editor._request_close()
		await process_frame
		await process_frame
		_ok(shell.plugin_editor == null and shell.main_menu.visible and shell.in_menu(), "close returns to the menu")
	else:
		print("SKIP shell wiring: no data dir")

	# The screen itself builds with no data.
	var screen = PluginEditor.new()
	root.add_child(screen)
	screen.setup(nova, data)
	await process_frame
	_ok(screen.ed != null and screen.tool == "changes", "editor screen builds on a new document")
	screen.queue_free()

	print("PLUGIN EDITOR " + ("OK" if ok else "FAILED"))
	quit(0 if ok else 1)


func _ok(cond: bool, label: String) -> void:
	if cond:
		print("ok  ", label)
	else:
		ok = false
		print("FAIL ", label)
