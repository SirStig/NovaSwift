# Godot settings keys (Apple `GameSettings` -> `Prefs.gd`)

For whoever builds the Settings rows (`godot/screens/Settings.gd` and the NovaSwift UI kit). Every Apple
`GameSettings` field with a Godot equivalent has a key in `godot/Prefs.gd` (`user://settings.cfg`), default = Apple's
default. A row only has to do `Prefs.set_value(section, key, value)` (and `Prefs.save()` when the page closes): nothing
else needs calling. `Prefs.hub.changed(section, key)` fires on every `set_value`, and the `SettingsPlumbing` autoload
(`godot/SettingsPlumbing.gd`) re-applies the engine and presentation settings once per frame. Reset a page with
`Prefs.reset_section(section)`.

Types: `bool`, `float`, `int`, `enum` (a `String` from the listed values; the values are Apple's raw values so a
picker can map `GameSettings.X.allCases` one to one).

Wired column: **yes** = the pref changes behaviour today (verified by `godot/tests/settings_plumbing_selfcheck.gd`
unless noted), **partial** = works in part (see note), **key only** = the key exists and persists but nothing reads it
yet (named owner/reason), **n/a** = Apple-only platform feature, no key.

## How the engine settings reach the bridge

`Prefs.engine_settings()` packs the gameplay prefs into a JSON object with Apple's property names and
`NovaWorld.apply_settings(json)` (`godot/bridge/Sources/NovaSwiftGodot/Settings.swift`) applies it to the live world and
every world built afterwards (difficulty -> `CombatTuning.playerDamageScale`, System Aliveness -> spawner model and
population scale, `GameplayEnhancements`, tight-formation flight tuning). `NovaWorld.settings_state()` reads back what
the engine is running with. The tables and rules are the shared `Sources/NovaSwiftEngine/GameSettingsRules.swift` and
`GameSpeedRules.swift`, the same code the Apple app calls.

## Gameplay (Apple: Settings > Gameplay, Port Options, Enhancements)

| Apple field | Prefs `section/key` | Type / range | Default | Apple label (section) | Wired |
|---|---|---|---|---|---|
| `difficulty` | `gameplay/difficulty` | enum `veryEasy` `easy` `normal` `hard` (damage taken x0.3 / 0.6 / 1.0 / 1.5) | `normal` | Difficulty (Port Options) | yes |
| `systemAliveness` | `gameplay/system_aliveness` | enum `original` `authentic` (Quiet) `normal` `bustling` | `original` | System Aliveness (Port Options) | yes (spawn model + population scale; existing systems update live) |
| `gameSpeed` | `gameplay/game_speed` | enum `x0_5` `x1` (labelled "Authentic") `x1_5` `x2` `x4` `x8` | `x1` | Game speed (Gameplay) | yes. Caps Lock doubles it (`GameSpeedRules`, the original's 2x mode; tracked by `SettingsPlumbing`, see below) |
| `autoTargetAfterFiring` | `gameplay/auto_target_after_firing` | bool | false | Auto-target after firing (Gameplay) | yes (engine flag; the rising edge of the primary trigger with no target locks the nearest hostile) |
| `confirmLanding` | `gameplay/confirm_landing` | bool | false | Confirm before landing (Gameplay) | yes ("Land here?" dialog drawn by `SettingsPlumbing`, port style in both presentations) |
| `autoLanding` | `gameplay/auto_landing` | bool | false | Auto-landing (Port Options) | yes (Land flies to the selected/nearest body and sets down; a manual turn/thrust or a second press cancels) |
| `tutorialHints` | `hints/enabled` | bool | true | Tutorial hints (Gameplay) | yes (existing `Hints.gd`); "Show all hints again" = `Prefs.reset_hints()` |
| `pauseOnFocusLoss` | `gameplay/pause_on_focus_loss` | bool | true | Pause when app loses focus (Gameplay) | yes (window focus lost in flight opens the pause menu) |
| `enhancements.manualPluginOrder` | n/a (kept in `plugins-state.json`) | bool | false | Manual plug-in order (Enhancements) | yes (plug-in manager) |
| `enhancements.formationFlying` | `gameplay/formation_flying` | bool | false | Tight formations (Enhancements) | yes (`FlightTuning.aiInertialess`; the galaxy is rebuilt, so it takes effect from the next system/world) |
| `enhancements.forgivingLanding` | `gameplay/forgiving_landing` | bool | false | Forgiving landing (Enhancements) | yes (one Land press, `radius + 70` at 130 px/s, no clearance step) |
| `enhancements.quickHyperjump` | `gameplay/quick_hyperjump` | bool | false | Quick hyperjump (Enhancements) | **key only**: the quick turn/burst jump phases are Apple `GameScene.stepJump` (app-side); the bridge flies the original jump. The flag reaches the engine but nothing consumes it |
| `enhancements.frequentAutosave` | `gameplay/frequent_autosave` | bool | false | Frequent autosave (Enhancements) | yes (existing) |
| `enhancements.autoRoutePlotting` | `gameplay/auto_route_plotting` | bool | false | Automatic route plotting (Enhancements) | yes (the galaxy map starts with it on/off; its map key still toggles it) |
| `enhancements.nearestFirstTargeting` | `gameplay/nearest_first_targeting` | bool | false | Nearest-first targeting (Enhancements) | yes (Tab cycle, R, Alt-R) |
| `enhancements.modernKeyBindings` | `input/modern_keys` | bool | false | Modern key layout (Enhancements) | yes (existing) |
| `enhancements.screenShake` | `graphics/screen_shake` | bool | false | Screen shake (Enhancements) | yes (flight renderer; suppressed by Reduce flashing) |

## Controls (Apple: Settings > Controls)

| Apple field | Prefs `section/key` | Type / range | Default | Apple label | Wired |
|---|---|---|---|---|---|
| `invertTurn` | `input/invert_turn` | bool | false | Invert turn direction | yes |
| `mouseAiming` | `input/mouse_aiming` | bool | false | Aim toward mouse cursor | yes (desktop; ship turns toward the pointer while flying, the right stick and turn keys win) |
| `stickDeadzone` | `input/deadzone` | float 0..0.5 | `Controls.STICK_DEADZONE` | Stick dead zone | yes (existing) |
| `controlScheme`, `tiltSensitivity`, `cursorSensitivity`, `hapticsEnabled` | none | | | Touch flying, tilt, cursor speed, haptics | n/a (touch/tilt/virtual cursor/haptics) |
| (port) Controller on-screen keyboard | `ui/pad_keyboard` | enum `auto` `off` | `auto` | (Apple opens its pad keyboard on Cursor-click) | yes (`godot/ui/PadKeyboard.gd`) |

## Graphics (Apple: Settings > Graphics)

| Apple field | Prefs `section/key` | Type / range | Default | Apple label | Wired |
|---|---|---|---|---|---|
| `frameRateCap` | `graphics/frame_rate_cap` | enum `fps30` `fps60` `fps120` `unlimited` | `fps60` (Apple macOS default) | Frame rate limit | yes (`Engine.max_fps`; not applied headless) |
| `showFPS` | `graphics/show_fps` | bool | false | Show FPS counter (HUD & Interface) | yes (top-right label) |
| `smoothSprites` | `graphics/smooth_sprites` | bool | false | Smooth sprite scaling | yes (flight world `texture_filter`; set, visual not checked on a GPU) |
| `starfieldDensity` | `graphics/starfield_density` | float 0.2..2 | 1.0 | (graphics quality presets only) | **key only**: `flight/StarfieldDrawer.gd` (flight agent) uses the original's `star_count` |
| `particleDensity` | `graphics/particle_density` | enum `full` `reduced` `minimal` | `full` | Particle effects | **key only**: `flight/EffectsDrawer.gd` (flight agent) |
| `engineGlow` | `classic/engine_glow` | bool | true | Engine & weapon glow | yes (existing key, shared with the Classic Preferences window) |
| `ceHyperspaceLook` | `graphics/ce_hyperspace_look` | bool | false | Windows hyperspace look | **key only**: `screens/HyperjumpFx.gd` has no CE variant |
| `noHyperspaceEffects` | `classic/hyperspace_effects` (same polarity as Apple's "Hyperspace effects" toggle: true = effects on) | bool | true | Hyperspace effects | yes (existing, `HyperjumpFx.gd`) |
| `shipBarPosition` | `graphics/ship_bar_position` | enum `above` `below` `off` | `off` | Hull / shield bars | **key only**: no ship bars are drawn (flight agent) |
| `showPlanetLabels` | `graphics/show_planet_labels` | bool | false | Show planet names | **key only**: no stellar labels are drawn (flight agent) |
| `cameraView` | `graphics/camera_view` | int 0..3 (Classic, Look ahead, Ship up, Chase) | 0 | Camera view | yes (flight agent) |
| `cameraZoom` | `graphics/camera_zoom` | float 0.5..3 | 1.0 | (zoom) | yes (flight agent) |
| `chaseTilt` | `graphics/chase_tilt` | float degrees | 30 | Chase tilt | yes (flight agent) |
| `hdGraphics`, `hdDetail`, `hullPresentation`, `modelDetail`, `liveLighting`, quality presets | none | | | HD / 3D options | n/a for now (no HD pipeline in Godot, parity package 9) |
| classic Preferences: `smokeTrails`, `shipAnimations`, `runningLights`, `weaponEffects`, `parallaxStarfield` | `classic/smoke_trails`, `ship_animations`, `running_lights`, `weapon_effects`, `parallax_starfield` | bool | true | Original Preferences window | yes (flight renderer) |
| classic: `playMovies`, `ambientSounds`, `shareProcessorTime`, `checkForUpdates`, `brightnessStep` | `classic/play_movies`, `ambient_sounds`, `share_processor_time`, `check_for_updates`, `brightness_step` | bool / int 0..5 | true / false / 3 | Original Preferences window | key only (no movies, no ambient loop, no brightness ramp in Godot) |
| classic: `introMusic`, `soundVolumeStep` | `classic/intro_music`, `classic/sound_volume_step` | bool / int 0..7 | true / 5 | Original Preferences window | yes (existing) |

## Audio (Apple: Settings > Audio)

| Apple field | Prefs `section/key` | Type / range | Default | Apple label | Wired |
|---|---|---|---|---|---|
| `masterVolume` | `audio/master` | float 0..1 | 1.0 | Master | yes |
| `musicVolume` | `audio/music` | float 0..1 | 0.7 | Music | yes |
| `sfxVolume` | `audio/sfx` | float 0..1 | 1.0 (Apple 0.9) | Effects | yes |
| `uiVolume` | `audio/ui` | float 0..1 | 1.0 (Apple 0.8) | Interface | yes |
| `muteAll` | `audio/muted` | bool | false | Mute all | yes |
| `musicEnabled` | `audio/music_enabled` | bool | true | Background music | yes (title music gain) |

## HUD, interface and presentation (Apple: Settings > Presentation, Interface Options, HUD & Interface)

| Apple field | Prefs `section/key` | Type / range | Default | Apple label | Wired |
|---|---|---|---|---|---|
| `fullscreenGalaxyMap` / `modernMainMenu` / `modernDialogs` / `modernHUD` | `presentation/fullscreen_galaxy_map` / `modern_menu` / `modern_dialogs` / `modern_hud` | bool | false | Full-screen galaxy map / Modern main menu / Modern dialog chrome / Modern HUD; presets via `Prefs.apply_ui_mode` | yes (existing) |
| `sidebarPauseMenu` | `interface/sidebar_pause_menu` | bool | true | Sidebar pause menu | **key only**: Godot has one pause menu |
| `showMissionStorylineTags` | `story/show_mission_storyline_tags` | bool | true | Show mission storyline tags | yes (existing) |
| `showRadar` | `interface/show_radar` | bool | true | Show radar | partial: the primitive (Nova Swift) HUD hides it; the Classic `ïntf` radar (`ui/classic/AuthenticHUD.gd`) still draws it |
| `hudOpacity` | `interface/hud_opacity` | float 0.2..1 | 1.0 | HUD opacity | yes (primitive HUD and the Classic status bar; the world stays opaque) |
| `uiScale` | `interface/ui_scale` | float 0.8..1.4 | 1.0 | Overall UI scale | partial: sets the window `content_scale_factor`, so it scales every screen and the flight view's visible area too |
| `largerHUD` | `accessibility/larger_hud` | bool | false | Larger HUD | partial: primitive HUD x1.28 (Apple's factor); the Classic `ïntf` bar is fixed art |
| `highContrastHUD` | `accessibility/high_contrast_hud` | bool | false | High-contrast HUD | partial: primitive HUD bars (solid black, bright border); not the Classic bar |
| `debugModeEnabled` / `uiDebugOverlay` | `developer/debug_mode` / `developer/ui_debug_overlay` | bool | false | Debug mode (Developer) | yes (existing) |
| `iCloudSaves`, `iCloudGameData` | none | | | iCloud sync (Saved Games) | n/a |

## Accessibility (Apple: Settings > Accessibility)

| Apple field | Prefs `section/key` | Type / range | Default | Apple label | Wired |
|---|---|---|---|---|---|
| `reduceFlashing` | `graphics/reduce_flashing` | bool | false | Reduce flashing & motion | yes (flight agent: particles, flashes, shake, jump flash) |
| `colorblindMode` | `accessibility/colorblind_mode` | enum `none` `protanopia` `deuteranopia` `tritanopia` | `none` | Colorblind mode | yes (screen-space shader using the engine's `ColorblindFilter` matrix, over everything) |

## Caps Lock 2x (no key; a live input)

The original's Caps Lock toggles the 2x speed mode. Godot cannot query the lock state, so `SettingsPlumbing` tracks the
key (macOS: key down = on; elsewhere each tap toggles) and calls `NovaWorld.set_caps_lock`. The bridge then runs
`GameSpeedRules` (effective multiplier = Settings speed x 2; a jump that began at 1x/2x holds its speed). A row may show
the state with `NovaWorld.x2_active()` / `speed_multiplier()`. If the OS lock and the tracked state ever disagree, a
Settings button can call `SettingsPlumbing.set_caps_lock(bool)`.

## Pad keyboard (no Settings row required)

`ui/PadKeyboard.gd` is an autoload; any `LineEdit` that takes focus while the last input was a gamepad opens it. A row
for `ui/pad_keyboard` (`auto` / `off`) is optional. API: `PadKeyboard.attach(line_edit, {title, suggestions, style, auto})`,
`PadKeyboard.open_for(line_edit)`, `PadKeyboard.close(commit)`, `PadKeyboard.is_open()`, `PadKeyboard.pad_active()`.
