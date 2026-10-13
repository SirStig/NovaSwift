# NOVA Swift — the loading screen (port of the Apple app's LoadingView + Branding art): the launch
# key art drifting behind three depths of parallax stars, the NOVA SWIFT wordmark with its fire
# flickering, amber targeting brackets in the corners, and a ship's-computer readout (phase, count,
# percent, a cockpit-gauge bar, a tip).
#
# Driven by Shell (`show_loading` / `set_loading_progress` / `hide_loading`, see screens/Shell.gd):
# this node only draws. Progress is real when the caller reports it (`set_progress`); otherwise the
# bar sweeps (`set_indeterminate`). The bar follows the presentation mode like the Apple view:
# the original's flat cölr ProgressBar in Classic (ProgOutline frame, ProgBright fill, 198-px
# span), the amber segmented gauge in Nova Swift.
#
# Loaded with preload() (no class_name), like Controls.gd. Layer 200: above every shell screen.
extends CanvasLayer

const Prefs = preload("res://Prefs.gd")
const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")

const AMBER := Color(1.0, 0.7, 0.28)
const BRANDING := "res://assets/branding/"
const TIPS := [
	"Land on a planet or station to trade, refuel, repair, and take on missions.",
	"Check the Mission BBS and the Bar at each port -- that's where jobs and storylines begin.",
	"Every hyperspace jump burns fuel. Refuel when you land before heading back out.",
	"Disable a ship with weapons fire, then board it to plunder its cargo and credits.",
	"Your standing with each government decides who greets you and who opens fire.",
	"Spend credits at the Outfitter -- afterburners, shields and weapons change how you fight.",
	"Open the galaxy map to plot a course; your ship jumps through it one system at a time.",
	"Buy goods cheap on industrial worlds and sell them dear out on the frontier.",
	"Hire escorts at the Bar to fight at your side -- they draw a daily wage.",
	"Cargo and courier missions pay on delivery, and some run against a deadline.",
	"Some missions only appear at the right place and time, or once a government trusts you.",
]
const CELLS := 36
## The original's bar: fill span 198 px (LoadingProgressBar.fillSpan) inside a 204x10 rect.
const CLASSIC_W := 204
const CLASSIC_H := 10
const CLASSIC_SCALE := 2
const OPEN_STEP_SECONDS := 2.0 / 60.0

var phase := "Loading"
var count_text := ""
var fraction := 0.0            # 0...1, drawn value
var indeterminate := true
var shown_seconds := 0.0

var _target := 0.0
var _t := 0.0
var _classic := false
var _root: Control
var _backdrop: TextureRect
var _flames: TextureRect
var _letters: TextureRect
var _stars: Control
var _brackets: Control
var _bar: Control
var _phase_label: Label
var _count_label: Label
var _pct_label: Label
var _tip_label: Label
var _tip_index := randi() % TIPS.size()
var _tip_timer := 0.0
var _opening_step := 0
var _star_data: Array = []


func _ready() -> void:
	layer = 200
	_classic = not bool(Prefs.get_value("presentation", "modern_menu"))
	_build()
	_seed_stars()


static func _texture(file: String) -> Texture2D:
	var path := BRANDING + file
	if ResourceLoader.exists(path):
		var t = load(path)
		if t is Texture2D:
			return t
	# Not imported (a bare checkout never opened in the editor): read the PNG directly.
	var img := Image.load_from_file(ProjectSettings.globalize_path(path))
	return ImageTexture.create_from_image(img) if img != null else null


func _build() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_STOP   # nothing below is clickable while loading
	add_child(_root)
	var black := ColorRect.new()
	black.color = Color(0.01, 0.012, 0.025)
	black.set_anchors_preset(Control.PRESET_FULL_RECT)
	black.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(black)

	_backdrop = TextureRect.new()
	_backdrop.texture = _texture("launch-backdrop.png")
	_backdrop.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	_backdrop.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_COVERED
	_backdrop.set_anchors_preset(Control.PRESET_FULL_RECT)
	_backdrop.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_backdrop.pivot_offset = get_viewport().get_visible_rect().size * 0.5
	_root.add_child(_backdrop)

	_stars = _Stars.new()
	_stars.owner_screen = self
	_stars.set_anchors_preset(Control.PRESET_FULL_RECT)
	_stars.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_stars)

	# Darken toward the bottom so the readout stays legible.
	var shade := TextureRect.new()
	var grad := Gradient.new()
	grad.set_color(0, Color(0, 0, 0, 0))
	grad.set_color(1, Color(0, 0, 0, 0.6))
	grad.add_point(0.5, Color(0, 0, 0, 0))
	var gt := GradientTexture2D.new()
	gt.gradient = grad
	gt.fill_from = Vector2(0, 0)
	gt.fill_to = Vector2(0, 1)
	gt.width = 4
	gt.height = 256
	shade.texture = gt
	shade.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	shade.set_anchors_preset(Control.PRESET_FULL_RECT)
	shade.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(shade)

	var col := VBoxContainer.new()
	col.set_anchors_preset(Control.PRESET_FULL_RECT)
	col.offset_left = 32
	col.offset_right = -32
	col.offset_top = 24
	col.offset_bottom = -34
	col.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(col)

	var mark_box := CenterContainer.new()
	mark_box.size_flags_vertical = Control.SIZE_EXPAND_FILL
	mark_box.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(mark_box)
	var mark := Control.new()
	mark.custom_minimum_size = Vector2(620, 310)
	mark.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mark_box.add_child(mark)
	for pair in [["wordmark-flames.png", "_flames"], ["wordmark-letters.png", "_letters"]]:
		var tr := TextureRect.new()
		tr.texture = _texture(pair[0])
		tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
		tr.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
		tr.set_anchors_preset(Control.PRESET_FULL_RECT)
		tr.pivot_offset = Vector2(310, 310)   # flames grow from the bottom edge
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		mark.add_child(tr)
		set(pair[1], tr)

	var panel_row := CenterContainer.new()
	panel_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
	col.add_child(panel_row)
	var panel := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.55)
	sb.border_color = Color(AMBER.r, AMBER.g, AMBER.b, 0.22)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 26
	sb.content_margin_right = 26
	sb.content_margin_top = 18
	sb.content_margin_bottom = 18
	panel.add_theme_stylebox_override("panel", sb)
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel_row.add_child(panel)
	var v := VBoxContainer.new()
	v.custom_minimum_size = Vector2(520, 0)
	v.add_theme_constant_override("separation", 14)
	v.mouse_filter = Control.MOUSE_FILTER_IGNORE
	panel.add_child(v)

	var head := HBoxContainer.new()
	head.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(head)
	_phase_label = _label(head, phase.to_upper(), 13, Color(AMBER.r, AMBER.g, AMBER.b, 0.9))
	_phase_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_count_label = _label(head, " ", 13, Color(0.7, 0.72, 0.78))
	_pct_label = _label(head, "", 13, Color(AMBER.r, AMBER.g, AMBER.b, 0.9))
	_pct_label.custom_minimum_size = Vector2(48, 0)
	_pct_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT

	_bar = _Bar.new()
	_bar.owner_screen = self
	_bar.custom_minimum_size = Vector2(CLASSIC_W * CLASSIC_SCALE, CLASSIC_H * CLASSIC_SCALE) if _classic else Vector2(0, 12)
	_bar.size_flags_horizontal = Control.SIZE_SHRINK_CENTER if _classic else Control.SIZE_FILL
	_bar.mouse_filter = Control.MOUSE_FILTER_IGNORE
	v.add_child(_bar)

	var tip_head := _label(v, "TIP", 12, Color(AMBER.r, AMBER.g, AMBER.b, 0.7))
	tip_head.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tip_label = _label(v, TIPS[_tip_index], 13, Color(0.7, 0.72, 0.78))
	_tip_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_tip_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	_tip_label.custom_minimum_size = Vector2(460, 36)

	_brackets = _Brackets.new()
	_brackets.set_anchors_preset(Control.PRESET_FULL_RECT)
	_brackets.offset_left = 18
	_brackets.offset_top = 18
	_brackets.offset_right = -18
	_brackets.offset_bottom = -18
	_brackets.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.add_child(_brackets)
	_refresh_labels()


func _label(parent: Control, text: String, size: int, color: Color) -> Label:
	var l := Label.new()
	l.text = text
	l.add_theme_font_size_override("font_size", size)
	l.add_theme_color_override("font_color", color)
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(l)
	return l


func _seed_stars() -> void:
	# A fixed, seeded field at three depths: nearer stars move faster and shine brighter.
	var rng := RandomNumberGenerator.new()
	rng.seed = 7
	for i in 170:
		var depth := rng.randf()
		_star_data.append({"x": rng.randf(), "y": rng.randf(), "speed": 0.002 + depth * depth * 0.014,
			"size": 0.8 + depth * 1.8, "alpha": 0.25 + depth * 0.6})


# --- reporting ---------------------------------------------------------------------

## Real progress: `frac` in 0...1 (monotonic -- the bar never steps back), optional "12 / 40".
func set_progress(new_phase: String, frac: float, count := "") -> void:
	phase = new_phase
	count_text = count
	indeterminate = false
	_target = maxf(_target, clampf(frac, 0.0, 1.0))
	_refresh_labels()


## No measurable progress: the bar sweeps until the caller hides the screen.
func set_indeterminate(new_phase: String) -> void:
	phase = new_phase
	count_text = ""
	indeterminate = true
	_refresh_labels()


func percent() -> int:
	return roundi(fraction * 100.0)


func _refresh_labels() -> void:
	if _phase_label == null:
		return
	_phase_label.text = phase.to_upper()
	_count_label.text = count_text if count_text != "" else " "
	_pct_label.text = "" if indeterminate else "%d%%" % percent()


func _process(delta: float) -> void:
	_t += delta
	shown_seconds += delta
	# The bar eases toward the reported value rather than jumping.
	fraction = move_toward(fraction, _target, delta * 1.5)
	if not indeterminate:
		_pct_label.text = "%d%%" % percent()
	var vs := get_viewport().get_visible_rect().size
	if _backdrop != null:
		_backdrop.pivot_offset = vs * 0.5
		var z := 1.06 + 0.03 * sin(_t / 23.0)
		_backdrop.scale = Vector2(z, z)
		_backdrop.position = Vector2(14.0 * sin(_t / 31.0), 8.0 * cos(_t / 37.0))
	if _flames != null:
		# A few unrelated sines read as irregular flicker, not a pulse.
		var lift := 1.0 + 0.035 * sin(_t * 7.1) + 0.022 * sin(_t * 12.7 + 1.3) + 0.012 * sin(_t * 23.3 + 0.4)
		var glow := 0.86 + 0.08 * sin(_t * 9.3 + 2.1) + 0.06 * sin(_t * 15.9)
		_flames.pivot_offset = Vector2(_flames.size.x * 0.5, _flames.size.y)
		_flames.scale = Vector2(1.0 + 0.01 * sin(_t * 5.3), lift)
		_flames.modulate = Color(1, 1, 1, glow)
	_opening_step = int(_t / OPEN_STEP_SECONDS)
	_tip_timer += delta
	if _tip_timer > 7.0:
		_tip_timer = 0.0
		_tip_index = (_tip_index + 1) % TIPS.size()
		_tip_label.text = TIPS[_tip_index]
	_stars.queue_redraw()
	_bar.queue_redraw()


# --- drawing helpers (inner controls call back into the screen) ------------------------

class _Stars extends Control:
	var owner_screen: Node

	func _draw() -> void:
		if owner_screen == null:
			return
		var t: float = owner_screen._t
		for st in owner_screen._star_data:
			var x := fposmod(float(st.x) - t * float(st.speed), 1.0)
			draw_circle(Vector2(x * size.x, float(st.y) * size.y), float(st.size) * 0.5, Color(1, 1, 1, float(st.alpha)))


class _Brackets extends Control:
	func _draw() -> void:
		var l := minf(56.0, size.x * 0.06)
		var c := Color(AMBER.r, AMBER.g, AMBER.b, 0.7)
		var corners := [[0.0, 0.0, 1.0, 1.0], [size.x, 0.0, -1.0, 1.0], [0.0, size.y, 1.0, -1.0], [size.x, size.y, -1.0, -1.0]]
		for k in corners:
			draw_polyline(PackedVector2Array([Vector2(k[0] + k[2] * l, k[1]), Vector2(k[0], k[1]), Vector2(k[0], k[1] + k[3] * l)]), c, 2.0)


class _Bar extends Control:
	var owner_screen: Node

	func _draw() -> void:
		if owner_screen == null:
			return
		if owner_screen._classic:
			_draw_classic()
		else:
			_draw_segmented()

	func _value() -> float:
		return owner_screen.fraction

	func _draw_segmented() -> void:
		var gap := 3.0
		var w := maxf(1.0, (size.x - gap * (CELLS - 1)) / CELLS)
		var lit := int(floor(clampf(_value(), 0.0, 1.0) * CELLS))
		var sweep := -1
		if owner_screen.indeterminate:
			# A short lit run travelling along the gauge.
			sweep = int(owner_screen._t * 18.0) % (CELLS + 6) - 3
		for i in CELLS:
			var on := (i >= sweep and i < sweep + 4) if owner_screen.indeterminate else (i < lit)
			var r := Rect2(i * (w + gap), 0, w, size.y)
			if on:
				var bright := 1.0 if (i == lit - 1 or (owner_screen.indeterminate and i == sweep + 3)) else 0.82
				draw_rect(r.grow(2.0), Color(AMBER.r, AMBER.g, AMBER.b, 0.12))
				draw_rect(r, Color(AMBER.r, AMBER.g, AMBER.b, bright))
			else:
				draw_rect(r, Color(AMBER.r, AMBER.g, AMBER.b, 0.08))
				draw_rect(r, Color(AMBER.r, AMBER.g, AMBER.b, 0.28), false, 1.0)

	func _draw_classic() -> void:
		# NovaUi_RedrawProgressBar 0x004ab3d0: ProgOutline frame, ProgBright fill, ProgDim frame,
		# black beyond; the outline opens from the middle row one pixel per 2 ticks.
		var s := float(CLASSIC_SCALE)
		var out := ClassicTheme.color("progOutline")
		var bright := ClassicTheme.color("progBright")
		var dim := ClassicTheme.color("progDim")
		var step: int = owner_screen._opening_step
		var mid := CLASSIC_H / 2
		var t := mid - step
		var b := mid + step
		if t > 0 or b < CLASSIC_H:
			t = maxi(t, 0)
			b = mini(b, CLASSIC_H)
			draw_rect(Rect2(0, t * s, CLASSIC_W * s, (b - t) * s), Color.BLACK)
			draw_rect(Rect2(0, t * s, CLASSIC_W * s, (b - t) * s), out, false, s)
			return
		var fill_right := CLASSIC_W - 1
		if owner_screen.indeterminate:
			fill_right = 1 + int(fposmod(owner_screen._t * 90.0, 198.0))
		else:
			fill_right = mini(int(floor(1.0 + clampf(_value(), 0.0, 1.0) * 198.0)), CLASSIC_W - 1)
		draw_rect(Rect2(0, 0, CLASSIC_W * s, CLASSIC_H * s), Color.BLACK)
		draw_rect(Rect2(2 * s, 2 * s, maxf(0.0, fill_right - 3) * s, (CLASSIC_H - 4) * s), bright)
		draw_rect(Rect2(1 * s, 1 * s, maxf(0.0, fill_right - 1) * s, (CLASSIC_H - 2) * s), dim, false, s)
		draw_rect(Rect2(0, 0, CLASSIC_W * s, CLASSIC_H * s), out, false, s)
