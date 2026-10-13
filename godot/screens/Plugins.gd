# NOVA Swift — Plug-ins screen: installed list (enable / delete / import), the online catalog
# (browse, details, install, update), and the load order. The Godot counterpart of the Apple
# app's Launcher/PluginsView.swift + Plugins/{InstalledPluginsView,PluginCard,PluginDetailView,
# RemoteImage}.swift. All rules live in the shared Swift core behind the bridge's `NovaPlugins`
# class (Plugins.swift): discovery, the original-vs-manual load order, the merge, the catalog,
# download + checksum + unpack. This file is presentation only.
#
# Reach it with `Plugins.new()` + `add_child` + `setup(nova)`; it emits `closed` when done.
# Wiring (main menu "Plug-ins" button, Settings button) is in docs/GODOT_LAYER.md.
#
# Behaviour copied from Apple:
#   * Without the "Manual plug-in order" enhancement every installed plug-in loads automatically
#     (the original rule); only a total conversion can be switched. Load order is the original's
#     alphabetical order. With it on, each plug-in has an enable switch and Up / Down.
#   * Changes take effect by reloading the game data (a loading overlay shows while it runs).
#     Apple reloads after every change; here changes are batched and applied when you press
#     Apply, leave the screen, or an install finishes.
#   * Only the player's own user plug-in folder is deletable; the game's own "Nova Plug-ins"
#     folder is read-only here.
#   * Downloads are HTTPS only, checksum-verified by NovaSwiftPluginStore, and never mirrored.
#
# Gamepad / keyboard: pure Godot focus navigation (d-pad / arrows move, A / Enter activate,
# B / Esc back out of a detail page first, then close).
extends CanvasLayer

const ShellUI = preload("res://screens/ShellUI.gd")

signal closed

const TABS := ["Installed", "Browse", "Load order"]
const FILTERS := ["Popular", "Recent", "Total conversions", "Ships", "Story", "Graphics",
	"Gameplay", "Installed", "Updates"]
const BUNDLED_CATALOG := "res://data/PluginCatalog.json"

var tab := "Installed"
var filter := "Popular"
var query := ""
var detail_id := ""            # catalog entry shown on the detail page
var first_control: Control
var tab_buttons := {}

var _nova: Object
var _pl: Object
var _root: Control
var _content: VBoxContainer
var _scroll: ScrollContainer
var _status: Label
var _overlay: Control
var _busy_apply := false
var _apply_btn: Button
var _poll := 0.0
var _icons := {}               # url -> Array[TextureRect] waiting for bytes
var _import_dialog: FileDialog
var _delete_confirm := ""      # plug-in id awaiting a second press of Delete


func setup(nova: Object, start_tab := "Installed") -> void:
	_nova = nova
	layer = 72
	_pl = ClassDB.instantiate("NovaPlugins")
	_pl.attach(nova)
	_pl.set_bundled_catalog(ProjectSettings.globalize_path(BUNDLED_CATALOG))
	_pl.rescan()
	_pl.catalog_offline()
	_pl.catalog_refresh()
	tab = start_tab
	_root = ShellUI.screen(self, 0.96)
	var margin := MarginContainer.new()
	margin.set_anchors_preset(Control.PRESET_FULL_RECT)
	for side in ["left", "right"]:
		margin.add_theme_constant_override("margin_" + side, 90)
	margin.add_theme_constant_override("margin_top", 40)
	margin.add_theme_constant_override("margin_bottom", 40)
	_root.add_child(margin)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	margin.add_child(box)

	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 10)
	box.add_child(head)
	var title := Label.new()
	title.text = "Plug-ins"
	title.add_theme_font_size_override("font_size", 28)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(title)
	for t in TABS:
		var b := Button.new()
		b.text = t
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(130, 40)
		b.pressed.connect(_set_tab.bind(t))
		head.add_child(b)
		tab_buttons[t] = b
	var imp := ShellUI.button(head, "Import…", _open_import, nova)
	imp.custom_minimum_size = Vector2(110, 40)
	_apply_btn = ShellUI.button(head, "Apply", func(): await _apply(); _render(), nova)
	_apply_btn.custom_minimum_size = Vector2(100, 40)
	var done := ShellUI.button(head, "Done", _done, nova)
	done.custom_minimum_size = Vector2(100, 40)

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(_scroll)
	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 6)
	_scroll.add_child(_content)
	_status = ShellUI.label(box, "", 14, ShellUI.MUTED)

	_import_dialog = FileDialog.new()
	_import_dialog.file_mode = FileDialog.FILE_MODE_OPEN_ANY
	_import_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_import_dialog.use_native_dialog = false
	_import_dialog.title = "Import a plug-in (.zip, .rez, .ndat or a folder)"
	_import_dialog.size = Vector2i(900, 560)
	_import_dialog.file_selected.connect(_import)
	_import_dialog.dir_selected.connect(_import)
	_import_dialog.theme = ShellUI.theme()
	add_child(_import_dialog)

	_render()


# ------------------------------------------------------------------ state helpers

func _installed() -> Array:
	return JSON.parse_string(_pl.list())


func _state() -> Dictionary:
	return JSON.parse_string(_pl.state())


func _catalog() -> Dictionary:
	return JSON.parse_string(_pl.catalog_state())


func _set_tab(t: String) -> void:
	tab = t
	detail_id = ""
	_delete_confirm = ""
	_render()


func _clear() -> void:
	_icons.clear()
	for c in _content.get_children():
		_content.remove_child(c)
		c.queue_free()
	first_control = null


func _render() -> void:
	for t in tab_buttons:
		tab_buttons[t].set_pressed_no_signal(t == tab and detail_id == "")
	_clear()
	if detail_id != "":
		_render_detail()
	else:
		match tab:
			"Installed": _render_installed()
			"Browse": _render_browse()
			"Load order": _render_order()
	var st := _state()
	_apply_btn.disabled = not st.needsReload
	if st.needsReload:
		_status.text = "Plug-in changes pending - they apply when you press Apply, leave this screen, or an install finishes."
	_focus_first()


func _focus_first() -> void:
	if first_control != null:
		ShellUI.focus(first_control)
	else:
		ShellUI.focus(tab_buttons[tab])


func _note(parent: Control, text: String, size := 14, color := ShellUI.MUTED) -> Label:
	var l := ShellUI.label(parent, text, size, color)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	return l


func _row() -> HBoxContainer:
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0.11, 0.12, 0.16)
	sb.set_corner_radius_all(4)
	sb.set_content_margin_all(10)
	panel.add_theme_stylebox_override("panel", sb)
	_content.add_child(panel)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 10)
	panel.add_child(h)
	return h


func _btn(parent: Control, text: String, cb: Callable, width := 0) -> Button:
	var b := ShellUI.button(parent, text, cb, _nova)
	b.alignment = HORIZONTAL_ALIGNMENT_CENTER
	if width > 0:
		b.custom_minimum_size.x = width
	if first_control == null:
		first_control = b
	return b


func _badge(parent: Control, text: String, color := Color(0.5, 0.6, 1.0)) -> void:
	var l := Label.new()
	l.text = "[" + text + "]"
	l.add_theme_font_size_override("font_size", 12)
	l.add_theme_color_override("font_color", color)
	parent.add_child(l)


func _icon(parent: Control, url: String) -> void:
	var tr := TextureRect.new()
	tr.custom_minimum_size = Vector2(44, 44)
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	parent.add_child(tr)
	if url != "":
		if not _icons.has(url):
			_icons[url] = []
		_icons[url].append(tr)
		_try_icon(url)


func _try_icon(url: String) -> void:
	var bytes: PackedByteArray = _pl.image(url)
	if bytes.is_empty():
		return
	var img := Image.new()
	var err := img.load_png_from_buffer(bytes)
	if err != OK:
		err = img.load_jpg_from_buffer(bytes)
	if err != OK:
		err = img.load_webp_from_buffer(bytes)
	var tex := ImageTexture.create_from_image(img) if err == OK else null
	for tr in _icons.get(url, []):
		if is_instance_valid(tr):
			tr.texture = tex
	_icons.erase(url)


# ------------------------------------------------------------------ Installed

func _render_installed() -> void:
	var st := _state()
	var list := _installed()
	var shown := 0
	var failures: Array = st.failures
	if not failures.is_empty():
		_note(_content, "Failed to load: %d file(s) were skipped when the game data last loaded." % failures.size(),
			14, Color(1.0, 0.6, 0.3))
		for f in failures:
			_note(_content, "  %s (in %s): %s" % [f.file, f.plugin, f.message], 12, Color(1.0, 0.6, 0.3))
	if list.is_empty():
		_note(_content, "No plug-ins installed.", 18, ShellUI.TEXT)
		_note(_content, "Browse the catalog to install one, or Import your own .rez, .ndat or .zip files.\nPlug-ins in your game's \"Nova Plug-ins\" folder and in " + st.installDir + " are found automatically.")
		_btn(_content, "Browse the catalog", _set_tab.bind("Browse"))
		return
	var catalog := _catalog()
	var by_id := {}
	for e in catalog.entries:
		by_id[e.id] = e
	for optional in [false, true]:
		var group := list.filter(func(p): return p.optional == optional)
		if group.is_empty():
			continue
		if optional:
			ShellUI.label(_content, "Optional extras inside plug-ins", 16, ShellUI.TEXT)
		for p in group:
			_installed_row(p, by_id.get(p.id))
			shown += 1
	_note(_content, "Searched: " + ", ".join(PackedStringArray(st.dirs)), 12)


func _installed_row(p: Dictionary, entry) -> void:
	var h := _row()
	_icon(h, str(entry.icon) if entry != null else "")
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(col)
	var name := Label.new()
	name.text = str(entry.name) if entry != null else str(p.name)
	name.add_theme_font_size_override("font_size", 17)
	name.clip_text = true
	col.add_child(name)
	var meta := HBoxContainer.new()
	meta.add_theme_constant_override("separation", 6)
	col.add_child(meta)
	var kind := Label.new()
	kind.text = p.kindLabel
	kind.add_theme_font_size_override("font_size", 12)
	kind.add_theme_color_override("font_color", ShellUI.MUTED)
	meta.add_child(kind)
	if p.total_conversion:
		_badge(meta, "Total conversion", Color(0.6, 0.55, 1.0))
	if entry == null:
		_badge(meta, "Imported" if p.deletable else "Game folder", Color(0.6, 0.7, 0.8))
	if entry != null and entry.status == "update":
		_badge(meta, "Update", Color(1.0, 0.65, 0.25))
	if p.optional:
		_badge(meta, "Optional", Color(0.6, 0.7, 0.8))
	if entry != null:
		_btn(h, "Details", _open_detail.bind(str(entry.id)), 90)
		if entry.status == "update" and entry.downloadable:
			_btn(h, "Update", func(): _start_install(str(entry.id)), 90)
	if p.deletable:
		var confirm: bool = _delete_confirm == p.id
		_btn(h, "Really delete?" if confirm else "Delete", _delete.bind(str(p.id)), 130 if confirm else 90)
	if p.canToggle:
		_btn(h, "Enabled" if p.enabled else "Off", _toggle.bind(str(p.id), not p.enabled), 90)
	else:
		var auto := Label.new()
		auto.text = "Loads automatically" if p.enabled else "Not loaded"
		auto.add_theme_font_size_override("font_size", 12)
		auto.add_theme_color_override("font_color", ShellUI.MUTED)
		h.add_child(auto)


func _toggle(id: String, on: bool) -> void:
	_pl.set_enabled(id, on)
	_render()


func _delete(id: String) -> void:
	if _delete_confirm != id:
		_delete_confirm = id
		_render()
		return
	_delete_confirm = ""
	if _pl.delete(id):
		await _apply("Removing plug-in...")
	_render()


# ------------------------------------------------------------------ Browse

func _render_browse() -> void:
	var cat := _catalog()
	var bar := HBoxContainer.new()
	bar.add_theme_constant_override("separation", 8)
	_content.add_child(bar)
	var search := LineEdit.new()
	search.placeholder_text = "Search plug-ins"
	search.text = query
	search.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	search.custom_minimum_size = Vector2(0, 38)
	search.text_submitted.connect(func(t): query = t; _render())
	bar.add_child(search)
	if first_control == null:
		first_control = search
	var fb := _btn(bar, "Filter: " + filter, _cycle_filter, 230)
	_btn(bar, "Refresh", func(): _pl.catalog_refresh(); _render(), 100)
	if cat.updates.size() > 0:
		_btn(bar, "Update all (%d)" % cat.updates.size(), _update_all, 160)
	var src := "Online catalog"
	if cat.offline:
		src = "Offline - showing a saved catalog (%s). Downloads need a connection." % cat.error
	elif cat.source == "cache":
		src = "Saved catalog (refreshing)..." if cat.refreshing else "Saved catalog"
	elif cat.source == "bundled":
		src = "Built-in catalog (refreshing)..." if cat.refreshing else "Built-in catalog"
	_note(_content, src, 12, Color(1.0, 0.7, 0.4) if cat.offline else ShellUI.MUTED)
	var rows := _filtered(cat.entries)
	if rows.is_empty():
		_note(_content, "Nothing matches.", 16, ShellUI.TEXT)
	for e in rows:
		_entry_row(e)


func _cycle_filter() -> void:
	filter = FILTERS[(FILTERS.find(filter) + 1) % FILTERS.size()]
	_render()


func _filtered(entries: Array) -> Array:
	var out: Array = []
	var q := query.strip_edges().to_lower()
	for e in entries:
		var tags: Array = e.tags.map(func(t): return str(t).to_lower())
		var ok := true
		match filter:
			"Total conversions": ok = e.tc
			"Ships": ok = tags.has("ships") or tags.has("ship")
			"Story": ok = tags.has("story")
			"Graphics": ok = tags.has("graphics")
			"Gameplay": ok = tags.has("gameplay")
			"Installed": ok = e.status != "available"
			"Updates": ok = e.status == "update"
		if ok and q != "":
			var hay: String = (str(e.name) + " " + str(e.author) + " " + str(e.summary) + " " + " ".join(PackedStringArray(tags))).to_lower()
			ok = hay.contains(q)
		if ok:
			out.append(e)
	if filter == "Recent":
		out.sort_custom(func(a, b): return [str(a.recency), str(b.name)] > [str(b.recency), str(a.name)])
	else:
		out.sort_custom(func(a, b): return [int(a.popularity), str(b.name)] > [int(b.popularity), str(a.name)])
	return out


func _entry_row(e: Dictionary) -> void:
	var h := _row()
	_icon(h, str(e.icon))
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	h.add_child(col)
	var name := Label.new()
	name.text = "%s  v%s  by %s" % [e.name, e.version, e.author]
	name.add_theme_font_size_override("font_size", 16)
	name.clip_text = true
	col.add_child(name)
	_note(col, str(e.summary), 13)
	var meta := HBoxContainer.new()
	meta.add_theme_constant_override("separation", 6)
	col.add_child(meta)
	if e.tc:
		_badge(meta, "Total conversion", Color(0.6, 0.55, 1.0))
	if str(e.size) != "":
		_badge(meta, str(e.size), Color(0.6, 0.7, 0.8))
	_btn(h, "Details", _open_detail.bind(str(e.id)), 90)
	_action_button(h, e)


## Install / Update / Installed / progress for one catalog entry.
func _action_button(parent: Control, e: Dictionary) -> void:
	var t: Dictionary = e.transfer
	if not t.is_empty():
		if t.working:
			var pct := "" if float(t.progress) < 0.0 else " %d%%" % int(float(t.progress) * 100.0)
			_btn(parent, "Cancel" + pct, func(): _pl.cancel_install(str(e.id)); _render(), 130)
		else:
			_btn(parent, "Failed - dismiss", func(): _pl.dismiss_failure(str(e.id)); _render(), 150)
			_note(_content, "  " + str(t.error), 12, Color(1.0, 0.55, 0.45))
		return
	match e.status:
		"installed":
			var b := _btn(parent, "Installed", func(): pass, 100)
			b.disabled = true
		"update":
			_btn(parent, "Update", func(): _start_install(str(e.id)), 100).disabled = not e.downloadable
		_:
			_btn(parent, "Install", func(): _start_install(str(e.id)), 100).disabled = not e.downloadable


func _start_install(id: String) -> void:
	if not _pl.install(id):
		var cat := _catalog()
		for e in cat.entries:
			if e.id == id and e.transfer.is_empty():
				_status.text = "Can't download right now (offline or no direct HTTPS link)."
	_render()


func _update_all() -> void:
	for id in _catalog().updates:
		_pl.install(str(id))
	_render()


# ------------------------------------------------------------------ Detail

func _open_detail(id: String) -> void:
	detail_id = id
	_render()


func _render_detail() -> void:
	var cat := _catalog()
	var e = null
	for x in cat.entries:
		if x.id == detail_id:
			e = x
	_btn(_content, "< Back", func(): detail_id = ""; _render(), 120)
	if e == null:
		_note(_content, "This plug-in is not in the catalog.", 16, ShellUI.TEXT)
		return
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	_content.add_child(head)
	_icon(head, str(e.icon))
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(col)
	var n := Label.new()
	n.text = str(e.name)
	n.add_theme_font_size_override("font_size", 24)
	col.add_child(n)
	_note(col, "by %s  -  version %s%s" % [e.author, e.version,
		("  (installed: %s)" % e.installedVersion) if e.installedVersion != "" and e.status == "update" else ""], 14)
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 8)
	_content.add_child(actions)
	_action_button(actions, e)
	if e.status != "available":
		_btn(actions, "Delete", func(): _delete_entry(str(e.id)), 100)
	_note(_content, str(e.description) if str(e.description) != "" else str(e.summary), 15, ShellUI.TEXT)
	var facts := []
	if not e.tags.is_empty():
		facts.append("Tags: " + ", ".join(PackedStringArray(e.tags)))
	if str(e.size) != "":
		facts.append("Download size: " + str(e.size))
	facts.append("Downloaded from: " + str(e.downloadHost))
	if not e.dependencies.is_empty():
		facts.append("Needs: " + ", ".join(PackedStringArray(e.dependencies)))
	if str(e.homepage) != "":
		facts.append("Homepage: " + str(e.homepage))
	if str(e.license) != "":
		facts.append("License: " + str(e.license))
	for f in facts:
		_note(_content, f, 13)


func _delete_entry(id: String) -> void:
	if _pl.delete(id):
		await _apply("Removing plug-in...")
	_render()


# ------------------------------------------------------------------ Load order

func _render_order() -> void:
	var manual: bool = _pl.manual_order()
	var list := _installed()
	_note(_content, "You choose the order. When two plug-ins change the same thing, the one lower in this list wins." if manual else
		"This is the original game's order: every plug-in loads, sorted by file name, and when two change the same thing the later one wins. A total conversion replaces the stock scenario while it is switched on.", 14)
	var mb := _btn(_content, "Manual plug-in order: " + ("On" if manual else "Off"), _toggle_manual)
	mb.alignment = HORIZONTAL_ALIGNMENT_LEFT
	if manual:
		_note(_content, "Lets you reorder plug-ins and choose which ones load. This is an enhancement, not how the original worked.", 12)
	if list.is_empty():
		_note(_content, "No plug-ins installed.", 16, ShellUI.TEXT)
	for p in list:
		var h := _row()
		var idx := Label.new()
		idx.text = str(int(p.index) + 1)
		idx.custom_minimum_size.x = 30
		h.add_child(idx)
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		h.add_child(col)
		var nm := Label.new()
		nm.text = str(p.name)
		nm.add_theme_font_size_override("font_size", 16)
		col.add_child(nm)
		_note(col, "Loads" if p.enabled else "Off", 12, Color(0.45, 0.85, 0.5) if p.enabled else ShellUI.MUTED)
		if p.total_conversion:
			_badge(h, "Total conversion", Color(0.6, 0.55, 1.0))
		if manual:
			_btn(h, "Up", _move.bind(str(p.id), -1), 70).disabled = int(p.index) == 0
			_btn(h, "Down", _move.bind(str(p.id), 1), 70).disabled = int(p.index) == list.size() - 1


func _toggle_manual() -> void:
	_pl.set_manual_order(not _pl.manual_order())
	_render()


func _move(id: String, offset: int) -> void:
	_pl.move(id, offset)
	_render()


# ------------------------------------------------------------------ import / apply / close

func _open_import() -> void:
	var home := OS.get_environment("HOME")
	if home == "":
		home = OS.get_environment("USERPROFILE")
	if home != "":
		_import_dialog.current_dir = home
	_import_dialog.popup_centered()


func _import(path: String) -> void:
	var r: Dictionary = JSON.parse_string(_pl.import_from(path))
	if r.ok:
		_status.text = "Imported \"%s\"." % r.id
		await _apply("Loading plug-in...")
	else:
		_status.text = "That didn't work: " + str(r.error)
	_render()


## Re-run the data load with the current plug-in set, behind a loading overlay (Apple shows its
## loading view while GameDataController.reload runs). The merge is synchronous, so give the
## overlay two frames to draw first.
func _apply(message := "Loading plug-ins...") -> bool:
	if _busy_apply:
		return false
	_busy_apply = true
	var base: String = _state().base
	var ok := false
	var shell := _find_shell()
	if shell != null and base != "":
		# Worker-thread load with the Shell's loading screen (real progress).
		ok = await shell.load_data_async(base, message)
	else:
		_show_overlay(message)
		await get_tree().process_frame
		await get_tree().process_frame
		ok = _pl.reload()
		_hide_overlay()
	_pl.rescan()
	_busy_apply = false
	_status.text = ("Loaded %d resources." % _pl.loaded_resource_count()) if ok else "Couldn't reload the game data."
	return ok


## The Shell (has `load_data_async`) among this node's ancestors, if any.
func _find_shell() -> Node:
	var n := get_parent()
	while n != null:
		if n.has_method("load_data_async"):
			return n
		n = n.get_parent()
	return null


func _show_overlay(message: String) -> void:
	_hide_overlay()
	_overlay = Control.new()
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.8)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.add_child(dim)
	var c := CenterContainer.new()
	c.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.add_child(c)
	var l := Label.new()
	l.text = message
	l.add_theme_font_size_override("font_size", 26)
	c.add_child(l)
	_root.add_child(_overlay)


func _hide_overlay() -> void:
	if _overlay != null and is_instance_valid(_overlay):
		_overlay.queue_free()
	_overlay = null


func _done() -> void:
	if _pl.needs_reload():
		await _apply()
	closed.emit()


func _process(delta: float) -> void:
	if _root == null:
		return
	_poll += delta
	if _poll < 0.4:
		return
	_poll = 0.0
	for url in _icons.keys():
		_try_icon(url)
	if _busy_apply:
		return
	var cat := _catalog()
	var working := false
	for e in cat.entries:
		if not e.transfer.is_empty():
			working = true
	if cat.busy or cat.refreshing or working:
		# Refresh progress / catalog arrival, unless the player is typing.
		if tab == "Browse" and not (get_viewport().gui_get_focus_owner() is LineEdit):
			var pos := _scroll.scroll_vertical
			var f := get_viewport().gui_get_focus_owner()
			var focus_text: String = f.text if f is Button else ""
			_render()
			_scroll.scroll_vertical = pos
			_restore_focus(focus_text)
		elif detail_id != "":
			_render()
	elif cat.needsReload and not cat.busy and _installed_changed_by_store(cat):
		await _apply("Installing...")
		_render()


## Only an install / update that just finished triggers the automatic reload (toggles and
## moves wait for Apply / Done).
var _was_working := false
func _installed_changed_by_store(cat: Dictionary) -> bool:
	var was := _was_working
	_was_working = cat.busy
	return was and not cat.busy


func _restore_focus(text: String) -> void:
	if text == "":
		return
	for b in _content.find_children("*", "Button", true, false):
		if b.text == text:
			ShellUI.focus(b)
			return


func _unhandled_input(event: InputEvent) -> void:
	if _busy_apply or (_import_dialog != null and _import_dialog.visible):
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		if detail_id != "":
			detail_id = ""
			_render()
		else:
			_done()
