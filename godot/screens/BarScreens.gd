# NOVA Swift — the bar's Hire Escort browser and Gambling screen (Godot).
#
# Every rule is shared Swift reached through NovaWorld's "Gameplay gaps" bridge
# section: the hire list, price, availability and wing cap are `EscortHire`
# (the code Apple's HireEscortView rules were extracted into); the racing game is
# `RaceSession` (GamblingView's odds: standard wager min(credits, 1000), typed
# wager up to min(credits, 10000), a win pays four times the wager, a repeat of
# the previous winner is a guaranteed loss). This file only lays out Controls and
# routes input; both screens are overlays on the Spaceport (its overlay plumbing).
#
# Controller-first with Godot focus: d-pad / stick move focus, A / Enter press,
# B / Esc closes (Spaceport's overlay back). Mouse works everywhere.
#
# Loaded with preload() (no class_name), like the other screens. The holovid race
# clip (Race n.mov) isn't played — the result screen shows the outcome art.
extends RefCounted

const CS = preload("res://ui/classic/ClassicScreen.gd")
const T = preload("res://ui/classic/ClassicTheme.gd")
const CD = preload("res://ui/classic/ClassicDialog.gd")

const COL_DIM := Color(0.62, 0.66, 0.74)
const COL_HI := Color(1.0, 0.95, 0.7)
const COL_GOOD := Color(0.5, 0.9, 0.5)
const COL_BAD := Color(1.0, 0.5, 0.5)

var _sp: Node          # the Spaceport (overlay plumbing, textures, labels)
var _nova: Object

# Hire Escort
var _hire_sel := -1
var _hire_msg := ""

# Gambling
var _pick := -1
var _gamble_msg := ""


func setup(spaceport: Node, nova: Object) -> void:
	_sp = spaceport
	_nova = nova


func _json(t: String) -> Dictionary:
	var v = JSON.parse_string(t)
	return v if v is Dictionary else {}


# A fresh overlay box for a screen; the previous one (if any) is closed first.
func _begin(width: float) -> VBoxContainer:
	_sp._close_overlay()
	_sp._overlay = _sp._make_overlay()
	return _sp._overlay_box(Vector2(width, 0))


# --- Hire Escort -----------------------------------------------------------------------

func open_hire() -> void:
	_hire_sel = -1
	_hire_msg = ""
	_nova.sound_beep(2)
	_show_hire()


func _show_hire(focus_id := -2) -> void:
	if _sp._classic():
		_hire_classic()
		return
	var d := _json(_nova.hire_list())
	var ships: Array = d.get("ships", [])
	var labels: Dictionary = d.get("labels", {})
	var box := _begin(980)
	var head := HBoxContainer.new()
	box.add_child(head)
	var title = _sp._label("Ships for Hire", 22, COL_HI, head)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sp._label("You have: %s cr" % _sp._commas(int(d.get("credits", 0))), 16, COL_HI, head)

	var sel: Dictionary = {}
	for s in ships:
		if int(s.id) == _hire_sel:
			sel = s
	if sel.is_empty() and not ships.is_empty():
		sel = ships[0]
		_hire_sel = int(sel.id)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 16)
	box.add_child(body)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(380, 380)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	body.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	var focus_btn: Button = null
	for s in ships:
		var b := Button.new()
		b.name = "ship_%d" % int(s.id)
		b.text = "%s   %s cr" % [str(s.name), _sp._commas(int(s.price))]
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.toggle_mode = true
		b.button_pressed = int(s.id) == _hire_sel
		if bool(s.locked):
			b.modulate = Color(1, 1, 1, 0.55)   # not unlocked yet: greyed, not hidden
		var id := int(s.id)
		b.pressed.connect(func(): _hire_sel = id; _show_hire(id))
		list.add_child(b)
		if id == (_hire_sel if focus_id == -2 else focus_id):
			focus_btn = b
	if ships.is_empty():
		_sp._label("No ships are available for hire here today.", 15, COL_DIM, list)

	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(540, 0)
	side.add_theme_constant_override("separation", 5)
	body.add_child(side)
	if not sel.is_empty():
		var pic: Texture2D = _sp._pict_tex(int(sel.pict))
		if pic != null:
			var row := CenterContainer.new()
			row.add_child(_sp._picture(pic, Vector2(280, 180)))
			side.add_child(row)
		_sp._label(str(sel.name), 20, COL_HI, side)
		_sp._label(str(sel.category), 14, Color(1.0, 0.82, 0.4), side)
		_sp._label("Shield / Armor: %d / %d" % [int(sel.shield), int(sel.armor)], 14, Color.WHITE, side)
		_sp._label("Guns / Turrets: %d / %d" % [int(sel.guns), int(sel.turrets)], 14, Color.WHITE, side)
		var dscroll := ScrollContainer.new()
		dscroll.custom_minimum_size = Vector2(0, 90)
		dscroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		side.add_child(dscroll)
		var desc = _sp._label(str(sel.description), 13, COL_DIM)
		desc.get_parent().remove_child(desc)
		desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		dscroll.add_child(desc)
		_sp._label("Hire:  %s cr" % _sp._commas(int(sel.price)), 15, COL_HI, side)
		_sp._label("Per day:  %s cr" % _sp._commas(int(sel.perDay)), 15, COL_HI, side)
	if not bool(d.get("hasRoom", true)):
		_sp._label("You can't command any more escorts.", 14, COL_BAD, box)
	var status = _sp._label(_hire_msg, 14, Color(1.0, 0.8, 0.5), box)
	status.name = "hire_status"

	var bar := HBoxContainer.new()
	box.add_child(bar)
	var hire = _sp._button(str(labels.get("hire", "Hire Escort")), _hire_pressed, bar)
	hire.name = "hire_button"
	hire.disabled = sel.is_empty() or not bool(sel.get("canHire", false))
	var done = _sp._button(str(labels.get("done", "Done")), _close_overlay_beep, bar)
	done.name = "hire_done"
	for c in bar.get_children():
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sp._overlay_back = _close_overlay_beep
	if focus_btn != null:
		_sp._focus(focus_btn)
	elif not hire.disabled:
		_sp._focus(hire)
	else:
		_sp._focus(done)


func _hire_pressed() -> void:
	if _hire_sel < 0:
		return
	var name := ""
	for s in _json(_nova.hire_list()).get("ships", []):
		if int(s.id) == _hire_sel:
			name = str(s.name)
	if _nova.hire_escort(_hire_sel):
		_nova.sound_beep(2)
		_hire_msg = "Hired the %s — it joins you on takeoff." % name
	else:
		_nova.sound_beep(4)
		_hire_msg = "Can't hire that ship."
	_sp._update_credits()
	_show_hire()


func _close_overlay_beep() -> void:
	_nova.sound_beep(3)
	_sp._close_overlay()


# --- Gambling --------------------------------------------------------------------------

func open_gamble() -> void:
	_pick = -1
	_gamble_msg = ""
	_nova.sound_beep(2)
	_show_choose()


func _color_button(c: Dictionary, index: int, chosen: bool) -> Button:
	var b := Button.new()
	b.name = "color_%d" % index
	b.toggle_mode = true
	b.button_pressed = chosen
	b.custom_minimum_size = Vector2(130, 130)
	var tex: Texture2D = _sp._pict_tex(int(c.chosen if chosen else c.idle))
	if tex != null:
		b.icon = tex
		b.expand_icon = true
	else:
		b.text = str(c.name)
	return b


func _show_choose() -> void:
	if _sp._classic():
		_choose_classic()
		return
	var d := _json(_nova.gamble_info())
	var labels: Dictionary = d.get("labels", {})
	var box := _begin(640)
	var head := HBoxContainer.new()
	box.add_child(head)
	var t = _sp._label("Galaxy Racing Network", 22, COL_HI, head)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var credits = _sp._label("%s cr" % _sp._commas(int(d.get("credits", 0))), 16, COL_HI, head)
	credits.name = "gamble_credits"
	_sp._label("Choose your color for the next race", 15, COL_DIM, box)
	var row := HBoxContainer.new()
	row.alignment = BoxContainer.ALIGNMENT_CENTER
	row.add_theme_constant_override("separation", 10)
	box.add_child(row)
	var first: Button = null
	var colors: Array = d.get("colors", [])
	for i in colors.size():
		var idx := i
		var b := _color_button(colors[i], i, i == _pick)
		b.pressed.connect(func(): _pick = idx; _show_choose())
		row.add_child(b)
		if i == _pick or first == null:
			first = b
	var status = _sp._label(_gamble_msg, 14, Color(1.0, 0.8, 0.5), box)
	status.name = "gamble_status"
	var bar := HBoxContainer.new()
	box.add_child(bar)
	var have_cash := int(d.get("credits", 0)) > 0
	var bet1 = _sp._button(str(labels.get("bet1000", "Bet 1000")), func(): _bet(int(d.get("standard", 0))), bar)
	bet1.name = "bet_standard"
	bet1.disabled = _pick < 0 or not have_cash
	var bet = _sp._button(str(labels.get("bet", "Bet")) + "…", func(): _show_amount(d), bar)
	bet.name = "bet_amount"
	bet.disabled = _pick < 0 or not have_cash
	var leave = _sp._button(str(labels.get("leave", "Leave")), _close_overlay_beep, bar)
	leave.name = "gamble_leave"
	for c in bar.get_children():
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sp._overlay_back = _close_overlay_beep
	_sp._focus(first if first != null else leave)


# The typed wager (STR# 2002 #372 "Amount to bet:"), capped at min(credits, 10000).
func _show_amount(d: Dictionary) -> void:
	var cap := maxi(1, int(d.get("max", 1)))
	if _sp._classic():
		_sp._c.prompt(str(d.get("prompt", "Amount to bet:")), cap, mini(1000, cap), func(q): _bet(q), _show_choose)
		return
	var box := _begin(480)
	_sp._label(str(d.get("prompt", "Amount to bet:")), 18, COL_HI, box)
	var spin := SpinBox.new()
	spin.name = "bet_spin"
	spin.min_value = 1
	spin.max_value = cap
	spin.value = mini(1000, cap)
	spin.step = 1
	spin.custom_minimum_size = Vector2(0, 44)
	box.add_child(spin)
	var bar := HBoxContainer.new()
	box.add_child(bar)
	var ok = _sp._button("OK", func(): _bet(int(spin.value)), bar)
	ok.name = "amount_ok"
	var cancel = _sp._button("Cancel", _show_choose, bar)
	for c in bar.get_children():
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spin.get_line_edit().text_submitted.connect(func(_t): _bet(int(spin.value)))
	_sp._overlay_back = _show_choose
	_sp._focus(spin.get_line_edit())


func _bet(wager: int) -> void:
	if _pick < 0:
		return
	var r := _json(_nova.gamble_bet(_pick, wager))
	if not bool(r.get("ok", false)):
		_nova.sound_beep(4)
		_gamble_msg = "You can't cover that bet."
		_show_choose()
		return
	_sp._update_credits()
	_show_result(r)


func _show_result(r: Dictionary) -> void:
	if _sp._classic():
		_result_classic(r)
		return
	var d := _json(_nova.gamble_info())
	var colors: Array = d.get("colors", [])
	var labels: Dictionary = d.get("labels", {})
	var box := _begin(640)
	var won := int(r.payout) > 0
	# Top row: the real outcome (the winner in its "wins" art, the rest disabled).
	var top := HBoxContainer.new()
	top.alignment = BoxContainer.ALIGNMENT_CENTER
	top.add_theme_constant_override("separation", 10)
	box.add_child(top)
	for i in colors.size():
		var tex: Texture2D = _sp._pict_tex(int(colors[i].win if i == int(r.winner) else colors[i].lose))
		var pic: Control = _sp._picture(tex, Vector2(96, 84))
		top.add_child(pic)
	# Bottom row echoes the player's own pick.
	var mine := HBoxContainer.new()
	mine.alignment = BoxContainer.ALIGNMENT_CENTER
	mine.add_theme_constant_override("separation", 10)
	box.add_child(mine)
	for i in colors.size():
		var tex2: Texture2D = _sp._pict_tex(int(colors[i].chosen)) if i == int(r.pick) else null
		mine.add_child(_sp._picture(tex2, Vector2(96, 84)))
	var line = _sp._label(str(r.text), 17, COL_GOOD if won else COL_BAD, box)
	line.name = "gamble_result"
	line.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var credits = _sp._label("%s cr" % _sp._commas(int(r.credits)), 15, COL_HI, box)
	credits.name = "gamble_credits"
	credits.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var bar := HBoxContainer.new()
	box.add_child(bar)
	var leave = _sp._button(str(labels.get("leave", "Leave")), _close_overlay_beep, bar)
	leave.name = "gamble_leave"
	var again = _sp._button("Bet Again", func(): _pick = -1; _gamble_msg = ""; _show_choose(), bar)
	again.name = "bet_again"
	for c in bar.get_children():
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_sp._overlay_back = _close_overlay_beep
	_sp._focus(again)


# --- Classic (original UI) versions ------------------------------------------------------------

var _hire_dlg: Control
var _hire_top := 0
var _gamble_dlg: Control


func _overlay_swap(old: Control, d: Control, default_key: String) -> void:
	var key := CS.focus_key(old)
	if key.begins_with("tile"):
		key = ""   # the selection, not the old slot, decides which tile gets focus
	_sp._c.show_overlay(d)
	_sp._overlay_back = _close_overlay_beep
	if key == "" or not CS.focus_by_key(d, key):
		CS.focus_by_key(d, default_key)


# Hire Escort: the Shipyard's frame (PICT 8501, DITL 1004) renting instead of buying.
func _hire_classic() -> void:
	var data := _json(_nova.hire_list())
	var ships: Array = data.get("ships", [])
	var labels: Dictionary = data.get("labels", {})
	var by_id := {}
	for s in ships:
		by_id[int(s.id)] = s
	if not by_id.has(_hire_sel) and not ships.is_empty():
		_hire_sel = int(ships[0].id)
	var d := CS.frame(_nova, 1004, 8501)
	var grid := CS.ItemGrid.new()
	grid.build(d, CS.rect(_nova, 1004, 4, Rect2i(9, 8, 333, 271)), 100)
	var pane := CS.rect(_nova, 1004, 5, Rect2i(354, 10, 192, 267))
	var pic := CS.picture(d, null, CS.rect(_nova, 1004, 7, Rect2i(557, 8, 200, 200)), TextureRect.STRETCH_KEEP_ASPECT_COVERED)
	var nm := CS.text(d, "", Rect2i(pane.position, Vector2i(pane.size.x, 16)), 12, Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT, true)
	var desc := CS.scroll_text(d, "", Rect2i(pane.position.x, pane.position.y + 16, pane.size.x, pane.size.y - 16))
	var info_r := CS.rect(_nova, 1004, 8, Rect2i(614, 214, 143, 100))
	var rows := []
	for i in 3:
		var y := info_r.position.y + i * 22
		rows.append([CS.text(d, "", Rect2i(info_r.position.x, y, 66, 16), 10, Color(0.6, 0.6, 0.6)),
			CS.text(d, "", Rect2i(info_r.position.x + 66, y, info_r.size.x - 66, 16), 10, Color.WHITE)])
	var msg := ""   # the original shows no hire feedback; the roster / counts just update
	var status := CS.text(d, msg, Rect2i(205, 289, 155, 25), 9, CS.AMBER)
	status.name = "hire_status"
	status.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	var hire := CS.button(d, str(labels.get("hire", "Hire Escort")), CS.rect(_nova, 1004, 0, Rect2i(365, 289, 109, 25)), 0,
		_hire_pressed, true, "hire_button")
	hire.refused.connect(func(): _nova.sound_beep(4))
	CS.button(d, str(labels.get("done", "Done")), CS.rect(_nova, 1004, 6, Rect2i(480, 289, 109, 25)), 6, _close_overlay_beep, true, "hire_done")
	var up := CS.button(d, "^", CS.rect(_nova, 1004, 11, Rect2i(141, 288, 25, 25)), 11, func(): grid.scroll(-1), true, "hire_up")
	var down := CS.button(d, "&", CS.rect(_nova, 1004, 12, Rect2i(171, 288, 25, 25)), 12, func(): grid.scroll(1), true, "hire_down")
	var show := func(id: int):
		_hire_sel = id
		var s: Dictionary = by_id.get(id, {})
		if s.is_empty():
			return
		pic.texture = T.pict(int(s.pict)) if int(s.pict) >= 0 else null
		nm.text = str(s.name)
		desc.label.text = "%s\nShield / Armor: %d / %d\nGuns / Turrets: %d / %d\n\n%s" % [str(s.category),
			int(s.shield), int(s.armor), int(s.guns), int(s.turrets), str(s.description)]
		desc.scroll_vertical = 0
		var vals := [["Hire:", "%d cr" % int(s.price)], ["Per day:", "%d cr" % int(s.perDay)],
			["You Have:", "%d cr" % int(data.get("credits", 0))]]
		for r in 3:
			rows[r][0].text = vals[r][0]
			rows[r][1].text = vals[r][1]
		hire.disabled = not bool(s.get("canHire", false))
	var items := []
	for s in ships:
		var pid := int(s.pict)
		items.append({"id": int(s.id), "name": str(s.name), "tex": T.pict(pid) if pid >= 0 else null,
			"qty": 0, "locked": bool(s.locked)})
	grid.on_select = show
	grid.on_activate = func(_id): if not hire.disabled: hire.grab_focus()
	grid.on_scroll = func():
		_hire_top = grid.top_row
		up.disabled = grid.top_row <= 0
		down.disabled = grid.top_row >= grid.max_top()
	grid.set_items(items, _hire_sel, _hire_top)
	for i in grid.tiles.size():
		pass
	show.call(_hire_sel)
	var old := _hire_dlg
	_hire_dlg = d
	var si: int = grid.slot_of_selected()
	_overlay_swap(old, d, "tile%d" % si if si >= 0 else "hire_done")
	if ships.is_empty():
		CS.text(d, "No ships are available for hire here today.", Rect2i(30, 120, 280, 30), 11, Color(0.7, 0.7, 0.7),
			HORIZONTAL_ALIGNMENT_CENTER)


func _gamble_bg(old: Control, d: Control, default_key: String) -> void:
	_gamble_dlg = d
	_overlay_swap(old, d, default_key)


# Choose your colour: DITL 1023 on PICT 8529.
func _choose_classic() -> void:
	var data := _json(_nova.gamble_info())
	var labels: Dictionary = data.get("labels", {})
	var colors: Array = data.get("colors", [])
	var d := CS.frame(_nova, 1023, 8529)
	var lefts := [13, 128, 243, 357]
	var first_key := ""
	for i in colors.size():
		var idx := i
		var r := CS.rect(_nova, 1023, 2 + i, Rect2i(lefts[i], 88, 100, 100))
		var b := CS.row(d, r, 2 + i)
		b.name = "color_%d" % i
		b.set_meta("fkey", "color_%d" % i)
		var chosen := i == _pick
		var tex := T.pict(int(colors[i].chosen if chosen else colors[i].idle))
		if tex != null:
			var tr := TextureRect.new()
			tr.texture = tex
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			tr.size = Vector2(r.size)
			tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			b.add_child(tr)
		if chosen:
			var ring := ReferenceRect.new()
			ring.editor_only = false
			ring.border_color = Color(1, 0.9, 0.2, 0.85)
			ring.border_width = 3.0
			ring.size = Vector2(r.size)
			ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
			b.add_child(ring)
		b.pressed.connect(func(): _pick = idx; _choose_classic())
		if first_key == "" or chosen:
			first_key = "color_%d" % i
	var have_cash := int(data.get("credits", 0)) > 0
	var bet1 := CS.button(d, str(labels.get("bet1000", "Bet 1000")), CS.rect(_nova, 1023, 1, Rect2i(129, 196, 99, 25)), 1,
		func(): _bet(int(data.get("standard", 0))), _pick >= 0 and have_cash, "bet_standard")
	var bet := CS.button(d, str(labels.get("bet", "Bet")), CS.rect(_nova, 1023, 0, Rect2i(243, 196, 99, 25)), 0,
		func(): _show_amount(data), _pick >= 0 and have_cash, "bet_amount")
	for b in [bet1, bet]:
		b.refused.connect(func(): _nova.sound_beep(4))
	var cr := CS.text(d, "%s cr" % CS.credits(int(data.get("credits", 0))), Rect2i(13, 203, 100, 14), 11, CS.GOLD,
		HORIZONTAL_ALIGNMENT_CENTER)
	cr.name = "gamble_credits"
	var st := CS.text(d, "", Rect2i(13, 66, 444, 16), 11, CS.AMBER, HORIZONTAL_ALIGNMENT_CENTER)
	st.name = "gamble_status"
	CS.button(d, str(labels.get("leave", "Leave")), Rect2i(357, 196, 99, 25), 20, _close_overlay_beep, true, "gamble_leave")
	_gamble_bg(_gamble_dlg, d, first_key)


# Result: DITL 1015 (251x214, no frame art).
func _result_classic(r: Dictionary) -> void:
	var data := _json(_nova.gamble_info())
	var colors: Array = data.get("colors", [])
	var labels: Dictionary = data.get("labels", {})
	var d := CS.frame(_nova, 1015, -1, {"chrome": CD.Chrome.PICT, "fallback_size": Vector2i(251, 214)})
	var won := int(r.payout) > 0
	var lefts := [6, 67, 128, 189]
	for i in colors.size():
		var top := CS.rect(_nova, 1015, 2 + i, Rect2i(lefts[i], 5, 56, 48))
		var tex := T.pict(int(colors[i].win if i == int(r.winner) else colors[i].lose))
		if tex != null:
			CS.picture(d, tex, top, TextureRect.STRETCH_KEEP_ASPECT)
		if i == int(r.pick):
			var mine := CS.rect(_nova, 1015, 6 + i, Rect2i(lefts[i], 67, 56, 48))
			var t2 := T.pict(int(colors[i].chosen))
			if t2 != null:
				CS.picture(d, t2, mine, TextureRect.STRETCH_KEEP_ASPECT)
	var line := CS.text(d, str(r.text), CS.rect(_nova, 1015, 11, Rect2i(6, 125, 238, 48)), 12,
		Color(0.5, 0.9, 0.5) if won else Color(1, 0.5, 0.5), HORIZONTAL_ALIGNMENT_CENTER)
	line.name = "gamble_result"
	var cr := CS.text(d, "%s cr" % CS.credits(int(r.credits)), CS.rect(_nova, 1015, 1, Rect2i(87, 186, 75, 20)), 10, CS.GOLD,
		HORIZONTAL_ALIGNMENT_CENTER)
	cr.name = "gamble_credits"
	CS.button(d, str(labels.get("leave", "Leave")), CS.rect(_nova, 1015, 10, Rect2i(6, 182, 75, 25)), 10, _close_overlay_beep, true, "gamble_leave")
	CS.button(d, "Bet Again", CS.rect(_nova, 1015, 0, Rect2i(169, 182, 75, 25)), 0,
		func(): _pick = -1; _gamble_msg = ""; _choose_classic(), true, "bet_again")
	_gamble_bg(_gamble_dlg, d, "bet_again")
