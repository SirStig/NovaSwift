# NOVA Swift -- the multiplayer plug-in gate dialog: what to do when a server's GAMEPLAY plug-ins differ from yours.
#
# Opened by the Multiplayer hub when a join is refused with code "plugins" (the REJECT detail carries the server's
# manifest, total conversion and add-ons). Cosmetic plug-ins (art / sound / text only) never get here:
# the gate manifest is gameplay-only (Sources/NovaSwiftKit/PluginGameplay.swift).
#
#   * everything the server needs is in the plug-in catalog  -> ONE prompt: "This server uses these plug-ins: A, B, C.
#     Install and enable them for this session?"  [Install & Join] [Cancel]   (also switches off your extras and
#     selects the server's total conversion, listed in the same sentence);
#   * something can't be resolved automatically (not in the catalog, offline catalog) -> the detailed list
#     (missing / other version / extra / total conversion, with the server's website or contact) and the actions
#     that still work: install what is available, switch off extras, switch total conversion.
#
# "Apply" = remember the player's own set (NetPrefs "plugin_restore", restored when the session ends), install,
# enable / disable via the manual-order mode, reload the game data through the Shell's loading screen, then join
# again. Reloading replaces the data objects, so it only runs on the main menu (no pilot flying); mid-flight the
# dialog asks the player to return to the menu first.
#
# Loaded with preload() (no class_name), like Controls.gd.
extends Node

const Alert = preload("res://ui/novaswift/NovaAlert.gd")
const NetPlugins = preload("res://net/NetPlugins.gd")
const NetPrefs = preload("res://net/NetPrefs.gd")

const CATALOG := "res://data/PluginCatalog.json"

var nova: Object = null
var svc: Node = null
var shell: Node = null
var pl: Object = null


## detail: the REJECT detail ({server_manifest, server_tc, server_addons}); join: {host, port, pw, name};
## meta: {website, contact} of the server when known.
func run(host: Node, nova_obj: Object, service: Node, detail: Dictionary, join: Dictionary, meta: Dictionary) -> void:
	nova = nova_obj
	svc = service
	shell = NetPlugins.find_shell(host)
	host.add_child(self)
	var required: Array = NetPlugins.required_from_manifest(str(detail.get("server_manifest", "")))
	var server_tc: String = str(detail.get("server_tc", ""))
	var local: Dictionary = NetPlugins.local_info(nova, true)
	var cmp: Dictionary = NetPlugins.compare(required, server_tc, local)
	_open_catalog()
	await _wait_catalog()
	var cat: Dictionary = _catalog_by_id()
	var plan: Dictionary = _plan(cmp, cat, required)
	if bool(plan["auto"]):
		_prompt_simple(host, cmp, plan, detail, join)
	else:
		_prompt_detail(host, cmp, plan, detail, join, meta)


func _open_catalog() -> void:
	if not ClassDB.class_exists("NovaPlugins"):
		return
	pl = ClassDB.instantiate("NovaPlugins")
	pl.attach(nova)
	if FileAccess.file_exists(CATALOG):
		pl.set_bundled_catalog(ProjectSettings.globalize_path(CATALOG))
	pl.rescan()
	pl.catalog_offline()
	pl.catalog_refresh()


func _wait_catalog() -> void:
	if pl == null:
		return
	var t: float = 0.0
	while t < 6.0:
		var st: Variant = JSON.parse_string(str(pl.catalog_state()))
		if st is Dictionary and not bool((st as Dictionary).get("refreshing", false)) and not ((st as Dictionary).get("entries", []) as Array).is_empty():
			return
		await get_tree().create_timer(0.25).timeout
		t += 0.25


func _catalog_by_id() -> Dictionary:
	var out: Dictionary = {}
	if pl == null:
		return out
	var st: Variant = JSON.parse_string(str(pl.catalog_state()))
	if st is Dictionary:
		for e in ((st as Dictionary).get("entries", []) as Array):
			var d: Dictionary = e
			out[str(d.get("id", ""))] = d
			out["name:" + str(d.get("name", "")).to_lower()] = d
	return out


## -> {auto, install:[{req, entry}], unresolved:[req], extras:[...], switch_tc: bool}
func _plan(cmp: Dictionary, cat: Dictionary, required: Array) -> Dictionary:
	var install: Array = []
	var unresolved: Array = []
	for r in (cmp["rows"] as Array):
		var row: Dictionary = r
		if str(row["state"]) == "ok":
			continue
		var e: Variant = cat.get(str(row["id"]), cat.get("name:" + str(row["name"]).to_lower()))
		if e is Dictionary and bool((e as Dictionary).get("downloadable", false)):
			install.append({"req": row, "entry": e})
		else:
			unresolved.append(row)
	var tc_needed: bool = bool(cmp["tc_mismatch"]) and str(cmp["tc_server"]) != ""
	return {"auto": unresolved.is_empty(), "install": install, "unresolved": unresolved, "extras": cmp["extra"], "switch_tc": tc_needed,
		"required": required}


func _names(rows: Array) -> String:
	var n: PackedStringArray = PackedStringArray()
	for r in rows:
		n.append(str((r as Dictionary).get("name", "?")))
	return ", ".join(n)


func _prompt_simple(host: Node, cmp: Dictionary, plan: Dictionary, detail: Dictionary, join: Dictionary) -> void:
	var need: Array = []
	for r in (cmp["rows"] as Array):
		need.append(r)
	var msg: String = "This server uses these plug-ins: %s.\n\nInstall and enable them for this session?" % _names(need)
	if not (plan["extras"] as Array).is_empty():
		msg += "\n\nYour other plug-ins (%s) are switched off while you play here." % _names(plan["extras"])
	msg += "\n\nYour own plug-ins come back when you leave the game."
	Alert.show(host, {"title": "Plug-ins needed", "message": msg, "width": 480.0, "buttons": [
		{"title": "Cancel", "role": "cancel", "cb": func() -> void: queue_free()},
		{"title": "Install & Join", "cb": func() -> void: _apply(plan, detail, join, true)}]})


func _prompt_detail(host: Node, cmp: Dictionary, plan: Dictionary, detail: Dictionary, join: Dictionary, meta: Dictionary) -> void:
	var lines: PackedStringArray = PackedStringArray()
	for r in (cmp["rows"] as Array):
		var row: Dictionary = r
		var mark: String = {"ok": "[ok]", "wrong": "[other version]", "missing": "[missing]"}.get(str(row["state"]), "[?]")
		var how: String = ""
		if str(row["state"]) != "ok":
			var resolvable: bool = false
			for i in (plan["install"] as Array):
				if str(((i as Dictionary)["req"] as Dictionary)["id"]) == str(row["id"]):
					resolvable = true
			how = " - in the plug-in catalog" if resolvable else " - NOT in the catalog"
		lines.append("%s %s%s" % [mark, str(row["name"]), how])
	if not (plan["extras"] as Array).is_empty():
		lines.append("")
		lines.append("You have, but the server doesn't: " + _names(plan["extras"]))
	if bool(plan["switch_tc"]):
		lines.append("")
		lines.append("Total conversion: the server runs \"%s\"." % str(cmp["tc_server"]))
	if not (plan["unresolved"] as Array).is_empty():
		lines.append("")
		lines.append("Some plug-ins can't be installed automatically (not in the catalog, or the catalog is offline). Get them from the server's owner:")
		var site: String = str(meta.get("website", ""))
		var contact: String = str(meta.get("contact", ""))
		lines.append(site if site != "" else "(no website listed)")
		if contact != "":
			lines.append("Contact: " + contact)
	var buttons: Array = [{"title": "Cancel", "role": "cancel", "cb": func() -> void: queue_free()}]
	if not (plan["install"] as Array).is_empty() or not (plan["extras"] as Array).is_empty() or bool(plan["switch_tc"]):
		buttons.append({"title": "Apply what I can & Join", "cb": func() -> void: _apply(plan, detail, join, false)})
	var site_url: String = str(meta.get("website", ""))
	if site_url.begins_with("https://"):
		buttons.append({"title": "Open server website", "cb": func() -> void:
			OS.shell_open(site_url)
			queue_free()})
	Alert.show(host, {"title": "Plug-ins don't match", "message": "\n".join(lines), "width": 560.0, "buttons": buttons})


# --- apply ------------------------------------------------------------------------------------------------

func _apply(plan: Dictionary, detail: Dictionary, join: Dictionary, full: bool) -> void:
	if shell == null or not shell.has_method("load_data_async") or not shell.has_method("in_menu"):
		_info("Can't change plug-ins from here. Open Multiplayer from the main menu and try again.")
		return
	if not bool(NetPlugins.at_main_menu(shell)):
		_info("Changing plug-ins reloads the game data, which can't happen while you are flying. Save and return to the main menu (Pause > Save & Quit), open Multiplayer and join again - your choice is remembered only for that join.")
		return
	if pl == null:
		_info("The plug-in system isn't available in this build.")
		return
	NetPlugins.remember_own_set(pl)
	shell.show_loading("Getting plug-ins for this server", true)
	await get_tree().process_frame
	var failed: PackedStringArray = PackedStringArray()
	for i in (plan["install"] as Array):
		var entry: Dictionary = (i as Dictionary)["entry"]
		var id: String = str(entry.get("id", ""))
		shell.set_loading_progress("Installing %s" % str(entry.get("name", id)), 0.0)
		if not bool(pl.install(id)) or not await _wait_install(id, str(entry.get("name", id))):
			failed.append(str(entry.get("name", id)))
	pl.rescan()
	# Enable the server's set, switch off the player's extras (the manual-order mode is what allows toggling).
	pl.set_manual_order(true)
	for r in (NetPlugins.required_from_manifest(str(detail.get("server_manifest", ""))) as Array):
		pl.set_enabled(str((r as Dictionary).get("id", "")), true)
	for x in (plan["extras"] as Array):
		pl.set_enabled(str((x as Dictionary).get("id", "")), false)
	var tc_id: String = str(detail.get("server_tc", ""))
	if tc_id != "":
		pl.set_enabled(tc_id, true)
		for a in (detail.get("server_addons", []) as Array):
			pl.tc_addon_set_enabled(tc_id, str(a), true)
	var base: String = str(JSON.parse_string(str(pl.state())).get("base", ""))
	var ok: bool = await shell.load_data_async(base, "Reloading plug-ins")
	pl.rescan()
	NetPlugins.invalidate()
	shell.hide_loading()
	if not ok:
		_info("The game data couldn't be reloaded with these plug-ins. Your own set will be restored.")
		svc.request_plugin_restore()
		return
	if not failed.is_empty():
		_info("Couldn't install: %s. The join may fail again; the list will show what is still missing." % ", ".join(failed))
	svc.last_error = ""
	svc.last_error_code = ""
	svc.join_game(str(join.get("host", "")), int(join.get("port", 53735)), str(join.get("pw", "")), str(join.get("name", "")))
	queue_free()


func _wait_install(id: String, label: String) -> bool:
	var t: float = 0.0
	while t < 300.0:
		await get_tree().create_timer(0.3).timeout
		t += 0.3
		var st: Variant = JSON.parse_string(str(pl.catalog_state()))
		if not (st is Dictionary):
			continue
		for e in ((st as Dictionary).get("entries", []) as Array):
			var d: Dictionary = e
			if str(d.get("id", "")) != id:
				continue
			var tr: Variant = d.get("transfer", {})
			if tr is Dictionary and not (tr as Dictionary).is_empty():
				var tr_d: Dictionary = tr
				if str(tr_d.get("error", "")) != "":
					return false
				shell.set_loading_progress("Installing %s" % label, maxf(0.0, float(tr_d.get("progress", 0.0))))
			elif str(d.get("status", "")) == "installed":
				return true
	return false


func _info(text: String) -> void:
	Alert.show(self, {"title": "Plug-ins", "message": text, "buttons": [{"title": "OK", "role": "cancel", "cb": func() -> void: queue_free()}]})
