# NOVA Swift — NovaSwift UI kit: dialog chrome, mirroring the Apple app's NovaDialog.swift
# (NovaDialog, DialogChrome, NovaPanelBackground, ModernDialogPanel).
#
# Three looks, exactly as NovaPanelBackground picks them:
#   "modern"   Settings > "Modern dialog chrome" on: a steel-bordered space-blue "screen" with a top
#              glow and a faint wave sheen (ModernDialogPanel)
#   "classic"  the default with game data: the original dësc dialog frame, PICT 8524 (9 px top cap)
#              / 8525 (stretching middle) / 8526 (40 px grey control strip), with the original
#              three-state button art in the strip (ui/classic/ClassicButton)
#   "plain"    no data imported: a dark rounded card, capsule buttons
#
#   var d := Chrome.dialog(host, {"title": "Select a Pilot", "width": 480,
#       "buttons": [{"text": "New Pilot", "default": true, "cb": ...}, {"text": "Close", "cancel": true, "cb": ...}]})
#   NC.label(d.body, "...")           # d.body is the content VBox; d.root the scrim Control to free
#
#   var c := Chrome.card_frame(host, "Settings", 660, 620, func(): close())   # DialogChrome
#   c.body is the content slot (fill it), c.done the Done button
#
# Both add a scrim (Color(0,0,0,0.55)) that swallows clicks, centre the panel, route Esc / pad B to
# the cancel (or Done) action and Return / Enter to the default button.
#
# Loaded with preload() (no class_name), like Controls.gd.
extends RefCounted

const T = preload("res://ui/novaswift/NovaTheme.gd")
const NC = preload("res://ui/novaswift/NovaControls.gd")
const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")
const ClassicButton = preload("res://ui/classic/ClassicButton.gd")
const Prefs = preload("res://Prefs.gd")


## "modern" | "classic" | "plain" (NovaPanelBackground's choice).
static func mode() -> String:
	if bool(Prefs.get_value("presentation", "modern_dialogs")):
		return "modern"
	if ClassicTheme.has_data() and ClassicTheme.pict(8524) != null and ClassicTheme.pict(8526) != null:
		return "classic"
	return "plain"


## Fill `panel` (a Control with a size) with the dialog frame as its first children. Returns the
## strip height reserved at the bottom for the footer (40 for the classic art).
static func add_frame(panel: Control, m: String = "") -> void:
	if m == "":
		m = mode()
	match m:
		"classic":
			var top: Texture2D = ClassicTheme.pict(8524) if ClassicTheme.pict(8524) != null else ClassicTheme.pict(8521)
			var mid: Texture2D = ClassicTheme.pict(8525) if ClassicTheme.pict(8525) != null else ClassicTheme.pict(8522)
			var bot: Texture2D = ClassicTheme.pict(8526) if ClassicTheme.pict(8526) != null else ClassicTheme.pict(8523)
			var v := VBoxContainer.new()
			v.add_theme_constant_override("separation", 0)
			v.set_anchors_preset(Control.PRESET_FULL_RECT)
			v.mouse_filter = Control.MOUSE_FILTER_IGNORE
			panel.add_child(v)
			panel.move_child(v, 0)
			for spec in [[top, 9, false], [mid, 0, true], [bot, 40, false]]:
				var tr := TextureRect.new()
				tr.texture = spec[0]
				tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
				tr.stretch_mode = TextureRect.STRETCH_SCALE
				tr.texture_filter = CanvasItem.TEXTURE_FILTER_LINEAR
				tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
				if spec[2]:
					tr.size_flags_vertical = Control.SIZE_EXPAND_FILL
				else:
					tr.custom_minimum_size = Vector2(0, spec[1])
				v.add_child(tr)
		"modern":
			var p := Panel.new()
			p.set_anchors_preset(Control.PRESET_FULL_RECT)
			p.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var sb := StyleBoxFlat.new()
			sb.bg_color = Color(0.04, 0.085, 0.195)
			sb.set_corner_radius_all(16)
			sb.set_border_width_all(4)
			sb.border_color = Color(0.58, 0.58, 0.6)
			sb.shadow_color = Color(0, 0, 0, 0.6)
			sb.shadow_size = 20
			sb.shadow_offset = Vector2(0, 10)
			sb.anti_aliasing = true
			p.add_theme_stylebox_override("panel", sb)
			p.clip_children = CanvasItem.CLIP_CHILDREN_AND_DRAW
			panel.add_child(p)
			panel.move_child(p, 0)
			# vertical blue gradient + the top glow, clipped to the rounded shape
			var g := Gradient.new()
			g.set_color(0, Color(0.03, 0.06, 0.15))
			g.set_color(1, Color(0.05, 0.11, 0.24))
			var gt := GradientTexture2D.new()
			gt.gradient = g
			gt.fill_from = Vector2(0.5, 0)
			gt.fill_to = Vector2(0.5, 1)
			gt.width = 8
			gt.height = 64
			var tr := TextureRect.new()
			tr.texture = gt
			tr.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			tr.stretch_mode = TextureRect.STRETCH_SCALE
			tr.set_anchors_preset(Control.PRESET_FULL_RECT)
			tr.mouse_filter = Control.MOUSE_FILTER_IGNORE
			p.add_child(tr)
			var rg := Gradient.new()
			rg.set_color(0, Color(0.15, 0.35, 0.6, 0.35))
			rg.set_color(1, Color(0.15, 0.35, 0.6, 0.0))
			var rt := GradientTexture2D.new()
			rt.gradient = rg
			rt.fill = GradientTexture2D.FILL_RADIAL
			rt.fill_from = Vector2(0.5, 0.0)
			rt.fill_to = Vector2(1.0, 0.0)
			rt.width = 128
			rt.height = 64
			var glow := TextureRect.new()
			glow.texture = rt
			glow.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
			glow.stretch_mode = TextureRect.STRETCH_SCALE
			glow.set_anchors_preset(Control.PRESET_FULL_RECT)
			glow.anchor_bottom = 0.6
			glow.mouse_filter = Control.MOUSE_FILTER_IGNORE
			p.add_child(glow)
		_:
			var p2 := Panel.new()
			p2.set_anchors_preset(Control.PRESET_FULL_RECT)
			p2.mouse_filter = Control.MOUSE_FILTER_IGNORE
			p2.add_theme_stylebox_override("panel", T.box(Color(0.10, 0.10, 0.10), 8, Color(1, 1, 1, 0.2), 1))
			panel.add_child(p2)
			panel.move_child(p2, 0)


## A footer button for the chrome mode: the original button art in "classic", capsules otherwise.
## spec: {text, default, cancel, destructive, enabled, cb}
static func footer_button(spec: Dictionary, m: String) -> Control:
	var text: String = spec.get("text", "")
	var enabled: bool = spec.get("enabled", true)
	var b: BaseButton
	if m == "classic":
		var cb_ := ClassicButton.make(text, maxi(50, text.length() * 8 + 12))
		cb_.disabled = not enabled
		b = cb_
	else:
		var kind := "pill_default" if spec.get("default", false) else "pill"
		var nb := NC.button(text, kind)
		nb.disabled = not enabled
		if spec.get("destructive", false) and not spec.get("default", false):
			nb.add_theme_color_override("font_color", T.RED)
		b = nb
	var cb: Callable = spec.get("cb", Callable())
	if cb.is_valid():
		b.pressed.connect(cb)
	b.set_meta("spec", spec)
	return b


## A scrim + centred panel with a title, a content body and a footer strip of buttons.
## Returns {root, panel, body, buttons: {text: Control}, mode}. `host` is any CanvasLayer / Control.
static func dialog(host: Node, opts: Dictionary) -> Dictionary:
	var m := mode()
	var width: float = opts.get("width", 460.0)
	var title: String = opts.get("title", "")
	var specs: Array = opts.get("buttons", [])
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.theme = T.theme()
	host.add_child(root)
	var scrim := ColorRect.new()
	scrim.color = T.SCRIM
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(scrim)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	center.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(center)
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(width, 0)
	panel.add_theme_stylebox_override("panel", T.empty())
	center.add_child(panel)
	add_frame(panel, m)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	panel.add_child(v)
	var inner := MarginContainer.new()
	inner.add_theme_constant_override("margin_left", 22)
	inner.add_theme_constant_override("margin_right", 22)
	inner.add_theme_constant_override("margin_top", 18 + (9 if m == "classic" else 0))
	inner.add_theme_constant_override("margin_bottom", 16)
	v.add_child(inner)
	var body := VBoxContainer.new()
	body.add_theme_constant_override("separation", 14)
	inner.add_child(body)
	if title != "":
		var t := NC.label(body, title, "heading", "bold", T.AMBER)
		t.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var strip := HBoxContainer.new()
	strip.add_theme_constant_override("separation", 10)
	strip.custom_minimum_size = Vector2(0, 40)
	strip.alignment = BoxContainer.ALIGNMENT_END
	var sm := MarginContainer.new()
	sm.add_theme_constant_override("margin_left", 16)
	sm.add_theme_constant_override("margin_right", 16)
	sm.add_theme_constant_override("margin_bottom", 4 if m != "classic" else 0)
	sm.add_child(strip)
	v.add_child(sm)
	var buttons := {}
	var default_btn: Control = null
	var cancel_cb := Callable()
	for spec in specs:
		var b := footer_button(spec, m)
		strip.add_child(b)
		b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
		buttons[spec.get("text", "")] = b
		if spec.get("default", false):
			default_btn = b
		if spec.get("cancel", false):
			cancel_cb = spec.get("cb", Callable())
	var out := {"root": root, "panel": panel, "body": body, "buttons": buttons, "mode": m,
		"default": default_btn, "strip": strip}
	# Esc / pad B -> cancel, Return -> default (NovaDialog.novaDialogKeys)
	var keys := DialogKeys.new()
	keys.default_btn = default_btn
	keys.cancel_cb = cancel_cb
	root.add_child(keys)
	if default_btn != null:
		T_focus(default_btn)
	elif not buttons.is_empty():
		T_focus(buttons.values()[0])
	return out


## Return / Esc routing for a dialog (kept as a node so it dies with the dialog).
class DialogKeys extends Node:
	var default_btn: Control
	var cancel_cb := Callable()

	func _unhandled_input(event: InputEvent) -> void:
		if not is_inside_tree():
			return
		if event.is_action_pressed("ui_cancel") and cancel_cb.is_valid():
			get_viewport().set_input_as_handled()
			cancel_cb.call()
		elif event is InputEventKey and event.pressed and not event.echo \
				and (event.keycode == KEY_ENTER or event.keycode == KEY_KP_ENTER) \
				and default_btn != null and is_instance_valid(default_btn) and not (default_btn as BaseButton).disabled:
			get_viewport().set_input_as_handled()
			(default_btn as BaseButton).pressed.emit()


static func T_focus(c: Control) -> void:
	(func(): if is_instance_valid(c) and c.is_inside_tree(): c.grab_focus()).call_deferred()


## DialogChrome: a fixed-size (design_w x design_h) centred card — amber title, a content slot that
## fills the card, and a Done strip — scaled down uniformly to fit the viewport (never up). Returns
## {root, card, body, done, scale, mode}; `body` is the slot to fill, `done` the Done button.
static func card_frame(host: Node, title: String, design_w: float, design_h: float, on_close: Callable) -> Dictionary:
	var m := mode()
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.theme = T.theme()
	host.add_child(root)
	var scrim := ColorRect.new()
	scrim.color = T.SCRIM
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	root.add_child(scrim)
	var card := Control.new()
	card.custom_minimum_size = Vector2(design_w, design_h)
	card.size = Vector2(design_w, design_h)
	card.mouse_filter = Control.MOUSE_FILTER_IGNORE
	root.add_child(card)
	add_frame(card, m)
	var v := VBoxContainer.new()
	v.set_anchors_preset(Control.PRESET_FULL_RECT)
	v.add_theme_constant_override("separation", 0)
	card.add_child(v)
	var head := MarginContainer.new()
	head.add_theme_constant_override("margin_left", 22)
	head.add_theme_constant_override("margin_right", 22)
	head.add_theme_constant_override("margin_top", 16 + (9 if m == "classic" else 0))
	head.add_theme_constant_override("margin_bottom", 10)
	v.add_child(head)
	NC.label(head, title, "heading", "bold", T.AMBER)
	var body := Control.new()
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body.clip_contents = true
	v.add_child(body)
	var strip := HBoxContainer.new()
	strip.alignment = BoxContainer.ALIGNMENT_END
	strip.custom_minimum_size = Vector2(0, 44)
	var sm := MarginContainer.new()
	sm.add_theme_constant_override("margin_left", 16)
	sm.add_theme_constant_override("margin_right", 16)
	sm.add_child(strip)
	v.add_child(sm)
	var done: Control
	if m == "classic":
		var cb_ := ClassicButton.make("Done", 60)
		cb_.pressed.connect(on_close)
		done = cb_
	else:
		var nb := NC.button("Done", "primary", on_close)
		nb.add_theme_stylebox_override("normal", T.box(T.ACCENT, 20, Color(0, 0, 0, 0), 0, Vector2(22, 7)))
		nb.add_theme_stylebox_override("hover", T.box(T.ACCENT.lightened(0.12), 20, Color(0, 0, 0, 0), 0, Vector2(22, 7)))
		nb.add_theme_stylebox_override("pressed", T.box(T.ACCENT.darkened(0.15), 20, Color(0, 0, 0, 0), 0, Vector2(22, 7)))
		T.style_text(nb, "button", "semibold", Color.BLACK, 15)
		done = nb
	done.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	strip.add_child(done)
	var out := {"root": root, "card": card, "body": body, "done": done, "scale": 1.0, "mode": m,
		"design": Vector2(design_w, design_h)}
	var fit := func():
		var vp := root.get_viewport_rect().size
		var k := minf(1.0, minf(maxf(1.0, vp.x - 28.0) / design_w, maxf(1.0, vp.y - 28.0) / design_h))
		card.scale = Vector2(k, k)
		card.pivot_offset = Vector2.ZERO
		card.position = (vp - Vector2(design_w, design_h) * k) * 0.5
		out["scale"] = k
	root.resized.connect(fit)
	root.tree_entered.connect(func(): fit.call_deferred())
	fit.call_deferred()
	return out
