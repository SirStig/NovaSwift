# NOVA Swift — NovaSwift UI kit: form controls and building blocks, mirroring the Apple app's
# NovaFormControls.swift (NovaToggleStyle, NovaSlider, NovaSegmentedPicker, NovaMenuPicker),
# NovaDialog.swift (NovaTextField, NovaSelectRow) and the SwiftUI Form / button styles the port's
# own screens use. Everything is built from stock Godot controls (Button, CheckBox, HSlider,
# OptionButton, LineEdit, PanelContainer, Label + StyleBoxFlat + icon textures), so it composes in
# the headless preview and navigates by Godot focus alone.
#
# Every builder takes the `parent` it adds to and returns the control, so a screen reads like the
# SwiftUI one:
#
#   var g := NC.section(page, "Graphics", "sparkles", "footer text")
#   NC.toggle(g, "Smooth sprite scaling", on, func(v): ...)
#   NC.slider(g, "Starfield density", 1.0, 0.2, 2.0, 0.05, NC.pct, func(v): ...)
#   NC.menu(g, "Camera view", ["Classic", "Look ahead"], 0, func(i): ...)
#   NC.segmented(g, ["Low", "Medium", "High"], 2, func(i): ...)
#   NC.form_button(g, "Import Data", "square.and.arrow.down", func(): ...)
#
# Focus: keyboard / pad focus shows the kit's own treatment (Apple's controller-cursor "hover-grow"
# plus an amber ring) only while the last input was keyboard / pad — never for the mouse. The
# stock Godot focus box is switched off in NovaTheme.theme().
#
# Loaded with preload() (no class_name), like Controls.gd.
extends RefCounted

const T = preload("res://ui/novaswift/NovaTheme.gd")
const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")

const ROW_H := 40.0


## A grouped Form section's box: rows are added with `add_row` (a hairline separates them).
class Group extends VBoxContainer:
	var rows := 0

	func _init() -> void:
		add_theme_constant_override("separation", 0)

	## Add `c` as the next row (min height 40, hairline above it unless it is the first).
	func add_row(c: Control, min_h := 40.0) -> Control:
		if rows > 0:
			var line := ColorRect.new()
			line.color = T.GROUP_LINE
			line.custom_minimum_size = Vector2(0, 1)
			line.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(line)
		var holder := MarginContainer.new()
		holder.custom_minimum_size = Vector2(0, min_h)
		holder.add_theme_constant_override("margin_left", 12)
		holder.add_theme_constant_override("margin_right", 12)
		holder.add_theme_constant_override("margin_top", 2)
		holder.add_theme_constant_override("margin_bottom", 2)
		c.size_flags_vertical = Control.SIZE_SHRINK_CENTER if not (c is VBoxContainer) else Control.SIZE_FILL
		holder.add_child(c)
		add_child(holder)
		rows += 1
		return c


# --- text ------------------------------------------------------------------------------------

static func label(parent: Node, text: String, role := "body", weight := "regular", color: Variant = T.WHITE,
		wrap := false) -> Label:
	var l := Label.new()
	l.text = text
	T.style_text(l, role, weight, color)
	if wrap:
		l.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
		l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if parent != null:
		parent.add_child(l)
	return l


## `.novaFont(.caption).foregroundStyle(.secondary)`
static func caption(parent: Node, text: String) -> Label:
	return label(parent, text, "caption", "regular", T.SECONDARY, true)


## A Form section footer (system footnote, secondary).
static func footer(parent: Node, text: String) -> Label:
	var l := label(parent, text, "caption", "regular", T.SECONDARY, true)
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_font_override("font", T.system())
	return l


static func spacer(parent: Node, h := 0.0, expand := false) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if expand:
		c.size_flags_vertical = Control.SIZE_EXPAND_FILL
		c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(c)
	return c


static func hspacer(parent: Node) -> Control:
	var c := Control.new()
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	parent.add_child(c)
	return c


static func pct(x: float) -> String:
	return "%d%%" % roundi(x * 100.0)


# --- sections (SwiftUI Form / Section) -----------------------------------------------------------

## Section header: SF icon + amber `.button` semibold title (SettingsView.sectionHeader).
static func section_header(parent: Node, title: String, icon_name := "") -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	if icon_name != "":
		var tr := TextureRect.new()
		tr.texture = T.icon(icon_name, 16, T.AMBER)
		tr.custom_minimum_size = Vector2(16, 16)
		tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(tr)
	label(h, title, "button", "semibold", T.AMBER)
	parent.add_child(h)
	return h


## A grouped section: header (icon + title), a rounded dark group box returned for rows, and the
## muted footer beneath it. `parent` is the page's VBox.
static func section(parent: Node, title: String, icon_name := "", footer_text := "") -> Group:
	var top := parent.get_child_count() > 0
	if top:
		spacer(parent, 10)
	var hdr_wrap := MarginContainer.new()
	hdr_wrap.add_theme_constant_override("margin_left", 4)
	hdr_wrap.add_theme_constant_override("margin_bottom", 2)
	parent.add_child(hdr_wrap)
	if title != "":
		section_header(hdr_wrap, title, icon_name)
	var box := PanelContainer.new()
	box.add_theme_stylebox_override("panel", T.box(T.GROUP_BG, 10, Color(1, 1, 1, 0.05), 1))
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent.add_child(box)
	var g := Group.new()
	g.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	box.add_child(g)
	if footer_text != "":
		var fw := MarginContainer.new()
		fw.add_theme_constant_override("margin_left", 4)
		fw.add_theme_constant_override("margin_right", 4)
		fw.add_theme_constant_override("margin_top", 6)
		parent.add_child(fw)
		footer(fw, footer_text)
	return g


# --- focus treatment -----------------------------------------------------------------------------

## Apple's controller-cursor hover-grow, pad / keyboard only: scale up a touch around the centre
## while focused (small controls 1.07, wide rows 1.015). The amber ring is the theme's focus box.
static func grow_on_focus(c: Control, amount := 1.05) -> void:
	c.focus_entered.connect(func():
		if not ClassicTheme.nav_active or not is_instance_valid(c):
			return
		c.pivot_offset = c.size * 0.5
		var tw := c.create_tween()
		tw.tween_property(c, "scale", Vector2(amount, amount), 0.12).set_trans(Tween.TRANS_BACK).set_ease(Tween.EASE_OUT))
	c.focus_exited.connect(func():
		if not is_instance_valid(c):
			return
		var tw := c.create_tween()
		tw.tween_property(c, "scale", Vector2.ONE, 0.1))


# --- buttons -------------------------------------------------------------------------------------

## kind: "primary" (borderedProminent, accent fill), "bordered" (.bordered), "destructive"
## (bordered, red), "form" (a button row inside a Form), "plain" (no chrome), "pill" /
## "pill_default" (the modern NovaDialog footer capsules).
static func button(text: String, kind := "bordered", cb: Callable = Callable(), icon_name := "") -> Button:
	var b := Button.new()
	b.text = text
	b.focus_mode = Control.FOCUS_ALL
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var fg := T.WHITE
	var pad := Vector2(12, 5)
	var radius := 7
	var role := "button"
	var weight := "regular"
	var size := 14
	var nb: StyleBox
	var hb: StyleBox
	var pb: StyleBox
	match kind:
		"primary":
			fg = Color(0.05, 0.04, 0.02)
			nb = T.box(T.ACCENT, radius, Color(0, 0, 0, 0), 0, pad)
			hb = T.box(T.ACCENT.lightened(0.12), radius, Color(0, 0, 0, 0), 0, pad)
			pb = T.box(T.ACCENT.darkened(0.15), radius, Color(0, 0, 0, 0), 0, pad)
			weight = "medium"
		"destructive":
			fg = T.RED
			nb = T.box(T.BORDERED_BG, radius, Color(0, 0, 0, 0), 0, pad)
			hb = T.box(Color(1, 1, 1, 0.22), radius, Color(0, 0, 0, 0), 0, pad)
			pb = T.box(Color(1, 1, 1, 0.3), radius, Color(0, 0, 0, 0), 0, pad)
		"form":
			pad = Vector2(12, 5)
			size = 15
			radius = 6
			nb = T.box(Color(1, 1, 1, 0.10), radius, Color(1, 1, 1, 0.04), 1, pad)
			hb = T.box(Color(1, 1, 1, 0.18), radius, Color(1, 1, 1, 0.04), 1, pad)
			pb = T.box(Color(1, 1, 1, 0.26), radius, Color(1, 1, 1, 0.04), 1, pad)
		"plain":
			nb = T.empty()
			hb = T.empty()
			pb = T.empty()
			pad = Vector2(4, 2)
		"pill", "pill_default":
			size = 15
			pad = Vector2(18, 7)
			radius = 20
			if kind == "pill_default":
				fg = Color.BLACK
				nb = T.box(Color(0.93, 0.64, 0.25), radius, Color(1, 1, 1, 0.18), 1, pad)
				hb = T.box(Color(1.0, 0.72, 0.3), radius, Color(1, 1, 1, 0.18), 1, pad)
				pb = T.box(Color(0.8, 0.54, 0.2), radius, Color(1, 1, 1, 0.18), 1, pad)
			else:
				nb = T.box(Color(0.27, 0.27, 0.27), radius, Color(1, 1, 1, 0.18), 1, pad)
				hb = T.box(Color(0.34, 0.34, 0.34), radius, Color(1, 1, 1, 0.18), 1, pad)
				pb = T.box(Color(0.2, 0.2, 0.2), radius, Color(1, 1, 1, 0.18), 1, pad)
		_:
			nb = T.box(T.BORDERED_BG, radius, Color(0, 0, 0, 0), 0, pad)
			hb = T.box(Color(1, 1, 1, 0.22), radius, Color(0, 0, 0, 0), 0, pad)
			pb = T.box(Color(1, 1, 1, 0.3), radius, Color(0, 0, 0, 0), 0, pad)
	b.add_theme_stylebox_override("normal", nb)
	b.add_theme_stylebox_override("hover", hb)
	b.add_theme_stylebox_override("pressed", pb)
	b.add_theme_stylebox_override("hover_pressed", pb)
	b.add_theme_stylebox_override("disabled", T.box(Color(1, 1, 1, 0.05), radius, Color(0, 0, 0, 0), 0, pad) if kind != "plain" else T.empty())
	T.style_text(b, role, weight, fg, size)
	for st in ["font_hover_color", "font_pressed_color", "font_focus_color", "font_hover_pressed_color"]:
		b.add_theme_color_override(st, fg)
	b.add_theme_color_override("font_disabled_color", Color(fg.r, fg.g, fg.b, 0.4))
	if icon_name != "":
		b.icon = T.icon(icon_name, 16, fg)
		b.add_theme_constant_override("h_separation", 6)
		for st in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_focus_color", "icon_hover_pressed_color"]:
			b.add_theme_color_override(st, Color.WHITE)
	if cb.is_valid():
		b.pressed.connect(cb)
	grow_on_focus(b, 1.05)
	return b


## A small icon-only button (a 30 x 30 hit area): trash, duplicate, chevron, refresh, close.
static func icon_button(icon_name: String, cb: Callable, color := T.AMBER, size := 30, px := 16) -> Button:
	var b := Button.new()
	b.icon = T.icon(icon_name, px, color)
	b.expand_icon = false
	b.icon_alignment = HORIZONTAL_ALIGNMENT_CENTER
	b.custom_minimum_size = Vector2(size, size)
	b.focus_mode = Control.FOCUS_ALL
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var hover := T.box(Color(1, 1, 1, 0.10), 8)
	b.add_theme_stylebox_override("normal", T.empty())
	b.add_theme_stylebox_override("hover", hover)
	b.add_theme_stylebox_override("pressed", T.box(Color(1, 1, 1, 0.18), 8))
	b.add_theme_stylebox_override("disabled", T.empty())
	if cb.is_valid():
		b.pressed.connect(cb)
	grow_on_focus(b, 1.1)
	return b


static func bordered_icon_button(icon_name: String, cb: Callable, tooltip := "") -> Button:
	var b := button("", "bordered", cb)
	b.icon = T.icon(icon_name, 16, T.WHITE)
	b.tooltip_text = tooltip
	b.custom_minimum_size = Vector2(36, 30)
	return b


## A button row inside a Form (Apple `.novaFormButton()` + a Label with a symbol): left aligned,
## sized to its content, added as its own row.
static func form_button(group: Group, text: String, icon_name := "", cb: Callable = Callable()) -> Button:
	var b := button(text, "form", cb, icon_name)
	var hb := HBoxContainer.new()
	hb.add_child(b)
	group.add_row(hb)
	return b


# --- toggle / slider / pickers -------------------------------------------------------------------

## NovaToggleStyle: amber 16 px check box + `.body` label. Returns the CheckBox.
static func toggle(group: Variant, text: String, value: bool, cb: Callable = Callable()) -> CheckBox:
	var c := CheckBox.new()
	c.text = text
	c.button_pressed = value
	c.focus_mode = Control.FOCUS_ALL
	c.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	T.style_text(c, "body", "regular", T.WHITE)
	c.add_theme_color_override("font_hover_color", T.WHITE)
	c.add_theme_color_override("font_pressed_color", T.WHITE)
	c.add_theme_color_override("font_hover_pressed_color", T.WHITE)
	c.add_theme_constant_override("h_separation", 10)
	c.custom_minimum_size = Vector2(0, 32)
	c.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if cb.is_valid():
		c.toggled.connect(cb)
	if group is Group:
		group.add_row(c)
	elif group != null:
		group.add_child(c)
	return c


## Slider row: title left, value (secondary caption) right, the NovaSlider under them
## (SettingsView.sliderRow). Returns the HSlider (focusable; left / right step it).
static func slider(group: Variant, title: String, value: float, lo: float, hi: float, step: float,
		fmt: Callable, cb: Callable = Callable()) -> HSlider:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 4)
	var head := HBoxContainer.new()
	v.add_child(head)
	var t := label(head, title, "body")
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var val := label(head, "", "caption", "regular", T.SECONDARY)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = value
	s.custom_minimum_size = Vector2(0, 16)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.focus_mode = Control.FOCUS_ALL
	s.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	v.add_child(s)
	val.text = fmt.call(s.value)
	s.value_changed.connect(func(x: float):
		val.text = fmt.call(x)
		if cb.is_valid():
			cb.call(x))
	v.set_meta("value_label", val)
	v.set_meta("title_label", t)
	s.set_meta("row", v)
	if group is Group:
		group.add_row(v, 52.0)
	elif group != null:
		group.add_child(v)
	return s


## NovaSegmentedPicker: a row of equal segments, the selected one amber with black text. Returns
## the HBox; `.get_meta("buttons")` is the Button array. cb(index) on a change.
static func segmented(parent: Node, options: Array, selected: int, cb: Callable = Callable(), enabled := true) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 4)
	h.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var buttons: Array = []
	for i in options.size():
		var b := Button.new()
		b.text = str(options[i])
		b.toggle_mode = true
		b.button_pressed = i == selected
		b.disabled = not enabled
		b.focus_mode = Control.FOCUS_ALL
		b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
		var pad := Vector2(10, 6)
		b.add_theme_stylebox_override("normal", T.box(T.CHIP_BG, 5, Color(0, 0, 0, 0), 0, pad))
		b.add_theme_stylebox_override("hover", T.box(Color(0.2, 0.2, 0.2), 5, Color(0, 0, 0, 0), 0, pad))
		b.add_theme_stylebox_override("pressed", T.box(T.AMBER, 5, Color(0, 0, 0, 0), 0, pad))
		b.add_theme_stylebox_override("hover_pressed", T.box(T.AMBER.lightened(0.1), 5, Color(0, 0, 0, 0), 0, pad))
		b.add_theme_stylebox_override("disabled", T.box(Color(0.1, 0.1, 0.1), 5, Color(0, 0, 0, 0), 0, pad))
		T.style_text(b, "caption", "semibold", T.WHITE)
		b.add_theme_color_override("font_pressed_color", Color.BLACK)
		b.add_theme_color_override("font_hover_pressed_color", Color.BLACK)
		b.add_theme_color_override("font_focus_color", T.WHITE)
		b.add_theme_color_override("font_disabled_color", Color(1, 1, 1, 0.4))
		b.pressed.connect(func():
			for j in buttons.size():
				buttons[j].set_pressed_no_signal(j == i)
			if cb.is_valid():
				cb.call(i))
		grow_on_focus(b, 1.03)
		h.add_child(b)
		buttons.append(b)
	h.set_meta("buttons", buttons)
	if parent != null:
		if parent is Group:
			parent.add_row(h, 44.0)
		else:
			parent.add_child(h)
	return h


## Select option `i` of a segmented picker without firing its callback.
static func segmented_select(h: Control, i: int) -> void:
	var buttons: Array = h.get_meta("buttons")
	for j in buttons.size():
		buttons[j].set_pressed_no_signal(j == i)


## NovaMenuPicker row: title left, value chip (current value + up/down chevron) right that opens a
## popup list. cb(index) on a change. Returns the OptionButton.
static func menu(group: Variant, title: String, options: Array, selected: int, cb: Callable = Callable(),
		enabled := true) -> OptionButton:
	var h := HBoxContainer.new()
	var t := label(h, title, "body")
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var o := option_chip(options, selected, cb)
	o.disabled = not enabled
	h.add_child(o)
	h.set_meta("title_label", t)
	o.set_meta("row", h)
	if group is Group:
		group.add_row(h)
	elif group != null:
		group.add_child(h)
	return o


static func option_chip(options: Array, selected: int, cb: Callable = Callable()) -> OptionButton:
	var o := OptionButton.new()
	o.focus_mode = Control.FOCUS_ALL
	o.flat = false
	o.fit_to_longest_item = false
	for i in options.size():
		o.add_item(str(options[i]), i)
	o.select(clampi(selected, 0, maxi(0, options.size() - 1)))
	o.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	T.style_text(o, "body", "regular", T.WHITE)
	o.get_popup().add_theme_font_override("font", T.font("body"))
	o.get_popup().add_theme_font_size_override("font_size", 15)
	o.get_popup().add_theme_stylebox_override("panel", T.box(Color(0.11, 0.11, 0.11), 8, Color(1, 1, 1, 0.16), 1, Vector2(4, 4)))
	o.get_popup().add_theme_stylebox_override("hover", T.box(T.AMBER, 5))
	o.get_popup().add_theme_color_override("font_hover_color", Color.BLACK)
	o.get_popup().add_theme_color_override("font_color", T.WHITE)
	if cb.is_valid():
		o.item_selected.connect(cb)
	grow_on_focus(o, 1.04)
	return o


## A stepper (the tvOS NovaSlider −/+ style): − [value] +. cb(new_value).
static func stepper(parent: Node, value: int, lo: int, hi: int, cb: Callable) -> HBoxContainer:
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	var v := label(null, str(value), "body")
	v.custom_minimum_size = Vector2(32, 0)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	var state := [value]
	for d in [-1, 1]:
		var b := icon_button("minus" if d < 0 else "plus", func():
			state[0] = clampi(state[0] + d, lo, hi)
			v.text = str(state[0])
			cb.call(state[0]), T.AMBER, 30, 14)
		b.add_theme_stylebox_override("normal", T.box(Color(0.14, 0.14, 0.14), 5))
		b.custom_minimum_size = Vector2(30, 24)
		h.add_child(b)
		if d < 0:
			h.add_child(v)
	if parent != null:
		parent.add_child(h)
	return h


## "Saved to .......... iCloud": a title with a secondary value at the right.
static func value_row(group: Group, title: String, value: String) -> Label:
	var h := HBoxContainer.new()
	var t := label(h, title, "body")
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var v := label(h, value, "body", "regular", T.SECONDARY)
	v.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	group.add_row(h)
	return v


# --- text fields ---------------------------------------------------------------------------------

## NovaTextField: dark field, grey hairline, amber caret / border while editing.
static func text_field(placeholder := "", text := "", cb_submit: Callable = Callable()) -> LineEdit:
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.text = text
	e.custom_minimum_size = Vector2(0, 36)
	e.focus_mode = Control.FOCUS_ALL
	T.style_text(e, "body", "regular", T.WHITE)
	if cb_submit.is_valid():
		e.text_submitted.connect(cb_submit)
	return e


## The Plug-ins search field: magnifier, plain field, clear button, soft rounded fill.
static func search_field(parent: Node, placeholder: String, text: String, cb_changed: Callable,
		cb_submit: Callable = Callable()) -> LineEdit:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", T.box(T.FIELD_BG_SOFT, 12, Color(0, 0, 0, 0), 0, Vector2(10, 8)))
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 8)
	p.add_child(h)
	var mag := TextureRect.new()
	mag.texture = T.icon("magnifyingglass", 16, T.SECONDARY)
	mag.custom_minimum_size = Vector2(16, 16)
	mag.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	mag.mouse_filter = Control.MOUSE_FILTER_IGNORE
	h.add_child(mag)
	var e := LineEdit.new()
	e.placeholder_text = placeholder
	e.text = text
	e.flat = true
	e.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	e.add_theme_stylebox_override("normal", T.empty())
	e.add_theme_stylebox_override("focus", T.empty())
	T.style_text(e, "body", "regular", T.WHITE)
	e.add_theme_color_override("font_placeholder_color", T.SECONDARY)
	h.add_child(e)
	var clear := icon_button("xmark", func(): e.text = ""; cb_changed.call(""), T.SECONDARY, 22, 12)
	clear.visible = text != ""
	h.add_child(clear)
	e.text_changed.connect(func(t: String):
		clear.visible = t != ""
		cb_changed.call(t))
	if cb_submit.is_valid():
		e.text_submitted.connect(cb_submit)
	parent.add_child(p)
	e.set_meta("panel", p)
	return e


# --- rows & chips ----------------------------------------------------------------------------------

## NovaSelectRow: a full-width selectable row (sidebar category, scenario) — dark chip, amber when
## selected with black text and icon. Returns the toggle Button (pressed = selected).
static func select_row(parent: Node, text: String, icon_name := "", selected := false, cb: Callable = Callable()) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.button_pressed = selected
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.focus_mode = Control.FOCUS_ALL
	b.custom_minimum_size = Vector2(0, 30)
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var pad := Vector2(10, 6)
	b.add_theme_stylebox_override("normal", T.box(T.CHIP_BG, 5, Color(0, 0, 0, 0), 0, pad))
	b.add_theme_stylebox_override("hover", T.box(Color(0.2, 0.2, 0.2), 5, Color(0, 0, 0, 0), 0, pad))
	b.add_theme_stylebox_override("pressed", T.box(T.AMBER, 5, Color(0, 0, 0, 0), 0, pad))
	b.add_theme_stylebox_override("hover_pressed", T.box(T.AMBER, 5, Color(0, 0, 0, 0), 0, pad))
	T.style_text(b, "body", "semibold", T.WHITE, 13)
	b.add_theme_color_override("font_pressed_color", Color.BLACK)
	b.add_theme_color_override("font_hover_pressed_color", Color.BLACK)
	b.add_theme_constant_override("h_separation", 10)
	if icon_name != "":
		b.icon = T.icon(icon_name, 18, Color.WHITE)
		b.add_theme_color_override("icon_normal_color", Color.WHITE)
		b.add_theme_color_override("icon_hover_color", Color.WHITE)
		b.add_theme_color_override("icon_focus_color", Color.WHITE)
		b.add_theme_color_override("icon_pressed_color", Color.BLACK)
		b.add_theme_color_override("icon_hover_pressed_color", Color.BLACK)
	if cb.is_valid():
		b.pressed.connect(cb)
	grow_on_focus(b, 1.03)
	parent.add_child(b)
	return b


## A filter chip (PluginsView.filterChips): capsule, accent fill + white text when selected.
static func chip(parent: Node, text: String, selected: bool, cb: Callable) -> Button:
	var b := Button.new()
	b.text = text
	b.toggle_mode = true
	b.button_pressed = selected
	b.focus_mode = Control.FOCUS_ALL
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var pad := Vector2(14, 8)
	b.add_theme_stylebox_override("normal", T.box(Color(1, 1, 1, 0.10), 40, Color(0, 0, 0, 0), 0, pad))
	b.add_theme_stylebox_override("hover", T.box(Color(1, 1, 1, 0.16), 40, Color(0, 0, 0, 0), 0, pad))
	b.add_theme_stylebox_override("pressed", T.box(T.ACCENT, 40, Color(0, 0, 0, 0), 0, pad))
	b.add_theme_stylebox_override("hover_pressed", T.box(T.ACCENT, 40, Color(0, 0, 0, 0), 0, pad))
	T.style_text(b, "body", "medium", T.WHITE, 14)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	b.add_theme_color_override("font_hover_pressed_color", Color.WHITE)
	b.pressed.connect(cb)
	grow_on_focus(b, 1.05)
	parent.add_child(b)
	return b


## PluginBadge: tiny capsule, tinted text on a 16 % tint.
static func badge(parent: Node, text: String, color := T.SECONDARY, icon_name := "") -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", T.box(Color(color.r, color.g, color.b, 0.16), 20, Color(0, 0, 0, 0), 0, Vector2(7, 3)))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var h := HBoxContainer.new()
	h.add_theme_constant_override("separation", 4)
	p.add_child(h)
	if icon_name != "":
		var tr := TextureRect.new()
		tr.texture = T.icon(icon_name, 11, color)
		tr.custom_minimum_size = Vector2(11, 11)
		tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
		h.add_child(tr)
	var l := label(h, text, "caption", "semibold", color)
	l.add_theme_font_size_override("font_size", 11)
	l.add_theme_font_override("font", T.system("semibold"))
	parent.add_child(p)
	return p


## A rounded card (plug-in rows / cards, pilot rows): `.primary.opacity(0.07)` fill.
static func card(parent: Node, radius := 14, pad := 12, border := false) -> PanelContainer:
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", T.box(T.CARD_BG, radius, T.CARD_BORDER if border else Color(0, 0, 0, 0), 1 if border else 0, Vector2(pad, pad)))
	p.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	if parent != null:
		parent.add_child(p)
	return p


## A card that is itself a button (a roster row, a plug-in card): returns the Button, whose
## `content` meta is the MarginContainer to fill. The Button's normal / hover / focus boxes are
## the card chrome.
static func card_button(parent: Node, bg := T.CARD_BG, border := T.CARD_BORDER, radius := 18, pad := 16) -> Button:
	var b := Button.new()
	b.focus_mode = Control.FOCUS_ALL
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	b.toggle_mode = false
	b.action_mode = BaseButton.ACTION_MODE_BUTTON_RELEASE
	b.add_theme_stylebox_override("normal", T.box(bg, radius, border, 1))
	b.add_theme_stylebox_override("hover", T.box(Color(bg.r, bg.g, bg.b, minf(1.0, bg.a + 0.05)).lightened(0.05), radius, border, 1))
	b.add_theme_stylebox_override("pressed", T.box(Color(bg.r, bg.g, bg.b, minf(1.0, bg.a + 0.1)).lightened(0.1), radius, border, 1))
	b.add_theme_stylebox_override("disabled", T.box(bg, radius, border, 1))
	var m := MarginContainer.new()
	m.set_anchors_preset(Control.PRESET_FULL_RECT)
	for s in ["left", "right", "top", "bottom"]:
		m.add_theme_constant_override("margin_" + s, pad)
	m.mouse_filter = Control.MOUSE_FILTER_IGNORE
	b.add_child(m)
	b.set_meta("content", m)
	grow_on_focus(b, 1.015)
	if parent != null:
		parent.add_child(b)
	return b


## Make a Button the size of its card content (a Button does not size to children).
static func fit_card(b: Button) -> void:
	var m: Control = b.get_meta("content")
	var fit := func():
		if is_instance_valid(b) and is_instance_valid(m):
			b.custom_minimum_size.y = m.get_combined_minimum_size().y
	m.minimum_size_changed.connect(fit)
	fit.call_deferred()


## SwiftUI ProgressView: a thin amber bar (value 0..1), or an indeterminate shimmer when < 0.
static func progress(parent: Node, value: float, width := 60.0) -> ProgressBar:
	var p := ProgressBar.new()
	p.custom_minimum_size = Vector2(width, 6)
	p.show_percentage = false
	p.min_value = 0.0
	p.max_value = 1.0
	p.value = maxf(0.0, value)
	p.add_theme_stylebox_override("background", T.box(Color(1, 1, 1, 0.12), 3))
	p.add_theme_stylebox_override("fill", T.box(T.AMBER, 3))
	p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	parent.add_child(p)
	return p


## An icon TextureRect (e.g. the plug-in kind symbol).
static func icon_rect(parent: Node, icon_name: String, px := 16, color := T.WHITE) -> TextureRect:
	var tr := TextureRect.new()
	tr.texture = T.icon(icon_name, px, color)
	tr.custom_minimum_size = Vector2(px, px)
	tr.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if parent != null:
		parent.add_child(tr)
	return tr


## Pad glyph hint (PadGlyph.swift): the connected pad's button name for a Controls action in a small
## rounded chip, or nothing when no pad is connected.
static func pad_glyph(parent: Node, action: String, tint := T.AMBER) -> Control:
	if Input.get_connected_joypads().is_empty():
		return null
	var Controls_ = load("res://Controls.gd")
	var name: String = Controls_.describe_buttons(action)
	if name == "" or name == "-" or name == "none":
		return null
	var p := PanelContainer.new()
	p.add_theme_stylebox_override("panel", T.box(Color(1, 1, 1, 0.10), 5, Color(0, 0, 0, 0), 0, Vector2(5, 2)))
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	label(p, name, "caption", "bold", tint).add_theme_font_size_override("font_size", 12)
	if parent != null:
		parent.add_child(p)
	return p
