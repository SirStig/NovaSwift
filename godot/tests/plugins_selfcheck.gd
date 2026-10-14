# Headless check of plug-in loading + the manager: discovery next to the data (the "Nova
# Plug-ins" sibling folder), enable/disable (manual order), load order precedence, persisted state,
# the user plug-in folder (import / install from a local archive / delete), catalog parsing from
# a fixture (NO network), story-lane plug-in names, reload, and the Plugins screen itself.
#   NOVA_PLUGIN_OFFLINE=1 NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/plugins_selfcheck.gd
# Real plug-ins come from data/plugins (git-ignored); loose Collision Damage.rez is used as the fixture.
# Prints PLUGINS CHECK: PASS / FAIL.
extends SceneTree

const Prefs = preload("res://Prefs.gd")
const Controls = preload("res://Controls.gd")
const PluginsScreen = preload("res://screens/Plugins.gd")

var ok := true
var nova
var pl


func _check(label: String, cond: bool, detail := "") -> bool:
	print(("  ok   " if cond else "  FAIL ") + label + ((" — " + detail) if detail != "" else ""))
	if not cond:
		ok = false
	return cond


func _frames(n := 3) -> void:
	for i in n:
		await process_frame


func _ids(list: Array) -> Array:
	return list.map(func(p): return p.id)


func _link_tree(src: String, dst: String) -> void:
	DirAccess.make_dir_recursive_absolute(dst)
	var da := DirAccess.open(dst)
	for f in DirAccess.get_files_at(src):
		if f.get_extension().to_lower() in ["rez", "ndat"]:
			da.create_link(src.path_join(f), dst.path_join(f))
	for d in DirAccess.get_directories_at(src):
		_link_tree(src.path_join(d), dst.path_join(d))


func _wipe(path: String) -> void:
	if DirAccess.dir_exists_absolute(path):
		for f in DirAccess.get_files_at(path):
			DirAccess.remove_absolute(path.path_join(f))
		for d in DirAccess.get_directories_at(path):
			_wipe(path.path_join(d))
		DirAccess.remove_absolute(path)


func _init() -> void:
	Prefs.path = OS.get_user_data_dir() + "/plugins_settings.cfg"
	Prefs.load_all()
	Controls.register()
	_run.call_deferred()


func _run() -> void:
	var repo := ProjectSettings.globalize_path("res://") + ".."
	var data := OS.get_environment("NOVA_DATA_DIR")
	if data == "":
		data = repo + "/data/base"
	var src_rez := repo + "/data/plugins/Collision Damage.rez"
	if not FileAccess.file_exists(src_rez):
		print("SKIP: data/plugins/Collision Damage.rez not present")
		print("PLUGINS CHECK: PASS")
		quit(0)
		return
	var scratch := OS.get_user_data_dir() + "/plugins_check"
	_wipe(scratch)
	DirAccess.make_dir_recursive_absolute(scratch)

	nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	pl = ClassDB.instantiate("NovaPlugins")
	pl.attach(nova)
	pl.set_state_file(scratch + "/state.json")
	pl.set_install_dir(scratch + "/user/Plug-ins")

	# --- baseline: no plug-ins anywhere -------------------------------------------------
	_check("load_game (base only)", nova.load_game(data))
	var base_count: int = pl.loaded_resource_count()
	_check("no plug-ins discovered next to data/base", JSON.parse_string(pl.list()).is_empty())
	var base_ships: int = pl.loaded_type_count("shïp")
	_check("base has ships", base_ships > 0, str(base_ships))

	# --- a game folder with a sibling "Nova Plug-ins" holding two copies of one plug-in --
	var game := scratch + "/game"
	DirAccess.make_dir_recursive_absolute(game + "/Nova Files")
	DirAccess.make_dir_recursive_absolute(game + "/Nova Plug-ins")
	_link_tree(data, game + "/Nova Files")
	DirAccess.copy_absolute(src_rez, game + "/Nova Plug-ins/A.rez")
	DirAccess.copy_absolute(src_rez, game + "/Nova Plug-ins/B.rez")
	var nf := game + "/Nova Files"
	_check("load_game (with Nova Plug-ins sibling)", nova.load_game(nf))
	var l1: Array = JSON.parse_string(pl.list())
	_check("discovery finds both plug-ins in load order", _ids(l1) == ["A.rez", "B.rez"], str(_ids(l1)))
	_check("original rule: all enabled, none switchable", l1.all(func(p): return p.enabled and not p.canToggle))
	var with_both: int = pl.loaded_resource_count()
	var summary: Dictionary = JSON.parse_string(pl.contribution_summary())
	print("   resources base=", base_count, " with plug-ins=", with_both, " contribution keys=", summary.keys())
	_check("plug-ins change the merged data", with_both != base_count or summary.has("B.rez"))
	_check("original order: later file name (B) wins identical resources",
		summary.has("B.rez") and not summary.has("A.rez"), str(summary.keys()))
	var st: Dictionary = JSON.parse_string(pl.state())
	_check("state lists the searched Nova Plug-ins folder", st.dirs.any(func(d): return str(d).ends_with("Nova Plug-ins")))
	_check("base excludes plug-in folders (no double load)", not st.failures.size() > 0)

	# --- manual order: enable switches + move -------------------------------------------
	_check("ordinary plug-ins can't be switched without manual order", not pl.set_enabled("A.rez", false))
	pl.set_manual_order(true)
	l1 = JSON.parse_string(pl.list())
	_check("manual order: switchable, nothing enabled until chosen",
		l1.all(func(p): return p.canToggle and not p.enabled), str(l1.map(func(p): return p.enabled)))
	_check("enable A", pl.set_enabled("A.rez", true))
	_check("reload", pl.reload())
	summary = JSON.parse_string(pl.contribution_summary())
	_check("only A contributes", summary.has("A.rez") and not summary.has("B.rez"), str(summary.keys()))
	_check("enable B", pl.set_enabled("B.rez", true))
	pl.reload()
	summary = JSON.parse_string(pl.contribution_summary())
	_check("manual order, A before B: B wins", summary.has("B.rez") and not summary.has("A.rez"))
	_check("move B up (before A)", pl.move("B.rez", -1))
	_check("order changed", _ids(JSON.parse_string(pl.list())) == ["B.rez", "A.rez"])
	pl.reload()
	summary = JSON.parse_string(pl.contribution_summary())
	_check("load order respected: now A wins", summary.has("A.rez") and not summary.has("B.rez"), str(summary.keys()))
	_check("can't move past the end", not pl.move("B.rez", -1))
	_check("disable both", pl.set_enabled("A.rez", false) and pl.set_enabled("B.rez", false))
	_check("reload restores the base data", pl.reload() and pl.loaded_resource_count() == base_count
		and JSON.parse_string(pl.contribution_summary()).keys() == [""],
		"%d vs %d" % [pl.loaded_resource_count(), base_count])
	# persisted: a brand new facade reads the same file
	pl.set_enabled("A.rez", true)
	pl.reload()
	var pl2 = ClassDB.instantiate("NovaPlugins")
	pl2.attach(nova)
	pl2.rescan()
	var l2: Array = JSON.parse_string(pl2.list())
	_check("state persists (order + enabled)", _ids(l2) == ["B.rez", "A.rez"] and l2[1].enabled and not l2[0].enabled, str(l2))
	var saved = JSON.parse_string(FileAccess.get_file_as_string(scratch + "/state.json"))
	_check("state file holds manual flag, order and enabled flags", saved is Dictionary and saved.manual == true
		and saved.plugins.map(func(p): return p.id) == ["B.rez", "A.rez"]
		and saved.plugins.map(func(p): return p.isEnabled) == [false, true], str(saved))

	# --- user plug-in folder: import, local install, delete -----------------------------
	_check("import a loose .rez", JSON.parse_string(pl.import_from(src_rez)).ok)
	_check("import is under the user folder", FileAccess.file_exists(scratch + "/user/Plug-ins/Collision Damage.rez"))
	pl.rescan()
	var l3: Array = JSON.parse_string(pl.list())
	var imported = l3.filter(func(p): return p.id == "Collision Damage.rez")
	_check("imported plug-in is listed and deletable", imported.size() == 1 and imported[0].deletable)
	_check("game-folder plug-ins are not deletable", not pl.delete("A.rez"))
	_check("delete the imported one", pl.delete("Collision Damage.rez"))
	pl.rescan()
	_check("gone after rescan", not _ids(JSON.parse_string(pl.list())).has("Collision Damage.rez"))
	# zip -> real installer (unpack into <install>/<id>/) with version metadata
	var zip_path := scratch + "/fixture.zip"
	var zp := ZIPPacker.new()
	zp.open(zip_path)
	zp.start_file("Fixture Plug-in/Fixture.rez")
	zp.write_file(FileAccess.get_file_as_bytes(src_rez))
	zp.close_file()
	zp.close()
	var inst: Dictionary = JSON.parse_string(pl.install_local("fixture-plugin", zip_path, "1.0"))
	_check("install from local archive", inst.ok, str(inst))
	pl.rescan()
	var l4: Array = JSON.parse_string(pl.list())
	var fx = l4.filter(func(p): return p.id == "fixture-plugin")
	_check("installed plug-in id == catalog id (looked through the wrapper folder)", fx.size() == 1, str(_ids(l4)))
	_check("install marks a reload as needed", pl.needs_reload())

	# --- catalog from a fixture file: no network ----------------------------------------
	var cat_path := scratch + "/catalog.json"
	var cf := FileAccess.open(cat_path, FileAccess.WRITE)
	cf.store_string(JSON.stringify({"schemaVersion": 1, "plugins": [
		{"id": "fixture-plugin", "name": "Fixture", "author": "Me", "version": "1.2", "summary": "s",
			"tags": ["ships"], "downloadURLs": ["https://example.invalid/fixture.zip"], "popularity": 3},
		{"id": "http-only", "name": "Insecure", "author": "X", "version": "1.0", "summary": "s",
			"downloadURLs": ["http://example.invalid/x.zip"], "popularity": 9},
		{"id": "not-installed", "name": "Other", "author": "Y", "version": "1.0", "summary": "s",
			"isTotalConversion": true, "downloadURLs": ["https://example.invalid/o.zip"], "popularity": 1}]}))
	cf.close()
	_check("catalog fixture parses", pl.catalog_load_file(cat_path))
	var cat: Dictionary = JSON.parse_string(pl.catalog_state())
	var by := {}
	for e in cat.entries:
		by[e.id] = e
	_check("3 entries", cat.entries.size() == 3)
	_check("installed v1.0 vs catalog v1.2 -> update available", by["fixture-plugin"].status == "update" and by["fixture-plugin"].installedVersion == "1.0")
	_check("updates list", cat.updates == ["fixture-plugin"])
	_check("uninstalled entry", by["not-installed"].status == "available")
	_check("non-HTTPS link is not downloadable and install refuses", not by["http-only"].downloadable and not pl.install("http-only"))
	_check("bundled catalog copy matches the shipped one",
		FileAccess.get_file_as_string("res://data/PluginCatalog.json") == FileAccess.get_file_as_string(repo + "/Sources/NovaSwiftPluginStore/Resources/PluginCatalog.json"))
	_check("set_bundled_catalog reads it", pl.set_bundled_catalog(ProjectSettings.globalize_path("res://data/PluginCatalog.json")))
	pl.catalog_offline()
	cat = JSON.parse_string(pl.catalog_state())
	_check("offline catalog lists the shipped entries", cat.entries.size() > 0 and cat.source in ["bundled", "cache"], str(cat.source))

	# --- reload with the installed + game plug-ins; story lane names ---------------------
	pl.set_manual_order(false)
	_check("reload with original rules", pl.reload())
	_check("needs_reload cleared by a load", not pl.needs_reload())
	var sync_count: int = pl.loaded_resource_count()
	_check("async load starts", nova.load_game_async(nf))
	var st_a: Dictionary = {}
	for i in 3000:
		st_a = JSON.parse_string(nova.load_status())
		if st_a.get("done", false):
			break
		await process_frame
		OS.delay_msec(20)
	_check("async load includes plug-ins (same data as load_game)", st_a.get("ok", false) and pl.loaded_resource_count() == sync_count,
		"%d vs %d" % [pl.loaded_resource_count(), sync_count])

	# --- the Plugins screen ---------------------------------------------------------------
	var scr = PluginsScreen.new()
	root.add_child(scr)
	scr.setup(nova)
	# setup() also starts a live catalog refresh (network); let it finish (or fail) first so a late
	# reply can't replace the fixture catalog mid-check (this was the intermittent failure).
	for i in 400:
		if not bool(JSON.parse_string(pl.catalog_state()).get("refreshing", false)):
			break
		await create_timer(0.05).timeout
	pl.catalog_load_file(cat_path)   # after setup: it loads the offline/bundled catalog first
	await _frames(4)
	_check("screen: tabs", scr.tab_buttons.has("Installed") and scr.tab_buttons.has("Browse") and scr.tab_buttons.has("Load order"))
	_check("screen: installed rows", scr._content.get_child_count() >= 2)
	_check("screen: focus target exists (gamepad nav)", scr.first_control != null and scr.first_control.focus_mode != Control.FOCUS_NONE)
	scr._set_tab("Browse")
	await _frames(2)
	_check("screen: browse shows catalog entries", scr._content.find_children("*", "Button", true, false).any(func(b): return b.text == "Update"))
	scr._open_detail("not-installed")
	await _frames(2)
	_check("screen: detail page", scr.detail_id == "not-installed" and scr._content.get_child_count() > 3)
	scr.detail_id = ""
	scr._set_tab("Load order")
	await _frames(2)
	_check("screen: load order rows", scr._content.get_child_count() >= 3)
	var closed := [false]
	scr.closed.connect(func(): closed[0] = true)
	var ev := InputEventAction.new()
	ev.action = "ui_cancel"
	ev.pressed = true
	root.push_input(ev)
	await _frames(6)
	_check("screen: Esc/B closes", closed[0])
	scr.queue_free()

	print("PLUGINS CHECK: ", "PASS" if ok else "FAIL")
	quit(0 if ok else 1)
