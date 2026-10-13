# NOVA Swift — Godot frontend.
#
# Drives the Swift engine through the NovaSwiftGodot GDExtension and renders the
# result. Two modes, chosen automatically at startup:
#
#   • Real data — if EV Nova data is found (NOVA_DATA_DIR env var, else the repo's
#     data/base/), it loads it, builds a real system via GameSession.makeWorld,
#     and renders actual hull, planet, shot, rock and explosion SPRITES decoded
#     by NovaSwiftKit.
#   • Demo — otherwise a data-free physics world: a ship you fly plus drifting
#     hulls, drawn as primitives. Runs with no data so the slice always works.
#
# Either way the loop is the same and it's the real engine:
#   Godot input -> Swift ControlIntent -> World.step -> Swift readback -> render.
#
# Swift is the single source of truth for game state: targeting, hostility,
# weapon readiness, fuel, sensor range, and now the whole combat entity set
# (shots, beams, rocks) are all engine calls (mirroring the Apple app's
# GameScene/GameHUDModel split) — this script only lays out pixels and does
# small numeric formatting over whatever the bridge returns, never its own game
# logic. The one thing it owns outright is the transient particle layer: the
# engine says "an explosion happened here, this big, playing this bööm", and
# how that looks on screen is the frontend's business.
#
# Timing note: nova.step() runs the engine's own fixed 30 Hz tick internally and
# hands back render-interpolated poses, so this script just forwards the display
# delta and draws whatever comes out. See NovaWorld.step.
#
# Controls: every input is an InputMap action registered by Controls.gd with both
# a keyboard key and a gamepad binding (Steam Deck / any SDL pad) — see that file
# for the full table. Keyboard: the original's keys (as the Apple app ships them) —
# arrows fly, Z burn, Space/Ctrl fire, ` cycle targets, R/Alt-R nearest hostile/ship,
# W/Alt-W switch secondary, 1-4 nav stellar, L land (two presses), M map, J jump;
# docked UI is screens/Spaceport.gd. Pad: left stick fly, right stick aim, A/B fire,
# D-pad ↓ land.

extends Node2D

const Controls = preload("res://Controls.gd")
const Prefs = preload("res://Prefs.gd")                      # user://settings.cfg
const Shell = preload("res://screens/Shell.gd")              # main menu, settings, pause, data setup
const NavScreens = preload("res://screens/NavScreens.gd")   # galaxy map + hyperjump
const Interactions = preload("res://screens/Interactions.gd")   # hail, board/plunder, escorts
const GameAudio = preload("res://audio/GameAudio.gd")          # snd playback (voice pool)
const BrightnessVeil = preload("res://ui/BrightnessVeil.gd")      # Preferences brightness (gamma veil)
const StoryScreens = preload("res://screens/StoryScreens.gd") # story texts, mission offers, Player/Mission Info
const Spaceport = preload("res://screens/Spaceport.gd")     # landing, trade, outfitter, shipyard
const ClassicTheme = preload("res://ui/classic/ClassicTheme.gd")   # Classic UI kit (original ïntf HUD, DLOG/DITL dialogs)
const AuthenticHUD = preload("res://ui/classic/AuthenticHUD.gd")
const DevTools = preload("res://debug/DevTools.gd")           # Debug suite (console, tools, bug report)
const DescMovie = preload("res://ui/DescMovie.gd")             # dësc movies (gate / wormhole entry)
const FlightRenderer = preload("res://flight/FlightRenderer.gd")   # the world drawn on screen (godot/flight/)

var _dev: Node               # DevTools: debug suite host (always captures the log)
var _shell: Node             # Shell: menus around the game (see screens/Shell.gd)

var nova                     # NovaWorld (from the NovaSwiftGodot GDExtension)
var _has_data := false
var _nav: Node               # NavScreens: galaxy map screen + hyperjump visual
var _interact: Node          # Interactions: hail / plunder / escort dialogs
var _audio: Node             # GameAudio: drains the bridge's sound cues every frame

var _story: Node            # StoryScreens: story text / offer dialogs, Player + Mission Info
var _spaceport: Node         # Spaceport: the whole docked UI
var _flight: Node2D          # FlightRenderer: stellars, ships, shots, effects, camera, starfield

# Actions that must be released before they count again — set on a screen
# change so the button that launched you (pad B) doesn't also fire a missile.
var _suppressed := {}

# The status line (Apple MessageLogView): ONE line, a new message replaces the old
# outright; [{text, age}] holds at most that one entry. It lasts 0xf0 raw sim calls
# (about 5 s, bridge hud_message_seconds) and fades over the last 0.6 s.
var _log: Array = []
const LOG_MAX_LINES := 1
const LOG_LIFETIME := 5.0
const LOG_FADE := 0.6
const MESSAGE_LINE_H := 26.0     # the original's message rect is one 26 px line (0x0087550b)
const MESSAGE_PAD_LEFT := 16.0
const MESSAGE_PAD_RIGHT := 50.0  # + the status-bar sidebar
const MESSAGE_PAD_BOTTOM := 8.0
const MESSAGE_FONT_SIZE := 14    # NovaFont .hud base size

var _death_timer := -1.0              # game over: seconds until the main menu (the wreck plays out first)

const COLOR_PLAYER := Color(0.55, 0.85, 1.0)

# Body kind -> fallback circle color (0 landable, 1 planet, 2 hypergate, 3 wormhole, 4 deadly).
const BODY_COLORS := [
	Color(0.45, 0.7, 0.5),
	Color(0.6, 0.6, 0.65),
	Color(0.5, 0.75, 1.0),
	Color(0.8, 0.5, 1.0),
	Color(0.9, 0.35, 0.3),
]
# Radar/IFF relationship code (from NovaWorld.shipRelationships) -> blip color.
# 0 hostile, 1 neutral, 2 friendly/escort, 3 disabled, 4 self.
const RELATIONSHIP_COLORS := [
	Color(0.95, 0.25, 0.25),
	Color(0.35, 0.55, 0.95),
	Color(0.35, 0.9, 0.45),
	Color(0.55, 0.55, 0.6),
	COLOR_PLAYER,
]

const RADAR_CENTER_MARGIN := Vector2(120, 120)
const RADAR_PIXEL_RADIUS := 90.0
const RADAR_WORLD_RANGE := 4500.0   # matches the Apple app's own client-side radarRange

# The status-line texts are the bridge's (`drain_interaction_messages`: STR# 2002 lines and the
# literals GameScene posts). The Apple app does not narrate a target dying, a ship docking or
# launching, so those events post nothing here.


func _ready() -> void:
	if not ClassDB.class_exists("NovaWorld"):
		push_error("NovaWorld class not found — is godot/bin/ built? See scripts/build-gdextension.sh")
		return
	Prefs.load_all()      # rebinds + dead zone must be in before register()
	Controls.register()
	Prefs.apply_video()
	nova = ClassDB.instantiate("NovaWorld")
	add_child(nova)
	_flight = FlightRenderer.new()
	add_child(_flight)
	_flight.setup(nova)
	_audio = GameAudio.new()
	add_child(_audio)
	_audio.setup(nova)
	Prefs.apply_audio(_audio)
	add_child(BrightnessVeil.new())   # the original Preferences brightness arrows (Package C2)

	_nav = NavScreens.new()
	add_child(_nav)
	_nav.setup(nova)
	if nova.has_method("set_gate_transport_deferred"):
		nova.set_gate_transport_deferred(true)   # wormholes wait for the entry movie (_on_land)
	_nav.log_message.connect(_push_log)
	_nav.screen_closed.connect(_suppress_held)
	_nav.arrived.connect(func(_n): _refresh_flight())

	_interact = Interactions.new()
	add_child(_interact)
	_interact.setup(nova)
	_interact.log_message.connect(_push_log)
	_interact.screen_closed.connect(_suppress_held)

	_spaceport = Spaceport.new()
	add_child(_spaceport)
	_spaceport.setup(nova)
	_spaceport.launch_requested.connect(_on_launch)

	_story = StoryScreens.new()   # after the spaceport: its dialogs sit above and take input first
	add_child(_story)
	_story.setup(nova)
	_story.log_message.connect(_push_log)
	_story.screen_closed.connect(_suppress_held)
	_story.close_spaceport_screen.connect(_spaceport.story_close_screen)
	_story.forced_launch.connect(_on_launch)
	get_viewport().size_changed.connect(_sync_story_view)
	_sync_story_view()

	_shell = Shell.new()
	add_child(_shell)
	_shell.setup(nova, _audio)
	_shell.data_loaded.connect(func(_dir): _has_data = true)
	_shell.pilot_chosen.connect(_on_pilot_chosen)
	_shell.demo_chosen.connect(_on_demo_chosen)
	_shell.resumed.connect(_suppress_held)
	_shell.player_info_requested.connect(func(): _story.open_info("general"))

	_dev = DevTools.new()
	add_child(_dev)
	_dev.setup(nova, Callable(self, "_dbg_to_screen"))

	_start_world()
	_nav.run_selftest_if_requested()


# The observe goal counts a mission ship as seen only inside the visible play area.
# World (engine) -> screen position, for the debug suite's AI overlay (inverse of the click mapping).
func _dbg_to_screen(w: Vector2) -> Vector2:
	return _flight.world_to_screen(w)


func _sync_story_view() -> void:
	var sz := get_viewport_rect().size
	nova.set_story_view_size(sz.x, sz.y)


func _start_world() -> void:
	# Dev/CI shortcuts skip the shell: throwaway pilot (never saved) or the demo.
	if OS.get_environment("NOVA_SKIP_PILOT_MENU") != "" or OS.get_environment("NOVA_DEMO") != "":
		var data_dir: String = Prefs.find_data(nova)
		if data_dir != "":
			_has_data = true
			print("NOVA Swift: loaded data from ", data_dir)
			nova.make_world(-1)
		else:
			nova.make_demo_world()
			_has_data = false
			print("NOVA Swift: no data found — running demo world")
		_refresh_flight()
		return
	# Otherwise the shell shows the main menu (or the data-setup screen first);
	# the world isn't built until a pilot is chosen or the demo is picked.
	_shell.start_async()   # the data loads on a worker thread behind the loading screen


func _on_pilot_chosen() -> void:
	if not nova.make_world(-1):
		nova.make_demo_world()
		_has_data = false
	_suppress_held()
	_refresh_flight()


func _on_demo_chosen() -> void:
	nova.make_demo_world()
	_has_data = false
	_suppress_held()
	_refresh_flight()


# Esc / Start in plain flight opens the pause menu. Every screen that uses those
# keys (map, dialogs, docked UI) handles them first, so this only sees them when
# nothing else wants them.
func _unhandled_input(event: InputEvent) -> void:
	if event.is_action_pressed("pause_menu") and _can_pause():
		get_viewport().set_input_as_handled()
		_shell.open_pause()
	elif event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT \
			and _can_pause():
		# Click to select (GameScene.selectAt): a ship under the pointer locks as the target,
		# a stellar takes the travel selection, your own ship clears the target, empty
		# space clears the stellar. Screen -> world is FlightRenderer.screen_to_world.
		var world_pos: Vector2 = _flight.screen_to_world(event.position)
		nova.click_select(world_pos.x, world_pos.y)


func _can_pause() -> bool:
	return nova != null and _shell != null and not _shell.in_menu() and not _shell.is_paused() \
		and not nova.is_landed() and not _spaceport.is_open() \
		and not _nav.blocks_flight() and not _interact.blocks_flight() and not nova.story_blocks_flight()


# Quitting is an original save point only while landed (the launch tail runs).
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_CLOSE_REQUEST and nova != null and _shell != null and not _shell.in_menu() and _has_data:
		nova.pilot_autosave("backgroundLanded" if nova.is_landed() else "background")


# The world was (re)built: the renderer re-reads the system's sÿst.BkgndColor, drops transient effects and
# snaps the camera. Not per frame — it only changes when the system does.
func _refresh_flight() -> void:
	_flight.has_data = _has_data
	_flight.reset_world()


## The width the Classic status bar reserves (the world is centred in the part to its left).
func _hud_bar_width() -> float:
	if _has_data and ClassicTheme.classic("hud") and _classic_hud != null:
		return _classic_hud.get_child(0).bar_width(get_viewport_rect().size)
	return 0.0


func _flight_frame(delta: float, sim_ran: bool) -> void:
	_flight.has_data = _has_data
	_flight.set_active(true)
	_flight.frame(delta, _hud_bar_width(), sim_ran)


func _process(delta: float) -> void:
	if nova == null:
		return
	if _shell.in_menu():
		$HUD.visible = false
		_flight.set_active(false)
		return
	if _shell.is_paused():
		return   # pause menu up: the sim, HUD and last frame stay frozen

	# A suppressed action becomes live again once it's been let go.
	for action in _suppressed.keys():
		if not Input.is_action_pressed(action):
			_suppressed.erase(action)

	var hud: Label = $HUD
	if nova.is_landed():
		# Docked: the flight sim is paused (no set_intent/step) — only the
		# Trade Center + launch hotkeys and the message-log fade run. Mirrors
		# the Apple app's spaceport screens owning the frame while landed. The
		# flight HUD label is a Control child, so it draws *over* this script's
		# _draw output and has to be hidden explicitly.
		hud.visible = false
		_flight.set_active(false)
		if not _spaceport.is_open():
			_spaceport.open()   # screens/Spaceport.gd owns input while docked
		_flight.prewarm_step(4.0)   # warm the launch system's art while docked (off-thread decode, budgeted upload)
		_drain_events_to_log(0.0)   # docked: the sim (and the status line's clock) is stopped
		queue_redraw()
		return

	if _spaceport.is_open():
		_spaceport.close()
	# The top-left status/key-hint line is a dev overlay — the original has none,
	# so the Classic HUD hides it (Nova Swift presentation keeps it).
	hud.visible = not (_has_data and ClassicTheme.classic("hud"))

	if _nav.blocks_flight() or _interact.blocks_flight() or _story.blocks_flight():   # map / hail / plunder dialog up: sim paused
		_flight_frame(0.0, false)
		_drain_events_to_log(0.0)   # map / dialog up: the sim is paused, so is the message clock
		queue_redraw()
		return

	if _dev != null and _dev.captures_input():   # debug suite up: keys belong to it, the sim keeps running
		nova.set_intent(false, false, false, false, false, false, false)
		nova.step(delta)
		_flight_frame(delta, true)
		_drain_events_to_log(delta)
		queue_redraw()
		return

	nova.set_intent(_held("turn_left"), _held("turn_right"), _held("thrust"), _held("reverse"),
		_held("afterburner"), _held("fire_primary"), _held("fire_secondary"))
	nova.set_self_destruct(_held("self_destruct"))   # Alt-−, held: the five-second countdown
	var aim: float = Controls.aim_heading()
	nova.set_aim_heading(not is_nan(aim), 0.0 if is_nan(aim) else aim)
	nova.step(delta)
	_check_game_over(delta)

	_flight_frame(delta, true)
	if nova.hyperjump_active():
		_flight.prewarm_step(3.0)   # the destination's art, uploaded a few ms a frame during the jump
	_process_hotkeys()
	_clear_cannot_jump_overlays()
	_drain_events_to_log(delta)
	_update_top_label()
	queue_redraw()


func _on_launch() -> void:
	if nova.launch():
		_suppress_held()
		_refresh_flight()


func _update_top_label() -> void:
	var hud: Label = $HUD
	var mode := "real data" if _has_data else "demo world (no data)"
	var ship_name := ""
	if _has_data:
		ship_name = nova.ship_type_name(nova.player_ship_type())
	hud.text = "NOVA Swift — Godot · %s%s · ships %d\n" % [
			mode, ("  ·  " + ship_name) if ship_name != "" else "", nova.ship_count(),
		] \
		+ ("L-stick fly · R-stick aim · A/B fire · X/Y target · LB/RB weapon · L3 burn · D-pad ↓ land"
			if Controls.pad_connected() else _keyboard_hint())


# The keyboard cheat-sheet in the top label, from the live bindings (so it follows the
# layout and any rebinds).
func _keyboard_hint() -> String:
	var parts := [
		"%s/%s/%s/%s fly" % [Controls.describe_keys("turn_left"), Controls.describe_keys("turn_right"),
			Controls.describe_keys("thrust"), Controls.describe_keys("reverse")],
		"%s burn" % Controls.describe_keys("afterburner"),
		"%s fire" % Controls.describe_keys("fire_primary"),
		"%s secondary" % Controls.describe_keys("fire_secondary"),
		"%s target" % Controls.describe_keys("target_next"),
		"%s switch weapon" % Controls.describe_keys("secondary_next"),
		"%s land" % Controls.describe_keys("land"),
	]
	return " · ".join(parts)


# Godot also matches a chord's plain key (extra modifiers are ignored), so of a
# (chord, plain) pair the chord is tested first and wins.
func _chord(chord: String, plain: String) -> String:
	if Input.is_action_just_pressed(chord):
		return "chord"
	if Input.is_action_just_pressed(plain):
		return "plain"
	return ""


# Discrete actions fire once per press, not once per held frame. The ship-target keys
# are the original's (0x0044b120 sounds: a new target snd 152, none found snd 153,
# clearing snd 150 — all raised by the bridge, as is the Alt-N / N / S beeps).
func _process_hotkeys() -> void:
	if Input.is_action_just_pressed("target_prev"):
		nova.cycle_target(true, false)
	elif Input.is_action_just_pressed("target_escort_next"):
		nova.cycle_target(false, true)
	elif Input.is_action_just_pressed("target_next"):
		nova.cycle_target(false, false)
	match _chord("target_nearest", "target_nearest_hostile"):
		"chord": nova.select_nearest_engaged()
		"plain": nova.select_nearest_hostile_threat()
	match _chord("clear_ship_target", "clear_target"):
		"chord": nova.clear_ship_target()
		"plain": _clear_target()
	if Input.is_action_just_pressed("dismiss_message"):
		_log.clear()   # Return: dismiss the status-bar message (slot 0x06)
	if Input.is_action_just_pressed("clear_secondary"):
		nova.clear_secondary_weapon()
	if Input.is_action_just_pressed("secondary_prev"):
		_log_weapon_switch(nova.cycle_secondary_weapon(false))
	elif Input.is_action_just_pressed("secondary_next"):
		_log_weapon_switch(nova.cycle_secondary_weapon(true))
	if Input.is_action_just_pressed("land"):
		_on_land()
	if Input.is_action_just_pressed("toggle_cloak"):
		nova.toggle_cloak()
	if Input.is_action_just_pressed("eject"):
		nova.request_eject()
	if Input.is_action_just_pressed("recall_fighters"):
		nova.recall_fighters()
	if Input.is_action_just_pressed("hyperspace_arm"):
		nova.hyperspace_arm()
	_nav.process_hotkeys()   # M map, J hyperjump
	_interact.process_hotkeys()   # Y hail, B board, escort panel + orders
	_story.process_hotkeys()      # P Player Info, I Mission Info
	# 1-5 pick an escort group while the Escort Commands panel is up (Interactions);
	# otherwise 1-4 select the system's nav stellars.
	if not nova.escort_panel_open():
		for i in 4:
			if Input.is_action_just_pressed("nav_stellar_%d" % (i + 1)):
				nova.select_nav_stellar(i)


# N: the original clears the travel selection (a selected stellar and an armed jump);
# the modern layout's clear key drops the ship target as well.
func _clear_target() -> void:
	if Controls.layout == Controls.LAYOUT_MODERN:
		nova.clear_player_target()
	nova.clear_travel_selection()


# The Land key is the original's two presses (the bridge's press_land): the first on the
# selected stellar (the nearest approachable one if none is) requests clearance —
# refused with the original's text if the stellar denies you, bribes included — the
# second sets down. Landing on a gate uses it instead.
func _on_land() -> void:
	var r = JSON.parse_string(nova.press_land())
	var result: String = r.get("result", "none") if r is Dictionary else "none"
	match result:
		"landed":
			_suppress_held()
		"gate":
			_suppress_held()
			_nav.open_gate_picker()
		"wormhole":
			# Stellar_EnterWormhole 0x00456ca0: the dësc movie keyed to the wormhole's spöb id plays, then
			# the transport (the bridge picked the exit already).
			_suppress_held()
			var ms: int = int(r.get("movie_desc", -1))
			DescMovie.play_gate(self, ms, func():
				if nova.has_method("wormhole_enter_pending"):
					nova.wormhole_enter_pending()
				_suppress_held())


# Held this frame, unless still suppressed from before a screen change.
func _held(action: String) -> bool:
	return Input.is_action_pressed(action) and not _suppressed.has(action)


func _pressed(action: String) -> bool:
	return Input.is_action_just_pressed(action) and not _suppressed.has(action)


# On land/launch, everything currently held must be let go before it acts on the
# new screen (pad A is both "fire" and "buy"; B both "launch" and "missile").
func _suppress_held() -> void:
	for action in Controls.BINDINGS:
		if Input.is_action_pressed(action):
			_suppressed[action] = true


func _log_weapon_switch(new_name: String) -> void:
	pass   # Apple posts nothing on a weapon switch; the readout shows it


# FL-23 (0x0044aa70): while a jump engages, a status line still showing one of the cannot-jump overlays
# (STR# 2002 #42 too close to the centre, #36 tractor beam, #30 well beyond range, #31 nothing out here)
# is cleared. Returns whether it cleared one.
var _cannot_jump_texts: Array = []

func _clear_cannot_jump_overlays() -> bool:
	if _log.is_empty() or not nova.hyperjump_active():
		return false
	if _cannot_jump_texts.is_empty():
		var strs: PackedStringArray = nova.classic_strings(2002)
		for n in [42, 36, 30, 31]:
			if n - 1 < strs.size() and strs[n - 1] != "":
				_cannot_jump_texts.append(strs[n - 1].replace("\r", " ").replace("\n", " "))
	if _cannot_jump_texts.has(str(_log[0]["text"])):
		_log.clear()
		return true
	return false


func _push_log(text: String) -> void:
	var line := text.replace("\r", " ").replace("\n", " ")
	if line.strip_edges() == "":
		_log.clear()    # an empty post clears the line, as in the original
		return
	# Each post carries its own length in raw sim calls: the buoy 0x1e0, a mission Q 0x1f4, a
	# HailQuote 0x1a4, landing 0xfa / 0x168, everything else 0xf0 (OriginalText.Duration).
	var life := LOG_LIFETIME
	if nova != null:
		life = float(nova.hud_message_seconds(int(nova.status_line_raw_calls(text))))
	_log = [{"text": line, "age": 0.0, "life": life}]


func _drain_events_to_log(delta: float) -> void:
	# Message timers run on SIM time: the callers pass 0 while the map / a dialog / the spaceport
	# holds the sim, and the Settings game speed (and Caps Lock 2x) shortens them as it does the
	# original's raw-call counters (B4).
	var sim_dt: float = delta * float(nova.speed_multiplier()) if delta > 0.0 else 0.0
	for entry in _log:
		entry["age"] += sim_dt
	_log = _log.filter(func(e): return e["age"] < float(e.get("life", LOG_LIFETIME)))
	nova.set_status_line_busy(not _log.is_empty())   # the HailQuote broadcast waits for a free line

	# drain_events() genuinely drains on the bridge side, so this is safe to call
	# on a frame where the sim didn't tick (docked) — it just comes back empty.
	nova.drain_events()   # names only; the narrated lines arrive through the message channels


func _draw() -> void:
	# The world itself is the FlightRenderer's (godot/flight/), drawn behind this node; this draws the
	# primitive HUD and the text overlays over it.
	if nova == null or _shell.in_menu() or nova.is_landed():
		return
	var vp := get_viewport_rect().size
	var pw: Vector2 = nova.player_position()
	var target_id: int = nova.player_target_id()

	# Settings > Larger HUD (Apple scales its modern HUD x1.28): the primitive HUD draws on a scaled
	# canvas whose "viewport" is vp / k, so everything anchored to an edge stays on that edge.
	var k := Prefs.hud_scale()
	var hv := vp / k
	_hud_high_contrast = Prefs.hud_high_contrast()
	if k != 1.0:
		draw_set_transform(Vector2.ZERO, 0.0, Vector2(k, k))
	if not _sync_classic_hud():   # Classic presentation: the ïntf status bar (a CanvasLayer) draws these
		_draw_status_bars(hv)
		_draw_weapon_readout(hv)
		_draw_target_panel(hv, target_id)
	if not _classic_hud_on:
		_draw_nav_panel(hv)
		if Prefs.show_radar():   # Settings > Show radar
			_draw_radar(hv, pw)
	if k != 1.0:
		draw_set_transform(Vector2.ZERO, 0.0, Vector2.ONE)
	_draw_land_prompt(vp)
	_draw_message_log(vp)
	_draw_alert_icons(vp)


# Classic presentation (Settings > Presentation, default): the original `ïntf` status
# bar from the player's data replaces the primitive HUD below. Created/freed here as
# the setting changes; returns whether it is showing.
var _classic_hud: CanvasLayer
var _classic_hud_on := false

func _sync_classic_hud() -> bool:
	ClassicTheme.setup(nova)
	var want: bool = _has_data and ClassicTheme.classic("hud")
	if want and _classic_hud == null:
		var hud = AuthenticHUD.new()
		hud.setup(nova)
		if hud.is_ready():
			hud.active = func(): return not _shell.in_menu() and not nova.is_landed()
			_classic_hud = CanvasLayer.new()
			_classic_hud.layer = 5
			_classic_hud.add_child(hud)
			add_child(_classic_hud)
		else:
			hud.free()
			want = false   # data without an ïntf/backdrop keeps the primitive HUD
	elif not want and _classic_hud != null:
		_classic_hud.queue_free()
		_classic_hud = null
	_classic_hud_on = want and _classic_hud != null
	return _classic_hud_on


# The death sequence ran out with no eject: let the wreck play out, then back to the main
# menu without saving — the pilot resumes from its last launch (OS-02, FL-03).
func _check_game_over(delta: float) -> void:
	if nova.take_player_destroyed():
		_death_timer = 2.2
	if _death_timer >= 0.0:
		_death_timer -= delta
		if _death_timer < 0.0:
			_shell.on_player_killed()


# MARK: HUD — status bars, weapon readout, target panel, radar, message log.
# All values below come straight from bridge Callables (Swift's World/Ship
# state); this function only picks colors/positions and formats numbers.

const BAR_W := 170.0
const BAR_H := 14.0
const BAR_GAP := 6.0
const HUD_FONT_SIZE := 14

var _hud_high_contrast := false   # Settings > High-contrast HUD (set each _draw)

func _bar(pos: Vector2, frac: float, fill: Color, label: String) -> void:
	var bg := Color(0.0, 0.0, 0.0, 0.95) if _hud_high_contrast else Color(0.15, 0.15, 0.18, 0.85)
	draw_rect(Rect2(pos, Vector2(BAR_W, BAR_H)), bg)
	draw_rect(Rect2(pos, Vector2(BAR_W * clampf(frac, 0.0, 1.0), BAR_H)), fill)
	draw_rect(Rect2(pos, Vector2(BAR_W, BAR_H)), Color(1, 1, 1, 0.9 if _hud_high_contrast else 0.25), false,
		2.0 if _hud_high_contrast else 1.0)
	draw_string(ThemeDB.fallback_font, pos + Vector2(6, BAR_H - 3), label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_FONT_SIZE - 2, Color(1, 1, 1, 1.0 if _hud_high_contrast else 0.9))


func _draw_status_bars(vp: Vector2) -> void:
	var origin := Vector2(20, vp.y - 96)
	var shield: float = nova.player_shield_fraction()
	var armor: float = nova.player_armor_fraction()
	var fuel: float = nova.player_fuel_fraction()
	var jumps: int = nova.player_jumps_remaining()

	_bar(origin, shield, Color(0.35, 0.65, 1.0), "Shield %d%%" % int(round(shield * 100)))
	_bar(origin + Vector2(0, BAR_H + BAR_GAP), armor, Color(0.85, 0.65, 0.25), "Armor %d%%" % int(round(armor * 100)))
	_bar(origin + Vector2(0, (BAR_H + BAR_GAP) * 2), fuel, Color(0.4, 0.85, 0.5), "Fuel · %d jump%s" % [jumps, "" if jumps == 1 else "s"])


func _draw_weapon_readout(vp: Vector2) -> void:
	var pos := Vector2(vp.x * 0.5 - BAR_W * 0.5, vp.y - 40)
	if not nova.has_secondary_weapon():
		draw_string(ThemeDB.fallback_font, pos, "No Secondary Weapon",
			HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_FONT_SIZE, Color(0.7, 0.7, 0.75, 0.8))
		return

	var weapon_name: String = nova.secondary_weapon_name()
	if weapon_name == "":   # S cleared the selection
		draw_string(ThemeDB.fallback_font, pos, "No Secondary Weapon",
			HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_FONT_SIZE, Color(0.7, 0.7, 0.75, 0.8))
		return
	var ammo: int = nova.secondary_weapon_ammo()
	var cooldown: float = nova.secondary_weapon_cooldown_fraction()
	var label := "%s - %d" % [weapon_name, ammo] if ammo >= 0 else weapon_name
	draw_string(ThemeDB.fallback_font, pos, label,
		HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_FONT_SIZE, Color(1, 0.9, 0.75, 0.95))
	# Ready/reload bar — full when ready to fire, drains as it just fired.
	var bar_pos := pos + Vector2(0, 6)
	draw_rect(Rect2(bar_pos, Vector2(BAR_W, 4)), Color(0.15, 0.15, 0.18, 0.85))
	draw_rect(Rect2(bar_pos, Vector2(BAR_W * (1.0 - cooldown), 4)), Color(1.0, 0.7, 0.3))


func _draw_target_panel(vp: Vector2, target_id: int) -> void:
	if target_id < 0:
		return
	var pos := Vector2(vp.x - BAR_W - 20, 130)
	var target: String = nova.target_name()
	var hostile: bool = nova.target_is_hostile()
	var shield: float = nova.target_shield_fraction()
	var armor: float = nova.target_armor_fraction()
	var dist: float = nova.target_distance()

	var name_col := Color(0.95, 0.35, 0.3) if hostile else Color(0.55, 0.8, 1.0)
	draw_string(ThemeDB.fallback_font, pos, target,
		HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_FONT_SIZE, name_col)
	draw_string(ThemeDB.fallback_font, pos + Vector2(0, 16), "%d m" % int(dist),
		HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_FONT_SIZE - 2, Color(0.8, 0.8, 0.85, 0.8))
	_bar(pos + Vector2(0, 24), shield, Color(0.35, 0.65, 1.0), "Shield %d%%" % int(round(shield * 100)))
	_bar(pos + Vector2(0, 24 + BAR_H + BAR_GAP), armor, Color(0.85, 0.65, 0.25), "Armor %d%%" % int(round(armor * 100)))


func _draw_radar(vp: Vector2, pw: Vector2) -> void:
	var rc := Vector2(vp.x - RADAR_CENTER_MARGIN.x, RADAR_CENTER_MARGIN.y)
	var sensor_range: float = nova.effective_sensor_range(RADAR_WORLD_RANGE)
	if sensor_range <= 0.0:
		sensor_range = RADAR_WORLD_RANGE
	var radar_scale := RADAR_PIXEL_RADIUS / sensor_range

	draw_circle(rc, RADAR_PIXEL_RADIUS, Color(0.08, 0.12, 0.1, 0.55))
	draw_arc(rc, RADAR_PIXEL_RADIUS, 0.0, TAU, 48, Color(0.4, 0.9, 0.5, 0.5), 1.0, true)

	# Stellars first and dimmer, so ship blips read on top of them — the same
	# ordering the original's radar uses.
	if _has_data:
		var bodies: PackedFloat32Array = nova.body_transforms()
		var i := 0
		while i + 3 < bodies.size():
			var off := Vector2(bodies[i], bodies[i + 1]) - pw
			if off.length() <= sensor_range:
				var kind := int(bodies[i + 3])
				var col: Color = BODY_COLORS[kind] if kind < BODY_COLORS.size() else BODY_COLORS[1]
				col.a = 0.55
				draw_circle(rc + Vector2(off.x, -off.y) * radar_scale, 4.0, col)
			i += 4

	var j := 0
	var n := 0
	var _ship_xf: PackedFloat32Array = _flight.ship_xf
	var _ship_rel: PackedInt32Array = _flight.ship_rel
	while j + 3 < _ship_xf.size():
		if n > 0:  # index 0 is the player; drawn as the fixed center dot below.
			var world_offset := Vector2(_ship_xf[j], _ship_xf[j + 1]) - pw
			if world_offset.length() <= sensor_range:
				var blip_offset := Vector2(world_offset.x, -world_offset.y) * radar_scale
				var code: int = _ship_rel[n] if n < _ship_rel.size() else 1
				var col: Color = RELATIONSHIP_COLORS[code] if code < RELATIONSHIP_COLORS.size() else RELATIONSHIP_COLORS[1]
				draw_circle(rc + blip_offset, 2.5, col)
		j += 4
		n += 1

	draw_circle(rc, 3.0, COLOR_PLAYER)


## The HUD's own text face for the status line and prompts: Apple's `.hud` role (Geneva
## stand-in, semibold, 14 pt, white) — the ïntf status font in Classic presentation.
func _hud_text() -> Dictionary:
	var font: Font = ThemeDB.fallback_font
	var right := 0.0
	var classic := false
	if _classic_hud_on and _classic_hud != null:
		var h = _classic_hud.get_child(0)
		font = h.text_font()
		right = h.bar_width(get_viewport_rect().size)
		classic = true
	var fv := FontVariation.new()
	fv.base_font = font
	fv.variation_embolden = 0.3    # semibold
	return {"font": fv, "size": MESSAGE_FONT_SIZE, "color": Color.WHITE, "classic": classic, "right": right}


## Text with Apple's `shadow(.black 0.9, radius 2, y 1)`.
func _shadow_string(font: Font, pos: Vector2, text: String, size: int, col: Color) -> void:
	draw_string(font, pos + Vector2(0, 1), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.9 * col.a))
	draw_string(font, pos + Vector2(1, 2), text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, Color(0, 0, 0, 0.45 * col.a))
	draw_string(font, pos, text, HORIZONTAL_ALIGNMENT_LEFT, -1, size, col)


## The Classic message rect for a `vp` window (AuthenticHUD.message_rect); Rect2() outside Classic.
func message_rect(vp: Vector2) -> Rect2:
	if not _classic_hud_on or _classic_hud == null:
		return Rect2()
	var h = _classic_hud.get_child(0)
	return AuthenticHUD.message_rect(vp, h.bar_width(vp), h.ui_scale(vp))


## The Classic message font size in px (12 pt x ui_scale) and the pen origin (baseline-left) the line is
## drawn at: the rect's left edge, its top + the font ascent (DrawPascalStringInFilledRect).
func message_font_px(vp: Vector2) -> int:
	if not _classic_hud_on or _classic_hud == null:
		return MESSAGE_FONT_SIZE
	return maxi(6, int(round(float(AuthenticHUD.MESSAGE_FONT_DESIGN) * _classic_hud.get_child(0).ui_scale(vp))))


func message_text_origin(vp: Vector2) -> Vector2:
	if not _classic_hud_on or _classic_hud == null:
		return Vector2(MESSAGE_PAD_LEFT, vp.y - MESSAGE_PAD_BOTTOM)
	var r: Rect2 = message_rect(vp)
	var f: Font = _classic_hud.get_child(0).text_font()
	return Vector2(r.position.x, r.position.y + f.get_ascent(message_font_px(vp)))


## The one-line status message (MessageLogView): bottom-left, 16 px in, 8 px up, clipped
## (no ellipsis) at the sidebar + 50 px; fades over its last 0.6 s.
func _draw_message_log(vp: Vector2) -> void:
	if _log.is_empty():
		return
	var ht := _hud_text()
	var entry: Dictionary = _log[0]
	var t: float = entry["age"]
	var col: Color = ht["color"]
	if bool(ht["classic"]):
		# Classic: the original's message rect (FUN_0087550b), 12 pt white, hanging from its top,
		# no shadow and no fade (the rect is simply refilled when the timer ends).
		var h = _classic_hud.get_child(0)
		var r: Rect2 = message_rect(vp)
		var cfont: Font = h.text_font()
		var cfs: int = message_font_px(vp)
		var ctext := str(entry["text"])
		while ctext.length() > 0 and cfont.get_string_size(ctext, HORIZONTAL_ALIGNMENT_LEFT, -1, cfs).x > r.size.x:
			ctext = ctext.substr(0, ctext.length() - 1)   # clipped to the rect, no ellipsis
		draw_string(cfont, message_text_origin(vp), ctext, HORIZONTAL_ALIGNMENT_LEFT, -1, cfs, Color.WHITE)
		return
	col.a = clampf((float(entry.get("life", LOG_LIFETIME)) - t) / LOG_FADE, 0.0, 1.0)
	var font: Font = ht["font"]
	var fs := int(ht["size"])
	var text := str(entry["text"])
	var max_w := vp.x - float(ht["right"]) - MESSAGE_PAD_LEFT - MESSAGE_PAD_RIGHT
	while text.length() > 0 and font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fs).x > max_w:
		text = text.substr(0, text.length() - 1)
	var base := vp.y - MESSAGE_PAD_BOTTOM - font.get_descent(fs)
	_shadow_string(font, Vector2(MESSAGE_PAD_LEFT, base), text, fs, col)


# The two playfield icons (B6): the "x2" cicn 20000 at the top-left while the effective speed is
# exactly 2x (Frame_AnchorX2IndicatorSprite 0x0042cbb0), and the low-volume Red Alert blink, cicn
# 18000 + parity at the playfield's top-right (FUN_0042cc30), driven by the shared RedAlertCue.
var _cicn_cache := {}

func _cicn_tex(id: int) -> Texture2D:
	if _cicn_cache.has(id):
		return _cicn_cache[id]
	var tex: Texture2D = null
	var info: PackedInt32Array = nova.cicn_info(id)
	if info.size() >= 2 and info[0] > 0 and info[1] > 0:
		var bytes: PackedByteArray = nova.cicn_rgba(id)
		if bytes.size() >= info[0] * info[1] * 4:
			tex = ImageTexture.create_from_image(Image.create_from_data(info[0], info[1], false, Image.FORMAT_RGBA8, bytes))
	_cicn_cache[id] = tex
	return tex


## [x2 icon rect or Rect2(), red-alert icon rect or Rect2(), red-alert cicn id or -1] for a `vp` window.
func alert_icon_layout(vp: Vector2) -> Array:
	var x2_rect := Rect2()
	if nova.x2_active():
		var t: Texture2D = _cicn_tex(20000)
		if t != null:
			x2_rect = Rect2(Vector2.ZERO, t.get_size())
	var frame: int = nova.red_alert_blink_frame()
	var rid := -1
	var ra_rect := Rect2()
	if frame >= 0:
		var t2: Texture2D = _cicn_tex(18000 + frame)
		if t2 != null:
			rid = 18000 + frame
			var right := vp.x
			if _classic_hud_on and _classic_hud != null:
				right -= float(_classic_hud.get_child(0).bar_width(vp))   # the playfield ends where the sidebar begins
			ra_rect = Rect2(Vector2(right - t2.get_size().x, 0.0), t2.get_size())
	return [x2_rect, ra_rect, rid]


func _draw_alert_icons(vp: Vector2) -> void:
	var vol: float = 0.0 if bool(Prefs.get_value("audio", "muted")) else float(Prefs.get_value("audio", "master")) * float(Prefs.get_value("audio", "sfx"))
	nova.set_alert_low_volume(vol * 7.0 < 2.0)   # the blink only shows below 2 of 7 (RedAlertCue)
	var lay: Array = alert_icon_layout(vp)
	var x2_rect: Rect2 = lay[0]
	if x2_rect.size.x > 0.0:
		draw_texture_rect(_cicn_tex(20000), x2_rect, false)
	var ra_rect: Rect2 = lay[1]
	if ra_rect.size.x > 0.0:
		draw_texture_rect(_cicn_tex(int(lay[2])), ra_rect, false)


# The Land control's name for prompts: the pad's button when a controller is connected,
# else the key.
func _land_label() -> String:
	return Controls.describe_buttons("land") if Controls.pad_connected() else Controls.describe_keys("land")


# In flight: the original's land hint while an approachable stellar is in reach
# (PlayerLanding.prompt, via the bridge): "Press L to request landing on X" before
# clearance, "Press L to land on X" after, "Slow down to land on X" when speed is what
# stops it — the Apple app's HUD text.
func _draw_land_prompt(vp: Vector2) -> void:
	var prompt: PackedStringArray = nova.land_prompt()
	if prompt.size() < 2 or prompt[0] == "none":
		return
	var spob_name := prompt[1]
	var text := ""
	match prompt[0]:
		"land": text = "Press %s to land on %s" % [_land_label(), spob_name]
		"request":
			text = "Press %s to request landing on %s" % [_land_label(), spob_name]
		_:
			text = "Slow down to land on " + spob_name
	# ContextualActionsView (desktop): the same white .hud line, centred over the play
	# area, 8 px up, a message-line higher while a message is showing.
	var ht := _hud_text()
	var font: Font = ht["font"]
	var fsz := int(ht["size"])
	var lift := MESSAGE_LINE_H if not _log.is_empty() else 0.0
	var w := font.get_string_size(text, HORIZONTAL_ALIGNMENT_LEFT, -1, fsz).x
	var cx := (vp.x - float(ht["right"])) * 0.5
	var pos := Vector2(cx - w * 0.5, vp.y - MESSAGE_PAD_BOTTOM - lift - font.get_descent(fsz))
	_shadow_string(font, pos, text, fsz, Color.WHITE)


# The original Nav panel (0x0045e400): title (Nav System Off / Stellar Navigation /
# Hyperspace) over the selected stellar or the armed next hop; the hop is dimmed until
# the jump could actually be made. Strings and state are the bridge's.
func _draw_nav_panel(vp: Vector2) -> void:
	var rd: PackedStringArray = nova.nav_readout()
	if rd.size() < 3:
		return
	var pos := Vector2(20, vp.y - 130)
	draw_string(ThemeDB.fallback_font, pos, rd[0], HORIZONTAL_ALIGNMENT_LEFT, -1, HUD_FONT_SIZE - 2,
		Color(0.7, 0.8, 0.9, 0.9))
	if rd[1] != "":
		var col := Color(0.55, 0.8, 1.0) if rd[2] != "1" else Color(0.45, 0.5, 0.58)
		draw_string(ThemeDB.fallback_font, pos + Vector2(0, 17), rd[1], HORIZONTAL_ALIGNMENT_LEFT, -1,
			HUD_FONT_SIZE, col)
