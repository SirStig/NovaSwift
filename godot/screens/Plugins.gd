# NOVA Swift — Plug-ins screen: browse the online catalog (search, filter chips, cards, details,
# install / update), the installed list (enable / delete / import) and the load order. The Godot
# counterpart of the Apple app's Launcher/PluginsView.swift + Plugins/{InstalledPluginsView,
# PluginCard,PluginDetailView,RemoteImage}.swift, drawn with the NovaSwift UI kit (ui/novaswift/):
# a full-window dark gradient, a top bar (title, Import, refresh, Done), a Browse / Installed /
# Load order segmented picker, a search field, filter chips and a grid of rounded plug-in cards.
# All rules live in the shared Swift core behind the bridge's `NovaPlugins` class (Plugins.swift):
# discovery, the original-vs-manual load order, the merge, the catalog, download + checksum +
# unpack. This file is presentation only.
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
const T = preload("res://ui/novaswift/NovaTheme.gd")
const NC = preload("res://ui/novaswift/NovaControls.gd")
const Alert = preload("res://ui/novaswift/NovaAlert.gd")

signal closed

const TABS := ["Browse", "Installed", "Load order"]
const FILTERS := ["Popular", "Recent", "Total conversions", "Ships", "Story", "Graphics",
	"Gameplay", "Installed", "Updates"]
const BUNDLED_CATALOG := "res://data/PluginCatalog.json"
const KIND_SYMBOL := {"totalConversion": "sparkles", "patch": "hammer", "gameplay": "slider.horizontal.3",
	"graphics": "photo", "unknown": "puzzlepiece.extension"}

var tab := "Browse"
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
var _title: Label
var _back_btn: Button
var _tabbar: Control
var _poll := 0.0
var _icons := {}               # url -> Array[TextureRect] waiting for bytes
var _import_dialog: FileDialog
var _delete_confirm := ""      # plug-in id awaiting a second press of Delete


func setup(nova: Object, start_tab := "Browse") -> void:
	_nova = nova
	layer = 72
	_pl = ClassDB.instantiate("NovaPlugins")
	_pl.attach(nova)
	_pl.set_bundled_catalog(ProjectSettings.globalize_path(BUNDLED_CATALOG))
	_pl.rescan()
	_pl.catalog_offline()
	_pl.catalog_refresh()
	tab = start_tab if TABS.has(start_tab) else "Browse"
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.theme = T.theme()
	add_child(_root)
	# LinearGradient(white 0.06 -> 0.11, top to bottom)
	var g := Gradient.new()
	g.set_color(0, T.PLUGINS_BG_TOP)
	g.set_color(1, T.PLUGINS_BG_BOTTOM)
	var gt := GradientTexture2D.new()
	gt.gradient = g
	gt.fill_from = Vector2(0.5, 0)
	gt.fill_to = Vector2(0.5, 1)
	gt.width = 8
	gt.height = 64
	var bg := TextureRect.new()
	bg.texture = gt
	bg.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	bg.stretch_mode = TextureRect.STRETCH_SCALE
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP   # nothing below the screen is clickable
	_root.add_child(bg)
	var box := VBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT)
	box.add_theme_constant_override("separation", 0)
	_root.add_child(box)

	# Top bar: [Back] Title ........ [progress] Import  refresh  Done
	var top := MarginContainer.new()
	for s in ["left", "right"]:
		top.add_theme_constant_override("margin_" + s, 20)
	top.add_theme_constant_override("margin_top", 12)
	top.add_theme_constant_override("margin_bottom", 12)
	box.add_child(top)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	top.add_child(head)
	_back_btn = NC.button("Back", "bordered", func(): detail_id = ""; _render(), "chevron.left")
	_back_btn.visible = false
	head.add_child(_back_btn)
	_title = NC.label(head, "Plugins", "body", "bold", T.WHITE)
	_title.add_theme_font_override("font", T.system("bold"))
	_title.add_theme_font_size_override("font_size", 22)
	_title.clip_text = true
	NC.hspacer(head)
	var imp := NC.button("Import", "bordered", _open_import, "square.and.arrow.down")
	head.add_child(imp)
	var refresh := NC.bordered_icon_button("arrow.clockwise", func(): _pl.catalog_refresh(); _render(), "Refresh catalog")
	head.add_child(refresh)
	_apply_btn = NC.button("Apply", "bordered", func(): await _apply(); _render())
	head.add_child(_apply_btn)
	var done := NC.button("Done", "primary", _done)
	head.add_child(done)

	# Tab bar: Browse | Installed | Load order (segmented, max 460 wide)
	var tb := MarginContainer.new()
	for s in ["left", "right"]:
		tb.add_theme_constant_override("margin_" + s, 20)
	tb.add_theme_constant_override("margin_bottom", 8)
	box.add_child(tb)
	_tabbar = tb
	var seg_row := HBoxContainer.new()
	tb.add_child(seg_row)
	var seg := NC.segmented(null, ["Browse", "Installed", "Load order"], TABS.find(tab), func(i: int): _set_tab(TABS[i]))
	seg.size_flags_horizontal = Control.SIZE_FILL
	seg.custom_minimum_size = Vector2(460, 0)
	seg_row.add_child(seg)
	var seg_buttons: Array = seg.get_meta("buttons")
	for i in TABS.size():
		tab_buttons[TABS[i]] = seg_buttons[i]

	_scroll = ScrollContainer.new()
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_scroll.follow_focus = true
	box.add_child(_scroll)
	var pad := MarginContainer.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for s in ["left", "right"]:
		pad.add_theme_constant_override("margin_" + s, 20)
	pad.add_theme_constant_override("margin_bottom", 24)
	_scroll.add_child(pad)
	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 14)
	pad.add_child(_content)
	var sw := MarginContainer.new()
	sw.add_theme_constant_override("margin_left", 20)
	box.add_child(sw)
	_status = NC.label(sw, "", "caption", "regular", T.SECONDARY, true)

	_import_dialog = FileDialog.new()
	_import_dialog.file_mode = FileDialog.FILE_MODE_OPEN_ANY
	_import_dialog.access = FileDialog.ACCESS_FILESYSTEM
	_import_dialog.use_native_dialog = false
	_import_dialog.title = "Import a plug-in (.zip, .rez, .ndat or a folder)"
	_import_dialog.size = Vector2i(900, 560)
	_import_dialog.file_selected.connect(_import)
	_import_dialog.dir_selected.connect(_import)
	_import_dialog.theme = T.theme()
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
	var in_detail := detail_id != ""
	for t in tab_buttons:
		tab_buttons[t].set_pressed_no_signal(t == tab)
	_tabbar.visible = not in_detail
	_back_btn.visible = in_detail
	_title.text = "Plugins"
	_clear()
	if in_detail:
		_render_detail()
	else:
		match tab:
			"Installed": _render_installed()
			"Browse": _render_browse()
			"Load order": _render_order()
	var st := _state()
	_apply_btn.visible = bool(st.needsReload)
	if st.needsReload:
		_status.text = "Plug-in changes pending - they apply when you press Apply, leave this screen, or an install finishes."
	_focus_first()


func _focus_first() -> void:
	if first_control != null:
		ShellUI.focus(first_control)
	else:
		ShellUI.focus(tab_buttons[tab])


func _note(parent: Control, text: String, size := 14, color: Variant = T.SECONDARY) -> Label:
	var l := NC.label(parent, text, "body", "regular", color, true)
	l.add_theme_font_override("font", T.system())
	l.add_theme_font_size_override("font_size", size)
	return l


func _row() -> HBoxContainer:
	var panel := NC.card(_content, 14, 12)
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 12)
	panel.add_child(h)
	return h


func _btn(parent: Control, text: String, cb: Callable, width := 0, kind := "bordered", icon := "") -> Button:
	var b := NC.button(text, kind, cb, icon)
	if width > 0:
		b.custom_minimum_size.x = width
	parent.add_child(b)
	if first_control == null:
		first_control = b
	return b


func _badge(parent: Control, text: String, color := T.SECONDARY, icon := "") -> void:
	NC.badge(parent, text, color, icon)


## PluginIconTile: the catalog icon, else a tinted tile with the plug-in kind's symbol.
func _icon(parent: Control, url: String, size := 44, tint := T.SECONDARY, symbol := "puzzlepiece.extension") -> Control:
	var tile := PanelContainer.new()
	tile.custom_minimum_size = Vector2(size, size)
	tile.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	tile.add_theme_stylebox_override("panel", T.box(Color(tint.r, tint.g, tint.b, 0.6), int(size * 0.22), Color(0, 0, 0, 0), 0))
	tile.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
	var sym := TextureRect.new()
	sym.texture = T.icon(symbol, int(size * 0.5), Color(1, 1, 1, 0.92))
	sym.stretch_mode = TextureRect.STRETCH_KEEP_CENTERED
	sym.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(sym)
	var tr := TextureRect.new()
	tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	tr.set_anchors_preset(Control.PRESET_FULL_RECT)
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	tile.add_child(tr)
	parent.add_child(tile)
	if url != "":
		if not _icons.has(url):
			_icons[url] = []
		_icons[url].append(tr)
		_try_icon(url)
	return tile


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


static func _entry_tint(e: Dictionary) -> Color:
	if e.get("tc", false):
		return T.INDIGO
	var tags: Array = (e.get("tags", []) as Array).map(func(t): return str(t).to_lower())
	if tags.has("patch") or tags.has("graphics"):
		return T.TEAL
	if tags.has("gameplay"):
		return T.ORANGE
	return Color(0.56, 0.56, 0.58)


static func _entry_symbol(e: Dictionary) -> String:
	if e.get("tc", false):
		return KIND_SYMBOL["totalConversion"]
	var tags: Array = (e.get("tags", []) as Array).map(func(t): return str(t).to_lower())
	if tags.has("patch") or tags.has("graphics"):
		return KIND_SYMBOL["patch"]
	if tags.has("gameplay"):
		return KIND_SYMBOL["gameplay"]
	return KIND_SYMBOL["unknown"]


# ------------------------------------------------------------------ Installed

func _empty_state(parent: Control, title: String, body: String) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.alignment = BoxContainer.ALIGNMENT_CENTER
	v.add_theme_constant_override("separation", 8)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var c := CenterContainer.new()
	v.add_child(c)
	NC.icon_rect(c, "puzzlepiece.extension", 34, T.SECONDARY)
	var t := NC.label(v, title, "body", "semibold")
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var b := _note(v, body, 13)
	b.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_top", 40)
	m.add_theme_constant_override("margin_bottom", 40)
	m.add_child(v)
	parent.add_child(m)
	return v


func _render_installed() -> void:
	var st := _state()
	var list := _installed()
	var failures: Array = st.failures
	if not failures.is_empty():
		var fc := NC.card(_content, 10, 10)
		fc.add_theme_stylebox_override("panel", T.box(Color(T.ORANGE.r, T.ORANGE.g, T.ORANGE.b, 0.1), 10, Color(0, 0, 0, 0), 0, Vector2(10, 10)))
		var fv := VBoxContainer.new()
		fv.add_theme_constant_override("separation", 6)
		fc.add_child(fv)
		var fh := HBoxContainer.new()
		fh.add_theme_constant_override("separation", 6)
		fv.add_child(fh)
		NC.icon_rect(fh, "exclamationmark.triangle.fill", 16, T.ORANGE)
		NC.label(fh, "Failed to load", "body", "semibold", T.ORANGE)
		_note(fv, "These files were skipped when the game data last loaded. The rest of the plug-ins are unaffected.", 12)
		for f in failures:
			_note(fv, "%s  (in %s)\n%s" % [f.file, f.plugin, f.message], 12, T.ORANGE)
	if list.is_empty():
		var es := _empty_state(_content, "No plug-ins installed", "Browse the catalog to install one, or import your own .rez, .ndat or .zip files.\nPlug-ins in your game's \"Nova Plug-ins\" folder and in " + st.installDir + " are found automatically.")
		var hb := HBoxContainer.new()
		hb.alignment = BoxContainer.ALIGNMENT_CENTER
		es.add_child(hb)
		_btn(hb, "Import files...", _open_import)
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
			var oh := NC.label(_content, "Optional extras inside plug-ins", "body", "semibold")
			oh.add_theme_font_override("font", T.system("semibold"))
		for p in group:
			_installed_row(p, by_id.get(p.id))
	_note(_content, "Searched: " + ", ".join(PackedStringArray(st.dirs)), 12, T.TERTIARY)


func _installed_row(p: Dictionary, entry) -> void:
	var h := _row()
	var tint: Color = _entry_tint(entry) if entry != null else Color(0.5, 0.5, 0.52)
	var sym: String = _entry_symbol(entry) if entry != null else KIND_SYMBOL.get(str(p.get("kind", "unknown")), "puzzlepiece.extension")
	_icon(h, str(entry.icon) if entry != null else "", 44, tint, sym)
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 3)
	h.add_child(col)
	var name := NC.label(col, str(entry.name) if entry != null else str(p.name), "body", "semibold")
	name.add_theme_font_override("font", T.system("semibold"))
	name.add_theme_font_size_override("font_size", 16)
	name.clip_text = true
	var meta := HBoxContainer.new()
	meta.add_theme_constant_override("separation", 6)
	col.add_child(meta)
	var kind := NC.label(meta, str(p.kindLabel), "caption", "regular", T.SECONDARY)
	kind.add_theme_font_override("font", T.system())
	if p.total_conversion:
		_badge(meta, "Total conversion", T.INDIGO)
	if entry != null and entry.status == "update":
		_badge(meta, "Update", T.ORANGE, "arrow.clockwise")
	if entry == null:
		_badge(meta, "Imported" if p.deletable else "Built in")
	if p.optional:
		_badge(meta, "Optional")
	if entry != null:
		var info := NC.icon_button("info.circle", _open_detail.bind(str(entry.id)), T.SECONDARY, 30, 16)
		info.tooltip_text = "Details"
		h.add_child(info)
		if first_control == null:
			first_control = info
		if entry.status == "update" and entry.downloadable:
			_btn(h, "Update", func(): _start_install(str(entry.id)), 0)
	if p.deletable:
		var confirm: bool = _delete_confirm == p.id
		if confirm:
			_btn(h, "Really delete?", _delete.bind(str(p.id)), 0, "destructive")
		else:
			var d := NC.icon_button("trash", _delete.bind(str(p.id)), T.RED, 30, 16)
			d.tooltip_text = "Delete"
			h.add_child(d)
			if first_control == null:
				first_control = d
	if p.canToggle:
		var tg := NC.toggle(h, "", bool(p.enabled), func(on: bool): _toggle(str(p.id), on))
		tg.text = ""
		tg.custom_minimum_size = Vector2(20, 24)
		tg.size_flags_horizontal = Control.SIZE_SHRINK_END
		tg.tooltip_text = "Enabled"
		if first_control == null:
			first_control = tg
	else:
		var auto := NC.label(h, "Loads automatically" if p.enabled else "Not loaded", "caption", "regular", T.SECONDARY)
		auto.add_theme_font_override("font", T.system())
		auto.add_theme_font_size_override("font_size", 12)


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

func _grid_columns() -> int:
	var w := _root.get_viewport_rect().size.x - 40.0
	return maxi(1, int((w + 16.0) / (290.0 + 16.0)))


func _render_browse() -> void:
	var cat := _catalog()
	var search := NC.search_field(_content, "Search plug-ins, authors, tags", query,
		func(t: String): query = t,
		func(t: String): query = t; _render())
	# also re-filter as you pause typing is not wanted (focus would jump); Enter applies
	if first_control == null:
		first_control = search
	var chips := HFlowContainer.new()
	chips.add_theme_constant_override("h_separation", 8)
	chips.add_theme_constant_override("v_separation", 8)
	_content.add_child(chips)
	for f in FILTERS:
		var count: int = cat.updates.size() if f == "Updates" else 0
		NC.chip(chips, ("%s (%d)" % [f, count]) if count > 0 else f, filter == f, func(): filter = f; _render())
	var src := ""
	if cat.offline:
		src = "You're offline. Showing the last catalog downloaded; downloads and updates are off until you reconnect. (%s)" % cat.error
	elif cat.source == "cache" and cat.refreshing:
		src = "Saved catalog (refreshing)..."
	elif cat.source == "bundled" and cat.refreshing:
		src = "Built-in catalog (refreshing)..."
	if src != "":
		var nl := HBoxContainer.new()
		nl.add_theme_constant_override("separation", 6)
		_content.add_child(nl)
		if cat.offline:
			NC.icon_rect(nl, "wifi.slash", 14, T.SECONDARY)
		_note(nl, src, 12)
	if cat.updates.size() > 0 and filter != "Updates" and not cat.offline:
		var ub := HBoxContainer.new()
		_content.add_child(ub)
		_btn(ub, "Update all (%d)" % cat.updates.size(), _update_all, 0, "bordered", "arrow.clockwise")
	var rows := _filtered(cat.entries)
	if rows.is_empty():
		_empty_state(_content, "Everything is up to date" if filter == "Updates" else "Nothing here",
			"Try a different filter." if query == "" else "No plug-ins match “%s”." % query)
	else:
		var grid := GridContainer.new()
		grid.columns = _grid_columns()
		grid.add_theme_constant_override("h_separation", 16)
		grid.add_theme_constant_override("v_separation", 16)
		grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		_content.add_child(grid)
		for e in rows:
			_card(grid, e)
	var foot := _note(_content, "Plug-in files download straight from each author's own site. NovaSwift doesn't host or change them, and you need your own copy of EV Nova to play any of them.", 12, T.TERTIARY)
	foot.custom_minimum_size = Vector2(400, 0)


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


## PluginCard: icon tile, name + "by author", three summary lines, then badges and the state
## control. Pressing the card opens its details.
func _card(parent: Control, e: Dictionary) -> void:
	var b := NC.card_button(parent, T.CARD_BG, T.CARD_BORDER, 18, 16)
	b.custom_minimum_size = Vector2(0, 190)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.pressed.connect(_open_detail.bind(str(e.id)))
	b.tooltip_text = "%s by %s" % [e.name, e.author]
	if first_control == null:
		first_control = b
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 12)
	(b.get_meta("content") as Control).add_child(v)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 12)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(top)
	_icon(top, str(e.icon), 56, _entry_tint(e), _entry_symbol(e))
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 2)
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	top.add_child(col)
	var name := NC.label(col, str(e.name), "body", "semibold")
	name.add_theme_font_override("font", T.system("semibold"))
	name.add_theme_font_size_override("font_size", 16)
	name.clip_text = true
	name.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var by := NC.label(col, "by " + str(e.author), "caption", "regular", T.SECONDARY)
	by.add_theme_font_override("font", T.system())
	by.clip_text = true
	by.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	var sum := _note(v, str(e.summary), 13)
	sum.max_lines_visible = 3
	sum.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	sum.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var fill := Control.new()
	fill.size_flags_vertical = Control.SIZE_EXPAND_FILL
	fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(fill)
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 6)
	foot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(foot)
	if e.tc:
		_badge(foot, "Total conversion", T.INDIGO, "sparkles")
	var tags: Array = e.tags
	for i in mini(tags.size(), 1 if e.tc else 2):
		_badge(foot, str(tags[i]))
	NC.hspacer(foot)
	_action_button(foot, e, true)


## Install / Update / Installed / progress for one catalog entry. `compact` = the card's state
## label look (Apple PluginStateLabel); otherwise full bordered buttons.
func _action_button(parent: Control, e: Dictionary, compact := false) -> void:
	var t: Dictionary = e.transfer
	if not t.is_empty():
		if t.working:
			if compact:
				NC.progress(parent, float(t.progress) if float(t.progress) >= 0.0 else 0.5, 60)
			else:
				var pct := "" if float(t.progress) < 0.0 else " %d%%" % int(float(t.progress) * 100.0)
				NC.progress(parent, float(t.progress) if float(t.progress) >= 0.0 else 0.5, 120)
				_btn(parent, "Cancel" + pct, func(): _pl.cancel_install(str(e.id)); _render(), 0)
		else:
			_btn(parent, "Failed - dismiss", func(): _pl.dismiss_failure(str(e.id)); _render(), 0, "bordered", "exclamationmark.triangle.fill")
			_note(_content, "  " + str(t.error), 12, T.ORANGE)
		return
	var label := ""
	var icon := ""
	var color := T.AMBER
	var enabled := true
	match e.status:
		"installed":
			label = "Installed"
			icon = "checkmark.circle.fill"
			color = T.GREEN
			enabled = false
		"update":
			label = "Update"
			icon = "arrow.clockwise"
			color = T.ORANGE
			enabled = bool(e.downloadable)
		_:
			label = "Get"
			icon = "arrow.down.circle.fill"
			enabled = bool(e.downloadable)
	if compact:
		# a flat label-looking button: icon + text in the state colour (Get is the accent colour)
		var b := NC.button(label, "plain", func(): _start_install(str(e.id)), icon)
		b.icon = T.icon(icon, 16, color)
		T.style_text(b, "button", "semibold", color, 14)
		for st in ["font_hover_color", "font_pressed_color", "font_focus_color", "font_disabled_color"]:
			b.add_theme_color_override(st, color)
		b.disabled = not enabled
		if label == "Installed":
			T.style_text(b, "caption", "semibold", color, 12)
		parent.add_child(b)
	else:
		if label == "Installed":
			var ib := _btn(parent, "Installed", func(): pass, 0, "bordered", "checkmark.circle.fill")
			ib.disabled = true
		else:
			var kind := "primary"
			var txt := label
			var b2 := _btn(parent, txt, func(): _start_install(str(e.id)), 0, kind, icon)
			b2.disabled = not enabled
			if label == "Get" and str(e.size) != "":
				b2.text = "Get  ·  " + str(e.size)


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


func _section_title(text: String) -> void:
	var l := NC.label(_content, text, "body", "semibold")
	l.add_theme_font_override("font", T.system("semibold"))
	l.add_theme_font_size_override("font_size", 18)


func _render_detail() -> void:
	var cat := _catalog()
	var e = null
	for x in cat.entries:
		if x.id == detail_id:
			e = x
	if e == null:
		_note(_content, "This plug-in is not in the catalog.", 16, T.WHITE)
		return
	_title.text = str(e.name)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 16)
	_content.add_child(head)
	_icon(head, str(e.icon), 96, _entry_tint(e), _entry_symbol(e))
	var col := VBoxContainer.new()
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.add_theme_constant_override("separation", 6)
	head.add_child(col)
	var n := NC.label(col, str(e.name), "body", "bold")
	n.add_theme_font_override("font", T.system("bold"))
	n.add_theme_font_size_override("font_size", 30)
	_note(col, "by %s" % e.author, 18)
	var badges := HBoxContainer.new()
	badges.add_theme_constant_override("separation", 6)
	col.add_child(badges)
	_badge(badges, "v" + str(e.version))
	if e.tc:
		_badge(badges, "Total conversion", T.INDIGO, "sparkles")
	if e.status == "update":
		_badge(badges, ("Update from v" + str(e.installedVersion)) if str(e.installedVersion) != "" else "Update available", T.ORANGE, "arrow.clockwise")
	elif e.status != "available":
		_badge(badges, "Installed", T.GREEN, "checkmark")
	var actions := HBoxContainer.new()
	actions.add_theme_constant_override("separation", 12)
	_content.add_child(actions)
	_action_button(actions, e)
	if e.status != "available":
		var del := _btn(actions, "Delete", func(): _confirm_delete_entry(e), 0, "destructive", "trash")
		del.icon = T.icon("trash", 16, T.RED)
	var long_text: String = str(e.description) if str(e.description) != "" else str(e.summary)
	_section_title("About")
	_note(_content, long_text, 15, T.WHITE)
	_section_title("Details")
	var facts := VBoxContainer.new()
	facts.add_theme_constant_override("separation", 8)
	_content.add_child(facts)
	_fact(facts, "Version", str(e.version))
	_fact(facts, "Author", str(e.author))
	if str(e.size) != "":
		_fact(facts, "Download size", str(e.size))
	_fact(facts, "Downloads from", str(e.downloadHost))
	if not e.tags.is_empty():
		_fact(facts, "Tags", ", ".join(PackedStringArray(e.tags)))
	if str(e.license) != "":
		_fact(facts, "License", str(e.license))
	if str(e.homepage) != "":
		_fact(facts, "Homepage", str(e.homepage))
	_section_title("Compatibility")
	_note(_content, "Needs your own copy of EV Nova's game data. NovaSwift doesn't include it.", 14)
	if e.tc:
		_note(_content, "A total conversion replaces the stock scenario. Only one can be played at a time.", 14)
	for dep in e.dependencies:
		_note(_content, "Needs " + str(dep), 14)


func _fact(parent: Control, label: String, value: String) -> void:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	parent.add_child(h)
	var l := _note(h, label, 14)
	l.custom_minimum_size = Vector2(130, 0)
	l.size_flags_horizontal = Control.SIZE_FILL
	var v := _note(h, value, 14, T.WHITE)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL


func _confirm_delete_entry(e: Dictionary) -> void:
	Alert.show(self, {"title": "Delete %s?" % e.name,
		"message": "The plug-in's files are removed from this device. You can install it again later.",
		"buttons": [{"title": "Cancel", "role": "cancel"},
			{"title": "Delete", "role": "destructive", "cb": func(): _delete_entry(str(e.id))}]})


func _delete_entry(id: String) -> void:
	if _pl.delete(id):
		await _apply("Removing plug-in...")
	_render()


# ------------------------------------------------------------------ Load order

func _render_order() -> void:
	var manual: bool = _pl.manual_order()
	var list := _installed()
	_note(_content, "You choose the order. When two plug-ins change the same thing, the one lower in this list wins. Changes apply next time you start a game." if manual else
		"This is the original game's order: every plug-in loads, sorted by file name, and when two change the same thing the later one wins. A total conversion replaces the stock scenario while it is switched on.", 14)
	var mb := NC.toggle(_content, "Manual plug-in order", manual, func(on: bool):
		_pl.set_manual_order(on)
		_render())
	if first_control == null:
		first_control = mb
	if manual:
		_note(_content, "Lets you reorder plug-ins and choose which ones load. This is an enhancement, not how the original worked.", 12)
	if list.is_empty():
		_note(_content, "No plug-ins installed.", 16, T.SECONDARY)
	for p in list:
		var h := _row()
		if not p.enabled:
			h.modulate.a = 0.6
		var idx := NC.label(h, str(int(p.index) + 1), "body", "semibold", T.SECONDARY)
		idx.custom_minimum_size.x = 28
		idx.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		var col := VBoxContainer.new()
		col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col.add_theme_constant_override("separation", 2)
		h.add_child(col)
		var nm := NC.label(col, str(p.name), "body", "semibold")
		nm.add_theme_font_override("font", T.system("semibold"))
		nm.add_theme_font_size_override("font_size", 16)
		_note(col, "Loads" if p.enabled else "Off", 12, T.GREEN if p.enabled else T.SECONDARY)
		if p.total_conversion:
			_badge(h, "Total conversion", T.INDIGO)
		if manual:
			var up := NC.icon_button("chevron.up", _move.bind(str(p.id), -1), T.WHITE, 30, 14)
			up.disabled = int(p.index) == 0
			h.add_child(up)
			var dn := NC.icon_button("chevron.down", _move.bind(str(p.id), 1), T.WHITE, 30, 14)
			dn.disabled = int(p.index) == list.size() - 1
			h.add_child(dn)
			if first_control == null and not up.disabled:
				first_control = up


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
