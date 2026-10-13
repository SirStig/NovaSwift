# NOVA Swift — the docked spaceport (Godot): landing screen, Trade Center,
# Outfitter, Shipyard (+ Ship Info), Recharge and Leave.
#
# Every rule — which services a spöb offers, what the outfitter/shipyard list,
# prices, trade-ins, whether a purchase is allowed, refuelling — lives in shared
# Swift (SpaceportShops / PilotEconomy / LandedServices, reached through
# NovaWorld's "Spaceport" bridge section), the same code the Apple SwiftUI
# spaceport calls. This file only lays out Controls and routes input.
#
# Controller-first, using only Godot focus navigation: arrows / d-pad / left
# stick move focus, Enter / A press, Esc / B back out (from the landing screen B
# launches). Extra actions (Controls.gd): X / S sell, Y / Q buy-quantity prompt,
# RB / E sell-quantity prompt, Y / I ship info. Mouse works everywhere.
#
# Loaded with preload() (no class_name), like PilotMenu.gd.
extends CanvasLayer

## The player chose Leave / pressed back on the landing screen. Main performs
## the actual nova.launch().
signal launch_requested

const BarScreens = preload("res://screens/BarScreens.gd")   # Hire Escort, Gamble
const StoryGuide = preload("res://screens/StoryGuide.gd")
const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")
const SpaceportClassic = preload("res://screens/SpaceportClassic.gd")   # the original-UI look
const DescMovie = preload("res://ui/DescMovie.gd")   # the stellar's own dësc movie, played as the player docks

const PANEL_SIZE := Vector2(1180, 660)
const COL_DIM := Color(0.62, 0.66, 0.74)
const COL_HI := Color(1.0, 0.95, 0.7)

var _nova: Object
var _root: Control
var _col: VBoxContainer           # the current screen's content
var _overlay: Control             # quantity prompt / ship info, above the screen
var _overlay_back: Callable = Callable()
var _back: Callable = Callable()  # what ui_cancel does on the current screen
var _screen := ""
var _status: Label
var _credits_label: Label
var _info := {}
var _tex := {}                    # PICT id -> Texture2D (or null)
var _spob_tex := {}               # spöb id -> Texture2D (or null)

# Trade
var _trade_sel := 0
var _trade_data := {}
# Outfitter / shipyard
var _items: Array = []
var _sel_id := -1
var _detail: Dictionary = {}      # nodes updated when the selection changes
var _tiles := {}
var _message := ""

# Story: Bar, Mission BBS, Holovid, lane offers
var _story_labels := {}
var _bar_active := false          # the patrons are still lining up to make their pitch
var _bar_wait := 0.0
var _bar_offer_up := false
var _shop_wait := 0.0
var _reopen_bbs_pending := false  # the BBS reopens afresh once an accept's texts are read
var _bbs_list: Array = []
var _bbs_nodes: Dictionary = {}
var _bar_screens                  # BarScreens: the bar's Hire Escort + Gamble overlays
var _c                            # SpaceportClassic: the Classic (original EV Nova) windows
var _modern_center: Control       # the plain Nova Swift panel's container (hidden in Classic)


func setup(nova: Object) -> void:
	_nova = nova
	ClassicTheme.setup(nova)
	_c = SpaceportClassic.new()
	_c.setup(self, nova)
	_bar_screens = BarScreens.new()
	_bar_screens.setup(self, nova)
	layer = 40
	visible = false
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_root)
	var dim := ColorRect.new()
	dim.color = Color(0.03, 0.03, 0.06, 1.0)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(dim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)
	_modern_center = center
	var box := PanelContainer.new()
	box.custom_minimum_size = PANEL_SIZE
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.09, 0.09, 0.12)
	style.border_color = Color(0.45, 0.5, 0.6)
	style.set_border_width_all(2)
	style.set_corner_radius_all(4)
	style.set_content_margin_all(14)
	box.add_theme_stylebox_override("panel", style)
	center.add_child(box)
	_col = VBoxContainer.new()
	_col.add_theme_constant_override("separation", 6)
	box.add_child(_col)


func is_open() -> bool:
	return visible


## True when the docked UI is drawn in the Classic (original EV Nova) presentation.
func _classic() -> bool:
	return ClassicTheme.classic("dialogs")


## Common start of every screen build: drop the overlay, reset per-screen handles.
func _begin(back: Callable) -> void:
	_close_overlay()
	_back = back
	_detail = {}
	_tiles = {}
	_status = null


## Show the landing screen (call once per landing).
func open() -> void:
	_message = ""
	visible = true
	_modern_center.visible = not _classic()
	_story_labels = JSON.parse_string(_nova.story_labels()) if _nova.has_game() else {}
	_show_hub()
	# Docking plays the stellar's dësc movie first (Stellar_RunDockAndLaunchSequence 0x00455e10 ->
	# Ui_LoadDescAndPlayMovie 0x0049e3c0, whatever the Flags say about "after the text").
	var clip: Dictionary = {}
	if _nova.has_game() and _info is Dictionary:
		clip = DescMovie.lookup(int(_info.get("id", -1)))
	if clip.is_empty():
		_roll_landing_offer()
	else:
		DescMovie.play(self, clip, _roll_landing_offer)


## The main spaceport makes one lane offer as the player lands (0x00448670):
## simply touching down can hand over a mission. Its dialog is StoryScreens'.
func _roll_landing_offer() -> void:
	if _nova.has_game() and visible:
		_nova.offer_roll("spaceport")


## Leaving the outfitter zeroes Flags 0x0010 items and charts (EC-28).
func _outfitter_closed() -> void:
	if _nova != null and _nova.has_method("outfitter_close"):
		_nova.outfitter_close()


func close() -> void:
	if _screen == "outfitter":
		_outfitter_closed()
	_close_overlay()
	_c.clear_all()
	visible = false
	_screen = ""
	_bar_active = false
	_reopen_bbs_pending = false


func _unhandled_input(event: InputEvent) -> void:
	if not visible or _nova.story_blocks_flight():
		return   # a story text / offer dialog above owns input
	if event.is_action_pressed("ui_cancel") or (_screen == "hub" and not _overlay and event.is_action_pressed("launch")):
		if _overlay_back.is_valid():
			_overlay_back.call()
		elif _back.is_valid():
			_back.call()
		get_viewport().set_input_as_handled()
		return
	if _overlay:
		return
	match _screen:
		"trade":
			if event.is_action_pressed("trade_sell"):
				_trade_sell(-1)
			elif event.is_action_pressed("shop_buy_qty"):
				_trade_prompt(true)
			elif event.is_action_pressed("shop_sell_qty"):
				_trade_prompt(false)
		"outfitter":
			if event.is_action_pressed("trade_sell"):
				_outfit_sell(1)
			elif event.is_action_pressed("shop_buy_qty"):
				_outfit_prompt(true)
			elif event.is_action_pressed("shop_sell_qty"):
				_outfit_prompt(false)
		"shipyard":
			if event.is_action_pressed("ship_info"):
				_ship_info()
		"bbs":
			if event.is_action_pressed("bbs_accept"):
				_bbs_accept()


# --- widgets -------------------------------------------------------------------

func _clear(title: String, back: Callable) -> void:
	_close_overlay()
	for c in _col.get_children():
		_col.remove_child(c)
		c.queue_free()
	_back = back
	_detail = {}
	_tiles = {}
	_status = null
	var head := HBoxContainer.new()
	var t := Label.new()
	t.text = title
	t.add_theme_font_size_override("font_size", 26)
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(t)
	_credits_label = Label.new()
	_credits_label.add_theme_font_size_override("font_size", 16)
	_credits_label.add_theme_color_override("font_color", COL_HI)
	head.add_child(_credits_label)
	_col.add_child(head)
	_update_credits()


func _update_credits() -> void:
	if _credits_label != null:
		_credits_label.text = "%s cr" % _commas(int(_nova.player_credits()))


func _label(text: String, size := 15, color := COL_DIM, parent: Node = null) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	(parent if parent != null else _col).add_child(l)
	return l


func _button(text: String, cb: Callable, parent: Node = null) -> Button:
	var b := Button.new()
	b.text = text
	b.custom_minimum_size = Vector2(0, 38)
	b.pressed.connect(cb)
	(parent if parent != null else _col).add_child(b)
	return b


func _msg(text: String) -> void:
	_message = text
	if _status != null:
		_status.text = text
	_c.set_message(text)


func _add_status() -> void:
	_status = _label(_message, 15, Color(1.0, 0.8, 0.5))


func _focus(b: Control) -> void:
	(func(): if is_instance_valid(b) and b.is_inside_tree(): b.grab_focus()).call_deferred()


# A focusable table row: cells laid out in fixed-width columns.
func _row(cells: Array, widths: Array, cb: Callable, header := false) -> Button:
	var b := Button.new()
	b.custom_minimum_size = Vector2(0, 30)
	b.pressed.connect(cb)
	var h := HBoxContainer.new()
	h.set_anchors_preset(Control.PRESET_FULL_RECT)
	h.offset_left = 10
	h.offset_right = -10
	h.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(h)
	for i in cells.size():
		var l := Label.new()
		l.text = str(cells[i])
		l.custom_minimum_size = Vector2(widths[i], 0)
		l.mouse_filter = Control.MOUSE_FILTER_IGNORE
		l.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
		if i > 0:
			l.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
		h.add_child(l)
	return b


func _picture(tex: Texture2D, size: Vector2) -> TextureRect:
	var r := TextureRect.new()
	r.custom_minimum_size = size
	r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	r.texture = tex
	return r


func _pict_tex(pict_id: int) -> Texture2D:
	if pict_id < 0:
		return null
	if _tex.has(pict_id):
		return _tex[pict_id]
	var tex: Texture2D = null
	var wh: PackedInt32Array = _nova.pict_info(pict_id)
	if wh.size() >= 2 and wh[0] > 0 and wh[1] > 0:
		var bytes: PackedByteArray = _nova.pict_rgba(pict_id)
		if bytes.size() >= wh[0] * wh[1] * 4:
			tex = ImageTexture.create_from_image(
				Image.create_from_data(wh[0], wh[1], false, Image.FORMAT_RGBA8, bytes))
	_tex[pict_id] = tex
	return tex


# A station has no landing PICT: its own space sprite (frame 0) stands in.
func _spob_sprite_tex(spob_id: int) -> Texture2D:
	if _spob_tex.has(spob_id):
		return _spob_tex[spob_id]
	var tex: Texture2D = null
	var info: PackedInt32Array = _nova.sprite_info(5, spob_id)
	if info.size() >= 7 and info[5] > 0 and info[6] > 0:
		var bytes: PackedByteArray = _nova.sprite_rgba(5, spob_id)
		if bytes.size() >= info[5] * info[6] * 4:
			var img := Image.create_from_data(info[5], info[6], false, Image.FORMAT_RGBA8, bytes)
			tex = ImageTexture.create_from_image(img.get_region(Rect2i(0, 0, info[0], info[1])))
	_spob_tex[spob_id] = tex
	return tex


# --- landing screen ------------------------------------------------------------

func _show_hub() -> void:
	# Closing a shop resets the lane-offer context (0x00448660); leaving the
	# Mission BBS drops its shown listing.
	if _screen == "outfitter":
		_outfitter_closed()
	if _screen in ["trade", "outfitter", "shipyard"]:
		_nova.offer_clear_context()
	elif _screen == "bbs":
		_nova.bbs_close()
	_bar_active = false
	_screen = "hub"
	_info = JSON.parse_string(_nova.spaceport_info())
	if not (_info is Dictionary) or _info.is_empty():
		_info = {"name": "Spaceport", "description": "", "labels": {}}
	var lb: Dictionary = _info.get("labels", {})
	if _classic():
		_begin(func(): launch_requested.emit())
		_c.hub()
		return
	_clear(str(_info.name), func(): launch_requested.emit())

	var pic: Texture2D = _pict_tex(_nova.spaceport_picture_id(1, int(_info.get("id", -1))))
	if pic == null:
		pic = _spob_sprite_tex(int(_info.get("id", -1)))
	var frame := PanelContainer.new()
	var black := StyleBoxFlat.new()
	black.bg_color = Color.BLACK
	frame.add_theme_stylebox_override("panel", black)
	frame.add_child(_picture(pic, Vector2(612, 285)))
	var pic_row := CenterContainer.new()
	pic_row.add_child(frame)
	_col.add_child(pic_row)

	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 16)
	_col.add_child(body)
	var scroll := ScrollContainer.new()
	scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.custom_minimum_size = Vector2(0, 150)
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)
	var desc := Label.new()
	desc.text = str(_info.get("description", ""))
	desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	desc.add_theme_font_size_override("font_size", 14)
	scroll.add_child(desc)

	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(260, 0)
	body.add_child(side)
	var first: Button = null
	# Left column of the original: Bar, Mission BBS, Trade Center.
	if _info.get("bar", false):
		first = _button(lb.get("bar", "Bar"), _show_bar, side)
	if not _info.get("uninhabited", false) and _nova.has_game():
		var bbs := _button(str(_story_labels.get("missionBBS", "Mission BBS")), _open_bbs, side)
		first = first if first != null else bbs
	if _info.get("trade", false):
		var tb := _button(lb.get("trade", "Trade Center"), _show_trade, side)
		first = first if first != null else tb
	if _info.get("outfitter", false):
		var b := _button(lb.get("outfitter", "Outfitter"), _show_outfitter, side)
		first = first if first != null else b
	if _info.get("shipyard", false):
		var b := _button(lb.get("shipyard", "Shipyard"), _show_shipyard, side)
		first = first if first != null else b
	if _info.get("needsRecharge", false):
		var b := _button("%s  (%d/%d)" % [lb.get("recharge", "Recharge"), int(_info.fuel), int(_info.maxFuel)],
				_recharge, side)
		first = first if first != null else b
	var leave := _button(lb.get("leave", "Leave"), func(): launch_requested.emit(), side)
	_add_status()
	_focus(first if first != null else leave)


func _recharge() -> void:
	var cost: int = _nova.spaceport_recharge()
	_message = ("Refuelled for %s cr." % _commas(cost)) if cost > 0 else \
			("Refuelled." if cost == 0 else "")
	_show_hub()


# --- trade center ----------------------------------------------------------------

func _show_trade() -> void:
	if _screen != "trade":
		_shop_opened("trade")
	_screen = "trade"
	_trade_data = JSON.parse_string(_nova.trade_view())
	var rows: Array = _trade_data.get("rows", [])
	if _classic():
		_trade_sel = clampi(_trade_sel, 0, maxi(rows.size() - 1, 0))
		_begin(_show_hub)
		_c.trade()
		return
	_clear("Trade Center", _show_hub)
	var widths := [330, 90, 120, 140]
	var hd: Array = _trade_data.get("headers", ["Commodity", "Price", "Hold"])
	var head := _row([hd[0], "", hd[1], hd[2]], widths, func(): pass, true)
	head.disabled = true
	head.focus_mode = Control.FOCUS_NONE
	_col.add_child(head)
	_trade_sel = clampi(_trade_sel, 0, maxi(rows.size() - 1, 0))
	var focus_row: Button = null
	for i in rows.size():
		var r: Dictionary = rows[i]
		var b := _row([r.name, r.label, "%d cr/ton" % int(r.price), ("%d t" % int(r.held)) if int(r.held) > 0 else "—"],
				widths, _trade_buy.bind(-1, i))
		b.focus_entered.connect(func(): _trade_sel = i)
		match int(r.level):
			1: b.add_theme_color_override("font_color", Color(0.5, 0.9, 0.5))
			3: b.add_theme_color_override("font_color", Color(1, 0.5, 0.5))
		_col.add_child(b)
		if i == _trade_sel:
			focus_row = b
	if rows.is_empty():
		_label("No commodity exchange here.")
	var sp := Control.new()
	sp.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_col.add_child(sp)
	_label(str(_trade_data.get("status", "")), 14)
	if str(_trade_data.get("disaster", "")) != "":
		_label(str(_trade_data.disaster), 14, Color(1, 0.55, 0.3))
	_add_status()
	var bar := HBoxContainer.new()
	_col.add_child(bar)
	_button("Buy 10", func(): _trade_buy(-1, _trade_sel), bar)
	_button("Sell 10", func(): _trade_sell(-1), bar)
	_button("Buy…", func(): _trade_prompt(true), bar)
	_button("Sell…", func(): _trade_prompt(false), bar)
	var done := _button("Done", _show_hub, bar)
	for c in bar.get_children():
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label(_hint("A buy · X sell · Y buy… · RB sell… · B done", "Enter buy · S sell · Q buy… · E sell… · Esc done"), 13)
	_focus(focus_row if focus_row != null else done)


func _trade_buy(_unused: int, row: int) -> void:
	var rows: Array = _trade_data.get("rows", [])
	if row < 0 or row >= rows.size():
		return
	var n: int = _nova.trade_quantity(row, true, -1)
	var got: int = _nova.trade_buy(row, n) if n > 0 else 0
	_message = ("Bought %d t of %s." % [got, rows[row].name]) if got > 0 else "Can't buy any — no free space or credits."
	_show_trade()


func _trade_sell(row: int) -> void:
	row = _trade_sel if row < 0 else row
	var rows: Array = _trade_data.get("rows", [])
	if row < 0 or row >= rows.size():
		return
	var n: int = _nova.trade_quantity(row, false, -1)
	var got: int = _nova.trade_sell(row, n) if n > 0 else 0
	_message = ("Sold %d t of %s." % [got, rows[row].name]) if got > 0 else "Nothing to sell."
	_show_trade()


func _trade_prompt(buying: bool) -> void:
	var rows: Array = _trade_data.get("rows", [])
	if _trade_sel < 0 or _trade_sel >= rows.size():
		return
	var row := _trade_sel
	var top: int = _nova.trade_quantity(row, buying, 32000)
	if top <= 0:
		_msg("Nothing to %s." % ("buy" if buying else "sell"))
		return
	_prompt("%s how many tons of %s?" % ["Buy" if buying else "Sell", rows[row].name], top, top, func(q):
		var got: int = _nova.trade_buy(row, q) if buying else _nova.trade_sell(row, q)
		_message = "%s %d t of %s." % ["Bought" if buying else "Sold", got, rows[row].name]
		_show_trade())


# --- quantity prompt ---------------------------------------------------------------

# A modal "how many?" box, prefilled with the maximum as the original's is.
# Left/right ±1, up/down ±10, digits type, Backspace erases; OK / Cancel.
func _prompt(title: String, maxv: int, initial: int, on_ok: Callable) -> void:
	if _classic():
		_c.prompt(title, maxv, initial, on_ok)
		return
	_close_overlay()
	_overlay = _make_overlay()
	var box := _overlay_box(Vector2(520, 0))
	var state := {"q": clampi(initial, 1, maxv)}
	_label(title, 18, COL_HI, box)
	var qty := Button.new()
	qty.custom_minimum_size = Vector2(0, 48)
	qty.add_theme_font_size_override("font_size", 24)
	qty.text = str(state.q)
	box.add_child(qty)
	var set_q := func(v: int):
		state.q = clampi(v, 1, maxv)
		qty.text = str(state.q)
	qty.gui_input.connect(func(e: InputEvent):
		if e.is_action_pressed("ui_left"):
			set_q.call(state.q - 1)
		elif e.is_action_pressed("ui_right"):
			set_q.call(state.q + 1)
		elif e.is_action_pressed("ui_up"):
			set_q.call(state.q + 10)
		elif e.is_action_pressed("ui_down"):
			set_q.call(state.q - 10)
		else:
			return
		qty.accept_event())
	qty.gui_input.connect(func(e: InputEvent):
		if e is InputEventKey and e.pressed and not e.echo:
			if e.keycode >= KEY_0 and e.keycode <= KEY_9:
				set_q.call(int(str(state.q) + str(e.keycode - KEY_0)) if state.q < 100000 else state.q)
				qty.accept_event()
			elif e.keycode == KEY_BACKSPACE:
				set_q.call(int(str(state.q).substr(0, str(state.q).length() - 1)) if str(state.q).length() > 1 else 1)
				qty.accept_event())
	var steps := HBoxContainer.new()
	box.add_child(steps)
	for d in [-10, -1, 1, 10]:
		_button("%+d" % d, func(): set_q.call(state.q + d), steps).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_button("Max", func(): set_q.call(maxv), steps).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var bar := HBoxContainer.new()
	box.add_child(bar)
	var ok := _button("OK", func():
		var q: int = state.q
		_close_overlay()
		on_ok.call(q), bar)
	ok.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_button("Cancel", _close_overlay, bar).size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_overlay_back = _close_overlay
	_focus(qty)


func _make_overlay() -> Control:
	var o := Control.new()
	o.set_anchors_preset(Control.PRESET_FULL_RECT)
	var dim := ColorRect.new()
	dim.color = Color(0, 0, 0, 0.6)
	dim.set_anchors_preset(Control.PRESET_FULL_RECT)
	o.add_child(dim)
	_root.add_child(o)
	return o


func _overlay_box(min_size: Vector2) -> VBoxContainer:
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_overlay.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = min_size
	var style := StyleBoxFlat.new()
	style.bg_color = Color(0.11, 0.11, 0.15)
	style.border_color = Color(0.6, 0.65, 0.75)
	style.set_border_width_all(2)
	style.set_content_margin_all(16)
	panel.add_theme_stylebox_override("panel", style)
	center.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 8)
	panel.add_child(box)
	return box


func _close_overlay() -> void:
	var had := _overlay != null
	if _overlay != null:
		var o := _overlay
		_overlay = null
		o.get_parent().remove_child(o)
		o.queue_free()
	_overlay_back = Callable()
	if had:
		_c.overlay_closed()


# --- outfitter ---------------------------------------------------------------------

func _show_outfitter() -> void:
	if _screen != "outfitter":
		_nova.outfitter_open()
		_shop_opened("outfitter")
	_screen = "outfitter"
	var parsed = JSON.parse_string(_nova.outfitter_list())
	_items = parsed if parsed is Array else []
	if _classic():
		var fresh := _detail.is_empty()
		if not _items.is_empty() and _find_item(_sel_id) < 0:
			_sel_id = int(_items[0].id)
		_begin(_show_hub)
		_detail = {"classic": true}
		_c.shop_window("outfit", fresh)
		return
	_clear("Outfitter", _show_hub)
	if not _items.is_empty() and _find_item(_sel_id) < 0:
		_sel_id = int(_items[0].id)
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 14)
	_col.add_child(body)

	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(640, 440)
	scroll.follow_focus = true
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	scroll.add_child(grid)
	var focus_tile: Button = null
	for it in _items:
		var t := _tile(it, _outfit_tile_text(it))
		var id := int(it.id)
		t.pressed.connect(func():
			_sel_id = id
			_outfit_buy(1))
		t.focus_entered.connect(func(): _select(id))
		grid.add_child(t)
		_tiles[id] = t
		if id == _sel_id:
			focus_tile = t
	if _items.is_empty():
		_label("Nothing for sale here.", 15, COL_DIM, grid)

	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(470, 0)
	side.add_theme_constant_override("separation", 5)
	body.add_child(side)
	_detail.pic = _picture(null, Vector2(200, 200))
	var pic_row := CenterContainer.new()
	pic_row.add_child(_detail.pic)
	side.add_child(pic_row)
	_detail.name = _label("", 20, COL_HI, side)
	var dscroll := ScrollContainer.new()
	dscroll.custom_minimum_size = Vector2(0, 110)
	dscroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	side.add_child(dscroll)
	_detail.desc = Label.new()
	_detail.desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail.desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail.desc.add_theme_font_size_override("font_size", 13)
	dscroll.add_child(_detail.desc)
	_detail.stats = _label("", 14, Color(0.85, 0.88, 0.95), side)

	_add_status()
	var bar := HBoxContainer.new()
	_col.add_child(bar)
	_detail.buy = _button("Buy", func(): _outfit_buy(1), bar)
	_detail.sell = _button("Sell", func(): _outfit_sell(1), bar)
	_detail.buyq = _button("Buy…", func(): _outfit_prompt(true), bar)
	_detail.sellq = _button("Sell…", func(): _outfit_prompt(false), bar)
	var done := _button("Done", _show_hub, bar)
	for c in bar.get_children():
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label(_hint("A buy 1 · X sell 1 · Y buy… · RB sell… · B done",
			"Enter buy 1 · S sell 1 · Q buy… · E sell… · Esc done"), 13)
	_select(_sel_id)
	_focus(focus_tile if focus_tile != null else done)


func _tile(it: Dictionary, text: String) -> Button:
	var t := Button.new()
	t.custom_minimum_size = Vector2(156, 54)
	t.text = text
	t.clip_text = true
	t.text_overrun_behavior = TextServer.OVERRUN_TRIM_ELLIPSIS
	t.add_theme_font_size_override("font_size", 12)
	if it.get("locked", false):
		t.modulate = Color(1, 1, 1, 0.45)
	return t


func _outfit_tile_text(it: Dictionary) -> String:
	return "%s%s" % [it.name, ("  ×%d" % int(it.owned)) if int(it.owned) > 0 else ""]


func _find_item(id: int) -> int:
	for i in _items.size():
		if int(_items[i].id) == id:
			return i
	return -1


func _select(id: int) -> void:
	_sel_id = id
	var i := _find_item(id)
	if _detail.is_empty():
		return
	if _detail.has("classic"):
		_c.select(id)
		return
	if i < 0:
		_detail.name.text = ""
		return
	var it: Dictionary = _items[i]
	if _screen == "outfitter":
		var st = JSON.parse_string(_nova.outfitter_state())
		_detail.pic.texture = _pict_tex(_nova.spaceport_picture_id(2, id))
		_detail.name.text = str(it.name)
		_detail.desc.text = _nova.outfitter_description(id)
		_detail.stats.text = "Item Price: %s cr\nYou Have: %s cr\nItem Mass: %d tons\nFree Mass: %d tons\nCargo: %d/%d tons\nOwned: %d   Sells for: %s cr%s" % [
			_commas(int(it.price)), _commas(int(st.credits)), int(it.mass), int(st.freeMass),
			int(st.cargoUsed), int(st.cargoCapacity), int(it.owned), _commas(int(it.salePrice)),
			"\n(sell-back only here)" if it.sellOnly else ("\n(not available to you yet)" if it.locked else "")]
		_detail.buy.disabled = not it.canBuy
		_detail.buyq.disabled = not it.canBuy
		_detail.sell.disabled = not it.canSell
		_detail.sellq.disabled = not it.canSell
	else:
		var st2 = JSON.parse_string(_nova.shipyard_state())
		_detail.pic.texture = _pict_tex(_nova.spaceport_picture_id(3, id))
		_detail.name.text = str(it.name)
		var info = JSON.parse_string(_nova.shipyard_info(id))
		_detail.desc.text = str(info.get("description", ""))
		_detail.stats.text = "Price: %s cr\nTrade-in: %s cr\nYou Have: %s cr%s" % [
			_commas(int(it.price)), _commas(int(st2.tradeIn)), _commas(int(st2.credits)),
			"\n(your current ship)" if it.current else ("\n(not available to you yet)" if it.locked else "")]
		_detail.buy.disabled = not it.canBuy


func _outfit_buy(n: int) -> void:
	var i := _find_item(_sel_id)
	if i < 0:
		return
	var it: Dictionary = _items[i]
	var got: int = _nova.outfitter_buy(_sel_id, n)
	_message = ("Bought %d× %s." % [got, it.name]) if got > 0 else \
			"Can't buy that — check credits, free mass, mounts and limits."
	_show_outfitter()


func _outfit_sell(n: int) -> void:
	var i := _find_item(_sel_id)
	if i < 0:
		return
	var it: Dictionary = _items[i]
	var got: int = _nova.outfitter_sell(_sel_id, n)
	_message = ("Sold %d× %s." % [got, it.name]) if got > 0 else "Can't sell that."
	if got <= 0:
		_nova.sound_beep(4)   # NovaUi_RunOutfitterInteractionLoop 0x0048ea70: a sale that fails sounds snd 153
	_show_outfitter()


func _outfit_prompt(buying: bool) -> void:
	var i := _find_item(_sel_id)
	if i < 0:
		return
	var it: Dictionary = _items[i]
	if not (it.canBuy if buying else it.canSell):
		return
	var top: int = _nova.outfitter_max(_sel_id, buying)
	if top <= 0:
		return
	_prompt("How many %s?" % it.plural, top, top, func(q):
		if buying:
			_outfit_buy(q)
		else:
			_outfit_sell(q))


# --- shipyard ------------------------------------------------------------------------

func _show_shipyard() -> void:
	if _screen != "shipyard":
		_shop_opened("shipyard")
	_screen = "shipyard"
	var parsed = JSON.parse_string(_nova.shipyard_list())
	_items = parsed if parsed is Array else []
	if _classic():
		var fresh := _detail.is_empty()
		if not _items.is_empty() and _find_item(_sel_id) < 0:
			_sel_id = int(_items[0].id)
		_begin(_show_hub)
		_detail = {"classic": true}
		_c.shop_window("ship", fresh)
		return
	_clear("Shipyard", _show_hub)
	if not _items.is_empty() and _find_item(_sel_id) < 0:
		_sel_id = int(_items[0].id)
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 14)
	_col.add_child(body)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(640, 440)
	scroll.follow_focus = true
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 4)
	grid.add_theme_constant_override("v_separation", 4)
	scroll.add_child(grid)
	var focus_tile: Button = null
	for it in _items:
		var t := _tile(it, str(it.name))
		var id := int(it.id)
		# Buying a hull is destructive (the old fittings are traded in), so a
		# tile press selects and moves to Buy Ship rather than buying outright.
		t.pressed.connect(func():
			_sel_id = id
			_select(id)
			_focus(_detail.buy))
		t.focus_entered.connect(func(): _select(id))
		grid.add_child(t)
		_tiles[id] = t
		if id == _sel_id:
			focus_tile = t
	if _items.is_empty():
		_label("No ships for sale here.", 15, COL_DIM, grid)

	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(470, 0)
	side.add_theme_constant_override("separation", 5)
	body.add_child(side)
	_detail.pic = _picture(null, Vector2(300, 200))
	var pic_row := CenterContainer.new()
	pic_row.add_child(_detail.pic)
	side.add_child(pic_row)
	_detail.name = _label("", 20, COL_HI, side)
	var dscroll := ScrollContainer.new()
	dscroll.custom_minimum_size = Vector2(0, 130)
	dscroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	side.add_child(dscroll)
	_detail.desc = Label.new()
	_detail.desc.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_detail.desc.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_detail.desc.add_theme_font_size_override("font_size", 13)
	dscroll.add_child(_detail.desc)
	_detail.stats = _label("", 14, Color(0.85, 0.88, 0.95), side)

	_add_status()
	var bar := HBoxContainer.new()
	_col.add_child(bar)
	_detail.info = _button("Info", _ship_info, bar)
	_detail.buy = _button("Buy Ship", _ship_buy, bar)
	var done := _button("Done", _show_hub, bar)
	for c in bar.get_children():
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label(_hint("A select/buy · Y info · B done", "Enter select/buy · I info · Esc done"), 13)
	_select(_sel_id)
	_focus(focus_tile if focus_tile != null else done)


func _ship_buy() -> void:
	var i := _find_item(_sel_id)
	if i < 0:
		return
	var name := str(_items[i].name)
	if _nova.shipyard_buy(_sel_id):
		_message = "Bought the %s." % name
	else:
		_message = "Can't buy that ship."
	_show_shipyard()


func _ship_info() -> void:
	if _find_item(_sel_id) < 0:
		return
	var info = JSON.parse_string(_nova.shipyard_info(_sel_id))
	if not (info is Dictionary) or info.is_empty():
		return
	if _classic():
		_c.ship_info(info, _sel_id)
		return
	_close_overlay()
	_overlay = _make_overlay()
	var box := _overlay_box(Vector2(820, 0))
	_label(str(info.name), 24, COL_HI, box)
	if str(info.get("subtitle", "")) != "":
		_label(str(info.subtitle), 14, COL_DIM, box)
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 16)
	box.add_child(row)
	row.add_child(_picture(_pict_tex(_nova.spaceport_picture_id(3, _sel_id)), Vector2(300, 200)))
	var grid := GridContainer.new()
	grid.columns = 4
	grid.add_theme_constant_override("h_separation", 14)
	row.add_child(grid)
	for s in info.stats:
		_label(str(s[0]), 14, COL_DIM, grid)
		_label(str(s[1]), 14, Color(0.9, 0.92, 1.0), grid)
	_label("Cost: %s cr" % _commas(int(info.price)), 15, COL_HI, box)
	_label("Standard weapons: " + (", ".join(info.weapons) if not info.weapons.is_empty() else "None"), 14, COL_DIM, box)
	if not info.outfits.is_empty():
		_label("Standard outfits: " + ", ".join(info.outfits), 14, COL_DIM, box)
	var d := _label(str(info.description), 13, COL_DIM, box)
	d.custom_minimum_size = Vector2(780, 0)
	var done := _button("Done", _close_overlay, box)
	_overlay_back = _close_overlay
	_focus(done)


# --- story: lane offers, Bar, Mission BBS, Holovid -------------------------------------

# The original ticks these at 60 Hz: the bar's first patron 15 ticks after walking
# in, each next 30 + Rand(30) ticks after the last offer closes; an open shop makes
# its next offer on the same 30 + Rand(30) idle timer (0x00448670, 0x0048d190).
func _next_wait() -> float:
	return (30 + randi() % 30) / 60.0


func _shop_opened(shop: String) -> void:
	# Opening a shop can surface an offer (its own AvailLocation), as walking into
	# the trade centre / shipyard / outfitter can hand you a mission.
	_shop_wait = _next_wait()
	_nova.offer_roll(shop)


func _process(delta: float) -> void:
	if not visible or _nova == null or not _nova.has_game():
		return
	# A `Q` fired by a mission accepted here closes whatever screen is open (its
	# message waits for the launch); one that bounces the pilot is Main's.
	if _nova.story_text_pending() == false and _reopen_bbs_pending:
		_reopen_bbs_pending = false
		_reopen_bbs()
	if _overlay != null or _nova.story_blocks_flight():
		return
	match _screen:
		"bar":
			if _bar_offer_up:
				_bar_offer_up = false
				_bar_wait = _next_wait()
			elif _bar_active:
				_bar_wait -= delta
				if _bar_wait <= 0.0:
					var r: int = _nova.offer_roll("bar")
					if r == 0:
						_bar_active = false       # nobody else has anything: the round is over
					elif r == 1:
						_bar_offer_up = true
					else:
						_bar_wait = _next_wait()
		"trade", "outfitter", "shipyard":
			_shop_wait -= delta
			if _shop_wait <= 0.0:
				_shop_wait = _next_wait()
				_nova.offer_roll(_screen)


## A `Q` from a mission script: back to the main spaceport screen.
func story_close_screen() -> void:
	if visible and _screen != "hub":
		_close_overlay()
		_show_hub()


func _show_bar() -> void:
	if _screen != "bar":
		_bar_active = true
		_bar_wait = 15.0 / 60.0
		_bar_offer_up = false
		if _nova.has_method("bar_opened"):
			_nova.bar_opened()   # EC-26: the previous race winner resets with the window
	_screen = "bar"
	var b = JSON.parse_string(_nova.bar_info())
	if not (b is Dictionary):
		b = {}
	if _classic():
		_begin(_show_hub)
		_c.bar(b)
		return
	_clear("Bar", _show_hub)
	var pic := _picture(_pict_tex(int(b.get("pict", -1))), Vector2(600, 220))
	if int(b.get("pict", -1)) >= 0:
		var row := CenterContainer.new()
		row.add_child(pic)
		_col.add_child(row)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_col.add_child(scroll)
	var text := Label.new()
	text.text = str(b.get("text", ""))
	text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	text.add_theme_font_size_override("font_size", 16)
	scroll.add_child(text)
	_add_status()
	var bar := HBoxContainer.new()
	_col.add_child(bar)
	# The original's bar: Hire Escort (live under the six-escort cap), Holovid, Gamble, Leave.
	var hire := _button(str(b.get("hire", "Hire Escort")), _bar_screens.open_hire, bar)
	hire.name = "bar_hire"
	hire.disabled = not bool(b.get("canHire", true))
	var holo := _button(str(b.get("holovid", "Holovid")), _holovid, bar)
	holo.name = "bar_holovid"
	var gamble := _button(str(b.get("gamble", "Gamble")), _bar_screens.open_gamble, bar)
	gamble.name = "bar_gamble"
	var leave := _button(str(b.get("leave", "Leave")), _show_hub, bar)
	leave.name = "bar_leave"
	for c in bar.get_children():
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label(_hint("A press · B leave", "Enter press · Esc leave"), 13)
	_focus(holo)


# The bar's news screen — read on demand, never forced on landing.
func _holovid() -> void:
	var h = JSON.parse_string(_nova.holovid_info())
	if not (h is Dictionary) or h.is_empty():
		return
	_nova.sound_beep(2)
	if _classic():
		_c.holovid(h)
		return
	_close_overlay()
	_overlay = _make_overlay()
	var box := _overlay_box(Vector2(780, 0))
	_label("Holovid", 22, COL_HI, box)
	if int(h.pict) >= 0:
		var row := CenterContainer.new()
		row.add_child(_picture(_pict_tex(int(h.pict)), Vector2(720, 240)))
		box.add_child(row)
	var sc := ScrollContainer.new()
	sc.custom_minimum_size = Vector2(0, 200)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	box.add_child(sc)
	var t := Label.new()
	t.text = str(h.text)
	t.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.add_theme_font_size_override("font_size", 15)
	sc.add_child(t)
	var done := _button(_info.get("labels", {}).get("leave", "Leave"), _close_holovid, box)
	_overlay_back = _close_holovid
	_focus(done)


func _close_holovid() -> void:
	_nova.sound_beep(3)
	_close_overlay()


# --- Mission BBS ------------------------------------------------------------------------

func _open_bbs() -> void:
	var r = JSON.parse_string(_nova.bbs_open(true))
	if r is Dictionary and r.get("open", false):
		_show_bbs(str(r.get("date", "")))


# After an accept the board closes and reopens afresh, or not at all when nothing
# is left to offer (silently — 0x0043c470, 0x00491f30).
func _reopen_bbs() -> void:
	if _screen != "bbs":
		return
	var r = JSON.parse_string(_nova.bbs_open(false))
	if r is Dictionary and r.get("open", false):
		_show_bbs(str(r.get("date", "")))
	else:
		_show_hub()


func _show_bbs(date: String) -> void:
	_screen = "bbs"
	_bbs_nodes = {}
	var parsed = JSON.parse_string(_nova.bbs_list())
	_bbs_list = parsed if parsed is Array else []
	if _classic():
		_begin(_show_hub)
		_c.bbs(date)
		return
	_clear(str(_story_labels.get("missionBBS", "Mission BBS")), _show_hub)
	_label(date, 14)
	var body := HBoxContainer.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.add_theme_constant_override("separation", 16)
	_col.add_child(body)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(380, 460)
	scroll.follow_focus = true
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	scroll.add_child(list)
	var side := VBoxContainer.new()
	side.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	side.add_theme_constant_override("separation", 8)
	body.add_child(side)
	_bbs_nodes.title = _label("", 20, COL_HI, side)
	var pic_row := CenterContainer.new()
	side.add_child(pic_row)
	_bbs_nodes.pic_row = pic_row
	var dscroll := ScrollContainer.new()
	dscroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	dscroll.custom_minimum_size = Vector2(0, 280)
	dscroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	side.add_child(dscroll)
	_bbs_nodes.text = Label.new()
	_bbs_nodes.text.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_bbs_nodes.text.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_bbs_nodes.text.add_theme_font_size_override("font_size", 14)
	dscroll.add_child(_bbs_nodes.text)
	_add_status()
	var bar := HBoxContainer.new()
	_col.add_child(bar)
	# The BBS's own fixed labels: STR# 150 #26 "Accept" and #1 "Leave".
	_bbs_nodes.accept = _button(str(_story_labels.get("accept", "Accept")), _bbs_accept, bar)
	_bbs_nodes.accept.disabled = true
	var leave := _button(str(_story_labels.get("leave", "Leave")), _show_hub, bar)
	for c in bar.get_children():
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_label(_hint("A select · X accept · B leave", "Enter select · A accept · Esc leave"), 13)
	var first: Button = null
	for m in _bbs_list:
		var id := int(m.id)
		var b := Button.new()
		b.text = str(m.name)
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.clip_text = true
		b.custom_minimum_size = Vector2(0, 32)
		# Stepping to a listing presents it (Tab / Down in the original).
		b.focus_entered.connect(_bbs_show.bind(id))
		b.pressed.connect(_bbs_show.bind(id))
		var _b = StoryGuide.make_badge(_nova, id, self)
		if _b != null:
			b.add_child(_b)
			_b.set_anchors_and_offsets_preset(Control.PRESET_CENTER_RIGHT, Control.PRESET_MODE_KEEP_SIZE, 6)
		list.add_child(b)
		if first == null:
			first = b
	if _bbs_list.is_empty():
		_label("No missions available.", 15, COL_DIM, list)
	_focus(first if first != null else leave)


func _bbs_show(id: int) -> void:
	var r: int = _nova.bbs_select(id)
	if r == 2:
		_bbs_after_accept()   # a can't-refuse listing with no text activated at once
		return
	var o = JSON.parse_string(_nova.offer_state())
	if not (o is Dictionary) or o.is_empty() or _bbs_nodes.is_empty():
		return
	if _classic():
		_c.bbs_present(o)
		return
	_bbs_nodes.title.text = str(o.title)
	_bbs_nodes.text.text = str(o.text)
	_bbs_nodes.accept.disabled = false
	for c in _bbs_nodes.pic_row.get_children():
		_bbs_nodes.pic_row.remove_child(c)
		c.queue_free()
	if int(o.pict) >= 0:
		_bbs_nodes.pic_row.add_child(_picture(_pict_tex(int(o.pict)), Vector2(380, 130)))


func _bbs_accept() -> void:
	if _screen != "bbs" or _bbs_nodes.is_empty() or _bbs_nodes.accept.disabled:
		return
	# A failed activation keeps the board open (its no-room text shows over it).
	if _nova.bbs_accept():
		_bbs_after_accept()


func _bbs_after_accept() -> void:
	_reopen_bbs_pending = true


# --- misc ----------------------------------------------------------------------------

func _hint(pad: String, keys: String) -> String:
	var pad_on := not Input.get_connected_joypads().is_empty()
	return pad if pad_on else keys


static func _commas(n: int) -> String:
	var s := str(abs(n))
	var out := ""
	for i in s.length():
		if i > 0 and (s.length() - i) % 3 == 0:
			out += ","
		out += s[i]
	return ("-" if n < 0 else "") + out
