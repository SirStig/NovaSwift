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
		if str(row.get("type", "")) == "sÿst":
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
	# PluginDocument.isDirty is changeCount != savedChangeCount and undo/redo count as changes (by design, same
	# as the Apple editor), so undoing everything empties the stack but leaves the document marked unsaved.
	_ok(clean.canUndo == false and clean.canRedo == true, "two undos empty the undo stack")

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
			texts.append(str(b.tooltip_text).get_slice("  (", 0))
		for name in ["Close", "File", "Save", "Nothing to undo", "Nothing to redo", "Test Run", "Overview", "Resources", "Galaxy Map", "Star System", "Story & Bits", "Validation", "Project & Export", "Bundle Files"]:
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
	_ok(screen.ed != null and screen.tool == "overview", "editor screen builds on a new document")
	await _drive(screen)
	screen.queue_free()

	print("PLUGIN EDITOR " + ("OK" if ok else "FAILED"))
	quit(0 if ok else 1)


## Visit every tool and inspector kind, and run the edit commands, so runtime errors surface here.
func _drive(screen) -> void:
	for t in screen.TOOLS:
		screen._show_tool(str(t[0]))
		await process_frame
		_ok(screen.tool == str(t[0]) and screen._tool_host.get_child_count() > 0, "tool %s builds" % str(t[0]))
	for ty in ["shïp", "wëap", "oütf", "sÿst", "spöb", "mïsn", "dësc", "STR#", "PICT", "rlëD", "snd ", "DITL", "gövt", "crön"]:
		screen._pick_type(ty)
		await process_frame
		var insp = screen._inspector
		_ok(insp != null and insp.get_child_count() > 0, "inspector for '%s' #%d (%d cards)" % [ty, screen.selected_id, insp.get_child_count() if insp else 0])
	screen._pick_type("shïp")
	screen.selected_id = 128
	screen._show_tool("resources")
	await process_frame
	screen._inspector._commit({"t": "int", "v": 999}, "speed")
	await process_frame
	_ok(bool(screen._st.get("dirty", false)), "inspector edit marks the document dirty")
	screen._show_tool("overview")
	await process_frame
	screen._create_current()
	await process_frame
	_ok(screen.tool == "resources" and screen.selected_id >= 128, "New creates and selects (#%d)" % screen.selected_id)
	screen._duplicate_current()
	await process_frame
	screen._inspector.open_picker("wëap", 128, screen._inspector, func(_id: int) -> void: pass)
	await process_frame
	_ok(screen._inspector._picker_list.item_count > 0, "resource picker lists weapons (%d)" % screen._inspector._picker_list.item_count)
	screen._inspector._picker.hide()
	screen._do_undo()
	screen._do_undo()
	screen._do_undo()
	await process_frame
	_ok(not bool(screen._st.get("canUndo", true)), "undo unwinds every editor edit")
	screen._system_id = 128
	screen._show_tool("system")
	await process_frame
	screen._show_tool("galaxy")
	await process_frame
	screen._show_tool("story")
	await process_frame
	for t in screen.TOOLS:
		screen._show_tool(str(t[0]))
		await process_frame


func _ok(cond: bool, label: String) -> void:
	if cond:
		print("ok  ", label)
	else:
		ok = false
		print("FAIL ", label)
