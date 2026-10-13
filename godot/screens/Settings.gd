# NOVA Swift — Settings screen, laid out like the Apple app's SettingsView: a card titled in amber,
# a category sidebar on the left (with a pinned "Reset All Settings"), and the selected category's
# grouped sections on the right -- amber section headers over dark rounded groups, toggles as amber
# check boxes, "title ........ 70%" slider rows, footers in muted caption text. Persisted by Prefs.gd.
#
#   Interface (page "Presentation")   presentation preset + Original Preferences Window, interface
#                                     options, storyline tags
#   Controls                          dead zone, key layout, every rebindable action
#   Graphics (page "Video")           fullscreen, vsync, window scale, gate links
#   Audio                             mute + master / effects / interface / music
#   Data & Advanced (page "Support")  Saved Games (Pilots folder), Support, Developer
#
# Opened from the main menu and the in-flight pause menu. Everything is reachable by Godot focus
# navigation alone (arrows / d-pad / left stick move, Enter / A activate, left/right adjust a
# focused slider, Esc / B go back), with the thick focus ring from ShellUI's theme. Moving focus
# onto a sidebar entry shows its page; Right (or Down from the last entry) enters the page, Up from
# its first control returns to the sidebar.
#
# The original Preferences window (DLOG 4003, screens/ClassicPreferences.gd) opens only from a
# button on the Interface page -- it never replaces this screen.
#
# Controls page: every rebindable action from Controls.BINDINGS with its key and its pad button.
# Activate either to rebind: the next key (or pad button) pressed is captured, Esc cancels (a pad
# press that is not wanted just times out after 6 s). A binding already held by another action in
# the same group (Flight / Docked / Galaxy map) is swapped onto it, as PadBindings.bind does in the
# Apple app. Sticks, triggers and the analog axes are fixed. "Defaults" restores the page;
# everything is re-applied immediately (Controls.register()) and written to user://settings.cfg
# when the screen closes.
#
# Game speed is not here: the bridge doesn't expose GameSpeedRules yet.
extends CanvasLayer

const ShellUI = preload("res://screens/ShellUI.gd")
const Controls = preload("res://Controls.gd")
const Prefs = preload("res://Prefs.gd")
const PilotFiles = preload("res://screens/PilotFiles.gd")
const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")
const ClassicPreferences = preload("res://screens/ClassicPreferences.gd")

## Audio/video/deadzone changed (Main re-applies volumes to GameAudio + music).
signal changed
signal closed
## "Flight Training" (Apple Settings > Gameplay): the host closes Settings and runs the course.
signal training_requested

const CAPTURE_TIMEOUT := 6.0
const DevSettingsPage = preload("res://debug/DevSettingsPage.gd")
const PluginsScreen = preload("res://screens/Plugins.gd")
## Page keys in sidebar order (Apple SettingsView category order), and what the sidebar calls them.
const PAGES := ["Presentation", "Controls", "Video", "Audio", "Plugins", "Support"]
const PAGE_TITLES := {"Presentation": "Interface", "Controls": "Controls", "Video": "Graphics",
	"Audio": "Audio", "Plugins": "Plug-ins", "Support": "Data & Advanced"}
const AMBER := Color(1.0, 0.7, 0.28)         # novaAmber
const GROUP_BG := Color(0.085, 0.09, 0.115)

var page := "Presentation"
var tab_buttons := {}          # page name -> Button (the sidebar entries)
var sliders := {}              # "section.key" -> HSlider
var rebind_buttons := {}       # action -> {"key": Button, "pad": Button}
var first_control: Control
## Set by the host before setup(): Settings was opened from the main menu, so Flight Training can run.
var allow_training := false
var classic_prefs: Node        # the original Preferences window while it is up

var _nova: Object
var _root: Control
var _content: VBoxContainer
var _group: VBoxContainer      # the section group rows are added to
var _status: Label
var _scroll: ScrollContainer
var _reset_all_btn: Button
var _reset_armed := false
var _capture := {}             # {action, field, button} while waiting for an input
var _capture_serial := 0
var _dirty := false


func setup(nova: Object, start_page := "Presentation") -> void:
	_nova = nova
	layer = 70
	_root = ShellUI.screen(self, 0.96)
	var center := CenterContainer.new()
	center.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.add_child(center)
	var card := PanelContainer.new()
	card.custom_minimum_size = Vector2(900, 600)
	var cs := StyleBoxFlat.new()
	cs.bg_color = ShellUI.PANEL
	cs.border_color = Color(AMBER.r, AMBER.g, AMBER.b, 0.35)
	cs.set_border_width_all(2)
	cs.set_corner_radius_all(6)
	cs.set_content_margin_all(16)
	card.add_theme_stylebox_override("panel", cs)
	center.add_child(card)
	var outer := VBoxContainer.new()
	outer.add_theme_constant_override("separation", 10)
	card.add_child(outer)

	var title := Label.new()
	title.text = "Settings"
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", AMBER)
	outer.add_child(title)

	var body := HBoxContainer.new()
	body.add_theme_constant_override("separation", 12)
	body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	outer.add_child(body)

	# Sidebar: one entry per category, then the pinned destructive reset.
	var side := VBoxContainer.new()
	side.custom_minimum_size = Vector2(190, 0)
	side.add_theme_constant_override("separation", 6)
	body.add_child(side)
	for p in PAGES:
		var b := Button.new()
		b.text = PAGE_TITLES[p]
		b.toggle_mode = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.custom_minimum_size = Vector2(0, 40)
		b.pressed.connect(show_page.bind(p))
		b.focus_entered.connect(_on_tab_focus.bind(p))
		side.add_child(b)
		tab_buttons[p] = b
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	side.add_child(spacer)
	_reset_all_btn = Button.new()
	_reset_all_btn.text = "Reset All Settings"
	_reset_all_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	_reset_all_btn.custom_minimum_size = Vector2(0, 36)
	_reset_all_btn.add_theme_color_override("font_color", Color(1.0, 0.45, 0.4))
	_reset_all_btn.pressed.connect(_reset_all)
	side.add_child(_reset_all_btn)

	body.add_child(VSeparator.new())

	_scroll = ScrollContainer.new()
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.custom_minimum_size = Vector2(0, 440)
	_scroll.follow_focus = true
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	body.add_child(_scroll)
	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 6)
	_scroll.add_child(_content)

	_status = ShellUI.label(outer, "", 14, Color(1.0, 0.75, 0.4))
	var foot := HBoxContainer.new()
	foot.add_theme_constant_override("separation", 8)
	outer.add_child(foot)
	var defaults := Button.new()
	defaults.text = "Defaults"
	defaults.custom_minimum_size = Vector2(160, 40)
	defaults.pressed.connect(_reset_page)
	foot.add_child(defaults)
	var fill := Control.new()
	fill.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	foot.add_child(fill)
	var back := Button.new()
	back.text = "Done"
	back.custom_minimum_size = Vector2(160, 40)
	back.pressed.connect(close)
	foot.add_child(back)
	show_page(start_page if PAGES.has(start_page) else "Presentation")


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

func _on_tab_focus(p: String) -> void:
	if p != page:
		show_page(p)


func show_page(p: String) -> void:
	_cancel_capture()
	page = p
	_reset_armed = false
	_reset_all_btn.text = "Reset All Settings"
	for tab in tab_buttons:
		tab_buttons[tab].button_pressed = tab == p
	for c in _content.get_children():
		_content.remove_child(c)
		c.queue_free()
	sliders.clear()
	rebind_buttons.clear()
	_status.text = ""
	first_control = null
	_group = _content
	_scroll.scroll_vertical = 0
	match p:
		"Audio": _build_audio()
		"Video": _build_video()
		"Presentation": _build_presentation()
		"Controls": _build_controls()
		"Plugins": _build_plugins()
		"Support": _build_support()
	_link_focus(p)
	# Land focus on the sidebar entry, so up/down flips pages and right enters the page.
	ShellUI.focus(tab_buttons[p])


## Right from the sidebar enters the page; Up from the page's first control returns to it.
func _link_focus(p: String) -> void:
	var tab: Button = tab_buttons[p]
	(func():
		if not is_instance_valid(tab) or not tab.is_inside_tree():
			return
		for t in tab_buttons.values():
			t.focus_neighbor_right = NodePath()
		if first_control != null and is_instance_valid(first_control) and first_control.is_inside_tree():
			tab.focus_neighbor_right = tab.get_path_to(first_control)
			first_control.focus_neighbor_top = first_control.get_path_to(tab)
			first_control.focus_neighbor_left = first_control.get_path_to(tab)).call_deferred()


# --- Apple-style building blocks -------------------------------------------------------

## A titled group: amber header, a dark rounded box the rows go into, a muted footer under it.
## Everything added afterwards (rows, checks, sliders) lands in the box until the next section().
func _section(title_text: String, footer := "") -> VBoxContainer:
	var head := Label.new()
	head.text = title_text
	head.add_theme_font_size_override("font_size", 16)
	head.add_theme_color_override("font_color", AMBER)
	var top := _content.get_child_count() > 0
	if top:
		var gap := Control.new()
		gap.custom_minimum_size = Vector2(0, 8)
		_content.add_child(gap)
	_content.add_child(head)
	var box := PanelContainer.new()
	var sb := StyleBoxFlat.new()
	sb.bg_color = GROUP_BG
	sb.border_color = Color(1, 1, 1, 0.07)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(8)
	sb.set_content_margin_all(12)
	box.add_theme_stylebox_override("panel", sb)
	box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_child(box)
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 8)
	box.add_child(v)
	_group = v
	if footer != "":
		var f := ShellUI.label(_content, footer, 12)
		f.add_theme_color_override("font_color", Color(0.58, 0.61, 0.69))
	return v


func _row(label: String) -> HBoxContainer:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 12)
	var l := Label.new()
	l.text = label
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_font_size_override("font_size", 15)
	r.add_child(l)
	_group.add_child(r)
	return r


## A slider row as in Apple's sliderRow: title left, value right, the slider under them.
func _slider(label: String, section: String, key: String, lo: float, hi: float, step: float,
		fmt: Callable) -> HSlider:
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 2)
	_group.add_child(v)
	var head := HBoxContainer.new()
	v.add_child(head)
	var t := Label.new()
	t.text = label
	t.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	t.add_theme_font_size_override("font_size", 15)
	head.add_child(t)
	var val := Label.new()
	val.add_theme_font_size_override("font_size", 13)
	val.add_theme_color_override("font_color", ShellUI.MUTED)
	head.add_child(val)
	var s := HSlider.new()
	s.min_value = lo
	s.max_value = hi
	s.step = step
	s.value = float(Prefs.get_value(section, key))
	s.custom_minimum_size = Vector2(0, 22)
	s.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	s.focus_mode = Control.FOCUS_ALL
	v.add_child(s)
	val.text = fmt.call(s.value)
	s.value_changed.connect(func(x: float):
		val.text = fmt.call(x)
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
	c.custom_minimum_size = Vector2(0, 34)
	c.toggled.connect(func(on: bool):
		Prefs.set_value(section, key, on)
		_after_change(section))
	_group.add_child(c)
	if first_control == null:
		first_control = c
	return c


func _button(label: String, cb: Callable) -> Button:
	var b := Button.new()
	b.text = label
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.custom_minimum_size = Vector2(0, 38)
	b.pressed.connect(cb)
	_group.add_child(b)
	if first_control == null:
		first_control = b
	return b


func _caption(text: String) -> Label:
	var l := ShellUI.label(_group, text, 12)
	l.add_theme_color_override("font_color", Color(0.58, 0.61, 0.69))
	return l


func _after_change(section: String) -> void:
	if section == "video":
		Prefs.apply_video()
	elif section == "input":
		Controls.register()
	_mark_changed()


func _pct(x: float) -> String:
	return "%d%%" % roundi(x * 100.0)


# --- Audio ---------------------------------------------------------------------------

func _build_audio() -> void:
	_section("Audio", "Master scales everything; the individual sliders balance music, weapon/engine effects and interface clicks beneath it. Music plays over the main menu only, as in the original (if your data has the track as an mp3).")
	_check("Mute all", "audio", "muted")
	_slider("Master", "audio", "master", 0.0, 1.0, 0.05, _pct)
	_slider("Effects", "audio", "sfx", 0.0, 1.0, 0.05, _pct)
	_slider("Interface", "audio", "ui", 0.0, 1.0, 0.05, _pct)
	_slider("Music", "audio", "music", 0.0, 1.0, 0.05, _pct)


# --- Graphics ------------------------------------------------------------------------

func _build_video() -> void:
	_section("Graphics", "Window scale applies when not fullscreen. The play area adapts to 16:9 and 16:10 (Steam Deck) screens. Gate links draw hypergate and wormhole spokes on the plain galaxy map -- an enhancement the original lacks.")
	_check("Fullscreen", "video", "fullscreen")
	_check("VSync", "video", "vsync")
	_slider("Window scale", "video", "scale", 0.75, 2.0, 0.25,
		func(x: float): return "%dx%d" % [roundi(1280 * x), roundi(720 * x)])
	_check("Gate links on the galaxy map (enhancement)", "map", "gate_links")
	_section("Flight View", "Classic is the original's fixed, north-up camera. Look ahead drifts the view ahead of your ship; Ship up turns the world so your ship always points up; Chase falls back to Ship up (the 3D tilt needs live 3D hulls). Screen shake and the camera views are enhancements the original lacks; Reduce flashing also steadies the exhaust and removes sparks and flashes.")
	_slider("Camera view", "graphics", "camera_view", 0, 3, 1,
		func(x: float): return ["Classic", "Look ahead", "Ship up", "Chase"][clampi(int(x), 0, 3)])
	_slider("Camera zoom", "graphics", "camera_zoom", 0.5, 2.0, 0.25,
		func(x: float): return "%.2fx world per pixel" % x)
	_check("Screen shake (enhancement)", "graphics", "screen_shake")
	_check("Reduce flashing", "graphics", "reduce_flashing")


# --- Interface (Presentation) ----------------------------------------------------------

## Presentation: Classic (the original's status bar / dialogs / menu, drawn from the
## player's own data -- the default) or Nova Swift (the port's own screens), as in
## the Apple app's GameSettings presets; the toggles below mix them. Reads
## Prefs[presentation]; screens pick the change up the next time they open (the
## HUD immediately).
func _build_presentation() -> void:
	var mode_name := {Prefs.UI_CLASSIC: "Classic", Prefs.UI_ENHANCED: "Enhanced", Prefs.UI_NOVA_SWIFT: "Nova Swift",
		Prefs.UI_CUSTOM: "Custom"}
	_section("Presentation", "Classic draws the original interface from your game data (status bar, dialogs, menu). Enhanced adds the full-screen galaxy map. Nova Swift uses the port's own modern screens. Presets are templates -- pick one, then fine-tune the options below. Current: %s." % mode_name[Prefs.ui_mode()])
	var modes := HBoxContainer.new()
	modes.add_theme_constant_override("separation", 8)
	_group.add_child(modes)
	var mode_buttons := {}
	for m in [[Prefs.UI_CLASSIC, "Classic"], [Prefs.UI_ENHANCED, "Enhanced"], [Prefs.UI_NOVA_SWIFT, "Nova Swift"]]:
		var b := Button.new()
		b.text = m[1]
		b.toggle_mode = true
		b.custom_minimum_size = Vector2(130, 38)
		b.button_pressed = Prefs.ui_mode() == m[0]
		b.pressed.connect(func():
			Prefs.apply_ui_mode(m[0])
			_mark_changed()
			show_page.call_deferred("Presentation"))
		modes.add_child(b)
		mode_buttons[m[0]] = b
	if first_control == null:
		first_control = mode_buttons[Prefs.UI_CLASSIC]
	if ClassicTheme.has_data():
		_button("Original Preferences Window…", open_classic_preferences)
	_section("Interface Options", "Mix the port's modern touches over the authentic EV Nova presentation. Full-screen map opens the galaxy map without its dialog frame. Storyline tags mark missions that continue a reconstructed campaign and jump to it in the Story Guide -- an aftermarket hint the original game never had.")
	for t in [["Full-screen galaxy map", "fullscreen_galaxy_map"], ["Modern main menu", "modern_menu"],
			["Modern dialog chrome", "modern_dialogs"], ["Modern HUD", "modern_hud"]]:
		var c := _check(t[0], "presentation", t[1])
		c.toggled.connect(func(_on: bool): show_page.call_deferred("Presentation"))
	_check("Show mission storyline tags", "story", "show_mission_storyline_tags")
	_section("Tutorial", "Tutorial hints show one-time tips as you play (your first flight, the spaceport, the Mission BBS, the Outfitter) -- \"Show all hints again\" brings them back. Flight Training is a safe practice flight that never touches your pilot.")
	var hc := _check("Tutorial hints", "hints", "enabled")
	hc.toggled.connect(func(_on: bool): show_page.call_deferred("Presentation"))
	if Prefs.hints_enabled():
		_button("Show all hints again", func():
			Prefs.reset_hints()
			_status.text = "Hints will show again.")
	if allow_training:
		_button("Flight Training", func(): training_requested.emit())


## The original's Preferences window (DLOG 4003) over Settings; Settings comes back, focused, when
## it closes.
func open_classic_preferences() -> Node:
	if classic_prefs != null:
		return classic_prefs
	_root.visible = false
	classic_prefs = ClassicPreferences.new()
	add_child(classic_prefs)
	classic_prefs.setup(_nova)
	classic_prefs.changed.connect(_mark_changed)
	classic_prefs.key_settings.connect(func():
		(func(): show_page("Controls")).call_deferred())
	classic_prefs.closed.connect(func():
		classic_prefs = null
		_root.visible = true
		show_page(page))
	return classic_prefs


# --- Controls ------------------------------------------------------------------------

func _build_controls() -> void:
	_section("Controls", "Off = the original's keys (arrows, Space, Ctrl, Z; W/Alt-W, R, N, E…). The dead zone is how far a stick must move before it registers. Sticks and triggers are fixed.")
	_slider("Stick dead zone", "input", "deadzone", 0.0, 0.5, 0.01, _pct)
	var modern := _check("Modern key layout (the port's earlier keys)", "input", "modern_keys")
	modern.toggled.connect(func(_on: bool): show_page.call_deferred("Controls"))
	for group in Controls.GROUPS:
		_section("Keyboard & Controller Bindings -- " + group if group == Controls.GROUPS.keys()[0] else group,
			"Activate a key or pad button to rebind it (Esc cancels)." if group == Controls.GROUPS.keys()[0] else "")
		for action in Controls.GROUPS[group]:
			_rebind_row(_group, action)


func _rebind_row(list: Control, action: String) -> void:
	var r := HBoxContainer.new()
	r.add_theme_constant_override("separation", 8)
	var l := Label.new()
	l.text = Controls.ACTION_LABELS.get(action, action)
	l.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	l.add_theme_font_size_override("font_size", 14)
	r.add_child(l)
	var kb := Button.new()
	kb.custom_minimum_size = Vector2(190, 32)
	kb.pressed.connect(_begin_capture.bind(action, _key_field(action), kb))
	r.add_child(kb)
	var pb := Button.new()
	pb.custom_minimum_size = Vector2(170, 32)
	pb.pressed.connect(_begin_capture.bind(action, "buttons", pb))
	r.add_child(pb)
	list.add_child(r)
	rebind_buttons[action] = {"key": kb, "pad": pb}
	if first_control == null:
		first_control = kb
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


# --- Data & Advanced (Support) ---------------------------------------------------------

func _build_plugins() -> void:
	_section("Plug-ins", "EV Nova plug-ins and total conversions. Every plug-in in your game's Nova Plug-ins folder and in the NovaSwift plug-in folder loads automatically, in the original's order. The manager browses the online catalog, installs and updates, imports your own files and (optionally) lets you choose and order them.")
	_button("Open the Plug-ins Manager…", func(): _open_plugins("Installed"))
	_button("Browse the Online Catalog…", func(): _open_plugins("Browse"))
	_button("Load Order…", func(): _open_plugins("Load order"))


func _open_plugins(start_tab: String) -> void:
	var scr = PluginsScreen.new()
	add_child(scr)
	scr.setup(_nova, start_tab)
	scr.closed.connect(func():
		scr.queue_free()
		show_page("Plugins"))


func _build_support() -> void:
	_section("Saved Games", "Pilots are ordinary .evpilot files -- copy them, back them up, or open one from anywhere with Open Pilot. Changing the folder copies the pilots already in the old one across (the originals stay). Rotating backups live in a Backups folder beside them.")
	var r := _row("Saved to")
	var path := Label.new()
	path.text = PilotFiles.dir()
	path.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	path.custom_minimum_size = Vector2(380, 0)
	path.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
	path.add_theme_font_size_override("font_size", 12)
	path.add_theme_color_override("font_color", ShellUI.MUTED)
	r.add_child(path)
	var fa := _check("Frequent autosave", "gameplay", "frequent_autosave")
	fa.tooltip_text = "Off = the original: pilots save only when you leave a spaceport."
	_caption("Frequent autosave (an enhancement, off by default) also saves when you land and jump, every few minutes in flight, and remembers where you were. Off is the original's cadence.")
	_button("Open Pilots Folder", func(): OS.shell_show_in_file_manager(PilotFiles.dir()))
	_button("Change Pilots Folder…", func():
		PilotFiles.pick_folder(self, PilotFiles.dir(), func(d: String):
			PilotFiles.set_dir(d)
			_mark_changed()
			show_page("Support")))
	if PilotFiles.is_custom() and OS.get_environment("NOVA_PILOTS_DIR") == "":
		_button("Use the Default Folder", func():
			PilotFiles.set_dir("")
			_mark_changed()
			show_page("Support"))
	_section("Support and Developer")
	DevSettingsPage.build(self, _group, _mark_changed)


# --- resets ----------------------------------------------------------------------------

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
		"Presentation":
			Prefs.reset_section("presentation")
			Prefs.reset_section("story")
	_dirty = true
	changed.emit()
	show_page(page)


## Sidebar "Reset All Settings": asks for a second press (a pad can't answer a dialog).
func _reset_all() -> void:
	if not _reset_armed:
		_reset_armed = true
		_reset_all_btn.text = "Press again to reset everything"
		return
	for sec in ["audio", "video", "map", "input", "story", "presentation", "classic"]:
		Prefs.reset_section(sec)
	Prefs.reset_bindings()
	Controls.register()
	Prefs.apply_video()
	_dirty = true
	changed.emit()
	show_page(page)
	_status.text = "All settings restored to their defaults."


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


