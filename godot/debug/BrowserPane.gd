# NOVA Swift — Ships / Outfits / Govts tabs (port of DevBrowsers.swift).
#
# One searchable list per kind; expanding a row shows the data set's description and action chips
# that SUBMIT CONSOLE COMMANDS (never mutate state directly), so every browser action is logged
# and reproducible:  Ships: Fly this (`ship <id>`) · Hostile / Escort / Neutral (`spawn ...`);
# Outfits: Grant ×1 / ×5 / Remove (`outfit add|remove`); Govts: Hostile / Neutral / Friendly here
# (`relation ...`), with the worst legal record the pilot holds in that government's systems.
extends VBoxContainer

const DevUI = preload("res://debug/DevUI.gd")
const SHOWN := 200
const KIND_GLYPH := {"ships": "airplane", "outfits": "shippingbox.fill", "govts": "flag.fill"}

var _tools: Node
var _kind := "ships"
var _search: LineEdit
var _list: VBoxContainer
var _scroll: ScrollContainer
var _count: PanelContainer
var _expanded := -1
var _timer := 0.0


func setup(tools: Node, kind: String) -> void:
	_tools = tools
	_kind = kind
	add_theme_constant_override("separation", 0)
	var pad := DevUI.margin(self, 12, 10, 12, 10)
	pad.size_flags_vertical = Control.SIZE_EXPAND_FILL
	var col := DevUI.vbox(pad, 8)
	var bar := DevUI.hbox(col, 8)
	_search = DevUI.search_field(bar, "Search %s…" % kind, func(_t): _refresh())
	_count = DevUI.pill(bar, "0", DevUI.GREEN, str(KIND_GLYPH[kind]))
	_scroll = DevUI.scroll(col)
	_list = DevUI.vbox(_scroll, 6)
	_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL


func on_show() -> void:
	_refresh()


func focus_first() -> void:
	if _search != null:
		_search.grab_focus()


func tick(delta: float) -> void:
	_timer += delta
	if _timer >= 1.0:
		_timer = 0.0
		if _kind != "ships":
			_refresh_badges()


func _fetch() -> Array:
	var d: Object = _tools.dbg
	var raw: String
	match _kind:
		"ships": raw = d.ships_json(_search.text, SHOWN)
		"outfits": raw = d.outfits_json(_search.text, SHOWN)
		_: raw = d.govts_json(_search.text, SHOWN)
	var rows = JSON.parse_string(raw)
	return rows if rows is Array else []


func _refresh() -> void:
	var rows := _fetch()
	_count.get_meta("label").text = "%d%s" % [rows.size(), "+" if rows.size() >= SHOWN else ""]
	var keep := _scroll.scroll_vertical
	DevUI.clear_children(_list)
	if rows.is_empty():
		DevUI.spacer(_list, 0, 24)
		DevUI.empty_state(_list, "search", "No %s match" % _kind.trim_suffix("s"), "Try a name or an id.")
		return
	for r in rows:
		_add_row(r)
	_scroll.set_deferred("scroll_vertical", keep)


## Owned counts / legal records change as actions run; re-list when a visible badge changed.
func _refresh_badges() -> void:
	if _expanded == -1:
		return
	_refresh()


func _add_row(r: Dictionary) -> void:
	var id := int(r.id)
	var open := id == _expanded
	var card := DevUI.card(_list, open)
	card.add_theme_constant_override("separation", 4)
	var head := DevUI.hbox(card, 8)
	var btn := Button.new()
	btn.focus_mode = Control.FOCUS_ALL
	btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.clip_text = true
	DevUI.style_chip(btn, DevUI.GREEN if open else Color.WHITE, 7, Vector2(6, 4))
	for st in ["normal", "hover", "pressed", "hover_pressed"]:
		btn.add_theme_stylebox_override(st, StyleBoxEmpty.new())
	btn.add_theme_color_override("font_color", DevUI.GREEN if open else Color.WHITE)
	btn.add_theme_font_size_override("font_size", 13)
	DevUI.set_icon(btn, "chevron.down" if open else "chevron.right", 11, DevUI.DIM, Color.WHITE, DevUI.DIM)
	btn.text = str(r.name)
	btn.pressed.connect(func():
		_expanded = -1 if _expanded == id else id
		_refresh())
	head.add_child(btn)
	if _kind == "outfits" and int(r.get("owned", 0)) > 0:
		DevUI.pill(head, "×%d owned" % int(r.owned), DevUI.GREEN, "checkmark.circle.fill")
	elif _kind == "govts" and int(r.get("record", 0)) != 0:
		var friendly := int(r.record) > 0
		DevUI.pill(head, "friendly" if friendly else "hostile", DevUI.GREEN if friendly else DevUI.RED)
	DevUI.pill(head, "#%d" % id, DevUI.DIM)
	var st := DevUI.label(card, str(r.stats), 10, Color(1, 1, 1, 0.5), true)
	st.clip_text = true
	st.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	if not open:
		return
	DevUI.rule(card)
	var detail := str(r.get("detail", ""))
	if detail != "":
		DevUI.wrap_label(card, detail.replace("\r", "\n").left(600), 11, Color(1, 1, 1, 0.7))
	var chips := DevUI.flow(card, 6)
	match _kind:
		"ships":
			DevUI.button(chips, "Fly this", func(): _tools.run("ship %d" % id), DevUI.GREEN, false, "airplane")
			DevUI.button(chips, "Hostile", func(): _tools.run("spawn hostile %d" % id), DevUI.RED, false, "scope")
			DevUI.button(chips, "Escort", func(): _tools.run("spawn escort %d" % id), DevUI.BLUE, false, "person.2.fill")
			DevUI.button(chips, "Neutral", func(): _tools.run("spawn neutral %d" % id), DevUI.DIM, false, "circle")
		"outfits":
			DevUI.button(chips, "Grant ×1", func(): _tools.run("outfit add %d" % id), DevUI.GREEN, false, "plus")
			DevUI.button(chips, "Grant ×5", func(): _tools.run("outfit add %d 5" % id), DevUI.GREEN, false, "plus")
			DevUI.button(chips, "Remove", func(): _tools.run("outfit remove %d" % id), DevUI.RED, false, "minus")
		_:
			DevUI.button(chips, "Hostile here", func(): _tools.run("relation -30000"), DevUI.RED, false, "exclamationmark.triangle.fill")
			DevUI.button(chips, "Neutral here", func(): _tools.run("relation 0"), DevUI.DIM, false, "circle")
			DevUI.button(chips, "Friendly here", func(): _tools.run("relation 30000"), DevUI.GREEN, false, "checkmark.circle.fill")
