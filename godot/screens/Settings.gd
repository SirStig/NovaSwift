# NOVA Swift — Settings screen (Audio · Video · Controls), persisted by Prefs.gd.
#
# Opened from the main menu and the in-flight pause menu. Everything is reachable
# by Godot focus navigation alone (arrows / d-pad / left stick move, Enter / A
# activate, left/right adjust a focused slider, Esc / B go back), with the
# thick focus ring from ShellUI's theme.
#
# Controls page: every rebindable action from Controls.BINDINGS with its key and
# its pad button. Activate either to rebind: the next key (or pad button) pressed
# is captured, Esc cancels (a pad press that is not wanted just times out after
# 6 s). A binding already held by another action in the same group (Flight /
# Docked / Galaxy map) is swapped onto it, as PadBindings.bind does in the Apple
# app. Sticks, triggers and the analog axes are fixed. "Defaults" restores the
# page; everything is re-applied immediately (Controls.register()) and written to
# user://settings.cfg when the screen closes.
#
# Game speed is not here: the bridge doesn't expose GameSpeedRules yet.
extends CanvasLayer

const ShellUI = preload("res://screens/ShellUI.gd")
const Controls = preload("res://Controls.gd")
const Prefs = preload("res://Prefs.gd")

## Audio/video/deadzone changed (Main re-applies volumes to GameAudio + music).
signal changed
signal closed

const CAPTURE_TIMEOUT := 6.0
const PAGES := ["Audio", "Video", "Presentation", "Controls"]

var page := "Audio"
var tab_buttons := {}          # page name -> Button
var sliders := {}              # "section.key" -> HSlider
var rebind_buttons := {}       # action -> {"key": Button, "pad": Button}
var first_control: Control

var _nova: Object
var _root: Control
var _content: VBoxContainer
var _status: Label
var _capture := {}             # {action, field, button} while waiting for an input
var _capture_serial := 0
var _dirty := false


func setup(nova: Object, start_page := "Audio") -> void:
	_nova = nova
	layer = 70
	_root = ShellUI.screen(self, 0.96)
	var box := ShellUI.panel(_root, 780, 8)
	ShellUI.title(box, "Settings", 28)

	var tabs := HBoxContainer.new()
	tabs.add_theme_constant_override("separation", 8)
	box.add_child(tabs)
	for p in PAGES:
		var b := Button.new()
		b.text = p
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(150, 38)
		b.pressed.connect(show_page.bind(p))
		tabs.add_child(b)
		tab_buttons[p] = b

	_content = VBoxContainer.new()
	_content.add_theme_constant_override("separation", 6)
	box.add_child(_content)

	_status = ShellUI.label(box, "", 14, Color(1.0, 0.75, 0.4))
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 8)
	box.add_child(foot)
	var defaults := Button.new()
	defaults.text = "Defaults"
	defaults.custom_minimum_size = Vector2(160, 40)
	defaults.pressed.connect(_reset_page)
	foot.add_child(defaults)
	var back := Button.new()
	back.text = "Back"
	back.custom_minimum_size = Vector2(160, 40)
	back.pressed.connect(close)
	foot.add_child(back)
	show_page(start_page)


func _exit_tree() -> void:
	if _dirty:
		Prefs.save()
		_dirty = false


func close() -> void:
	_cancel_capture()
	if _dirty:
		Prefs.save()
		_dirty = false
	closed.emit()
	queue_free()


func _mark_changed() -> void:
	_dirty = true
	changed.emit()


# --- pages ---------------------------------------------------------------------

func show_page(p: String) -> void:
	_cancel_capture()
	page = p
	for tab in tab_buttons:
		tab_buttons[tab].button_pressed = tab == p
	for c in _content.get_children():
		_content.remove_child(c)
		c.queue_free()
	sliders.clear()
	rebind_buttons.clear()
	_status.text = ""
	first_control = null
	match p:
		"Audio": _build_audio()
		"Video": _build_video()
		"Presentation": _build_presentation()
		"Controls": _build_controls()
	# Land focus on the tab, so left/right flips pages and down enters the page.
	ShellUI.focus(tab_buttons[p])


func _row(label: String) -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 12)
	var l := Label.new()
	l.text = label
	l.custom_minimum_size = Vector2(230, 0)
	l.add_theme_font_size_override("font_size", 16)
	r.add_child(l)
	_content.add_child(r)
	return r


## A labelled slider bound to Prefs[section][key].
func _slider(label: String, section: String, key: String, lo: float, hi: float, step: float,
		fmt: Callable) -> HSlider:
	var r := _row(label)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = float(Prefs.get_value(section, key))
	s.custom_minimum_size = Vector2(320, 30)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	s.focus_mode = Control.FOCUS_ALL
	r.add_child(s)
	var v := Label.new()
	v.custom_minimum_size = Vector2(70, 0)
	v.text = fmt.call(s.value)
	r.add_child(v)
	s.value_changed.connect(func(x: float):
		v.text = fmt.call(x)
		Prefs.set_value(section, key, x)
		_after_change(section))
	sliders[section + "." + key] = s
	if first_control == null:
		first_control = s
	return s


func _check(label: String, section: String, key: String) -> CheckButton:
	var c := CheckButton.new()
	c.text = label
	c.button_pressed = bool(Prefs.get_value(section, key))
	c.custom_minimum_size = Vector2(0, 38)
	c.toggled.connect(func(on: bool):
		Prefs.set_value(section, key, on)
		_after_change(section))
	_content.add_child(c)
	if first_control == null:
		first_control = c
	return c


func _after_change(section: String) -> void:
	if section == "video":
		Prefs.apply_video()
	elif section == "input":
		Controls.register()
	_mark_changed()


func _pct(x: float) -> String:
	return "%d%%" % roundi(x * 100.0)


func _build_audio() -> void:
	_slider("Master volume", "audio", "master", 0.0, 1.0, 0.05, _pct)
	_slider("Effects volume", "audio", "sfx", 0.0, 1.0, 0.05, _pct)
	_slider("Interface volume", "audio", "ui", 0.0, 1.0, 0.05, _pct)
	_slider("Music volume", "audio", "music", 0.0, 1.0, 0.05, _pct)
	_check("Mute all sound", "audio", "muted")
	ShellUI.label(_content, "Music plays over the main menu only, as in the original (if your data has the track as an mp3).", 13)


func _build_video() -> void:
	_check("Fullscreen", "video", "fullscreen")
	_check("VSync", "video", "vsync")
	_slider("Window scale", "video", "scale", 0.75, 2.0, 0.25,
		func(x: float): return "%dx%d" % [roundi(1280 * x), roundi(720 * x)])
	_check("Gate links on the galaxy map (enhancement)", "map", "gate_links")
	ShellUI.label(_content, "Window scale applies when not fullscreen. The play area adapts to 16:9 and 16:10 (Steam Deck) screens.", 13)


## Presentation: Classic (the original's status bar / dialogs / menu, drawn from the
## player's own data -- the default) or Nova Swift (the port's own screens), as in
## the Apple app's GameSettings presets; the three toggles below mix them. Reads
## Prefs[presentation]; screens pick the change up the next time they open (the
## HUD immediately).
func _build_presentation() -> void:
	var modes := HBoxContainer.new()
	modes.add_theme_constant_override("separation", 8)
	_content.add_child(modes)
	var mode_buttons := {}
	for m in [[Prefs.UI_CLASSIC, "Classic"], [Prefs.UI_NOVA_SWIFT, "Nova Swift"]]:
		var b := Button.new()
		b.text = m[1]
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(190, 40)
		b.button_pressed = Prefs.ui_mode() == m[0]
		b.pressed.connect(func():
			Prefs.apply_ui_mode(m[0])
			_mark_changed()
			show_page.call_deferred("Presentation"))
		modes.add_child(b)
		mode_buttons[m[0]] = b
	if first_control == null:
		first_control = mode_buttons[Prefs.UI_CLASSIC]
	ShellUI.label(_content, "Classic draws the original interface from your game data (status bar, dialogs, menu). Nova Swift uses the port's own modern screens.", 13)
	for t in [["Modern main menu", "modern_menu"], ["Modern dialogs", "modern_dialogs"], ["Modern HUD (status bar)", "modern_hud"]]:
		var c := _check(t[0], "presentation", t[1])
		c.toggled.connect(func(_on: bool): show_page.call_deferred("Presentation"))
	var mode_name := {Prefs.UI_CLASSIC: "Classic", Prefs.UI_NOVA_SWIFT: "Nova Swift", Prefs.UI_CUSTOM: "Custom"}
	ShellUI.label(_content, "Current: " + str(mode_name[Prefs.ui_mode()]), 14, ShellUI.ACCENT)


func _build_controls() -> void:
	_slider("Stick dead zone", "input", "deadzone", 0.0, 0.5, 0.01, _pct)
	var modern := _check("Modern key layout (the port's earlier keys)", "input", "modern_keys")
	modern.toggled.connect(func(_on: bool): show_page.call_deferred("Controls"))
	ShellUI.label(_content, "Off = the original's keys (arrows, Space, Ctrl, Z; W/Alt-W, R, N, E…). Activate a key or pad button to rebind it (Esc cancels). Sticks and triggers are fixed.", 13)
	var scroll := ScrollContainer.new()
	scroll.custom_minimum_size = Vector2(0, 290)
	scroll.follow_focus = true
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	_content.add_child(scroll)
	var list := VBoxContainer.new()
	list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list.add_theme_constant_override("separation", 4)
	scroll.add_child(list)
	for group in Controls.GROUPS:
		var h := Label.new()
		h.text = group
		h.add_theme_font_size_override("font_size", 17)
		h.add_theme_color_override("font_color", ShellUI.ACCENT)
		list.add_child(h)
		for action in Controls.GROUPS[group]:
			_rebind_row(list, action)


func _rebind_row(list: Control, action: String) -> void:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 8)
	var l := Label.new()
	l.text = Controls.ACTION_LABELS.get(action, action)
	l.custom_minimum_size = Vector2(250, 0)
	r.add_child(l)
	var kb := Button.new()
	kb.custom_minimum_size = Vector2(230, 34)
	kb.pressed.connect(_begin_capture.bind(action, _key_field(action), kb))
	r.add_child(kb)
	var pb := Button.new()
	pb.custom_minimum_size = Vector2(230, 34)
	pb.pressed.connect(_begin_capture.bind(action, "buttons", pb))
	r.add_child(pb)
	list.add_child(r)
	rebind_buttons[action] = {"key": kb, "pad": pb}
	_refresh_row(action)


static func _key_field(action: String) -> String:
	# Which key field this row edits: the one the action is bound through right now
	# (so the layout switch, which moves some actions between plain and chord keys,
	# edits the field the player sees), else the one it is declared with.
	var spec: Dictionary = Controls.effective(action)
	for f in ["keys", "shift_keys", "alt_keys"]:
		if not (spec.get(f, []) as Array).is_empty():
			return f
	var base: Dictionary = Controls.BINDINGS[action]
	if base.has("keys"):
		return "keys"
	return "shift_keys" if base.has("shift_keys") else ("alt_keys" if base.has("alt_keys") else "keys")


func _refresh_row(action: String) -> void:
	var row: Dictionary = rebind_buttons.get(action, {})
	if row.is_empty():
		return
	row.key.text = "Key: " + Controls.describe_keys(action)
	row.pad.text = "Pad: " + Controls.describe_buttons(action)


func _refresh_all_rows() -> void:
	for action in rebind_buttons:
		_refresh_row(action)


# --- rebinding -----------------------------------------------------------------

func _begin_capture(action: String, field: String, button: Button) -> void:
	_cancel_capture()
	_capture = {"action": action, "field": field, "button": button}
	_capture_serial += 1
	button.text = "Press a key…" if field != "buttons" else "Press a pad button…"
	_status.text = "Waiting for input — Esc cancels."
	var serial := _capture_serial
	get_tree().create_timer(CAPTURE_TIMEOUT).timeout.connect(func():
		if _capture_serial == serial and not _capture.is_empty():
			_cancel_capture())


func _cancel_capture() -> void:
	if _capture.is_empty():
		return
	var action: String = _capture.action
	_capture = {}
	_status.text = ""
	_refresh_row(action)


## Feed an event to the capture. Public so a test can drive it (parse_input_event
## is not delivered headless). Returns true if the event was consumed.
func capture_event(event: InputEvent) -> bool:
	if _capture.is_empty():
		return false
	var field: String = _capture.field
	var code := -1
	if field == "buttons":
		if event is InputEventKey and event.pressed and event.physical_keycode == KEY_ESCAPE:
			_cancel_capture()
			return true
		if event is InputEventJoypadButton and event.pressed:
			code = event.button_index
	elif event is InputEventKey and event.pressed and not event.echo:
		if event.physical_keycode == KEY_ESCAPE:
			_cancel_capture()
			return true
		code = event.physical_keycode
	if code < 0:
		return false
	_apply_rebind(_capture.action, field, code)
	return true


func _apply_rebind(action: String, field: String, code: int) -> void:
	_capture = {}
	var swapped := Controls.rebind(action, field, code)
	Controls.register()
	_dirty = true
	_refresh_all_rows()
	if swapped != "":
		_status.text = "Swapped with \"%s\"." % Controls.ACTION_LABELS.get(swapped, swapped)
	else:
		_status.text = ""
	changed.emit()


func _input(event: InputEvent) -> void:
	if not _capture.is_empty() and (event is InputEventKey or event is InputEventJoypadButton):
		if capture_event(event):
			get_viewport().set_input_as_handled()
		elif event is InputEventKey or event is InputEventJoypadButton:
			# Anything else pressed while waiting is swallowed so it can't also
			# navigate or activate the focused button.
			if event.is_pressed():
				get_viewport().set_input_as_handled()


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel"):
		get_viewport().set_input_as_handled()
		close()


func _reset_page() -> void:
	match page:
		"Audio": Prefs.reset_section("audio")
		"Video":
			Prefs.reset_section("video")
			Prefs.reset_section("map")
			Prefs.apply_video()
		"Controls":
			Prefs.reset_section("input")
			Prefs.reset_bindings()
			Controls.register()
	_dirty = true
	changed.emit()
	show_page(page)
