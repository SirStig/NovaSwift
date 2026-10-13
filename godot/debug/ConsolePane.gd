# NOVA Swift — Console tab (port of DevConsoleView's ConsolePane + ConsoleLogStore).
#
# The scrollback is the Swift ring buffer (NovaDebug.log_*): the engine's `Logging` output
# ("[AI] ..."), Godot's own log ("[Godot] ..."), and the console's echoes / results / errors,
# with Apple's filters -- five severity chips (Debug/Info/Notice/Warning/Critical, each with a
# coloured dot and a live count), category chips built from what has been seen, free-text
# search -- plus Copy and Clear. Rows are a timestamp column, a coloured level badge and the
# message, with an alternating tint; tagged ships and stellars (`«ship:id:name»`) render as
# clickable chips that run `select ship|spob <id>`; clicking a row selects it and offers Copy /
# Run again / Edit. The command line has shell-style up/down history, Tab completion, a usage
# hint for the command being typed, command-name suggestions, and quick chips so a pad can drive
# it without typing (a Steam Deck's on-screen keyboard works for the rest).
extends VBoxContainer

const DevUI = preload("res://debug/DevUI.gd")

const LEVELS := ["Debug", "Info", "Notice", "Warning", "Critical"]
const BADGES := ["DBG", "INF", "NTC", "WRN", "CRT"]
const LEVEL_COLORS := [Color(0.62, 0.66, 0.72), Color(0.88, 0.9, 0.94), Color(0.45, 0.72, 1.0),
	Color(1.0, 0.62, 0.3), Color(0.95, 0.38, 0.33)]
const QUICK := ["help", "history", "clear", "god", "fuel", "heal", "refuel", "fps", "ai", "uidebug"]
const POLL := 0.25
const MAX_ROWS := 400
const KEEP_ROWS := 700

var _tools: Node
var _scroll: ScrollContainer
var _rows: VBoxContainer
var _empty: Control
var _input: LineEdit
var _input_box: PanelContainer
var _search: LineEdit
var _count: Label
var _suggest: HFlowContainer
var _hint: Label
var _cats: HFlowContainer
var _sel_bar: PanelContainer
var _sel_label: Label
var _sel_run: Button
var _sel_text := ""
var _sel_kind := ""
var _sel_panel: PanelContainer
var _level_buttons := []
var _level_counts := [0, 0, 0, 0, 0]
var _cnt_last := 0
var _cnt_total := 0
var _muted_levels := {}        # level index -> true
var _muted_cats := {}          # category -> true
var _known_cats: Array = []
var _last_id := 0
var _prev_total := 0
var _rows_shown := 0
var _timer := 0.0
var _hist := -1
var _alt := false
var _link_re := RegEx.new()
var _st_even: StyleBoxFlat
var _st_odd: StyleBoxFlat
var _st_sel: StyleBoxFlat
var _badge_styles := {}


func setup(tools: Node) -> void:
	_tools = tools
	add_theme_constant_override("separation", 0)
	_link_re.compile("«(ship|spob):(-?\\d+):([^»]*)»")
	_st_even = _row_style(Color(1, 1, 1, 0.0))
	_st_odd = _row_style(Color(1, 1, 1, 0.032))
	_st_sel = _row_style(Color(DevUI.GREEN.r, DevUI.GREEN.g, DevUI.GREEN.b, 0.14))

	var pad := DevUI.margin(self, 12, 10, 12, 10)
	pad.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var col := DevUI.vbox(pad, 7)

	# --- toolbar: search + actions, then the severity / category filter chips
	var bar := DevUI.hbox(col, 6)
	_search = DevUI.search_field(bar, "Filter log…", func(_t): _rebuild())
	_search.get_meta("panel").custom_minimum_size = Vector2(150, 0)
	_count = DevUI.label(bar, "0 lines", 11, DevUI.FAINT, true)
	DevUI.icon_button(bar, "doc.on.doc", "Copy the visible log", _copy)
	DevUI.icon_button(bar, "line.3.horizontal.decrease", "Reset all filters", _reset_filters)
	DevUI.icon_button(bar, "trash", "Clear the log", func(): _tools.run("clear"); _rebuild(), DevUI.RED)

	var chips := DevUI.flow(col, 6)
	for i in LEVELS.size():
		var b := DevUI.button(chips, LEVELS[i], _toggle_level.bind(i), LEVEL_COLORS[i], true, "circle.fill")
		b.set_pressed_no_signal(true)
		b.add_theme_color_override("font_color", Color(LEVEL_COLORS[i], 0.5))
		b.add_theme_color_override("icon_normal_color", Color(LEVEL_COLORS[i], 0.4))
		_level_buttons.append(b)
	_cats = DevUI.flow(col, 5)

	# --- log
	var log_box := PanelContainer.new()
	log_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	log_box.clip_contents = true
	var lb := DevUI.panel_style(Color(0, 0, 0, 0.4), Color(1, 1, 1, 0.08), 10)
	lb.content_margin_left = 0
	lb.content_margin_right = 0
	lb.content_margin_top = 4
	lb.content_margin_bottom = 4
	log_box.add_theme_stylebox_override("panel", lb)
	col.add_child(log_box)
	_scroll = DevUI.scroll(log_box)
	_scroll.follow_focus = false
	_rows = DevUI.vbox(_scroll, 0)
	_rows.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_empty = DevUI.empty_state(log_box, "log", "Nothing logged yet", "Engine output, Godot's log and your commands appear here.")
	_empty.visible = false
	_empty.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_empty.size_flags_vertical = Control.SIZE_SHRINK_CENTER

	# --- selected-row action bar
	_sel_bar = PanelContainer.new()
	_sel_bar.add_theme_stylebox_override("panel", DevUI.panel_style(Color(DevUI.GREEN.r, DevUI.GREEN.g, DevUI.GREEN.b, 0.08), Color(DevUI.GREEN.r, DevUI.GREEN.g, DevUI.GREEN.b, 0.3), 9))
	_sel_bar.visible = false
	col.add_child(_sel_bar)
	var sb := DevUI.hbox(_sel_bar, 6)
	_sel_label = DevUI.label(sb, "", 11, DevUI.TEXT, true)
	_sel_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sel_label.clip_text = true
	DevUI.button(sb, "Copy", func(): DisplayServer.clipboard_set(_sel_text), DevUI.GREEN, false, "doc.on.doc")
	_sel_run = DevUI.button(sb, "Run again", func(): _tools.run(_sel_text); _deselect(), DevUI.GREEN, false, "arrow.clockwise")
	DevUI.button(sb, "Edit", _edit_selected, DevUI.BLUE, false, "pencil")
	DevUI.icon_button(sb, "xmark", "Dismiss", _deselect, DevUI.DIM, 12)

	# --- suggestions / usage hint / command line
	_suggest = DevUI.flow(col, 5)
	_hint = DevUI.label(col, "", 11, DevUI.AMBER, true)
	_input_box = PanelContainer.new()
	_input_box.add_theme_stylebox_override("panel", _input_style(false))
	col.add_child(_input_box)
	var row := DevUI.hbox(_input_box, 8)
	DevUI.icon_rect(row, "dev.prompt", 16, DevUI.GREEN)
	_input = LineEdit.new()
	_input.placeholder_text = "Type a command…  (try help)"
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.flat = true
	_input.caret_blink = true
	_input.add_theme_stylebox_override("normal", StyleBoxEmpty.new())
	_input.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	_input.add_theme_font_override("font", DevUI.mono())
	_input.add_theme_font_size_override("font_size", 14)
	_input.text_submitted.connect(_submit)
	_input.text_changed.connect(func(_t): _hist = -1; _update_suggestions())
	_input.gui_input.connect(_on_input_key)
	_input.focus_entered.connect(func(): _input_box.add_theme_stylebox_override("panel", _input_style(true)))
	_input.focus_exited.connect(func(): _input_box.add_theme_stylebox_override("panel", _input_style(false)))
	row.add_child(_input)
	DevUI.label(row, "↑↓ history · Tab complete", 10, DevUI.FAINT).size_flags_vertical = Control.SIZE_SHRINK_CENTER
	DevUI.primary_button(row, "Run", "paperplane.fill", func(): _submit(_input.text))
	_update_suggestions()


func _row_style(bg: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.content_margin_left = 10
	s.content_margin_right = 10
	s.content_margin_top = 3
	s.content_margin_bottom = 3
	return s


func _input_style(focused: bool) -> StyleBoxFlat:
	var s := DevUI.field_style(focused, 11)
	s.bg_color = Color(0, 0, 0, 0.5)
	s.content_margin_top = 5
	s.content_margin_bottom = 5
	s.content_margin_right = 6
	return s


func on_show() -> void:
	_rebuild()


func focus_first() -> void:
	if _input != null:
		_input.grab_focus()


func tick(delta: float) -> void:
	_timer += delta
	if _timer >= POLL:
		_timer = 0.0
		_poll()


func on_command(_line: String) -> void:
	_poll()
	_hist = -1


# --- command line -----------------------------------------------------------------

func _submit(text: String) -> void:
	if text.strip_edges() == "":
		return
	_input.text = ""
	_hist = -1
	_tools.run(text)
	_update_suggestions()
	_poll()
	_input.grab_focus.call_deferred()


func _on_input_key(event: InputEvent) -> void:
	if not (event is InputEventKey) or not event.pressed:
		return
	match event.keycode:
		KEY_UP:
			_walk_history(-1)
			_input.accept_event()
		KEY_DOWN:
			_walk_history(1)
			_input.accept_event()
		KEY_TAB:
			var c: String = _tools.dbg.console_complete(_input.text)
			if c != "":
				_input.text = c
				_input.caret_column = c.length()
				_update_suggestions()
			_input.accept_event()


## Shell-style recall; walking past the newest entry returns to an empty prompt.
func _walk_history(delta: int) -> void:
	var hist = JSON.parse_string(_tools.dbg.console_history())
	if not (hist is Array) or hist.is_empty():
		return
	var nxt: int
	if _hist == -1:
		if delta > 0:
			return
		nxt = hist.size() - 1
	else:
		nxt = _hist + delta
	if nxt < 0:
		nxt = 0
	elif nxt >= hist.size():
		_hist = -1
		_input.text = ""
		_update_suggestions()
		return
	_hist = nxt
	_input.text = str(hist[nxt])
	_input.caret_column = _input.text.length()
	_update_suggestions()


func _update_suggestions() -> void:
	DevUI.clear_children(_suggest)
	_hint.text = ""
	_hint.visible = false
	var draft := _input.text if _input != null else ""
	var matches = JSON.parse_string(_tools.dbg.console_matches(draft))
	if matches is Array and not matches.is_empty():
		for m in matches:
			var b := DevUI.button(_suggest, "%s  %s" % [m.name, m.summary.left(36)], func():
				_input.text = str(m.name) + " "
				_input.caret_column = _input.text.length()
				_input.grab_focus()
				_update_suggestions(), DevUI.GREEN)
			b.add_theme_font_override("font", DevUI.mono())
			b.add_theme_font_size_override("font_size", 11)
		return
	var hint: String = _tools.dbg.console_hint(draft)
	if hint != "":
		_hint.text = hint
		_hint.visible = true
	elif draft.strip_edges() == "":
		var q := DevUI.caps(_suggest, "Quick", DevUI.FAINT)
		q.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		for cmd in QUICK:
			var b := DevUI.button(_suggest, cmd, func(): _submit(cmd), DevUI.GREEN)
			b.add_theme_font_override("font", DevUI.mono())
			b.add_theme_font_size_override("font_size", 11)


# --- log view ---------------------------------------------------------------------

func _filter_json() -> String:
	var lv := []
	for i in _muted_levels:
		lv.append(int(i))
	return JSON.stringify({"mutedLevels": lv, "mutedCategories": _muted_cats.keys(), "search": _search.text})


func _toggle_level(on: bool, i: int) -> void:
	if on:
		_muted_levels.erase(i)
	else:
		_muted_levels[i] = true
	_rebuild()


func _toggle_cat(on: bool, c: String) -> void:
	if on:
		_muted_cats.erase(c)
	else:
		_muted_cats[c] = true
	_rebuild()


func _reset_filters() -> void:
	_muted_levels.clear()
	_muted_cats.clear()
	_search.text = ""
	for b in _level_buttons:
		b.set_pressed_no_signal(true)
	_known_cats = []
	_rebuild()


func _copy() -> void:
	DisplayServer.clipboard_set(_tools.dbg.log_text(_filter_json(), 1500))


func _clear_rows() -> void:
	_deselect()
	DevUI.clear_children(_rows)
	_alt = false


func _rebuild() -> void:
	_clear_rows()
	_last_id = 0
	_prev_total = 0
	_rows_shown = 0
	_poll(true)


func _update_counts() -> void:
	# Unfiltered tally so each severity chip shows how many lines it would reveal.
	var res = JSON.parse_string(_tools.dbg.log_query(_cnt_last, "{}", 4000))
	if not (res is Dictionary):
		return
	if int(res.total) < _cnt_total:
		_level_counts = [0, 0, 0, 0, 0]
		_cnt_last = 0
		res = JSON.parse_string(_tools.dbg.log_query(0, "{}", 4000))
		if not (res is Dictionary):
			return
	_cnt_total = int(res.total)
	for e in res.entries:
		_cnt_last = maxi(_cnt_last, int(e.id))
		if str(e.kind) == "log":
			var lv := clampi(int(e.get("level", 2)), 0, 4)
			_level_counts[lv] += 1
	for i in LEVELS.size():
		var n: int = _level_counts[i]
		_level_buttons[i].text = "%s  %s" % [LEVELS[i], DevUI.fmt_int(n)] if n > 0 else LEVELS[i]


func _poll(force_follow := false) -> void:
	if _tools == null or _tools.dbg == null:
		return
	var res = JSON.parse_string(_tools.dbg.log_query(_last_id, _filter_json(), MAX_ROWS))
	if not (res is Dictionary):
		return
	var total := int(res.total)
	if total < _prev_total:          # the buffer was cleared elsewhere
		_clear_rows()
		_last_id = 0
		_rows_shown = 0
		res = JSON.parse_string(_tools.dbg.log_query(0, _filter_json(), MAX_ROWS))
	_prev_total = total
	_sync_categories(res.categories)
	var entries: Array = res.entries
	if _rows_shown + entries.size() > MAX_ROWS * 2:
		_rebuild()
		return
	var bar := _scroll.get_v_scroll_bar()
	var at_bottom: bool = force_follow or _sel_panel == null and (bar.value + bar.page >= bar.max_value - 8.0)
	for e in entries:
		_append_row(e)
		_last_id = maxi(_last_id, int(e.id))
	_rows_shown += entries.size()
	if _rows.get_child_count() > KEEP_ROWS:
		for i in 100:
			var c := _rows.get_child(0)
			if c == _sel_panel:
				_deselect()
			_rows.remove_child(c)
			c.queue_free()
	_count.text = ("%d of %d lines" % [_rows_shown, total]) if _filters_active() else ("%d lines" % total)
	_empty.visible = _rows.get_child_count() == 0
	if _empty.visible:
		(_empty.get_child(1) as Label).text = "No lines match the filters" if _filters_active() else "Nothing logged yet"
	_update_counts()
	if at_bottom and not entries.is_empty():
		_to_bottom.call_deferred()


func _to_bottom() -> void:
	await get_tree().process_frame
	_scroll.scroll_vertical = int(_scroll.get_v_scroll_bar().max_value)


func _filters_active() -> bool:
	return not _muted_levels.is_empty() or not _muted_cats.is_empty() or _search.text.strip_edges() != ""


func _sync_categories(cats: Array) -> void:
	if cats == _known_cats:
		return
	_known_cats = cats.duplicate()
	DevUI.clear_children(_cats)
	if cats.is_empty():
		return
	var cap := DevUI.caps(_cats, "Categories", DevUI.FAINT)
	cap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	for c in cats:
		var b := DevUI.button(_cats, str(c), _toggle_cat.bind(c), DevUI.BLUE, true)
		b.add_theme_font_override("font", DevUI.mono())
		b.add_theme_font_size_override("font_size", 10)
		b.add_theme_stylebox_override("normal", DevUI._box(Color(1, 1, 1, 0.04), Color(1, 1, 1, 0.1), 20, Vector2(9, 2)))
		b.add_theme_stylebox_override("pressed", DevUI._box(Color(DevUI.BLUE, 0.2), Color(DevUI.BLUE, 0.6), 20, Vector2(9, 2)))
		b.add_theme_stylebox_override("hover_pressed", DevUI._box(Color(DevUI.BLUE, 0.28), Color(DevUI.BLUE, 0.7), 20, Vector2(9, 2)))
		b.add_theme_color_override("font_color", Color(1, 1, 1, 0.4))
		b.set_pressed_no_signal(not _muted_cats.has(c))


func _badge(text: String, color: Color) -> PanelContainer:
	var key := text + color.to_html()
	var p := PanelContainer.new()
	if not _badge_styles.has(key):
		_badge_styles[key] = DevUI._box(Color(color.r, color.g, color.b, 0.16), Color(color.r, color.g, color.b, 0.0), 5, Vector2(5, 1), 0)
	p.add_theme_stylebox_override("panel", _badge_styles[key])
	p.custom_minimum_size = Vector2(38, 0)
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var l := DevUI.label(p, text, 9, color, true)
	l.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	l.add_theme_font_override("font", DevUI.sans("bold"))
	return p


func _append_row(e: Dictionary) -> void:
	var color := Color.WHITE
	var badge := ""
	var kind := str(e.kind)
	var bold := false
	match kind:
		"log":
			var lv := clampi(int(e.get("level", 2)), 0, 4)
			color = LEVEL_COLORS[lv]
			badge = BADGES[lv]
			bold = lv == 4
		"echo":
			color = DevUI.GREEN
			badge = "RUN"
		"error":
			color = DevUI.RED
			badge = "ERR"
		_:
			color = Color(1, 1, 1, 0.85)
	var row := PanelContainer.new()
	_alt = not _alt
	row.add_theme_stylebox_override("panel", _st_odd if _alt else _st_even)
	row.mouse_filter = Control.MOUSE_FILTER_STOP
	row.set_meta("alt", _alt)
	var h := DevUI.hbox(row, 8)
	var ts := DevUI.label(h, str(e.t) if kind == "log" else "", 10, Color(1, 1, 1, 0.34), true)
	ts.custom_minimum_size = Vector2(62, 0)
	ts.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
	if badge != "":
		var b := _badge(badge, color)
		b.size_flags_vertical = Control.SIZE_SHRINK_BEGIN
		h.add_child(b)
	else:
		DevUI.spacer(h, 38, 0)
	var raw := str(e.text)
	var text := DevUI.bb_escape(raw)
	if _link_re.search(raw) != null:
		var rt := RichTextLabel.new()
		rt.bbcode_enabled = true
		rt.fit_content = true
		rt.scroll_active = false
		rt.selection_enabled = false
		rt.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		rt.custom_minimum_size = Vector2(40, 0)
		rt.add_theme_font_size_override("normal_font_size", 12)
		rt.add_theme_font_size_override("bold_font_size", 12)
		rt.add_theme_color_override("default_color", color)
		rt.meta_clicked.connect(_on_meta)
		rt.text = _link_re.sub(text, "[url=$1:$2][color=#7fe0c8][b]$3[/b][/color][/url]", true)
		h.add_child(rt)
	else:
		var m := DevUI.label(h, raw, 12, color, true)
		m.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
		m.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		m.custom_minimum_size = Vector2(40, 0)
		if bold:
			m.add_theme_font_override("font", DevUI.mono())
	row.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			_select(row, kind, raw))
	_rows.add_child(row)


# --- row selection ------------------------------------------------------------------

func _select(row: PanelContainer, kind: String, text: String) -> void:
	if _sel_panel == row:
		_deselect()
		return
	_deselect()
	_sel_panel = row
	row.add_theme_stylebox_override("panel", _st_sel)
	_sel_kind = kind
	_sel_text = text.trim_prefix("> ").trim_prefix(">").strip_edges() if kind == "echo" else text
	_sel_label.text = text
	_sel_run.visible = kind == "echo"
	_sel_bar.visible = true


func _deselect() -> void:
	if _sel_panel != null and is_instance_valid(_sel_panel):
		_sel_panel.add_theme_stylebox_override("panel", _st_odd if bool(_sel_panel.get_meta("alt", false)) else _st_even)
	_sel_panel = null
	if _sel_bar != null:
		_sel_bar.visible = false


func _edit_selected() -> void:
	_input.text = _sel_text
	_input.caret_column = _input.text.length()
	_input.grab_focus()
	_update_suggestions()
	_deselect()


func _on_meta(meta: Variant) -> void:
	var parts := str(meta).split(":")
	if parts.size() == 2:
		_tools.run("select %s %s" % [parts[0], parts[1]])
