# NOVA Swift — in-flight interactions (Godot): hailing a ship or stellar,
# boarding + the Plunder window, the "Ship captured!" question, the Escorts
# window (hail your own escort) and the Escort Commands panel.
#
# Every rule and every string is shared Swift (FlightComm / FlightPlunder /
# FlightEscorts, reached through NovaWorld's "Interactions" bridge section — the
# code the Apple app's HailDialogView / PlunderView / EscortsView rules were
# extracted into). This file only lays out Controls and routes input.
#
# Controller-first with Godot focus: d-pad / stick move focus, A / Enter press,
# B / Esc close (Abort in the plunder window). Mouse works everywhere. While a
# dialog is up the flight sim is paused (Main checks blocks_flight()), as the
# Apple app pauses it.
#
# Loaded with preload() (no class_name), like the other screens.
extends CanvasLayer

signal log_message(text: String)
signal screen_closed

const COL_AMBER := Color(1.0, 0.82, 0.4)
const COL_DIM := Color(0.62, 0.66, 0.74)
const COL_RED := Color(1.0, 0.35, 0.3)

var nova
var _dialog: Control = null       # dim + panel while a dialog is up
var _kind := ""                   # hail | plunder | capture | name | escorts
var _box: VBoxContainer           # the current dialog's content
var _focus_key := ""
var _tex := {}                    # PICT id / sprite key -> Texture2D (or null)
var _hud: PanelContainer          # the Escort Commands panel (never blocks input)
var _hud_box: VBoxContainer
var _esc_group := -1              # Escorts window: -1 all, else EscortType
var _esc_sel := -1                # Escorts window: selected roster record
var _name_edit: LineEdit
var _capture := {}


func setup(world) -> void:
	nova = world
	layer = 30
	_hud = PanelContainer.new()
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.position = Vector2(24, 150)
	_hud.add_theme_stylebox_override("panel", _style(Color(0.05, 0.06, 0.09, 0.82)))
	_hud_box = VBoxContainer.new()
	_hud_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(_hud_box)
	_hud.visible = false
	add_child(_hud)


func blocks_flight() -> bool:
	return _dialog != null


func _style(bg: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = Color(0.45, 0.5, 0.6)
	s.set_border_width_all(2)
	s.set_corner_radius_all(4)
	s.set_content_margin_all(12)
	return s


func _beep(n: int) -> void:
	nova.sound_beep(n)


func _json(text: String) -> Dictionary:
	var v = JSON.parse_string(text)
	return v if v is Dictionary else {}


# MARK: Flight-time hotkeys ----------------------------------------------------

# Called by Main once per flight frame. The Alt chords also match their plain
# key (Godot ignores extra modifiers), so the Alt variant is tested first.
func process_hotkeys() -> void:
	if Input.is_action_just_pressed("hail_stellar"):
		hail(true)
	elif Input.is_action_just_pressed("hail_target"):
		hail(false)
	if Input.is_action_just_pressed("board_target"):
		board()
	if Input.is_action_just_pressed("escort_panel"):
		var r := _json(nova.escort_press_e())
		_beep(int(r.get("beep", 0)))
		if str(r.get("message", "")) != "":
			log_message.emit(r["message"])
	for k in 5:
		if Input.is_action_just_pressed("escort_group_%d" % (k + 1)):
			var picked: int = nova.escort_group_key(k)
			if picked > 0:
				_beep(picked)
	if Input.is_action_just_pressed("escort_attack"):
		escort_order(2)
	if Input.is_action_just_pressed("escort_defend"):
		escort_order(1)
	if Input.is_action_just_pressed("escort_hold"):
		escort_order(4)
	if Input.is_action_just_pressed("escort_return"):
		escort_order(3)
	elif Input.is_action_just_pressed("escort_formation"):
		escort_order(0)


func escort_order(code: int) -> void:
	var text: String = nova.escort_order(code)
	if text != "":
		log_message.emit(text)


func _process(_delta: float) -> void:
	if nova == null:
		return
	for line in nova.drain_interaction_messages():
		log_message.emit(line)
	_refresh_escort_panel()


# MARK: Hail ---------------------------------------------------------------------

func hail(stellar: bool) -> void:
	var r := _json(nova.hail_open(stellar))
	var result := str(r.get("result", "nothing"))
	if result == "nothing":
		return
	if int(r.get("beep", 0)) > 0:
		_beep(int(r["beep"]))
	match result:
		"refused":
			if str(r.get("message", "")) != "":
				log_message.emit(r["message"])
		"escorts":
			_open_escorts()
		"window":
			_kind = "hail"
			_focus_key = ""
			_show_hail()


func _show_hail() -> void:
	var st := _json(nova.hail_state())
	if st.is_empty():
		_close_dialog()
		return
	_begin("")
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	_box.add_child(row)
	var portrait := TextureRect.new()
	portrait.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	portrait.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	portrait.custom_minimum_size = Vector2(260, 220) if st["kind"] == "planet" else Vector2(200, 200)
	portrait.texture = _hail_portrait(st)
	row.add_child(portrait)
	var col := VBoxContainer.new()
	col.custom_minimum_size = Vector2(380, 0)
	col.add_theme_constant_override("separation", 6)
	row.add_child(col)
	col.add_child(_label(str(st["name"]), 20, COL_AMBER))
	if str(st["classLine"]) != "":
		col.add_child(_label(str(st["classLine"]), 14, COL_DIM))
	if str(st["status"]) != "":
		col.add_child(_label(str(st["status"]), 14, COL_RED if st["statusHostile"] else COL_DIM))
	var text := _label(str(st["text"]), 15, Color.WHITE)
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.custom_minimum_size = Vector2(380, 64)
	col.add_child(text)
	var paying: bool = st.has("payment")
	col.add_child(_button("top", str(st["top"]), _hail_top, not paying))
	if st["middleVisible"]:
		col.add_child(_button("middle", str(st["middle"]), _hail_middle, st["middleEnabled"] and not paying))
	col.add_child(_button("close", str(st["close"]), _hail_close, not paying))
	if paying:
		var p: Dictionary = st["payment"]
		var sep := HSeparator.new()
		_box.add_child(sep)
		var msg := _label(str(p["message"]), 16, COL_AMBER)
		_box.add_child(msg)
		var pr := HBoxContainer.new()
		_box.add_child(pr)
		pr.add_child(_button("accept", str(p["accept"]), func(): _pay(true), true))
		pr.add_child(_button("lower", str(p["lower"]), func(): _pay(false), true))
	_apply_focus(["accept", "top", "middle", "close"] if paying else ["top", "middle", "close"])


func _hail_portrait(st: Dictionary) -> Texture2D:
	if st["kind"] == "ship":
		return _pict_tex(int(st["pict"]))
	return _sprite_frame_tex(5, int(st["id"]))


func _hail_top() -> void:
	_beep(2)   # the comm window's action buttons sound snd 151
	_focus_key = "top"
	nova.hail_press_top()
	_show_hail()


func _hail_middle() -> void:
	_beep(2)
	_focus_key = "middle"
	nova.hail_press_middle()
	_show_hail()


func _hail_close() -> void:
	_beep(3)   # closing sounds snd 152
	nova.hail_close()
	_close_dialog()


func _pay(accept: bool) -> void:
	_focus_key = "accept"
	nova.hail_press_payment(accept)
	_show_hail()


# MARK: Boarding / plunder -----------------------------------------------------

func board() -> void:
	var r := _json(nova.board_attempt())
	if int(r.get("beep", 0)) > 0:
		_beep(int(r["beep"]))
	match str(r.get("result", "nothing")):
		"recovered":
			if str(r.get("message", "")) != "":
				log_message.emit(r["message"])
		"window":
			_kind = "plunder"
			_focus_key = ""
			_show_plunder()


const PLUNDER_BUTTONS := [["Energy", 0], ["Cargo", 1], ["Credits", 2], ["Ammo", 3], ["Capture Ship", 4]]


func _show_plunder() -> void:
	var st := _json(nova.plunder_state())
	if st.is_empty():
		_close_dialog()
		return
	_begin("")
	_box.add_child(_label("Select what to plunder from this ship:", 16, COL_AMBER))
	_box.add_child(_label(str(st["name"]), 14, COL_DIM))
	_box.add_child(_row("Cargo:", ("%d tons" % st["cargoTons"]) if st["cargoTons"] > 0 else "None"))
	_box.add_child(_row("Ammo:", str(int(st["ammo"])) if st["ammo"] > 0 else "None"))
	if st["capture"] >= 0:
		_box.add_child(_row("Capture Odds:", "%d%%" % st["capture"]))
	_box.add_child(HSeparator.new())
	_box.add_child(_label("%d credits · %d energy" % [st["credits"], st["energy"]], 13, COL_DIM))
	var live := {0: st["energy"] > 0, 1: st["cargoTons"] > 0, 2: st["credits"] > 0,
		3: st["ammo"] > 0, 4: st["capture"] >= 0}
	var grid := GridContainer.new()
	grid.columns = 3
	_box.add_child(grid)
	for b in PLUNDER_BUTTONS:
		var btn := _button(b[0], b[0], _plunder_press.bind(b[1]), true)
		# A greyed button stays pressable: the original answers it with snd 153.
		btn.modulate = Color.WHITE if live[b[1]] else Color(1, 1, 1, 0.45)
		grid.add_child(btn)
	grid.add_child(_button("Abort", "Abort", _plunder_abort, true))
	_apply_focus(["Cargo", "Credits", "Abort"])


func _plunder_press(action: int) -> void:
	_focus_key = PLUNDER_BUTTONS[action][0]
	var r := _json(nova.plunder_press(action))
	_beep(4 if r.get("refused", false) else 3)   # every plunder button sounds snd 152; refused 153
	for line in r.get("messages", []):
		log_message.emit(str(line))
	if r.get("choice", false):
		_close_dialog()
		_show_capture()
	elif r.get("closed", false):
		_close_dialog()
	else:
		_show_plunder()


func _plunder_abort() -> void:
	_beep(3)
	nova.plunder_abort()
	_close_dialog()


func _show_capture() -> void:
	_capture = _json(nova.capture_question())
	if _capture.is_empty():
		return
	_kind = "capture"
	_focus_key = ""
	_begin("")
	_box.add_child(_label("Ship captured!", 18, COL_AMBER))
	var msg := _label(str(_capture["message"]), 15, Color.WHITE)
	msg.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	msg.custom_minimum_size = Vector2(440, 60)
	_box.add_child(msg)
	var row := HBoxContainer.new()
	_box.add_child(row)
	row.add_child(_button("cmd", "Take Command", _show_name_prompt, true))
	if _capture["canEscort"]:
		row.add_child(_button("esc", "Use as Escort", _capture_escort, true))
	_apply_focus(["cmd"])


func _capture_escort() -> void:
	_beep(2)
	for line in nova.capture_resolve(false, ""):
		log_message.emit(line)
	_close_dialog()


func _show_name_prompt() -> void:
	_beep(2)
	_kind = "name"
	_begin("")
	_box.add_child(_label(str(_capture["prompt"]), 16, COL_AMBER))
	_name_edit = LineEdit.new()
	_name_edit.text = str(_capture["defaultName"])
	_name_edit.max_length = 63
	_name_edit.custom_minimum_size = Vector2(360, 0)
	_name_edit.text_submitted.connect(func(_t): _name_ok())
	_box.add_child(_name_edit)
	var row := HBoxContainer.new()
	_box.add_child(row)
	row.add_child(_button("ok", "OK", _name_ok, true))
	row.add_child(_button("cancel", "Cancel", _name_cancel, true))
	_apply_focus(["ok"])


func _name_ok() -> void:
	var name := _name_edit.text
	for line in nova.capture_resolve(true, name):
		log_message.emit(line)
	_close_dialog()


func _name_cancel() -> void:
	log_message.emit(str(_capture.get("cancelled", "Cancelled.")))
	nova.capture_cancel()
	_close_dialog()


# MARK: Escorts window ---------------------------------------------------------

func _open_escorts() -> void:
	_kind = "escorts"
	_focus_key = ""
	_esc_group = -1
	_esc_sel = -1
	_show_escorts()


func _show_escorts() -> void:
	var labels := _json(nova.escort_labels())
	var roster = JSON.parse_string(nova.escort_roster())
	if roster == null:
		roster = []
	_begin("")
	_box.add_child(_label("Escorts", 18, COL_AMBER))
	var groups := HBoxContainer.new()
	_box.add_child(groups)
	var names: Array = labels.get("groups", ["All"])
	for i in names.size():
		var g := i - 1
		var gb := _button("g%d" % i, str(names[i]), func(): _esc_group = g; _focus_key = "g%d" % (g + 1); _show_escorts(), true)
		gb.toggle_mode = true
		gb.button_pressed = (g == _esc_group)
		groups.add_child(gb)
	var orders := HBoxContainer.new()
	_box.add_child(orders)
	var ol: Dictionary = labels.get("orders", {})
	for code in [2, 1, 4, 0, 3]:
		orders.add_child(_button("o%d" % code, str(ol.get(str(code), str(code))),
			func(): _escort_window_order(code), true))
	_box.add_child(HSeparator.new())
	if roster.is_empty():
		_box.add_child(_label("No escorts.", 14, COL_DIM))
	var sel = null
	for m in roster:
		var line := "%s — shields %d%% armor %d%%%s%s" % [m["name"], int(m["shield"] * 100), int(m["armor"] * 100),
			"  (disabled)" if m["disabled"] else "", ("  · " + m["origin"]) if m["origin"] != "" else ""]
		var rid: int = m["record"] if m["record"] >= 0 else -1000 - int(m["entity"])
		var rb := _button("r%d" % rid, line, func(): _esc_sel = rid; _focus_key = "r%d" % rid; _show_escorts(), true)
		rb.toggle_mode = true
		rb.button_pressed = (rid == _esc_sel)
		rb.alignment = HORIZONTAL_ALIGNMENT_LEFT
		_box.add_child(rb)
		if rid == _esc_sel:
			sel = m
	var bar := HBoxContainer.new()
	_box.add_child(bar)
	if sel != null and sel["canRelease"]:
		bar.add_child(_button("rel", "Dismiss" if sel["origin"] == "Captured" else "Release", func():
			nova.escort_release(int(sel["record"])); _esc_sel = -1; _focus_key = "close"; _show_escorts(), true))
	bar.add_child(_button("close", "Close", _close_dialog, true))
	_apply_focus(["close"])


func _escort_window_order(code: int) -> void:
	_focus_key = "o%d" % code
	var text: String = nova.escort_order_group(_esc_group, code)
	if text != "":
		log_message.emit(text)
	_show_escorts()


# MARK: Escort Commands panel (HUD) --------------------------------------------

func _refresh_escort_panel() -> void:
	if not nova.escort_panel_open():
		_hud.visible = false
		return
	var st := _json(nova.escort_panel_state())
	if st.is_empty():
		_hud.visible = false
		return
	for c in _hud_box.get_children():
		_hud_box.remove_child(c)
		c.queue_free()
	_hud_box.add_child(_label(str(st["title"]), 14, COL_AMBER))
	for r in st["rows"]:
		var col: Color = Color.WHITE if r["enabled"] else Color(0.4, 0.42, 0.48)
		if r["selected"]:
			col = COL_AMBER
		_hud_box.add_child(_label("%s   %s" % [r["label"], r["order"]], 13, col))
	_hud.modulate.a = clampf(float(st["level"]) / 32.0, 0.0, 1.0)
	_hud.visible = true


# MARK: Dialog plumbing --------------------------------------------------------

func _begin(title: String) -> void:
	_clear_dialog_nodes()
	_dialog = Control.new()
	_dialog.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_dialog)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dialog.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dialog.add_child(center)
	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", _style(Color(0.09, 0.09, 0.12)))
	center.add_child(panel)
	_box = VBoxContainer.new()
	_box.add_theme_constant_override("separation", 8)
	panel.add_child(_box)
	if title != "":
		_box.add_child(_label(title, 18, COL_AMBER))


func _clear_dialog_nodes() -> void:
	if _dialog != null:
		_dialog.queue_free()
		_dialog = null


func _close_dialog() -> void:
	_clear_dialog_nodes()
	_kind = ""
	screen_closed.emit()


func _label(text: String, size: int, col: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", col)
	return l


func _row(a: String, b: String) -> HBoxContainer:
	var h := HBoxContainer.new()
	var la := _label(a, 14, Color.WHITE)
	la.custom_minimum_size = Vector2(140, 0)
	h.add_child(la)
	h.add_child(_label(b, 14, Color.WHITE))
	return h


func _button(key: String, text: String, cb: Callable, enabled: bool) -> Button:
	var b := Button.new()
	b.text = text
	b.name = "btn_" + key
	b.disabled = not enabled
	b.focus_mode = Control.FOCUS_ALL if enabled else Control.FOCUS_NONE
	b.set_meta("key", key)
	b.pressed.connect(cb)
	return b


# Focus the remembered button, else the first of `prefer` that can take focus.
func _apply_focus(prefer: Array) -> void:
	var want := [_focus_key] + prefer
	for k in want:
		var n := _dialog.find_child("btn_" + str(k), true, false) if _dialog != null else null
		if n is Button and not n.disabled:
			n.call_deferred("grab_focus")
			return


func _input(event: InputEvent) -> void:
	if _dialog == null:
		return
	if event is InputEventKey and event.pressed and not event.echo:
		if _kind == "hail" and not _json(nova.hail_state()).has("payment"):
			# The comm window's own shortcuts (0x0047fa40): G greetings,
			# R request assistance, E closes the channel.
			if event.physical_keycode == KEY_G:
				_hail_top()
				get_viewport().set_input_as_handled()
				return
			if event.physical_keycode == KEY_R:
				if _json(nova.hail_state()).get("middleEnabled", false):
					_hail_middle()
				get_viewport().set_input_as_handled()
				return
			if event.physical_keycode == KEY_E:
				_hail_close()
				get_viewport().set_input_as_handled()
				return
	if event.is_action_pressed("ui_cancel"):
		match _kind:
			"hail":
				if not _json(nova.hail_state()).has("payment"):   # the haggle can't be dismissed
					_hail_close()
			"plunder":
				_plunder_abort()
			"escorts":
				_close_dialog()
			"name":
				_name_cancel()
		get_viewport().set_input_as_handled()


# MARK: Textures ----------------------------------------------------------------

func _pict_tex(pict_id: int) -> Texture2D:
	if pict_id < 0:
		return null
	var key := "p%d" % pict_id
	if _tex.has(key):
		return _tex[key]
	var tex: Texture2D = null
	var wh: PackedInt32Array = nova.pict_info(pict_id)
	if wh.size() >= 2 and wh[0] > 0 and wh[1] > 0:
		var bytes: PackedByteArray = nova.pict_rgba(pict_id)
		if bytes.size() >= wh[0] * wh[1] * 4:
			tex = ImageTexture.create_from_image(Image.create_from_data(wh[0], wh[1], false, Image.FORMAT_RGBA8, bytes))
	_tex[key] = tex
	return tex


# First frame of a decoded sprite sheet (a stellar's space sprite, as the Apple
# stellar comm shows).
func _sprite_frame_tex(kind: int, id: int) -> Texture2D:
	var key := "s%d_%d" % [kind, id]
	if _tex.has(key):
		return _tex[key]
	var tex: Texture2D = null
	var info: PackedInt32Array = nova.sprite_info(kind, id)
	if info.size() >= 7 and info[5] > 0 and info[6] > 0:
		var bytes: PackedByteArray = nova.sprite_rgba(kind, id)
		if bytes.size() >= info[5] * info[6] * 4:
			var sheet := ImageTexture.create_from_image(Image.create_from_data(info[5], info[6], false, Image.FORMAT_RGBA8, bytes))
			var atlas := AtlasTexture.new()
			atlas.atlas = sheet
			atlas.region = Rect2(0, 0, info[0], info[1])
			tex = atlas
	_tex[key] = tex
	return tex
