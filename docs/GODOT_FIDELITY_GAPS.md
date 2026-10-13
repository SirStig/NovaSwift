# Godot fidelity gaps: what the ORIGINAL EV Nova has that `godot/` still lacks

Audit date 2026-10-13, read-only, against the live tree (commit `18404c6` plus uncommitted work; another agent is currently adding
`godot/Movies.gd`, `godot/ui/MoviePlayer.gd`, `godot/tests/movies_selfcheck.gd`). This supersedes the status columns of
`docs/GODOT_PARITY.md`, which is stale (Story Map, Debug Suite, plug-ins, settings plumbing, flight visuals, new-pilot flow, About,
Pers LinkMission offers, gambling, hire escort and jettison pods are all done now).

Goal: play the original game start to finish, looking and behaving like it. Only things the original game has are listed in the
packages. NovaSwift-only extras are in the deferred list at the bottom.

How it was checked: the Apple app (`app/NovaSwift/Game/GameScene.swift`, `GameContainerView.swift`, the 56 `scene.on...` / `...Provider`
hooks the container wires, every `WorldEvent` case the scene handles) and `docs/reverse-engineering/FIDELITY_PLAN.md` items were
walked and each behaviour was grepped in `godot/**/*.gd` and `godot/bridge/Sources/NovaSwiftGodot/*.swift`. Most original rules live in
shared Swift (`Sources/`) and are already reached by the bridge. The remaining gaps are mostly places where the Apple container/scene
wires a shared rule to the live world and the bridge never does, so the rule never runs. Status vocabulary: DONE / PARTIAL / MISSING.
Effort: S under a day, M 1-3 days.

Verified DONE (no work needed): ship flight/AI/weapons through the shared engine; ïntf status bar (bars, radar, target, secondary,
nav, cargo, credits); STR# 2002 message sources and one-line placement; landing two-press + clearance + fee + bribes; gates and
wormholes; hyperjump (align/accelerate/flash/arrive, fuel, multi-jump, no-jump refusal #42/#10/#29); hail/bribe/beg/assist/tribute;
board/plunder/capture/panic self-destruct; escorts window + orders + upgrade/sell + payroll; Trade Center incl. öops disasters and
junk rows; outfitter/shipyard/ship info; Bar, Hire Escort, Galaxy Racing gambling (no clip, see C), Mission BBS, mission offers incl. pêrs
LinkMission; mission ships/crons/NCB/story texts; Player Info / Mission Info (shared `PlayerInfoPages`); jettison + pods; scans and
contraband fines; tribbles/perishables; eject/escape pod/respawn; self-destruct; death + Strict Play permadeath; pilots/saves/import;
intro slideshow; main menu incl. About (dësc 32767); DLOG 4003 preferences window (visual prefs applied); flight visuals (shän layers,
bank, shield flare, booms, smoke, trails, lightning, death bursts, camera Classic).

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
| A6 | Bombs (OS-08, ModType 47/50) detonate after a fuse | DONE (2026-10-13, `WorldPilotLink`; see GODOT_LAYER.md "Live-world wiring") | Apple `checkHazardOutfits` (`GameContainerView.swift:2954`) is called from `onPlayerTick`; nothing equivalent in the bridge |
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
| C2 | Brightness arrows (STR# 139, 0-6) change screen gamma | MISSING | value is stored only; Apple applies a black/white veil (`RootView.brightnessVeil`, gamma = step*10+70 %) |
| C3 | Ambient Sounds: the landed spaceport plays the spöb's `AmbientSound` loop; off = silence (0x00491f30) | MISSING | no loop in `GameAudio.gd` / Spaceport; Apple `GameAudio.startAmbient` / `stopAmbient` |
| C4 | Preferences that are stored but have no effect: Share Processor Time (no counterpart needed), Ship Animations (applied via `set_flight_options`), Check For Updates (N/A) | PARTIAL | only document; low value |
| C5 | Title music from `.mov` (Nova Files names it as `.mov`) | PARTIAL | `TitleMusic.gd` is silent for `.mov` unless the movies package converts audio |

### Package D. Galaxy map fidelity (original map window)  [S-M]

Files: `godot/screens/GalaxyMap.gd`, `godot/screens/NavScreens.gd`, `godot/screens/HyperjumpFx.gd`, bridge `NovaWorld.swift` region
`Navigation & hyperjump` and `Navigation.swift`. Tests: new checks in `godot/tests/ui_polish_selfcheck.gd` neighbours.

| # | Original behaviour | Status | Concrete gap |
|---|---|---|---|
| D1 | Show/Hide Borders political overlay, persisted (STR# 150 #56/#57) | MISSING | `docs/GODOT_LAYER.md` lists it as not ported; Apple `GalaxyMapView` has it |
| D2 | Mission-target cicn markers on the map and their fog exception | MISSING | listed as not ported |
| D3 | Map Tab / `\` adjacent-destination cycling (0x004a7710) | MISSING | `map_extend` is bound to Tab with a different meaning |
| D4 | Floating-map frame border and help line | MISSING | cosmetic, listed as not ported |
| D5 | Legal Status (#326) and Goods/Services panels honour exploration levels 1/2 (UI-04) | PARTIAL | verify side panel against `GalaxyMapView` for unexplored/charted levels |
| D6 | In-flight `\` destination cycle | MISSING | shared with B5; D owns the bridge half if B has not landed it |

### Package E. Movies (QuickTime) and media  [M, partly in progress]

Files: `godot/Movies.gd`, `godot/ui/MoviePlayer.gd`, `godot/screens/BarScreens.gd` (race clip only), `godot/screens/StoryScreens.gd` (offer
movie), `godot/screens/Spaceport.gd` (BBS offer hook, small), `godot/audio/TitleMusic.gd`. A concurrent agent is already writing
`Movies.gd` / `MoviePlayer.gd`; coordinate with it before assigning.

| # | Original behaviour | Status | Concrete gap |
|---|---|---|---|
| E1 | Race betting plays `Race 1..4.mov` | DONE (per coordinator, 2026-10-13) | wired via `Movies`/`MoviePlayer`; only re-verify the no-ffmpeg fallback |
| E2 | Mission-offer `dësc` movies (not wired yet; confirmed) (a mission's offer/completion text carries a movie filename; Apple `MissionBoardView.playMovie`) | MISSING | no movie hook in `StoryScreens.gd` offer dialog |
| E3 | `playMovies` pref gates all of the above | PARTIAL | read in `BarScreens.gd` only |

### Package F. Flight render remainder and on-device verification  [S-M]

Files: `godot/flight/*.gd`, `godot/bridge/Sources/NovaSwiftGodot/FlightVisuals.swift`, `godot/screens/HyperjumpFx.gd` (shared with D: only the
no-FX path). Do not touch HUD files.

| # | Original behaviour | Status | Concrete gap |
|---|---|---|---|
| F1 | Murk (sÿst.Murk) fog: far objects fade to the murk colour, per-sprite darkening | PARTIAL | `GODOT_PARITY.md` package 4 status: star tint only, no per-sprite murk |
| F2 | Hyperjump NPC warp-out/warp-in nodes (ships popping in/out of hyperspace) | PARTIAL | verify `shipArrived/shipDeparted` effects in `EffectsDrawer.gd` |
| F3 | Visual verification of the additive/fill shaders on a real GPU (gl_compatibility) | UNVERIFIED | all flight visuals have only headless/composed-PNG checks (`flight_visuals_selfcheck.gd`) |

---

> Concurrency note: a controls/targeting/weapons agent is editing `Controls.gd`, `Main.gd` and the targeting/weapons parts of `NovaWorld.swift`
> right now. Package B items B4/B5 (Return-dismiss, `\` cycle, key table) and anything in the Targeting/Weapons/Input regions belong to that
> agent: re-check them before assigning, and keep B to messages/HUD icons until it lands.

## Top 10 most impactful gaps (play-through order)

1. A1 combat rating / legal record / rank revocation never sync (`FlightComm.syncStanding` unused): rating-gated missions and ranks never unlock.
2. A3 pêrs and `shïp.AppearOn` gating and defeated/grudge persistence unwired: named pilots respawn, story-gated ones misappear.
3. A2 scooping and mining lose all cargo (`.asteroidMined` ignored, hold-room hook defaults true).
4. A4 pirates cannot board and plunder the player.
5. B1/B2 arrival, launch and sÿst buoy status lines missing (every jump and every launch).
6. A5 garrison/reinforcement/stellar-armor persistence across jumps.
7. B3 HailQuote broadcasts (ambient NPC chatter and taunts) missing.
8. C1 Key Settings dialog (DITL 4002) not ported.
9. E2 mission `dësc` movies (and E1 verification of race clips).
10. D1/D2 map: borders overlay and mission-target markers.

Also small but visible: C2 brightness and C3 spaceport ambient loop (preferences that do nothing), B4 Return-dismiss, B6 red-alert blink,
A6 bombs, A7 Strict Play flag and per-day seed.

---

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

Every Apple file was mapped to a Godot equivalent. Result: nothing original is absent that is not already listed in packages A-F.

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
| `Audio/*` | `audio/GameAudio.gd`, `TitleMusic.gd` | DONE except C3 ambient loop |
| `Input/*` | `Controls.gd` | DONE; touch/tilt/haptics N/A; being edited by the controls agent |
| `UI/*` (DITL dialogs, desc dialog, fonts, palettes) | `ui/classic/*` | DONE |
| `Tutorial/*`, `Debug/*`, `Editor/*`, `Multiplayer/*`, `Plugins/*`, `Data/HDGraphics` | `Tutorial.gd`, `Hints.gd`, `debug/*`, `Plugins.gd` | ENHANCEMENT (ported or deferred) |

## MISSING in both Apple and Godot (original behaviour per the decomp / reverse-engineering docs)

Source: `docs/reverse-engineering/FIDELITY_PLAN.md` "Deferred / not modelled" notes, `~/Projects/evnova-re/audit/{coverage,quirks,ui_rules}.md` and
`audit/unverified/*.tsv` (rows still `named-only` / `unexplored` in gameplay subsystems). Ordered by player-visible impact. Each is an
additional shared-engine or UI task; do it in Swift (`Sources/`) first so both frontends gain it.

| # | Original behaviour (address) | Evidence | Note |
|---|---|---|---|
| X1 | Map Tab / `\` adjacent-system cycle (0x004a74f0 / 0x004a7710) and in-flight `\` destination cycle | FIDELITY UI-15 "Deferred", ui_rules_partA row `MISSING` | Apple has `cycleHyperspaceLink` bound to `\` but the plan lists it deferred; verify before assigning |
| X2 | New-pilot travel hint chain STR# 2002 #22-31 (and the "hyperspace hint on every launch until reload" quirk) | UI-11 "Deferred" | overlaps `tutorialHints`; original text/trigger not reproduced |
| X3 | Original wording for remaining invented status lines: plunder credits/fuel/ammo ("Took N credits", "Siphoned...", "Transferred N rounds"), contraband fine/warning lines, domination ("submits to your rule"), stellar "scrambles N defenders", "destroyed"/"restored", escort "was destroyed" | UI-11 "Deferred: rewording the remaining invented hud.post sites" | grep `hud.post("` in `GameContainerView.swift` (about 20 sites) and bridge `post("` |
| X4 | HailQuote broadcast gates: pêrs flags 0x0400 / 0x0800 / player-class gates and the ambush trigger | UI-11 | even after Godot B3 lands the Apple port, these gates are unmodelled |
| X5 | Player Info: Tab / Shift-Tab page cycling and cargo junk count words | UI-13 "Deferred" | window must take keyboard focus from flight controls |
| X6 | Self-destruct cue sounds; hulls docked to the player die with it | UI-15 | |
| X7 | Folding hulls: `shän` Flags 0x0002 unfold on hyperspace/landing | FIDELITY Q8 (open) | `HullAnim.baseSet` never reads it |
| X8 | Tractor beam: shooter pulled by a heavier target arm | WP note, FIDELITY :1389 | |
| X9 | Released mission escort: cargo hand-back; ShipStart -1 spawn-count nuance; shop in-screen offer timer arms | AI-34, MS-06, MS-05 notes | low |
| X10 | Pod-debris sound (DAT_00591a80, id unknown); përs-flag debris arm at 0x00433050 l.904; RNG draw-shape parity (#20) | "Not done" list of the AI/spawn sweep | changes only the random stream / one sound |
| X11 | Target selection details: Q-UI-03 60-frame re-pick; freed target slots being reused | UI-07 | |
| X12 | Unresolved original quirks (UNCLEAR rows): miners hostile after assistance request (0x0047e470), OnShipDone text suppression on abort (0x00443c60), carrier escort weapon-1 range (Q1), escorts' `chär` Initial Record order | `audit/quirks.md` | needs a decomp trace, not code |
| X13 | Travel-destination overlay sprites and travel countdown sprite (0x0048e970 `NovaUi_LoadTravelOverlaySprites`, 0x00492c40 `RenderTravelDestinationOverlay`, 0x0042cc30 `Stellar_TickTravelCountdownSprite`, 0x00438fc7 reticle visibility with cloak/scanner/untargetable) | `audit/unverified/starmap_travel.tsv` (`named-only`) | verify against `updateSelectionBrackets` before treating as a gap |
| X14 | Frame/session cadence fragments never reconstructed: alt-tab dt reset and pause (0x00497cf0/0x00497d50, Apple `pauseOnFocusLoss` is an enhancement), viewport flash/particle present passes (0x00439a10-0x00439d40), transition-frame latch (0x00467de0) | `coverage.md` cluster 3 | mostly presentation timing |
| X15 | Resource-loader record zero-padding to fixed minimum sizes for every type (0x004bd3c0) | `coverage.md` cluster 4; LD-02 marked DONE | confirm per-type widths against `audit/raw/resource_field_layouts.tsv` |
| X16 | Licensing / shareware enforcer (përs slot 0x3ff, 0x0046ac50) and License.lcs | `coverage.md` cluster 8 | out of scope for BYO-data; listed for completeness |
| X17 | Debug HUD mnemonics `NovaUi_DrawAiStateMnemonic` / `DrawAiControlModeMnemonic`, CE cheat/NCB console (0x00872040) | `unverified/ai.tsv` | developer tools; Apple's AI overlay and debug console cover the intent |

### New Godot gaps found by this pass (already folded into the packages above)
A8 (aux-ship budget decrement, stranded-fighter accounting), B8 (cannot-jump overlay auto-clear), C4/C5 (stored-but-inert prefs, `.mov` title music),
D5 (exploration-level panels), F2 (NPC warp effects). No further Godot-only gaps were found in the Apple file walk.

---

## Plug-in loading gaps (2026-10-13, from `scripts/plugins-check.sh`; details in `docs/GODOT_LAYER.md` "Real plug-in verification")

All 13 downloaded plug-ins load with exactly the shared-Swift resource counts and play a pilot start to a jump without errors. What is left
is the same in the Apple app unless noted:

* **dësc movies (DONE 2026-10-13, both apps)**: story texts, docking, intro text, acknowledgements (see GODOT_LAYER "Total-conversion add-ons").
  Still missing: the movie played on entering a hypergate / wormhole (`Stellar_EnterHypergate` 0x00456480 / `Stellar_EnterWormhole`
  0x00456ca0 -> `FUN_0049e3c0`), which lives in flight code owned by other work (Main.gd / GameContainerView). Godot needs ffmpeg for movies.
  Base `dësc` 338 names `flyby.qt`, which is not in the user's base data (the original also finds nothing).
* **Intro movies / GIF (DONE)**: they are dësc 20000 (chär intro text) and 32766 (X key), not separate launch screens.
* **Plug-in fonts (DONE)**: registered from the TC folder in both apps.
* **Facelift on Override (DONE)**: per-TC add-on list; the old "stage it into Plug-Ins" is no longer needed. Global plug-ins still don't load under a TC.
* Graphics-only (HD pack) plug-ins on a TC's list are not ranked as layers (they have no files); add-ons with `.rez` files are.
* Headless runs print Godot "This control can't grab focus" warnings from `ui/classic/ClassicDialog.gd:598` (`focus_first`); not plug-in
  related (the BASE run prints them too) and filtered by the script.
