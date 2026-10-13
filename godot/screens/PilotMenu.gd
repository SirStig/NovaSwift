# NOVA Swift — startup pilot screen (list / new / load / delete).
#
# Shown before flight when real EV Nova data is loaded. Every call goes through
# NovaWorld's "Pilots & saves" bridge section, which drives the same portable
# PilotArchive / PilotFactory the Apple app uses, so the .evpilot files this
# reads and writes are interchangeable with the Apple build's.
#
# Fully drivable with keyboard AND gamepad using only Godot's built-in focus
# navigation: arrows / d-pad / left stick move focus (ui_up/ui_down/…), Enter / A
# press (ui_accept), Esc / B go back (ui_cancel). There is no text-entry
# requirement — the dice button fills in a name (PilotNames, shared with the
# Apple app's pad keyboard suggestions) — but a LineEdit is there for keyboards.
#
# Presentation: with the data loaded and Settings > Presentation > "Modern dialogs" off (the
# default) the screens are the Classic UI kit's, as in the Apple app: New Pilot is the original's
# native DLOG/DITL 3102 (3101 with several scenarios) -- Full Name, Nickname, gender, Strict Play,
# OK/Cancel -- followed by the ship-name prompt DLOG/DITL 3001; Open Pilot is the app's dialog
# panel (the original had only the Mac file picker). A "Random" button beside the gender control
# fills the name without typing (gamepad). The plain Nova Swift screens below stay behind the
# toggle. Same signals and the same method names (_show_list / _show_new / _create / ...).
#
# Loaded with preload() (no class_name) so it resolves without an editor import
# pass, like Controls.gd.
extends CanvasLayer

const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")
const ClassicDialog = preload("res://ui/classic/ClassicDialog.gd")

## The player picked or created a pilot; the live pilot is already bound on the
## bridge, so the host only has to build the world (`make_world(-1)`).
signal pilot_chosen
## Esc / B (or Back) on the pilot list, when a host (the main menu) is listening.
signal cancelled

## Set by the host before setup(): the classic main menu is on screen behind this screen (so no
## opaque backdrop of its own).
var over_menu := false
var _classic := false
var _cdlg: Control            # the modal host of the classic dialog currently up
var _cdialog: Control         # ...and the ClassicDialog itself
var _page := 0
const PAGE := 7

var _nova: Object
var _dir: String
var _root: Control
var _panel: VBoxContainer
var _pilots: Array = []
var _scenarios: Array = []

# New-pilot form state.
var _scenario_index := 0
var _is_male := true
var _name_edit: LineEdit
var _scenario_btn: Button
var _gender_btn: Button
var _status: Label
# What ui_cancel does on the current screen.
var _on_back: Callable = Callable()


func setup(nova: Object, dir: String, start_new := false) -> void:
	_nova = nova
	_dir = dir
	layer = 50
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	ClassicTheme.setup(nova)
	_classic = ClassicTheme.classic("dialogs")
	if _classic:
		if not over_menu:
			var back := ColorRect.new()
			back.color = Color(0.02, 0.02, 0.06, 0.94)
			back.set_anchors_preset(Control.PRESET_FULL_RECT)
			_root.add_child(back)
		if start_new:
			_show_new()
		else:
			_show_list()
		return
	var dim := ColorRect.new()
	dim.color = Color(0.02, 0.02, 0.06, 0.94)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)
	var box := PanelContainer.new()
	box.custom_minimum_size = Vector2(520, 0)
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.09, 0.12)
	style.border_color = Color(0.45, 0.5, 0.6)
	style.set_border_width_all(2)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(22)
	box.add_theme_stylebox_override("panel", style)
	center.add_child(box)
	_panel = VBoxContainer.new()
	_panel.add_theme_constant_override("separation", 8)
	box.add_child(_panel)
	if start_new:
		_show_new()
	else:
		_show_list()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and _on_back.is_valid():
		_on_back.call()
		get_viewport().set_input_as_handled()


# --- helpers ---------------------------------------------------------------

func _clear(title: String, back: Callable = Callable()) -> void:
	for c in _panel.get_children():
		_panel.remove_child(c)
		c.queue_free()
	_on_back = back
	_status = null
	var t := Label.new()
	t.text = title
	t.add_theme_font_size_override("font_size", 26)
	t.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_panel.add_child(t)


func _button(text: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size = Vector2(0, 38)
	b.pressed.connect(func(): _nova.sound_beep(1))   # port-only screen: the confirm beep (snd 150)
	b.pressed.connect(cb)
	_panel.add_child(b)
	return b


func _label(text: String, size := 15, color := Color(0.75, 0.78, 0.85)) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_panel.add_child(l)
	return l


func _focus(b: Control) -> void:
	# Deferred so the button is in the tree; guarded because a screen can be
	# replaced before the deferred call lands.
	(func(): if is_instance_valid(b) and b.is_inside_tree(): b.grab_focus()).call_deferred()


# --- pilot list --------------------------------------------------------------

func _show_list() -> void:
	if _classic:
		_c_list()
		return
	var hosted := not cancelled.get_connections().is_empty()
	_clear("Select Pilot", _cancel if hosted else Callable())
	var parsed = JSON.parse_string(_nova.pilot_list(_dir))
	_pilots = parsed if parsed is Array else []
	var first: Button = null
	for p in _pilots:
		var b := _button("%s — %s · %s · %s cr" % [p.name, p.ship, p.system, _commas(int(p.credits))],
				_show_pilot.bind(p))
		if first == null:
			first = b
	if _pilots.is_empty():
		_label("No pilots yet. Create one to begin.")
	var new_btn := _button("New Pilot…", _show_new)
	if hosted:
		_button("Back", _cancel)
	_focus(first if first != null else new_btn)


func _cancel() -> void:
	cancelled.emit()
	queue_free()


func _show_pilot(p: Dictionary) -> void:
	if _classic:
		_c_pilot(p)
		return
	_clear(p.name, _show_list)
	_label("%s · %s\n%s credits · %s\nScenario: %s · saved %s" % [
		p.ship, p.system, _commas(int(p.credits)), p.rating,
		p.scenario if p.scenario != "" else "—", p.updated])
	var play := _button("Play", _load.bind(p))
	_button("Delete…", _confirm_delete.bind(p))
	_button("Back", _show_list)
	_focus(play)


func _load(p: Dictionary) -> void:
	if _nova.pilot_load(_dir, p.id):
		_finish()
	else:
		_status_msg("Could not open that pilot.")


func _confirm_delete(p: Dictionary) -> void:
	if _classic:
		_c_confirm_delete(p)
		return
	_clear("Delete %s?" % p.name, _show_pilot.bind(p))
	_label("This removes the pilot, every save slot and all backups. It cannot be undone.")
	# Default focus is the safe choice.
	var no := _button("No, keep this pilot", _show_pilot.bind(p))
	_button("Yes, delete", func():
		_nova.pilot_delete(_dir, p.id)
		_show_list())
	_focus(no)


# --- new pilot -----------------------------------------------------------------

func _show_new() -> void:
	var parsed = JSON.parse_string(_nova.pilot_scenarios())
	_scenarios = parsed if parsed is Array else []
	if _classic:
		_c_new()
		return
	if _scenarios.is_empty():
		_clear("No Scenarios", _show_list)
		_label("No starting scenarios were found in the game data.")
		_focus(_button("Back", _show_list))
		return
	_scenario_index = 0
	_is_male = true
	_clear("New Pilot", _show_list)
	_scenario_btn = _button("", _cycle_scenario)
	_name_edit = LineEdit.new()
	_name_edit.max_length = _nova.pilot_max_name_length()
	_name_edit.text = _nova.pilot_default_name(0)
	_name_edit.placeholder_text = "Pilot name"
	_name_edit.custom_minimum_size = Vector2(0, 38)
	# Enter in the box moves on to Start rather than doing nothing.
	_name_edit.text_submitted.connect(func(_t): _start_btn.grab_focus())
	_panel.add_child(_name_edit)
	_button("Random name", func(): _name_edit.text = _nova.pilot_random_name())
	_gender_btn = _button("", func():
		_is_male = not _is_male
		_refresh_new())
	_start_btn = _button("Start", _create)
	_button("Back", _show_list)
	_status = _label("", 14, Color(1.0, 0.55, 0.5))
	_refresh_new()
	_focus(_start_btn)


var _start_btn: Button


func _refresh_new() -> void:
	var s: Dictionary = _scenarios[_scenario_index]
	_scenario_btn.text = "Scenario: %s%s" % [s.name,
		("  (%d/%d)" % [_scenario_index + 1, _scenarios.size()]) if _scenarios.size() > 1 else ""]
	_gender_btn.text = "Pilot: %s" % ("Male" if _is_male else "Female")


func _cycle_scenario() -> void:
	_scenario_index = (_scenario_index + 1) % _scenarios.size()
	_refresh_new()


func _create() -> void:
	if _classic:
		_c_name_ok()
		return
	var nm := _name_edit.text.strip_edges()
	if nm == "":
		_status_msg("Enter a name, or press Random name.")
		return
	var s: Dictionary = _scenarios[_scenario_index]
	# Nickname and ship name take the dialog's prefilled STR# 128 defaults, as
	# the Apple flow does when the player accepts them.
	var id: String = _nova.pilot_create(_dir, int(s.id), nm, _is_male,
			_nova.pilot_default_name(1), _nova.pilot_default_name(2))
	if id == "":
		_status_msg("Could not create the pilot.")
		return
	_finish()


func _status_msg(t: String) -> void:
	_nova.sound_beep(3)   # a rejected form keeps snd 152
	if _status != null:
		_status.text = t


func _finish() -> void:
	pilot_chosen.emit()
	queue_free()


static func _commas(n: int) -> String:
	var s := str(abs(n))
	var out := ""
	for i in s.length():
		if i > 0 and (s.length() - i) % 3 == 0:
			out += ","
		out += s[i]
	return ("-" if n < 0 else "") + out


# --- Classic dialogs ---------------------------------------------------------------------

func _c_show(d: Control) -> void:
	if _cdlg != null and is_instance_valid(_cdlg):
		_cdlg.queue_free()
	_cdialog = d
	_cdlg = ClassicDialog.modal(_root, d, 0.55 if over_menu else 0.0)


func _c_list() -> void:
	var hosted := not cancelled.get_connections().is_empty()
	var parsed = JSON.parse_string(_nova.pilot_list(_dir))
	_pilots = parsed if parsed is Array else []
	_page = clampi(_page, 0, maxi(0, (_pilots.size() - 1) / PAGE))
	var body := []
	for i in range(_page * PAGE, mini(_pilots.size(), (_page + 1) * PAGE)):
		var p: Dictionary = _pilots[i]
		body.append({"label": "%s - %s" % [p.name, p.ship], "action": _show_pilot.bind(p)})
	var footer := []
	if _pilots.size() > PAGE:
		footer.append({"label": "More", "action": func():
			_page = (_page + 1) % ((_pilots.size() + PAGE - 1) / PAGE)
			_c_list()})
	footer.append({"label": "New Pilot", "action": _show_new, "default": _pilots.is_empty()})
	if hosted:
		footer.append({"label": "Back", "action": _cancel, "cancel": true})
	var opts := {"title": "Select Pilot", "width": 460, "body_buttons": body, "body_buttons_width": 360,
		"footer_buttons": footer}
	if _pilots.is_empty():
		opts["text"] = "No pilots yet. Create one to begin."
	_c_show(ClassicDialog.panel(_nova, opts))
	if not body.is_empty():
		(func(): if is_instance_valid(_cdialog): _cdialog.item(0).grab_focus()).call_deferred()


func _c_pilot(p: Dictionary) -> void:
	var text := "%s - %s. %s credits - %s. Scenario: %s - saved %s" % [
		p.ship, p.system, _commas(int(p.credits)), p.rating,
		p.scenario if p.scenario != "" else "-", p.updated]
	_c_show(ClassicDialog.panel(_nova, {"title": p.name, "width": 460, "text": text,
		"body_buttons": [{"label": "Play", "action": _load.bind(p)},
			{"label": "Delete…", "action": _confirm_delete.bind(p)}],
		"footer_buttons": [{"label": "Back", "action": _show_list, "cancel": true}]}))


## The original's yes/no prompt (DLOG 3002); the safe answer (Cancel) holds the focus.
func _c_confirm_delete(p: Dictionary) -> void:
	var d := ClassicDialog.confirm(_nova,
		"Delete %s? This removes the pilot, every save slot and all backups. It cannot be undone." % p.name,
		{"ok": "Delete", "cancel": "Keep"})
	d.actions[0] = func():
		_nova.pilot_delete(_dir, p.id)
		_show_list()
	d.actions[4] = _show_pilot.bind(p)
	_c_show(d)
	(func(): if is_instance_valid(d): d.item(4).grab_focus()).call_deferred()


# New pilot: DLOG/DITL 3102 (3101 with several scenarios): 0 OK, 1 Cancel, 3 Strict Play,
# 7 Full Name, 8 Nickname, 10 gender, 12 scenario; 20 is the port's Random-name button.
const NP_OK := 0
const NP_CANCEL := 1
const NP_STRICT := 3
const NP_NAME := 7
const NP_NICK := 8
const NP_GENDER := 10
const NP_SCENARIO := 12
const NP_RANDOM := 20

var _nick_edit: LineEdit
var _strict := false


func _c_new() -> void:
	if _scenarios.is_empty():
		var d0 := ClassicDialog.confirm(_nova, "No starting scenarios were found in the game data.", {"ok": "OK", "cancel": "Back"})
		d0.actions[0] = _show_list
		d0.actions[4] = _show_list
		_c_show(d0)
		return
	_scenario_index = clampi(_scenario_index, 0, _scenarios.size() - 1)
	var multi := _scenarios.size() > 1
	var names := []
	for sc in _scenarios:
		names.append(str(sc.name))
	var keep_name := _name_edit.text if is_instance_valid(_name_edit) and _name_edit.is_inside_tree() else _nova.pilot_default_name(0)
	var keep_nick := _nick_edit.text if is_instance_valid(_nick_edit) and _nick_edit.is_inside_tree() else _nova.pilot_default_name(1)
	var me := self
	var d := ClassicDialog.from_ditl(_nova, 3101 if multi else 3102, {
		"texts": {NP_NAME: keep_name, NP_NICK: keep_nick},
		"default_item": NP_OK, "cancel_item": NP_CANCEL,
		"fallback_size": Vector2i(326, 213),
		"actions": {NP_OK: me._c_name_ok, NP_CANCEL: me._show_list,
			NP_RANDOM: func(): me._name_edit.text = me._nova.pilot_random_name()},
		"custom": {
			NP_GENDER: func(parent, rect: Rect2i):
				parent.add_cycle(["Male", "Female"], rect, NP_GENDER, 0 if me._is_male else 1)
				parent.cycled.connect(func(i, sel): if i == NP_GENDER: me._is_male = sel == 0)
				# Not in the original: a dice button for typing-free (gamepad) name entry.
				parent.add_button("Random", Rect2i(rect.end.x + 4, rect.position.y, 64, rect.size.y), NP_RANDOM),
			NP_SCENARIO: func(parent, rect: Rect2i):
				parent.add_cycle(names, rect, NP_SCENARIO, me._scenario_index)
				parent.cycled.connect(func(i, sel): if i == NP_SCENARIO: me._scenario_index = sel),
		}})
	_name_edit = d.texts.get(NP_NAME)
	_nick_edit = d.texts.get(NP_NICK)
	for e in [_name_edit, _nick_edit]:
		if e != null:
			e.max_length = int(_nova.pilot_max_name_length())
	if d.item(NP_STRICT) != null:
		d.item(NP_STRICT).button_pressed = _strict
		d.item(NP_STRICT).toggled.connect(func(on): me._strict = on)
	_c_show(d)


## OK on the pilot dialog: validate, then ask the ship's name (DLOG/DITL 3001).
func _c_name_ok() -> void:
	var nm := _name_edit.text.strip_edges()
	if nm == "":
		_status_msg("Enter a name, or press Random.")
		return
	var s: Dictionary = _scenarios[_scenario_index]
	var prompt: String = _nova.pilot_ship_name_prompt(int(s.id))
	var d := ClassicDialog.text_prompt(_nova, prompt, _nova.pilot_default_name(2))
	d.texts[4].max_length = 64
	d.actions[0] = func(): _c_start(nm, d.edit_text(4))
	d.actions[5] = _show_new
	_c_show(d)
	(func(): if is_instance_valid(d): d.texts[4].grab_focus()).call_deferred()


func _c_start(nm: String, ship_name: String) -> void:
	var s: Dictionary = _scenarios[_scenario_index]
	var nick := _nick_edit.text.strip_edges() if is_instance_valid(_nick_edit) else _nova.pilot_default_name(1)
	var id: String = _nova.pilot_create_strict(_dir, int(s.id), nm, _is_male, nick,
		ClassicDialog.prompt_answer(ship_name.strip_edges()), _strict)
	if id == "":
		_nova.sound_beep(3)
		_show_new()
		return
	_finish()
