# NOVA Swift — Console tab (port of DevConsoleView's ConsolePane + ConsoleLogStore).
#
# The scrollback is the Swift ring buffer (NovaDebug.log_*): the engine's `Logging` output
# ("[AI] ..."), Godot's own log ("[Godot] ..."), and the console's echoes / results / errors,
# with Apple's filters -- five severity chips (Debug/Info/Notice/Warning/Critical), category
# chips built from what has been seen, free-text search -- plus Copy and Clear. Tagged ships and
# stellars (`«ship:id:name»`) render as clickable chips that run `select ship|spob <id>`.
# The command line has shell-style up/down history, Tab completion, a usage hint for the command
# being typed, command-name suggestions, and quick chips so a pad can drive it without typing
# (a Steam Deck's on-screen keyboard works for the rest).
extends VBoxContainer

const DevUI = preload("res://debug/DevUI.gd")

const LEVELS := ["Debug", "Info", "Notice", "Warning", "Critical"]
const LEVEL_COLORS := [Color(1, 1, 1, 0.42), Color(1, 1, 1, 0.78), Color(0.45, 0.7, 1.0),
	Color(1.0, 0.6, 0.3), Color(0.95, 0.35, 0.3)]
const QUICK := ["help", "history", "clear", "god", "fuel", "heal", "refuel", "fps", "ai", "uidebug"]
const POLL := 0.25
const MAX_ROWS := 600

var _tools: Node
var _log: RichTextLabel
var _input: LineEdit
var _search: LineEdit
var _count: Label
var _suggest: HFlowContainer
var _hint: Label
var _cats: HFlowContainer
var _level_buttons := []
var _muted_levels := {}        # level index -> true
var _muted_cats := {}          # category -> true
var _known_cats: Array = []
var _last_id := 0
var _prev_total := 0
var _rows_shown := 0
var _timer := 0.0
var _hist := -1
var _link_re := RegEx.new()


func setup(tools: Node) -> void:
	_tools = tools
	add_theme_constant_override("separation", 5)
	_link_re.compile("«(ship|spob):(-?\\d+):([^»]*)»")

	var bar := DevUI.hbox(self, 6)
	_search = DevUI.search_field(bar, "filter log…", func(_t): _rebuild())
	_search.custom_minimum_size = Vector2(160, 0)
	_count = DevUI.label(bar, "0 lines", 11, DevUI.DIM)
	for i in LEVELS.size():
		var b := DevUI.button(bar, LEVELS[i], _toggle_level.bind(i), LEVEL_COLORS[i], true)
		b.set_pressed_no_signal(true)
		_level_buttons.append(b)
	DevUI.button(bar, "Reset", _reset_filters, DevUI.GREEN)
	DevUI.button(bar, "Copy", _copy, DevUI.GREEN)
	DevUI.button(bar, "Clear", func(): _tools.run("clear"); _rebuild(), DevUI.RED)

	_cats = DevUI.flow(self, 4)

	_log = RichTextLabel.new()
	_log.bbcode_enabled = true
	_log.scroll_following = true
	_log.selection_enabled = true
	_log.focus_mode = Control.FOCUS_ALL
	_log.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_log.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_log.fit_content = false
	_log.add_theme_stylebox_override("normal", DevUI.panel_style(Color(0, 0, 0, 0.35), Color(1, 1, 1, 0.06), 6))
	_log.meta_clicked.connect(_on_meta)
	add_child(_log)

	_suggest = DevUI.flow(self, 5)
	_hint = DevUI.label(self, "", 11, DevUI.DIM)

	var row := DevUI.hbox(self, 6)
	DevUI.label(row, ">", 14, DevUI.GREEN)
	_input = LineEdit.new()
	_input.placeholder_text = "command…  (help)"
	_input.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_input.caret_blink = true
	_input.text_submitted.connect(_submit)
	_input.text_changed.connect(func(_t): _hist = -1; _update_suggestions())
	_input.gui_input.connect(_on_input_key)
	row.add_child(_input)
	DevUI.button(row, "Run", func(): _submit(_input.text), DevUI.GREEN)
	_update_suggestions()


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
	var draft := _input.text if _input != null else ""
	var matches = JSON.parse_string(_tools.dbg.console_matches(draft))
	if matches is Array and not matches.is_empty():
		for m in matches:
			var b := DevUI.button(_suggest, "%s  %s" % [m.name, m.summary.left(36)], func():
				_input.text = str(m.name) + " "
				_input.caret_column = _input.text.length()
				_input.grab_focus()
				_update_suggestions(), DevUI.GREEN)
			b.add_theme_font_size_override("font_size", 11)
		return
	var hint: String = _tools.dbg.console_hint(draft)
	if hint != "":
		_hint.text = hint
	elif draft.strip_edges() == "":
		for q in QUICK:
			DevUI.button(_suggest, q, func(): _submit(q), DevUI.GREEN)


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


func _rebuild() -> void:
	_log.clear()
	_last_id = 0
	_prev_total = 0
	_rows_shown = 0
	_poll()


func _poll() -> void:
	if _tools == null or _tools.dbg == null:
		return
	var res = JSON.parse_string(_tools.dbg.log_query(_last_id, _filter_json(), MAX_ROWS))
	if not (res is Dictionary):
		return
	var total := int(res.total)
	if total < _prev_total:          # the buffer was cleared elsewhere
		_log.clear()
		_last_id = 0
		_rows_shown = 0
		res = JSON.parse_string(_tools.dbg.log_query(0, _filter_json(), MAX_ROWS))
	_prev_total = total
	_sync_categories(res.categories)
	var entries: Array = res.entries
	if _rows_shown + entries.size() > MAX_ROWS * 2:
		_rebuild()
		return
	for e in entries:
		_append_row(e)
		_last_id = maxi(_last_id, int(e.id))
	_rows_shown += entries.size()
	if entries.is_empty() and _last_id == 0:
		_last_id = 0
	elif int(res.lastId) > _last_id and entries.is_empty():
		pass
	_count.text = ("%d of %d lines" % [_rows_shown, total]) if _filters_active() else ("%d lines" % total)


func _filters_active() -> bool:
	return not _muted_levels.is_empty() or not _muted_cats.is_empty() or _search.text.strip_edges() != ""


func _sync_categories(cats: Array) -> void:
	if cats == _known_cats:
		return
	_known_cats = cats.duplicate()
	DevUI.clear_children(_cats)
	for c in cats:
		var b := DevUI.button(_cats, "[%s]" % c, _toggle_cat.bind(c), Color.WHITE, true)
		b.add_theme_font_size_override("font_size", 10)
		b.set_pressed_no_signal(not _muted_cats.has(c))


func _append_row(e: Dictionary) -> void:
	var color := Color.WHITE
	var bold := false
	match str(e.kind):
		"log":
			var lv := int(e.get("level", 2))
			color = LEVEL_COLORS[clampi(lv, 0, 4)]
			bold = lv == 4
		"echo":
			color = DevUI.GREEN
		"error":
			color = DevUI.RED
		_:
			color = Color.WHITE
	var text := DevUI.bb_escape(str(e.text))
	text = _link_re.sub(text, "[url=$1:$2][color=#7fe0c8][b]$3[/b][/color][/url]", true)
	var line := "[color=#%s]" % color.to_html(false)
	if str(e.kind) == "log":
		line += "[color=#707880]%s[/color]  " % e.t
	line += ("[b]%s[/b]" if bold else "%s") % text
	line += "[/color]\n"
	_log.append_text(line)


func _on_meta(meta: Variant) -> void:
	var parts := str(meta).split(":")
	if parts.size() == 2:
		_tools.run("select %s %s" % [parts[0], parts[1]])
