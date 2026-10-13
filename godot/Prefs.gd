# NOVA Swift — Godot frontend settings store (user://settings.cfg).
#
# One ConfigFile, loaded once at startup and re-applied whenever the Settings
# screen changes something:
#
#   [audio]   master · sfx · ui · music (0…1) · muted
#   [video]   fullscreen · vsync · scale (window size multiple of 1280×720)
#   [input]   deadzone (Controls.stick_deadzone) · modern_keys (Controls.layout: the port's
#             earlier key layout instead of the original's, default off)
#   [gameplay] frequent_autosave · difficulty · system_aliveness · game_speed · auto_target_after_firing ·
#             confirm_landing · auto_landing · pause_on_focus_loss · the enhancement toggles
#   [graphics] screen_shake · reduce_flashing · camera_view (0-3) · camera_zoom · chase_tilt -- flight camera and
#             accessibility (flight/FlightRenderer.gd reads them) · starfield_density · show_fps · smooth_sprites ·
#             particle_density · frame_rate_cap · ce_hyperspace_look · ship_bar_position · show_planet_labels
#   [interface] show_radar · hud_opacity · ui_scale · sidebar_pause_menu
#   [accessibility] larger_hud · high_contrast_hud · colorblind_mode
#   [ui]      pad_keyboard (auto|off)
#   [map]     gate_links — draw hypergate / wormhole spokes on the plain galaxy map (an
#             enhancement; the original draws them only in the gate picker), default off
#   [presentation] modern_menu · modern_dialogs · modern_hud · fullscreen_galaxy_map — Classic
#             (all false, default) draws the original ïntf status bar, DLOG/DITL dialogs, main
#             menu and framed galaxy map from the user's data (ui/classic/); Enhanced is Classic
#             with the full-screen map; Nova Swift (all true) keeps the port's own screens. See
#             ui_mode()/apply_ui_mode().
#   [developer] debug_mode · ui_debug_overlay · collapsed_sections -- the debug suite (debug/)
#   [data]    dir — the EV Nova data folder chosen in the data-setup screen
#   [pilots]  dir (the Pilots folder; "" = the default, see screens/PilotFiles.gd) · recent (paths of
#             pilot files opened lately) · migrated (user://pilots copied across once)
#   [classic] the original Preferences window's (DLOG 4003) flags and levels (screens/ClassicPreferences.gd)
#   [keys]    action -> { keys, buttons, alt_keys } — only what the player rebound
#
# Every GameSettings field with a Godot equivalent has a key here (docs/GODOT_SETTINGS_KEYS.md is the
# table). The engine-side ones reach the bridge through engine_settings() -> NovaWorld.apply_settings
# (SettingsPlumbing.gd autoload, which re-applies on Prefs.hub.changed); the rest are read where they act.
#
# Loaded with preload() (no class_name), like Controls.gd. All state is static so
# every screen sees the same values.
extends RefCounted

const Controls = preload("res://Controls.gd")

const PATH := "user://settings.cfg"
const BASE_SIZE := Vector2i(1280, 720)
const SCALES := [0.75, 1.0, 1.25, 1.5, 2.0]

const DEFAULTS := {
	"audio": {"master": 1.0, "sfx": 1.0, "ui": 1.0, "music": 0.7, "muted": false, "music_enabled": true},
	"video": {"fullscreen": false, "vsync": true, "scale": 1.0},
	# invert_turn / mouse_aiming: Apple invertTurn / mouseAiming (both off = the original's feel).
	"input": {"deadzone": Controls.STICK_DEADZONE, "modern_keys": false, "invert_turn": false,
		"mouse_aiming": false,
		# Controls Editor pickers (screens/controls_editor): keyboard size preset (full / tkl / compact), pad art style.
		"ctl_preset": "full", "ctl_pad_style": "auto"},
	"data": {"dir": ""},
	"pilots": {"dir": "", "recent": [], "migrated": false},
	# The original's Preferences window (NovaPrefs_ResetToDefaults: volume 5, brightness 3, all on
	# but update checks). Only the flags the Godot build has an equivalent for take effect (see
	# ClassicPreferences.gd); the rest are stored so the dialog round-trips.
	"classic": {"share_processor_time": true, "intro_music": true, "play_movies": true,
		"smoke_trails": true, "ship_animations": true, "engine_glow": true, "running_lights": true,
		"weapon_effects": true, "parallax_starfield": true, "ambient_sounds": true,
		"hyperspace_effects": true, "check_for_updates": false,
		"sound_volume_step": 5, "brightness_step": 3},
	"map": {"gate_links": false},
	# Tutorial hints (Apple GameSettings.tutorialHints + the per-install UserDefaults seen flags):
	# enabled gates the one-time hint cards, flight training offer; seen = the NovaHints storage keys
	# already dismissed, flight_card = the first-flight "Getting started" card, completed = flight
	# training finished or skipped once (TutorialProgress.hasCompleted).
	"hints": {"enabled": true, "seen": [], "flight_card": false, "completed": false},
	# Apple GameplayEnhancements.frequentAutosave (default off = the original's save points only).
	# The rest of Apple GameSettings' Gameplay section and GameplayEnhancements (engine-side, pushed to
	# the bridge by SettingsPlumbing.gd / engine_settings()). difficulty: veryEasy|easy|normal|hard;
	# system_aliveness: original|authentic|normal|bustling; game_speed: x0_5|x1|x1_5|x2|x4|x8 (x1 =
	# "Authentic", real time; Caps Lock doubles whichever is chosen). The five *_landing .. *_targeting
	# booleans are the enhancement toggles (all off = the original).
	"gameplay": {"frequent_autosave": false, "difficulty": "normal", "system_aliveness": "original",
		"game_speed": "x1", "auto_target_after_firing": false, "confirm_landing": false, "auto_landing": false,
		"pause_on_focus_loss": true, "formation_flying": false, "forgiving_landing": false,
		"quick_hyperjump": false, "auto_route_plotting": false, "nearest_first_targeting": false},
	# In-flight presentation (Apple GameSettings: enhancements.screenShake, reduceFlashing, cameraView,
	# cameraZoom, chaseTilt). Classic defaults: no shake, the original's fixed north-up camera at 1:1.
	# camera_view indexes flight/FlightCamera.gd VIEWS (0 Classic, 1 Look ahead, 2 Ship up, 3 Chase).
	# Plus Apple's Graphics section: starfield_density 0.2-2, show_fps, smooth_sprites (linear instead of
	# crisp), particle_density full|reduced|minimal, frame_rate_cap fps30|fps60|fps120|unlimited,
	# ce_hyperspace_look, ship_bar_position above|below|off, show_planet_labels.
	"graphics": {"screen_shake": false, "reduce_flashing": false, "camera_view": 0, "camera_zoom": 1.0,
		"chase_tilt": 30.0, "starfield_density": 1.0, "show_fps": false, "smooth_sprites": false,
		"particle_density": "full", "frame_rate_cap": "fps60", "ce_hyperspace_look": false,
		"ship_bar_position": "off", "show_planet_labels": false},
	# Apple's Interface HUD options (show_radar, hud_opacity 0.2-1) and the overall ui_scale (0.8-1.4).
	"interface": {"show_radar": true, "hud_opacity": 1.0, "ui_scale": 1.0, "sidebar_pause_menu": true},
	# Apple's Accessibility section. reduce_flashing lives in [graphics] (the flight agent's key) and
	# noHyperspaceEffects is [classic] hyperspace_effects, inverted (screens/HyperjumpFx.gd reads it);
	# colorblind_mode: none|protanopia|deuteranopia|tritanopia.
	"accessibility": {"larger_hud": false, "high_contrast_hud": false, "colorblind_mode": "none"},
	# The gamepad on-screen keyboard (ui/PadKeyboard.gd): auto = opens when a text field takes focus
	# while the last input was a gamepad; off = never.
	"ui": {"pad_keyboard": "auto"},
	# Story Guide: the amber storyline badge on mission rows (Apple showMissionStorylineTags).
	"story": {"show_mission_storyline_tags": true},
	# Presentation (mirrors the Apple GameSettings modernMainMenu / modernDialogs /
	# modernHUD toggles). false = the authentic original UI (default); true = the
	# port's own "Nova Swift" screens. Classic = all off, Nova Swift = all on.
	# fullscreen_galaxy_map: the map edge to edge instead of inside its original dialog frame
	# (Apple fullscreenGalaxyMap; off in Classic, on in Enhanced and Nova Swift).
	# Developer (Apple GameSettings.debugModeEnabled / uiDebugOverlay): gates the debug suite
	# (debug/DevTools.gd). Settings > Support > Debug mode.
	"developer": {"debug_mode": false, "ui_debug_overlay": false, "collapsed_sections": ""},
	"presentation": {"modern_menu": false, "modern_dialogs": false, "modern_hud": false,
		"fullscreen_galaxy_map": false},
}

## Emits (section, key) from every set_value, so anything that mirrors a setting (the engine plumbing,
## the colorblind shader, the FPS counter...) can follow it live. Connect to Prefs.hub.changed.
class Hub extends RefCounted:
	signal changed(section: String, key: String)

static var hub := Hub.new()
static var _cfg := ConfigFile.new()
static var _loaded := false
## Where load_all/save read and write; tests point it at a scratch file.
static var path := PATH


static func load_all() -> void:
	_cfg = ConfigFile.new()
	_cfg.load(path)   # a missing file is fine: every getter falls back to DEFAULTS
	_loaded = true
	Controls.stick_deadzone = float(get_value("input", "deadzone"))
	Controls.layout = Controls.LAYOUT_MODERN if bool(get_value("input", "modern_keys")) else Controls.LAYOUT_ORIGINAL
	Controls.overrides = {}
	if _cfg.has_section("keys"):
		for action in _cfg.get_section_keys("keys"):
			if Controls.BINDINGS.has(action) and _cfg.get_value("keys", action) is Dictionary:
				Controls.overrides[action] = _cfg.get_value("keys", action)


static func save() -> void:
	if not _loaded:
		load_all()
	if _cfg.has_section("keys"):
		_cfg.erase_section("keys")
	for action in Controls.overrides:
		_cfg.set_value("keys", action, Controls.overrides[action])
	_cfg.save(path)


static func get_value(section: String, key: String) -> Variant:
	if not _loaded:
		load_all()
	return _cfg.get_value(section, key, DEFAULTS.get(section, {}).get(key))


static func set_value(section: String, key: String, value: Variant) -> void:
	if not _loaded:
		load_all()
	_cfg.set_value(section, key, value)
	if section == "input" and key == "deadzone":
		Controls.stick_deadzone = float(value)
	elif section == "input" and key == "modern_keys":
		Controls.layout = Controls.LAYOUT_MODERN if bool(value) else Controls.LAYOUT_ORIGINAL
	hub.changed.emit(section, key)


## Back to factory settings for the sections the Settings screen's pages edit.
static func reset_section(section: String) -> void:
	for key in DEFAULTS.get(section, {}):
		set_value(section, key, DEFAULTS[section][key])


static func reset_bindings() -> void:
	Controls.reset_defaults()


## Push the saving settings (Frequent autosave) onto the bridge.
static func apply_saving(nova: Object) -> void:
	if nova != null and nova.has_method("set_frequent_autosave"):
		nova.set_frequent_autosave(bool(get_value("gameplay", "frequent_autosave")))


## The Apple GameSettings fields the engine applies, as the JSON object NovaWorld.apply_settings takes
## (keys and raw values are Apple's: difficulty "easy", gameSpeed "x1_5", enhancements {...}).
static func engine_settings() -> Dictionary:
	return {
		"difficulty": str(get_value("gameplay", "difficulty")),
		"systemAliveness": str(get_value("gameplay", "system_aliveness")),
		"gameSpeed": str(get_value("gameplay", "game_speed")),
		"autoTargetAfterFiring": bool(get_value("gameplay", "auto_target_after_firing")),
		"confirmLanding": bool(get_value("gameplay", "confirm_landing")),
		"autoLanding": bool(get_value("gameplay", "auto_landing")),
		"invertTurn": bool(get_value("input", "invert_turn")),
		"enhancements": {
			"formationFlying": bool(get_value("gameplay", "formation_flying")),
			"forgivingLanding": bool(get_value("gameplay", "forgiving_landing")),
			"quickHyperjump": bool(get_value("gameplay", "quick_hyperjump")),
			"frequentAutosave": bool(get_value("gameplay", "frequent_autosave")),
			"autoRoutePlotting": bool(get_value("gameplay", "auto_route_plotting")),
			"nearestFirstTargeting": bool(get_value("gameplay", "nearest_first_targeting")),
			"modernKeyBindings": bool(get_value("input", "modern_keys")),
			"screenShake": bool(get_value("graphics", "screen_shake")),
		},
	}


# --- HUD options (Apple GameSettings showRadar / hudOpacity / largerHUD / highContrastHUD) -----

static func show_radar() -> bool:
	return bool(get_value("interface", "show_radar"))


static func hud_opacity() -> float:
	return clampf(float(get_value("interface", "hud_opacity")), 0.2, 1.0)


## The modern HUD's scale: Apple's largerHUD is x1.28.
static func hud_scale() -> float:
	return 1.28 if bool(get_value("accessibility", "larger_hud")) else 1.0


static func hud_high_contrast() -> bool:
	return bool(get_value("accessibility", "high_contrast_hud"))


## Push every engine-side setting onto the bridge (also the saving one).
static func apply_engine(nova: Object) -> void:
	if nova == null:
		return
	if nova.has_method("apply_settings"):
		nova.apply_settings(JSON.stringify(engine_settings()))
	apply_saving(nova)


# --- tutorial hints (Apple HintTracker / TutorialProgress) -----------------------------------

static func hints_enabled() -> bool:
	return bool(get_value("hints", "enabled"))


static func hint_seen(key: String) -> bool:
	var seen = get_value("hints", "seen")
	return seen is Array and seen.has(key)


static func mark_hint_seen(key: String) -> void:
	var seen = get_value("hints", "seen")
	var list: Array = seen.duplicate() if seen is Array else []
	if not list.has(key):
		list.append(key)
		set_value("hints", "seen", list)
		save()


## "Show all hints again": the contextual hints and the first-flight card.
static func reset_hints() -> void:
	set_value("hints", "seen", [])
	set_value("hints", "flight_card", false)
	save()


static func tutorial_completed() -> bool:
	return bool(get_value("hints", "completed"))


static func mark_tutorial_completed() -> void:
	set_value("hints", "completed", true)
	save()


## Push the audio settings onto a GameAudio node (master / sfx / ui / muted).
static func apply_audio(audio: Object) -> void:
	if audio == null:
		return
	audio.master_volume = float(get_value("audio", "master"))
	audio.sfx_volume = float(get_value("audio", "sfx"))
	audio.ui_volume = float(get_value("audio", "ui"))
	audio.muted = bool(get_value("audio", "muted"))


## Linear gain for the title music: master × music, 0 when muted.
static func music_gain() -> float:
	if bool(get_value("audio", "muted")) or not bool(get_value("audio", "music_enabled")):
		return 0.0
	return float(get_value("audio", "master")) * float(get_value("audio", "music"))


static func apply_video() -> void:
	if DisplayServer.get_name() == "headless":
		return
	DisplayServer.window_set_vsync_mode(
		DisplayServer.VSYNC_ENABLED if bool(get_value("video", "vsync")) else DisplayServer.VSYNC_DISABLED)
	if bool(get_value("video", "fullscreen")):
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_FULLSCREEN)
	else:
		DisplayServer.window_set_mode(DisplayServer.WINDOW_MODE_WINDOWED)
		var size := Vector2i((Vector2(BASE_SIZE) * float(get_value("video", "scale"))).round())
		DisplayServer.window_set_size(size)


# --- presentation presets (Apple GameSettings.UIMode) ---------------------------

const UI_CLASSIC := "classic"
const UI_ENHANCED := "enhanced"
const UI_NOVA_SWIFT := "nova_swift"
const UI_CUSTOM := "custom"

const _UI_FLAGS := ["modern_menu", "modern_dialogs", "modern_hud", "fullscreen_galaxy_map"]


## "classic" (all authentic), "enhanced" (authentic + the full-screen map), "nova_swift" (all
## modern) or "custom" (mixed) -- Apple GameSettings.matchedPreset.
static func ui_mode() -> String:
	var on := {}
	for k in _UI_FLAGS:
		on[k] = bool(get_value("presentation", k))
	var count := on.values().count(true)
	if count == 0:
		return UI_CLASSIC
	if count == _UI_FLAGS.size():
		return UI_NOVA_SWIFT
	if count == 1 and on["fullscreen_galaxy_map"]:
		return UI_ENHANCED
	return UI_CUSTOM


## Stamp the toggles from a preset (UI_CUSTOM is a no-op).
static func apply_ui_mode(mode: String) -> void:
	if mode == UI_CUSTOM:
		return
	for k in _UI_FLAGS:
		var on: bool = mode == UI_NOVA_SWIFT or (mode == UI_ENHANCED and k == "fullscreen_galaxy_map")
		set_value("presentation", k, on)


## Whether the galaxy map draws edge to edge (otherwise inside its original dialog frame).
static func fullscreen_map() -> bool:
	return bool(get_value("presentation", "fullscreen_galaxy_map"))


# --- game data location -------------------------------------------------------

## Folders searched for EV Nova data, first hit wins: NOVA_DATA_DIR, the folder
## chosen in the data-setup screen, the repo's git-ignored data/base, the
## per-user Godot data dir, and the XDG location on Linux / Steam Deck.
static func data_candidates() -> PackedStringArray:
	var out := PackedStringArray()
	var env := OS.get_environment("NOVA_DATA_DIR")
	if env != "":
		out.append(env)
	var saved := str(get_value("data", "dir"))
	if saved != "":
		out.append(saved)
	out.append(ProjectSettings.globalize_path("res://") + "../data/base")
	out.append(ProjectSettings.globalize_path("user://data"))
	var home := OS.get_environment("HOME")
	if home == "" :
		home = OS.get_environment("USERPROFILE")
	if home != "":
		out.append(home.path_join(".local/share/NovaSwift/data"))
	return out


## First candidate that actually loads on `nova`, or "".
static func find_data(nova: Object) -> String:
	for dir in data_candidates():
		if DirAccess.dir_exists_absolute(dir) and nova.load_game(dir):
			return dir
	return ""
