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

var _tools: Node
var _kind := "ships"
var _search: LineEdit
var _list: VBoxContainer
var _count: Label
var _expanded := -1
var _timer := 0.0
var _dirty := true


func setup(tools: Node, kind: String) -> void:
	_tools = tools
	_kind = kind
	add_theme_constant_override("separation", 5)
	var bar := DevUI.hbox(self, 6)
	_search = DevUI.search_field(bar, "search %s…" % kind, func(_t): _refresh())
	_count = DevUI.label(bar, "", 11, DevUI.DIM)
	var sc := DevUI.scroll(self)
	_list = DevUI.vbox(sc, 5)
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
	_count.text = "%d%s" % [rows.size(), "+" if rows.size() >= SHOWN else ""]
	DevUI.clear_children(_list)
	if rows.is_empty():
		DevUI.label(_list, "No %s match." % _kind.trim_suffix("s"), 11, DevUI.DIM)
		return
	for r in rows:
		_add_row(r)


## Owned counts / legal records change as actions run; re-list when a visible badge changed.
func _refresh_badges() -> void:
	if _expanded == -1:
		return
	_refresh()


func _add_row(r: Dictionary) -> void:
	var id := int(r.id)
	var open := id == _expanded
	var card := DevUI.card(_list, open)
	var head := DevUI.button(card, "", func(): pass, Color.WHITE)
	head.flat = true
	head.alignment = HORIZONTAL_ALIGNMENT_LEFT
	var badge := ""
	if _kind == "outfits" and int(r.get("owned", 0)) > 0:
		badge = "   ×%d" % int(r.owned)
	elif _kind == "govts" and int(r.get("record", 0)) != 0:
		badge = "   (%s)" % ("friendly" if int(r.record) > 0 else "hostile")
	head.text = "%s   #%d%s" % [r.name, id, badge]
	head.add_theme_color_override("font_color", DevUI.GREEN if open else Color.WHITE)
	head.pressed.connect(func():
		_expanded = -1 if _expanded == id else id
		_refresh())
	DevUI.label(card, str(r.stats), 10, Color(1, 1, 1, 0.6))
	if not open:
		return
	var detail := str(r.get("detail", ""))
	if detail != "":
		DevUI.wrap_label(card, detail.replace("\r", "\n").left(600), 10, Color(1, 1, 1, 0.7))
	var chips := DevUI.flow(card, 6)
	match _kind:
		"ships":
			DevUI.button(chips, "Fly this", func(): _tools.run("ship %d" % id), DevUI.GREEN)
			DevUI.button(chips, "Hostile", func(): _tools.run("spawn hostile %d" % id), DevUI.RED)
			DevUI.button(chips, "Escort", func(): _tools.run("spawn escort %d" % id), DevUI.GREEN)
			DevUI.button(chips, "Neutral", func(): _tools.run("spawn neutral %d" % id), DevUI.GREEN)
		"outfits":
			DevUI.button(chips, "Grant ×1", func(): _tools.run("outfit add %d" % id), DevUI.GREEN)
			DevUI.button(chips, "Grant ×5", func(): _tools.run("outfit add %d 5" % id), DevUI.GREEN)
			DevUI.button(chips, "Remove", func(): _tools.run("outfit remove %d" % id), DevUI.RED)
		_:
			DevUI.button(chips, "Hostile here", func(): _tools.run("relation -30000"), DevUI.RED)
			DevUI.button(chips, "Neutral here", func(): _tools.run("relation 0"), DevUI.GREEN)
			DevUI.button(chips, "Friendly here", func(): _tools.run("relation 30000"), DevUI.GREEN)
