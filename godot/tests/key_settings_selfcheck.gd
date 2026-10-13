# Headless check of the original Key Settings window (C1, DLOG/DITL 4002): the 34-cell table,
# click-select + key capture stepping on, conflict refusal at OK, Cancel restoring, Set Default
# previewing, OK persisting through Controls.overrides, and the Preferences button opening it.
#   NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/key_settings_selfcheck.gd
extends SceneTree

const Prefs = preload("res://Prefs.gd")
const Controls = preload("res://Controls.gd")
const KS = preload("res://screens/ClassicKeySettings.gd")
const ClassicPreferences = preload("res://screens/ClassicPreferences.gd")

var _fails: int = 0


func _ok(cond: bool, what: String) -> void:
	print(("PASS " if cond else "FAIL ") + what)
	if not cond:
		_fails += 1


func _key(code: int, alt: bool = false, shift: bool = false) -> InputEventKey:
	var e := InputEventKey.new()
	e.physical_keycode = code as Key
	e.alt_pressed = alt
	e.shift_pressed = shift
	e.pressed = true
	return e


func _init() -> void:
	_run.call_deferred()


func _run() -> void:
	Prefs.path = OS.get_user_data_dir() + "/key_settings_selfcheck.cfg"
	DirAccess.remove_absolute(Prefs.path)
	Prefs.load_all()
	Controls.overrides = {}

	# --- the table -------------------------------------------------------------------------
	_ok(KS.CELLS.size() == 34, "34 key cells (DITL items 4...37)")
	var blanks: int = 0
	for a in KS.CELLS:
		if str(a) == "":
			blanks += 1
		else:
			_ok(Controls.BINDINGS.has(str(a)), "cell action %s exists" % str(a))
	_ok(blanks == 3, "three blank cells (autopilot + two spare slots)")
	_ok(KS.first_conflict() == -1, "the original's defaults hold no duplicate key among the cells")
	_ok(KS.label_for("thrust") == OS.get_keycode_string(KEY_UP), "Accelerate shows Up")
	_ok(KS.label_for("eject") == "Alt+" + OS.get_keycode_string(KEY_X), "Eject shows Alt+X")
	_ok(KS.label_for("") == "", "a blank cell has no label")

	# --- capture ---------------------------------------------------------------------------
	_ok(KS.capture_of(_key(KEY_Q)) == {"field": "keys", "code": KEY_Q}, "plain key captured")
	_ok(KS.capture_of(_key(KEY_Q, true)) == {"field": "alt_keys", "code": KEY_Q}, "Alt chord captured")
	_ok(KS.capture_of(_key(KEY_Q, false, true)) == {"field": "shift_keys", "code": KEY_Q}, "Shift chord captured")
	_ok(KS.capture_of(_key(KEY_SHIFT, false, true)) == {"field": "keys", "code": KEY_SHIFT}, "bare Shift binds itself")
	_ok(KS.capture_of(_key(KEY_ESCAPE)).is_empty(), "Escape is not captured (cancels)")
	_ok(KS.capture_of(_key(KEY_1)).is_empty() and KS.capture_of(_key(KEY_CAPSLOCK)).is_empty()
		and KS.capture_of(_key(KEY_F3)).is_empty(), "1-4, Caps Lock and F1-F5 are not capturable")
	var rel: InputEventKey = _key(KEY_Q)
	rel.pressed = false
	_ok(KS.capture_of(rel).is_empty(), "key release ignored")

	# --- the window ------------------------------------------------------------------------
	var nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	var dir: String = OS.get_environment("NOVA_DATA_DIR")
	if dir == "" or not nova.load_game(dir):
		print("FAIL no game data (set NOVA_DATA_DIR)")
		quit(1)
		return
	var ks: Node = KS.new()
	root.add_child(ks)
	ks.setup(nova)
	await process_frame
	_ok(ks.dialog != null and ks.dialog.window_size.x > 500, "dialog 4002 built at its own size")
	_ok(ks._cells.size() == 34 and not (ks._cells[33] as Dictionary).is_empty(), "34 cell controls built")
	_ok(ks.dialog.item(0) != null and ks.dialog.item(1) != null and ks.dialog.item(2) != null,
		"OK / Cancel / Set Default buttons present")
	ks.select_cell(0)
	ks.capture("keys", KEY_Q)
	_ok(Controls.effective("thrust")["keys"] == [KEY_Q], "capture binds Accelerate to Q")
	_ok(ks.selected == 1, "selection steps on to the next cell")
	ks.select_cell(5)   # the blank autopilot cell
	ks.capture("keys", KEY_Q)
	_ok(ks.selected == 6, "a blank cell is skipped")
	_ok(KS.first_conflict() == -1, "Q is held once")
	ks.select_cell(1)
	ks.capture("keys", KEY_Q)   # Decelerate also Q: a duplicate is allowed while editing
	ks._ok()
	_ok(is_instance_valid(ks) and not ks._closing, "OK refused while two cells share a key")
	_ok(ks.conflict == 0 and ks.selected == 0, "the first clashing cell is selected and outlined")
	_ok(bool((ks._cells[0] as Dictionary)["outline"].visible), "red outline shown")
	ks._set_default()
	_ok(Controls.overrides.is_empty() and Controls.effective("thrust")["keys"] == [KEY_UP], "Set Default previews the defaults")
	ks.select_cell(0)
	ks.capture("keys", KEY_Q)
	var closed_flag: Array = [false]
	ks.closed.connect(func(): closed_flag[0] = true)
	ks._ok()
	_ok(closed_flag[0], "OK with no conflict closes")
	_ok(Controls.effective("thrust")["keys"] == [KEY_Q], "OK keeps the new binding in Controls.overrides")
	var ev: InputEventKey = _key(KEY_Q)
	_ok(InputMap.event_is_action(ev, "thrust"), "OK re-registered the InputMap")
	Prefs.load_all()
	_ok(Controls.effective("thrust")["keys"] == [KEY_Q], "the rebind persisted in the settings file")

	# Cancel restores the snapshot
	var ks2: Node = KS.new()
	root.add_child(ks2)
	ks2.setup(nova)
	ks2.select_cell(2)
	ks2.capture("alt_keys", KEY_T)
	_ok(Controls.effective("turn_right").has("alt_keys") and Controls.effective("turn_right")["alt_keys"] == [KEY_T], "edit applied to the draft")
	ks2._cancel()
	_ok(Controls.effective("turn_right")["keys"] == [KEY_RIGHT], "Cancel discards the edit")

	# Preferences' Key Settings button opens it
	Controls.reset_defaults()
	Prefs.save()
	Controls.register()
	var cp: Node = ClassicPreferences.new()
	root.add_child(cp)
	cp.setup(nova)
	await process_frame
	cp.dialog.item(15).pressed.emit()
	await process_frame
	var found: bool = false
	for c in cp.get_children():
		if c.get_script() == KS:
			found = true
	_ok(found, "Preferences' Key Settings button opens the 4002 window")

	print("key_settings_selfcheck: %d failure(s)" % _fails)
	quit(1 if _fails > 0 else 0)
