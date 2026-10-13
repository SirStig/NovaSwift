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
# Loaded with preload() (no class_name) so it resolves without an editor import
# pass, like Controls.gd.
extends CanvasLayer

## The player picked or created a pilot; the live pilot is already bound on the
## bridge, so the host only has to build the world (`make_world(-1)`).
signal pilot_chosen
## Esc / B (or Back) on the pilot list, when a host (the main menu) is listening.
signal cancelled

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
