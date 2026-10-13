# NOVA Swift — the Debug Suite host (port of app/NovaSwift/Debug/: DevConsoleView, DevToolsPane,
# DebugController, DebugMetricsChip, FrameProfiler/PerfMonitor feeds). See docs/GODOT_LAYER.md
# "Debug suite" and docs/GODOT_PARITY.md section 12.
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

signal opened
signal closed

const TABS := [
	["console", "Console"], ["tools", "Tools"], ["state", "State"], ["bits", "Bits"],
	["ships", "Ships"], ["outfits", "Outfits"], ["govts", "Govts"], ["checks", "Checks"],
	["report", "Report"],
]
const WINDOW := 0.5                 # metrics window, seconds
const SPIKE_MS := 33.0              # a frame over this reads as a hitch

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
var _body: Control
var _panes := {}
var _overlay: Control
var _chip: Control
var _chip_label: Button
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
	return is_open or Engine.get_process_frames() <= _released_frame


## Run a console line; returns [{kind, text}] (the pane shows them via the shared log).
func run(line: String) -> Array:
	if dbg == null:
		return []
	var out = JSON.parse_string(dbg.console_run(line))
	if _panes.has("console"):
		_panes["console"].on_command(line)
	return out if out is Array else []


# --- open / close ----------------------------------------------------------------

func open_tab(tab: String) -> void:
	if tab != "report" and not debug_enabled():
		return
	if dbg == null:
		return
	is_open = true
	_panel.visible = true
	_show_tab(tab)
	_apply_visibility()
	opened.emit()


func toggle_console() -> void:
	if is_open:
		close()
	else:
		open_tab("console")


func close() -> void:
	if not is_open:
		return
	is_open = false
	_panel.visible = false
	_released_frame = Engine.get_process_frames()
	var f := get_viewport().gui_get_focus_owner()
	if f != null:
		f.release_focus()
	_apply_visibility()
	closed.emit()


func _apply_visibility() -> void:
	_chip.visible = debug_enabled() and not is_open and dbg != null
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
	if is_open and _panes.has(current) and _panes[current].has_method("tick"):
		_panes[current].tick(delta)


func _refresh_chip() -> void:
	if snapshot.is_empty():
		return
	var t := "%.0f fps · %d ships" % [float(snapshot.get("fps", 0)), int(snapshot.get("ships", 0))]
	if bool(snapshot.get("perfTest", false)):
		t += " · TEST"
	_chip_label.text = t
	var fps := float(snapshot.get("fps", 0))
	var c := DevUI.GREEN if fps >= 55.0 else (DevUI.AMBER if fps >= 30.0 else DevUI.RED)
	_chip_label.add_theme_color_override("font_color", c)


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
	DevUI.button(_chip, ">_", func(): open_tab("console"), DevUI.GREEN).focus_mode = Control.FOCUS_NONE
	_chip_label = DevUI.button(_chip, "— fps", func(): open_tab("tools"), DevUI.GREEN)
	_chip_label.focus_mode = Control.FOCUS_NONE
	add_child(_chip)


func _build_panel() -> void:
	_root = Control.new()
	_root.set_anchors_preset(Control.PRESET_FULL_RECT)
	_root.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_root.theme = DevUI.theme()
	add_child(_root)
	_panel = PanelContainer.new()
	_panel.visible = false
	_panel.anchor_left = 0.0
	_panel.anchor_right = 1.0
	_panel.anchor_top = 0.0
	_panel.anchor_bottom = 0.0
	_panel.offset_left = 8
	_panel.offset_right = -8
	_panel.offset_top = 8
	_panel.offset_bottom = 0
	_panel.add_theme_stylebox_override("panel", DevUI.panel_style(DevUI.PANEL_BG, DevUI.GREEN * Color(1, 1, 1, 0.45), 10))
	_root.add_child(_panel)
	var v := DevUI.vbox(_panel, 6)
	var bar := DevUI.hbox(v, 4)
	var title := DevUI.label(bar, "DEBUG SUITE", 12, DevUI.GREEN)
	title.custom_minimum_size = Vector2(110, 0)
	for t in TABS:
		var b := DevUI.button(bar, t[1], _show_tab.bind(t[0]), DevUI.DIM, true)
		_tab_buttons[t[0]] = b
	var sp := Control.new()
	sp.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	bar.add_child(sp)
	DevUI.button(bar, "Close", close, DevUI.RED)
	_body = Control.new()
	_body.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_body.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_body.custom_minimum_size = Vector2(0, 300)
	v.add_child(_body)
	get_viewport().size_changed.connect(_fit_panel)
	_fit_panel()


func _fit_panel() -> void:
	# Drops from the top, ~62% of the window (Apple's panel), never under 360 px.
	var h := maxf(360.0, get_viewport().get_visible_rect().size.y * 0.62)
	_panel.offset_bottom = _panel.offset_top + h
	_body.custom_minimum_size = Vector2(0, h - 70)


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
	_body.add_child(p)
	if tab in ["ships", "outfits", "govts"]:
		p.setup(self, tab)
	else:
		p.setup(self)
	_panes[tab] = p
	return p


func _show_tab(tab: String) -> void:
	if not _tab_buttons.has(tab):
		return
	current = tab
	for k in _tab_buttons:
		_tab_buttons[k].set_pressed_no_signal(k == tab)
	var p := pane(tab)
	for k in _panes:
		_panes[k].visible = (k == tab)
	if p != null and p.has_method("on_show"):
		p.on_show()
	if p != null and p.has_method("focus_first"):
		p.focus_first.call_deferred()
