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

const StoryGuide = preload("res://screens/StoryGuide.gd")
const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")
const CD = preload("res://ui/classic/ClassicDialog.gd")
const CS = preload("res://ui/classic/ClassicScreen.gd")
const Prefs = preload("res://Prefs.gd")
const Movies = preload("res://Movies.gd")
const MoviePlayer = preload("res://ui/MoviePlayer.gd")
const DescMovie = preload("res://ui/DescMovie.gd")

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
var _movie_shown_id: int = -1     # mission whose dësc movie already played for the pending offer
var _movie_playing: bool = false
var _text_movie_done: bool = false   # the head story text's dësc movie already played (before-text kind)


func setup(world) -> void:
	nova = world
	layer = 60
	ClassicTheme.setup(world)


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
	# (silent: story text, offers and movies have no sound site in the original)


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
	# The text's dësc movie (completion / failure / refusal / briefing texts: Ui_RunTravelSelectionDialog
	# 0x004982a0) plays before the text unless its Flags put it after.
	if not _text_movie_done:
		var clip: Dictionary = DescMovie.lookup(int(t.get("desc", -1)))
		if not clip.is_empty() and not bool(clip.get("after", false)):
			_text_movie_done = true
			_play_movie(clip.info, _open_text)
			return
	if ClassicTheme.classic("dialogs"):
		_open_text_classic(t)
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
	var t = _json(nova.story_text_info())
	var clip: Dictionary = DescMovie.lookup(int(t.get("desc", -1))) if (t is Dictionary and not t.is_empty()) else {}
	_close_modal()
	if not clip.is_empty() and bool(clip.get("after", false)):
		_play_movie(clip.info, _finish_text)   # Flags 0x0001: the movie follows the text
	else:
		_finish_text()


func _finish_text() -> void:
	_text_movie_done = false
	nova.story_text_dismiss()


# MARK: Mission offer --------------------------------------------------------

func _open_offer() -> void:
	var o = _json(nova.offer_state())
	if not (o is Dictionary) or o.is_empty():
		return
	if _movie_playing:
		return
	# The offer's dësc movie (mission board / Frozen Heart / ARPIA2 briefings) plays before the text
	# unless its Flags put it after (0x00442510); same rules as the Apple MissionBoardView.
	var mv: Dictionary = _offer_movie(int(o.get("id", -1)))
	if not mv.is_empty() and not bool(mv.after) and _movie_shown_id != int(o.get("id", -1)):
		_movie_shown_id = int(o.get("id", -1))
		_play_movie(mv.info, _open_offer)
		return
	if ClassicTheme.classic("dialogs"):
		_open_offer_classic(o)
		return
	var box := _dialog_root(620)
	var title_row := HBoxContainer.new()
	box.add_child(title_row)
	var title_l := _lbl(str(o.get("title", "")), 22, COL_AMBER, title_row)
	var _bo = StoryGuide.make_badge(nova, int(o.get("id", -1)), self)
	if _bo != null:
		title_row.add_child(_bo)
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
	_finish_offer(func(): nova.offer_accept())


func _offer_decline() -> void:
	_finish_offer(func(): nova.offer_decline())


## Close the offer dialog and run `action`, after the movie when the dësc says so (Flags 0x0001).
func _finish_offer(action: Callable) -> void:
	var o = _json(nova.offer_state())
	var id: int = int(o.get("id", -1)) if o is Dictionary else -1
	_close_modal()
	var mv: Dictionary = _offer_movie(id) if id >= 0 else {}
	_movie_shown_id = -1
	if not mv.is_empty() and bool(mv.after):
		_play_movie(mv.info, action)
	else:
		action.call()


## {info, after} for the pending offer's dësc movie when it can play right now, else {}. A clip that is
## found but not converted yet starts converting in the background (it plays next time), as the race clips do.
func _offer_movie(mission_id: int) -> Dictionary:
	if mission_id < 0 or not bool(Prefs.get_value("classic", "play_movies")) or not ClassDB.class_exists("NovaPlugins"):
		return {}
	var pl: Object = ClassDB.instantiate("NovaPlugins")
	if pl == null or not pl.has_method("desc_movie"):
		return {}
	var dm = _json(pl.desc_movie(3872 + mission_id))   # MissionRes.offerTextID
	if not (dm is Dictionary) or str(dm.get("movie", "")).strip_edges() == "":
		return {}
	var path: String = Movies.find_movie(str(dm.movie).strip_edges(), Movies.search_roots(""))
	if path == "":
		return {}
	var info: Dictionary = Movies.ready(path)
	if info.is_empty():
		Movies.convert_async(path)
		return {}
	return {"info": info, "after": bool(dm.get("after", false))}


## A skippable full-dialog movie; `then` runs when it ends, is skipped or fails.
func _play_movie(info: Dictionary, then: Callable) -> void:
	_movie_playing = true
	var box := _dialog_root(520)
	var player: Control = MoviePlayer.new()
	player.name = "offer_movie"
	player.setup(info, Vector2(480, 300))
	box.add_child(player)
	var skip := _btn("Skip", func(): player.skip(), box)
	_open_modal(box, "movie", [skip], func(): player.skip())
	_focus(skip)
	player.finished.connect(func():
		_movie_playing = false
		_close_modal()
		then.call())


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
	if ClassicTheme.classic("dialogs"):
		_build_info_classic(focus_tab)
		return
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
		var _bm = StoryGuide.make_badge(nova, int(m.id), self)
		if _bm != null:
			b.add_child(_bm)
			_bm.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT, Control.PRESET_MODE_KEEP_SIZE, 6)
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


# MARK: Classic (original DLOG/DITL) dialogs ---------------------------------------------
# Story text: the generic dësc reader (DITL 3003 text-only on PICT 8524/8525/8526 sized to the
# text, 3004 with the dësc picture on 8527). Mission offer: DITL 1016 "Single Mission" on
# 8521/8522/8523. Player Info: DITL 1017 on 8518/8519/8520. Mission Info: DITL 1012 on 8517.

func _info_rect(did: int, idx: int, stock: Rect2i) -> Rect2i:
	return CS.rect(nova, did, idx, stock)


func _modal_host(d: Control, kind: String, buttons: Array, cancel: Callable) -> void:
	_prev_focus = get_viewport().gui_get_focus_owner()
	_modal = CD.modal(self, d, 0.6)
	_modal_kind = kind
	_modal_buttons = buttons
	_modal_cancel = cancel
	# (silent: story text, offers and movies have no sound site in the original)


## Three stacked PICTs as one frame (top / stretched middle / bottom) at `size`.
func _three_slice(d: Control, top: int, mid: int, bot: int, top_h: int, bot_h: int) -> void:
	var h: int = d.window_size.y
	var w: int = d.window_size.x
	for part in [[top, 0, top_h], [mid, top_h, h - top_h - bot_h], [bot, h - bot_h, bot_h]]:
		var tex := ClassicTheme.pict(part[0])
		var tr := TextureRect.new()
		tr.texture = tex
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_SCALE
		tr.position = Vector2(0, part[1])
		tr.size = Vector2(w, part[2])
		tr.mouse_filter = Control.MOUSE_FILTER_STOP
		d.add_child(tr)


func _open_text_classic(t: Dictionary) -> void:
	var text := str(t.get("text", ""))
	var pid := int(t.get("pict", -1))
	var with_pic := pid >= 128 and ClassicTheme.pict(pid) != null
	var did := 3004 if with_pic else 3003
	var win := Vector2i(441, 313)
	var parsed = JSON.parse_string(nova.classic_dialog(did))
	if parsed is Dictionary and parsed.has("w"):
		win = Vector2i(int(parsed["w"]), int(parsed["h"]))
	var ok_r := CS.rect(nova, did, 0, Rect2i(91, 276, 259, 25))
	var pic_r := CS.rect(nova, did, 1, Rect2i(10, 10, 200, 200))
	var txt_r := CS.rect(nova, did, 2, Rect2i(20, 20, 400, 240))
	var shrink := 0
	if not with_pic:
		var th := int(ceil(ClassicTheme.body_font().get_multiline_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, txt_r.size.x, 12).y))
		if th < txt_r.size.y:
			shrink = (txt_r.size.y - maxi(th, 0x30)) - 16
	win.y -= shrink
	var d: Control = CD._make(nova, win, CD.Chrome.PICT if with_pic else CD.Chrome.PANEL)
	d._add_background(ClassicTheme.pict(8527) if with_pic else null)
	if with_pic:
		CS.picture(d, ClassicTheme.pict(pid), Rect2i(pic_r.position, Vector2i(ClassicTheme.pict(pid).get_size())), TextureRect.STRETCH_KEEP)
	var sc := CS.scroll_text(d, text, Rect2i(txt_r.position, Vector2i(txt_r.size.x, txt_r.size.y - shrink)), 12, Color.WHITE)
	d.beep = false
	var ok: TextureButton = d.add_button("OK", Rect2i(ok_r.position.x, ok_r.position.y - shrink, ok_r.size.x, ok_r.size.y), 0)
	ok.name = "story_ok"
	d.actions[0] = _dismiss_text
	d.default_item = 0
	_modal_host(d, "text", [ok], _dismiss_text)
	_focus(ok)


func _open_offer_classic(o: Dictionary) -> void:
	var win := Vector2i(441, 317)
	var parsed = JSON.parse_string(nova.classic_dialog(1016))
	if parsed is Dictionary and parsed.has("w"):
		win = Vector2i(int(parsed["w"]), int(parsed["h"]))
	var d: Control = CD._make(nova, win, CD.Chrome.NONE)
	d.beep = false
	_three_slice(d, 8521, 8522, 8523, 9, 40)
	var pane := CS.rect(nova, 1016, 2, Rect2i(12, 9, 415, 267))
	var content := VBoxContainer.new()
	content.custom_minimum_size = Vector2(pane.size.x - 8, 0)
	content.add_theme_constant_override("separation", 5)
	var title := Label.new()
	title.text = str(o.get("title", ""))
	title.add_theme_font_override("font", ClassicTheme.chrome_font())
	title.add_theme_font_size_override("font_size", 12)
	title.add_theme_color_override("font_color", Color.WHITE)
	var title_row := HBoxContainer.new()
	title_row.add_theme_constant_override("separation", 4)
	title_row.add_child(title)
	var _bo = StoryGuide.make_badge(nova, int(o.get("id", -1)), self)
	if _bo != null:
		_bo.custom_minimum_size = Vector2(22, 16)
		title_row.add_child(_bo)
	content.add_child(title_row)
	var tex := ClassicTheme.pict(int(o.get("pict", -1))) if int(o.get("pict", -1)) >= 0 else null
	if tex != null:
		var tr := TextureRect.new()
		tr.texture = tex
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		var sz := tex.get_size()
		var k := minf(1.0, minf(140.0 / sz.y, (pane.size.x - 8.0) / sz.x))
		tr.custom_minimum_size = Vector2(sz.x * k, sz.y * k)
		content.add_child(tr)
	var body := Label.new()
	body.text = str(o.get("text", ""))
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.custom_minimum_size = Vector2(pane.size.x - 10, 0)
	body.add_theme_font_override("font", ClassicTheme.body_font())
	body.add_theme_font_size_override("font_size", 11)
	body.add_theme_color_override("font_color", Color.WHITE)
	body.add_theme_constant_override("line_spacing", 0)
	content.add_child(body)
	if str(o.get("destination", "")) != "":
		var dest := Label.new()
		dest.text = "Destination: %s" % o.destination
		dest.add_theme_font_override("font", ClassicTheme.body_font())
		dest.add_theme_font_size_override("font_size", 10)
		dest.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
		content.add_child(dest)
	var sc := CS.PaneScroll.new()
	sc.position = Vector2(pane.position)
	sc.size = Vector2(pane.size)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.get_v_scroll_bar().modulate = Color(1, 1, 1, 0)
	sc.add_child(content)
	d.add_child(sc)
	var buttons := []
	var cancel := Callable()
	var yes: TextureButton
	if o.get("canRefuse", true):
		var no := CS.button(d, str(o.get("refuse", "No")), CS.rect(nova, 1016, 1, Rect2i(117, 285, 99, 25)), 1, _offer_decline, true, "offer_refuse")
		yes = CS.button(d, str(o.get("accept", "Yes")), CS.rect(nova, 1016, 0, Rect2i(225, 285, 99, 25)), 0, _offer_accept, true, "offer_accept")
		buttons = [no, yes]
		cancel = _offer_decline
	else:
		yes = CS.button(d, str(o.get("accept", "Yes")), CS.rect(nova, 1016, 5, Rect2i(173, 285, 99, 25)), 5, _offer_accept, true, "offer_accept")
		buttons = [yes]
	d.default_item = 0
	_modal_host(d, "offer", buttons, cancel)
	_focus(yes)


func _tab_pict_button(d: Control, label: String, r: Rect2i, idx: int, active: bool, cb: Callable, key: String) -> void:
	var b := CS.button(d, label, r, idx, cb, true, key)
	if active:
		b.texture_normal = ClassicTheme.button_texture(r.size.x, 1)


func _build_info_classic(focus_tab: bool) -> void:
	var was_open := _info != null
	if _info != null:
		var old := _info
		_info = null
		old.get_parent().remove_child(old)
		old.queue_free()
	if not was_open:
		nova.sound_beep(2)
	var data = _json(nova.player_info())
	if not (data is Dictionary):
		data = {}
	var d: Control
	var focus_key := "done"
	if _info_tab == "missions":
		d = _mission_info_dialog(data)
	else:
		d = _player_info_dialog(data)
	d.beep = false
	_info = CD.modal(self, d, 0.55)
	if focus_tab:
		var target: Control = d.find_child("btn_" + (_info_focus if _info_focus != "" else focus_key), true, false)
		if target == null:
			target = d.find_child("btn_done", true, false)
		_focus(target)


var _info_focus := ""


func _player_info_dialog(data: Dictionary) -> Control:
	var win := Vector2i(413, 227)
	var parsed = JSON.parse_string(nova.classic_dialog(1017))
	if parsed is Dictionary and parsed.has("w"):
		win = Vector2i(int(parsed["w"]), int(parsed["h"]))
	var d: Control = CD._make(nova, win, CD.Chrome.NONE)
	_three_slice(d, 8518, 8519, 8520, 40, 40)
	var names := ["general", "cargo", "extras", "honors"]
	var defaults := ["General", "Cargo", "Extras", "Honors"]
	for i in 4:
		var t: String = names[i]
		var r := CS.rect(nova, 1017, 1 + i, Rect2i(7 + 100 * i, 8, 99, 25))
		_tab_pict_button(d, str(_labels.get(t, defaults[i])), r, 1 + i, t == _info_tab, _switch_tab.bind(t), "tab_" + t)
		d.items[1 + i].name = "btn_tab_" + t
	var pane := CS.rect(nova, 1017, 5, Rect2i(4, 40, 405, 141))
	match _info_tab:
		"general":
			var g: Dictionary = data.get("general", {})
			var holder := Control.new()
			holder.custom_minimum_size = Vector2(pane.size.x - 12, 0)
			var rows_l: Array = g.get("left", [])
			var rows_r: Array = g.get("right", [])
			var n := maxi(rows_l.size(), rows_r.size())
			for i in n:
				if i < rows_l.size():
					_row_cell(holder, str(rows_l[i][0]), 6, 75, Color(0.6, 0.6, 0.6), 4 + i * 15)
					_row_cell(holder, str(rows_l[i][1]), 85, 120, Color.WHITE, 4 + i * 15)
				if i < rows_r.size():
					_row_cell(holder, str(rows_r[i][0]), 213, 70, Color(0.6, 0.6, 0.6), 4 + i * 15)
					_row_cell(holder, str(rows_r[i][1]), 283, 120, Color.WHITE, 4 + i * 15)
			var eco := Label.new()
			eco.text = str(g.get("economy", ""))
			eco.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
			eco.position = Vector2(6, 8 + n * 15)
			eco.size = Vector2(393, 40)
			eco.add_theme_font_override("font", ClassicTheme.body_font())
			eco.add_theme_font_size_override("font_size", 10)
			eco.add_theme_color_override("font_color", Color.WHITE)
			holder.add_child(eco)
			holder.custom_minimum_size.y = 10 + n * 15 + 40
			var sc := CS.PaneScroll.new()
			sc.position = Vector2(pane.position)
			sc.size = Vector2(pane.size)
			sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
			sc.get_v_scroll_bar().modulate = Color(1, 1, 1, 0)
			sc.add_child(holder)
			d.add_child(sc)
		"cargo":
			CS.scroll_text(d, str(data.get("cargo", "")), Rect2i(pane.position.x + 6, pane.position.y + 4, 393, pane.size.y - 4), 10, Color.WHITE)
		"extras":
			CS.scroll_text(d, str(data.get("extras", "")), Rect2i(pane.position.x + 6, pane.position.y + 4, 393, pane.size.y - 4), 10, Color.WHITE)
		_:
			CS.scroll_text(d, str(data.get("honors", "")), Rect2i(pane.position.x + 6, pane.position.y + 4, 393, pane.size.y - 4), 10, Color.WHITE)
	if _info_tab == "cargo" and data.get("canJettison", false):
		CS.button(d, str(_labels.get("jettison", "Jettison Cargo")), CS.rect(nova, 1017, 6, Rect2i(60, 195, 150, 25)), 6,
			_jettison_confirm, true, "btn_jettison")
		d.items[6].name = "btn_jettison"
	var done := CS.button(d, str(_labels.get("done", "Done")), CS.rect(nova, 1017, 0, Rect2i(293, 195, 99, 25)), 0, close_info, true, "btn_done")
	done.name = "btn_done"
	if _info_msg != "":
		CS.text(d, _info_msg, Rect2i(8, 184, 390, 12), 10, CS.AMBER)
	_info_focus = "tab_" + _info_tab
	return d


func _jettison_confirm() -> void:
	var prompt := ClassicTheme.string_at(2002, 291, "Jettison all cargo?")
	var c := CD.confirm(nova, prompt, {"ok": ClassicTheme.string_at(150, 50, "Yes"), "cancel": ClassicTheme.string_at(150, 51, "No")})
	var host := CD.modal(self, c, 0.4)
	c.activated.connect(func(i: int):
		host.queue_free()
		if i == 0:
			_jettison())


func _mission_info_dialog(data: Dictionary) -> Control:
	var d: Control = CS.frame(nova, 1012, 8517)
	CS.text(d, str(data.get("date", "")), CS.rect(nova, 1012, 6, Rect2i(343, 4, 122, 12)), 10, Color(0.75, 0.75, 0.75), HORIZONTAL_ALIGNMENT_RIGHT)
	var missions = _json(nova.mission_list())
	if not (missions is Array):
		missions = []
	var lr := CS.rect(nova, 1012, 1, Rect2i(9, 24, 195, 84))
	var br := CS.rect(nova, 1012, 3, Rect2i(218, 26, 242, 91))
	var brief := CS.scroll_text(d, "", br, 10, Color(0.82, 0.82, 0.82))
	var abort_btn := CS.button(d, str(_labels.get("abort", "Abort")), CS.rect(nova, 1012, 4, Rect2i(57, 125, 99, 25)), 4,
		_abort_selected, false, "abort")
	abort_btn.name = "btn_abort"
	abort_btn.refused.connect(func(): if _info_sel < 0: nova.sound_beep(4))
	var done := CS.button(d, str(_labels.get("done", "Done")), CS.rect(nova, 1012, 0, Rect2i(290, 125, 99, 25)), 0, close_info, true, "done")
	done.name = "btn_done"
	if missions.is_empty():
		var l := CS.text(d, "No active missions.", lr, 11, Color(0.6, 0.6, 0.6), HORIZONTAL_ALIGNMENT_CENTER)
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		_info_focus = "done"
		return d
	var sel := -1
	for i in missions.size():
		if int(missions[i].id) == _info_sel:
			sel = i
	if sel < 0:
		sel = 0
		_info_sel = int(missions[0].id)
	var box := Control.new()
	box.position = Vector2(lr.position)
	box.size = Vector2(lr.size)
	box.clip_contents = true
	d.add_child(box)
	var rows := []
	var show := func(i: int):
		var m: Dictionary = missions[i]
		_info_sel = int(m.id)
		brief.label.text = str(m.brief)
		brief.scroll_vertical = 0
		abort_btn.disabled = not m.canAbort
		for k in rows.size():
			rows[k].set_selected(k == i)
	for i in missions.size():
		var m: Dictionary = missions[i]
		var rb := CS.Row.new()
		rb.position = Vector2(0, i * 16)
		rb.size = Vector2(lr.size.x, 16)
		rb.name = "btn_m%d" % i
		rb.hi.color = Color(1.0, 0.7, 0.28, 0.28)
		var _bm = StoryGuide.make_badge(nova, int(m.id), self)
		if _bm != null:
			_bm.custom_minimum_size = Vector2(18, 16)
			_bm.size = Vector2(18, 16)
			_bm.position = Vector2(lr.size.x - 22, 0)
			rb.add_child(_bm)
		CS.cell(rb, ("• " if m.failed else "") + str(m.name), 5, lr.size.x - 8 - (22 if _bm != null else 0), 16, Color.WHITE if i == sel else Color(0.78, 0.78, 0.78), HORIZONTAL_ALIGNMENT_LEFT, 11)
		rb.focus_entered.connect(show.bind(i))
		rb.pressed.connect(show.bind(i))
		box.add_child(rb)
		d._register(30 + i, rb, Rect2i(lr.position.x, lr.position.y + i * 16, lr.size.x, 16), true)
		rows.append(rb)
	show.call(sel)
	_info_focus = "m%d" % sel
	return d


func _row_cell(parent: Control, text: String, x: int, w: int, color: Color, y: int) -> void:
	var l := CS.cell(parent, text, x, w, 12, color, HORIZONTAL_ALIGNMENT_LEFT, 9)
	l.position.y = y
