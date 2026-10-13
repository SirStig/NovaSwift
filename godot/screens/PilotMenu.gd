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
# Open Pilot is a real file open, as in the original: "Choose Pilot File..." runs the OS file picker
# (screens/PilotFiles.gd) starting in the Pilots folder, so a pilot opens from anywhere, an original
# EV Nova pilot (.plt / Mac) is converted and saved as .evpilot, and a compact recent list sits
# under it. "Manage Pilots..." keeps the old per-pilot list (play / delete) for the Pilots folder.
#
# Presentation: with the data loaded and Settings > Presentation > "Modern dialogs" off (the
# default) the screens are the Classic UI kit's, as in the Apple app: New Pilot is the original's
# native DLOG/DITL 3102 (3101 with several scenarios) -- Full Name, Nickname, gender, Strict Play,
# OK/Cancel -- followed by the ship-name prompt DLOG/DITL 3001; Open Pilot is the app's dialog
# panel (the original had only the Mac file picker). A "Random" button beside the gender control
# fills the name without typing (gamepad). The plain Nova Swift screens are the Apple app's modern
# path drawn with the NovaSwift UI kit (ui/novaswift/, pilot rows in ui/novaswift/pilot/): a
# "Select a Pilot" roster over the menu, the pilot's slots / backups, "Create a New Pilot" (scenario
# step when a plug-in adds scenarios, then name + nickname + gender + Strict Play, then the ship
# name). Each is a NovaDialog stacked over whatever is underneath. Same signals and the same
# method names (_show_list / _show_new / _create / ...).
#
# Loaded with preload() (no class_name) so it resolves without an editor import
# pass, like Controls.gd.
extends CanvasLayer

const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")
const ClassicDialog = preload("res://ui/classic/ClassicDialog.gd")
const PilotFiles = preload("res://screens/PilotFiles.gd")
const T = preload("res://ui/novaswift/NovaTheme.gd")
const NC = preload("res://ui/novaswift/NovaControls.gd")
const Chrome = preload("res://ui/novaswift/NovaChrome.gd")
const Alert = preload("res://ui/novaswift/NovaAlert.gd")
const PilotUI = preload("res://ui/novaswift/pilot/NovaPilotUI.gd")

## The player picked or created a pilot; the live pilot is already bound on the
## bridge, so the host only has to build the world (`make_world(-1)`).
signal pilot_chosen
## Esc / B (or Back) on the pilot list, when a host (the main menu) is listening.
signal cancelled
## A NEW pilot was written (scenario id): the host plays the intro / training offer before play.
## Only emitted when something listens; otherwise `pilot_chosen` fires as before.
signal pilot_created(scenario_id: int)
## The New Pilot form opened (true) / closed (false): the main menu reads "Creating Pilot...".
signal creating_changed(on: bool)

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
var _recent: Array = []        # rows of the Open Pilot screen (pilot_inspect_file + path)
var _picker: Node
var _import_path := ""
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
	# Plain (NovaSwift) screens: each is a NovaDialog built by _nd(); nothing to lay out up front.
	_panel = VBoxContainer.new()
	if start_new:
		_show_new()
	else:
		_show_list()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and _on_back.is_valid():
		_on_back.call()
		get_viewport().set_input_as_handled()


# --- helpers ---------------------------------------------------------------

var _ndlg := {}            # the NovaDialog currently up (plain screens)


## Open the NovaDialog for a plain screen, replacing the previous one. `_panel` becomes its body.
func _nd(title: String, width: float, buttons: Array, back: Callable = Callable()) -> Dictionary:
	if not _ndlg.is_empty() and is_instance_valid(_ndlg.root):
		_ndlg.root.queue_free()
	if _cdlg != null and is_instance_valid(_cdlg):   # a classic (DITL) dialog was up: this replaces it
		_cdlg.queue_free()
		_cdlg = null
		_cdialog = null
	_on_back = back
	_status = null
	_ndlg = Chrome.dialog(_root, {"title": title, "width": width, "buttons": buttons})
	_panel = _ndlg.body
	return _ndlg


func _clear(title: String, back: Callable = Callable()) -> void:
	_nd(title, 520.0, [], back)


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
	var l := NC.label(_panel, text, "body", "regular", color, true)
	l.add_theme_font_size_override("font_size", size)
	return l


func _focus(b: Control) -> void:
	# Deferred so the button is in the tree; guarded because a screen can be
	# replaced before the deferred call lands.
	(func(): if is_instance_valid(b) and b.is_inside_tree(): b.grab_focus()).call_deferred()


# --- open pilot (picker + recent) ----------------------------------------------------

func _refresh_pilots() -> void:
	var parsed = JSON.parse_string(_nova.pilot_list(_dir))
	_pilots = parsed if parsed is Array else []
	_recent = PilotFiles.recent_rows(_nova, _dir)


func _show_list() -> void:
	creating_changed.emit(false)
	_refresh_pilots()
	_show_roster()


## "Select a Pilot" (Apple PilotListView): one card per pilot identity, a duplicate and a delete
## button beside each, and New Pilot / Import EV Nova Pilot... / Close in the footer.
func _show_roster() -> void:
	var hosted := not cancelled.get_connections().is_empty()
	var groups := _groups()
	var specs := [
		{"text": "New Pilot", "default": groups.is_empty(), "cb": _show_new},
		{"text": "Import EV Nova Pilot…", "cb": _browse}]
	if hosted:
		specs.append({"text": "Close", "cb": _cancel})
	var d := _nd("Select a Pilot", 480.0, specs, _cancel if hosted else Callable())
	var first: Control = null
	if groups.is_empty():
		PilotUI.roster_empty(_panel)
	else:
		var list := PilotUI.roster_scroll(_panel, groups.size())
		for g in groups:
			var parts := PilotUI.roster_row(list, g, {
				"open": _show_group.bind(str(g.group)),
				"duplicate": _duplicate_group.bind(g),
				"delete": _confirm_delete_group.bind(g),
				# TODO(wiring): the bridge has no pilot_duplicate yet (Apple PilotRoster.duplicate).
				"can_duplicate": _nova.has_method("pilot_duplicate")})
			if first == null:
				first = parts.open
	var outside: Array = _recent.filter(func(r): return not str(r.path).begins_with(_dir))
	if not outside.is_empty():
		PilotUI.caps_label(_panel, "RECENT FILES")
		for r in outside:
			var rb := PilotUI.link_button(_panel, "%s — %s · %s" % [r.name, r.ship, r.system], "folder", open_path.bind(r.path), T.SECONDARY)
			if first == null:
				first = rb
	_status = NC.label(_panel, "", "caption", "regular", Color(1.0, 0.55, 0.5), true)
	_focus(first if first != null else d.buttons["New Pilot"])


func _duplicate_group(g: Dictionary) -> void:
	if _nova.has_method("pilot_duplicate") and _nova.pilot_duplicate(_dir, str(g.most_recent)) != "":
		_nova.sound_beep(1)
		_show_roster()
	else:
		_status_msg("Duplicating pilots isn't available in this build yet.")


func _confirm_delete_group(g: Dictionary) -> void:
	var n: int = (g.slots as Array).size()
	var word := "%d save slots" % n if n > 1 else "save"
	Alert.show(self, {"title": "Delete pilot?",
		"message": "“%s” — its %s and all backups will be removed. This can't be undone." % [g.name, word],
		"buttons": [{"title": "Cancel", "role": "cancel"},
			{"title": "Delete", "role": "destructive", "cb": func():
				_nova.pilot_delete(_dir, str(g.most_recent))
				_show_roster()}]})


## The OS file picker (or Godot's pad-friendly one, see PilotFiles.want_native), starting in the
## Pilots folder.
func _browse() -> void:
	_picker = PilotFiles.pick_file(self, _dir, open_path)


## Open the pilot file at `path` -- a NovaSwift .evpilot (from anywhere) or an original EV Nova
## pilot (shown for confirmation, then converted). True when a native pilot was opened.
func open_path(path: String) -> bool:
	var info = JSON.parse_string(_nova.pilot_inspect_file(path))
	var kind: String = info.get("kind", "unknown") if info is Dictionary else "unknown"
	if kind == "evpilot":
		var id: String = _nova.pilot_open_file(_dir, path)
		if id == "":
			_notice("Could not open that pilot.")
			return false
		PilotFiles.note_recent(path)
		_finish()
		return true
	if kind == "original":
		import_preview(path)
		return false
	_notice(str(info.get("error", "This is not an EV Nova or NovaSwift pilot file.")) if info is Dictionary else "Could not read that file.")
	return false


## Original EV Nova pilot: convert against the loaded data and ask before creating the NovaSwift
## pilot (Apple's PilotImportView).
func import_preview(path: String) -> void:
	var sum = JSON.parse_string(_nova.pilot_import_preview(path))
	if not (sum is Dictionary) or sum.has("error"):
		_notice("Could not import that pilot: %s" % (str(sum.get("error", "unreadable file")) if sum is Dictionary else "unreadable file"))
		return
	_import_path = path
	var lines := PackedStringArray([
		"%s%s - %s" % [sum.name, (" \"%s\"" % sum.nickname) if str(sum.nickname) != "" else "", sum.format],
		"Ship: %s" % sum.ship,
		"Credits: %s cr   Date: %s" % [_commas(int(sum.credits)), sum.date],
		"Combat rating: %s" % sum.rating,
		"Story progress: %s. Escorts: %d" % [sum.story, int(sum.escorts)]])
	if str(sum.location) != "":
		lines.append("Location: %s" % sum.location)
	for w in sum.warnings:
		lines.append("! " + str(w))
	if not (sum.unmapped as Array).is_empty():
		lines.append("Not carried over: " + "; ".join(PackedStringArray(sum.unmapped)))
	var text := "\n".join(lines)
	var d := _nd("Import EV Nova Pilot", 480.0, [
		{"text": "Cancel", "cb": _show_list},
		{"text": "Create Pilot", "default": true, "cb": import_commit}], _show_list)
	PilotUI.kv_row(_panel, "Pilot", "%s%s" % [sum.name, (" “%s”" % sum.nickname) if str(sum.nickname) != "" else ""])
	PilotUI.caps_label(_panel, str(sum.format))
	PilotUI.kv_row(_panel, "Ship", str(sum.ship))
	PilotUI.kv_row(_panel, "Credits", "%s cr" % _commas(int(sum.credits)))
	PilotUI.kv_row(_panel, "Date", str(sum.date))
	if str(sum.location) != "":
		PilotUI.kv_row(_panel, "Location", str(sum.location))
	PilotUI.kv_row(_panel, "Combat rating", str(sum.rating))
	PilotUI.kv_row(_panel, "Story progress", str(sum.story))
	PilotUI.kv_row(_panel, "Escorts", str(int(sum.escorts)))
	if not (sum.warnings as Array).is_empty():
		NC.label(_panel, "Warnings", "caption", "bold", T.AMBER)
		for w in sum.warnings:
			NC.label(_panel, "• " + str(w), "caption", "regular", T.SECONDARY, true)
	if not (sum.unmapped as Array).is_empty():
		NC.label(_panel, "Not carried over", "caption", "bold", Color(0.7, 0.7, 0.7))
		for w in sum.unmapped:
			NC.label(_panel, "• " + str(w), "caption", "regular", PilotUI.DIM, true)
	_focus(d.default)


## Write the previewed conversion into the Pilots folder as a new .evpilot and play it.
func import_commit() -> bool:
	var id: String = _nova.pilot_import_commit(_dir)
	if id == "":
		_notice("Could not create the pilot.")
		return false
	PilotFiles.note_recent(_nova.pilot_file_path(_dir, id))
	_finish()
	return true


## A one-button message on whichever screen is up; OK returns to the Open Pilot screen.
func _notice(text: String) -> void:
	_nova.sound_beep(3)
	Alert.show(self, {"title": "Open Pilot", "message": text,
		"buttons": [{"title": "OK", "role": "cancel", "cb": _show_list}]})


# --- manage pilots (the Pilots folder, one row per pilot) ------------------------------------

func _show_manage() -> void:
	_show_roster()


func _cancel() -> void:
	creating_changed.emit(false)
	cancelled.emit()
	queue_free()


func _show_pilot(p: Dictionary) -> void:
	_show_group(str(p.id))


func _load(p: Dictionary) -> void:
	if _nova.pilot_load(_dir, p.id):
		PilotFiles.note_recent(_nova.pilot_file_path(_dir, p.id))
		_finish()
	else:
		_status_msg("Could not open that pilot.")


func _confirm_delete(p: Dictionary) -> void:
	Alert.show(self, {"title": "Delete pilot?",
		"message": "“%s” — its save slots and all backups will be removed. This can't be undone." % p.name,
		"buttons": [{"title": "Cancel", "role": "cancel"},
			{"title": "Delete", "role": "destructive", "cb": func():
				_nova.pilot_delete(_dir, p.id)
				_show_roster()}]})


# --- new pilot -----------------------------------------------------------------

func _show_new() -> void:
	creating_changed.emit(true)
	var parsed = JSON.parse_string(_nova.pilot_scenarios())
	_scenarios = parsed if parsed is Array else []
	if _classic:
		_c_new()
		return
	if _scenarios.is_empty():
		var nd := _nd("No Scenarios", 420.0, [{"text": "OK", "default": true, "cb": _show_list}], _show_list)
		NC.label(_panel, "No starting scenarios were found in the game data. Import your EV Nova data first.", "body", "regular", T.WHITE, true)
		return
	_scenario_index = 0
	_is_male = true
	_strict = false
	# NewPilotView: with several scenarios a "Select a Scenario" step comes first (a plug-in added
	# them); a single scenario goes straight to the name step.
	if _scenarios.size() > 1:
		_new_scenario_step()
	else:
		_new_name_step()


var _start_btn: Control
var _strict_btn: Control
var _ship_edit: LineEdit
var _pending_name := ""
var _pending_nick := ""


func _scenario_summary(sc: Dictionary) -> String:
	return "%s cr · %s" % [_commas(int(sc.get("cash", 0))), sc.get("ship", "ship")]


func _new_scenario_step() -> void:
	var d := _nd("Select a Scenario", 500.0, [
		{"text": "Cancel", "cb": _show_list},
		{"text": "Continue", "default": true, "cb": _new_name_step}], _show_list)
	var rows: Array = []
	for i in _scenarios.size():
		var sc: Dictionary = _scenarios[i]
		var b := NC.select_row(_panel, str(sc.name), "", i == _scenario_index)
		b.custom_minimum_size = Vector2(0, 44)
		var cap := NC.caption(b, _scenario_summary(sc))
		cap.set_anchors_preset(Control.PRESET_BOTTOM_WIDE)
		cap.offset_left = 10
		cap.offset_bottom = -4
		cap.add_theme_font_size_override("font_size", 11)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		rows.append(b)
		b.pressed.connect(func():
			_scenario_index = i
			for j in rows.size():
				rows[j].set_pressed_no_signal(j == i))
	_focus(rows[_scenario_index])


## "Create a New Pilot": Full Name (+ dice), Nickname, Gender, Strict Play, scenario summary.
func _new_name_step() -> void:
	var back := _new_scenario_step if _scenarios.size() > 1 else _show_list
	var sc: Dictionary = _scenarios[_scenario_index]
	var d := _nd("Create a New Pilot", 400.0, [
		{"text": "Cancel", "cb": back},
		{"text": "Create", "default": true, "cb": _new_confirm_name}], back)
	_start_btn = d.default
	var r1 := HBoxContainer.new()
	r1.add_theme_constant_override("separation", 10)
	_panel.add_child(r1)
	NC.label(r1, "Full Name:", "caption", "regular").custom_minimum_size = Vector2(84, 0)
	_name_edit = NC.text_field("Captain", _pending_name if _pending_name != "" else _nova.pilot_default_name(0))
	_name_edit.max_length = _nova.pilot_max_name_length()
	_name_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_edit.text_submitted.connect(func(_t): _new_confirm_name())
	r1.add_child(_name_edit)
	var dice := NC.icon_button("dice", func(): _name_edit.text = _nova.pilot_random_name(), T.AMBER, 34, 18)
	dice.add_theme_stylebox_override("normal", T.box(T.FIELD_BG, 5, T.FIELD_BORDER, 1))
	dice.tooltip_text = "Random name"
	r1.add_child(dice)
	var r2 := HBoxContainer.new()
	r2.add_theme_constant_override("separation", 10)
	_panel.add_child(r2)
	NC.label(r2, "Nickname:", "caption", "regular").custom_minimum_size = Vector2(84, 0)
	_nick_edit = NC.text_field("", _pending_nick if _pending_nick != "" else _nova.pilot_default_name(1))
	_nick_edit.max_length = _nova.pilot_max_name_length()
	_nick_edit.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r2.add_child(_nick_edit)
	var r3 := HBoxContainer.new()
	r3.add_theme_constant_override("separation", 12)
	_panel.add_child(r3)
	NC.label(r3, "Gender:", "caption", "regular").custom_minimum_size = Vector2(84, 0)
	var seg := NC.segmented(r3, ["Male", "Female"], 0 if _is_male else 1, func(i: int): _is_male = i == 0)
	seg.size_flags_horizontal = Control.SIZE_FILL
	seg.custom_minimum_size = Vector2(200, 0)
	_strict_btn = NC.toggle(_panel, "Strict Play", _strict, func(on: bool): _strict = on)
	_strict_btn.custom_minimum_size = Vector2(200, 28)
	_strict_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	NC.caption(_panel, _scenario_summary(sc))
	_status = NC.label(_panel, "", "caption", "regular", Color(1.0, 0.55, 0.5), true)
	_focus(_name_edit)


func _new_confirm_name() -> void:
	var nm := _name_edit.text.strip_edges() if is_instance_valid(_name_edit) else _pending_name
	if nm == "":
		_status_msg("Enter a name, or press the dice.")
		return
	_pending_name = nm
	_pending_nick = _nick_edit.text.strip_edges() if is_instance_valid(_nick_edit) else _pending_nick
	_new_ship_step()


## The ship-name prompt after the pilot dialog (STR# 2002 #121); Cancel abandons the new pilot.
func _new_ship_step() -> void:
	var sc: Dictionary = _scenarios[_scenario_index]
	var d := _nd("", 400.0, [
		{"text": "Cancel", "cb": _show_list},
		{"text": "OK", "default": true, "cb": _create}], _new_name_step)
	NC.label(_panel, _nova.pilot_ship_name_prompt(int(sc.id)), "caption", "regular", T.WHITE, true).custom_minimum_size = Vector2(360, 0)
	_ship_edit = NC.text_field("", _nova.pilot_default_name(2))
	_ship_edit.max_length = 64
	_ship_edit.text_submitted.connect(func(_t): _create())
	_panel.add_child(_ship_edit)
	_status = NC.label(_panel, "", "caption", "regular", Color(1.0, 0.55, 0.5), true)
	_focus(_ship_edit)


func _refresh_new() -> void:
	pass


func _cycle_scenario() -> void:
	_scenario_index = (_scenario_index + 1) % _scenarios.size()


func _create() -> void:
	if _classic:
		_c_name_ok()
		return
	var nm := _name_edit.text.strip_edges() if is_instance_valid(_name_edit) else _pending_name
	if nm == "":
		_status_msg("Enter a name, or press Random name.")
		return
	var s: Dictionary = _scenarios[_scenario_index]
	# Nickname and ship name: the fields of the steps above, else the STR# 128 defaults (as when the
	# player accepts the prefilled values).
	var nick: String = _nick_edit.text.strip_edges() if is_instance_valid(_nick_edit) else (_pending_nick if _pending_nick != "" else _nova.pilot_default_name(1))
	var ship: String = _ship_edit.text.strip_edges() if is_instance_valid(_ship_edit) else _nova.pilot_default_name(2)
	var id: String = _nova.pilot_create_strict(_dir, int(s.id), nm, _is_male, nick, ship, _strict)
	if id == "":
		_status_msg("Could not create the pilot.")
		return
	PilotFiles.note_recent(_nova.pilot_file_path(_dir, id))
	_finish_new(int(s.id))


func _status_msg(t: String) -> void:
	_nova.sound_beep(3)   # a rejected form keeps snd 152
	if _status != null:
		_status.text = t


func _finish() -> void:
	creating_changed.emit(false)
	pilot_chosen.emit()
	queue_free()


## A new pilot was written: tell a host that plays the intro (Shell), else just choose it.
func _finish_new(scenario_id: int) -> void:
	if pilot_created.get_connections().is_empty():
		_finish()
		return
	creating_changed.emit(false)
	pilot_created.emit(scenario_id)
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
	if not _ndlg.is_empty() and is_instance_valid(_ndlg.root):
		_ndlg.root.queue_free()
		_ndlg = {}
	_on_back = Callable()
	if _cdlg != null and is_instance_valid(_cdlg):
		_cdlg.queue_free()
	_cdialog = d
	_cdlg = ClassicDialog.modal(_root, d, 0.55 if over_menu else 0.0)


func _c_list() -> void:
	var hosted := not cancelled.get_connections().is_empty()
	var body := [{"label": "Choose Pilot File...", "action": _browse}]
	for r in _recent:
		body.append({"label": "%s - %s" % [r.name, r.ship], "action": open_path.bind(r.path)})
	var footer := [{"label": "New Pilot", "action": _show_new, "default": _recent.is_empty()}]
	if not _pilots.is_empty():
		footer.append({"label": "Manage", "action": _show_manage})
	if hosted:
		footer.append({"label": "Back", "action": _cancel, "cancel": true})
	var opts := {"title": "Open Pilot", "width": 460, "body_buttons": body, "body_buttons_width": 360,
		"footer_buttons": footer,
		"text": "Pick a pilot file from anywhere, or one of your recent pilots." if not _recent.is_empty()
			else "Pick a pilot file from anywhere, or create a new pilot."}
	_c_show(ClassicDialog.panel(_nova, opts))
	(func(): if is_instance_valid(_cdialog): _cdialog.item(1 if not _recent.is_empty() else 0).grab_focus()).call_deferred()


## The per-pilot list of the Pilots folder (play / delete), paged like the original's lists.
func _c_manage() -> void:
	_refresh_pilots()
	_page = clampi(_page, 0, maxi(0, (_pilots.size() - 1) / PAGE))
	var body := []
	for i in range(_page * PAGE, mini(_pilots.size(), (_page + 1) * PAGE)):
		var p: Dictionary = _pilots[i]
		body.append({"label": "%s - %s" % [p.name, p.ship], "action": _show_pilot.bind(p)})
	var footer := []
	if _pilots.size() > PAGE:
		footer.append({"label": "More", "action": func():
			_page = (_page + 1) % ((_pilots.size() + PAGE - 1) / PAGE)
			_c_manage()})
	footer.append({"label": "Back", "action": _show_list, "cancel": true})
	var opts := {"title": "Pilots", "width": 460, "body_buttons": body, "body_buttons_width": 360,
		"footer_buttons": footer}
	if _pilots.is_empty():
		opts["text"] = "No pilots in the Pilots folder."
	_c_show(ClassicDialog.panel(_nova, opts))
	if not body.is_empty():
		(func(): if is_instance_valid(_cdialog): _cdialog.item(0).grab_focus()).call_deferred()


func _c_pilot(p: Dictionary) -> void:
	var text := "%s - %s. %s credits - %s. Scenario: %s - saved %s" % [
		p.ship, p.system, _commas(int(p.credits)), p.rating,
		p.scenario if p.scenario != "" else "-", p.updated]
	_c_show(ClassicDialog.panel(_nova, {"title": p.name, "width": 460, "text": text,
		"body_buttons": [{"label": "Play", "action": _load.bind(p)},
			{"label": "Slots & Backups", "action": _show_group.bind(p.id)},
			{"label": "Delete…", "action": _confirm_delete.bind(p)}],
		"footer_buttons": [{"label": "Back", "action": _show_manage, "cancel": true}]}))


## The original's yes/no prompt (DLOG 3002); the safe answer (Cancel) holds the focus.
func _c_confirm_delete(p: Dictionary) -> void:
	var d := ClassicDialog.confirm(_nova,
		"Delete %s? This removes the pilot, every save slot and all backups. It cannot be undone." % p.name,
		{"ok": "Delete", "cancel": "Keep"})
	d.actions[0] = func():
		_nova.pilot_delete(_dir, p.id)
		_show_manage()
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
	var keep_name: String = _name_edit.text if is_instance_valid(_name_edit) and _name_edit.is_inside_tree() else _nova.pilot_default_name(0)
	var keep_nick: String = _nick_edit.text if is_instance_valid(_nick_edit) and _nick_edit.is_inside_tree() else _nova.pilot_default_name(1)
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
	var nick: String = _nick_edit.text.strip_edges() if is_instance_valid(_nick_edit) else _nova.pilot_default_name(1)
	var id: String = _nova.pilot_create_strict(_dir, int(s.id), nm, _is_male, nick,
		ClassicDialog.prompt_answer(ship_name.strip_edges()), _strict)
	if id == "":
		_nova.sound_beep(3)
		_show_new()
		return
	PilotFiles.note_recent(_nova.pilot_file_path(_dir, id))
	_finish_new(int(s.id))


# --- save slots and backups (Apple PilotGroupDetailView / PilotBackupsView) ---------------------
#
# A pilot is a group of up to 3 independent save slots (Slot 1 is the original), each with its own
# rotating backup history. The group screen plays a slot, adds one (a copy of the most recent),
# deletes one (when there are several), renames the pilot, and opens the backups browser: every
# backup of every slot, newest first; picking one rolls that slot back to it (the current state is
# backed up first) and plays it. Classic dialogs or the plain Nova Swift panel; keyboard + pad only
# need focus navigation.

var _group_id := ""            # the group on screen (re-read from the bridge after every change)
var _backup_page := 0


func _groups() -> Array:
	var parsed = JSON.parse_string(_nova.pilot_groups(_dir))
	return parsed if parsed is Array else []


## The group row containing save id `any_id` (a slot id), or {}.
func _group_row(any_id: String) -> Dictionary:
	for g in _groups():
		if str(g.group) == any_id:
			return g
		for sl in g.slots:
			if str(sl.id) == any_id:
				return g
	return {}


func _slot_text(sl: Dictionary) -> String:
	return "%s - %s. %s cr - %s - %s" % [sl.ship, sl.system if str(sl.system) != "" else "-",
		_commas(int(sl.credits)), sl.rating, sl.updated]


## The group detail screen for the pilot owning save `any_id`.
func _show_group(any_id: String) -> void:
	var g := _group_row(any_id)
	if g.is_empty():
		_show_manage()
		return
	_group_id = str(g.group)
	var slots: Array = g.slots
	# PilotGroupDetailView: header (scenario / Rename), SAVES, one row per slot, New Save Slot,
	# View All Backups; footer Back / Continue (the most recent slot).
	var d := _nd(str(g.name), 480.0, [
		{"text": "Back", "cb": _show_roster},
		{"text": "Continue", "default": true, "cb": _play_slot.bind(str(g.most_recent))}], _show_roster)
	PilotUI.group_header(_panel, str(g.scenario), _rename_group.bind(str(g.name)))
	PilotUI.caps_label(_panel, "SAVES")
	var first: Control = null
	for sl in slots:
		var parts := PilotUI.slot_row(_panel, sl, {"play": _play_slot.bind(str(sl.id)),
			"delete": _confirm_delete_slot.bind(str(sl.id), int(sl.slot)), "multiple": slots.size() > 1})
		if first == null:
			first = parts.play
	if bool(g.can_add):
		PilotUI.link_button(_panel, "New Save Slot (%d/%d)" % [slots.size(), int(g.max_slots)], "plus.square.on.square", _add_slot)
	PilotUI.link_button(_panel, "View All Backups", "clock.arrow.circlepath", _show_backups.bind(0), T.SECONDARY)
	_status = NC.label(_panel, "", "caption", "regular", Color(1.0, 0.55, 0.5), true)
	_focus(d.default if first == null else first)


func _play_slot(slot_id: String) -> void:
	if _nova.pilot_load(_dir, slot_id):
		PilotFiles.note_recent(_nova.pilot_file_path(_dir, slot_id))
		_finish()
	else:
		_notice("Could not open that pilot.")


func _add_slot() -> void:
	_nova.sound_beep(1)
	if _nova.pilot_add_slot(_dir, _group_id) == "":
		_nova.sound_beep(3)
	_show_group(_group_id)


## "Delete this save slot?" -- the safe answer (Keep) holds the focus.
func _confirm_delete_slot(slot_id: String, slot: int) -> void:
	var msg := "Delete this save slot? Slot %d and its backups will be removed. This can't be undone." % slot
	var back := _show_group.bind(_group_id)
	var del := func():
		_nova.pilot_delete_slot(_dir, slot_id)
		_show_group(_group_id)
	Alert.show(self, {"title": "Delete this save slot?",
		"message": "This slot and its backups will be removed. This can't be undone.",
		"buttons": [{"title": "Cancel", "role": "cancel"}, {"title": "Delete", "role": "destructive", "cb": del}]})


func _rename_group(current: String) -> void:
	Alert.show(self, {"title": "Rename Pilot", "text": current, "buttons": [
		{"title": "Cancel", "role": "cancel"},
		{"title": "Save", "cb": func(t: String): _do_rename(t)}]})


func _do_rename(name_text: String) -> void:
	var nm := name_text.strip_edges()
	if nm != "":
		_nova.pilot_rename_group(_dir, _group_id, nm)
	_show_group(_group_id)


## Every backup across the group's slots, newest first, paged like the other lists.
func _show_backups(page: int) -> void:
	var parsed = JSON.parse_string(_nova.pilot_group_history(_dir, _group_id))
	var rows: Array = parsed if parsed is Array else []
	_backup_page = clampi(page, 0, maxi(0, (rows.size() - 1) / PAGE))
	var empty_text := "No backups yet -- they are made automatically each time you launch from a spaceport, and on manual saves."
	var slice := rows.slice(_backup_page * PAGE, (_backup_page + 1) * PAGE)
	var more := rows.size() > PAGE
	var bspecs := []
	if more:
		bspecs.append({"text": "More", "cb": func(): _show_backups((_backup_page + 1) % ((rows.size() + PAGE - 1) / PAGE))})
	bspecs.append({"text": "Close", "default": true, "cb": _show_group.bind(_group_id)})
	var d := _nd("Backups", 480.0, bspecs, _show_group.bind(_group_id))
	var first: Control = null
	if rows.is_empty():
		var el := NC.label(_panel, "No backups yet — they're made automatically on landing, jumping, or manual save.", "caption", "regular", T.SECONDARY, true)
		el.custom_minimum_size = Vector2(380, 0)
	for r in slice:
		var b := PilotUI.backup_row(_panel, r, "Slot %d" % int(r.slot), _restore.bind(str(r.slot_id), str(r.path)))
		if first == null:
			first = b
	_status = NC.label(_panel, "", "caption", "regular", Color(1.0, 0.55, 0.5), true)
	_focus(first if first != null else d.default)


## Roll `slot_id` back to the backup file and play it (Apple: restore, then model.play).
func _restore(slot_id: String, path: String) -> void:
	if _nova.pilot_restore(_dir, slot_id, path):
		_play_slot(slot_id)
	else:
		_notice("Could not restore that backup.")
