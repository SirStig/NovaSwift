# NOVA Swift — Settings screen: the Godot form of the Apple app's Launcher/SettingsView.swift, drawn
# with the NovaSwift UI kit (ui/novaswift/): DialogChrome card (660 x 620, the original dialog frame
# in Classic presentation / the modern steel-and-blue panel with "Modern dialog chrome" / a plain
# dark card without game data), an amber "Settings" title, a category sidebar (NovaSelectRow chips
# with a pinned red "Reset All Settings") and, on the right, the selected category's grouped
# sections: amber icon headers over dark rounded groups, amber check boxes, "title .... 70%" slider
# rows, value-chip menu pickers, segmented pickers, footers in muted caption text.
#
# Pages, in Apple's order (page key -> sidebar title):
#   Presentation -> Interface      Presentation preset, Interface Options, HUD & Interface
#   Gameplay                       speed, auto-target, landing confirm, tutorial hints, flight training
#   Enhancements                   the GameplayEnhancements catalog + Port Options
#   Controls                       sticks, toggles, the full-window Controls Editor
#   Video -> Graphics              quality, camera, particles ... + Window
#   Audio                          mute + the four volume sliders
#   Accessibility                  reduce flashing & motion, colourblind mode
#   Support -> Data & Advanced     Saved Games, Support, Developer
#
# Every row writes the Prefs key listed in docs/GODOT_SETTINGS_KEYS.md (the SettingsPlumbing
# autoload applies it; nothing here talks to the bridge). Rows Apple has that Godot has no key for at
# all (touch / haptics / cursor speed, HD & 3D, graphics-quality presets) are drawn anyway and persist
# to Prefs [apple]; each is listed in `todo_rows` ("Page / Title -> apple.key"). Rows whose key exists
# but whose behaviour is not read yet (quick hyperjump, show planet names, ship bars, particle density,
# starfield density, Windows hyperspace look, sidebar pause menu fallback ...) still write their key.
#
# Everything is reachable by Godot focus navigation alone (arrows / d-pad / stick move, Enter / A
# activate, left / right step a focused slider, Esc / B go back); the kit draws Apple's controller
# hover-grow + an amber ring only for keyboard / pad. Moving focus onto a sidebar entry shows its
# page; Right (or Down from the last entry) enters the page, Up from its first control returns.
#
# The original Preferences window (DLOG 4003, screens/ClassicPreferences.gd) opens only from the
# button in the Presentation section -- it never replaces this screen.
#
# Controls page: sticks / toggles, then "Open Controls Editor" -> screens/controls_editor (a visual
# keyboard + controller over Controls.BINDINGS). There the next key (or pad button) pressed is
# captured, Esc cancels (an unanswered capture times out after 6 s). A binding already held by another action in the
# same group is swapped onto it (PadBindings.bind). Re-applied immediately (Controls.register());
# written to user://settings.cfg when the screen closes.
extends CanvasLayer

const ErrorReport = preload("res://ui/ErrorReport.gd")   # logs folder + prefilled GitHub issue (error boundary helpers)
const T = preload("res://ui/novaswift/NovaTheme.gd")
const NC = preload("res://ui/novaswift/NovaControls.gd")
const Chrome = preload("res://ui/novaswift/NovaChrome.gd")
const Alert = preload("res://ui/novaswift/NovaAlert.gd")
const Inert = preload("res://ui/novaswift/NovaInert.gd")
const Controls = preload("res://Controls.gd")
const ControlsEditor = preload("res://screens/controls_editor/ControlsEditor.gd")
const Prefs = preload("res://Prefs.gd")
const PilotFiles = preload("res://screens/PilotFiles.gd")
const UpdateController = preload("res://updater/UpdateController.gd")
const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")
const ClassicDialog = preload("res://ui/classic/ClassicDialog.gd")
const ClassicPreferences = preload("res://screens/ClassicPreferences.gd")

## Audio/video/deadzone changed (Main re-applies volumes to GameAudio + music).
signal changed
signal closed
## "Flight Training" (Apple Settings > Gameplay): the host closes Settings and runs the course.
signal training_requested
## "Import Data" / "Preview Setup Wizard" (Apple Settings > Data & Advanced): the host closes
## Settings and opens the data-setup screen.
signal data_setup_requested
signal data_setup_preview_requested

## Page keys in sidebar order (Apple SettingsView category order), and what the sidebar calls them.
const PAGES := ["Presentation", "Gameplay", "Enhancements", "Controls", "Video", "Audio", "Accessibility", "Support"]
const PAGE_TITLES := {"Presentation": "Interface", "Gameplay": "Gameplay", "Enhancements": "Enhancements",
	"Controls": "Controls", "Video": "Graphics", "Audio": "Audio", "Accessibility": "Accessibility",
	"Support": "Data & Advanced"}
const PAGE_ICONS := {"Presentation": "sparkles.tv", "Gameplay": "gamecontroller", "Enhancements": "wand.and.stars",
	"Controls": "dpad", "Video": "sparkles", "Audio": "speaker.wave.2", "Accessibility": "accessibility",
	"Support": "externaldrive"}
const AMBER := T.AMBER

var page := "Presentation"
var tab_buttons := {}          # page name -> Button (the sidebar entries)
var sliders := {}              # "section.key" -> HSlider
var controls_editor: Node      # the visual Controls Editor while it is open
var first_control: Control
## Set by the host before setup(): Settings was opened from the main menu, so Flight Training can run.
var allow_training := false
var classic_prefs: Node        # the original Preferences window while it is up
## Apple rows drawn without engine wiring on the pages built so far ("Page / Title -> apple.key").
var todo_rows: Array = []
var frame: Dictionary          # Chrome.card_frame result

var _nova: Object
var _root: Control
var _content: VBoxContainer
var _group: NC.Group           # the section group rows are added to
var _status: Label
var _scroll: ScrollContainer
var _reset_all_btn: Button
var _dirty := false
var _pl: Object                # NovaPlugins handle (the Manual plug-in order enhancement)


func setup(nova: Object, start_page := "Presentation") -> void:
	_nova = nova
	layer = 70
	frame = Chrome.card_frame(self, "Settings", 660.0, 620.0, close)
	_root = frame.root
	var body: Control = frame.body
	var split := HBoxContainer.new()
	split.set_anchors_preset(Control.PRESET_FULL_RECT)
	split.offset_left = 14
	split.offset_right = -14
	split.offset_bottom = -10
	split.add_theme_constant_override("separation", 0)
	body.add_child(split)

	# Sidebar: one NovaSelectRow per category, then the pinned destructive reset.
	var side_wrap := MarginContainer.new()
	side_wrap.custom_minimum_size = Vector2(176, 0)
	for s in ["left", "right"]:
		side_wrap.add_theme_constant_override("margin_" + s, 8)
	side_wrap.add_theme_constant_override("margin_top", 10)
	side_wrap.add_theme_constant_override("margin_bottom", 10)
	split.add_child(side_wrap)
	var side := VBoxContainer.new()
	side.add_theme_constant_override("separation", 6)
	side_wrap.add_child(side)
	for p in PAGES:
		var b := NC.select_row(side, PAGE_TITLES[p], PAGE_ICONS[p], p == page)
		b.pressed.connect(show_page.bind(p))
		b.focus_entered.connect(_on_tab_focus.bind(p))
		tab_buttons[p] = b
	NC.spacer(side, 0, true)
	_reset_all_btn = NC.button("Reset All Settings", "plain", _reset_all_confirm, "arrow.counterclockwise")
	_reset_all_btn.add_theme_color_override("font_color", T.RED)
	for st in ["font_hover_color", "font_pressed_color", "font_focus_color"]:
		_reset_all_btn.add_theme_color_override(st, T.RED)
	_reset_all_btn.icon = T.icon("arrow.counterclockwise", 14, T.RED)
	_reset_all_btn.alignment = HORIZONTAL_ALIGNMENT_LEFT
	T.style_text(_reset_all_btn, "caption", "regular", T.RED)
	side.add_child(_reset_all_btn)

	var divider := ColorRect.new()
	divider.color = Color(1, 1, 1, 0.12)
	divider.custom_minimum_size = Vector2(1, 0)
	split.add_child(divider)

	var right := VBoxContainer.new()
	right.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right.add_theme_constant_override("separation", 0)
	split.add_child(right)
	_scroll = ScrollContainer.new()
	_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_scroll.follow_focus = true
	_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	right.add_child(_scroll)
	var pad := MarginContainer.new()
	pad.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	for s in ["left", "right"]:
		pad.add_theme_constant_override("margin_" + s, 10)
	pad.add_theme_constant_override("margin_top", 10)
	pad.add_theme_constant_override("margin_bottom", 10)
	_scroll.add_child(pad)
	_content = VBoxContainer.new()
	_content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_content.add_theme_constant_override("separation", 4)
	pad.add_child(_content)
	_status = NC.label(right, "", "caption", "regular", Color(1.0, 0.75, 0.4), true)
	show_page(start_page if PAGES.has(start_page) else "Presentation")


func _exit_tree() -> void:
	if _dirty:
		Prefs.save()
		_dirty = false


func close() -> void:
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
	page = p
	for tab in tab_buttons:
		tab_buttons[tab].set_pressed_no_signal(tab == p)
	for c in _content.get_children():
		_content.remove_child(c)
		c.queue_free()
	sliders.clear()
	todo_rows.clear()
	_status.text = ""
	first_control = null
	_group = null
	_scroll.scroll_vertical = 0
	match p:
		"Presentation":
			_build_presentation()
			_build_hud_interface()
		"Gameplay": _build_gameplay()
		"Enhancements": _build_enhancements()
		"Controls": _build_controls()
		"Video": _build_video()
		"Audio": _build_audio()
		"Accessibility": _build_accessibility()
		"Support": _build_support()
	_link_focus(p)
	# Land focus on the sidebar entry, so up/down flips pages and right enters the page.
	_focus_later(tab_buttons[p])


static func _focus_later(c: Control) -> void:
	(func(): if is_instance_valid(c) and c.is_inside_tree(): c.grab_focus()).call_deferred()


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


# --- kit wrappers: rows bound to Prefs ----------------------------------------------------

func _section(title_text: String, footer := "", icon := "") -> NC.Group:
	_group = NC.section(_content, title_text, icon, footer)
	return _group


func _note_first(c: Control) -> void:
	if first_control == null:
		first_control = c


## Pref lookup that never errors for keys the Prefs table declares no default for (the Apple rows
## without wiring, sidebar_pause_menu): the stored value, else Prefs' own default, else `default`.
static func _pv(section: String, key: String, default: Variant) -> Variant:
	Prefs.get_value("audio", "master")   # makes sure the file is loaded
	return Prefs._cfg.get_value(section, key, Prefs.DEFAULTS.get(section, {}).get(key, default))


func _check(label: String, section: String, key: String, default: Variant = null) -> CheckBox:
	var c := NC.toggle(_group, label, bool(_pv(section, key, default if default != null else false)), func(on: bool):
		Prefs.set_value(section, key, on)
		_after_change(section))
	_note_first(c)
	return c


func _slider(label: String, section: String, key: String, lo: float, hi: float, step: float,
		fmt: Callable, disabled := false) -> HSlider:
	var s := NC.slider(_group, label, float(_pv(section, key, lo)), lo, hi, step, fmt, func(x: float):
		Prefs.set_value(section, key, x)
		_after_change(section))
	sliders[section + "." + key] = s
	if disabled:
		s.editable = false
		(s.get_meta("row") as Control).modulate.a = 0.5
	_note_first(s)
	return s


func _menu(label: String, section: String, key: String, options: Array, default_i := 0) -> OptionButton:
	var o := NC.menu(_group, label, options, int(_pv(section, key, default_i)), func(i: int):
		Prefs.set_value(section, key, i)
		_after_change(section))
	_note_first(o)
	return o


func _button(label: String, cb: Callable, icon := "") -> Button:
	var b := NC.form_button(_group, label, icon, cb)
	_note_first(b)
	return b


func _caption(text: String) -> Label:
	var h := NC.caption(null, text)
	_group.add_row(h, 0.0)
	return h


# TODO(wiring) rows: the Apple row exists, the engine does not read it yet. The value persists to
# Prefs [apple] under the Apple GameSettings property name (snake_case).
func _todo_note(title_text: String, key: String) -> void:
	todo_rows.append("%s / %s -> apple.%s" % [PAGE_TITLES.get(page, page), title_text, key])


func _apple_check(label: String, key: String, default := false) -> CheckBox:
	_todo_note(label, key)
	return _check(label, "apple", key, default)


func _apple_slider(label: String, key: String, lo: float, hi: float, step: float, fmt: Callable,
		default := 1.0, disabled := false) -> HSlider:
	_todo_note(label, key)
	var s := NC.slider(_group, label, float(_pv("apple", key, default)), lo, hi, step, fmt, func(x: float):
		Prefs.set_value("apple", key, x)
		_mark_changed())
	sliders["apple." + key] = s
	if disabled:
		s.editable = false
		(s.get_meta("row") as Control).modulate.a = 0.5
	_note_first(s)
	return s


func _apple_menu(label: String, key: String, options: Array, default_i := 0) -> OptionButton:
	_todo_note(label, key)
	return _menu(label, "apple", key, options, default_i)


## A menu bound to an enum pref stored as a String (Apple's raw values, docs/GODOT_SETTINGS_KEYS.md).
func _enum_menu(label: String, section: String, key: String, values: Array, labels: Array) -> OptionButton:
	var cur := str(Prefs.get_value(section, key))
	var o := NC.menu(_group, label, labels, maxi(0, values.find(cur)), func(i: int):
		Prefs.set_value(section, key, values[i])
		_after_change(section))
	_note_first(o)
	return o


## A segmented picker bound to an enum pref stored as a String.
func _enum_segmented(section: String, key: String, values: Array, labels: Array) -> HBoxContainer:
	var h := NC.segmented(_group, labels, maxi(0, values.find(str(Prefs.get_value(section, key)))), func(i: int):
		Prefs.set_value(section, key, values[i])
		_after_change(section))
	_note_first(h.get_meta("buttons")[0])
	return h


func _apple_segmented(key: String, options: Array, default_i: int) -> HBoxContainer:
	_todo_note("segmented " + key, key)
	var h := NC.segmented(_group, options, int(_pv("apple", key, default_i)), func(i: int):
		Prefs.set_value("apple", key, i)
		_mark_changed())
	_note_first(h.get_meta("buttons")[0])
	return h


func _after_change(section: String) -> void:
	if section == "video":
		Prefs.apply_video()
	elif section == "input":
		Controls.register()
	_mark_changed()


func _pct(x: float) -> String:
	return "%d%%" % roundi(x * 100.0)


func _rebuild() -> void:
	show_page.call_deferred(page)


# --- Interface (Presentation) ----------------------------------------------------------

const PRESET_BLURB := {
	"classic": "The faithful EV Nova look, rendered from your own game data.",
	"enhanced": "Classic, with the galaxy map opened up to full screen.",
	"nova_swift": "The port's own modern interface — modern menu, dialogs and HUD.",
	"custom": "Your own mix of interface options.",
}


func _build_presentation() -> void:
	var mode: String = Prefs.ui_mode()
	_section("Presentation", PRESET_BLURB[mode] + " Presets are templates — pick one to set the interface options below, then fine-tune any of them individually.", "sparkles.tv")
	# Nova Swift is only offered to someone already using it; Custom only reflects a hand-mixed state.
	var keys: Array = [Prefs.UI_CLASSIC, Prefs.UI_ENHANCED]
	var names: Array = ["Classic", "Enhanced"]
	if mode == Prefs.UI_NOVA_SWIFT:
		keys.append(Prefs.UI_NOVA_SWIFT)
		names.append("Nova Swift")
	keys.append(Prefs.UI_CUSTOM)
	names.append("Custom")
	var h := NC.segmented(_group, names, keys.find(mode), func(i: int):
		if keys[i] == Prefs.UI_CUSTOM:
			(func(): show_page(page)).call_deferred()
			return
		Prefs.apply_ui_mode(keys[i])
		_mark_changed()
		_rebuild())
	_note_first(h.get_meta("buttons")[0])
	if ClassicTheme.has_data():
		_button("Original Preferences Window…", open_classic_preferences, "macwindow")
	_section("Interface Options", "Mix the port's modern touches over the authentic EV Nova presentation. Full-screen map opens the galaxy map without its dialog frame. The sidebar pause menu (on by default) opens the port's own menu, with the Story Guide and, in debug mode, the Debug Suite; off, pausing opens the original's plain pause dialog. Storyline tags mark missions that continue a reconstructed campaign and jump to it in the Story Guide — an aftermarket hint the original game never had.", "slider.horizontal.3")
	for t in [["Full-screen galaxy map", "fullscreen_galaxy_map"], ["Modern main menu", "modern_menu"],
			["Modern dialog chrome", "modern_dialogs"], ["Modern HUD", "modern_hud"]]:
		var c := _check(t[0], "presentation", t[1])
		c.toggled.connect(func(_on: bool): _rebuild())
	# Sidebar pause menu: read by screens/PauseMenu.gd (Prefs interface/sidebar_pause_menu, default on).
	_check("Sidebar pause menu", "interface", "sidebar_pause_menu")
	_check("Show mission storyline tags", "story", "show_mission_storyline_tags", true)


## On-screen HUD readouts and their look (Apple hudInterfaceSection). Keys: docs/GODOT_SETTINGS_KEYS.md.
func _build_hud_interface() -> void:
	_section("HUD & Interface", "On-screen readouts and their look, in every presentation. Hull/shield bars over ships weren't in the original — set them to Hidden for the authentic look, and the original never labelled planets in flight either. Larger and high-contrast HUD affect the modern HUD; UI scale resizes menus and dialogs everywhere.", "rectangle.on.rectangle")
	_check("Show radar", "interface", "show_radar")
	_check("Show planet names", "graphics", "show_planet_labels")          # key only: no stellar labels drawn yet
	_enum_menu("Hull / shield bars", "graphics", "ship_bar_position", ["above", "below", "off"], ["Above Ships", "Below Ships", "Hidden"])   # key only
	_slider("HUD opacity", "interface", "hud_opacity", 0.2, 1.0, 0.05, _pct)
	_check("Larger HUD", "accessibility", "larger_hud")
	_check("High-contrast HUD", "accessibility", "high_contrast_hud")
	_slider("Overall UI scale", "interface", "ui_scale", 0.8, 1.4, 0.05, _pct)
	_check("Show FPS counter", "graphics", "show_fps")


## The original's Preferences window (DLOG 4003) over Settings; Settings comes back, focused, when
## it closes.
func open_classic_preferences() -> Node:
	if classic_prefs != null:
		return classic_prefs
	# Overlay, not replacement: Settings stays drawn underneath (inert) while the original window is up.
	var tok := Inert.hold(_root)
	classic_prefs = ClassicPreferences.new()
	add_child(classic_prefs)
	classic_prefs.setup(_nova)
	classic_prefs.changed.connect(_mark_changed)
	classic_prefs.key_settings.connect(func():
		(func(): show_page("Controls")).call_deferred())
	classic_prefs.closed.connect(func():
		classic_prefs = null
		Inert.release(tok)
		show_page(page))
	return classic_prefs


# --- Gameplay -------------------------------------------------------------------------------

func _build_gameplay() -> void:
	_section("Gameplay", "Game speed sets the overall pace — Authentic is the faithful, unhurried EV Nova cruise; drop to 0.5× for more room to react in a dogfight, or step it up to 8× when you'd rather not wait. Every speed applies the rules of EV Nova's own Caps Lock 2× mode (jumps take the same real time, beams hit as often) at its own multiplier, and turning Caps Lock on in flight doubles whichever speed you pick, as in the original; a co-op session uses the host's speed and ignores Caps Lock. Auto-target locks onto the nearest hostile the moment you open fire. Tutorial hints show one-time tips as you play — “Show all hints again” brings them back. Difficulty, traffic and other options the original didn't have are under Enhancements.", "gamecontroller")
	_enum_segmented("gameplay", "game_speed", ["x0_5", "x1", "x1_5", "x2", "x4", "x8"], ["0.5×", "Authentic", "1.5×", "2×", "4×", "8×"])
	_check("Auto-target after firing", "gameplay", "auto_target_after_firing")
	_check("Confirm before landing", "gameplay", "confirm_landing")
	var hc := _check("Tutorial hints", "hints", "enabled")
	hc.toggled.connect(func(_on: bool): _rebuild())
	if Prefs.hints_enabled():
		_button("Show all hints again", func():
			Prefs.reset_hints()
			_status.text = "Hints will show again.")
	if allow_training:
		_button("Flight Training", func(): training_requested.emit(), "graduationcap")
	_check("Pause when app loses focus", "gameplay", "pause_on_focus_loss")


# --- Enhancements ---------------------------------------------------------------------------

func _manual_order_handle() -> Object:
	if _pl == null and ClassDB.class_exists("NovaPlugins") and _nova != null:
		_pl = ClassDB.instantiate("NovaPlugins")
		_pl.attach(_nova)
	return _pl


## The GameplayEnhancements catalog, one row per behaviour the original lacks (Apple
## enhancementsSection): the toggle plus its one-line "replaces" caption.
func _enhancement(title_text: String, replaces: String, section: String, key: String, live: bool,
		rebuild := false) -> void:
	var holder := VBoxContainer.new()
	holder.add_theme_constant_override("separation", 2)
	var c: CheckBox
	if live:
		c = NC.toggle(holder, title_text, bool(_pv(section, key, false)), func(on: bool):
			Prefs.set_value(section, key, on)
			_after_change(section))
		if rebuild:
			c.toggled.connect(func(_on: bool): _rebuild())
	else:
		_todo_note(title_text, key)
		c = NC.toggle(holder, title_text, bool(_pv(section, key, false)), func(on: bool):
			Prefs.set_value(section, key, on)
			_mark_changed())
	NC.caption(holder, replaces)
	_group.add_row(holder, 0.0)
	_note_first(c)


func _build_enhancements() -> void:
	_section("Enhancements", "Behaviours NovaSwift adds that the original EV Nova doesn't have. Each is off by default, so the game plays as the original did unless you turn one on.", "wand.and.stars")
	var pl := _manual_order_handle()
	var holder := VBoxContainer.new()
	holder.add_theme_constant_override("separation", 2)
	var mo := NC.toggle(holder, "Manual plug-in order", pl != null and bool(pl.manual_order()), func(on: bool):
		if pl != null:
			pl.set_manual_order(on)
			_mark_changed())
	NC.caption(holder, "Pick which plug-ins load and in what order. The original loads every installed plug-in, alphabetically.")
	_group.add_row(holder, 0.0)
	_note_first(mo)
	# Keys: gameplay/* (docs/GODOT_SETTINGS_KEYS.md). Quick hyperjump persists but the bridge does not fly it yet.
	_enhancement("Tight formations", "Escorts and fleet wings hold formation precisely. In the original they fly their own hull's momentum.", "gameplay", "formation_flying", true)
	_enhancement("Forgiving landing", "Land from a wider circle around a planet at a higher speed. The original needs you almost stopped over it.", "gameplay", "forgiving_landing", true)
	_enhancement("Quick hyperjump", "Jump after a short turn and burst. The original brakes to a stop, then spins up for the length of its warp-up sound.", "gameplay", "quick_hyperjump", true)
	_enhancement("Frequent autosave", "Save on every jump, every few minutes and when the app goes to the background. The original saves only when you leave a spaceport, so dying or quitting in flight rolls you back.", "gameplay", "frequent_autosave", true)
	_enhancement("Automatic route plotting", "Tap any system on the map to plot the shortest course there. In the original you click a neighbouring system, and Shift-click to add each further jump yourself.", "gameplay", "auto_route_plotting", true)
	_enhancement("Nearest-first targeting", "Target cycling starts with the closest ship and wraps around. In the original it goes in arrival order, ends at No Target, and reaches every ship in the system.", "gameplay", "nearest_first_targeting", true)
	_enhancement("Modern key layout", "Return fires secondaries, Shift is the afterburner and P pauses, applied when you reset the keys. The original layout uses Control, Z and P for Player Info.", "input", "modern_keys", true, true)
	_enhancement("Screen shake", "The view shakes when something blows up nearby. The original never moves the camera.", "graphics", "screen_shake", true)
	# Godot-only: the galaxy map's gate spokes (an enhancement the original lacks).
	_enhancement("Gate links on the galaxy map", "Draw hypergate and wormhole spokes on the plain galaxy map. The original draws them only in the gate picker.", "map", "gate_links", true)
	_section("Port Options", "System Aliveness controls how much traffic systems carry and how often ships land — Original is the exact original game; Quiet is the closest to its pace on the port's model; Normal and Bustling are livelier.", "slider.horizontal.3")
	_enum_menu("Difficulty", "gameplay", "difficulty", ["veryEasy", "easy", "normal", "hard"], ["Very Easy", "Easy", "Normal", "Hard"])
	_caption("Scales the damage you take. The original has no setting; Normal matches it.")
	_enum_menu("System Aliveness", "gameplay", "system_aliveness", ["original", "authentic", "normal", "bustling"], ["Original", "Quiet", "Normal", "Bustling"])
	_caption("Exactly the original game's traffic: the system's average ship count, with arrivals trickling in.")
	_check("Auto-landing", "gameplay", "auto_landing")
	_caption("Pressing Land flies you to the target and sets down. The original has no autopilot.")


# --- Controls ------------------------------------------------------------------------

func _build_controls() -> void:
	_section("Controls", "The dead zone is how far a stick or drag must move before it registers. Sticks and triggers are fixed; the keys and pad buttons below can be rebound.", "dpad")
	_slider("Stick dead zone", "input", "deadzone", 0.0, 0.5, 0.01, _pct)
	# The gamepad UI cursor (ui/PadCursor.gd): left stick pointer, A click, right stick scroll.
	_check("Controller cursor", "input", "pad_cursor", true)
	_slider("Controller cursor speed", "input", "cursor_speed", 0.4, 2.0, 0.05, _pct)
	# Haptic feedback has no Godot key (docs/GODOT_SETTINGS_KEYS.md: n/a); the row stays as Apple draws it.
	_check("Invert turn direction", "input", "invert_turn")
	_apple_check("Haptic feedback", "haptics_enabled", true)
	_check("Aim toward mouse cursor", "input", "mouse_aiming")
	var modern := _check("Modern key layout (the port's earlier keys)", "input", "modern_keys")
	modern.toggled.connect(func(_on: bool): _rebuild())
	_section("Key & Button Bindings", "A visual editor: a rendered keyboard (Full, Tenkeyless or Compact) and a controller (Xbox, PlayStation, Switch Pro or Steam Deck). Pick a key or button to see and change what it does, or pick an action and press the key or button you want.", "keyboard")
	_button("Open Controls Editor", open_controls_editor, "keyboard")
	_section("")
	_button("Reset Controls to Defaults", func():
		Prefs.reset_section("input")
		Prefs.reset_bindings()
		Controls.register()
		_mark_changed()
		show_page("Controls"), "arrow.counterclockwise")


## Opens the full-window Controls Editor over Settings (hidden meanwhile); returns it.
func open_controls_editor() -> Node:
	if controls_editor != null and is_instance_valid(controls_editor):
		return controls_editor
	var ed: Node = ControlsEditor.new()
	controls_editor = ed
	_root.visible = false
	ed.closed.connect(func():
		controls_editor = null
		if is_instance_valid(_root):
			_root.visible = true
		_dirty = true
		changed.emit()
		if page == "Controls":
			show_page("Controls"))
	add_child(ed)
	ed.setup()
	return ed


# --- Graphics ------------------------------------------------------------------------

func _build_video() -> void:
	_section("Graphics", "Camera zoom is world pixels shown per screen point; 1.0 is the original's own native scale (higher shows more of the system at once, everything reading smaller). Camera view changes only how flight is framed: Classic is the original's fixed, north-up view; Look ahead drifts the view toward where you're heading; Ship up turns the view with your ship; Chase, with live 3D ships, lays the view back behind your ship (falls back to Ship up without them). Ships fly and fight the same in every view. In flight, O changes the view and [ and ] zoom. EV Nova's art is pixel art — leave smooth scaling off for the crisp, faithful look. Hyperspace jumps fade to white as on the Mac; the Windows look skips the fade and only flashes.", "sparkles")
	# Quality presets and the HD / 3D rows have no Godot key (HD pipeline not ported): drawn, stored
	# under [apple], not read. Everything else is bound to docs/GODOT_SETTINGS_KEYS.md.
	_apple_segmented("graphics_quality", ["Low", "Medium", "High", "Ultra"], 2)
	_slider("Starfield density", "graphics", "starfield_density", 0.2, 2.0, 0.05, _pct)
	_slider("Camera zoom", "graphics", "camera_zoom", 0.5, 3.0, 0.05, _pct)
	var cv := _menu("Camera view", "graphics", "camera_view", ["Classic", "Look ahead", "Ship up", "Chase"], 0)
	cv.item_selected.connect(func(_i: int): _rebuild())
	if int(_pv("graphics", "camera_view", 0)) == 3:
		_slider("Chase camera tilt", "graphics", "chase_tilt", 0.0, 60.0, 1.0, func(x: float): return "%d°" % roundi(x))
	_enum_menu("Frame rate limit", "graphics", "frame_rate_cap", ["fps30", "fps60", "fps120", "unlimited"], ["30 FPS", "60 FPS", "120 FPS", "Unlimited"])
	_check("Smooth sprite scaling", "graphics", "smooth_sprites")
	_apple_check("HD graphics from plug-ins", "hd_graphics")
	if bool(_pv("apple", "hd_graphics", false)):
		_apple_menu("HD detail", "hd_detail", ["Low (1×)", "Standard (2×)", "Sharp (4×)"], 1)
		_apple_menu("Ships with 3D models", "hull_presentation", ["Sprites", "Full live 3D"], 0)
	_enum_menu("Particle effects", "graphics", "particle_density", ["full", "reduced", "minimal"], ["Full", "Reduced", "Minimal"])
	_check("Engine & weapon glow", "classic", "engine_glow")
	_check("Windows hyperspace look", "graphics", "ce_hyperspace_look")
	_check("Hyperspace effects", "classic", "hyperspace_effects")
	_section("Window", "Window scale applies when not fullscreen. The play area adapts to 16:9 and 16:10 (Steam Deck) screens.", "macwindow")
	_check("Fullscreen", "video", "fullscreen")
	_check("VSync", "video", "vsync")
	_slider("Window scale", "video", "scale", 0.75, 2.0, 0.25,
		func(x: float): return "%dx%d" % [roundi(1280 * x), roundi(720 * x)])


# --- Audio ---------------------------------------------------------------------------

func _build_audio() -> void:
	_section("Audio", "Master is the original's sound-volume step and scales everything; Effects and Interface balance weapon/engine sounds and interface beeps beneath it. The title music plays once over the main menu only, as in the original (if your data has the track as an mp3); its slider only turns it off at 0.", "speaker.wave.2")
	var mute := _check("Mute all", "audio", "muted")
	_slider("Master", "audio", "master", 0.0, 1.0, 0.05, _pct)
	_slider("Music", "audio", "music", 0.0, 1.0, 0.05, _pct)
	_slider("Effects", "audio", "sfx", 0.0, 1.0, 0.05, _pct)
	_slider("Interface", "audio", "ui", 0.0, 1.0, 0.05, _pct)
	_check("Background music", "audio", "music_enabled")
	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 8)
	var beep := NC.button("Test Beep", "form", func():
		if _nova != null and _nova.has_method("sound_beep"):
			_nova.sound_beep(1), "speaker.wave.2")
	hb.add_child(beep)
	_group.add_row(hb)
	mute.toggled.connect(func(on: bool):
		for k in ["audio.master", "audio.music", "audio.sfx", "audio.ui"]:
			if sliders.has(k):
				(sliders[k] as HSlider).editable = not on
				((sliders[k] as HSlider).get_meta("row") as Control).modulate.a = 0.5 if on else 1.0)
	if mute.button_pressed:
		mute.toggled.emit(true)


# --- Accessibility ----------------------------------------------------------------------

func _build_accessibility() -> void:
	_section("Accessibility", "Reduce flashing calms the exhaust flicker, screen shake and jump flash. (Larger HUD, high-contrast HUD and UI scale are under HUD & Interface.)", "accessibility")
	_check("Reduce flashing & motion", "graphics", "reduce_flashing")
	_enum_menu("Colorblind mode", "accessibility", "colorblind_mode", ["none", "protanopia", "deuteranopia", "tritanopia"], ["Off", "Protanopia (red-weak)", "Deuteranopia (green-weak)", "Tritanopia (blue-weak)"])


# --- Data & Advanced (Support) ---------------------------------------------------------

func _build_support() -> void:
	_section("Saved Games", "Pilots are ordinary .evpilot files — copy them, back them up, or open one from anywhere with Open Pilot. Changing the folder copies the pilots already in the old one across (the originals stay). Rotating backups live in a Backups folder beside them. There is no iCloud here: the Apple app's iCloud pilot and game-data sync rows do not exist on this platform.", "externaldrive")
	var r := NC.value_row(_group, "Saved to", PilotFiles.dir())
	r.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	r.custom_minimum_size = Vector2(340, 0)
	r.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	r.add_theme_font_size_override("font_size", 13)
	_button("Open Pilots Folder", func(): OS.shell_show_in_file_manager(PilotFiles.dir()), "folder")
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
	_button("Re-import / Change Game Data…", func(): data_setup_requested.emit(), "square.and.arrow.down")
	_build_updates()
	_section("Support", "Builds a report you can share: your description plus the pilot save, the recent game log and a self-test — the state that's hard to describe in a message. None of your imported EV Nova data is included.", "lifepreserver")
	_button("Report a Bug…", func(): get_tree().call_group("nova_devtools", "open_tab", "report"), "ladybug")
	_button("Report on GitHub…", func(): ErrorReport.open_issue("[Godot %s] Bug report" % ErrorReport.version(), "(describe the problem here)"), "ladybug")
	_button("Open Logs Folder", ErrorReport.open_logs_folder, "folder")
	_button("About NovaSwift", _show_about, "info.circle")
	_section("Developer", "Shows an in-game debug button that opens the debug suite: the UI measurement overlay, a performance stress test, and more developer tools as we build them. Preview Setup Wizard replays the full first-run data guide from the top, even with data already imported.", "hammer")
	var dev := NC.toggle(_group, "Debug mode", bool(Prefs.get_value("developer", "debug_mode")), func(on: bool):
		Prefs.set_value("developer", "debug_mode", on)
		_mark_changed()
		_rebuild())
	_note_first(dev)
	if dev.button_pressed:
		_button("Open Debug Suite", func(): get_tree().call_group("nova_devtools", "open_tab", "console"), "ladybug")
		_button("Preview Setup Wizard", func(): data_setup_preview_requested.emit(), "sparkles")


## Auto-updater switches (godot/updater/, docs/UPDATER.md). Keys: updates/check, updates/beta.
func _build_updates() -> void:
	_section("Updates", "NovaSwift looks for a newer release when the main menu opens, at most once a day, and asks before downloading anything. Updates are signed; anything that does not verify is refused. Experimental updates also offers test builds that may be unstable or break saves.", "arrow.clockwise")
	_check("Check for updates", "updates", "check", true)
	_check("Experimental updates", "updates", "beta", false)
	_caption("Also offer test builds that may be unstable or break saves. Back up your pilots. Turning this off while on an experimental build offers a return to the newest stable version.")
	NC.value_row(_group, "Version", str(ProjectSettings.get_setting("application/config/version", "0.7.0")))
	NC.value_row(_group, "Last checked", UpdateController.last_check_text())
	var why: String = UpdateController.disabled_reason()
	if why != "":
		_caption(why)
	_button("Check Now", func(): get_tree().call_group("nova_updater", "check_now"), "arrow.clockwise")


## Apple AboutView: the data's own About text over the NovaSwift header in the generic dësc dialog.
func _show_about() -> void:
	var version := str(ProjectSettings.get_setting("application/config/version", "0.7.0"))
	if ClassicTheme.has_data() and _nova != null and _nova.has_method("about_nova_text"):
		var pict: int = int(_nova.classic_desc_graphic(32767)) if _nova.has_method("classic_desc_graphic") else -1
		var d = ClassicDialog.desc_dialog(_nova, _nova.about_nova_text(version), pict)
		var host: Control = ClassicDialog.modal(self, d, 0.6)
		d.activated.connect(func(_i): if is_instance_valid(host): host.queue_free())
	else:
		Alert.show(self, {"title": "About NovaSwift", "message": "NovaSwift %s — a free, unofficial port by Joshua Kac (SirStig). Not affiliated with or endorsed by Ambrosia Software or ATMOS. github.com/SirStig/NovaSwift" % version})


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


## Sidebar "Reset All Settings": the same destructive confirm Apple raises.
func _reset_all_confirm() -> void:
	Alert.show(self, {"title": "Reset every setting to its default?", "buttons": [
		{"title": "Cancel", "role": "cancel"},
		{"title": "Reset All", "role": "destructive", "cb": _reset_all}]})


func _reset_all() -> void:
	for sec in ["audio", "video", "map", "input", "story", "presentation", "classic", "graphics", "gameplay", "interface", "accessibility"]:
		Prefs.reset_section(sec)
	# The [apple] rows without a Godot key: drop what was stored so every row reads its default again.
	Prefs._cfg.erase_section("apple")
	Prefs.reset_bindings()
	Controls.register()
	Prefs.apply_video()
	_dirty = true
	changed.emit()
	show_page(page)
	_status.text = "All settings restored to their defaults."


func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("ui_cancel") and _root.visible:
		get_viewport().set_input_as_handled()
		close()
