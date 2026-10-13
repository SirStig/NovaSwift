# NOVA Swift — Godot frontend settings store (user://settings.cfg).
#
# One ConfigFile, loaded once at startup and re-applied whenever the Settings
# screen changes something:
#
#   [audio]   master · sfx · ui · music (0…1) · muted
#   [video]   fullscreen · vsync · scale (window size multiple of 1280×720)
#   [input]   deadzone (Controls.stick_deadzone) · modern_keys (Controls.layout: the port's
#             earlier key layout instead of the original's, default off)
#   [map]     gate_links — draw hypergate / wormhole spokes on the plain galaxy map (an
#             enhancement; the original draws them only in the gate picker), default off
#   [presentation] modern_menu · modern_dialogs · modern_hud · fullscreen_galaxy_map — Classic
#             (all false, default) draws the original ïntf status bar, DLOG/DITL dialogs, main
#             menu and framed galaxy map from the user's data (ui/classic/); Enhanced is Classic
#             with the full-screen map; Nova Swift (all true) keeps the port's own screens. See
#             ui_mode()/apply_ui_mode().
#   [data]    dir — the EV Nova data folder chosen in the data-setup screen
#   [keys]    action -> { keys, buttons, alt_keys } — only what the player rebound
#
# Game speed (the Apple app's GameSpeedRules multiplier) is not exposed by the
# bridge yet, so there is deliberately no setting for it here.
#
# Loaded with preload() (no class_name), like Controls.gd. All state is static so
# every screen sees the same values.
extends RefCounted

const Controls = preload("res://Controls.gd")

const PATH := "user://settings.cfg"
const BASE_SIZE := Vector2i(1280, 720)
const SCALES := [0.75, 1.0, 1.25, 1.5, 2.0]

const DEFAULTS := {
	"audio": {"master": 1.0, "sfx": 1.0, "ui": 1.0, "music": 0.7, "muted": false},
	"video": {"fullscreen": false, "vsync": true, "scale": 1.0},
	"input": {"deadzone": Controls.STICK_DEADZONE, "modern_keys": false},
	"data": {"dir": ""},
	"map": {"gate_links": false},
	# Presentation (mirrors the Apple GameSettings modernMainMenu / modernDialogs /
	# modernHUD toggles). false = the authentic original UI (default); true = the
	# port's own "Nova Swift" screens. Classic = all off, Nova Swift = all on.
	# fullscreen_galaxy_map: the map edge to edge instead of inside its original dialog frame
	# (Apple fullscreenGalaxyMap; off in Classic, on in Enhanced and Nova Swift).
	"presentation": {"modern_menu": false, "modern_dialogs": false, "modern_hud": false,
		"fullscreen_galaxy_map": false},
}

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


## Back to factory settings for the sections the Settings screen's pages edit.
static func reset_section(section: String) -> void:
	for key in DEFAULTS.get(section, {}):
		set_value(section, key, DEFAULTS[section][key])


static func reset_bindings() -> void:
	Controls.reset_defaults()


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
	if bool(get_value("audio", "muted")):
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
