# NOVA Swift — Classic UI kit: an original EV Nova dialog as a Godot Control.
#
# The Control's rect is the dialog window in the original's 1:1 pixel space
# (the DLOG size, or the backdrop PICT when one is given); every item sits at its
# DITL rect. `fit()` then scales that crisply (0.5-step, nearest-filtered) and
# centres it in the viewport, so a 640x480-era layout is sharp on 1280x720 and on
# the Steam Deck's 1280x800. Buttons are `ClassicButton`s (real three-state art,
# or the native bevelled push button on the text prompts), Return = the default
# item, ui_cancel (Esc / pad B) = the cancel item, and gamepad / keyboard focus
# moves by DITL geometry (nova.classic_focus_neighbours).
#
#   var dlg = ClassicDialog.confirm(nova, "Quit to the main menu?")     # DLOG 3002
#   dlg.accepted.connect(...); dlg.cancelled.connect(...)
#   ClassicDialog.modal(self, dlg)                                       # dim + centre
#
#   var d = ClassicDialog.from_ditl(nova, 1011, {frame_pict: 8531, labels: {...},
#                                                actions: {0: some_callable}})
#   var p = ClassicDialog.panel(nova, {title: "Paused", body_buttons: [...]})  # dësc frame
#
# Item indices are 0-based DITL indices, as the game (and the Apple app) address
# them. See docs/GODOT_LAYER.md "Classic UI kit" for the full option list.
#
# Loaded with preload() (no class_name), like Controls.gd.
extends Control

const Theme_ := preload("res://ui/classic/ClassicTheme.gd")
const ButtonScript := preload("res://ui/classic/ClassicButton.gd")

enum Chrome {
	NATIVE,   ## white window, black 1 px border; native bevelled buttons (DLOG 3001/3002 prompts)
	PICT,     ## backdrop PICT at (0,0); the window is the PICT's size; three-state art buttons
	PANEL,    ## stretchable dësc frame (PICT 8524 top / 8525 body / 8526 control strip)
	NONE,     ## transparent: items only (caller draws behind)
}

## A button / picture item was activated (any item with an action).
signal activated(index: int)
## The default item (Return) was activated.
signal accepted
## The cancel item (Esc / pad B) was activated.
signal cancelled

var nova: Object
var chrome: int = Chrome.NATIVE
var window_size := Vector2i(340, 140)
var items := {}               # DITL index -> Control
var texts := {}               # DITL index -> Label / LineEdit
var default_item := -1
var cancel_item := -1
var fit_to_viewport := true
var text_color := Color.BLACK
## Confirm beep (snd 150) on a button press. Off by default: the original's own windows (the
## spaceport hub, trade, outfitter, shipyard, bar, Preferences, story text) press silently; the
## generic dialogs the Apple app builds as NovaDialog (confirm, text prompt, panel, the port-only
## pilot screens) turn it on (`GameAudio.uiSelect`).
var beep := false
## DITL index -> Callable() bound by the caller.
var actions := {}

var _focusables: Array[Dictionary] = []   # {index, ctrl, rect: Rect2i}
var _host: Control
var _dirty_focus := true


# --- construction -----------------------------------------------------------------

static func _make(nova_obj: Object, size: Vector2i, chrome_kind: int) -> Control:
	var d: Control = (load("res://ui/classic/ClassicDialog.gd") as GDScript).new()
	d.nova = nova_obj
	d.chrome = chrome_kind
	d.window_size = size
	d.custom_minimum_size = Vector2(size)
	d.size = Vector2(size)
	d.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	d.focus_mode = Control.FOCUS_NONE
	d.text_color = Color.BLACK if chrome_kind == Chrome.NATIVE else Theme_.color("listText")
	return d


## Build a dialog from DLOG/DITL `id`. opts (all optional):
##   chrome        Chrome.*  (default: PICT if frame_pict >= 0 else NATIVE)
##   frame_pict    backdrop PICT id (the window becomes the PICT's size)
##   fallback_size Vector2i used when the data has no such DLOG/DITL (340x140)
##   texts         {index: String}   static text / edit initial text overrides
##   labels        {index: String}   button / checkbox label overrides
##   hidden        Array[int]        items not built
##   disabled      Array[int]        buttons greyed
##   actions       {index: Callable} bound to buttons and clickable pictures
##   default_item  index answering Return (default: 0 when it is a button)
##   cancel_item   index answering Esc / pad B
##   custom        {index: Callable(parent: Control, rect: Rect2i) -> void} for user items
##   text_color    Color for static text (black on NATIVE, cölr listText otherwise)
##   fit           false = leave scale 1 (the caller scales)
static func from_ditl(nova_obj: Object, id: int, opts := {}) -> Control:
	var info: Dictionary = {}
	if nova_obj != null and Theme_.has_data():
		var parsed = JSON.parse_string(nova_obj.classic_dialog(id))
		if parsed is Dictionary:
			info = parsed
	var frame := int(opts.get("frame_pict", -1))
	var kind := int(opts.get("chrome", Chrome.PICT if frame >= 0 else Chrome.NATIVE))
	var size: Vector2i = opts.get("fallback_size", Vector2i(340, 140))
	if info.has("w"):
		size = Vector2i(int(info["w"]), int(info["h"]))
	var frame_tex: Texture2D = Theme_.pict(frame) if (frame >= 0 and kind == Chrome.PICT) else null
	if frame_tex != null:
		size = Vector2i(frame_tex.get_size())
	var d: Control = _make(nova_obj, size, kind)
	d.fit_to_viewport = bool(opts.get("fit", true))
	d.beep = bool(opts.get("beep", false))
	if opts.has("text_color"):
		d.text_color = opts["text_color"]
	d._add_background(frame_tex)
	var hidden: Array = opts.get("hidden", [])
	var disabled: Array = opts.get("disabled", [])
	var otexts: Dictionary = opts.get("texts", {})
	var labels: Dictionary = opts.get("labels", {})
	var custom: Dictionary = opts.get("custom", {})
	d.actions = opts.get("actions", {})
	var items_arr: Array = info.get("items", [])
	d.default_item = int(opts.get("default_item", 0 if (items_arr.size() > 0 and items_arr[0]["kind"] == "button") else -1))
	d.cancel_item = int(opts.get("cancel_item", -1))
	for it in items_arr:
		var idx := int(it["i"])
		var rect := Rect2i(int(it["l"]), int(it["t"]), int(it["r"]) - int(it["l"]), int(it["b"]) - int(it["t"]))
		# The DITLs park unused items off-window; the original never draws them.
		if idx in hidden or rect.position.x >= size.x or rect.position.y >= size.y:
			continue
		match str(it["kind"]):
			"button":
				var b = d.add_button(str(labels.get(idx, it["text"])), rect, idx)
				b.disabled = idx in disabled
			"checkbox":
				d.add_check(str(labels.get(idx, it["text"])), rect, idx)
			"static":
				d.add_label(str(otexts.get(idx, it["text"])), rect, idx)
			"edit":
				d.add_edit(str(otexts.get(idx, it["text"])), rect, idx)
			"picture", "icon":
				d.add_picture(int(it["res"]), rect, idx)
			_:
				if custom.has(idx):
					custom[idx].call(d, rect)
	d.cancel_item = int(opts.get("cancel_item", -1))
	return d


## The original's yes/no prompt (DLOG/DITL 3002, `classicConfirm`): prompt text,
## OK (default) / Cancel. `ok` / `cancel` override the button labels.
static func confirm(nova_obj: Object, prompt: String, opts := {}) -> Control:
	var o := {"texts": {2: prompt}, "default_item": 0, "cancel_item": 4, "beep": true,
		"fallback_size": Vector2i(354, 140)}
	var labels := {}
	if opts.has("ok"):
		labels[0] = opts["ok"]
	if opts.has("cancel"):
		labels[4] = opts["cancel"]
	o["labels"] = labels
	return from_ditl(nova_obj, 3002, o)


## The original's text prompt (DLOG/DITL 3001, `classicTextPrompt`): prompt, edit
## field (item 4, `edit_text()`), OK / Cancel. Answers are limited to 64 bytes and
## a leading "the " is dropped by `prompt_answer()`.
static func text_prompt(nova_obj: Object, prompt: String, initial := "") -> Control:
	return from_ditl(nova_obj, 3001, {"texts": {2: prompt, 4: initial}, "default_item": 0, "cancel_item": 5,
		"beep": true, "fallback_size": Vector2i(354, 140)})


## A stretchable dësc-frame dialog (the app's own NovaDialog look: metal border,
## black interior, grey control strip). opts: title, text, width (441), body_buttons
## and footer_buttons (Arrays of {label, action: Callable, default, cancel,
## disabled}), body_buttons_width (200).
static func panel(nova_obj: Object, opts := {}) -> Control:
	var top_tex = Theme_.pict(8524)
	var bot_tex = Theme_.pict(8526)
	# The frame art is a fixed width; the strip is the bottom piece's height.
	var width := int(opts.get("width", top_tex.get_width() if top_tex != null else 441))
	var strip := bot_tex.get_height() if bot_tex != null else 40
	var top_h := top_tex.get_height() if top_tex != null else 9
	var title := str(opts.get("title", ""))
	var text := str(opts.get("text", ""))
	var body: Array = opts.get("body_buttons", [])
	var footer: Array = opts.get("footer_buttons", [])
	var bw := int(opts.get("body_buttons_width", 200))
	var bh := Theme_.button_height()
	var y := top_h + 14
	var plan := []   # [kind, text, rect]
	if title != "":
		plan.append(["title", title, Rect2i(24, y, width - 56, 26)])
		y += 36
	if text != "":
		# The frame art's metal border eats ~12 px on the right: keep the wrap width clear of it.
		var lines := maxi(1, int(ceil(float(text.length()) * 7.0 / float(width - 56))))
		var th := lines * 16
		plan.append(["text", text, Rect2i(24, y, width - 56, th)])
		y += th + 12
	var body_rects := []
	for b in body:
		body_rects.append(Rect2i((width - bw) / 2, y, bw, bh))
		y += bh + 8
	y += 6
	var height := y + strip   # the bottom piece is the control strip
	var d: Control = _make(nova_obj, Vector2i(width, height), Chrome.PANEL)
	d.beep = true   # the Apple NovaDialog look: its footer / row buttons click with snd 150
	d.fit_to_viewport = bool(opts.get("fit", true))
	d.text_color = Theme_.color("listText")
	d._add_background(null)
	for p in plan:
		if p[0] == "title":
			d.add_label(p[1], p[2], -1, 18, Theme_.FOCUS, true)
		else:
			d.add_label(p[1], p[2])
	var idx := 0
	for i in body.size():
		var spec: Dictionary = body[i]
		d._add_spec_button(spec, body_rects[i], idx)
		idx += 1
	var fx := width - 16
	for i in range(footer.size() - 1, -1, -1):
		var spec: Dictionary = footer[i]
		var w := maxi(50, str(spec.get("label", "")).length() * 8 + 26)
		fx -= w
		d._add_spec_button(spec, Rect2i(fx, height - strip + (strip - bh) / 2, w, bh), idx + i)
		fx -= 10
	return d


## The original's generic `dësc` reader (Ui_RunTravelSelectionDialog 0x004982a0; Apple
## DescTextDialog): text only = DLOG/DITL 3003 on PICT 8524 / 8525 / 8526 that SHRINKS to the
## measured text (shared DescDialogLayout.shrink, via the bridge); with a graphic (>= 128) =
## 3004 on backdrop PICT 8527 with the dësc picture in item 1. OK = item 0, text = item 2
## (white 12 pt Geneva stand-in on black, wrapped, scrolls when it overflows: wheel, Up/Down,
## PgUp/PgDn, right stick). `<REG>` and `\r` are resolved by the bridge. opts: fit.
## `d.get_meta("desc")` = {shrink, text_height, text_rect, scroll, with_picture, size}.
static func desc_dialog(nova_obj: Object, text: String, graphic_id := -1, opts := {}) -> Control:
	var info = JSON.parse_string(nova_obj.desc_dialog_info()) if nova_obj != null else null
	if not (info is Dictionary):
		info = {"textDialog": 3003, "pictDialog": 3004, "top": 8524, "body": 8525, "bottom": 8526, "backdrop": 8527, "minText": 48}
	var body: String = nova_obj.desc_dialog_text(text) if nova_obj != null else text.replace("\r", "\n")
	var pict_tex: Texture2D = Theme_.pict(graphic_id) if graphic_id >= 128 else null
	var with_pic := pict_tex != null
	var dlg_id := int(info["pictDialog"] if with_pic else info["textDialog"])
	var ditl = JSON.parse_string(nova_obj.classic_dialog(dlg_id)) if nova_obj != null else null
	var rects := {}
	var size := Vector2i(441, 313)
	if ditl is Dictionary and ditl.has("w"):
		size = Vector2i(int(ditl["w"]), int(ditl["h"]))
		for it in ditl.get("items", []):
			rects[int(it["i"])] = Rect2i(int(it["l"]), int(it["t"]), int(it["r"]) - int(it["l"]), int(it["b"]) - int(it["t"]))
	var ok_r: Rect2i = rects.get(0, Rect2i(size.x - 130, size.y - 36, 99, 25))
	var txt_r: Rect2i = rects.get(2, Rect2i(18, 40, size.x - 36, size.y - 100))
	var pic_r: Rect2i = rects.get(1, Rect2i(18, 18, 100, 100))
	var back_tex: Texture2D = Theme_.pict(int(info["backdrop"])) if with_pic else null
	if with_pic and back_tex != null:
		size = Vector2i(back_tex.get_size())
	# Measure the wrapped text at the item's width with the very Label that will show it.
	var fs := 12
	var font: Font = Theme_.body_font()
	var l := Label.new()
	l.text = body
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	# The pane's (hidden) scroll bar still takes its width from the wrap width.
	var wrap_w := txt_r.size.x - int(VScrollBar.new().get_minimum_size().x)
	l.custom_minimum_size = Vector2(wrap_w, 0)
	l.add_theme_font_override("font", font)
	l.add_theme_font_size_override("font_size", fs)
	l.add_theme_color_override("font_color", Color.WHITE)
	l.add_theme_constant_override("line_spacing", 0)
	l.mouse_filter = Control.MOUSE_FILTER_PASS
	# (a wrapping Label's minimum height needs its width applied, so shape the paragraph
	# with the very break flags AUTOWRAP_WORD_SMART uses)
	var th := int(ceil(font.get_multiline_string_size(body, HORIZONTAL_ALIGNMENT_LEFT, float(wrap_w), fs, -1,
		TextServer.BREAK_MANDATORY | TextServer.BREAK_WORD_BOUND | TextServer.BREAK_ADAPTIVE).y))
	var shrink := 0
	if not with_pic:
		shrink = int(nova_obj.desc_dialog_shrink(th, txt_r.size.y)) if nova_obj != null else 0
	var win := Vector2i(size.x, size.y - shrink)
	var d: Control = _make(nova_obj, win, Chrome.PICT if with_pic else Chrome.PANEL)
	d.fit_to_viewport = bool(opts.get("fit", true))
	d.text_color = Color.WHITE
	var black := ColorRect.new()
	black.color = Color.BLACK
	black.size = Vector2(win)
	black.mouse_filter = Control.MOUSE_FILTER_STOP
	d.add_child(black)
	d._add_background(back_tex)
	if with_pic:
		var tr := TextureRect.new()
		tr.texture = pict_tex
		tr.stretch_mode = TextureRect.STRETCH_KEEP
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.clip_contents = true
		tr.position = Vector2(pic_r.position)
		tr.size = Vector2(pic_r.size)
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		d.add_child(tr)
	var view_r := Rect2i(txt_r.position, Vector2i(txt_r.size.x, txt_r.size.y - shrink))
	var sc := DescScroll.new()
	sc.position = Vector2(view_r.position)
	sc.size = Vector2(view_r.size)
	sc.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	sc.get_v_scroll_bar().modulate = Color(1, 1, 1, 0)
	sc.add_child(l)
	sc.label = l
	d.add_child(sc)
	d.texts[2] = l
	d.default_item = 0
	d.cancel_item = 0
	var ok_rect := Rect2i(ok_r.position.x, ok_r.position.y - shrink, ok_r.size.x, ok_r.size.y)
	d.add_button(str(opts.get("ok", "OK")), ok_rect, 0)
	d.set_meta("desc", {"shrink": shrink, "text_height": th, "text_rect": view_r, "scroll": sc,
		"with_picture": with_pic, "size": win, "ok_rect": ok_rect, "dialog_id": dlg_id})
	return d


## The dësc text pane: clipped, scrolls with the wheel, Up/Down, PgUp/PgDn and the right stick.
class DescScroll extends ScrollContainer:
	var label: Label

	func scrollable() -> bool:
		return label != null and label.get_minimum_size().y > size.y + 0.5

	func _process(_dt: float) -> void:
		if not is_visible_in_tree():
			return
		var ax := Input.get_joy_axis(0, JOY_AXIS_RIGHT_Y)
		if absf(ax) > 0.35:
			scroll_vertical += int(ax * 8.0)

	func _input(event: InputEvent) -> void:
		if not is_visible_in_tree() or not scrollable():
			return
		if event.is_action_pressed("ui_up"):
			scroll_vertical -= 16
		elif event.is_action_pressed("ui_down"):
			scroll_vertical += 16
		elif event.is_action_pressed("ui_page_up"):
			scroll_vertical -= int(size.y) - 16
		elif event.is_action_pressed("ui_page_down"):
			scroll_vertical += int(size.y) - 16
		else:
			return
		get_viewport().set_input_as_handled()


func _add_spec_button(spec: Dictionary, rect: Rect2i, idx: int) -> void:
	var b = add_button(str(spec.get("label", "")), rect, idx)
	b.disabled = bool(spec.get("disabled", false))
	if spec.has("action"):
		actions[idx] = spec["action"]
	if bool(spec.get("default", false)):
		default_item = idx
	if bool(spec.get("cancel", false)):
		cancel_item = idx


## Show `dialog` over `parent` (a CanvasLayer / full-rect Control) on a dimmed,
## input-blocking scrim; returns the host. `dialog.close()` frees it again.
static func modal(parent: Node, dialog: Control, dim := 0.55) -> Control:
	var host := Control.new()
	host.set_anchors_preset(Control.PRESET_FULL_RECT)
	host.mouse_filter = Control.MOUSE_FILTER_STOP
	var scrim := ColorRect.new()
	scrim.color = Color(0, 0, 0, dim)
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_IGNORE
	host.add_child(scrim)
	host.add_child(dialog)
	dialog._host = host
	parent.add_child(host)
	return host


func close() -> void:
	var n: Node = _host if _host != null else self
	if is_instance_valid(n):
		n.queue_free()


# --- items ---------------------------------------------------------------------------

func _add_background(frame_tex: Texture2D) -> void:
	match chrome:
		Chrome.NATIVE:
			var bg := ColorRect.new()
			bg.color = Color.WHITE
			bg.size = Vector2(window_size)
			bg.mouse_filter = Control.MOUSE_FILTER_STOP
			add_child(bg)
			var border := ReferenceRect.new()
			border.border_color = Color.BLACK
			border.border_width = 1.0
			border.editor_only = false
			border.size = Vector2(window_size)
			border.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(border)
		Chrome.PICT:
			if frame_tex != null:
				var tr := TextureRect.new()
				tr.texture = frame_tex
				tr.stretch_mode = TextureRect.STRETCH_KEEP
				tr.size = Vector2(window_size)
				tr.mouse_filter = Control.MOUSE_FILTER_STOP
				add_child(tr)
			else:
				_dark_fallback()
		Chrome.PANEL:
			var top := Theme_.pict(8524)
			var mid := Theme_.pict(8525)
			var bot := Theme_.pict(8526)
			if top == null or mid == null or bot == null:
				_dark_fallback()
				return
			# Exactly as the original / Apple DescTextDialog: every piece at its
			# NATIVE size (never stretched) — body under the top piece, top over
			# it, bottom aligned to the dialog's bottom edge — clipped to the
			# dialog. Stretching them is what tore the frame apart.
			clip_contents = true
			var h := float(window_size.y)
			for part in [[mid, float(top.get_height())], [top, 0.0], [bot, h - float(bot.get_height())]]:
				var tr := TextureRect.new()
				tr.texture = part[0]
				tr.stretch_mode = TextureRect.STRETCH_KEEP
				tr.texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
				tr.position = Vector2(0, part[1])
				tr.size = Vector2(part[0].get_size())
				tr.mouse_filter = Control.MOUSE_FILTER_STOP
				add_child(tr)


func _dark_fallback() -> void:
	var bg := ColorRect.new()
	bg.color = Color(0.1, 0.1, 0.12)
	bg.size = Vector2(window_size)
	add_child(bg)


func _register(index: int, c: Control, rect: Rect2i, focusable: bool) -> void:
	if index >= 0:
		items[index] = c
	if focusable:
		_focusables.append({"index": index, "ctrl": c, "rect": rect})
		_dirty_focus = true


## A push button at DITL `rect` (art buttons are drawn at the art's 25 px height,
## centred on the rect, spanning its width; native buttons fill the rect).
func add_button(label: String, rect: Rect2i, index := -1) -> TextureButton:
	var native := chrome == Chrome.NATIVE
	var b = ButtonScript.make(label, rect.size.x, ButtonScript.Style.NATIVE if native else ButtonScript.Style.ART, rect.size.y)
	var y := rect.position.y if native else rect.position.y + (rect.size.y - int(b.size.y)) / 2
	b.position = Vector2(rect.position.x, y)
	if native:
		b.size = Vector2(rect.size)
	add_child(b)
	b.is_default = (index == default_item and index >= 0)
	b.pressed.connect(_activate.bind(index))
	# A greyed button is silent: only the original's specific refusals (shipyard Buy Ship, mission
	# Abort with nothing picked, plunder, the sell that would overdraw mass) wire `refused` -> snd 153.
	_register(index, b, rect, true)
	return b


func add_check(label: String, rect: Rect2i, index := -1) -> TextureButton:
	var b = ButtonScript.make(label, rect.size.x, ButtonScript.Style.CHECK, rect.size.y)
	b.position = Vector2(rect.position)
	add_child(b)
	b.toggled.connect(func(_on): if index >= 0 and actions.has(index): actions[index].call())
	_register(index, b, rect, true)
	return b


## Static text (wrapped, clipped to the rect). Returns the Label.
func add_label(text: String, rect: Rect2i, index := -1, font_size := 12, color := Color(), chrome_font := false) -> Label:
	var l := Label.new()
	l.text = text
	l.position = Vector2(rect.position)
	l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	l.clip_text = true
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	l.add_theme_font_override("font", Theme_.chrome_font() if chrome_font else Theme_.body_font())
	l.add_theme_font_size_override("font_size", font_size)
	l.add_theme_color_override("font_color", color if color != Color() else text_color)
	l.add_theme_constant_override("line_spacing", 0)
	l.size = Vector2(rect.size)   # after the font overrides (size clamps to the minimum at assignment)
	l.set_deferred("size", Vector2(rect.size))
	add_child(l)
	if index >= 0:
		texts[index] = l
	_register(index, l, rect, false)
	return l


## A single-line edit field (item text = initial value).
func add_edit(initial: String, rect: Rect2i, index := -1) -> LineEdit:
	var e := LineEdit.new()
	e.text = initial
	e.position = Vector2(rect.position)
	e.add_theme_font_override("font", Theme_.body_font())
	e.add_theme_font_size_override("font_size", 12)
	e.add_theme_color_override("font_color", Color.BLACK)
	e.add_theme_color_override("caret_color", Color.BLACK)
	e.add_theme_color_override("selection_color", Color(0.6, 0.7, 0.95))
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color.WHITE
	sb.border_color = Theme_.NATIVE_DARK
	sb.set_border_width_all(1)
	sb.content_margin_left = 3
	sb.content_margin_right = 3
	sb.content_margin_top = 0
	sb.content_margin_bottom = 0
	e.add_theme_stylebox_override("normal", sb)
	e.add_theme_stylebox_override("focus", sb)   # the caret is the only focus cue (no outline)
	e.size = Vector2(rect.size)
	# A LineEdit can't be shorter than its font line + borders (22 px here vs the DITL's 16 px rows):
	# keep the box centred on the DITL rect (as the original / Apple's centred TextField) instead of
	# growing downward over the next row, so the text sits mid-box.
	var fit := func():
		var h: float = maxf(float(rect.size.y), e.get_combined_minimum_size().y)
		e.size = Vector2(float(rect.size.x), h)
		e.position = Vector2(float(rect.position.x), float(rect.position.y) + (float(rect.size.y) - h) * 0.5)
	e.minimum_size_changed.connect(fit)
	e.text_submitted.connect(func(_t): if default_item >= 0: _activate(default_item))
	add_child(e)
	fit.call()
	texts[index] = e
	_register(index, e, rect, true)
	return e


## A pop-up-menu stand-in (the DITLs' `control` items on CNTL 500 / 501): a native button at `rect`
## that shows the current entry and steps to the next on every press (a real pop-up would open an
## unscaled OS-style window, and cycling is what the gamepad wants anyway). Read `selected_of(index)`;
## `cycled(index, selected)` fires on change.
signal cycled(index: int, selected: int)
var _cycle := {}      # DITL index -> {labels, selected}

func add_cycle(labels: Array, rect: Rect2i, index := -1, selected := 0) -> TextureButton:
	var b = ButtonScript.make("", rect.size.x, ButtonScript.Style.NATIVE, rect.size.y)
	b.position = Vector2(rect.position)
	b.size = Vector2(rect.size)
	add_child(b)
	_cycle[index] = {"labels": labels, "selected": clampi(selected, 0, maxi(0, labels.size() - 1))}
	var refresh := func():
		var c: Dictionary = _cycle[index]
		b.label = "%s  \u25be" % str(c["labels"][c["selected"]]) if not c["labels"].is_empty() else ""
	refresh.call()
	b.pressed.connect(func():
		var c: Dictionary = _cycle[index]
		if c["labels"].size() > 1:
			c["selected"] = (int(c["selected"]) + 1) % c["labels"].size()
			refresh.call()
			cycled.emit(index, int(c["selected"]))
		if beep and nova != null and nova.has_method("sound_beep"):
			nova.sound_beep(1))
	_register(index, b, rect, true)
	return b


func selected_of(index: int) -> int:
	return int(_cycle[index]["selected"]) if _cycle.has(index) else 0


## A PICT / icon item; clickable when `actions[index]` is bound.
func add_picture(pict_id: int, rect: Rect2i, index := -1) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = Theme_.pict(pict_id)
	tr.stretch_mode = TextureRect.STRETCH_SCALE
	tr.position = Vector2(rect.position)
	tr.size = Vector2(rect.size)
	tr.mouse_filter = Control.MOUSE_FILTER_PASS
	tr.gui_input.connect(func(ev: InputEvent):
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			_activate(index))
	add_child(tr)
	_register(index, tr, rect, false)
	return tr


# --- access ---------------------------------------------------------------------------

func item(index: int) -> Control:
	return items.get(index)


func set_text(index: int, text: String) -> void:
	var c: Control = texts.get(index)
	if c != null:
		c.text = text


func edit_text(index := 4) -> String:
	var e: Control = texts.get(index)
	return e.text if e is LineEdit else ""


## What the original stores for a text prompt: a leading "the " removed. Null-ish
## empty string when over the 64-byte limit (the original beeps and stays open).
static func prompt_answer(s: String) -> String:
	var t := s
	if t.to_lower().begins_with("the "):
		t = t.substr(4)
	return t


func focus_first() -> void:
	var target: Control = null
	for f in _focusables:
		if f["index"] == default_item:
			target = f["ctrl"]
	if target == null and not _focusables.is_empty():
		target = _focusables[0]["ctrl"]
	if target != null and target.is_inside_tree():
		target.grab_focus()


func _activate(index: int) -> void:
	if beep and nova != null and nova.has_method("sound_beep") and items.get(index) is BaseButton:
		nova.sound_beep(1)
	if actions.has(index):
		# The action's owner can already be gone (a press that closed the screen,
		# then a second press/accept in the same frame) — skip a dead Callable
		# instead of erroring.
		var action: Callable = actions[index]
		if action.is_valid():
			action.call()
		else:
			actions.erase(index)
	activated.emit(index)
	if index >= 0 and index == default_item:
		accepted.emit()
	if index >= 0 and index == cancel_item:
		cancelled.emit()


# --- layout / input ---------------------------------------------------------------------

func _ready() -> void:
	_wire_focus()
	fit()
	get_viewport().size_changed.connect(fit)
	focus_first.call_deferred()


## Scale crisply and centre in the viewport (call again after changing the window).
func fit() -> void:
	if not is_inside_tree():
		return
	var vp := get_viewport_rect().size
	var s := 1.0
	if fit_to_viewport and nova != null and nova.has_method("classic_crisp_scale"):
		s = float(nova.classic_crisp_scale(window_size.x, window_size.y, vp.x, vp.y))
	scale = Vector2(s, s)
	position = ((vp - Vector2(window_size) * s) / 2.0).round()


## Focus neighbours from the DITL geometry (up/down/left/right).
func _wire_focus() -> void:
	if not _dirty_focus or _focusables.size() < 2 or nova == null:
		return
	_dirty_focus = false
	var flat := PackedInt32Array()
	for f in _focusables:
		var r: Rect2i = f["rect"]
		flat.append_array(PackedInt32Array([r.position.x, r.position.y, r.end.x, r.end.y]))
	var nb: PackedInt32Array = nova.classic_focus_neighbours(flat)
	var sides := [SIDE_TOP, SIDE_BOTTOM, SIDE_LEFT, SIDE_RIGHT]
	for i in _focusables.size():
		var c: Control = _focusables[i]["ctrl"]
		for d in 4:
			var j := nb[i * 4 + d]
			if j >= 0:
				c.set_focus_neighbor(sides[d], c.get_path_to(_focusables[j]["ctrl"]))
	# Tab order follows reading order.


func _input(event: InputEvent) -> void:
	if not is_visible_in_tree() or cancel_item < 0:
		return
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		_activate(cancel_item)
