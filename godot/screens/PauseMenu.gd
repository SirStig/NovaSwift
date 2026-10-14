# NOVA Swift — in-flight pause menu (Esc / pad Start).
#
# Resume · Player Info · Story Map · Settings · Save & Quit to menu · Quit. The flight sim is paused by
# Main.gd while this is up. It only reports the choice; Main.gd does the saving
# and screen changes. Esc / B / Start again resume.
#
# Presentation: Settings > Interface > "Sidebar pause menu" (on by default, as in the Apple app)
# draws the port's own sidebar -- Apple's GameMenuView: a 340 px panel sliding in from the left over
# a dimmed scrim, an app-logo header (ship / system, close button), then Resume · Galaxy Map ·
# Pilot Info · Missions · Story Guide · Preferences · Report Issue · Full Screen · [Debug Suite] |
# Multiplayer | Save Pilot · Load Pilot | Main Menu. With it off, the original's plain pause dialog:
# with the data loaded and "Modern dialogs" off, the Classic UI kit (ui/classic/: the dësc dialog
# frame PICT 8524/8525/8526 with the original three-state buttons), otherwise the plain Nova Swift
# panel below. The sim stays paused underneath either way.
extends CanvasLayer

const ShellUI = preload("res://screens/ShellUI.gd")
const Prefs = preload("res://Prefs.gd")
const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")
const ClassicDialog = preload("res://ui/classic/ClassicDialog.gd")
const T = preload("res://ui/novaswift/NovaTheme.gd")
const NC = preload("res://ui/novaswift/NovaControls.gd")
const Alert = preload("res://ui/novaswift/NovaAlert.gd")

signal resume
signal settings
signal player_info
signal story_map
signal save_quit_to_menu
signal quit
## Sidebar rows the classic pause dialog does not have. Unconnected ones fall back (see _row_action).
signal galaxy_map
signal missions
## "Save Pilot" with Frequent autosave on (the original saves only when you leave a spaceport).
signal save_pilot
## "Multiplayer" row: the shell opens the hub. Unconnected, the row only explains.
signal multiplayer_hub

## The sidebar header (Apple hud.shipName / hud.systemName); the host may set them before setup().
var ship_name := ""
var system_name := ""
var sidebar: Control            # the sidebar panel when drawn
var sidebar_rows := {}          # title -> Button

var first_button: Control
var buttons: Array[Control] = []
## The save-and-leave entry's label ("Leave Training" during the training flight).
var save_label := "Save & Quit to Menu"
var classic_dialog: Control     # the ClassicDialog when drawn in Classic presentation


func setup(nova: Object, can_save: bool) -> void:
	layer = 60
	ClassicTheme.setup(nova)
	if bool(_pv("interface", "sidebar_pause_menu", true)):
		_setup_sidebar(nova, can_save)
		return
	if ClassicTheme.classic("dialogs"):
		_setup_classic(nova, can_save)
		return
	var root := ShellUI.screen(self, 0.78)
	var box := ShellUI.panel(root, 340, 8)
	ShellUI.title(box, "Paused", 28)
	first_button = ShellUI.button(box, "Resume", func(): resume.emit(), nova)
	buttons.append(first_button)
	buttons.append(ShellUI.button(box, "Player Info", func(): player_info.emit(), nova))
	buttons.append(ShellUI.button(box, "Story Map", func(): story_map.emit(), nova))
	buttons.append(ShellUI.button(box, "Settings", func(): settings.emit(), nova))
	buttons.append(ShellUI.button(box, "Report a Bug", func(): _devtools("report"), nova))
	if Prefs.get_value("developer", "debug_mode"):
		buttons.append(ShellUI.button(box, "Debug Suite", func(): _devtools("console"), nova))
	if can_save:
		buttons.append(ShellUI.button(box, save_label, func(): save_quit_to_menu.emit(), nova))
	buttons.append(ShellUI.button(box, "Quit", func(): quit.emit(), nova))
	ShellUI.focus(first_button)


## The app logo (imported if the editor has been run, else read straight off disk).
static func _logo() -> Texture2D:
	var path := "res://assets/branding/app-logo.png"
	if ResourceLoader.exists(path):
		return load(path)
	var img := Image.load_from_file(ProjectSettings.globalize_path(path))
	return ImageTexture.create_from_image(img) if img != null else null


static func _pv(section: String, key: String, default: Variant) -> Variant:
	Prefs.get_value("audio", "master")   # makes sure the file is loaded
	return Prefs._cfg.get_value(section, key, Prefs.DEFAULTS.get(section, {}).get(key, default))


## Apple GameMenuView: the sidebar. `can_save` gates Save Pilot / Load Pilot / Main Menu (no pilot
## to save without data).
## Row density for the logical viewport height (Steam Deck 1280x800 at UI scale 2 is only 400 px tall):
## the list always scrolls with pad focus, but compacting shows far more rows at once.
func _density() -> int:
	var vh: float = get_viewport().get_visible_rect().size.y if is_inside_tree() else 800.0
	return 2 if vh < 520.0 else (1 if vh < 700.0 else 0)


func _setup_sidebar(nova: Object, can_save: bool) -> void:
	var root := Control.new()
	root.set_anchors_preset(Control.PRESET_FULL_RECT)
	root.theme = T.theme()
	add_child(root)
	# Scrim: black 55 %, click = resume.
	var scrim := ColorRect.new()
	scrim.color = T.SCRIM
	scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	scrim.gui_input.connect(func(e: InputEvent):
		if e is InputEventMouseButton and e.pressed and e.button_index == MOUSE_BUTTON_LEFT:
			resume.emit())
	root.add_child(scrim)
	var panel := PanelContainer.new()
	panel.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	panel.custom_minimum_size = Vector2(340, 0)
	panel.offset_right = 340
	var sb := T.box(Color(0.10, 0.10, 0.10, 0.94), 0)
	sb.border_width_right = 1
	sb.border_color = Color(1, 1, 1, 0.08)
	panel.add_theme_stylebox_override("panel", sb)
	root.add_child(panel)
	sidebar = panel
	var v := VBoxContainer.new()
	v.add_theme_constant_override("separation", 0)
	panel.add_child(v)
	# header: logo, ship / system, close
	var hm := MarginContainer.new()
	for side in ["left", "right", "top", "bottom"]:
		hm.add_theme_constant_override("margin_" + side, [16, 10, 6][_density()])
	v.add_child(hm)
	var head := HBoxContainer.new()
	head.add_theme_constant_override("separation", 12)
	hm.add_child(head)
	var logo := TextureRect.new()
	logo.texture = _logo()
	logo.custom_minimum_size = Vector2([44, 36, 28][_density()], [44, 36, 28][_density()])
	logo.expand_mode = TextureRect.EXPAND_IGNORE_SIZE
	logo.stretch_mode = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	head.add_child(logo)
	var names := VBoxContainer.new()
	names.add_theme_constant_override("separation", 2)
	names.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	head.add_child(names)
	NC.label(names, ship_name if ship_name != "" else "NOVA SWIFT", "heading", "regular", T.AMBER)
	if system_name != "":
		NC.label(names, system_name, "caption", "regular", T.SECONDARY)
	var close := NC.icon_button("xmark", func(): resume.emit(), T.WHITE, 30, 12)
	close.add_theme_stylebox_override("normal", T.box(Color(1, 1, 1, 0.10), 20))
	close.tooltip_text = "Resume"
	head.add_child(close)
	var rule := ColorRect.new()
	rule.color = Color(1, 1, 1, 0.12)
	rule.custom_minimum_size = Vector2(0, 1)
	v.add_child(rule)
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	scroll.follow_focus = true
	v.add_child(scroll)
	var pad := MarginContainer.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for side in ["left", "right", "top", "bottom"]:
		pad.add_theme_constant_override("margin_" + side, [12, 8, 4][_density()])
	scroll.add_child(pad)
	var list := VBoxContainer.new()
	list.add_theme_constant_override("separation", [2, 2, 1][_density()])
	pad.add_child(list)
	_row(list, "Resume", "play.fill", T.AMBER, func(): resume.emit())
	_row(list, "Galaxy Map", "map.fill", T.WHITE, func(): _row_action(galaxy_map, func(): _press_action("galaxy_map")))
	_row(list, "Pilot Info", "person.crop.circle", T.WHITE, func(): player_info.emit())
	_row(list, "Missions", "list.bullet.clipboard", T.WHITE, func(): _row_action(missions, func(): story_map.emit()))
	_row(list, "Story Guide", "point.3.connected", T.WHITE, func(): story_map.emit())
	_row(list, "Preferences", "gearshape.fill", T.WHITE, func(): settings.emit())
	_row(list, "Report Issue", "ladybug", T.WHITE, func(): _devtools("report"))
	_row(list, "Full Screen", "fullscreen", T.WHITE, _toggle_fullscreen)
	if Prefs.get_value("developer", "debug_mode"):
		_row(list, "Debug Suite", "ladybug", T.DEBUG_GREEN, func(): _devtools("console"))
	_gap(list)
	_row(list, "Multiplayer", "person.2.fill", T.WHITE, func():
		if multiplayer_hub.get_connections().is_empty():
			Alert.show(self, {"title": "Notice", "message": "Multiplayer isn't available here."})
		else:
			multiplayer_hub.emit())
	_gap(list)
	_row(list, "Save Pilot", "square.and.arrow.down", T.WHITE, _save_pilot, can_save)
	_row(list, "Load Pilot", "folder", T.WHITE, func(): save_quit_to_menu.emit(), can_save)
	_gap(list)
	_row(list, "Main Menu" if save_label == "Save & Quit to Menu" else save_label, "door.exit", T.RED, func(): save_quit_to_menu.emit())
	_row(list, "Quit Game", "xmark", T.RED, func(): quit.emit())
	for b in sidebar_rows.values():
		buttons.append(b)
	first_button = sidebar_rows["Resume"]
	ShellUI.focus(first_button)


func _gap(list: VBoxContainer) -> void:
	var m := MarginContainer.new()
	m.add_theme_constant_override("margin_top", [6, 4, 2][_density()])
	m.add_theme_constant_override("margin_bottom", [6, 4, 2][_density()])
	var r := ColorRect.new()
	r.color = Color(1, 1, 1, 0.08)
	r.custom_minimum_size = Vector2(0, 1)
	m.add_child(r)
	list.add_child(m)


## GameMenuView.row: an SF symbol in the tint (amber unless coloured), the title in `.button`
## medium, a faint rounded fill.
func _row(list: VBoxContainer, title: String, icon_name: String, tint: Color, cb: Callable, enabled := true) -> Button:
	var b := Button.new()
	b.text = title
	b.alignment = HORIZONTAL_ALIGNMENT_LEFT
	b.focus_mode = Control.FOCUS_ALL
	b.disabled = not enabled
	b.custom_minimum_size = Vector2(0, [43, 36, 26][_density()])
	b.mouse_default_cursor_shape = Control.CURSOR_POINTING_HAND
	var icon_color := T.AMBER if tint == T.WHITE else tint
	b.icon = T.icon(icon_name, 18, icon_color)
	b.expand_icon = false
	b.add_theme_constant_override("h_separation", 14)
	for st in ["icon_normal_color", "icon_hover_color", "icon_pressed_color", "icon_focus_color", "icon_disabled_color"]:
		b.add_theme_color_override(st, Color.WHITE)
	var pad := Vector2(10, [8, 5, 2][_density()])
	b.add_theme_stylebox_override("normal", T.box(Color(1, 1, 1, 0.05), 10, Color(0, 0, 0, 0), 0, pad))
	b.add_theme_stylebox_override("hover", T.box(Color(1, 1, 1, 0.10), 10, Color(0, 0, 0, 0), 0, pad))
	b.add_theme_stylebox_override("pressed", T.box(Color(1, 1, 1, 0.16), 10, Color(0, 0, 0, 0), 0, pad))
	b.add_theme_stylebox_override("disabled", T.box(Color(1, 1, 1, 0.03), 10, Color(0, 0, 0, 0), 0, pad))
	T.style_text(b, "button", "medium", tint)
	for st in ["font_hover_color", "font_pressed_color", "font_focus_color"]:
		b.add_theme_color_override(st, tint)
	b.add_theme_color_override("font_disabled_color", Color(tint.r, tint.g, tint.b, 0.4))
	b.pressed.connect(cb)
	NC.grow_on_focus(b, 1.02)
	list.add_child(b)
	sidebar_rows[title] = b
	return b


## A sidebar row whose own signal nobody listens to falls back to `fallback`.
func _row_action(sig: Signal, fallback: Callable) -> void:
	if sig.get_connections().is_empty():
		fallback.call()
	else:
		sig.emit()


## Close the menu and press a gameplay action once (the host handles it as the key would).
func _press_action(action: String) -> void:
	var tree := get_tree()
	resume.emit()
	if InputMap.has_action(action):
		var down := InputEventAction.new()
		down.action = action
		down.pressed = true
		Input.parse_input_event(down)
		var up := InputEventAction.new()
		up.action = action
		up.pressed = false
		(func(): Input.parse_input_event(up)).call_deferred()


func _toggle_fullscreen() -> void:
	var on := DisplayServer.window_get_mode() != DisplayServer.WINDOW_MODE_FULLSCREEN
	Prefs.set_value("video", "fullscreen", on)
	Prefs.apply_video()
	Prefs.save()


## Apple: the original saves only when you leave a spaceport; an in-flight save is the
## frequent-autosave enhancement.
func _save_pilot() -> void:
	if not bool(Prefs.get_value("gameplay", "frequent_autosave")):
		Alert.show(self, {"title": "Notice", "message": "Pilots are saved when you leave a spaceport. Quitting in flight returns you to your last launch."})
		return
	_row_action(save_pilot, func(): pass)
	Alert.show(self, {"title": "Notice", "message": "Pilot saved."})


func _setup_classic(nova: Object, can_save: bool) -> void:
	var specs := [
		{"label": "Resume", "action": func(): resume.emit()},
		{"label": "Player Info", "action": func(): player_info.emit()},
		{"label": "Story Map", "action": func(): story_map.emit()},
		{"label": "Settings", "action": func(): settings.emit()},
		{"label": "Report a Bug", "action": func(): _devtools("report")},
	]
	if Prefs.get_value("developer", "debug_mode"):
		specs.append({"label": "Debug Suite", "action": func(): _devtools("console")})
	if can_save:
		specs.append({"label": save_label, "action": func(): save_quit_to_menu.emit()})
	specs.append({"label": "Quit", "action": func(): quit.emit()})
	classic_dialog = ClassicDialog.panel(nova, {"title": "Paused", "body_buttons": specs, "body_buttons_width": 220})
	ClassicDialog.modal(self, classic_dialog, 0.78)
	for i in specs.size():
		buttons.append(classic_dialog.item(i))
	first_button = buttons[0]


## Close the menu (play continues underneath) and open the debug suite on `tab`.
func _devtools(tab: String) -> void:
	var tree := get_tree()
	resume.emit()
	tree.call_group("nova_devtools", "open_tab", tab)


func _unhandled_input(event: InputEvent) -> void:
	if not visible:
		return
	if event.is_action_pressed("ui_cancel") or event.is_action_pressed("pause_menu"):
		get_viewport().set_input_as_handled()
		resume.emit()


## Hide while a sub-screen (Settings) is on top, show again after.
func set_active(on: bool) -> void:
	visible = on
	if on:
		if classic_dialog != null:
			classic_dialog.focus_first.call_deferred()
		else:
			ShellUI.focus(first_button)
