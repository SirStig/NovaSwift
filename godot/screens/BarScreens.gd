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
