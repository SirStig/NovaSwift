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

var _tools: Node
var _search: LineEdit
var _list: VBoxContainer
var _status: Label
var _held_label: Label
var _filter := "all"
var _filter_buttons := {}
var _expanded := -1
var _timer := 0.0
var _sig := ""
var _was_ready := false


func setup(tools: Node) -> void:
	_tools = tools
	add_theme_constant_override("separation", 5)
	var bar := DevUI.hbox(self, 6)
	for f in [["all", "All"], ["held", "Held"], ["orphans", "Orphans"]]:
		var key: String = f[0]
		var b := DevUI.button(bar, f[1], func(on: bool):
			if on:
				_filter = key
				for k in _filter_buttons:
					_filter_buttons[k].set_pressed_no_signal(k == key)
				_refresh(true)
			else:
				_filter_buttons[key].set_pressed_no_signal(true), DevUI.DIM, true)
		b.set_pressed_no_signal(key == "all")
		_filter_buttons[key] = b
	_search = DevUI.search_field(bar, "search bits or mission names…", func(_t): _refresh(true))
	_held_label = DevUI.label(bar, "", 11, DevUI.DIM)
	_status = DevUI.label(self, "", 11, DevUI.DIM)
	var sc := DevUI.scroll(self)
	_list = DevUI.vbox(sc, 5)
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
	_held_label.text = "%d held" % int(res.held)
	if not force and sig == _sig:
		return
	_sig = sig
	_status.text = ("Indexing control bits…" if not bool(res.ready) else "") \
		+ ("%d bit(s)%s" % [int(res.total), " (showing first %d — refine the search)" % SHOWN if int(res.total) > SHOWN else ""])
	DevUI.clear_children(_list)
	for row in res.bits:
		_add_row(row)


func _add_row(row: Dictionary) -> void:
	var bit := int(row.bit)
	var is_set := bool(row.set)
	var card := DevUI.card(_list, bit == _expanded)
	var head := DevUI.hbox(card, 10)
	var open := DevUI.button(head, "", func(): pass, Color.WHITE)
	open.flat = true
	open.alignment = HORIZONTAL_ALIGNMENT_LEFT
	open.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var writers := int(row.writers)
	var tests := int(row.tests)
	var parts := []
	if writers > 0:
		parts.append("%d writer%s" % [writers, "" if writers == 1 else "s"])
	if tests > 0:
		parts.append("%d test%s" % [tests, "" if tests == 1 else "s"])
	open.text = "%s   bit %d   %s" % ["[SET]" if is_set else "[ - ]", bit, " · ".join(parts) if not parts.is_empty() else "no references"]
	open.add_theme_color_override("font_color", DevUI.GREEN if is_set else Color(1, 1, 1, 0.7))
	open.pressed.connect(func():
		_expanded = -1 if _expanded == bit else bit
		_refresh(true))
	if bit != _expanded:
		return
	var ex = JSON.parse_string(_tools.dbg.ncb_explain(bit))
	var any := false
	for group in [["set", "SET BY"], ["clear", "CLEARED BY"], ["toggle", "TOGGLED BY"], ["test", "TESTED BY"]]:
		var rows := []
		for r in ex.refs:
			if r.role == group[0]:
				rows.append(r)
		if rows.is_empty():
			continue
		any = true
		DevUI.label(card, group[1], 10, DevUI.GREEN)
		for r in rows:
			var text := "%s #%d %s · %s" % [r.kind, int(r.id), r.name, r.field]
			if r.role == "test":
				text += " (needs clear)" if bool(r.negated) else " (needs set)"
			DevUI.wrap_label(card, text, 10, Color(1, 1, 1, 0.72))
	if not any:
		DevUI.wrap_label(card, "Referenced nowhere in this data set — nothing sets, clears or reads it. Usually a plug-in bit, or a stale bit left in the save.", 10)
	var chips := DevUI.hbox(card, 6)
	DevUI.button(chips, "Set", func(): _tools.run("bit set %d" % bit); _refresh(true), DevUI.GREEN)
	DevUI.button(chips, "Clear", func(): _tools.run("bit clear %d" % bit); _refresh(true), DevUI.RED)
	DevUI.button(chips, "Toggle", func(): _tools.run("bit toggle %d" % bit); _refresh(true), DevUI.GREEN)
