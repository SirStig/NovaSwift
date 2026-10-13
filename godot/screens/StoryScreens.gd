# NOVA Swift — story dialogs (Godot): the modal story-text dialog, the mission
# offer dialog (landing / shop / bar / in-flight offers), and the Player Info /
# Mission Info window.
#
# Every rule and every string is shared Swift (StoryEngine, MissionOffers,
# PlayerInfoPages, reached through NovaWorld's "Story & missions" bridge
# section — the code the Apple app's StoryTextOverlay / MissionSingleDialog /
# PlayerInfoView / MissionInfoView sit on). This file only lays out Controls and
# routes input.
#
# Texts and offers are polled every frame, so they appear wherever they are raised
# — over the spaceport after a landing completes a mission, or in flight after a
# jump fails one. Each text is a modal dialog of its own, in order (the original's
# 0x004982a0); an offer follows once the texts are read. While anything here is up
# the flight sim is paused (Main checks blocks_flight()).
#
# Controller-first with Godot focus: A / Enter presses, B / Esc refuses an offer
# (or closes a text / the window). Loaded with preload() (no class_name).
extends CanvasLayer

signal log_message(text: String)
signal screen_closed
## A `Q` fired while landed: close whichever spaceport screen is open.
signal close_spaceport_screen
## A `Q` fired while landed bounced the pilot into space.
signal forced_launch

const COL_AMBER := Color(1.0, 0.82, 0.4)
const COL_DIM := Color(0.62, 0.66, 0.74)
const COL_RED := Color(1.0, 0.35, 0.3)
const TABS := ["general", "cargo", "extras", "honors", "missions"]

var nova
var _modal: Control = null        # dim + panel for the head text / offer
var _modal_kind := ""             # text | offer
var _modal_buttons: Array = []    # focusable buttons of the modal, left to right
var _modal_cancel: Callable = Callable()
var _prev_focus: Control = null   # what had focus under the modal, restored on close
var _info: Control = null         # the Player/Mission Info window
var _info_tab := "general"
var _info_sel := -1               # Missions tab: selected mission id
var _info_msg := ""
var _tex := {}                    # PICT id -> Texture2D (or null)
var _labels := {}


func setup(world) -> void:
	nova = world
	layer = 60


func blocks_flight() -> bool:
	return _modal != null or _info != null or nova.story_blocks_flight()


func _json(text: String):
	return JSON.parse_string(text)


func _style(bg: Color) -> StyleBoxFlat:
	var s := StyleBoxFlat.new()
	s.bg_color = bg
	s.border_color = Color(0.6, 0.65, 0.75)
	s.set_border_width_all(2)
	s.set_corner_radius_all(4)
	s.set_content_margin_all(16)
	return s


func _lbl(text: String, size := 15, color := COL_DIM, parent: Node = null) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	if parent != null:
		parent.add_child(l)
	return l


func _btn(text: String, cb: Callable, parent: Node = null) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(120, 38)
	b.pressed.connect(cb)
	if parent != null:
		parent.add_child(b)
	return b


func _pict_tex(pict_id: int) -> Texture2D:
	if pict_id < 0:
		return null
	if _tex.has(pict_id):
		return _tex[pict_id]
	var tex: Texture2D = null
	var wh: PackedInt32Array = nova.pict_info(pict_id)
	if wh.size() >= 2 and wh[0] > 0 and wh[1] > 0:
		var bytes: PackedByteArray = nova.pict_rgba(pict_id)
		if bytes.size() >= wh[0] * wh[1] * 4:
			tex = ImageTexture.create_from_image(
				Image.create_from_data(wh[0], wh[1], false, Image.FORMAT_RGBA8, bytes))
	_tex[pict_id] = tex
	return tex


func _picture(pict_id: int, max_h: float) -> Control:
	var tex := _pict_tex(pict_id)
	if tex == null:
		return null
	var r := TextureRect.new()
	r.texture = tex
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	var sz := tex.get_size()
	var k := minf(1.0, max_h / maxf(sz.y, 1.0))
	r.custom_minimum_size = Vector2(sz.x * k, sz.y * k)
	var row := CenterContainer.new()
	row.add_child(r)
	return row


func _focus(b: Control) -> void:
	(func(): if is_instance_valid(b) and b.is_inside_tree(): b.grab_focus()).call_deferred()


func _dialog_root(width: float) -> VBoxContainer:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(width, 0)
	panel.add_theme_stylebox_override("panel", _style(Color(0.11, 0.11, 0.15)))
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 10)
	panel.add_child(box)
	add_child(root)
	# remember which root this is (modal vs info) by the caller assigning it
	box.set_meta("root", root)
	return box


# MARK: Per-frame pump -------------------------------------------------------

func _process(_delta: float) -> void:
	if nova == null or not nova.has_game():
		return
	for line in nova.drain_story_messages():
		log_message.emit(line)
	if nova.take_close_spaceport_screen():
		close_spaceport_screen.emit()
	if nova.take_forced_launch():
		forced_launch.emit()
	if _modal != null:
		return
	if nova.story_text_pending():
		_open_text()
	elif nova.offer_pending():
		_open_offer()


# While a modal is up it owns navigation: up/down never wander to whatever is
# under it, left/right step between its buttons, cancel is its own.
func _input(event: InputEvent) -> void:
	if _modal == null:
		return
	if event.is_action_pressed("ui_up") or event.is_action_pressed("ui_down"):
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_left") or event.is_action_pressed("ui_right"):
		var step := -1 if event.is_action_pressed("ui_left") else 1
		var cur := _modal_buttons.find(get_viewport().gui_get_focus_owner())
		if cur >= 0 and _modal_buttons.size() > 1:
			_focus(_modal_buttons[(cur + step + _modal_buttons.size()) % _modal_buttons.size()])
		get_viewport().set_input_as_handled()
	elif event.is_action_pressed("ui_cancel"):
		if _modal_cancel.is_valid():
			_modal_cancel.call()
		get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if _info == null or _modal != null:
		return
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("player_info") \
			or event.is_action_pressed("mission_info"):
		close_info()
		get_viewport().set_input_as_handled()


func _open_modal(box: VBoxContainer, kind: String, buttons: Array, cancel: Callable) -> void:
	_prev_focus = get_viewport().gui_get_focus_owner()
	_modal = box.get_meta("root")
	_modal_kind = kind
	_modal_buttons = buttons
	_modal_cancel = cancel
	nova.sound_beep(2)


func _close_modal() -> void:
	if _modal != null:
		var m := _modal
		_modal = null
		m.get_parent().remove_child(m)
		m.queue_free()
	_modal_buttons = []
	_modal_cancel = Callable()
	_modal_kind = ""
	if _prev_focus != null and is_instance_valid(_prev_focus) and _prev_focus.is_inside_tree():
		_focus(_prev_focus)
	elif _info != null:
		pass
	_prev_focus = null


func _scroll(text: String, height: float) -> ScrollContainer:
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(0, height)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var l := _lbl(text, 15, Color(0.92, 0.94, 1.0))
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	sc.add_child(l)
	return sc


# MARK: Story text -----------------------------------------------------------

func _open_text() -> void:
	var t = _json(nova.story_text_info())
	if not (t is Dictionary) or t.is_empty():
		nova.story_text_dismiss()
		return
	var box := _dialog_root(560)
	var title := str(t.get("title", ""))
	_lbl(title if title != "" else "Mission", 22, COL_AMBER, box)
	var pic := _picture(int(t.get("pict", -1)), 160)
	if pic != null:
		box.add_child(pic)
	box.add_child(_scroll(str(t.get("text", "")), 190))
	var ok := _btn("OK", _dismiss_text, box)
	_open_modal(box, "text", [ok], _dismiss_text)
	_focus(ok)


func _dismiss_text() -> void:
	nova.story_text_dismiss()
	nova.sound_beep(3)
	_close_modal()


# MARK: Mission offer --------------------------------------------------------

func _open_offer() -> void:
	var o = _json(nova.offer_state())
	if not (o is Dictionary) or o.is_empty():
		return
	var box := _dialog_root(620)
	_lbl(str(o.get("title", "")), 22, COL_AMBER, box)
	var pic := _picture(int(o.get("pict", -1)), 140)
	if pic != null:
		box.add_child(pic)
	box.add_child(_scroll(str(o.get("text", "")), 210))
	if str(o.get("destination", "")) != "":
		_lbl("Destination: %s" % o.destination, 14, COL_DIM, box)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 12)
	box.add_child(row)
	var buttons := []
	var cancel := Callable()
	if o.get("canRefuse", true):
		var no := _btn(str(o.get("refuse", "No")), _offer_decline, row)
		no.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		buttons.append(no)
		cancel = _offer_decline
	var yes := _btn(str(o.get("accept", "Yes")), _offer_accept, row)
	yes.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	buttons.append(yes)
	_open_modal(box, "offer", buttons, cancel)
	_focus(yes)


func _offer_accept() -> void:
	_close_modal()
	nova.offer_accept()


func _offer_decline() -> void:
	_close_modal()
	nova.offer_decline()


# MARK: Player Info / Mission Info -------------------------------------------

## Flight-time hotkeys: P / pad Start opens Player Info, I opens Mission Info.
func process_hotkeys() -> void:
	if Input.is_action_just_pressed("player_info"):
		open_info("general")
	elif Input.is_action_just_pressed("mission_info"):
		open_info("missions")


func open_info(tab: String) -> void:
	if _info != null or _modal != null:
		return
	_info_tab = tab
	_info_msg = ""
	_labels = _json(nova.story_labels())
	_build_info()


func close_info() -> void:
	if _info != null:
		var i := _info
		_info = null
		i.get_parent().remove_child(i)
		i.queue_free()
		nova.sound_beep(3)
		screen_closed.emit()


func _build_info(focus_tab := true) -> void:
	var was_open := _info != null
	if _info != null:
		var old := _info
		_info = null
		old.get_parent().remove_child(old)
		old.queue_free()
	var box := _dialog_root(820)
	_info = box.get_meta("root")
	if not was_open:
		nova.sound_beep(2)
	var data = _json(nova.player_info())
	if not (data is Dictionary) or data.is_empty():
		data = {}
	var head := HBoxContainer.new()
	box.add_child(head)
	var title := _lbl("Player Info" if _info_tab != "missions" else "Mission Info", 24, COL_AMBER, head)
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_lbl(str(data.get("date", "")), 15, COL_DIM, head)

	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 6)
	box.add_child(tabs)
	var active_btn: Button = null
	for t in TABS:
		var b := _btn(_tab_label(t), _switch_tab.bind(t), tabs)
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.toggle_mode = false
		if t == _info_tab:
			b.modulate = Color(1.0, 0.9, 0.55)
			active_btn = b

	var focus_target: Control = active_btn
	match _info_tab:
		"general":
			var g: Dictionary = data.get("general", {})
			var cols := HBoxContainer.new()
			cols.add_theme_constant_override("separation", 30)
			box.add_child(cols)
			cols.add_child(_grid(g.get("left", [])))
			cols.add_child(_grid(g.get("right", [])))
			_lbl(str(g.get("economy", "")), 14, COL_DIM, box)
		"cargo":
			box.add_child(_scroll(str(data.get("cargo", "")), 240))
			if data.get("canJettison", false):
				var j := _btn(str(_labels.get("jettison", "Jettison Cargo")), _jettison, box)
				j.custom_minimum_size = Vector2(240, 38)
		"extras":
			box.add_child(_scroll(str(data.get("extras", "")), 280))
		"honors":
			box.add_child(_scroll(str(data.get("honors", "")), 280))
		"missions":
			focus_target = _build_missions(box, active_btn)
	if _info_msg != "":
		_lbl(_info_msg, 14, Color(1.0, 0.8, 0.5), box)
	var done := _btn(str(_labels.get("done", "Done")), close_info, box)
	done.custom_minimum_size = Vector2(160, 38)
	if focus_tab:
		_focus(focus_target if focus_target != null else done)


func _tab_label(t: String) -> String:
	if t == "missions":
		return "Missions"
	return str(_labels.get(t, t.capitalize()))


func _switch_tab(t: String) -> void:
	_info_tab = t
	_info_msg = ""
	_build_info()


func _grid(rows: Array) -> GridContainer:
	var g := GridContainer.new()
	g.columns = 2
	g.add_theme_constant_override("h_separation", 14)
	g.add_theme_constant_override("v_separation", 4)
	for r in rows:
		_lbl(str(r[0]), 15, COL_DIM, g)
		_lbl(str(r[1]), 15, Color(0.92, 0.94, 1.0), g)
	return g


func _jettison() -> void:
	var line: String = nova.jettison_cargo()
	_info_msg = line
	if line != "":
		log_message.emit(line)
	_build_info()


# The Missions tab: the active missions in slot order, the selected one's brief
# and objective on the right, Abort (disabled when the mission forbids it).
func _build_missions(box: VBoxContainer, tab_btn: Button) -> Control:
	var missions = _json(nova.mission_list())
	if not (missions is Array):
		missions = []
	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 16)
	box.add_child(body)
	var list := VBoxContainer.new()
	list.custom_minimum_size = Vector2(300, 0)
	body.add_child(list)
	var detail := VBoxContainer.new()
	detail.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.add_child(detail)
	if missions.is_empty():
		_lbl("No active missions.", 15, COL_DIM, list)
		return tab_btn
	var sel := -1
	for i in missions.size():
		if int(missions[i].id) == _info_sel:
			sel = i
	if sel < 0:
		sel = 0
		_info_sel = int(missions[0].id)
	var first: Button = null
	var brief := _lbl("", 14, Color(0.92, 0.94, 1.0), detail)
	var objective := _lbl("", 14, COL_AMBER, detail)
	var where := _lbl("", 14, COL_DIM, detail)
	var abort_btn := _btn(str(_labels.get("abort", "Abort")), _abort_selected, detail)
	var show := func(i: int):
		var m: Dictionary = missions[i]
		_info_sel = int(m.id)
		brief.text = str(m.brief)
		objective.text = ("Objective: " + str(m.objective)) + ("  (failed)" if m.failed else "")
		where.text = ("%s — %s" % [m.destination, m.system]) if str(m.destination) != "" else ""
		abort_btn.disabled = not m.canAbort
	for i in missions.size():
		var m: Dictionary = missions[i]
		var b := Button.new()
		b.text = ("• " if m.failed else "") + str(m.name)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 32)
		b.clip_text = true
		b.focus_entered.connect(show.bind(i))
		b.pressed.connect(show.bind(i))
		list.add_child(b)
		if i == sel:
			first = b
	show.call(sel)
	return first


func _abort_selected() -> void:
	if _info_sel < 0:
		nova.sound_beep(4)
		return
	if nova.mission_abort(_info_sel):
		_info_sel = -1
	_build_info()
