# NOVA Swift — the story intro shown when a new pilot is created.
#
# Port of the Apple app's IntroSequenceView: the scenario's `chär` intro PICTs as a timed slideshow
# (each shown IntroPictDelay x 60 ms, `duration` from the bridge's `pilot_intro`), then the intro
# `dësc` text on a final page that waits for the player. Click / Enter / Space / pad A advances to
# the next page early (Apple: tap, or the controller cursor's Menu); Esc / pad B skips the whole
# thing (Apple: Ⓑ and the Skip button); the button in the corner reads "Skip" and "Begin" on the
# last page. Pages cross-fade (0.4 s). A missing / undecodable PICT keeps the sequence moving with
# a black page.
#
# `finished` fires once, when the sequence completes or is skipped. `setup` returns false when the
# scenario has no intro at all (the host goes straight to the next step).
#
# Loaded with preload() (no class_name), like the other screens.
extends CanvasLayer

const Controls = preload("res://Controls.gd")
const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")
const ShellUI = preload("res://screens/ShellUI.gd")

signal finished

const FADE := 0.4
const TEXT_ID := 9000   # the text page's id in Apple's page list

var pages: Array = []        # [{pict: int, delay: float}] and a last {pict: -1, text: true} page
var index := 0
var intro_text := ""

var _nova: Object
var _root: Control
var _stage: Control          # the current page's content (cross-faded)
var _skip: Button
var _caption: Label
var _clock := 0.0
var _done := false
var _scroll: ScrollContainer


func setup(nova: Object, scenario_id: int) -> bool:
	_nova = nova
	layer = 70
	var parsed = JSON.parse_string(nova.pilot_intro(scenario_id))
	var info: Dictionary = parsed if parsed is Dictionary else {}
	for s in info.get("slides", []):
		pages.append({"pict": int(s["pict"]), "delay": float(s["duration"])})
	intro_text = str(info.get("text", ""))
	if intro_text != "":
		pages.append({"pict": -1, "delay": 0.0, "text": true})   # text page: manual advance
	if pages.is_empty():
		return false
	ClassicTheme.setup(nova)
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(_root)
	var black := ColorRect.new()
	black.color = Color.BLACK
	black.set_anchors_preset(Control.PRESET_FULL_RECT)
	black.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(black)
	_stage = Control.new()
	_stage.set_anchors_preset(Control.PRESET_FULL_RECT)
	_stage.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_stage)
	_build_chrome()
	_show_page(false)
	return true


func _build_chrome() -> void:
	_skip = Button.new()
	_skip.focus_mode = Control.FOCUS_NONE        # A / Enter / Space advance; B / Esc skip (below)
	_skip.custom_minimum_size = Vector2(96, 38)
	_skip.set_anchors_preset(Control.PRESET_BOTTOM_RIGHT)
	_skip.position = Vector2(-120, -62)
	_skip.pressed.connect(skip)
	_root.add_child(_skip)
	_caption = Label.new()
	_caption.add_theme_font_size_override("font_size", 12)
	_caption.add_theme_color_override("font_color", Color(1, 1, 1, 0.45))
	_caption.set_anchors_preset(Control.PRESET_BOTTOM_LEFT)
	_caption.position = Vector2(24, -34)
	_caption.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_caption)


func is_last_page() -> bool:
	return index >= pages.size() - 1


func current_page() -> Dictionary:
	return pages[index] if index >= 0 and index < pages.size() else {}


func _show_page(fade: bool) -> void:
	var page := current_page()
	if _stage.get_child_count() > 0:
		for c in _stage.get_children():
			c.queue_free()
	_scroll = null
	var content := Control.new()
	content.set_anchors_preset(Control.PRESET_FULL_RECT)
	content.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_stage.add_child(content)
	if bool(page.get("text", false)):
		_build_text_page(content)
	else:
		var tex: Texture2D = ClassicTheme.pict(int(page.get("pict", -1)))
		if tex != null:
			var r := TextureRect.new()
			r.texture = tex
			r.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			r.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
			r.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
			r.set_anchors_preset(Control.PRESET_FULL_RECT)
			r.offset_left = 20
			r.offset_top = 20
			r.offset_right = -20
			r.offset_bottom = -20
			r.mouse_filter = Control.MOUSE_FILTER_IGNORE
			content.add_child(r)
	_skip.text = "Begin" if is_last_page() else "Skip"
	_caption.text = ("A: Continue    B: Skip" if Controls.pad_connected()
			else "Click or press Enter to continue    Esc to skip")
	_clock = 0.0
	if fade:
		content.modulate.a = 0.0
		create_tween().tween_property(content, "modulate:a", 1.0, FADE)


func _build_text_page(content: Control) -> void:
	_scroll = ScrollContainer.new()
	_scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scroll.offset_bottom = -70
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	content.add_child(_scroll)
	var center := CenterContainer.new()
	center.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	center.custom_minimum_size = Vector2(0, 0)
	_scroll.add_child(center)
	var margin := MarginContainer.new()
	margin.custom_minimum_size = Vector2(640, 0)
	for side in ["left", "right", "top", "bottom"]:
		margin.add_theme_constant_override("margin_" + side, 32)
	center.add_child(margin)
	var l := Label.new()
	l.text = _nova.desc_dialog_text(intro_text) if _nova.has_method("desc_dialog_text") else intro_text
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.add_theme_font_size_override("font_size", 16)
	l.add_theme_color_override("font_color", Color.WHITE)
	l.add_theme_constant_override("line_spacing", 5)
	if ClassicTheme.has_data():
		l.add_theme_font_override("font", ClassicTheme.body_font())
	margin.add_child(l)


func _process(delta: float) -> void:
	if _done:
		return
	var page := current_page()
	# Picture pages advance on their own after their delay; the text page waits for the player.
	if int(page.get("pict", -1)) >= 0 or not bool(page.get("text", false)):
		var d := float(page.get("delay", 0.0))
		if d > 0.0:
			_clock += delta
			if _clock >= d:
				advance(false)


## Next page (a tap / the delay running out); past the last page the sequence finishes.
func advance(beep := true) -> void:
	if _done:
		return
	if beep:
		_nova.sound_beep(1)
	if index >= pages.size() - 1:
		_finish()
		return
	index += 1
	_show_page(true)


## Skip the rest (Ⓑ / Esc / the corner button).
func skip() -> void:
	if _done:
		return
	_nova.sound_beep(1)
	_finish()


func _finish() -> void:
	_done = true
	finished.emit()


func _input(event: InputEvent) -> void:
	if _done:
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		skip()
		return
	# Text page: the arrows / pad stick scroll, Enter / A continue.
	if _scroll != null and (event.is_action_pressed("ui_down") or event.is_action_pressed("ui_up")):
		get_viewport().set_input_as_handled()
		_scroll.scroll_vertical += 60 * (1 if event.is_action_pressed("ui_down") else -1)
		return
	if event.is_action_pressed("ui_accept"):
		get_viewport().set_input_as_handled()
		advance()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		if _skip != null and _skip.get_global_rect().has_point(event.position):
			return   # the corner button takes this click
		get_viewport().set_input_as_handled()
		advance()
