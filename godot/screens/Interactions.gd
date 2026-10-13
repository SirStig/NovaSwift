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

const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")
const CD = preload("res://ui/classic/ClassicDialog.gd")
const CS = preload("res://ui/classic/ClassicScreen.gd")

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
	ClassicTheme.setup(world)
	_hud = PanelContainer.new()
	_hud.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.position = Vector2(24, 150)
	_hud.add_theme_stylebox_override("panel", _style(Color(0.05, 0.06, 0.09, 0.82)))
	_hud_box = VBoxContainer.new()
	_hud_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_hud.add_child(_hud_box)
	_hud.visible = false
	add_child(_hud)


## Classic (original DLOG/DITL) presentation for the dialogs, or the plain Nova Swift ones.
func _classic() -> bool:
	return ClassicTheme.classic("dialogs")


## A fresh dialog host for the Classic path: a dim scrim; add ClassicDialogs to it.
func _begin_classic() -> Control:
	_clear_dialog_nodes()
	_dialog = Control.new()
	_dialog.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_dialog)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.55)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_dialog.add_child(dim)
	_box = null
	return _dialog


func _cbtn(d: Control, label: String, r: Rect2i, idx: int, cb: Callable, key: String, enabled := true) -> TextureButton:
	var b := CS.button(d, label, r, idx, cb, enabled, "btn_" + key)
	return b


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
	if _classic():
		_hail_classic(st)
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
	if _classic():
		_plunder_classic(st)
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
	if _classic():
		_capture_classic()
		return
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
	if _classic():
		_name_classic()
		return
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
	if _classic():
		_escorts_classic(labels, roster)
		return
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
	if sel != null and int(sel["record"]) >= 0:
		# The original's escort window (0x004853a0): Upgrade and Sell are exclusive toggle
		# marks the fleet pass processes on leaving a shipyard stellar; the line below says
		# so (STR# 2002 #292 / #295). Upgrade needs an UpgradeTo hull whose availability
		# passes; Sell is never offered for a hired (or mission) escort.
		var rec := int(sel["record"])
		var detail: Array[String] = []
		if int(sel["upgradeCost"]) > 0 and sel["canUpgrade"]:
			detail.append("upgrade to %s %s cr" % [sel["upgradeName"], str(int(sel["upgradeCost"]))])
		if sel["canSell"]:
			detail.append("sell %s cr" % str(int(sel["sellValue"])))
		var status := str(sel.get("status", ""))
		if status != "":
			_box.add_child(_label(status, 14, COL_AMBER))
		elif not detail.is_empty():
			_box.add_child(_label(", ".join(detail), 13, COL_DIM))
		if sel["pendingUpgrade"]:
			bar.add_child(_button("upg", "Cancel Upgrade", func():
				nova.escort_cancel_upgrade(rec); _focus_key = "upg"; _show_escorts(), true))
		elif sel["canUpgrade"]:
			bar.add_child(_button("upg", "Upgrade", func():
				nova.escort_request_upgrade(rec); _focus_key = "upg"; _show_escorts(), true))
		if sel["pendingSale"]:
			bar.add_child(_button("sell", "Cancel Sale", func():
				nova.escort_cancel_sale(rec); _focus_key = "sell"; _show_escorts(), true))
		elif sel["canSell"]:
			bar.add_child(_button("sell", "Sell", func():
				nova.escort_request_sale(rec); _focus_key = "sell"; _show_escorts(), true))
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
	var classic := _classic()
	_style_hud(classic)
	if classic:
		# Ui_DrawTargetCategoryPanel: black box, grey border, white title, green selected row.
		var t := _label(str(st["title"]), 12, Color.WHITE)
		t.add_theme_font_override("font", ClassicTheme.chrome_font())
		_hud_box.add_child(t)
	else:
		_hud_box.add_child(_label(str(st["title"]), 14, COL_AMBER))
	for r in st["rows"]:
		var col: Color = Color.WHITE if r["enabled"] else Color(0.4, 0.42, 0.48)
		if r["selected"]:
			col = COL_AMBER
		if classic:
			col = (Color(0.3, 1.0, 0.3) if r["selected"] else Color.WHITE) if r["enabled"] else Color(0.25, 0.25, 0.25)
		var l := _label("%s   %s" % [r["label"], r["order"]], 11 if classic else 13, col)
		if classic:
			l.add_theme_font_override("font", ClassicTheme.body_font())
		_hud_box.add_child(l)
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


var _hud_classic := -1


func _style_hud(classic: bool) -> void:
	var want := 1 if classic else 0
	if _hud_classic == want:
		return
	_hud_classic = want
	if classic:
		var sb := StyleBoxFlat.new()
		sb.bg_color = Color(0, 0, 0, 0.85)
		sb.border_color = Color(0.4, 0.4, 0.4)
		sb.set_border_width_all(1)
		sb.set_content_margin_all(6)
		_hud.add_theme_stylebox_override("panel", sb)
	else:
		_hud.add_theme_stylebox_override("panel", _style(Color(0.05, 0.06, 0.09, 0.82)))


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
		if n is BaseButton and not n.disabled:
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


# MARK: Classic (original DITL) dialogs --------------------------------------------------
# Mirrors the Apple HailDialogView (DITL 1007 / 1009 on PICT 8511 / 8512), NegotiationView
# (1008 / 8514), PlunderView (1011 / 8515), the capture decision (DLOG 3002) and name prompt
# (3001), and EscortsView (1022 / 8513).

func _hail_classic(st: Dictionary) -> void:
	var host := _begin_classic()
	var planet: bool = st["kind"] == "planet"
	var did := 1009 if planet else 1007
	var d := CS.frame(nova, did, 8512 if planet else 8511)
	d.beep = false
	host.add_child(d)
	var paying: bool = st.has("payment")
	var pr: Rect2i
	var tx: Rect2i
	var idr: Rect2i
	if planet:
		pr = CS.rect(nova, did, 4, Rect2i(222, 5, 310, 283))
		tx = CS.rect(nova, did, 3, Rect2i(5, 5, 200, 60))
		idr = CS.rect(nova, did, 5, Rect2i(16, 82, 120, 50))
	else:
		pr = CS.rect(nova, did, 10, Rect2i(216, 7, 200, 200))
		tx = CS.rect(nova, did, 9, Rect2i(11, 8, 192, 58))
		idr = CS.rect(nova, did, 11, Rect2i(40, 73, 134, 46))
	var tex: Texture2D = null
	if planet:
		var lp: int = nova.spaceport_picture_id(1, int(st["id"]))
		tex = _pict_tex(lp) if lp >= 0 else _sprite_frame_tex(5, int(st["id"]))
	else:
		tex = _pict_tex(int(st["pict"]))
	if tex != null:
		CS.picture(d, tex, pr, TextureRect.STRETCH_KEEP_ASPECT_COVERED if planet and int(nova.spaceport_picture_id(1, int(st["id"]))) >= 0 else TextureRect.STRETCH_KEEP_ASPECT_CENTERED)
	CS.text(d, str(st["text"]), Rect2i(tx.position, tx.size), 10, Color.WHITE)
	var y := idr.position.y
	CS.text(d, str(st["name"]), Rect2i(idr.position.x, y, idr.size.x, 16), 12, COL_AMBER, HORIZONTAL_ALIGNMENT_LEFT, true)
	y += 18
	if str(st["classLine"]) != "":
		CS.text(d, str(st["classLine"]), Rect2i(idr.position.x, y, idr.size.x, 14), 10, Color(0.75, 0.75, 0.75))
		y += 14
	if str(st["status"]) != "":
		CS.text(d, str(st["status"]), Rect2i(idr.position.x, y, idr.size.x, 14), 10,
			Color(1, 0.3, 0.3) if st["statusHostile"] else Color(0.75, 0.75, 0.75))
	if planet:
		_cbtn(d, str(st["top"]), CS.rect(nova, did, 1, Rect2i(27, 184, 146, 26)), 1, _hail_top, "top", not paying)
		if st["middleVisible"]:
			_cbtn(d, str(st["middle"]), CS.rect(nova, did, 2, Rect2i(27, 214, 146, 26)), 2, _hail_middle, "middle",
				st["middleEnabled"] and not paying)
		_cbtn(d, str(st["close"]), CS.rect(nova, did, 0, Rect2i(27, 244, 146, 26)), 0, _hail_close, "close", not paying)
	else:
		_cbtn(d, str(st["top"]), CS.rect(nova, did, 2, Rect2i(21, 125, 166, 26)), 2, _hail_top, "top", not paying)
		if st["middleVisible"]:
			_cbtn(d, str(st["middle"]), CS.rect(nova, did, 1, Rect2i(21, 153, 166, 26)), 1, _hail_middle, "middle",
				st["middleEnabled"] and not paying)
		_cbtn(d, str(st["close"]), CS.rect(nova, did, 0, Rect2i(21, 181, 166, 26)), 0, _hail_close, "close", not paying)
	if paying:
		var p: Dictionary = st["payment"]
		var h := CS.frame(nova, 1008, 8514)
		h.beep = false
		host.add_child(h)
		CS.text(h, str(p["message"]), CS.rect(nova, 1008, 2, Rect2i(7, 6, 248, 25)), 11, Color.WHITE)
		_cbtn(h, str(p["accept"]), CS.rect(nova, 1008, 1, Rect2i(58, 39, 146, 26)), 1, func(): _pay(true), "accept")
		_cbtn(h, str(p["lower"]), CS.rect(nova, 1008, 0, Rect2i(58, 74, 146, 26)), 0, func(): _pay(false), "lower")
		h.focus_first.call_deferred()
	_apply_focus(["accept", "top", "middle", "close"] if paying else ["top", "middle", "close"])


func _plunder_classic(st: Dictionary) -> void:
	var host := _begin_classic()
	var d := CS.frame(nova, 1011, 8515)
	d.beep = false
	host.add_child(d)
	var pan := CS.rect(nova, 1011, 4, Rect2i(11, 7, 287, 96))
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.55)
	bg.position = Vector2(pan.position)
	bg.size = Vector2(pan.size)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	d.add_child(bg)
	var cargo_t := int(st["cargoTons"])
	var y := pan.position.y + 4
	CS.text(d, "Select what to plunder from this ship:", Rect2i(pan.position.x + 6, y, pan.size.x - 12, 14), 11, COL_AMBER, HORIZONTAL_ALIGNMENT_LEFT, true)
	y += 18
	var rows := [["Cargo:", ("%d tons" % cargo_t) if cargo_t > 0 else "None"],
		["Ammo:", str(int(st["ammo"])) if st["ammo"] > 0 else "None"]]
	if st["capture"] >= 0:
		rows.append(["Capture Odds:", "%d%%" % st["capture"]])
	for r in rows:
		CS.text(d, r[0], Rect2i(pan.position.x + 6, y, 100, 14), 11, Color.WHITE)
		CS.text(d, r[1], Rect2i(pan.position.x + 106, y, 100, 14), 11, Color.WHITE, HORIZONTAL_ALIGNMENT_RIGHT)
		y += 15
	CS.text(d, "%d credits · %d energy" % [st["credits"], st["energy"]], Rect2i(pan.position.x + 6, pan.end.y - 16, pan.size.x - 12, 14), 10, Color(0.65, 0.65, 0.65))
	var live := {0: st["energy"] > 0, 1: st["cargoTons"] > 0, 2: st["credits"] > 0, 3: st["ammo"] > 0, 4: st["capture"] >= 0}
	# True DITL slots: Energy / Cargo / Credits, Ammo / Capture Ship, Abort.
	var slots := {"Energy": [5, Rect2i(16, 110, 89, 25), 0], "Cargo": [1, Rect2i(110, 110, 89, 25), 1],
		"Credits": [3, Rect2i(204, 110, 89, 25), 2], "Ammo": [2, Rect2i(35, 138, 89, 25), 3],
		"Capture Ship": [6, Rect2i(129, 138, 146, 25), 4]}
	for k in slots:
		var sl: Array = slots[k]
		var action: int = sl[2]
		var b := _cbtn(d, k, CS.rect(nova, 1011, sl[0], sl[1]), sl[0], _plunder_press.bind(action), k, live[action])
		b.refused.connect(func(): _beep(4))
	_cbtn(d, "Abort", CS.rect(nova, 1011, 0, Rect2i(91, 166, 126, 25)), 0, _plunder_abort, "Abort")
	_apply_focus(["Cargo", "Credits", "Abort"])


func _capture_classic() -> void:
	var host := _begin_classic()
	var can_escort: bool = _capture["canEscort"]
	var d := CD.from_ditl(nova, 3002, {"texts": {2: str(_capture["message"])}, "labels": {0: "Take Command", 4: "Use as Escort"},
		"hidden": [] if can_escort else [4], "default_item": 0, "cancel_item": -1, "fallback_size": Vector2i(354, 140),
		"actions": {0: _show_name_prompt, 4: _capture_escort}})
	d.beep = false
	host.add_child(d)
	d.item(0).name = "btn_cmd"
	if can_escort and d.item(4) != null:
		d.item(4).name = "btn_esc"
	_apply_focus(["cmd"])


func _name_classic() -> void:
	var host := _begin_classic()
	var d := CD.text_prompt(nova, str(_capture["prompt"]), str(_capture["defaultName"]))
	d.cancel_item = -1
	d.beep = false
	d.actions = {0: _name_ok, 5: _name_cancel}
	_name_edit = d.texts[4]
	_name_edit.max_length = 63
	host.add_child(d)
	d.item(0).name = "btn_ok"
	d.item(5).name = "btn_cancel"
	_apply_focus(["ok"])


func _escorts_classic(labels: Dictionary, roster: Array) -> void:
	var host := _begin_classic()
	var d := CS.frame(nova, 1022, 8513)
	d.beep = false
	d.window_size = Vector2i(d.window_size.x, d.window_size.y + 78)
	d.custom_minimum_size = Vector2(d.window_size)
	d.size = Vector2(d.window_size)
	host.add_child(d)
	var names: Array = labels.get("groups", ["All"])
	var has := not roster.is_empty()
	var sm := CS.rect(nova, 1022, 9, Rect2i(14, 9, 192, 58))
	CS.text(d, "Escort Wing" if has else "No escorts", Rect2i(sm.position.x, sm.position.y + 8, sm.size.x, 16), 12,
		Color.WHITE if has else Color(0.5, 0.5, 0.5), HORIZONTAL_ALIGNMENT_CENTER, true)
	CS.text(d, ("%d ship%s under command" % [roster.size(), "" if roster.size() == 1 else "s"]) if has else "Capture or hire ships to command",
		Rect2i(sm.position.x + 6, sm.position.y + 28, sm.size.x - 12, 28), 10, Color(0.6, 0.6, 0.6), HORIZONTAL_ALIGNMENT_CENTER)
	var orr := CS.rect(nova, 1022, 11, Rect2i(14, 79, 192, 52))
	CS.text(d, ("Orders to: %s" % names[_esc_group + 1]) if has else "—", Rect2i(orr.position.x + 6, orr.position.y + 18, orr.size.x - 12, 16), 11,
		COL_AMBER if has else Color(0.4, 0.4, 0.4), HORIZONTAL_ALIGNMENT_CENTER)
	var ol: Dictionary = labels.get("orders", {})
	# Items 2 / 3 / 1 / 0 top to bottom: Attack, Defend, Formation, Hold Position.
	for spec in [[2, 2, Rect2i(29, 141, 146, 26)], [3, 1, Rect2i(29, 169, 146, 26)], [1, 0, Rect2i(29, 197, 146, 26)], [0, 4, Rect2i(29, 225, 146, 26)]]:
		var code: int = spec[1]
		_cbtn(d, str(ol.get(str(code), str(code))), CS.rect(nova, 1022, spec[0], spec[2]), spec[0],
			func(): _escort_window_order(code), "o%d" % code, has)
	# Roster list (item 10).
	var lr := CS.rect(nova, 1022, 10, Rect2i(217, 30, 200, 200))
	var sc := ScrollContainer.new()
	sc.position = Vector2(lr.position)
	sc.size = Vector2(lr.size)
	sc.follow_focus = true
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.get_v_scroll_bar().modulate = Color(1, 1, 1, 0)
	d.add_child(sc)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", 2)
	list.custom_minimum_size = Vector2(lr.size.x - 4, 0)
	sc.add_child(list)
	if not has:
		var l := CS.text(d, "No escorts under your command.", lr, 11, Color(0.55, 0.55, 0.55), HORIZONTAL_ALIGNMENT_CENTER)
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	var sel = null
	for m in roster:
		var rid: int = m["record"] if m["record"] >= 0 else -1000 - int(m["entity"])
		var rb := CS.Row.new()
		rb.custom_minimum_size = Vector2(lr.size.x - 4, 30)
		rb.name = "btn_r%d" % rid
		rb.set_selected(rid == _esc_sel)
		rb.pressed.connect(func(): _esc_sel = -1 if _esc_sel == rid else rid; _focus_key = "r%d" % rid; _show_escorts())
		CS.cell(rb, str(m["name"]), 4, 120, 14, Color.WHITE, HORIZONTAL_ALIGNMENT_LEFT, 11)
		var origin := "Fighter" if m.get("fighter", false) else str(m["origin"])
		CS.cell(rb, origin, 120, lr.size.x - 128, 14, Color(0.6, 0.6, 0.6), HORIZONTAL_ALIGNMENT_RIGHT, 9)
		for bar in [[0.4, 0.7, 1.0, float(m["shield"]), 4], [1.0, 0.72, 0.3, float(m["armor"]), 98]]:
			var back := ColorRect.new()
			back.color = Color(1, 1, 1, 0.12)
			back.position = Vector2(bar[4], 20)
			back.size = Vector2(70, 4)
			back.mouse_filter = Control.MOUSE_FILTER_IGNORE
			rb.add_child(back)
			var fill := ColorRect.new()
			fill.color = Color(bar[0], bar[1], bar[2])
			fill.position = back.position
			fill.size = Vector2(70.0 * clampf(bar[3], 0.0, 1.0), 4)
			fill.mouse_filter = Control.MOUSE_FILTER_IGNORE
			rb.add_child(fill)
		list.add_child(rb)
		if rid == _esc_sel:
			sel = m
	# Action strip under the frame (Apple appends the same).
	var fh := int(d.window_size.y) - 78
	var strip := ColorRect.new()
	strip.color = Color(0.08, 0.08, 0.08)
	strip.position = Vector2(0, fh)
	strip.size = Vector2(d.window_size.x, 78)
	strip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	d.add_child(strip)
	var line := ColorRect.new()
	line.color = Color(1, 0.7, 0.28, 0.22)
	line.size = Vector2(d.window_size.x, 1)
	strip.add_child(line)
	var status := ""
	var rec := -1
	if sel != null and int(sel["record"]) >= 0:
		rec = int(sel["record"])
		status = str(sel.get("status", ""))
		if status == "":
			var detail: Array[String] = []
			if int(sel["upgradeCost"]) > 0 and sel["canUpgrade"]:
				detail.append("upgrade to %s %s cr" % [sel["upgradeName"], str(int(sel["upgradeCost"]))])
			if sel["canSell"]:
				detail.append("sell %s cr" % str(int(sel["sellValue"])))
			status = ", ".join(detail)
	elif sel != null:
		status = "Bay fighter - managed via its carrier"
	elif has:
		status = "Select an escort to hail it."
	CS.text(d, (str(sel["name"]) + " - " if sel != null else "") + status, Rect2i(8, fh + 4, d.window_size.x - 16, 14), 10, Color(0.6, 0.6, 0.6))
	var cur := [8, fh + 24]
	var add := func(label: String, w: int, cb: Callable, key: String, on := true) -> void:
		_cbtn(d, label, Rect2i(cur[0], cur[1], w, 25), 20 + cur[0] + cur[1], cb, key, on)
		cur[0] += w + 6
	var gnext := func():
		_esc_group = -1 if _esc_group >= names.size() - 2 else _esc_group + 1
		_focus_key = "grp"
		_show_escorts()
	add.call(str(names[_esc_group + 1]), 100, gnext, "grp", has)
	add.call(str(ol.get("3", "Return to Hangar")), 120, func(): _escort_window_order(3), "o3", has)
	var done_x: int = int(d.window_size.x) - 66
	if rec >= 0:
		cur[0] = 8
		cur[1] = fh + 50
		if sel["pendingUpgrade"]:
			add.call("Cancel Upgrade", 100, func(): nova.escort_cancel_upgrade(rec); _focus_key = "upg"; _show_escorts(), "upg")
		elif sel["canUpgrade"]:
			add.call("Upgrade", 70, func(): nova.escort_request_upgrade(rec); _focus_key = "upg"; _show_escorts(), "upg")
		if sel["pendingSale"]:
			add.call("Cancel Sale", 80, func(): nova.escort_cancel_sale(rec); _focus_key = "sell"; _show_escorts(), "sell")
		elif sel["canSell"]:
			add.call("Sell", 50, func(): nova.escort_request_sale(rec); _focus_key = "sell"; _show_escorts(), "sell")
		if sel["canRelease"]:
			add.call("Dismiss" if sel["origin"] == "Captured" else "Release", 80,
				func(): nova.escort_release(rec); _esc_sel = -1; _focus_key = "close"; _show_escorts(), "rel")
	_cbtn(d, "Done", Rect2i(done_x, fh + 24, 60, 25), 99, _close_dialog, "close")
	_apply_focus(["close"])
