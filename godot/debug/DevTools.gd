# NOVA Swift — the Debug Suite host (port of app/NovaSwift/Debug/: DevConsoleView, DevToolsPane,
# DebugController, DebugMetricsChip, FrameProfiler/PerfMonitor feeds). See docs/GODOT_LAYER.md
# "Debug suite".
#
# One CanvasLayer owned by Main.gd (and queried by Settings / the pause menu through the
# "nova_devtools" group). It always captures the log (engine `Logging` output via the Swift ring
# buffer + Godot's own log via DevLogger) so a bug report has history even if debug mode was
# never on. Everything else is gated by the `debugModeEnabled` setting (Prefs developer/debug_mode,
# Settings > Support > Developer), exactly as on Apple: with it off there is no hotkey, no chip,
# no pause-menu entry. "Report a Bug" is NOT gated (Apple: Settings > Support).
#
# Opening it (debug mode on):  F12  ·  Ctrl/Cmd+`  ·  both pad sticks clicked (L3+R3)  ·
# pause menu > Debug Suite  ·  Settings > Support > Open Debug Suite  ·  the corner chip.
# While open, flight input is not read (Main.gd asks captures_input()) but the sim keeps running
# underneath so the readouts stay live. Esc / pad B closes; pad LB/RB switch tabs.
extends CanvasLayer

const DevUI = preload("res://debug/DevUI.gd")
const Prefs = preload("res://Prefs.gd")
const DevLogger = preload("res://debug/DevLogger.gd")
const ConsolePane = preload("res://debug/ConsolePane.gd")
const ToolsPane = preload("res://debug/ToolsPane.gd")
const StatePane = preload("res://debug/StatePane.gd")
const BitsPane = preload("res://debug/BitsPane.gd")
const BrowserPane = preload("res://debug/BrowserPane.gd")
const ChecksPane = preload("res://debug/ChecksPane.gd")
const ReportPane = preload("res://debug/ReportPane.gd")
const Overlay = preload("res://debug/DevOverlay.gd")
const HDViewer = preload("res://debug/HDViewer.gd")

signal opened
signal closed

# [id, label, SF-symbol-style glyph (NovaSVG)] -- the glyphs are Apple's DevConsoleTab.systemImage.
const TABS := [
	["console", "Console", "terminal.fill"], ["tools", "Tools", "slider.horizontal.3"],
	["state", "State", "person.text.rectangle"], ["bits", "Bits", "switch.2"],
	["ships", "Ships", "airplane"], ["outfits", "Outfits", "shippingbox.fill"],
	["govts", "Govts", "flag.fill"], ["checks", "Checks", "checklist"],
	["report", "Report", "ladybug.fill"],
]
## Panes that live in the right-hand inspector rail on a wide panel (Apple's inspectorCases);
## state / checks / report take the full width; the console is the left half.
const RAIL_TABS := ["tools", "bits", "ships", "outfits", "govts"]
const FULL_TABS := ["state", "checks", "report"]
const WIDE_BREAKPOINT := 900.0
const WINDOW := 0.5                 # metrics window, seconds
const SPIKE_MS := 33.0              # a frame over this reads as a hitch

## Set by Main: true only during live in-flight gameplay (the corner chip shows only then).
var flight_live := Callable()
var dbg: Object                     # NovaDebug (bridge), null when the extension is older
var nova: Object                    # NovaWorld
var is_open := false
var current := "console"
## Latest profile_snapshot() as a Dictionary (fps, frame ms, phases, spike...).
var snapshot := {}

var _to_screen := Callable()
var _logger: Logger
var _root: Control
var _panel: PanelContainer
var _tab_buttons := {}
var _scrim: ColorRect
var _title: Label
var _metrics_label: Label
var _metrics_dot: Control
var _tabs_row: HBoxContainer
var _wide := true
var _rail_tab := "tools"
var _left: Control
var _rail: PanelContainer
var _rail_in: Control
var _full: Control
var _split: HBoxContainer
var _body: Control
var _tween: Tween
var _panes := {}
var _overlay: Control
var _chip: Control
var _chip_label: Button
var _ctx: Control
var _hd: Node
var _released_frame := -100
var _win_time := 0.0
var _win_frames := 0
var _win_worst := 0.0
var _last_flags := {}
var _stick_l := false
var _stick_r := false


func setup(nova_obj: Object, to_screen_cb := Callable()) -> void:
	nova = nova_obj
	_to_screen = to_screen_cb
	layer = 100
	add_to_group("nova_devtools")
	process_mode = Node.PROCESS_MODE_ALWAYS
	# Godot's own log -> queue -> Swift ring buffer (OS.add_logger exists since Godot 4.5).
	_logger = DevLogger.new()
	OS.add_logger(_logger)
	if ClassDB.class_exists("NovaDebug"):
		dbg = ClassDB.instantiate("NovaDebug")
		dbg.attach(nova)
		dbg.log_start()
	_build_overlay()
	_build_chip()
	_build_panel()
	if debug_enabled() and dbg != null and bool(Prefs.get_value("developer", "ui_debug_overlay")):
		dbg.console_run("uidebug on")
	_apply_visibility()


func _exit_tree() -> void:
	if _logger != null:
		OS.remove_logger(_logger)
		_logger = null


# --- gating ---------------------------------------------------------------------

## Apple GameSettings.debugModeEnabled (Settings > Developer > Debug mode).
func debug_enabled() -> bool:
	return bool(Prefs.get_value("developer", "debug_mode"))


## True while flight input must not be read: the suite is open (or closed this very frame, so
## the key that closed it is not also read as a flight command).
func captures_input() -> bool:
	var viewer := _hd != null and is_instance_valid(_hd)
	return is_open or viewer or _ctx != null or Engine.get_process_frames() <= _released_frame


## Run a console line; returns [{kind, text}] (the pane shows them via the shared log).
func run(line: String) -> Array:
	if dbg == null:
		return []
	var out = JSON.parse_string(dbg.console_run(line))
	if _panes.has("console"):
		_panes["console"].on_command(line)
	return out if out is Array else []


## Right-click / long-press menu (Apple DevContextMenu). `pick` is nova.dbg_pick JSON.
func show_context(pick: Dictionary, at: Vector2) -> void:
	dismiss_context()
	if not debug_enabled() or dbg == null:
		return
	var kind := str(pick.get("kind", ""))
	if kind != "ship" and kind != "stellar":
		return
	var id := int(pick.get("id", -1))
	var title := str(pick.get("name", ""))
	if title == "":
		title = "#%d" % id
	var catcher := Control.new()
	catcher.set_anchors_preset(Control.PRESET_FULL_RECT)
	catcher.mouse_filter = Control.MOUSE_FILTER_STOP
	catcher.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed:
			get_viewport().set_input_as_handled()
			dismiss_context())
	add_child(catcher)
	_ctx = catcher
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(150, 0)
	panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(0, 0, 0, 0.95)
	sb.border_color = Color(DevUI.GREEN.r, DevUI.GREEN.g, DevUI.GREEN.b, 0.5)
	sb.set_border_width_all(1)
	sb.set_corner_radius_all(10)
	sb.content_margin_left = 10
	sb.content_margin_right = 10
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	sb.shadow_color = Color(0, 0, 0, 0.5)
	sb.shadow_size = 8
	panel.add_theme_stylebox_override("panel", sb)
	catcher.add_child(panel)
	var box := VBoxContainer.new()
	box.add_theme_constant_override("separation", 5)
	panel.add_child(box)
	var head := DevUI.label(box, title, 11, DevUI.GREEN)
	head.add_theme_font_override("font", DevUI.mono())
	head.clip_text = true
	var actions: Array = []
	if kind == "ship":
		actions = [
			["Select", "select ship %d" % id, false],
			["Disable", "disable %d" % id, false],
			["Capture", "capture %d" % id, false],
			["Destroy", "destroy %d" % id, true],
		]
	else:
		actions = [
			["Select", "select spob %d" % id, false],
			["Conquer", "conquer %d" % id, false],
		]
	for action in actions:
		var b := Button.new()
		b.text = action[0]
		b.flat = true
		b.alignment = HORIZONTAL_ALIGNMENT_LEFT
		b.focus_mode = Control.FOCUS_ALL
		b.add_theme_font_override("font", DevUI.mono())
		b.add_theme_font_size_override("font_size", 11)
		b.add_theme_color_override("font_color", DevUI.RED if action[2] else Color(1, 1, 1))
		b.pressed.connect(_ctx_run.bind(str(action[1])))
		box.add_child(b)
	panel.reset_size()
	var vp := get_viewport().get_visible_rect().size
	var sz := panel.get_combined_minimum_size()
	panel.position = Vector2(clampf(at.x, 8, maxf(8, vp.x - sz.x - 8)), clampf(at.y, 8, maxf(8, vp.y - sz.y - 8)))
	if box.get_child_count() > 1 and box.get_child(1) is Control:
		box.get_child(1).grab_focus()


func dismiss_context() -> void:
	if _ctx != null and is_instance_valid(_ctx):
		_ctx.queue_free()
	_ctx = null


func _ctx_run(command: String) -> void:
	run(command)
	dismiss_context()


func open_hd_viewer() -> void:
	if dbg == null or not debug_enabled():
		return
	if _hd != null and is_instance_valid(_hd):
		return
	_hd = HDViewer.new()
	add_child(_hd)
	_hd.setup(self)
	_hd.closed.connect(func() -> void: _hd = null)


# --- open / close ----------------------------------------------------------------

func open_tab(tab: String) -> void:
	if tab != "report" and not debug_enabled():
		return
	if dbg == null:
		return
	is_open = true
	_set_shown(true)
	_show_tab(tab)
	_apply_visibility()
	opened.emit()


func toggle_console() -> void:
	if is_open:
		close()
	else:
		open_tab("console")


func close() -> void:
	dismiss_context()
	if _hd != null and is_instance_valid(_hd):
		_hd.queue_free()
		_hd = null
	if not is_open:
		return
	is_open = false
	_set_shown(false)
	_released_frame = Engine.get_process_frames()
	var f := get_viewport().gui_get_focus_owner()
	if f != null:
		f.release_focus()
	_apply_visibility()
	closed.emit()


func _apply_visibility() -> void:
	var live: bool = not flight_live.is_valid() or bool(flight_live.call())
	_chip.visible = debug_enabled() and not is_open and dbg != null and live
	_overlay.visible = debug_enabled() and dbg != null


# --- input -----------------------------------------------------------------------

func _input(event: InputEvent) -> void:
	if event is InputEventKey and event.pressed and not event.echo:
		var toggle: bool = event.keycode == KEY_F12 \
			or (event.keycode == KEY_QUOTELEFT and event.is_command_or_control_pressed())
		if toggle and debug_enabled() and dbg != null:
			get_viewport().set_input_as_handled()
			toggle_console()
			return
		if event.keycode == KEY_ESCAPE and _ctx != null:
			get_viewport().set_input_as_handled()
			dismiss_context()
			return
		if is_open and event.keycode == KEY_ESCAPE:
			get_viewport().set_input_as_handled()
			close()
			return
		if is_open and event.ctrl_pressed and (event.keycode == KEY_PAGEDOWN or event.keycode == KEY_PAGEUP):
			get_viewport().set_input_as_handled()
			_step_tab(1 if event.keycode == KEY_PAGEDOWN else -1)
			return
	elif event is InputEventJoypadButton:
		if event.button_index == JOY_BUTTON_LEFT_STICK:
			_stick_l = event.pressed
		elif event.button_index == JOY_BUTTON_RIGHT_STICK:
			_stick_r = event.pressed
		if event.pressed and _stick_l and _stick_r and debug_enabled() and dbg != null:
			toggle_console()
			return
		if is_open and event.pressed:
			if event.button_index == JOY_BUTTON_B:
				get_viewport().set_input_as_handled()
				close()
			elif event.button_index == JOY_BUTTON_LEFT_SHOULDER:
				get_viewport().set_input_as_handled()
				_step_tab(-1)
			elif event.button_index == JOY_BUTTON_RIGHT_SHOULDER:
				get_viewport().set_input_as_handled()
				_step_tab(1)


func _step_tab(delta: int) -> void:
	var ids := TABS.map(func(t): return t[0])
	var i: int = ids.find(current)
	_show_tab(ids[posmod(i + delta, ids.size())])


# --- per-frame -------------------------------------------------------------------

func _process(delta: float) -> void:
	if _chip != null:
		var live: bool = not flight_live.is_valid() or bool(flight_live.call())
		var want: bool = debug_enabled() and not is_open and dbg != null and live
		if _chip.visible != want:
			_chip.visible = want
	if _logger != null and dbg != null:
		for row in _logger.drain():
			dbg.log_append(row[0], "Godot", row[1])
	if dbg == null or not debug_enabled():
		return
	# Cheats/profiler wiring + frame profiler phases (Godot's own monitors; the engine's sim
	# sub-phases arrive through World.profiler inside the bridge).
	dbg.frame_tick(true)
	dbg.profile_record("godot process", Performance.get_monitor(Performance.TIME_PROCESS) * 1000.0)
	dbg.profile_record("godot physics", Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS) * 1000.0)
	dbg.profile_end_frame(SPIKE_MS)
	_win_time += delta
	_win_frames += 1
	_win_worst = maxf(_win_worst, delta * 1000.0)
	if _win_time >= WINDOW:
		var avg := _win_time / maxf(1.0, float(_win_frames)) * 1000.0
		var cpu := (Performance.get_monitor(Performance.TIME_PROCESS) + Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS)) * 1000.0
		dbg.metrics_report(float(Engine.get_frames_per_second()), avg, _win_worst, cpu,
			maxf(0.0, avg - cpu), float(OS.get_static_memory_usage()) / 1048576.0,
			int(Performance.get_monitor(Performance.OBJECT_NODE_COUNT)))
		var s = JSON.parse_string(dbg.profile_snapshot())
		if s is Dictionary:
			snapshot = s
		_win_time = 0.0
		_win_frames = 0
		_win_worst = 0.0
		_refresh_chip()
		_sync_prefs()
	_overlay.queue_redraw()
	if is_open:
		for k in _panes:
			var pn: Control = _panes[k]
			if pn.visible and pn.has_method("tick"):
				pn.tick(delta)


func _refresh_chip() -> void:
	if snapshot.is_empty():
		return
	var t := "%.0f fps · %d ships" % [float(snapshot.get("fps", 0)), int(snapshot.get("ships", 0))]
	if bool(snapshot.get("perfTest", false)):
		t += " · TEST"
	_chip_label.text = t
	var fps := float(snapshot.get("fps", 0))
	var c := DevUI.GREEN if fps >= 55.0 else (DevUI.AMBER if fps >= 30.0 else DevUI.RED)
	DevUI.style_chip(_chip_label, c, 14, Vector2(10, 4))
	if _metrics_label != null:
		_metrics_label.text = "%.0f fps · %.1f ms · %d ships" % [fps, float(snapshot.get("frameMsAvg", 0)), int(snapshot.get("ships", 0))]
		var st := StyleBoxFlat.new()
		st.bg_color = c
		st.set_corner_radius_all(8)
		_metrics_dot.add_theme_stylebox_override("panel", st)


## The measurement grid is a persisted setting on Apple (uiDebugOverlay); mirror console changes.
func _sync_prefs() -> void:
	var st = JSON.parse_string(dbg.state_json())
	if not (st is Dictionary) or not st.has("cheats"):
		return
	_last_flags = st["cheats"]
	var grid := bool(_last_flags.get("uidebug", false))
	if grid != bool(Prefs.get_value("developer", "ui_debug_overlay")):
		Prefs.set_value("developer", "ui_debug_overlay", grid)
		Prefs.save()


## Flags (god, fuel, ai, uidebug, perf) as of the last metrics window.
func flags() -> Dictionary:
	return _last_flags


func overlay_state() -> Dictionary:
	var st = JSON.parse_string(dbg.state_json()) if dbg != null else {}
	return st if st is Dictionary else {}


# --- UI --------------------------------------------------------------------------

func _build_overlay() -> void:
	_overlay = Overlay.new()
	_overlay.setup(self, _to_screen)
	var lay := CanvasLayer.new()
	lay.layer = 20
	lay.add_child(_overlay)
	add_child(lay)


func _build_chip() -> void:
	_chip = DevUI.hbox(null, 6)
	_chip.theme = DevUI.theme()
	_chip.position = Vector2(14, 68)
	var b := DevUI.button(_chip, "", func(): open_tab("console"), DevUI.GREEN, false, "terminal.fill")
	b.focus_mode = Control.FOCUS_NONE
	b.tooltip_text = "Developer Console (F12)"
	_chip_label = DevUI.button(_chip, "— fps", func(): open_tab("tools"), DevUI.GREEN)
	_chip_label.focus_mode = Control.FOCUS_NONE
	add_child(_chip)


func _build_panel() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = DevUI.theme()
	add_child(_root)
	# Backdrop scrim: dims the game and swallows clicks outside the panel (a click closes it).
	_scrim = ColorRect.new()
	_scrim.color = Color(0, 0, 0, 0.52)
	_scrim.set_anchors_preset(Control.PRESET_FULL_RECT)
	_scrim.mouse_filter = Control.MOUSE_FILTER_STOP
	_scrim.visible = false
	_scrim.gui_input.connect(func(ev: InputEvent) -> void:
		if ev is InputEventMouseButton and ev.pressed and ev.button_index == MOUSE_BUTTON_LEFT:
			close())
	_root.add_child(_scrim)
	_panel = PanelContainer.new()
	_panel.visible = false
	var sb := DevUI.panel_style(DevUI.PANEL_BG, DevUI.GREEN * Color(1, 1, 1, 0.38), 16)
	sb.content_margin_left = 0
	sb.content_margin_right = 0
	sb.content_margin_top = 0
	sb.content_margin_bottom = 0
	sb.shadow_color = Color(0, 0, 0, 0.6)
	sb.shadow_size = 28
	sb.shadow_offset = Vector2(0, 10)
	sb.anti_aliasing = true
	_panel.add_theme_stylebox_override("panel", sb)
	_panel.clip_contents = true
	_root.add_child(_panel)
	var v := DevUI.vbox(_panel, 0)

	# Header: icon tile + title, live metrics capsule, the tab strip, close.
	var head_bg := PanelContainer.new()
	var hs := DevUI.panel_style(Color(DevUI.GREEN.r, DevUI.GREEN.g, DevUI.GREEN.b, 0.05), Color(0, 0, 0, 0), 0)
	hs.content_margin_left = 14
	hs.content_margin_right = 12
	hs.content_margin_top = 9
	hs.content_margin_bottom = 9
	head_bg.add_theme_stylebox_override("panel", hs)
	v.add_child(head_bg)
	var bar := DevUI.hbox(head_bg, 10)
	var tile := PanelContainer.new()
	var ts := DevUI.panel_style(DevUI.GREEN, Color(0, 0, 0, 0), 8)
	ts.content_margin_left = 6
	ts.content_margin_right = 6
	ts.content_margin_top = 6
	ts.content_margin_bottom = 6
	tile.add_theme_stylebox_override("panel", ts)
	tile.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	DevUI.icon_rect(tile, "terminal", 16, Color(0.03, 0.06, 0.04))
	bar.add_child(tile)
	_title = DevUI.heading(bar, "Developer Console", 15, DevUI.GREEN)
	_title.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	var cap := DevUI.hbox(null, 6)
	var cap_p := PanelContainer.new()
	cap_p.add_theme_stylebox_override("panel", DevUI.panel_style(Color(1, 1, 1, 0.06), Color(1, 1, 1, 0.05), 20))
	(cap_p.get_theme_stylebox("panel") as StyleBoxFlat).content_margin_top = 4
	(cap_p.get_theme_stylebox("panel") as StyleBoxFlat).content_margin_bottom = 4
	cap_p.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	cap_p.add_child(cap)
	_metrics_dot = DevUI.dot(cap, DevUI.GREEN, 8)
	_metrics_label = DevUI.label(cap, "— fps", 11, Color(1, 1, 1, 0.75), true)
	bar.add_child(cap_p)
	DevUI.spacer(bar, 0, 0, true)
	_tabs_row = DevUI.hbox(bar, 2)
	for t in TABS:
		_tab_buttons[t[0]] = DevUI.tab_button(_tabs_row, t[1], t[2], _show_tab.bind(t[0]))
		_tab_buttons[t[0]].tooltip_text = t[1]
	var close_b := DevUI.button(bar, "esc", close, DevUI.DIM, false, "xmark")
	close_b.tooltip_text = "Close (Esc / pad B)"
	close_b.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	DevUI.rule(v, Color(DevUI.GREEN.r, DevUI.GREEN.g, DevUI.GREEN.b, 0.22))

	# Body: [console | inspector rail], with a full-width layer for State / Checks / Report.
	_body = Control.new()
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.custom_minimum_size = Vector2(0, 300)
	v.add_child(_body)
	_split = HBoxContainer.new()
	_split.set_anchors_preset(Control.PRESET_FULL_RECT)
	_split.add_theme_constant_override("separation", 0)
	_body.add_child(_split)
	_left = Control.new()
	_left.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_left.clip_contents = true
	_split.add_child(_left)
	_rail = PanelContainer.new()
	var rs := DevUI.panel_style(Color(1, 1, 1, 0.02), Color(0, 0, 0, 0), 0)
	rs.border_color = Color(DevUI.GREEN.r, DevUI.GREEN.g, DevUI.GREEN.b, 0.18)
	rs.border_width_left = 1
	rs.set_border_width(SIDE_RIGHT, 0)
	rs.content_margin_left = 0
	rs.content_margin_right = 0
	rs.content_margin_top = 0
	rs.content_margin_bottom = 0
	_rail.add_theme_stylebox_override("panel", rs)
	_split.add_child(_rail)
	_rail_in = Control.new()
	_rail_in.clip_contents = true
	_rail.add_child(_rail_in)
	_full = Control.new()
	_full.set_anchors_preset(Control.PRESET_FULL_RECT)
	_full.clip_contents = true
	_body.add_child(_full)
	get_viewport().size_changed.connect(_fit_panel)
	_fit_panel()


func _fit_panel() -> void:
	var vp := get_viewport().get_visible_rect().size
	# A centred drop-down: wide but never edge to edge, ~80% tall, never under 380 px.
	var w := clampf(vp.x - 40.0, 320.0, 1560.0)
	var h := clampf(vp.y * 0.82, 380.0, 880.0)
	h = minf(h, maxf(300.0, vp.y - 24.0))
	_panel.size = Vector2(w, h)
	_panel.custom_minimum_size = Vector2(w, h)
	_panel.position = Vector2((vp.x - w) * 0.5, 14.0)
	_wide = w >= WIDE_BREAKPOINT
	_title.visible = w >= 760.0
	_metrics_label.get_parent().get_parent().visible = w >= 900.0
	# Tab labels: selected always shows its name; others collapse to icons when tight.
	var roomy := w >= 1400.0
	for t in TABS:
		var b: Button = _tab_buttons[t[0]]
		b.text = t[1] if (roomy or t[0] == current) else ""
	_rail.custom_minimum_size = Vector2(clampf(w * 0.34, 380.0, 470.0) if _wide else 0.0, 0)
	_rail.size_flags_horizontal = Control.SIZE_FILL if _wide else Control.SIZE_EXPAND_FILL
	_apply_layout()


func _set_shown(on: bool) -> void:
	_scrim.visible = on
	_panel.visible = on
	if on:
		_fit_panel()
		if _tween != null and _tween.is_valid():
			_tween.kill()
		_panel.modulate.a = 0.0
		_scrim.modulate.a = 0.0
		var base_y: float = _panel.position.y
		_panel.position.y = base_y - 18.0
		_tween = create_tween().set_parallel(true).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
		_tween.tween_property(_panel, "modulate:a", 1.0, 0.16)
		_tween.tween_property(_scrim, "modulate:a", 1.0, 0.16)
		_tween.tween_property(_panel, "position:y", base_y, 0.18)


func pane(tab: String) -> Control:
	if _panes.has(tab):
		return _panes[tab]
	var p: Control
	match tab:
		"console": p = ConsolePane.new()
		"tools": p = ToolsPane.new()
		"state": p = StatePane.new()
		"bits": p = BitsPane.new()
		"ships": p = BrowserPane.new()
		"outfits": p = BrowserPane.new()
		"govts": p = BrowserPane.new()
		"checks": p = ChecksPane.new()
		"report": p = ReportPane.new()
		_: return null
	p.set_anchors_preset(Control.PRESET_FULL_RECT)
	# Inset so content never touches the panel edge / rail divider.
	if tab == "console":
		_left.add_child(p)
	elif tab in RAIL_TABS:
		_rail_in.add_child(p)
	else:
		_full.add_child(p)
	if tab in ["ships", "outfits", "govts"]:
		p.setup(self, tab)
	else:
		p.setup(self)
	_panes[tab] = p
	return p


## Which inspector pane the rail is showing: the current tab when it is a rail tab, else the
## last one used (Apple falls back to Tools).
func _rail_now() -> String:
	return current if current in RAIL_TABS else _rail_tab


func _apply_layout() -> void:
	if _split == null:
		return
	var full: bool = current in FULL_TABS
	_split.visible = not full
	_full.visible = full
	_left.visible = _wide or current == "console"
	_rail.visible = _wide or current in RAIL_TABS
	var rail_id := _rail_now()
	for k in _panes:
		var vis := false
		if k == "console":
			vis = not full and (_wide or current == "console")
		elif k in RAIL_TABS:
			vis = not full and k == rail_id and (_wide or current == k)
		else:
			vis = full and k == current
		_panes[k].visible = vis


func _show_tab(tab: String) -> void:
	if not _tab_buttons.has(tab):
		return
	current = tab
	if tab in RAIL_TABS:
		_rail_tab = tab
	# The pane(s) this layout needs: the tab itself, plus console + rail when wide.
	var p := pane(tab)
	if _wide and tab != "console" and not (tab in FULL_TABS):
		pane("console")
	if _wide and tab == "console":
		pane(_rail_tab)
	for k in _tab_buttons:
		var on: bool = k == tab or (_wide and tab == "console" and k == _rail_tab)
		_tab_buttons[k].set_pressed_no_signal(on)
	_fit_panel()
	if p != null and p.has_method("on_show"):
		p.on_show()
	if _wide and tab == "console" and _panes.has(_rail_tab) and _panes[_rail_tab].has_method("on_show"):
		_panes[_rail_tab].on_show()
	if _wide and tab != "console" and not (tab in FULL_TABS) and _panes.has("console") and _panes["console"].has_method("on_show"):
		pass
	if p != null and p.has_method("focus_first"):
		p.focus_first.call_deferred()
