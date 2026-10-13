# Godot wiring gaps

This file lists behaviour the original game has that the Godot frontend does not yet call. Engine-rule gaps live in [reverse-engineering/FIDELITY_PLAN.md](reverse-engineering/FIDELITY_PLAN.md) and [STATUS.md](STATUS.md). A DONE row here means the Godot path is wired to the shared Swift helper. It does not mean that helper matches the executable.

The shared helpers still diverge on EC-04 and EC-05 (gate and wormhole clearance and the fee), EC-25 (a bribe is one approach), OS-06 (wormhole exit draw), EC-26 (the bar's previous winner resets when the bar opens), OS-08 (bomb fuse reseed) and UI-06 (which body Land picks). Godot follows those helpers.

This file is the single list of Godot frontend gaps; [STATUS.md](STATUS.md#linux-and-windows) carries the summary table. Status words used in the rows:

* **DONE**: wired, and built and run on macOS (headless self-checks where the package names one).
* **WRITTEN, NOT BUILT**: the code is in the tree but has not been compiled or run. Treat it as unverified until someone builds it. This applies to: the hypergate and wormhole entry movies (both apps), D1-D4 (galaxy map borders, mission markers, Tab and backslash cycle), the sound-parity fixes, the ambient loop and the brightness veil (C2, C3, and the rows marked FIXED in the sound table), and the About-dialog picture (C6).
* **PARTIAL / MISSING / OPEN / UNVERIFIED**: as written in the row.

Packages A and B are wired and self-checked. Frontend work that is still open: the Key Settings dialog (C1), title music from a `.mov` (C5), murk (F1), the NPC warp effect check (F2), sound items S12, S25 and S26, on-GPU shader checks (F3), and building and running on Linux, Windows and the Steam Deck. Nothing else in this file is known to be missing.

---

## Work packages (ordered by how much each blocks "play the original start to finish")

Files named in each package are the ones that package owns. `godot/bridge/Sources/NovaSwiftGodot/NovaWorld.swift` is one 5k-line class
that SwiftGodot needs in a single file, so packages A, B and D each edit it: they must stay inside the named `// MARK:` regions
(A: `Event collection`, `World setup`/`makeConfiguredWorld`, `Gameplay gaps`; B: `Flight travel`, `Landing`, `completeHyperjump`/`launch`;
D: `Navigation & hyperjump`). Everything else is file-disjoint, so A, C, D, E and F can run in parallel; B should start after A merges
(or edit only its regions), because both touch `Main.gd`-adjacent message plumbing.

### Package A. Live-world wiring the Godot bridge never does (blocks story progression)  [DONE 2026-10-13]

Files: `godot/bridge/Sources/NovaSwiftGodot/NovaWorld.swift` (regions above), `Gaps.swift`, `Story.swift`. Almost no GDScript (status lines
already flow through `drain_*_messages`). Tests: extend `godot/tests/gameplay_gaps_selfcheck.gd`.

| # | Original behaviour | Status | Concrete gap (where the Apple app does it) |
|---|---|---|---|
| A1 | Combat rating rises with kills; crimes fold into the pilot's legal record and revoke crime-sensitive ranks (EC-02, EC-10, WP-04) | DONE (2026-10-13, `WorldPilotLink`; see GODOT_LAYER.md "Live-world wiring") | `FlightComm.syncStanding` (shared, ready) is never called by the bridge: `pilot.combatRating` never changes in Godot, `world.playerCombatRating` is never set, so mission `AvailRating`, rank gates, domination gate and the NPC rating-based fire ramp (AI-03) all see 0. Reputation delta is only folded on a landing request (`NovaWorld.swift:2942`). Call it on land, jump arrival, save and mission pass (Apple `syncCombatStanding`, `GameContainerView.swift:2551`) |
| A2 | Mining scoop / cargo boxes (OS-11): scooped resource boxes and asteroid yield go into the hold | DONE (2026-10-13, `WorldPilotLink`; see GODOT_LAYER.md "Live-world wiring") | `.asteroidMined` is emitted by the engine and ignored by the bridge, and `world.playerHoldHasRoom` stays the default `{ true }`: boxes (mined rock, plundered-loot spill, jettisoned cargo) vanish and no cargo is added. Apple: `scene.onAsteroidMined` / `playerHoldHasRoom` (`GameContainerView.swift:372-387`) via `PilotEconomy` cargo add + clamp |
| A3 | Pêrs / ship spawn gating and persistence (UI-17, AI-11): pêrs `ActiveOn` NCB, never respawn once defeated, grudges persist; `shïp.AppearOn` gates düde hulls | DONE (2026-10-13, `WorldPilotLink`; see GODOT_LAYER.md "Live-world wiring") | bridge never sets `world.persSpawnEligible`, `world.shipSpawnEligible`, `world.playerPersGrudges`, and ignores `.personGrudge` / `.personDefeated` (Apple `GameContainerView.swift:339-363, 388-393`). Result: defeated named pilots respawn, story-gated pêrs and hulls appear at the wrong time. `debug_pers_defeated` exists but nothing records |
| A4 | Pirates board YOU and take cargo/credits (AI-29) | DONE (2026-10-13, `WorldPilotLink`; see GODOT_LAYER.md "Live-world wiring") | `.playerBoarded(byShipID:ratio:)` is not handled; need `World.resolvePlayerBoarding` + credit/cargo deduction + beep + mission `Flags 0x8000` fail (Apple `GameContainerView.swift:1976-2002`) |
| A5 | Stellar defence/garrison and reinforcement state persists across jumps (AI-15/16, EC-16) | DONE (2026-10-13, `WorldPilotLink`; see GODOT_LAYER.md "Live-world wiring") | no `defenseStateProvider` equivalent: `applyDefenseState` (garrisons, `holdReinforcements`, escort category orders restore, `w.pilotName`, `w.missionCargoScanMask`) is never run; `.reinforcementsCalled` not stored; damaged destroyable stellars forget their armor (`stellarStrengthLeft`, `destroyedStellarIDs`). `stellarDestroyed` / `stellarDominated` persistence already works via `FlightComm.apply` |
| A6 | Bombs (OS-08, ModType 47/50) detonate after a fuse | DONE as wiring (the fuse still diverges: OS-08; see GODOT_LAYER.md "Live-world wiring") | Both frontends call `HazardOutfits`. The fuse is seeded once and kept; the original reseeds it on every recompute (OS-08) |
| A7 | Strict Play pilot: exact speeds instead of the 1.5x/2/3 non-strict scale (FL-03); per-day world seed | DONE (2026-10-13, `WorldPilotLink`; see GODOT_LAYER.md "Live-world wiring") | bridge leaves `world.strictPlay` false for every pilot and `GameSession.makeWorld` always uses the fixed seed `0x5EED_1234` (Apple passes `currentWorldSeed(systemID:)` from day) so ambient traffic is identical every visit |
| A8 | Landing/departure bookkeeping the Apple container does at `depart()`: `onMissionAuxShipsArrived` budget decrement, `recordMunitions` on launch, `warnStrandedFighters` | DONE (2026-10-13, `WorldPilotLink`; see GODOT_LAYER.md "Live-world wiring") | `Munitions.record` is called on save only (`NovaWorld.swift:2274`); verify aux-ship budget decrement and the "N fighters abandoned" accounting |

### Package B. Status line, messages, keys (what the player reads and presses)  [DONE 2026-10-13]

Files: `godot/Main.gd`, `godot/Controls.gd`, `godot/ui/classic/AuthenticHUD.gd`, `godot/Prefs.gd` (key table only), bridge `NovaWorld.swift` in
`Flight travel` / `Landing` / `completeHyperjump` / `launch` regions, `UIPolish.swift`. Do not touch flight/*.gd (package F).

| # | Original behaviour | Status | Concrete gap |
|---|---|---|---|
| B1 | Arrival line after every jump/gate: sÿst buoy (STR# 1000, UI-12) else "Arriving in the X system on <date>." (#43-48, gate/wormhole #46/#47, #49 "No stellar objects present.", abandoned-fighter clause) | DONE (2026-10-13, see GODOT_LAYER.md "Status line, messages and HUD icons") | `completeHyperjump` only sets `nav.arrivedIn`; `OriginalText.arrival` and `game.systemMessageText` are never called. Apple `postArrivalLine` (`GameContainerView.swift:1858`) |
| B2 | Launch line "Launching from X on <date>." (#55-60) | DONE (2026-10-13, see GODOT_LAYER.md "Status line, messages and HUD icons") | `launch()` forwards a staged `Q` quote only; `OriginalText.launch` never called (Apple `postLaunchLine`, :1887) |
| B3 | HailQuote broadcasts: pêrs/ships speak on the status line (1/140 per call after ~45 s, gated by pêrs flags; on turning hostile; on ambush) | DONE (2026-10-13, see GODOT_LAYER.md "Status line, messages and HUD icons") | no `broadcastContextProvider` / `GameScene.broadcastHailQuotes` port |
| B4 | Return dismisses the message (slot 6); empty post clears it; message timers run on sim time and freeze while paused | DONE (2026-10-13, see GODOT_LAYER.md "Status line, messages and HUD icons") | no `dismiss_message` action in `Controls.gd`; `Main.gd` ages `_log` by wall clock |
| B5 | `\` / Shift-`\` cycles the travel destination without opening the map (UI-15); Tab/`\` cycle adjacent systems on the map | DONE (2026-10-13, see GODOT_LAYER.md "Status line, messages and HUD icons") | no binding (also see D) |
| B6 | Red-alert blink icon (cicn 18000+frame, top-right) while threatened; x2 speed icon (cicn 20000) | DONE (2026-10-13, see GODOT_LAYER.md "Status line, messages and HUD icons") | `RedAlertCue` drives sound only; `x2_active()` is exported but no GDScript reads it |
| B7 | Radar stellar colours by landing standing when an IFF is fitted (RadarIFF.stellarColor) | DONE (2026-10-13, see GODOT_LAYER.md "Status line, messages and HUD icons") | `AuthenticHUD._draw_radar` draws every stellar as a dim ring |
| B8 | Jump refusal overlays #30/#31/#36/#42 auto-clear when a jump becomes legal (FL-23) | DONE (2026-10-13, see GODOT_LAYER.md "Status line, messages and HUD icons") | refusal text is produced; clear-on-legal not done |

### Package C. Preferences, Key Settings dialog, ambient sound  [S-M]

Files: `godot/screens/ClassicPreferences.gd`, new `godot/screens/ClassicKeySettings.gd`, `godot/screens/Shell.gd`, `godot/audio/GameAudio.gd`,
`godot/audio/TitleMusic.gd`, `godot/Prefs.gd` (`[classic]` block only), bridge `ClassicUI.swift` (DITL 4002 JSON) and `Audio.swift`.
Do not touch `Controls.gd` rebind storage (use `Controls.overrides`).

| # | Original behaviour | Status | Concrete gap |
|---|---|---|---|
| C1 | Key Settings dialog (DLOG 4002, the 34-cell key table, "NovaPrefs_ResetKeyBindings" defaults button) | MISSING | `ClassicPreferences.gd` emits `key_settings` which opens the NovaSwift Controls page; DITL 4002 is not drawn (Apple `ClassicKeySettingsView.swift`) |
| C2 | Brightness arrows (STR# 139, 0-6) change screen gamma | WRITTEN, NOT BUILT (2026-10-13, `ui/BrightnessVeil.gd`, added by `Main.gd`) | black veil below step 3, white (additive) above, gamma = step x 10 + 70 %, as Apple `RootView.brightnessVeil` |
| C3 | Ambient Sounds: the landed spaceport plays the spöb's `AmbientSound` loop; off = silence (0x00491f30) | WRITTEN, NOT BUILT (2026-10-13, `GameAudio.gd` `start_ambient`/`stop_ambient`, bridge `landed_ambient_sound()`) | follows the docked state, honours the Ambient Sounds pref, mute and the Settings sliders; stopped on takeoff and on returning to the menu |
| C4 | Preferences that are stored but have no effect: Share Processor Time (no counterpart needed), Ship Animations (applied via `set_flight_options`), Check For Updates (N/A) | PARTIAL | only document; low value |
| C6 | About dialog shows the original's picture | WRITTEN, NOT BUILT (2026-10-13) | |
| C5 | Title music from `.mov` (Nova Files names it as `.mov`) | PARTIAL | `TitleMusic.gd` is silent for `.mov` unless the movies package converts audio |

### Package D. Galaxy map fidelity (original map window)  [S-M]

Files: `godot/screens/GalaxyMap.gd`, `godot/screens/NavScreens.gd`, `godot/screens/HyperjumpFx.gd`, bridge `NovaWorld.swift` region
`Navigation & hyperjump` and `Navigation.swift`. Tests: new checks in `godot/tests/ui_polish_selfcheck.gd` neighbours.

| # | Original behaviour | Status | Concrete gap |
|---|---|---|---|
| D1 | Show/Hide Borders political overlay, persisted (STR# 150 #56/#57) | WRITTEN, NOT BUILT (2026-10-13, see GODOT_LAYER.md "Galaxy map: borders, mission marks, Tab cycle") | bridge `nav_borders` builds the shared `PoliticalOverlay`; `[map] show_borders`; DITL 2000 item 8 button + `B` key |
| D2 | Mission-target cicn markers on the map and their fog exception | WRITTEN, NOT BUILT (2026-10-13) | bridge `nav_mission_targets`; cicn 15000 16 px up-left, fogged targets drawn and pickable |
| D3 | Map Tab / `\` adjacent-destination cycling (0x004a74f0 / 0x004a7710) | WRITTEN, NOT BUILT (2026-10-13, both apps) | Godot `GalaxyMap.cycle_link` + bridge `nav_cycle_link`; `map_extend` moved Tab -> E. Apple: `handleDiscrete` intercepts the cycle / target-next keys while the map is open (Tab itself has no classic Apple binding). The two handlers are not decompiled (inside the 0x004a3aa0 loop), so the behaviour mirrors the in-flight `\` step (0x0044b120) |
| D4 | Floating-map frame border and help line | WRITTEN, NOT BUILT (2026-10-13) | `RouteMiniMap.gd` frame is the cölr FloatingMap colour; the original draws no help line under the Classic frame (already absent) |
| D5 | Legal Status (#326) and Goods/Services panels honour exploration levels 1/2 (UI-04) | DONE | `_draw_side` already gates every block on `classic_map_info.level` (Unknown / no Goods until level 2) |
| D6 | In-flight `\` destination cycle | DONE (with B5) | `cycle_hyperspace_link` actions + bridge `cycle_hyperspace_link` |

### Package E. Movies (QuickTime) and media  [M, partly in progress]

Files: `godot/Movies.gd`, `godot/ui/MoviePlayer.gd`, `godot/screens/BarScreens.gd` (race clip only), `godot/screens/StoryScreens.gd` (offer
movie), `godot/screens/Spaceport.gd` (BBS offer hook, small), `godot/audio/TitleMusic.gd`. A concurrent agent is already writing
`Movies.gd` / `MoviePlayer.gd`; coordinate with it before assigning.

| # | Original behaviour | Status | Concrete gap |
|---|---|---|---|
| E1 | Race betting plays `Race 1..4.mov` | DONE (per coordinator, 2026-10-13) | wired via `Movies`/`MoviePlayer`; only re-verify the no-ffmpeg fallback |
| E2 | Mission-offer `dësc` movies (a mission's offer/completion text carries a movie filename; Apple `MissionBoardView.playMovie`) | DONE (2026-10-13, both apps; see "Plug-in loading gaps" below) | story texts, docking, intro text and acknowledgements play their `dësc` movie |
| E3 | `playMovies` pref gates all of the above | PARTIAL | read in `BarScreens.gd` only |

### Package F. Flight render remainder and on-device verification  [S-M]

Files: `godot/flight/*.gd`, `godot/bridge/Sources/NovaSwiftGodot/FlightVisuals.swift`, `godot/screens/HyperjumpFx.gd` (shared with D: only the
no-FX path). Do not touch HUD files.

| # | Original behaviour | Status | Concrete gap |
|---|---|---|---|
| F1 | Murk (sÿst.Murk) fog: far objects fade to the murk colour, per-sprite darkening | PARTIAL | star tint only, no per-sprite murk |
| F2 | Hyperjump NPC warp-out/warp-in nodes (ships popping in/out of hyperspace) | PARTIAL | verify `shipArrived/shipDeparted` effects in `EffectsDrawer.gd` |
| F3 | Visual verification of the additive/fill shaders on a real GPU (gl_compatibility) | UNVERIFIED | all flight visuals have only headless/composed-PNG checks (`flight_visuals_selfcheck.gd`) |

---

## Still open as frontend wiring

- C1 Key Settings dialog (DLOG 4002) is not drawn.
- C4 and C5: a few stored preferences, and title music from a `.mov`, are partial.
- E3 `playMovies` gating: it was read from the bar only when this row was written; re-check now that `dësc` movies exist.
- F1 murk is a star tint only. F2 hyperjump NPC warp nodes are partial. F3 shader output is not checked on a real GPU.
- Sound S12 (enhancement not ported), S25 and S26 (map cycle sound; silent J with auto-route).
- Written but not built or tested: see the status words at the top.
- Linux, Windows and Steam Deck builds have not been made or run.

## Deferred: ENHANCEMENT gaps (NovaSwift-only; not original)

* Debug Suite parts not ported: HD/3D viewer, context-menu on ships (the rest is ported).
* HD graphics packs (NSgx/NSbl, `.nsx`), live 3D hulls, chase-camera 3D tilt, `hdGraphics`/`hdDetail`/`modelDetail`/`liveLighting` settings.
* Camera views key (Look ahead / Ship up / Chase cycle key `O`, zoom `[` `]`): renderer supports them, no keybinding or HUD toast.
* Autopilot key `A`, `cycleHyperspaceLink` as an enhancement, evasive escort order, `quickHyperjump`, forgiving landing UI toggle,
  nearest-first targeting toggle: shared rules exist; some are wired through `SettingsPlumbing.gd`, quick hyperjump is not.
* Starfield density, particle density, planet name labels, ship health bars over hulls, CE hyperspace look, sidebar pause menu,
  Story Guide badge placement on BBS/offer/Mission Info rows, FPS counter UI polish.
* Accessibility: larger HUD, high-contrast HUD, reduce flashing, no-hyperspace-effects, colorblind filter UI for the Classic `ïntf` bar.
* Tutorial / hints text chain beyond what `Tutorial.gd` and `Hints.gd` already do; loading tips.
* Plug-in editor port, multiplayer co-op (ENet/Steam), Game Center/iCloud equivalents, Steam Deck pad keyboard polish.
* Data setup wizard (guided import), managed data dir copy, web import server.


---

## Full walk of `app/NovaSwift/` vs Godot (beyond the parity rows)

Every Apple file was mapped to a Godot equivalent. Frontend wiring that is still open is in packages C, E and F. Engine differences are the open items in the fidelity plan.

| Apple area | Godot equivalent | Verdict |
|---|---|---|
| `Game/GameScene.swift` (flight, camera, effects, hail, board, gates, escorts, click-select) | `Main.gd`, `flight/*`, `screens/Interactions.gd`, bridge `NovaWorld.swift` | DONE except package A/B/F items |
| `Game/GameContainerView.swift` (56 scene hooks, arrival/launch lines, scans, bombs, boarding, syncCombatStanding, pers/defense providers, mining) | bridge sections | the A and B gaps; see their rows |
| `AuthenticHUDView`, `GameHUD`, `CameraRig`, `HullAnimation` | `ui/classic/AuthenticHUD.gd`, `Main.gd`, `flight/` | DONE except B6/B7 |
| `HailDialogView`, `NegotiationView`, `PlunderView`, `EscortsView`, `SystemFinderView`, `PlayerInfoView`, `GameMenuView`, `GalaxyMapView` | `Interactions.gd`, `BarScreens.gd`, `StoryScreens.gd`, `PauseMenu.gd`, `GalaxyMap.gd` | DONE except package D |
| `Spaceport/*` (landing hub, trade, outfitter, shipyard, ship info, hire, grid paging) | `Spaceport.gd`, `SpaceportClassic.gd` | DONE |
| `Story/*` (offers, BBS, mission info, gambling, story text, Story Guide) | `StoryScreens.gd`, `Spaceport.gd`, `BarScreens.gd`, `StoryGuide.gd` | DONE except E2 (offer movies; Apple `MissionBoardView.playMovie` incl. GIF fallback) |
| `Launcher/*` (main menu, preferences 4003, key settings 4002, settings, loading, plug-ins, data wizard) | `MainMenu.gd`, `ClassicMainMenu.gd`, `ClassicPreferences.gd`, `Settings.gd`, `LoadingScreen.gd`, `Plugins.gd`, `DataSetup.gd` | package C (4002, brightness); wizard is ENH |
| `Pilots/*` (new, list, groups, backups, import, intro) | `PilotMenu.gd`, `PilotFiles.gd`, `IntroSequence.gd` | DONE |
| `Audio/*` | `audio/GameAudio.gd`, `TitleMusic.gd` | DONE (see "Sound sites") |
| `Input/*` | `Controls.gd` | DONE; touch/tilt/haptics N/A; being edited by the controls agent |
| `UI/*` (DITL dialogs, desc dialog, fonts, palettes) | `ui/classic/*` | DONE |
| `Tutorial/*`, `Debug/*`, `Editor/*`, `Multiplayer/*`, `Plugins/*`, `Data/HDGraphics` | `Tutorial.gd`, `Hints.gd`, `debug/*`, `Plugins.gd` | ENHANCEMENT (ported or deferred) |

## Engine gaps are not listed here

Differences from the executable are the open items in the fidelity plan and in STATUS.md. This file does not keep a second list.

## Plug-in loading gaps (2026-10-13, from `scripts/plugins-check.sh`; details in `docs/GODOT_LAYER.md` "Real plug-in verification")

All 13 downloaded plug-ins load with exactly the shared-Swift resource counts and play a pilot start to a jump without errors. What is left
is the same in the Apple app unless noted:

* **dësc movies (DONE 2026-10-13, both apps)**: story texts, docking, intro text, acknowledgements (see GODOT_LAYER "Total-conversion add-ons").
  **Hypergate / wormhole entry movie (WRITTEN, NOT BUILT, 2026-10-13, both apps)**: `Stellar_EnterHypergate` 0x00456480 / `Stellar_EnterWormhole`
  0x00456ca0 call `FUN_0049e3c0(travelSelection + 0x80)` before the transport: the dësc whose id is the chosen destination sÿst
  (hypergate) or the wormhole's own spöb (wormhole); movie only, no text, modal and skippable, off with the QuickTime pref
  (`DAT_005914d3`); shared `GateTravelMovie` (see GODOT_LAYER "Galaxy map"). Godot needs ffmpeg for movies.
  Base `dësc` 338 names `flyby.qt`, which is not in the user's base data (the original also finds nothing).
* **Intro movies / GIF (DONE)**: they are dësc 20000 (chär intro text) and 32766 (X key), not separate launch screens.
* **Plug-in fonts (DONE)**: registered from the TC folder in both apps.
* **Facelift on Override (DONE)**: per-TC add-on list; the old "stage it into Plug-Ins" is no longer needed. Global plug-ins still don't load under a TC.
* Graphics-only (HD pack) plug-ins on a TC's list are not ranked as layers (they have no files); add-ons with `.rez` files are.
* Headless runs print Godot "This control can't grab focus" warnings from `ui/classic/ClassicDialog.gd:598` (`focus_first`); not plug-in
  related (the BASE run prints them too) and filtered by the script.

---

## Sound sites (2026-10-13 audit: Apple app vs Godot vs the decompiled original)

Every place the Apple app makes a sound, how the Godot frontend answers it, and what was changed. The mixing rules are shared code
(`SoundCues`, `SoundVoiceBoard`, `DeathBurstSounds`, `OriginalAudio`, `RedAlertCue`), so everything that comes from a `WorldEvent` or
the jump/alarm tick matches by construction; the differences were all in GDScript (which UI paths beep, music, ambient loop, defaults).
Test: `godot/tests/sound_parity_selfcheck.gd` (uses the test-only `debug_drain_sounds()` / `debug_pending_sounds()`, which return the queued
cues as `[{id, priority, onlyWhenSilent, interface, rate, x?, y?}]`). Beeps: 150 = beep1 confirm/dismiss, 151 = beep2 notice, 152 = beep3
select/back, 153 = beep4 denied, 154 = beep5 incoming. Priorities: beep 1, turret 3, NPC weapon 4, player weapon 5/6, explosion 6, red alert 5,
airlock/cloak 8, menu 10, klaxxon/chatter 0xF, warp out/shutters 0x32, warp up 32000.

Status key: MATCH (already identical), FIXED (was MISSING/DIFFERENT/EXTRA; the fix is written but **not yet built or run**, and neither has `sound_parity_selfcheck.gd`), OPEN (not changed, reason given).

| # | Site (Apple call / original function) | snd, priority, rules | Godot | Status |
|---|---|---|---|---|
| S1 | Weapon fire: `playWeaponFire` (`Weapon_FireShipWeapons`, `Weapon_FirePlayerWeaponBank`, point defense, bay launch) | wëap Sound+200; NPC 4 positional, player 5/6 centred, turret 3, bay 5; wëap Flags 0x0010 only when silent | `SoundCues.weaponFire` via `collectEvents` | MATCH |
| S2 | Explosions / bööm (`.explosion`, `.stellarDestroyed`) | bööm snd 300+n, priority 6, positional 200 px / 850²/d² law, floor 1/8 | `SoundCues.cues` | MATCH |
| S3 | Debris puff `.debrisPuffSound` | snd 372, priority 6, positional | `SoundCues.cues` | MATCH |
| S4 | NPC dying: 9 jittered bursts 0.2 s apart + final blast | bööm snd, priority 6 | `DeathBurstSounds` | MATCH |
| S5 | Player dying: same ten bursts (`beginPlayerDeathSequence`) | bööm snd, priority 6 | bursts were NPC-only; now begun on `.playerDying` (`NovaWorld.collectEvents`) | FIXED (was MISSING) |
| S6 | `.playerDying` / `.shipDisabled` (player) beep | snd 151, priority 1, interface volume | `SoundCues.cues` | MATCH |
| S7 | Cloak on/off `.playerCloakChanged` | snd 381 / 380, priority 8, centred | `SoundCues.cues` | MATCH |
| S8 | Red Alert (`RedAlertCue`, `updateWarnings`) | snd 370, priority 5 | `tickSoundAlarms` | MATCH |
| S9 | Klaxxon while the death timer runs | snd 371, priority 0xF, only when silent, stopped when it ends | `tickSoundAlarms` | MATCH |
| S10 | Warp up (`startWarpUp`/`stopWarpUp`), Caps Lock 2x | snd 128 (129 under 2x), priority 32000, rate = hull multiplier, only when silent, cut at 350/multiplier | `tickSoundAlarms` + `pitch_scale` | MATCH |
| S11 | Warp out: jump arrival, collapsed field, gate arrival | snd 130, priority 0x32, only when silent | `advanceHyperjump` / `completeHyperjump` / gate | MATCH |
| S12 | `quickHyperjump` enhancement charge loop (`startHyperspaceCharge`) | snd 128 looped, cut on commit | the enhancement has no Godot counterpart (the original jump runs) | OPEN (enhancement not ported; no sound to add) |
| S13 | Escort/combat chatter | hail bank snd, priority 0xF, interface volume, holds next line until it ends | bridge `chatterEnd` | MATCH |
| S14 | Mission `PlaySound` operation (`AppGameServices.playSound`) | priority 1, centred, effects level only | `NovaWorld` services hook | MATCH |
| S15 | Touchdown (`.shipLanded` entity 0, paid assistance) | snd 390, priority 8, once; launch is silent | `touchDown` queues `SoundCues.docking` once; `launch()` queues nothing | MATCH |
| S16 | Landing at an uninhabited stellar (`SpaceportView.onAppear`, `Stellar_RunDockAndLaunchSequence` 0x00455e10) | extra snd 151 | missing | FIXED (was MISSING) |
| S17 | Land key: request / denied / clearance / "No response." / too fast / cloaked / destroyed (`pressLand`, 0x00457580, 0x00459950) | 151, 151, 151, 150, 153, 153, 153 | `pressLand` / `postLandingClearance` in the bridge | MATCH |
| S18 | Hypergate refusal 151, wormhole with no exit 153 | 0x00457580, 0x00456ca0 | bridge | MATCH |
| S19 | Flight keys: ` cycle 152; R / Alt-R found 152 else 153; N 150; Alt-N 150 (if targeted); S 152 (if set); 1-4 150; \ 152; E 150 / 150 / none 153; group key 152; no cloak 153 (0x0044b120) | priority 1 | bridge | MATCH |
| S20 | Hail / comm window: open 154 (or refusal), action buttons 151, close 152 (0x0047e470, 0x00480030) | | bridge + `Interactions.gd` | MATCH |
| S21 | Boarding / plunder: board 154, each plunder button 152 (153 refused), Abort 152, capture decision 151 (0x0045a3d0, 0x00482940, 0x00497eb0) | | bridge + `Interactions.gd` | MATCH |
| S22 | Contraband scan 151 / result 154; stolen cargo 151; escort rejoin / fighter recovered 154; repair engaged 154; assistance 151+390; mission failed 151/153; deferred `Q` line 151/153/154 | | `SoundCues.cues` + bridge | MATCH |
| S23 | Galaxy map open 152, close 150; system Find match 154 / miss 153; refused jump 153 | 0x0044b120, 0x004aab30 | `GalaxyMap.gd`, `NavScreens.gd`, bridge | MATCH |
| S24 | Mini map zoom 150, link cycle 152 | | `NavScreens.gd` | MATCH |
| S25 | Galaxy map window: Tab/`\` link cycle 152, +/- zoom 150 while the map is open (`GameContainerView`) | | `GalaxyMap.gd` is being edited by the hypergate/map agent | OPEN (verify; not touched) |
| S26 | J with no route and `autoRoutePlotting` on opens the map silently (no 153) | | `NavScreens.engage_hyperjump` always beeps 153 on refusal | OPEN (NavScreens is the map agent's file; tiny) |
| S27 | News (holovid) open 151 / close 152 (0x0047d180) | | `Spaceport.gd` | MATCH |
| S28 | Mission computer (Player Info) open 151, close 152, Abort with nothing picked 153 (0x00446150) | | `StoryScreens.gd` | MATCH |
| S29 | Shipyard Buy Ship greyed 153 (0x00492f30) | | `SpaceportClassic.gd` | MATCH |
| S30 | Outfitter Sell that fails (would leave free mass negative) 153 (0x0048ea70) | beeped on a *greyed* Sell/Buy instead | now beeps on the failed sale only (`Spaceport._outfit_sell`) | FIXED (was DIFFERENT) |
| S31 | Trade centre / outfit Buy / quantity prompt over-max / hire escort / gamble bet beeps | original and Apple: none | each wired `sound_beep(4)` on a greyed button or invalid entry | FIXED (was EXTRA, 6 sites) |
| S32 | Bar, Hire Escort, Gambling open/close/hire/bet beeps (151/152/153) | none in the original or Apple | `BarScreens.gd` played them | FIXED (was EXTRA, 8 sites) |
| S33 | Story text / mission offer / offer movie open 151 and OK 152 | none | `StoryScreens._open_modal` / `_modal_host` / `_dismiss_text` | FIXED (was EXTRA, 3 sites) |
| S34 | Press of any button in an original window (spaceport hub, trade, outfitter, shipyard, bar, map, Preferences, About) | silent (NovaButton has no sound) | `ClassicDialog.beep` defaulted to snd 150 for every dialog | FIXED (was EXTRA: default now off; confirm / text prompt / panel / pilot screens keep it as Apple's NovaDialog does) |
| S35 | Greyed button in a generic dialog | silent | `ClassicDialog.add_button` wired snd 153 on every greyed press | FIXED (was EXTRA; only the S28-S30 / plunder sites wire it) |
| S36 | Preferences volume arrows 154 after applying (0x00488650) | | `ClassicPreferences._volume` | MATCH |
| S37 | NovaDialog buttons (confirm, prompts, pause menu rows, port-only screens) 150; form errors 152; Enter Ship with a killed pilot 153 | | `ClassicDialog` panel/confirm, `PilotMenu`, `Shell` | MATCH |
| S38 | Main menu: no hover sound | | none | MATCH |
| S39 | Main menu keys: snd 600, wait until it ends, snd 601, act (`FUN_0048bc20`) | | waited a fixed 0.12 s | FIXED (waits `frames / rate` of snd 600) |
| S40 | Main menu mouse: press on a button 600; drag off while held 601; release over it 601 and act at once (`FUN_004861b0`) | | played 600 then 601 on release | FIXED (was DIFFERENT) |
| S41 | Menu shutters 602 start / 603 land | priority 0x32 (`playMenuSlide`); 600/601 at 10 | `soundMenu` used 10 for all four | FIXED (priority by id) |
| S42 | Title music: starts at min(256, step x 0x30)/256, 40 ticks later step x 0x20/256, plays once per visit, fades out 8/256 per tick on leaving, "Intro Music" pref | | looped, level = master x Music slider, cut abruptly | FIXED (`TitleMusic.gd`, `Prefs.music_gain/start_gain`, `MainMenu.leave()`); `.mov` tracks still silent (C5) |
| S43 | Spaceport ambient loop (CustSndID, Ambient Sounds pref) | gapless loop while docked, stops on takeoff | missing | FIXED (was MISSING; C3) |
| S44 | Leaving the game for the menu stops every voice and loop (`stopAllLoops` + `stop(0)`) | | nothing stopped | FIXED (`Shell._open_main_menu` -> `GameAudio.stop_all`) |
| S45 | Volume defaults: step 5 (master 5/8), effects 0.9, interface 0.8; beeps and chatter scale by the interface slider, everything else by effects only | | master 1.0, effects 1.0, interface 1.0 | FIXED (defaults only; saved settings untouched) |
| S46 | Brightness pref (C2) | | stored only | FIXED (`ui/BrightnessVeil.gd`) |
| S47 | `snd` decoding: same `NovaSound.samples`, 16-bit mono, native rate (rounded to an integer for `AudioStreamWAV`, <= 0.003 % pitch), no loop points, rated cues via `pitch_scale` | | `sound_pcm` / `sound_info` | MATCH |
| S48 | 16-voice list, first 8 audible, priority/volume insertion, same-sound guards, stop by id | | `SoundVoiceBoard` (shared with `GameAudioEngine`'s `VoiceList`) | MATCH |
| S49 | Purchases / sells / trades / mission accept / hire: no sound in the original | | none after S31-S33 | MATCH |

Counts (49 rows): 30 MATCH, 16 FIXED, 3 OPEN. Fixed by original category: MISSING 5 (S5 S16 S43 S44 S46), DIFFERENT 6 (S30 S39 S40 S41 S42 S45),
EXTRA 5 groups (S31 S32 S33 = 17 explicit call sites removed; S34 S35 = two dialog defaults).

### Apple vs original (findings; Apple not changed unless stated; summarised in [STATUS.md](STATUS.md) under Known gaps)

1. **Music is scaled by the sound-volume step twice** in Apple: the main mixer already applies `masterVolume x step/8` and `GameAudio.musicGains`
   then sets the track to `step x 0x20/256` (= step/8) again, so the track plays at (step/8)². The original applies it once. Godot plays the
   original level. A fix (compensating the player-node gain) needs listening tests, so it is left for the Apple side.
2. **Spaceport ambient / quickHyperjump charge loops are scaled by the Effects slider twice** (`playLoop(volume: sfxVolume)` on a bus that is
   already `sfxVolume`). The original plays them at the global volume. Godot applies master x effects once.
3. **Ambient loop flag**: the original's landed loop only re-allocates its voice from the 0x00491f30 tick when spöb Flags2 bit 0x0010 ("Loop
   ambient sound") is *clear* (`Audio_AllocateVoiceSlot(&DAT_00591ab4)` on event 5); Apple always loops. The exact retrigger cadence of event 5 was
   not traced, so both frontends loop gaplessly.
4. Classic status-message rectangle: Apple draws it 16/8 px in from the corner with a 14 pt shadow; the original is left + 25, bottom - 5, 30 px high, 12 pt white, no shadow. Godot's Classic HUD follows the original (GODOT_LAYER.md, "Message position").
5. Apple's ambient check is `soundID >= 0`; the original loads it only when `CustSndID >= 128` and the pref is on. No shipped spöb has 0-127.
6. Apple's `.launch` event exists but is never played; the original launch is silent too (verified: `Stellar_RunDockAndLaunchSequence`
   sounds only the uninhabited snd 151).
7. Mission-computer, news, plunder, hail and flight-key beeps match their decomp call sites (see the table); no Apple deviation found there.

### Code touched by this pass (other agents: re-read before editing)

`godot/audio/GameAudio.gd`, `godot/audio/TitleMusic.gd`, `godot/Prefs.gd`, `godot/Main.gd` (veil), `godot/screens/{Shell,MainMenu,Settings,Spaceport,SpaceportClassic,BarScreens,StoryScreens,PilotMenu}.gd`,
`godot/ui/classic/{ClassicDialog,ClassicMainMenu}.gd`, new `godot/ui/BrightnessVeil.gd`, bridge `NovaWorld.swift` (player death bursts, uninhabited
landing beep, menu priorities, `landed_ambient_sound`, `debug_pending_sounds`, `debug_drain_sounds`) and `Audio.swift`. No `app/` or `Sources/` file changed.
