# NOVA Swift — Classic UI kit: one original-art push button.
#
# A TextureButton showing the real EV Nova three-state button (PICT 7500+3s caps /
# middle, masks 7600+3s: normal, pressed, grey) at the requested width, with the
# label drawn in the cölr button font and per-state colours. The original has no
# hover or focus outline: the mouse shows nothing but the pressed art. Keyboard /
# gamepad focus is shown only while the last input was keyboard-nav or a pad
# (ClassicTheme.nav_active) and mirrors the Apple controller cursor's target
# treatment: the ART button grows 1.07x (CursorClickable hover-grow); NATIVE and
# CHECK buttons get the original's dotted default ring. `Style.NATIVE` is the original's bevelled grey
# push button of the text/yes-no prompts (DLOG 3001/3002, ClassicUiWindow);
# `Style.CHECK` is its X check box.
#
#   var b := ClassicButton.make("Done", 120)         # 120 px wide, art height
#   b.pressed.connect(...)                            # TextureButton signals
#
# Loaded with preload() (no class_name), like Controls.gd.
extends TextureButton

const Theme_ := preload("res://ui/classic/ClassicTheme.gd")

enum Style { ART, NATIVE, CHECK }

var style: int = Style.ART
var label := "":
	set(v):
		label = v
		if _face != null:
			_face.queue_redraw()
## Alias of `label`, so code that reads a Button's `text` works on either.
var text: String:
	get: return label
	set(v): label = v
## The dialog's default item: native buttons keep their dotted rect.
var is_default := false:
	set(v):
		is_default = v
		if _face != null:
			_face.queue_redraw()
## Fired when a disabled button is pressed (the original beeps, snd 153).
signal refused

var _face: Control


## `width` is the whole button (caps included). Height is the art's (25) for ART,
## or `height` for NATIVE / CHECK.
static func make(text: String, width: int, btn_style: int = Style.ART, height := 20) -> TextureButton:
	var b = (load("res://ui/classic/ClassicButton.gd") as GDScript).new()
	b.setup(text, width, btn_style, height)
	return b


func setup(text: String, width: int, btn_style: int = Style.ART, height := 20) -> void:
	style = btn_style
	label = text
	ignore_texture_size = true
	stretch_mode = TextureButton.STRETCH_KEEP
	texture_filter = CanvasItem.TEXTURE_FILTER_NEAREST
	focus_mode = Control.FOCUS_ALL
	var h := height
	if style == Style.ART:
		h = Theme_.button_height()
		texture_normal = Theme_.button_texture(width, 0)
		texture_pressed = Theme_.button_texture(width, 1)
		texture_disabled = Theme_.button_texture(width, 2)
	elif style == Style.CHECK:
		toggle_mode = true
	custom_minimum_size = Vector2(width, h)
	size = Vector2(width, h)
	_face = _Face.new()
	_face.btn = self
	_face.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_face.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(_face)
	for sig in [button_down, button_up, toggled]:
		sig.connect(func(_a = null): _face.queue_redraw())
	focus_entered.connect(_sync_focus)
	focus_exited.connect(_sync_focus)
	resized.connect(func(): pivot_offset = size / 2.0)
	pivot_offset = Vector2(width, h) / 2.0


func _enter_tree() -> void:
	Theme_.track(self)
	Theme_.on_nav_changed(_sync_focus_flag)


func _sync_focus_flag(_on: bool) -> void:
	_sync_focus()


## Focus indication follows focus AND the last input device.
func _sync_focus() -> void:
	if _face != null:
		_face.queue_redraw()
	if style == Style.ART:
		var want := 1.07 if (Theme_.show_focus(self) and not disabled) else 1.0
		if not is_equal_approx(scale.x, want):
			var tw := create_tween()
			tw.tween_property(self, "scale", Vector2(want, want), 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT)


func _gui_input(event: InputEvent) -> void:
	# A press on a greyed button is refused, not ignored.
	if disabled and event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		refused.emit()


func _notification(what: int) -> void:
	if what == NOTIFICATION_DISABLED or what == NOTIFICATION_ENABLED:
		if _face != null:
			_face.queue_redraw()


class _Face extends Control:
	var btn: TextureButton

	func _draw() -> void:
		if btn == null:
			return
		var w := size.x
		var h := size.y
		var disabled: bool = btn.disabled
		var down: bool = btn.button_pressed if btn.toggle_mode else btn.is_pressed()
		match btn.style:
			Style.NATIVE:
				_draw_native(w, h, disabled, down)
			Style.CHECK:
				_draw_check(w, h, disabled, down)
			_:
				_draw_art_label(w, h, disabled, down)
		if Theme_.show_focus(btn) and not disabled:
			if btn.style == Style.NATIVE:
				_dotted_rect(Rect2(3, 3, w - 6, h - 6), Color.BLACK)
			elif btn.style == Style.CHECK:
				_dotted_rect(Rect2(-2, -2, 21, 21), Color.BLACK)

	func _label_font() -> Font:
		return Theme_.font_for(str(Theme_.palette().get("buttonFont", "Charcoal")))

	func _label_size() -> int:
		return int(Theme_.palette().get("buttonFontSize", 12))

	func _draw_art_label(w: float, h: float, disabled: bool, down: bool) -> void:
		var pal: Dictionary = Theme_.palette()
		var col: Color = pal["buttonGrey"] if disabled else (pal["buttonDown"] if down else pal["buttonUp"])
		var t: String = btn.label
		if t.length() == 1 and "^&+-".contains(t):
			_draw_glyph(t, w, h, col)
			return
		if t == "":
			return
		var font := _label_font()
		var fs := _label_size()
		var tw := font.get_string_size(t, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		# ThreeStateButton.labelOrigin: centred, baseline = h/2 + 5.
		draw_string(font, Vector2(roundf(w / 2.0 - tw / 2.0), floorf(h / 2.0) + 5), t,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)

	## The vector glyphs the original draws for "^ & + -" labels (2 px pen).
	func _draw_glyph(t: String, w: float, h: float, col: Color) -> void:
		var cx := floorf(w / 2.0)
		var cy := floorf(h / 2.0)
		var segs: Array = []
		match t:
			"^":
				var s := int(h / 10.0)
				segs = [[cx, cy - s, cx - 2 * s, cy + s], [cx, cy - s, cx + 2 * s, cy + s]]
			"&":
				var s := int(h / 10.0)
				segs = [[cx, cy + s, cx - 2 * s, cy - s], [cx, cy + s, cx + 2 * s, cy - s]]
			"+":
				var s := int(h / 8.0)
				segs = [[cx - s, cy, cx + s, cy], [cx, cy - s, cx, cy + s]]
			"-":
				var s := int(h / 9.0)
				segs = [[cx - s, cy, cx + s, cy]]
		for g in segs:
			draw_line(Vector2(g[0] + 1, g[1] + 1), Vector2(g[2] + 1, g[3] + 1), col, 2.0)

	func _bevel(w: float, h: float, light: Color, dark: Color) -> void:
		# FUN_004d0a50: light top/left inset 1, dark bottom/right inset 1-2.
		draw_rect(Rect2(1, 1, w - 2, 1), light)
		draw_rect(Rect2(1, 1, 1, h - 2), light)
		draw_rect(Rect2(1, h - 2, w - 2, 1), dark)
		draw_rect(Rect2(w - 2, 1, 1, h - 2), dark)

	func _draw_native(w: float, h: float, disabled: bool, down: bool) -> void:
		var T = Theme_
		draw_rect(Rect2(0, 0, w, h), T.NATIVE_PRESSED if down else T.NATIVE_FILL)
		draw_rect(Rect2(0, 0, w, h), Color.BLACK, false, 1.0)
		if down:
			_bevel(w, h, T.NATIVE_DARK, T.NATIVE_LIGHT)
		else:
			_bevel(w, h, T.NATIVE_LIGHT, T.NATIVE_DARK)
		var font: Font = T.body_font()
		var fs := 12
		var tw := font.get_string_size(btn.label, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x
		var col := Color(0.35, 0.35, 0.35) if disabled else Color.BLACK
		# baseline (top + bottom + size) / 2 - 1
		draw_string(font, Vector2(roundf(w / 2.0 - tw / 2.0), floorf((h + fs) / 2.0) - 1), btn.label,
			HORIZONTAL_ALIGNMENT_LEFT, -1, fs, col)
		if btn.is_default and not Theme_.show_focus(btn):
			_dotted_rect(Rect2(3, 3, w - 6, h - 6), Color.BLACK)

	func _draw_check(w: float, h: float, disabled: bool, down: bool) -> void:
		var T = Theme_
		draw_rect(Rect2(0, 0, 17, 17), T.NATIVE_FILL)
		_bevel(17, 17, T.NATIVE_LIGHT, T.NATIVE_DARK)
		draw_rect(Rect2(0, 0, 17, 17), Color.BLACK, false, 1.0)
		if down:
			draw_line(Vector2(3, 3), Vector2(14, 14), Color.BLACK, 1.0)
			draw_line(Vector2(14, 3), Vector2(3, 14), Color.BLACK, 1.0)
		draw_string(T.body_font(), Vector2(20, 13), btn.label, HORIZONTAL_ALIGNMENT_LEFT, w - 20, 12,
			Color(0.35, 0.35, 0.35) if disabled else Color.BLACK)

	func _dotted_rect(r: Rect2, col: Color) -> void:
		var x := r.position.x
		while x < r.end.x:
			draw_rect(Rect2(x, r.position.y, 1, 1), col)
			draw_rect(Rect2(x, r.end.y - 1, 1, 1), col)
			x += 2
		var y := r.position.y
		while y < r.end.y:
			draw_rect(Rect2(r.position.x, y, 1, 1), col)
			draw_rect(Rect2(r.end.x - 1, y, 1, 1), col)
			y += 2
