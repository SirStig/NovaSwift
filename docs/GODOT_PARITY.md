# Godot frontend parity audit

Goal: the Godot build (`godot/`) has everything the Apple app (`app/NovaSwift/`) has, except Apple-only platform
features, with original-game fidelity as the default. This is a read-only audit of Apple vs Godot as of 2026-10-12
(commit `2c59e3c` plus the uncommitted spaceport-reskin work, which is mid-change and not judged here).

Method: every file in `app/NovaSwift/{App,Audio,Data,Debug,Game,Input,Launcher,Pilots,Plugins,Spaceport,Story,Tutorial,UI,Multiplayer,Editor}`
was matched against `godot/` (GDScript screens, `godot/ui/classic/`, `godot/audio/`, `Main.gd`, `Controls.gd`, `Prefs.gd`) and the bridge
(`godot/bridge/Sources/NovaSwiftGodot/`). Status vocabulary:

* **DONE** equivalent. **PARTIAL** exists but differs (gap says how). **MISSING** nothing in Godot.
* **N/A** Apple-only platform thing (Game Center, iCloud, tilt, haptics, tvOS, App Store, touch overlay).
* **DESKTOP** not Apple-only but low priority (Plugin Editor is macOS-only in Apple; counts as a desktop candidate).

Effort: S = under a day, M = 1-3 days, L = a week or more. "Shared" means the logic already lives in `Sources/` and only needs a bridge call plus Godot layout.

Notation: statuses were verified by grep of `godot/` and the bridge. Anything marked "(verify)" was inferred from file names and should be eyeballed by the package owner.

## Summary

| Area | DONE | PARTIAL | MISSING | N/A | DESKTOP |
|---|---|---|---|---|---|
| 1. App shell, menus, data setup (Apple: App, Launcher, Data, UI) | 4 | 8 | 6 | 3 | 0 |
| 2. Settings (every `GameSettings` field, `App/GameSettings.swift`) | 5 | 4 | 35 | 2 | 0 |
| 3. Flight visuals (Apple: `Game/GameScene.swift`, `HullAnimation.swift`; Godot: `Main.gd` `_draw`) | 10 | 10 | 18 | 0 | 0 |
| 4. HUD (Apple: `Game/AuthenticHUDView.swift`, `GameHUD.swift`, `ContextualActionsView.swift`) | 3 | 3 | 3 | 2 | 0 |
| 5. Input and camera (Apple: `Input/`) | 4 | 1 | 2 | 2 | 0 |
| 6. Spaceport and economy (Apple: `Spaceport/`) | 8 | 4 | 2 | 0 | 0 |
| 7. Story, missions, Story Map (Apple: `Story/`) | 6 | 2 | 1 | 0 | 0 |
| 8. Pilots and saves (Apple: `Pilots/`, `Game/PilotStore.swift`) | 2 | 3 | 3 | 1 | 0 |
| 9. Plug-ins, HD packs, content loading (Apple: `Plugins/`, `Data/HDGraphics.swift`, `PluginsModel.swift`) | 4 | 2 | 5 | 1 | 2 |
| 10. Audio (Apple: `Audio/`) | 2 | 1 | 2 | 0 | 0 |
| 11. Tutorial, hints, intro (Apple: `Tutorial/`, `Pilots/IntroSequenceView.swift`) | 0 | 0 | 4 | 0 | 0 |
| 12. Debug suite and dev tools (Apple: `Debug/`) | 0 | 0 | 16 | 0 | 1 |
| 14. Interactions: hail, plunder, comms, negotiation, escorts | 3 | 2 | 0 | 0 | 0 |
| **Total** | 49 | 38 | 101 | 11 | 3 |

Section 13 (About) is a root-cause write-up, counted under section 1 and package 3. Headline: shared rules are largely ported; the gaps are presentation fidelity, tooling (Story Map, Debug Suite), settings plumbing, and content loading (plug-ins, HD, movies).


---

## 1. App shell, menus, data setup (Apple: App, Launcher, Data, UI)

| Feature | Apple file(s) | Godot status | Gap detail | Effort |
|---|---|---|---|---|
| Authentic main menu (PICT 8000, 6 buttons, shutters, pilot readout) | `Launcher/AuthenticMainMenuView.swift` | PARTIAL | `ui/classic/ClassicMainMenu.gd` done; missing "has been killed" and "Creating Pilot..." readout states (noted in GODOT_LAYER) | S |
| Modern main menu (New/Open/Enter/Settings/About/Plug-ins/Import) | `Launcher/ModernMainMenuView.swift` | PARTIAL | `screens/MainMenu.gd` plain path has no About, Plug-ins entries | S |
| **About Nova (dësc 32767)** | `Launcher/AuthenticMainMenuView.swift:298`, `UI/DescTextDialog.swift`, `Sources/NovaSwiftKit/DescDialogLayout.swift`, `Launcher/Branding.swift` (`AboutNovaText`) | DONE (2026-10-12) | `ClassicDialog.desc_dialog` on DITL 3003/3004, shared shrink, scroll, NovaSwift header, `<REG>`; plain menu has an About button too | - |
| NovaSwift About box (version, credits, repo/report links) | `Launcher/Branding.swift` `AboutView` | MISSING | No version/credits/links screen anywhere in Godot | S |
| Preferences (Classic DLOG 4003: Smoke Trails, Engine Glows, Running Lights, Weapon Effects, Parallax, Ambient, Hyperspace Fx, volume/brightness arrows, Key Settings) | `Launcher/ClassicPreferencesView.swift`, `ClassicKeySettingsView.swift` | PARTIAL | `screens/ClassicPreferences.gd` (DLOG 4003 via the kit, from Settings > Interface > Original Preferences Window...; Preferences still opens NovaSwift Settings first). Prefs `[classic]` holds every flag; only volume (master, snd 154) and Intro Music take effect. Key Settings opens the NovaSwift Controls page; the 34-cell DITL 4002 dialog is not ported | S |
| Settings screen (port's own) | `Launcher/SettingsView.swift` | PARTIAL | `screens/Settings.gd` restyled like Apple (sidebar + grouped sections, amber check boxes/sliders, Reset All, Pilots folder); still 5 pages (Interface, Controls, Graphics, Audio, Data & Advanced); gameplay/enhancements/accessibility categories are the section 2 gaps | M |
| Controls/key rebinding UI | `Launcher/ControlsView.swift`, `Input/KeyBindings.swift`, `PadBindings.swift` | DONE | `Settings.gd` Controls page, `Controls.gd`, swap-on-conflict, original vs modern layout | - |
| Launcher/first-run data wizard (platform guide, import, legal framing) | `Launcher/DataSetupWizard.swift`, `LauncherView.swift` | PARTIAL | `screens/DataSetup.gd` = folder picker + rescan + Run Demo; no guided wizard, no "I don't have it yet" help | M |
| Data import (copy .rez/.ndat, music mp3, fonts, race video into app dir) | `Data/DataImporter.swift`, `GameDataController.swift` | PARTIAL | Godot reads an in-place folder (`Prefs [data] dir`); no copy/managed data dir; music/fonts located by search only | S |
| Web import server (phone to desktop upload) | `Data/WebImportServer.swift` | N/A | iOS/Mac convenience; desktop uses folder picker | - |
| Game data cloud sync | `Data/GameDataCloudSync.swift`, `docs/ICLOUD_SYNC.md` | N/A | iCloud | - |
| Loading screen with progress, tips | `Launcher/LoadingView.swift`, `Data/GameDataController.swift` (prewarm) | DONE | `screens/LoadingScreen.gd` + `Shell.show_loading/set_loading_progress/hide_loading`; data loads on a worker thread (`load_game_async`/`load_status`, coarse real phases); shown only after 0.25 s. No sprite prewarm exists in Godot to report. Not verified visually | S |
| Pause menu (Resume, Galaxy Map, Pilot Info, Missions, **Story Guide**, Preferences, Report Issue, Full Screen, **Debug Suite**, Multiplayer, Save, Load, Main Menu) | `Game/GameMenuView.swift` | PARTIAL | `screens/PauseMenu.gd` has Resume, Settings, Save & Quit, Quit, Player Info and Story Map; no Debug, Report, Load Pilot, sidebar variant | S |
| Classic dialog kit (DLOG/DITL, 3-state art buttons, prompts) | `UI/ClassicDITLDialog.swift`, `ClassicPrompts.swift`, `ClassicUiWindow.swift`, `DITLPlacement.swift`, `NovaButton` | DONE | `ui/classic/ClassicDialog.gd`, `ClassicButton.gd` | - |
| Modern dialog chrome (NovaDialog, NovaAlert, form controls) | `UI/NovaDialog.swift`, `NovaAlert.swift`, `NovaFormControls.swift`, `NovaUITheme.swift` | PARTIAL | `screens/ShellUI.gd` is a simpler stand-in; no per-screen NovaDialog art chrome in Nova Swift mode | M |
| Fonts (Arimo/Rubik stand-ins, original Charcoal/Geneva if user supplies) | `UI/NovaFont.swift`, `Resources/Fonts` | DONE | `godot/ui/classic/fonts` (verify user-supplied Charcoal/Geneva loading) | S |
| Government palette, credits formatting | `UI/GovernmentPalette.swift`, `CreditsFormatting.swift` | DONE | shared `GovernmentMapPalette`, `creditsHUD` | - |
| HD graphics prompt | `UI/HDGraphicsPromptView.swift` | MISSING | tied to HD packs (section 9) | S |
| Branding (procedural wordmark/icon/loading art) | `Launcher/Branding.swift` | PARTIAL | the loading screen uses the app's wordmark/flames/key-art PNGs (`godot/assets/branding/`); the plain main menu still shows the icon + text title | S |
| Bug report (Settings > Support) | `Debug/BugReport*.swift` | DONE | see section 12 | M |
| App Store / TestFlight / update check | `App/*`, `checkForUpdates` | N/A | | - |

## 2. Settings (every `GameSettings` field, `App/GameSettings.swift`)

Godot persists only: `[audio] master/sfx/ui/music/muted`, `[video] fullscreen/vsync/scale`, `[input] deadzone/modern_keys`,
`[map] gate_links` (port-only), `[presentation] modern_menu/modern_dialogs/modern_hud/fullscreen_galaxy_map`, `[data] dir`, `[keys]`.
No gameplay setting reaches the engine: the bridge never builds a `GameplayEnhancements`, difficulty or spawn model.

| Setting | Godot status | Gap detail | Effort |
|---|---|---|---|
| difficulty (Easy/Normal/Hard, `playerDamageScale`) | MISSING | not in bridge `World` setup | S |
| systemAliveness (original/port spawn model, population scale) | MISSING | bridge uses default spawner | S |
| gameSpeed (Caps Lock 2x, Authentic 1x via `GameSpeedRules`) | MISSING | explicitly noted in `Prefs.gd`; `GameSpeedRules` not bridged | S |
| autoTargetAfterFiring | MISSING | | S |
| confirmLanding | MISSING | | S |
| autoLanding | MISSING | | S |
| tutorialHints | MISSING | no hints at all (section 11) | S |
| pauseOnFocusLoss | MISSING | `Main.gd` only autosaves on close request | S |
| enhancements.manualPluginOrder | DONE | Load order tab toggle (stored in plugins-state.json, not Prefs) | - |
| enhancements.formationFlying (tight formations) | MISSING | not wired in bridge | S |
| enhancements.forgivingLanding | PARTIAL | `attempt_land` test seam exists; no setting | S |
| enhancements.quickHyperjump | MISSING | | S |
| enhancements.frequentAutosave | MISSING | noted in GODOT_LAYER | S |
| enhancements.autoRoutePlotting | PARTIAL | `nav_plot_course` + `map_auto_route` key (T) exist, always on rather than a toggle | S |
| enhancements.nearestFirstTargeting | MISSING | | S |
| enhancements.modernKeyBindings | DONE | `input/modern_keys` | - |
| enhancements.screenShake | MISSING | no shake in `Main.gd` | S |
| controlScheme (touch flying) / tiltSensitivity / hapticsEnabled / cursorSensitivity | N/A | touch/tilt/haptics/virtual cursor | - |
| invertTurn | MISSING | low value on keyboard; pad users may want it | S |
| stickDeadzone | DONE | | - |
| mouseAiming | MISSING | | M |
| starfieldDensity | MISSING | | S |
| showFPS | MISSING | | S |
| smoothSprites | MISSING | Godot draws nearest/linear fixed | S |
| hdGraphics / hdDetail | MISSING | no HD pack pipeline (section 9) | L |
| hullPresentation / modelDetail / liveLighting (3D hulls) | MISSING | Apple 3D is unverified on device; low priority | L |
| particleDensity | MISSING | | S |
| frameRateCap | MISSING | VSync toggle only | S |
| engineGlow | MISSING | engine glow always on | S |
| ceHyperspaceLook | MISSING | | S |
| shipBarPosition (hull/shield bars over ships) | MISSING | | S |
| showPlanetLabels | MISSING | | S |
| cameraZoom / cameraView / chaseTilt | MISSING | no camera views or zoom in `Main.gd` | M |
| masterVolume / musicVolume / sfxVolume / uiVolume / muteAll | DONE | | - |
| musicEnabled | PARTIAL | music slider only; music plays over menu only | S |
| fullscreenGalaxyMap / modernMainMenu / modernDialogs / modernHUD | DONE | `Prefs [presentation]`, UI modes | - |
| sidebarPauseMenu | MISSING | | S |
| showMissionStorylineTags | PARTIAL | `Prefs` `story/show_mission_storyline_tags` (default on) gates `StoryGuide.badge_for_mission`; no Settings toggle yet |
| showRadar | MISSING | | S |
| hudOpacity | MISSING | | S |
| debugModeEnabled / uiDebugOverlay | DONE | Prefs developer/*; Settings > Support | S |
| iCloudSaves / iCloudGameData | N/A | | - |
| largerHUD / highContrastHUD / colorblindMode / reduceFlashing / noHyperspaceEffects | MISSING | Godot has none of the accessibility options | M |
| uiScale | PARTIAL | `video/scale` is window size, not UI scale | S |
| Classic prefs: playMovies, introMusic, smokeTrails, shipAnimations, runningLights, weaponEffects, parallaxStarfield, ambientSounds, shareProcessorTime, soundVolumeStep, brightnessStep | MISSING | none read by Godot; `checkForUpdates` is N/A | M |
| Preset Classic/Enhanced/Nova Swift | DONE | `Prefs.ui_mode()/apply_ui_mode()`; Apple presets also flip other fields (matchedPreset) | - |

## 3. Flight visuals (Apple: `Game/GameScene.swift`, `HullAnimation.swift`; Godot: `Main.gd` `_draw`)

Godot draws the whole world in one `_draw()` from packed bridge arrays (ships, projectiles, beams, rocks, bodies, effects). The bridge
exposes only 11 sprite kinds, and `Main.gd` uses SHIP, ENGINE_GLOW, SPOB, WEAPON, BOOM, ASTEROID, STARFIELD (kinds 2 shield, 3 running lights, 4 weapon glow, 6 destroyed spöb are exported but never drawn).

| Feature | Apple file(s) / symbol | Godot status | Gap detail | Effort |
|---|---|---|---|---|
| Hull sprites, heading frame pick | `GameScene` NPC/player nodes | DONE | `_draw_ships` | - |
| Hull bank / turning animation (shän bank frames) | `HullAnimation.swift`, `liveBank` | MISSING | Godot passes `sprite_frame` only; no bank layer | M |
| Engine glow | `npcEngineGlowTextures` | PARTIAL | drawn when thrusting; no shän engine-glow alt layer blend (additive), no afterburner intensity, setting `engineGlow` | S |
| Running lights | `npcLightTextures`, shän lights layer | MISSING | kind 3 exported, never drawn | S |
| Weapon glow / alt layer | `npcWeaponGlowTextures` | MISSING | kind 4 exported, never drawn | S |
| Shield overlay + shield flare on hit | `npcShieldTextures`, `advanceShieldFlare`, `applyShieldFlare` | MISSING | kind 2 exported, never drawn; shield hit only spawns spark dots (`FX_SHIELD_HIT`) | M |
| Cloak | `togglePlayerCloak`, cloak alpha | DONE | alpha dissolve in `_draw_ships` | - |
| Ionization | `applyIonize` / `releaseIonize` | PARTIAL | tint lerp only; Apple spawns crackle effect (verify) | S |
| Ship tint by government / pers colour | `applyShipTint` | MISSING | | S |
| Disabled ship look, disable flash | `spawnDisableFlash` | MISSING | | S |
| Damage smoke / smoke trails on weapons & hulls | `spawnSmokePuff`, `updateSmokePuffs`, cicn 1000/1008 | MISSING | no smoke at all (also a classic pref) | M |
| Explosions (bööm sprites) | `spawnExplosion` | DONE | `_draw_effects` | - |
| Staggered NPC / player death bursts + flash | `beginNPCDeathSequence`, `beginPlayerDeathSequence`, `spawnFlash` | PARTIAL | sounds staggered (`DeathBurstSounds`); visuals single generic burst | M |
| Hit sparks / debris | `spawnHitSpray`, `syncDebrisPuffs` | PARTIAL | dot sprays vs Apple's sprite-based puffs | S |
| Screen shake | `addShake`, `shakenCameraPosition` | MISSING | opt-in enhancement | S |
| Projectiles with spïn art, spinning | `syncProjectiles` | DONE | `_draw_projectiles` | - |
| Projectile trails (weapon smoke/trails) | `trailInfo` | MISSING | | M |
| Beams (core + corona), lightning bolts | `syncBeams`, `lightningPath` | PARTIAL | gradient beams done; lightning (wëap beam type with jitter) missing | M |
| Asteroids (röid, sprite frames) | `syncAsteroids` | DONE | | - |
| Freeflight objects (jettisoned cargo, pods) | `makeFreeflightNode` | DONE | `_draw_freeflight` | - |
| Planet sprites | `buildPlanets` | DONE | static first frame only | - |
| Animated stellars (spöb animation) | `updateAnimatedStellars`, `stellarAnimation` | MISSING | `_draw_sprite(entry, pos, 0)` always frame 0 | S |
| Destroyed stellars art (kind 6) | `PlanetVisual` | MISSING | | S |
| Gate glow, wormhole glow | `setGateGlow` | PARTIAL | arc ring vs Apple's glow node | S |
| Planet name labels (setting) | `keepPlanetLabelsUpright` | MISSING | | S |
| Selection brackets (target ship, nav stellar, nav cursor) | `updateSelectionBrackets`, `updateNavCursor`, `bracketPath` | PARTIAL | nav stellar bracket drawn; ship target is a red circle, not the corner brackets | S |
| Murk / nebula fog | `buildMurkFog`, `updateMurkFog`, `applyMurk` | PARTIAL | star tint by murk only; no fog layer, no per-sprite murk darkening | M |
| Nebula backdrop art in system | system nebula PICT | MISSING | only in galaxy map (`nav_nebulae`) | S |
| Original starfield (spïn 700 sprites) | `OriginalRendering` | DONE | Classic only; Nova Swift keeps dots | - |
| Parallax starfield option / density | `parallaxStarfield`, `starfieldDensity` | MISSING | | S |
| Hyperspace jump (align, accelerate, flash, arrive, streaks) | `beginJump`, `stepJump`, `showJumpStreaks`, `buildJumpOverlays` | PARTIAL | `HyperjumpFx.gd` (89 lines) vs Apple 5 phases + streaks + CE look + no-jump overlays (`clearCannotJumpOverlays`) | M |
| Hypergate / wormhole arrival and warp-out nodes | `warpOutNode`, `beginGateJump` | PARTIAL | engine places player; no warp-out visual for escorts/NPCs | S |
| No-jump zone indicator | `Hyperspace no-jump zone` MARK | MISSING | | S |
| Escort wing arriving after jump | `carryEscortsThroughJump` | DONE | shared `FlightEscorts` | - |
| Camera: zoom, look-ahead, ship-up, chase tilt | `CameraRig.swift`, `cycleCameraView` | MISSING | fixed camera | M |
| Jettison pods | `spawnJettisonPods` | DONE | (verify in `Main.gd`/`StoryScreens.gd` hits) | - |
| Live 3D hulls, HD hull replacement | `Live 3D hulls` MARK, `HDGraphics.swift` | MISSING | see section 9 | L |
| Frame pacing / particle density settings | `frameRateCap`, `particleDensity` | MISSING | | S |

## 4. HUD (Apple: `Game/AuthenticHUDView.swift`, `GameHUD.swift`, `ContextualActionsView.swift`)

| Feature | Apple file(s) | Godot status | Gap detail | Effort |
|---|---|---|---|---|
| Authentic `ïntf` status bar (shield/armor/fuel, radar, target, secondary, nav, cargo, IFF) | `AuthenticHUDView.swift` | DONE | `ui/classic/AuthenticHUD.gd` | - |
| Modern HUD (Nova Swift mode) | `GameHUD.swift` | PARTIAL | `Main.gd` primitive bars/radar/target panel; no hull/shield bars over ships, no opacity/larger/high-contrast/colorblind | M |
| Message log text sources | `GameContainerView` STR# 2002 usage | DONE (2026-10-12) | invented lines removed; bridge `polishNote` posts the STR# 2002 / GameScene lines; one bottom-left line, Apple placement and font; the land prompt text is Apple's own literal (GameScene), now Apple-positioned | - |
| Message buoy (sÿst.Message, STR# 1000) | `GameContainerView.swift:161` | MISSING | | S |
| Contextual action pills (Land/Board/Hail/Jump/Escorts) | `ContextualActionsView.swift` | N/A | touch-first; desktop keeps text hint | - |
| Escort command panel | `EscortsView.swift` | DONE | `Interactions.gd` (E key); no Upgrade/Sell | S |
| System finder (Named System / Nearest) | `SystemFinderView.swift` | DONE | `nav_find` | - |
| Ship bars over hulls | `shipBarPosition` | MISSING | | S |
| Radar on/off, scale, IFF colours | `showRadar` | PARTIAL | IFF done; no toggle | S |
| Show FPS | `showFPS`, `FrameProfiler` | MISSING | | S |
| Obstructions: HUD under dialogs/controller cursor | `ControllerCursor` | N/A | Godot focus nav instead | - |

## 5. Input and camera (Apple: `Input/`)

| Feature | Apple file(s) | Godot status | Gap detail | Effort |
|---|---|---|---|---|
| Original key table, modern layout, rebinding | `KeyBindings.swift`, `GameAction.swift` | DONE | `Controls.gd` | - |
| Gamepad bindings / pad rebinding | `PadBindings.swift`, `GameControllerInput.swift` | DONE | | - |
| Actions not present in Godot | `GameAction.swift` | PARTIAL | missing `autopilot`, `cycleHyperspaceLink`, `dismissMessage`, `cycleCameraView/cameraZoomIn/Out`, `cursor` bindings | S |
| Caps Lock 2x speed | `CapsLockState.swift`, `ModifierKeyBridge.swift` | MISSING | needs `GameSpeedRules` | S |
| Flight keyboard monitor (modifier chords) | `FlightKeyboardMonitor.swift` | DONE | chord-first logic in `Controls.gd` | - |
| Controller cursor (virtual mouse) | `ControllerCursor.swift`, `CursorScroll.swift`, `PadKeyboard.swift`, `TVTextEntry.swift` | N/A | Godot uses focus navigation; pad on-screen keyboard for name entry would be a Steam Deck nicety (name entry uses typed + dice) | - |
| Touch overlay, tilt, haptics | `TouchControlsOverlay.swift`, `TiltInput.swift`, `Haptics.swift` | N/A | | - |
| Mouse aim toward cursor | `mouseAiming` | MISSING | | M |
| Click-to-select targets in space | `GameScene.swift:1332` | DONE | `Main.gd` click-to-select | - |

## 6. Spaceport and economy (Apple: `Spaceport/`)

Spaceport reskin is in flight (`Spaceport.gd`, `SpaceportClassic.gd`); only gaps visible from outside are listed.

| Feature | Apple file(s) | Godot status | Gap detail | Effort |
|---|---|---|---|---|
| Landing hub, Recharge, Leave | `SpaceportView.swift` | DONE | Classic + plain | - |
| Trade Center, quantity prompt | `SpaceportScreens.swift`, `TradeQuantityPrompt.swift` | DONE | | - |
| Outfitter / Shipyard, locking, rank pricing | `SpaceportScreens.swift` | DONE | shared `SpaceportShops` | - |
| Ship info page (PICT 8507/8506) | `ShipInfoView.swift` | DONE | Classic + plain (`_ship_info`) | - |
| Outfit descriptions / info | `SpaceportScreens.swift` | PARTIAL | plain outfitter selects; verify description + weapon stats parity with Apple tooltips | S |
| Bar (patron offers, holovid news) | `SpaceportScreens.swift` | DONE | `Spaceport.gd` `_show_bar`, `_holovid` | - |
| Hire Escort | `HireEscortView.swift` | DONE | `BarScreens.gd` | - |
| Gambling | `Story/GamblingView.swift` | PARTIAL | `BarScreens.gd` done; race `.mov` clip not played | M |
| Mission BBS | `MissionBoardView.swift` | PARTIAL | accept/refuse done; **no storyline badge** (`StorylineTagBadge`) per row or in Mission Info | S |
| Grid paging, NovaMenu | `GridPaging.swift`, `NovaMenu.swift` | DONE | `ClassicScreen.ItemGrid` | - |
| Spaceport graphics (PICT landscape) | `SpaceportGraphics.swift` | DONE | | - |
| dësc movies / landing movies | `playMovies` | MISSING | Godot cannot play `.mov`; needs ffmpeg transcode or skip | L |
| Hints on first landing/BBS/outfitter | `Tutorial/GameHints.swift` | MISSING | | S |
| Strings: hard-coded English in plain-mode screens | n/a | PARTIAL | `Spaceport.gd`/`BarScreens.gd` literals ("No ships are available for hire here today.", "Ships for Hire", "Nothing for sale here.", "No missions available.", "Choose your color for the next race", "Select what to plunder from this ship:", "Ship captured!", "No escorts.") are not from STR#; Classic path mostly uses data | M |

## 7. Story, missions, Story Map (Apple: `Story/`)

| Feature | Apple file(s) | Godot status | Gap detail | Effort |
|---|---|---|---|---|
| Mission runtime, offers, story text, crons | `AppGameServices.swift`, `StoryTextOverlay.swift`, `StoryFlow.swift` | DONE | `StoryScreens.gd` + bridge `GodotGameServices` | - |
| Player Info (4-tab: General/Cargo/Extras/Honors, Jettison) | `Game/PlayerInfoView.swift` | DONE | `StoryScreens.gd` (P) | - |
| Mission Info | `MissionInfoView.swift` | DONE | I key | - |
| **Story Guide / Story Map window** | `StoryGuideView.swift`, `StoryGuideModel.swift`, `StoryGuidePresenter.swift`, `StorylineFlowView.swift` | DONE | `screens/StoryGuide.gd` (lane list, vertical flow, detail, blockers, jumps/cross-links, Abort, zoom, pad/mouse/keyboard); bridge `// MARK: Story Map` | - |
| Storyline tag badge on missions (BBS rows, Mission Info, bar, in-flight pers offers) | `StorylineTagBadge.swift`, `MissionBoardView.swift:110,357` | PARTIAL | `StoryGuide.make_badge(nova, mission_id, host)` built + tested; **not yet placed on the BBS / offer / Mission Info rows** (those files were owned by the reskin agent) -- hook lines in the GODOT_LAYER "Story Map" section | S |
| Storyline tag cache (prewarm + disk) | `Sources/NovaSwiftStory/StorylineTagCache.swift` | DONE | bridge `story_tag` prewarms off-thread through `StorylineTagCache` (fingerprint = FNV of mission ids+names) | - |
| Story Guide entry points | `GameMenuView.swift:144`, Mission Info, Spaceport (`SpaceportScreens.swift:1045`), `GameContainerView.swift:1083,3205` | PARTIAL | pause menu "Story Map" DONE (`PauseMenu.gd` + `Shell.gd`); the badge entries (BBS, Mission Info, in-flight offers) await the hook lines | S |
| In-flight pers mission offers (hail LinkMission) | `GameContainerView` | MISSING | noted in GODOT_LAYER | M |
| Mission objective log, abort mission | `MissionInfoView.swift` | DONE | | - |

### What the Story Map is, and how it is reached

The Story Guide is a single window (one Apple "Story Guide", the old Guide/Map tabs were removed). It reconstructs every campaign from the
mïsn control-bit graph: each mission's `AvailBits` (TEST) declares what it needs, `OnAccept/OnSuccess/OnShipDone` (SET) declare what it flips;
`StorylineAnalyzer.indexBitSources` links setters to testers. Shared pure logic, already in `Sources/NovaSwiftStory/`:

* `StorylineAnalyzer.storyMap(for: PlayerState) -> StoryMap` returns `lanes: [StoryMapLane]` (key, title, completed/total, governmentID, pluginID),
  `nodes: [StoryMapNode]` (step + laneIndex/rowIndex + deadEndOutcomes), `edges: [StoryMapEdge]` (from/to, kind unlocks/..., outcome success/refuse/failure/abort, isRandom), `untaggedCount`.
* `StorylineStep` has status (completed/active/available/locked), `offeredAt`, `objective`, `reward`, `synopsis`, and for locked steps `blockers: [BlockingBit]`
  with `unlockedBy: [UnlockSource]` (mission/cron + human hint), which is the "how to unlock this" feature.
* `StoryTreeLayout.swift` (`layoutTree`) and `storylineTags()/storylineTag(forMissionID:)` (+ `StorylineTagCache`) are also in the shared package.

SwiftUI-bound (reimplement in Godot): `StoryGuideView` (sidebar of lanes on wide windows, header menu on phone; lane row = title, "n/N steps", plugin label,
government colour dot), `StorylineFlowView` (vertical timeline in a `LazyVStack`; tap a row to expand objective, reward, synopsis, blockers; Abort button for the active step;
"jump to" and "switch storyline" cross-links), `StoryGuideModel` (off-main-thread build with a build token, memoized `flow(for:)`, `currentStepID`, cross-campaign
links, plugin label, government colours) and the pure but app-target `buildStoryFlow` in `StoryFlow.swift` (depth-first linearization into rows with a `StoryConnector`: start / then (quiet), On success/accept/completion/refuse/failure/abort, Unlocks, "50/50 chance").
Port path: move `StoryFlow.swift`'s pure function and row model into `Sources/NovaSwiftStory` (it only imports SwiftUI for `Color`), expose `story_lanes()`, `story_flow(key)` and `story_current_step(key)` as JSON from the bridge (build on a background thread; the analyzer is not Sendable), draw with Godot `Tree`/`VBoxContainer` rows.

Reached on Apple: Pause menu > Story Guide; the storyline badge on a mission (BBS rows, offers, Mission Info) opens it focused on that lane (`initialStorylineKey`); in flight via `GameContainerView.showStoryGuide`.

## 8. Pilots and saves (Apple: `Pilots/`, `Game/PilotStore.swift`)

| Feature | Apple file(s) | Godot status | Gap detail | Effort |
|---|---|---|---|---|
| New Pilot (chär scenarios, ship name, Strict Play) | `NewPilotView.swift` | DONE | `PilotMenu.gd` classic + plain | - |
| Open / delete pilot | `PilotListView.swift` | DONE | Pilots are real `.evpilot` files in a visible Pilots folder (`screens/PilotFiles.gd`; Documents/NovaSwift/Pilots, configurable in Settings, one-time copy from `user://pilots`); Open Pilot = OS file picker (pad: Godot FileDialog) + recent list; Manage = per-pilot play/delete | - |
| Pilot groups: multiple save slots per pilot, backups history, duplicate | `PilotGroupDetailView.swift`, `PilotBackupsView.swift`, `PilotRoster.swift` | MISSING | Godot shows one entry per pilot; backups exist on disk (`PilotArchive`) but no browse/restore UI | M |
| Import pilot (.plt / .evpilot) | `PilotImportView.swift` | DONE | `PilotMenu.open_path` -> `pilot_inspect_file`; original `.plt`/Mac pilots show the converter summary then `pilot_import_commit` (shared `EVNovaPilotImporter`); `.evpilot` opens from anywhere (copied into the Pilots folder). Tested with a synthetic `.plt` only | M |
| Intro sequence (chär intro PICT slideshow then intro dësc) | `IntroSequenceView.swift` | MISSING | no `intro` anywhere in Godot after New Pilot; goes straight to play | M |
| Death flow: "killed" readout, Strict Play permadeath, load last save | `GameContainerView.swift:400` | PARTIAL | `Main.gd:_check_game_over` waits 2.2 s then returns to menu; no killed state, no Strict Play delete (not wired per GODOT_LAYER) | S |
| Escape pod / eject | `GameScene.requestEject`, `OriginalEscapePod` | PARTIAL | `request_eject` bridge call exists; verify post-eject respawn dialog / ship loss flow | S |
| Save cadence (launch, quit, frequent autosave) | `PilotStore` | PARTIAL | original cadence done; `frequentAutosave` missing | S |
| iCloud saves | `PilotRoster` | N/A | | - |

## 9. Plug-ins, HD packs, content loading (Apple: `Plugins/`, `Data/HDGraphics.swift`, `PluginsModel.swift`)

| Feature | Apple file(s) | Godot status | Gap detail | Effort |
|---|---|---|---|---|
| Load plug-ins (merge into data set, load order) | `Data/PluginsModel.swift`, `GameDataController.swift` | DONE | `PluginRuntime.loadMerged` (Plugins.swift) used by `load_game` + `load_game_async`; shared `PluginSet`; see GODOT_LAYER.md Plug-ins | - |
| Plugin store (browse catalog, install, update, enable/disable, load order) | `Plugins/*.swift`, `Launcher/PluginsView.swift`, `Sources/NovaSwiftPluginStore` | DONE | `screens/Plugins.gd` over bridge `NovaPlugins` + `NovaSwiftPluginStore` (browse/install/update/delete/import, enable, load order). Downloads untested live (no network in checks) | - |
| Plugin storyline lane labels | `StoryGuideModel.pluginLabel` | DONE | lanes `pluginLabels` -> `StoryGuide.plugin_label` | - |
| HD graphics packs (NSgx/NSbl, `.nsx`), bake/cache, HD viewer | `Data/HDGraphics.swift`, `Sources/NovaSwiftHD`, `Debug/HDViewerView.swift` | MISSING | no HD in bridge; shared module may need Linux build check | L |
| Sprite pipeline (decode + persistent cache) | `Data/SpriteTextures.swift`, `SpriteDiskCache` | DONE | raw RGBA via bridge; cache off-Apple stores uncompressed | - |
| Audio data (snd decode, voices, music mp3) | `Audio/*` | DONE | see section 10 | - |
| Fonts from user data | `registerFonts(from:)` | PARTIAL | verify | S |
| Pers ships, quotes, hail texts | `GameContainerView` hail | DONE | shared `FlightComm`, STR# 3000-3002 | - |
| Cron news in bar/holovid | `SpaceportScreens` | DONE | | - |
| Ranks, legal record display | `PlayerInfoView` | PARTIAL | Player Info Honors/General done; legal record per system in map info (`GalaxyMap.gd`) only | S |
| dësc movies, race movies | `Data/GameDataController.swift` (`raceVideoURL`) | MISSING | `.mov` unsupported by Godot natively | L |
| Plugin Editor (macOS) | `Editor/**` (74 files, ~20k lines) | DESKTOP | candidate for a later desktop-wide editor; low priority | L |
| Multiplayer co-op | `Multiplayer/**`, `Sources/NovaSwiftNet` | DESKTOP | transport is Game Center on Apple (N/A); host-authoritative core is shared and could use ENet/Steam later; low priority | L |
| Game Center / leaderboards | `GameCenterMatchmaking.swift` | N/A | | - |

## 10. Audio (Apple: `Audio/`)

| Feature | Apple file(s) | Godot status | Gap detail | Effort |
|---|---|---|---|---|
| Event to sound table, voice board, distance law | `GameAudio.swift`, `GameAudioEngine.swift` | DONE | shared `SoundCues`, `SoundVoiceBoard`; `audio/GameAudio.gd` | - |
| Title music | `Audio` / `OriginalAudio.musicCandidates` | PARTIAL | mp3 only, `.mov` = silence; no Intro Music pref | S |
| UI beeps on flight target keys | `GameAudio` | MISSING | noted in GODOT_LAYER | S |
| Ambient sounds pref, preview sound in settings | `ambientSounds`, `SettingsView.swift:476` | MISSING | | S |
| Sound library / catalog | `NovaSoundLibrary.swift` | DONE | `sound_info`/`sound_pcm` | - |

## 11. Tutorial, hints, intro (Apple: `Tutorial/`, `Pilots/IntroSequenceView.swift`)

| Feature | Apple file(s) | Godot status | Gap detail | Effort |
|---|---|---|---|---|
| Flight training course (fly, turn, afterburner, target, fire, change weapon, land) | `TutorialModel.swift`, `TutorialContainerView.swift`, `TutorialCoachView.swift`, `TutorialOfferView.swift` | MISSING | whole feature; mostly touch-scheme driven on Apple, keyboard variant would need new copy | M |
| One-time contextual hints (spaceport, BBS, outfitter) + reset | `GameHints.swift` | MISSING | | S |
| Story intro slideshow | `IntroSequenceView.swift` | MISSING | see section 8 | M |
| Loading tips | `LoadingView.swift` | DONE | `LoadingScreen.TIPS` (Apple's list, minus the Flight Training tip) | S |

## 12. Debug suite and dev tools (Apple: `Debug/`)

**Status: ported (package 2) except the HD viewer; see GODOT_LAYER "Debug suite".** Previously Godot had none of this. The bridge has about 25 `debug_*` @Callables used only by `godot/tests/*_selfcheck.gd` (e.g. `debug_set_credits`, `debug_dock_at`, `debug_add_escort`, `debug_make_hulk`, `debug_place_player_at_spob`); they are a head start for cheat commands.
There is no way to open a console: `debugModeEnabled` is not a setting.

| Tool | Apple file(s) | What it does | Portable vs SwiftUI-bound | Godot status | Effort |
|---|---|---|---|---|---|
| Dev console (drop-down, command line, scrollback, history, clickable `«ship:id:name»` links) | `DevConsoleView.swift` (1066), `ConsoleController.swift`, `ConsoleLogStore.swift`, `DevEntityRef.swift` | command registry with `register(name, summary, usage, closure)`; log tail merged with command echoes | `ConsoleController` is portable logic with `ObservableObject`; `ConsoleLogStore` reads `OSLogStore` (Apple only, needs a ring-buffer logger replacement); view is SwiftUI | DONE | M |
| Console commands (registered in `GameContainerView.registerConsoleCommands`, ~line 4178) | `GameContainerView.swift` + `GameScene.swift` "Debug suite" MARKs | god, fuel (infinite), ai overlay, uidebug, heal, refuel, credits add/set, fps, perf start/stop stress, clearnpcs, killhostiles, hd (status/on/off/detail/overlay/reload/clear cache/viewer), spawn hostile/escort/neutral, ship, outfit add/remove, relation, bit set/clear/toggle/explain, date +days, select, destroy, disable, capture, conquer, cycle | closures touch `GameScene`/`PilotStore`/`World`; logic maps 1:1 onto bridge calls | DONE | M |
| Tools pane (SELECTED, PERFORMANCE, CHEATS, WORLD, HD/3D, STRESS TEST, EDITORS sections, collapsible) | `DevToolsPane.swift` | each control submits a console command | SwiftUI | DONE | M |
| Metrics chip (corner fps/ships readout) | `DevToolsPane.swift` `DebugMetricsChip`, `DebugController.swift` | | SwiftUI; data from `FrameProfiler` | DONE | S |
| Context menu on right-click (Destroy/Disable/Capture/Conquer) | `DevToolsPane.swift` `DevContextMenu` | | SwiftUI | DONE | S |
| Game-state editor (credits, fuel, ship health sliders, date, relations, control bits, hull, outfits, spawn enemies) | `DebugGameStateView.swift` (625) | writes `PlayerState` and live `World` | SwiftUI form; state ops portable | DONE | M |
| Diagnostics self-test battery (Data Set, Navigation, Pilot, Live World; pass/warn/fail) | `DebugDiagnosticsView.swift` (`DebugDiagnostics.run`) | pure functions over `NovaGame` + `PlayerState` + optional ship | battery is portable pure Swift (move to `Sources/`); view SwiftUI | DONE | M |
| Behavioral engine tests (damage, physics, combat, regen in throwaway `World`s) | `DebugTestsView.swift` (`DebugLiveTests`) | | portable (only `Engine`); view SwiftUI | DONE | S |
| Control-bit (NCB) browser with SET BY / TESTED BY | `DevBitBrowser.swift`, `NCBIndex.swift` | inverts all NCB expressions into a bit-first index | `NCBIndex` portable (pure data walk); view SwiftUI | DONE | M |
| Ship / Outfit / Government browsers (searchable, submit console commands) | `DevBrowsers.swift` | | SwiftUI; data via bridge lists | DONE | M |
| Frame profiler (phase timings, worst frame) | `FrameProfiler.swift` | | portable timing struct; Godot has `Performance`/`Time` equivalents | DONE | S |
| Perf monitor (5 s log line: fps, hitches, mem, threads) | `PerfMonitor.swift` | | os_signpost parts Apple-only; counters portable | DONE | S |
| AI overlay, UI measurement grid, god/fuel cheats | `GameScene` "AI overlay", `NovaDebug.swift`, `DebugController.swift` | | need Godot draw overlay (AI states from `World`) | DONE | M |
| Performance stress test (spawn N ships) | `GameScene.swift:6831` | | | DONE | S |
| HD / 3D viewer (turntable classic vs HD, spawn hull) | `HDViewerView.swift` (833) | | needs HD pipeline first | MISSING | L |
| Bug report bundle (report.txt, pilot.json, diagnostics.txt, console.log -> zip -> share) | `BugReport.swift`, `BugReportView.swift`, `GameDataArchiver.zip` | | bundle assembly portable; share sheet replaced by "reveal in file manager" | DONE | M |
| Plugin Editor "test run" debug panel | `Editor/Run/EditorDebugPanel.swift` | | | DESKTOP | L |

## 13. About Nova: why the Godot About was wrong (FIXED 2026-10-12, see package 3; kept as the root-cause record)

Apple (`AuthenticMainMenuView.swift:298-306`) opens `DescTextDialog(text: AboutNovaText.text(game:), graphicID: nil)`:

1. Text = a NovaSwift header ("NovaSwift <version> / A free, unofficial port by Joshua Kac (SirStig) / Not affiliated with... / repo URL") + `game.descText(32767)` with `<REG>` replaced by "EV Nova Community".
2. Layout from DLOG/DITL **3003** (text only) or **3004** (with picture): window size from the DLOG, OK = item 0, text rect = item 2, picture rect = item 1. Frame art = top PICT 8524 + tiled body 8525 + bottom 8526 (backdrop PICT 8527 when a picture is shown).
3. Height: `DescDialogLayout.shrink(textHeight, textItemHeight)` shrinks (or grows) the dialog to the measured text height; text is white 12 pt on black in a clipped scroll view that scrolls when it overflows; the dialog is scaled by `novaFrameScale`.

Godot (`screens/MainMenu.gd:_show_about`, ~line 133) calls `ClassicDialog.panel(nova, {"text": text, "width": 560, "footer_buttons": [OK]})` with `nova.classic_desc_text(32767)`. Concrete defects, all in `ui/classic/ClassicDialog.gd:panel` (line 169):

* Text height is guessed: `lines = ceil(len(text) * 7 / (width - 40))`, `height = lines * 16`. It ignores the explicit `\r`/`\n` paragraph breaks that dësc 32767 is full of and the real font metrics, so the label overflows the 8524/8525/8526 frame or leaves a huge gap; it never scrolls. 560 px width also does not match the 8524-8526 art (441 px) the frame is built from, so the art is stretched or tiled wrong.
* No DITL 3003/3004 geometry is used; the OK button is a hand-placed footer button instead of item 0's rect.
* No NovaSwift header (version, "unofficial port", repo), and `<REG>` is left as a literal token. Bridge `classicDescText` is a raw `game.descText(id)`.
* Text colour/font: uses `listText` cölr colour and the default body font rather than white Geneva/Arimo 12 on black.
* No `\r` to `\n` normalisation (classic Mac line endings), which Godot's Label wraps differently.

Fix: new `ClassicDialog.desc_dialog(nova, text, graphic_id)` that reads DITL 3003/3004 through the existing `classic_dialog(id)` JSON, builds 8524/8525/8526 (or 8527) as the frame, places a `RichTextLabel` (white, 12 pt, `\r` normalised) in a clipped `ScrollContainer` at item 2, measures real content height to apply `DescDialogLayout.shrink` (expose `shrink` and `AboutNovaText` header as bridge helpers; version from `project.godot`), and OK at item 0. The same widget serves every `dësc` reader (mission text, intro text, outfit descriptions, spaceport landing).

## 14. Interactions: hail, plunder, comms, negotiation, escorts

| Feature | Apple file(s) | Godot status | Gap detail | Effort |
|---|---|---|---|---|
| Hail ship / stellar, bribe, assistance, beg, tribute | `HailDialogView.swift`, `NegotiationView.swift` | DONE | `Interactions.gd`, shared `FlightComm` | - |
| Plunder / board / capture | `PlunderView.swift` | DONE | strings from STR# 2002 (verify "Ship captured!" literal) | S |
| Escorts window | `EscortsView.swift` | PARTIAL | no Upgrade/Sell | S |
| Domination / tribute flow | `GameScene` | DONE | | - |
| Galaxy map (Classic frame, fog, route, find, gate picker) | `GalaxyMapView.swift` (1749) | PARTIAL | `GalaxyMap.gd` done; missing Show/Hide Borders, Nearest System button, zoom reset; verify nebula + legal overlays | S |

---

## Recommended work packages

Ordered by user value. Each is sized for one agent. "Do not touch" lists keep concurrent agents from colliding (the spaceport-reskin agent owns `Spaceport.gd`, `SpaceportClassic.gd`, `BarScreens.gd`, `Interactions.gd`, `StoryScreens.gd` until it lands).

1. **Story Map / Story Guide (L) -- DONE except the badge placement.** See section 7 and GODOT_LAYER "Story Map".
2. **Debug Suite + Report a Bug (L) -- DONE except the HD viewer (package 9).** Add `debugModeEnabled`/`uiDebugOverlay` to `Prefs.gd`/Settings; move `DebugDiagnostics`, `DebugLiveTests`, `NCBIndex` and the console command parsing/registry into `Sources/` (Apple keeps using them); new bridge file `Debug.swift` exposing `console_run(line)`, `console_commands()`, `diagnostics_run()`, `ncb_explain(bit)`, ship/outfit/govt lists, and a ring-buffer log; new `godot/screens/DevConsole.gd` (drop-down console, tools pane with the same sections, ship/outfit/govt/bit browsers, metrics chip using Godot `Performance`), bug-report zip (pilot.json + diagnostics + log, reveal in file manager). Do not touch: `Main.gd` beyond a toggle key hook (a one-line `~` hook), HD viewer (package 9).
3. **About Nova fix + desc dialog (M).** Implement section 13: `ClassicDialog.desc_dialog`, bridge helpers (`classic_desc_dialog_layout`, `about_nova_text`, `<REG>` replace, shrink), real NovaSwift About box (version, credits, links) behind Settings/Modern menu. Touch: `ui/classic/ClassicDialog.gd`, `MainMenu.gd` (`_show_about`), `Settings.gd`, `ClassicUI.swift`. Also reused by package 8 intro text.
4. **Flight visual fidelity pass (L).** Draw the exported-but-unused layers (running lights kind 3, weapon glow kind 4, shield overlay + flare kind 2), shän bank frames, animated + destroyed stellars, ship tint by govt, disable flash, ship-target corner brackets, smoke puffs and weapon trails, staggered visual death bursts, lightning beams, murk fog layer, nebula backdrop, screen shake (opt-in), proper hyperjump phases/no-jump indicator. Mirror `GameScene` helper names; take as much logic as possible from `OriginalRendering`/`HullAnimation` into shared code. Touch: `Main.gd` (split drawing out into new `godot/FlightRender.gd` first), `HyperjumpFx.gd`, bridge `NovaWorld.swift` render queries. Do not touch HUD files.
5. **Settings parity + engine settings plumbing (M).** Extend `Prefs.gd`/`Settings.gd` with the missing gameplay and presentation fields (difficulty, system aliveness, game speed incl. Caps Lock, auto-target, confirm/auto landing, all `GameplayEnhancements`, show radar/FPS/planet labels, HUD opacity/larger/high-contrast/colorblind/reduce flashing, starfield density, particle density, frame cap, engine glow, smoke, camera view) and a bridge `apply_settings(json)` that builds `GameplayEnhancements`, difficulty and spawn model. Add the Classic Preferences dialog (DLOG 4003) behind Preferences, with the 4003 flags. Touch: `Prefs.gd`, `Settings.gd`, `Controls.gd` (new actions), new bridge `Settings.swift`. Do not touch: render code (it reads the prefs in package 4).
6. **Plug-in loading + manager (L) -- DONE (see GODOT_LAYER.md).** Scan `Nova Plug-ins`, merge in load order (`GameLibrary` + `manualPluginOrder`), show plug-in label in story lanes, then a Godot Plug-ins screen (browse/installed/load order) over `NovaSwiftPluginStore` (verify it builds on Linux/Windows). Touch: bridge `NovaWorld.swift loadGame`, new `Plugins.swift`, new `screens/Plugins.gd`, `MainMenu.gd`, `DataSetup.gd`. Do not touch: HD (package 9).
7. **HUD and message-source fidelity (M).** Replace invented `EVENT_MESSAGES`, "Press L to land", "Docked at ..." and plain-screen English literals with the STR# 2002/150/1000 lines the Apple app uses (add a shared `OriginalMessages` lookup, bridge `msg(id)`), add sÿst.Message buoy, ship bars over hulls, radar toggle/opacity, and the Modern HUD parity items. Audit `Spaceport.gd`/`BarScreens.gd`/`Interactions.gd` literals after the reskin lands. Touch: `Main.gd` HUD functions (after package 4 splits), `AuthenticHUD.gd`, bridge message helpers.
8. **New-pilot flow: intro, death, pilot slots, tutorial/hints (M).** Intro slideshow + dësc (reuses package 3 widget), "killed" menu state and Strict Play deletion, pilot groups/slots/backups browser and import, one-time hints, loading screen with tips, optional keyboard flight tutorial. Touch: `PilotMenu.gd`, `Shell.gd`, `MainMenu.gd` (killed readout), bridge `PilotSaves` calls, new `Hints.gd`, `Tutorial.gd`.
9. **HD packs and viewer (L).** Verify `NovaSwiftHD` compiles off Apple, bridge HD sprite lookup (replace hull/stellar/weapon sprites with pack art, bake cache), HD settings, HD viewer tool. Optional 3D hulls stay out of scope. Touch: bridge `HD.swift`, sprite cache in `Main.gd`/`FlightRender.gd`, viewer screen. Do last of the large items.
10. **Camera, input and accessibility (M).** Camera views and zoom (`CameraRig`), mouse aim, missing actions (autopilot, cycle hyperspace link, dismiss message), pad on-screen keyboard for names, accessibility options. Touch: `Controls.gd`, `Main.gd` camera transform (coordinate with 4), `Settings.gd` Controls page.
11. **Movies and media (L).** dësc/landing/race `.mov` playback: transcode-on-import (ffmpeg or Theora via `VideoStreamTheora`) or skip with fallback art; title music `.mov`. Touch: `TitleMusic.gd`, `BarScreens.gd` (after reskin), data import. Decide scope with the user first.
12. **Desktop extras, low priority (L).** Multiplayer over ENet/Steam using shared `NovaSwiftNet`; macOS/desktop Plugin Editor port. Only after 1 to 8.
