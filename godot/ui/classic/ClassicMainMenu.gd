# NOVA Swift — Classic UI kit: the authentic EV Nova main menu.
#
# Port of the Apple app's AuthenticMainMenuView: the 1024x768 title picture (PICT 8000)
# with the game logo (spïn 606), the three shutter strips (spïn 608-610, played once on
# entry with snd 602/603), the six real menu buttons (spïn 600-605: New Pilot, Open Pilot,
# Quit | Enter Ship, Preferences, About) at the cölr #128 coordinates, the rollover icon
# (spïn 607) and the loaded-pilot readout (STR# 2002 labels in MenuColor2, values in
# MenuColor1, the cölr menu font; the ship's targeting PICT added below the centre knob),
# all through the bridge's `classic_main_menu` / `classic_spin_*` / `classic_menu_readout`
# (layout and text rules are the shared MainMenuReadout).
#
# It only reports the choice (`chosen(action)`: new_pilot / open_pilot / quit / enter_ship /
# prefs / about / game_data); the host decides. The keys are the original's (N O Q E P A).
# Gamepad / keyboard focus moves between the two button columns and the focused button
# shows its highlighted frame, like a held mouse press.
#
# Loaded with preload() (no class_name), like Controls.gd.
extends Control

const Theme_ := preload("res://ui/classic/ClassicTheme.gd")
const ButtonScript := preload("res://ui/classic/ClassicButton.gd")

signal chosen(action: String)

const DESIGN := Vector2(1024, 768)
const SLIDE_FPS := 20.0
const KEYS := {KEY_N: "new_pilot", KEY_O: "open_pilot", KEY_Q: "quit", KEY_E: "enter_ship",
	KEY_P: "prefs", KEY_A: "about"}

var nova: Object
var layout := {}
## While a dialog is over the menu (or a sub-screen), buttons and keys are inert.
var blocked := false:
	set(v):
		blocked = v
		for b in buttons.values():
			b.focus_mode = Control.FOCUS_NONE if v else Control.FOCUS_ALL
			b.mouse_filter = Control.MOUSE_FILTER_IGNORE if v else Control.MOUSE_FILTER_STOP
var buttons := {}          # action -> TextureButton
var order: Array[String] = []   # actions in menu order (spïn 600..605)
var slides_done := false

var _canvas: Control
var _slide_rects: Array[TextureRect] = []
var _slide_frames: Array = []    # per strip: Array[Texture2D]
var _slide_frame := 0
var _slide_clock := 0.0
var _slide_last := 0
var _roll_rect: TextureRect
var _roll_tex: Array = []
var _roll_default := -1
var _readout: Control
var _pilot_pict: TextureRect
var _busy := false


static func make(nova_obj: Object) -> Control:
	var m: Control = (load("res://ui/classic/ClassicMainMenu.gd") as GDScript).new()
	m.nova = nova_obj
	m._build()
	return m


static func _tex(w: int, h: int, bytes: PackedByteArray) -> Texture2D:
	if w <= 0 or h <= 0 or bytes.size() != w * h * 4:
		return null
	return ImageTexture.create_from_image(Image.create_from_data(w, h, false, Image.FORMAT_RGBA8, bytes))


func _build() -> void:
	Theme_.setup(nova)
	var parsed = JSON.parse_string(nova.classic_main_menu())
	layout = parsed if parsed is Dictionary else {}
	set_anchors_preset(Control.PRESET_FULL_RECT)
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	var black := ColorRect.new()
	black.color = Color.BLACK
	black.set_anchors_preset(Control.PRESET_FULL_RECT)
	black.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(black)
	_canvas = Control.new()
	_canvas.size = DESIGN
	_canvas.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
	add_child(_canvas)

	_add_rect(Theme_.pict(int(layout.get("bg", 8000))), Vector2.ZERO)

	# Shutter strips: frame 0 is the retracted state (identical to the backdrop).
	for s in layout.get("slides", []):
		var frames: Array = []
		for f in int(s["count"]):
			frames.append(_tex(int(s["w"]), int(s["h"]), nova.classic_spin_tile_rgba(int(s["spin"]), f, 1)))
		_slide_frames.append(frames)
		_slide_rects.append(_add_rect(frames[0] if not frames.is_empty() else null, Vector2(s["x"], s["y"])))
		_slide_last = maxi(_slide_last, frames.size() - 1)

	# The logo, opaque at its authored origin so its baked surroundings land on the backdrop's.
	var lg = layout.get("logo")
	if lg is Dictionary:
		_add_rect(_tex(int(lg["w"]), int(lg["h"]), nova.classic_spin_tile_rgba(int(lg["spin"]), int(lg["frame"]), 1)),
			Vector2(lg["x"], lg["y"]))

	# Buttons (two frames each: up, highlighted).
	var idx := 0
	for b in layout.get("buttons", []):
		var up := _tex(int(b["w"]), int(b["h"]), nova.classic_spin_tile_rgba(int(b["spin"]), 0, 0))
		var down := _tex(int(b["w"]), int(b["h"]), nova.classic_spin_tile_rgba(int(b["spin"]), 1, 0))
		var tb := TextureButton.new()
		tb.texture_normal = up
		tb.texture_pressed = down
		tb.texture_focused = up    # the highlighted frame only for keyboard / pad focus (see _sync_nav)
		tb.set_meta("down_tex", down)
		tb.position = Vector2(b["x"], b["y"])
		tb.focus_mode = Control.FOCUS_ALL
		tb.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		tb.visible = false
		var act := str(b["action"])
		var i := idx
		tb.pressed.connect(func(): press(act))
		tb.mouse_entered.connect(func(): _show_rollover(i))
		tb.mouse_exited.connect(func(): _show_rollover(-1))
		tb.focus_entered.connect(func(): _show_rollover(i))
		tb.focus_exited.connect(func(): _show_rollover(-1))
		_canvas.add_child(tb)
		buttons[act] = tb
		order.append(act)
		idx += 1
	_wire_focus()
	Theme_.track(self)
	Theme_.on_nav_changed(func(_on): _sync_nav())
	_sync_nav()

	# Rollover indicator: the gold ATMOS wordmark at rest, the hovered button's icon otherwise.
	var ro: Dictionary = layout.get("rollover", {})
	if not ro.is_empty() and int(ro["count"]) > 0:
		for f in int(ro["count"]):
			_roll_tex.append(_tex(int(ro["w"]), int(ro["h"]), nova.classic_spin_tile_rgba(int(ro["spin"]), f, 0)))
		_roll_default = _roll_tex.size() - 1
		_roll_rect = _add_rect(_roll_tex[_roll_default], Vector2(ro["x"], ro["y"]))

	# The pilot's targeting PICT: transfer mode addOver, the black ground adds nothing.
	_pilot_pict = TextureRect.new()
	_pilot_pict.stretch_mode = TextureRect.STRETCH_KEEP
	var mat := CanvasItemMaterial.new()
	mat.blend_mode = CanvasItemMaterial.BLEND_MODE_ADD
	_pilot_pict.material = mat
	_pilot_pict.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(_pilot_pict)
	_readout = _Readout.new()
	_readout.menu = self
	_readout.size = DESIGN
	_readout.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(_readout)

	_begin_slides()
	resized.connect(fit)
	fit.call_deferred()


## Like Apple's menu: a keyboard/pad-focused button shows its highlighted frame; the mouse never does.
func _sync_nav() -> void:
	for b in buttons.values():
		b.texture_focused = b.get_meta("down_tex") if Theme_.nav_active else b.texture_normal


func _add_rect(tex: Texture2D, pos: Vector2) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = tex
	tr.stretch_mode = TextureRect.STRETCH_KEEP
	tr.position = pos
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_canvas.add_child(tr)
	return tr


## Scale the 1024x768 design space into the viewport (Apple's NovaCanvas .fit) and centre it.
func fit() -> void:
	if _canvas == null:
		return
	var vp := get_viewport_rect().size if is_inside_tree() else Vector2(1280, 720)
	var s := minf(vp.x / DESIGN.x, vp.y / DESIGN.y)
	_canvas.scale = Vector2(s, s)
	_canvas.position = ((vp - DESIGN * s) / 2.0).round()


## Left column New/Open/Quit and right column Enter/Prefs/About: up/down inside a column,
## left/right across to the same row.
func _wire_focus() -> void:
	for i in order.size():
		var b: TextureButton = buttons[order[i]]
		var col := i / 3
		var row := i % 3
		var up: int = col * 3 + (row + 2) % 3
		var down: int = col * 3 + (row + 1) % 3
		var across: int = ((1 - col) * 3 + row)
		if across < order.size():
			b.focus_neighbor_left = b.get_path_to(buttons[order[across]])
			b.focus_neighbor_right = b.get_path_to(buttons[order[across]])
		if up < order.size():
			b.focus_neighbor_top = b.get_path_to(buttons[order[up]])
		if down < order.size():
			b.focus_neighbor_bottom = b.get_path_to(buttons[order[down]])


func _show_rollover(i: int) -> void:
	if _roll_rect == null:
		return
	var f := i if (i >= 0 and i < _roll_tex.size() - 1) else _roll_default
	_roll_rect.texture = _roll_tex[f] if f >= 0 else null


func focus_default() -> void:
	var b: TextureButton = buttons.get("open_pilot", buttons.get(order[0]) if not order.is_empty() else null)
	if b != null and b.visible and b.is_inside_tree():
		b.grab_focus()


# --- the shutter run -----------------------------------------------------------------

func _begin_slides() -> void:
	_slide_frame = 0
	slides_done = _slide_last <= 0
	if slides_done:
		_finish_slides()
		return
	for _s in _slide_rects:
		_menu_sound(602)


func _process(dt: float) -> void:
	if slides_done:
		return
	_slide_clock += dt
	var step := 1.0 / SLIDE_FPS
	while _slide_clock >= step and not slides_done:
		_slide_clock -= step
		_set_slide_frame(_slide_frame + 1)


## Jump straight to a frame of the run (the timer calls it; a test can too).
func _set_slide_frame(f: int) -> void:
	_slide_frame = clampi(f, 0, _slide_last)
	for i in _slide_rects.size():
		var frames: Array = _slide_frames[i]
		if frames.is_empty():
			continue
		_slide_rects[i].texture = frames[mini(_slide_frame, frames.size() - 1)]
		if _slide_frame == frames.size() - 1 and f == _slide_frame:
			_menu_sound(603)
	# A button appears once the strip of its row has landed.
	for i in order.size():
		buttons[order[i]].visible = _strip_settled(i % 3)
	if _slide_frame >= _slide_last:
		_finish_slides()
	_readout.queue_redraw()


func _strip_settled(strip: int) -> bool:
	if strip >= _slide_frames.size():
		return true
	return _slide_frame >= _slide_frames[strip].size() - 1


func _finish_slides() -> void:
	slides_done = true
	for a in order:
		buttons[a].visible = true
	if _readout != null:
		_readout.queue_redraw()
	if is_inside_tree() and not blocked:
		focus_default.call_deferred()


func _menu_sound(id: int) -> void:
	if nova != null and nova.has_method("sound_menu"):
		nova.sound_menu(id)


# --- the pilot readout ------------------------------------------------------------------

## Show the readout for save `id` in `dir` ("" = no pilot loaded).
func set_pilot(dir: String, id: String) -> void:
	var parsed = JSON.parse_string(nova.classic_menu_readout(dir, id))
	_readout.data = parsed if parsed is Dictionary else {}
	var pid := int(_readout.data.get("pict", -1))
	var tex: Texture2D = Theme_.pict(pid) if pid >= 0 else null
	_pilot_pict.texture = tex
	if tex != null:
		_pilot_pict.position = Vector2(DESIGN.x / 2.0 - tex.get_width() / 2.0, DESIGN.y / 2.0 + MENU_PICT_TOP)
	_readout.queue_redraw()


const MENU_PICT_TOP := 0x118


class _Readout extends Control:
	var menu
	var data := {}

	func _draw() -> void:
		var pal: Dictionary = menu.layout
		var font: Font = Theme_.font_for(str(pal.get("font", "Geneva")))
		var fs := int(pal.get("fontSize", 9))
		var bright := Color.html(str(pal.get("color1", "#ff0000")))
		var dim := Color.html(str(pal.get("color2", "#800000")))
		var cx := DESIGN.x / 2.0
		var cy := DESIGN.y / 2.0
		for line in data.get("lines", []):
			draw_string(font, Vector2(cx + float(line["dx"]), cy + float(line["baseline"])), str(line["text"]),
				HORIZONTAL_ALIGNMENT_LEFT, -1, fs, dim if bool(line["label"]) else bright)
		var centred := str(data.get("centred", ""))
		# "No Pilot File Loaded" waits for the bottom shutter to land.
		if centred != "" and menu._strip_settled(2):
			var w := font.get_string_size(centred, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
			draw_string(font, Vector2(cx - w / 2.0, cy + 0x136), centred, HORIZONTAL_ALIGNMENT_LEFT, -1, fs, dim)


# --- input ----------------------------------------------------------------------------------

## A menu command: snd 600, then 601, then the choice (`FUN_0048bc20`).
func press(action: String) -> void:
	if blocked or _busy:
		return
	_busy = true
	_menu_sound(600)
	if is_inside_tree():
		await get_tree().create_timer(0.12).timeout
	_menu_sound(601)
	_busy = false
	chosen.emit(action)


func _unhandled_key_input(event: InputEvent) -> void:
	if blocked or not slides_done or not (event is InputEventKey) or not event.pressed or event.echo:
		return
	if event.ctrl_pressed or event.alt_pressed or event.meta_pressed:
		return
	var action: String = KEYS.get(event.keycode, "")
	if action != "" and buttons.has(action):
		get_viewport().set_input_as_handled()
		press(action)
