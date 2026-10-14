# Headless check of the settings plumbing (SettingsPlumbing.gd -> NovaWorld.apply_settings) and the
# gamepad on-screen keyboard (ui/PadKeyboard.gd). Each wired pref must change the engine-side value
# (read back through the bridge), game speed 1x/2x via Caps Lock must change the tick rate, the
# colorblind shader must toggle, and the pad keyboard must open on pad-focus of a LineEdit, type and submit.
#   NOVA_DATA_DIR=$PWD/data/base NOVA_PILOTS_DIR=<scratch> godot --headless --path godot -s res://tests/settings_plumbing_selfcheck.gd
extends SceneTree

const Prefs = preload("res://Prefs.gd")

var nova
var plumb
var pk
var ok := true
var submitted := ""
var changed_text := ""


func _init() -> void:
	_run()


func _check(label: String, cond: bool, detail := "") -> bool:
	print(("  ok   " if cond else "  FAIL ") + label + ((" -- " + detail) if detail != "" else ""))
	if not cond:
		ok = false
	return cond


func _state() -> Dictionary:
	return JSON.parse_string(nova.settings_state())


func _pref(section: String, key: String, value: Variant) -> void:
	Prefs.set_value(section, key, value)
	plumb.apply_now()


func _frames(n := 3) -> void:
	for i in n:
		await process_frame


## Fixed ticks run by 30 display frames of 1/30 s (one second of wall time).
func _ticks_per_second() -> int:
	var before: int = _state().ticks
	for i in 30:
		nova.step(1.0 / 30.0)
	return int(_state().ticks) - before


func _button_with_text(parent: Node, text: String) -> Button:
	for b in parent.find_children("*", "Button", true, false):
		if b.text == text:
			return b
	return null


func _run() -> void:
	await process_frame
	Prefs.path = OS.get_environment("NOVA_PILOTS_DIR") + "/settings_selfcheck.cfg"
	DirAccess.remove_absolute(Prefs.path)
	Prefs.load_all()
	plumb = root.get_node("SettingsPlumbing")
	pk = root.get_node("PadKeyboard")
	_check("autoloads present", plumb != null and pk != null)
	nova = ClassDB.instantiate("NovaWorld")
	root.add_child(nova)
	await _frames(2)
	_check("plumbing adopted the NovaWorld", plumb.nova == nova)
	var data := OS.get_environment("NOVA_DATA_DIR")
	if data == "":
		data = ProjectSettings.globalize_path("res://") + "../data/base"
	_check("load_game", nova.load_game(data))
	_check("make_world", nova.make_world(-1))

	print("-- defaults match Apple")
	plumb.apply_now()
	var st := _state()
	_check("difficulty normal -> damage 1.0", is_equal_approx(st.playerDamageScale, 1.0))
	_check("aliveness original -> original spawner, scale 1", st.spawnModel == "original" and is_equal_approx(st.populationScale, 1.0))
	_check("game speed x1 -> multiplier 1", st.gameSpeed == "x1")
	_check("no enhancement on", not st.enhancements.values().has(true), str(st.enhancements))

	print("-- difficulty")
	for pair in [["veryEasy", 0.3], ["easy", 0.6], ["hard", 1.5], ["normal", 1.0]]:
		_pref("gameplay", "difficulty", pair[0])
		_check("difficulty %s -> player damage x%s" % [pair[0], pair[1]], is_equal_approx(_state().playerDamageScale, pair[1]))
	_pref("gameplay", "difficulty", "hard")
	nova.make_world(-1)
	_check("a rebuilt world keeps Hard", is_equal_approx(_state().playerDamageScale, 1.5))
	_pref("gameplay", "difficulty", "normal")

	print("-- system aliveness")
	_pref("gameplay", "system_aliveness", "bustling")
	st = _state()
	_check("bustling -> port spawner x1.35", st.spawnModel == "port" and is_equal_approx(st.populationScale, 1.35), str(st.populationScale))
	_pref("gameplay", "system_aliveness", "authentic")
	_check("quiet -> x0.55", is_equal_approx(_state().populationScale, 0.55))
	nova.make_world(-1)
	_check("a rebuilt world keeps Quiet", is_equal_approx(_state().populationScale, 0.55) and _state().spawnModel == "port")
	_pref("gameplay", "system_aliveness", "original")

	print("-- game speed and Caps Lock 2x")
	nova.make_world(-1)
	var t1 := _ticks_per_second()
	_check("1x: 1 s -> 30 ticks", t1 == 30, str(t1))
	_check("multiplier 1", is_equal_approx(nova.speed_multiplier(), 1.0) and not nova.x2_active())
	plumb.set_caps_lock(true)
	var t2 := _ticks_per_second()
	_check("Caps Lock: 1 s -> 60 ticks", t2 == 60, str(t2))
	_check("multiplier 2, x2 indicator", is_equal_approx(nova.speed_multiplier(), 2.0) and nova.x2_active())
	_check("world time scale 2", is_equal_approx(_state().timeScale, 2.0))
	plumb.set_caps_lock(false)
	_pref("gameplay", "game_speed", "x4")
	var t4 := _ticks_per_second()
	_check("setting 4x: 1 s -> 120 ticks", t4 == 120, str(t4))
	plumb.set_caps_lock(true)
	var t8 := _ticks_per_second()
	_check("4x + Caps Lock -> 8x: 240 ticks", t8 == 240 and is_equal_approx(nova.speed_multiplier(), 8.0), str(t8))
	plumb.set_caps_lock(false)
	_pref("gameplay", "game_speed", "x0_5")
	var th := _ticks_per_second()
	_check("0.5x: 1 s -> 15 ticks", th == 15, str(th))
	_pref("gameplay", "game_speed", "x1")
	_check("back to 1x", _ticks_per_second() == 30 and is_equal_approx(nova.speed_multiplier(), 1.0))

	print("-- invert turn")
	nova.make_world(-1)
	var a0: float = nova.player_angle()
	nova.set_intent(true, false, false, false, false, false, false)   # turn left
	for i in 6:
		nova.step(1.0 / 30.0)
	var left: float = angle_difference(a0, nova.player_angle())
	_pref("input", "invert_turn", true)
	a0 = nova.player_angle()
	nova.set_intent(true, false, false, false, false, false, false)
	for i in 6:
		nova.step(1.0 / 30.0)
	var inv: float = angle_difference(a0, nova.player_angle())
	_check("turn-left turns one way normally, the other inverted", left * inv < 0.0 and absf(left) > 0.01, "%f vs %f" % [left, inv])
	_pref("input", "invert_turn", false)
	nova.set_intent(false, false, false, false, false, false, false)

	print("-- mouse aim")
	nova.make_world(-1)
	a0 = nova.player_angle()
	nova.set_mouse_aim(true, a0 + deg_to_rad(60.0))
	_check("state reports mouse aiming", _state().mouseAiming)
	for i in 30:
		nova.set_intent(false, false, false, false, false, false, false)
		nova.step(1.0 / 30.0)
	_check("the ship turned toward the pointer heading", absf(angle_difference(nova.player_angle(), a0 + deg_to_rad(60.0))) < deg_to_rad(8.0),
		"%f" % rad_to_deg(angle_difference(nova.player_angle(), a0 + deg_to_rad(60.0))))
	nova.set_mouse_aim(false, 0.0)
	_check("cleared", not _state().mouseAiming)

	print("-- landing: forgiving, confirm, auto")
	var targets: PackedInt32Array = nova.debug_land_targets()
	_check("system has land targets", targets.size() > 0)
	var pad_id := -1
	for id in targets:
		if nova.debug_place_player_at_spob(id):
			nova.set_intent(false, false, false, false, false, false, false)
			nova.step(1.0 / 30.0)
			if nova.nearest_landable_spob_id() == id:
				pad_id = id
				break
	_check("found a landable pad", pad_id >= 0)
	nova.make_world(-1)
	_pref("gameplay", "forgiving_landing", true)
	_check("forgiving landing reaches the world", _state().enhancements.forgivingLanding and _state().worldEnhancementsMatch)
	nova.debug_place_player_at_spob(pad_id)
	var r = JSON.parse_string(nova.press_land())
	_check("forgiving: ONE Land press sets down", r.result == "landed" and nova.is_landed(), str(r))
	nova.launch()
	_pref("gameplay", "forgiving_landing", false)
	nova.debug_place_player_at_spob(pad_id)
	r = JSON.parse_string(nova.press_land())
	_check("original: first press only requests clearance", r.result == "messages" and not nova.is_landed(), str(r))
	nova.step(1.0 / 30.0)   # the 250 px arm grants it on the next tick
	r = JSON.parse_string(nova.press_land())
	_check("original: second press lands", r.result == "landed" and nova.is_landed(), str(r))
	nova.launch()

	_pref("gameplay", "forgiving_landing", true)
	_pref("gameplay", "confirm_landing", true)
	nova.debug_place_player_at_spob(pad_id)
	r = JSON.parse_string(nova.press_land())
	_check("confirm landing: press asks first", r.result == "confirm" and not nova.is_landed() and nova.pending_land_confirm() == pad_id, str(r))
	await _frames(3)
	_check("the Land here? dialog is up", root.get_node_or_null("SettingsPlumbing/LandConfirm") != null)
	var cancel_btn: Button = root.get_node("SettingsPlumbing/LandConfirm").find_child("Cancel", true, false)
	cancel_btn.pressed.emit()
	await _frames(3)
	_check("cancel: still flying, dialog gone", not nova.is_landed() and nova.pending_land_confirm() < 0
		and root.get_node_or_null("SettingsPlumbing/LandConfirm") == null)
	r = JSON.parse_string(nova.press_land())
	await _frames(3)
	var land_btn: Button = root.get_node("SettingsPlumbing/LandConfirm").find_child("Land", true, false)
	land_btn.pressed.emit()
	await _frames(2)
	_check("Land: touches down", nova.is_landed())
	nova.launch()
	_pref("gameplay", "confirm_landing", false)
	_pref("gameplay", "forgiving_landing", false)

	_pref("gameplay", "auto_landing", true)
	nova.make_world(-1)
	var pad_pos: Vector2 = nova.debug_stellar_position(pad_id)
	nova.debug_teleport_player(pad_pos.x + 900.0, pad_pos.y + 700.0)
	nova.select_nav_stellar(0)
	nova.debug_select_stellar(pad_id)
	r = JSON.parse_string(nova.press_land())
	_check("auto-landing: Land engages the autopilot", r.result == "autoland" and nova.is_auto_landing(), str(r))
	var landed := false
	for i in 4000:
		nova.set_intent(false, false, false, false, false, false, false)
		nova.step(1.0 / 30.0)
		if nova.is_landed():
			landed = true
			break
	_check("the autopilot flew there and set down", landed and nova.landed_spob_id() == pad_id)
	nova.launch()
	nova.debug_teleport_player(pad_pos.x + 900.0, pad_pos.y + 700.0)
	nova.debug_select_stellar(pad_id)
	nova.press_land()
	nova.set_intent(true, false, false, false, false, false, false)
	nova.step(1.0 / 30.0)
	_check("a manual turn hands control back", not nova.is_auto_landing())
	_pref("gameplay", "auto_landing", false)

	print("-- enhancements and flags reach the engine")
	_pref("gameplay", "nearest_first_targeting", true)
	_check("nearest-first targeting", _state().enhancements.nearestFirstTargeting)
	_pref("gameplay", "formation_flying", true)
	_check("formation flying (rebuilds the galaxy)", _state().enhancements.formationFlying and _state().formationFlying)
	_pref("gameplay", "auto_route_plotting", true)
	_pref("gameplay", "quick_hyperjump", true)
	_pref("gameplay", "auto_target_after_firing", true)
	st = _state()
	_check("auto-route / quick hyperjump / auto-target flags", st.enhancements.autoRoutePlotting and st.enhancements.quickHyperjump and st.autoTargetAfterFiring)
	_pref("gameplay", "frequent_autosave", true)
	_check("frequent autosave still wired", _state().enhancements.frequentAutosave)
	for k in ["nearest_first_targeting", "formation_flying", "auto_route_plotting", "quick_hyperjump", "auto_target_after_firing", "frequent_autosave"]:
		Prefs.set_value("gameplay", k, false)
	plumb.apply_now()
	_check("all off again", not _state().enhancements.values().has(true))

	print("-- colorblind filter")
	_check("none: no overlay", plumb.cb_layer == null or not plumb.cb_layer.visible)
	var rows: PackedFloat32Array = nova.colorblind_matrix("tritanopia")
	_check("engine matrix: 16 floats, tritanopia G row (-0.5, 1, 0.5, 0)", rows.size() == 16 and rows[4] == -0.5 and rows[5] == 1.0 and rows[6] == 0.5)
	_pref("accessibility", "colorblind_mode", "tritanopia")
	_check("tritanopia: overlay on with that matrix", plumb.cb_layer != null and plumb.cb_layer.visible)
	var mat: ShaderMaterial = plumb.cb_layer.get_node("Rect").material
	_check("shader params carry the rows", mat.get_shader_parameter("row_g") == Vector4(-0.5, 1.0, 0.5, 0.0), str(mat.get_shader_parameter("row_g")))
	_pref("accessibility", "colorblind_mode", "protanopia")
	_check("protanopia B row (0.5, -0.5, 1, 0)", mat.get_shader_parameter("row_b") == Vector4(0.5, -0.5, 1.0, 0.0))
	_pref("accessibility", "colorblind_mode", "none")
	_check("none: overlay off again", not plumb.cb_layer.visible)

	print("-- presentation prefs")
	_pref("graphics", "show_fps", true)
	_check("FPS counter visible", plumb.fps_label != null and plumb.fps_label.visible)
	_pref("graphics", "show_fps", false)
	_check("FPS counter hidden", not plumb.fps_label.visible)
	_pref("interface", "ui_scale", 1.25)
	_check("UI scale -> window content scale factor", is_equal_approx(root.content_scale_factor, 1.25))
	_pref("interface", "ui_scale", 1.0)
	_check("larger HUD -> x1.28", is_equal_approx(Prefs.hud_scale(), 1.0))
	Prefs.set_value("accessibility", "larger_hud", true)
	_check("larger HUD on", is_equal_approx(Prefs.hud_scale(), 1.28))
	Prefs.set_value("accessibility", "larger_hud", false)
	var hub_hits := [0]
	var hub_cb := func(_s, _k): hub_hits[0] += 1
	Prefs.hub.changed.connect(hub_cb)
	Prefs.set_value("interface", "show_radar", false)
	Prefs.set_value("interface", "show_radar", true)
	_check("Prefs.hub.changed fires per set_value", hub_hits[0] == 2)
	Prefs.hub.changed.disconnect(hub_cb)   # a lambda left on the static hub outlives the script at quit

	await _check_pad_keyboard()

	DirAccess.remove_absolute(Prefs.path)
	print("settings plumbing selfcheck: %s" % ("0 failure(s)" if ok else "FAILED"))
	quit(0 if ok else 1)


func _check_pad_keyboard() -> void:
	print("-- pad keyboard")
	var host := Control.new()
	host.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	root.add_child(host)
	var le := LineEdit.new()
	le.placeholder_text = "Pilot name"
	le.text = "Captain"
	le.max_length = 12
	le.text_submitted.connect(func(t): submitted = t)
	le.text_changed.connect(func(t): changed_text = t)
	host.add_child(le)
	var other := Button.new()   # a neutral place for focus to rest
	host.add_child(other)
	pk.assume_pad = true

	# Mouse / keyboard focus does not open it.
	var key := InputEventKey.new()
	key.keycode = KEY_A
	key.pressed = true
	Input.parse_input_event(key)
	await _frames(2)
	_check("last input keyboard -> pad_active false", not pk.pad_active())
	le.grab_focus()
	await _frames(3)
	_check("focus with the keyboard: stays closed", not pk.is_open())
	other.grab_focus()
	await _frames(2)

	# Gamepad input, then focus.
	var pad := InputEventJoypadButton.new()
	pad.button_index = JOY_BUTTON_DPAD_DOWN
	pad.pressed = true
	Input.parse_input_event(pad)
	await _frames(2)
	_check("after a pad press -> pad_active", pk.pad_active())
	le.grab_focus()
	await _frames(3)
	_check("focusing a LineEdit with a pad opens the keyboard", pk.is_open())
	_check("pre-filled with the field's text", pk.text() == "Captain")
	_check("suggestions row offered for a pilot-name field", pk._chips.visible and pk._chips.get_child_count() >= 2)
	pk.backspace()
	pk.backspace()
	pk.type_text("n")
	pk.type_text("!")
	_check("typing edits the entry line", pk.text() == "Captan!", pk.text())
	pk.type_text("1234567890")
	_check("max_length respected", pk.text().length() == 12, pk.text())
	var done: Button = pk._root.find_child("Done", true, false)
	_check("Done / Cancel buttons exist", done != null and pk._root.find_child("Cancel", true, false) != null)
	done.pressed.emit()
	await _frames(3)
	_check("Done closes, writes back and submits", not pk.is_open() and le.text == "Captan!12345" and submitted == "Captan!12345" and changed_text == "Captan!12345",
		"%s / %s" % [le.text, submitted])
	_check("focus returned to the field without reopening", le.has_focus() and not pk.is_open())

	# Cancel leaves the field alone.
	pk.open_for(le)
	await _frames(2)
	pk.type_text("zzz")
	var cancel: Button = pk._root.find_child("Cancel", true, false)
	cancel.pressed.emit()
	await _frames(2)
	_check("Cancel leaves the text untouched", not pk.is_open() and le.text == "Captan!12345")

	# B (ui_cancel) cancels; Start commits; Y deletes; X spaces.
	pk.open_for(le)
	await _frames(2)
	var yb := InputEventJoypadButton.new()
	yb.button_index = JOY_BUTTON_Y
	yb.pressed = true
	Input.parse_input_event(yb)
	await _frames(1)
	_check("Y deletes a character", pk.text() == "Captan!1234")
	var xb := InputEventJoypadButton.new()
	xb.button_index = JOY_BUTTON_X
	xb.pressed = true
	Input.parse_input_event(xb)
	await _frames(1)
	_check("X types a space", pk.text() == "Captan!1234 ")
	var st := InputEventJoypadButton.new()
	st.button_index = JOY_BUTTON_START
	st.pressed = true
	Input.parse_input_event(st)
	await _frames(2)
	_check("Start commits", not pk.is_open() and le.text == "Captan!1234 ")
	pk.open_for(le)
	await _frames(2)
	var bb := InputEventJoypadButton.new()
	bb.button_index = JOY_BUTTON_B
	bb.pressed = true
	Input.parse_input_event(bb)
	await _frames(2)
	_check("B cancels", not pk.is_open() and le.text == "Captan!1234 ")

	# A on the focused field re-opens it.
	var a := InputEventJoypadButton.new()
	a.button_index = JOY_BUTTON_A
	a.pressed = true
	Input.parse_input_event(a)
	await _frames(3)
	_check("A on the focused field reopens it", pk.is_open())
	pk.close(false)
	await _frames(2)

	# attach() options and the off switch.
	var s2 := LineEdit.new()
	s2.placeholder_text = "Search plug-ins"
	host.add_child(s2)
	pk.attach(s2, {"title": "Find a plug-in", "suggestions": func(): return ["Alpha", "Beta"], "style": "classic"})
	pk.open_for(s2)
	await _frames(2)
	_check("attach: custom suggestions and classic style", pk._chips.get_child_count() == 3 and pk._style == "classic")
	_button_with_text(pk._root, "Alpha").pressed.emit()
	_check("a suggestion chip fills the entry line", pk.text() == "Alpha")
	pk.close(true)
	await _frames(2)
	_check("search field got the chip", s2.text == "Alpha")
	other.grab_focus()
	await _frames(2)
	Prefs.set_value("ui", "pad_keyboard", "off")
	s2.grab_focus()
	await _frames(3)
	_check("pref ui/pad_keyboard=off: no auto-open", not pk.is_open())
	Prefs.set_value("ui", "pad_keyboard", "auto")
	var s3 := LineEdit.new()
	host.add_child(s3)
	pk.attach(s3, {"auto": false})
	s3.grab_focus()
	await _frames(3)
	_check("attach auto=false: no auto-open", not pk.is_open())
	pk.assume_pad = false
