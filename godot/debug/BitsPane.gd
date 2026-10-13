# NOVA Swift — Bits tab (port of DevBitBrowser.swift + NCBIndex.swift).
#
# Every control bit referenced anywhere in the loaded data (plus any the pilot holds), searchable
# by number or by the storyline name of the resource that touches it. Expanding a bit shows what
# SETS / CLEARS / TOGGLES it and what TESTS it (with polarity: "needs set" vs "needs clear" -- the
# whole point of a test), from the shared NCBIndex built off the main thread, plus Set / Clear /
# Toggle which submit `bit set|clear|toggle <n>`. Filters: All · Held · Orphans (held but
# referenced nowhere -- usually a plug-in bit or a stale one in the save).
extends VBoxContainer

const DevUI = preload("res://debug/DevUI.gd")
const SHOWN := 250
const ROLE_COLORS := {"set": Color(0.35, 0.95, 0.5), "clear": Color(0.95, 0.4, 0.35),
	"toggle": Color(1.0, 0.72, 0.3), "test": Color(0.45, 0.72, 1.0)}

var _tools: Node
var _search: LineEdit
var _list: VBoxContainer
var _scroll: ScrollContainer
var _status: Label
var _held_pill: PanelContainer
var _filter := "all"
var _filter_buttons := {}
var _expanded := -1
var _timer := 0.0
var _sig := ""
var _was_ready := false


func setup(tools: Node) -> void:
	_tools = tools
	add_theme_constant_override("separation", 0)
	var pad := DevUI.margin(self, 12, 10, 12, 10)
	pad.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var col := DevUI.vbox(pad, 7)
	_search = DevUI.search_field(col, "Search bits or mission names…", func(_t): _refresh(true))
	var bar := DevUI.hbox(col, 4)
	for f in [["all", "All", "list.bullet"], ["held", "Held", "checkmark.circle.fill"], ["orphans", "Orphans", "questionmark.circle"]]:
		var key: String = f[0]
		var b := DevUI.button(bar, f[1], func(on: bool):
			if on:
				_filter = key
				for k in _filter_buttons:
					_filter_buttons[k].set_pressed_no_signal(k == key)
				_refresh(true)
			else:
				_filter_buttons[key].set_pressed_no_signal(true), DevUI.GREEN, true, f[2])
		b.set_pressed_no_signal(key == "all")
		_filter_buttons[key] = b
	DevUI.spacer(bar, 0, 0, true)
	_held_pill = DevUI.pill(bar, "0 held", DevUI.GREEN)
	_status = DevUI.label(col, "", 11, DevUI.FAINT)
	_scroll = DevUI.scroll(col)
	_list = DevUI.vbox(_scroll, 6)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL


func on_show() -> void:
	_tools.dbg.ncb_build()
	_refresh(true)


func focus_first() -> void:
	if _search != null:
		_search.grab_focus()


func tick(delta: float) -> void:
	_timer += delta
	if _timer < 0.5:
		return
	_timer = 0.0
	var ready: bool = _tools.dbg.ncb_ready()
	if ready != _was_ready:
		_was_ready = ready
		_refresh(true)
	else:
		_refresh(false)


func _refresh(force: bool) -> void:
	var res = JSON.parse_string(_tools.dbg.ncb_bits(_filter, _search.text, SHOWN))
	if not (res is Dictionary):
		return
	var sig := "%s|%s|%d|%d|%s" % [_filter, _search.text, int(res.total), int(res.held), str(res.bits.slice(0, 40))]
	_held_pill.get_meta("label").text = "%d held" % int(res.held)
	if not force and sig == _sig:
		return
	_sig = sig
	_status.text = ("Indexing control bits…  " if not bool(res.ready) else "") \
		+ ("%d bit%s%s" % [int(res.total), "" if int(res.total) == 1 else "s", " · showing first %d, refine the search" % SHOWN if int(res.total) > SHOWN else ""])
	var keep := _scroll.scroll_vertical
	DevUI.clear_children(_list)
	if res.bits.is_empty():
		DevUI.spacer(_list, 0, 24)
		DevUI.empty_state(_list, "search", "No bits match", "Try a bit number or part of a mission name.")
		return
	for row in res.bits:
		_add_row(row)
	_scroll.set_deferred("scroll_vertical", keep)


func _add_row(row: Dictionary) -> void:
	var bit := int(row.bit)
	var is_set := bool(row.set)
	var open := bit == _expanded
	var card := DevUI.card(_list, open)
	card.add_theme_constant_override("separation", 6)
	var head := DevUI.hbox(card, 8)
	var btn := Button.new()
	btn.focus_mode = Control.FOCUS_ALL
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	DevUI.style_chip(btn, DevUI.GREEN if is_set else DevUI.DIM, 7, Vector2(6, 4))
	for st in ["normal", "hover", "pressed", "hover_pressed"]:
		btn.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	btn.add_theme_color_override("font_color", Color.WHITE)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	btn.add_theme_font_override("font", DevUI.mono())
	btn.add_theme_font_size_override("font_size", 12)
	DevUI.set_icon(btn, "chevron.down" if open else "chevron.right", 11, DevUI.DIM, Color.WHITE, DevUI.DIM)
	var writers := int(row.writers)
	var tests := int(row.tests)
	var parts := []
	if writers > 0:
		parts.append("%d writer%s" % [writers, "" if writers == 1 else "s"])
	if tests > 0:
		parts.append("%d test%s" % [tests, "" if tests == 1 else "s"])
	btn.text = "bit %d    %s" % [bit, " · ".join(parts) if not parts.is_empty() else "no references"]
	btn.pressed.connect(func():
		_expanded = -1 if _expanded == bit else bit
		_refresh(true))
	head.add_child(btn)
	DevUI.pill(head, "SET" if is_set else "clear", DevUI.GREEN if is_set else DevUI.DIM, "checkmark.circle.fill" if is_set else "circle", is_set)
	if not open:
		return
	var ex = JSON.parse_string(_tools.dbg.ncb_explain(bit))
	var any := false
	for group in [["set", "Set by"], ["clear", "Cleared by"], ["toggle", "Toggled by"], ["test", "Tested by"]]:
		var rows := []
		for r in ex.refs:
			if r.role == group[0]:
				rows.append(r)
		if rows.is_empty():
			continue
		any = true
		var gh := DevUI.hbox(card, 6)
		DevUI.dot(gh, ROLE_COLORS[group[0]], 6)
		DevUI.caps(gh, group[1], ROLE_COLORS[group[0]], 10)
		for r in rows:
			var text := "%s #%d  %s · %s" % [r.kind, int(r.id), r.name, r.field]
			var rr := DevUI.hbox(card, 6)
			DevUI.spacer(rr, 12, 0)
			DevUI.wrap_label(rr, text, 11, Color(1, 1, 1, 0.75))
			if r.role == "test":
				DevUI.pill(rr, "needs clear" if bool(r.negated) else "needs set", DevUI.AMBER if bool(r.negated) else DevUI.BLUE)
	if not any:
		DevUI.wrap_label(card, "Referenced nowhere in this data set — nothing sets, clears or reads it. Usually a plug-in bit, or a stale bit left in the save.", 11, DevUI.FAINT)
	var chips := DevUI.flow(card, 6)
	DevUI.button(chips, "Set", func(): _tools.run("bit set %d" % bit); _refresh(true), DevUI.GREEN, false, "checkmark")
	DevUI.button(chips, "Clear", func(): _tools.run("bit clear %d" % bit); _refresh(true), DevUI.RED, false, "xmark")
	DevUI.button(chips, "Toggle", func(): _tools.run("bit toggle %d" % bit); _refresh(true), DevUI.AMBER, false, "arrow.triangle.merge")
