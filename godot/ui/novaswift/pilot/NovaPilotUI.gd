# NOVA Swift — NovaSwift UI kit: pilot-screen components, the Godot form of the Apple app's Pilots/
# PilotListView.swift, PilotGroupDetailView.swift, PilotBackupsView.swift, PilotImportView.swift and
# the modern path of NewPilotView.swift. The Classic path keeps the original DLOG/DITL dialogs
# (screens/PilotMenu.gd draws those with ui/classic/); everything here is the NovaSwift look:
# a NovaDialog (Chrome.dialog) with dark rows of rounded cards, amber chevrons and icon buttons.
#
# These are data-in / callbacks-out builders (no engine calls), fed with the dictionaries the
# bridge returns (NovaWorld.pilot_groups / pilot_group_history / pilot_import_preview ...):
#
#   PilotUI.roster_row(list, group, {open, duplicate, delete, can_duplicate})   one pilot identity
#   PilotUI.roster_empty(parent)                                                "No pilots yet."
#   PilotUI.roster_scroll(parent, rows_count)                                   the scrolling list host
#   PilotUI.group_header(parent, scenario, on_rename)                           scenario + Rename
#   PilotUI.slot_row(parent, slot, {play, delete, multiple})                    one save slot
#   PilotUI.link_button(parent, "New Save Slot (1/3)", "plus.square.on.square", cb, amber)
#   PilotUI.backup_row(parent, row, slot_label, on_restore)                     one backup entry
#   PilotUI.kv_row(parent, "Credits", "12,000 cr")                              import summary line
#   PilotUI.relative_text / commas                                              formatting
#
# Loaded with preload() (no class_name), like Controls.gd.
extends RefCounted

const T = preload("res://ui/novaswift/NovaTheme.gd")
const NC = preload("res://ui/novaswift/NovaControls.gd")

const ROW_BG := Color(0.06, 0.06, 0.06)       # Color(white: 0.06)
const ROW_BORDER := Color(0.26, 0.26, 0.26)   # Color(white: 0.26)
const SLOT_BORDER := Color(0.24, 0.24, 0.24)
const DIM := Color(0.5, 0.5, 0.5)             # Color(white: 0.5) detail text


static func commas(n: int) -> String:
	var s := str(abs(n))
	var out := ""
	for i in s.length():
		if i > 0 and (s.length() - i) % 3 == 0:
			out += ","
		out += s[i]
	return ("-" if n < 0 else "") + out


## A row card (NovaText stack): the Button whose `content` meta takes the children.
static func _card(parent: Node, border: Color, radius := 6, padh := 12, padv := 9) -> Button:
	var b := NC.card_button(parent, ROW_BG, border, radius, 0)
	var m: MarginContainer = b.get_meta("content")
	m.add_theme_constant_override("margin_left", padh)
	m.add_theme_constant_override("margin_right", padh)
	m.add_theme_constant_override("margin_top", padv)
	m.add_theme_constant_override("margin_bottom", padv)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	NC.fit_card(b)
	return b


static func _text(parent: Node, text: String, size: int, color: Color, weight := "regular") -> Label:
	var l := NC.label(parent, text, "body", weight, color)
	l.add_theme_font_size_override("font_size", size)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	return l


## One pilot identity: [card: name + "n slots" chip / ship · system / credits · rating · updated | chevron]
## then the duplicate and delete icon buttons (the context menu is not reachable with a pad).
## acts: {open: Callable, duplicate: Callable, delete: Callable, can_duplicate: bool}
static func roster_row(list: Node, g: Dictionary, acts: Dictionary) -> Dictionary:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	list.add_child(h)
	var slots: Array = g.slots
	var s: Dictionary = {}
	for sl in slots:
		if str(sl.id) == str(g.most_recent):
			s = sl
	if s.is_empty() and not slots.is_empty():
		s = slots[slots.size() - 1]
	var card := _card(h, ROW_BORDER)
	card.pressed.connect(acts.get("open", Callable()))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	(card.get_meta("content") as Control).add_child(row)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 3)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(col)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(top)
	_text(top, str(g.name), 14, T.WHITE, "bold")
	if slots.size() > 1:
		var chip := PanelContainer.new()
		chip.add_theme_stylebox_override("panel", T.box(Color(0.16, 0.16, 0.16), 20, Color(0, 0, 0, 0), 0, Vector2(5, 1)))
		chip.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_text(chip, "%d slots" % slots.size(), 9, DIM)
		top.add_child(chip)
	var sys := str(s.get("system", ""))
	_text(col, "%s · %s" % [s.get("ship", ""), sys if sys != "" else "—"], 11, T.SECONDARY)
	_text(col, "%s cr · %s · %s" % [commas(int(s.get("credits", 0))), s.get("rating", ""), s.get("updated", "")], 10, DIM)
	NC.icon_rect(row, "chevron.right", 18, T.AMBER)
	var dup := NC.icon_button("plus.square.on.square", acts.get("duplicate", Callable()), T.AMBER, 30, 16)
	dup.tooltip_text = "Duplicate"
	dup.disabled = not bool(acts.get("can_duplicate", true))
	h.add_child(dup)
	var del := NC.icon_button("trash", acts.get("delete", Callable()), T.RED, 30, 16)
	del.tooltip_text = "Delete"
	h.add_child(del)
	return {"row": h, "open": card, "duplicate": dup, "delete": del}


static func roster_empty(parent: Node) -> VBoxContainer:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 10)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var c := CenterContainer.new()
	v.add_child(c)
	NC.icon_rect(c, "person.crop.circle", 40, T.SECONDARY)
	var a := _text(v, "No pilots yet.", 14, T.WHITE)
	a.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var b := _text(v, "Create a pilot to begin your story.", 11, T.SECONDARY)
	b.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	v.custom_minimum_size = Vector2(0, 110)
	parent.add_child(v)
	return v


## The scrolling list host: height = min(rows * 68 + 8, 320) as PilotListView.
static func roster_scroll(parent: Node, rows: int) -> VBoxContainer:
	var sc := ScrollContainer.new()
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.custom_minimum_size = Vector2(0, minf(float(rows) * 68.0 + 8.0, 320.0))
	sc.follow_focus = true
	parent.add_child(sc)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	v.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(v)
	return v


static func group_header(parent: Node, scenario: String, on_rename: Callable) -> Button:
	var h := HBoxContainer.new()
	parent.add_child(h)
	_text(h, scenario if scenario != "" else "Pilot", 11, T.SECONDARY).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var b := NC.button("Rename", "plain", on_rename, "pencil")
	b.icon = T.icon("pencil", 12, T.AMBER)
	T.style_text(b, "caption", "regular", T.AMBER)
	b.add_theme_color_override("font_hover_color", T.AMBER)
	h.add_child(b)
	return b


## One save slot: "Slot N" bold, ship · system, credits · rating · updated; delete (when several)
## and the amber play glyph.
static func slot_row(parent: Node, sl: Dictionary, acts: Dictionary) -> Dictionary:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 6)
	parent.add_child(h)
	var card := _card(h, SLOT_BORDER, 6, 10, 8)
	card.pressed.connect(acts.get("play", Callable()))
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	(card.get_meta("content") as Control).add_child(row)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(col)
	_text(col, "Slot %d" % int(sl.slot), 12, T.WHITE, "bold")
	var sys := str(sl.get("system", ""))
	_text(col, "%s · %s" % [sl.get("ship", ""), sys if sys != "" else "—"], 11, T.SECONDARY)
	_text(col, "%s cr · %s · %s" % [commas(int(sl.get("credits", 0))), sl.get("rating", ""), sl.get("updated", "")], 10, DIM)
	var out := {"row": h, "play": card}
	if bool(acts.get("multiple", false)):
		var del := NC.icon_button("trash", acts.get("delete", Callable()), Color(T.RED.r, T.RED.g, T.RED.b, 0.8), 28, 14)
		del.tooltip_text = "Delete slot"
		row.add_child(del)
		out["delete"] = del
	NC.icon_rect(row, "play.circle.fill", 18, T.AMBER)
	return out


## A caption-sized text button with a leading symbol ("New Save Slot (1/3)", "View All Backups").
static func link_button(parent: Node, text: String, icon_name: String, cb: Callable, color := T.AMBER) -> Button:
	var b := NC.button(text, "plain", cb, icon_name)
	b.icon = T.icon(icon_name, 13, color)
	T.style_text(b, "caption", "regular", color)
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	for st in ["font_hover_color", "font_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(st, color)
	parent.add_child(b)
	return b


static func caps_label(parent: Node, text: String) -> Label:
	return _text(parent, text, 10, DIM)


## One backup: "Slot N" bold + system, credits · date, restore glyph.
static func backup_row(parent: Node, r: Dictionary, slot_label: String, on_restore: Callable) -> Button:
	var card := _card(parent, SLOT_BORDER, 6, 10, 8)
	card.pressed.connect(on_restore)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 10)
	row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	(card.get_meta("content") as Control).add_child(row)
	var col := VBoxContainer.new()
	col.add_theme_constant_override("separation", 2)
	col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(col)
	var top := HBoxContainer.new()
	top.add_theme_constant_override("separation", 6)
	top.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(top)
	_text(top, slot_label, 11, T.WHITE, "bold")
	var sys := str(r.get("system", ""))
	_text(top, sys if sys != "" else "—", 11, T.SECONDARY)
	_text(col, "%s cr · %s" % [commas(int(r.get("credits", 0))), r.get("updated", "")], 10, DIM)
	NC.icon_rect(row, "arrow.uturn.backward.circle", 18, T.AMBER)
	return card


## "Label:   value" (PilotImportView.row).
static func kv_row(parent: Node, label: String, value: String) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	parent.add_child(h)
	var l := _text(h, label + ":", 12, Color(0.6, 0.6, 0.6))
	l.custom_minimum_size = Vector2(110, 0)
	var v := NC.label(h, value, "body", "regular", T.WHITE, true)
	v.add_theme_font_size_override("font_size", 12)
	return h
