# Godot Layer — Linux / Windows support

**In progress.** The frontend plays a pilot from the main menu through flight,
landing, the spaceport, missions, the map and saving. Verified on-toolchain (macOS,
Swift 6.3 + Godot 4.7): the bridge builds, headless self-checks load real EV Nova
data and step the simulation, and all 13 catalog plug-ins load. The macOS arm64 and Linux x86_64 (Steam Deck) packages
have been built and verified headless (see [PACKAGING.md](PACKAGING.md)); nothing has run on a real Steam Deck,
Windows PC or GPU, and flight visuals have not been checked on a real GPU. The galaxy map, gate movies, sound
parity and brightness work was built and tested on macOS on 2026-10-13. The 2026-10-13 closing pass (Key Settings,
`.mov` title music, shot murk, quick hyperjump, status text and travel hints, Player Info) is written but not yet
built or tested; each such section below says so.

This file describes how the layer is built. What is done, written-but-untested and
open is tracked in [GODOT_FIDELITY_GAPS.md](GODOT_FIDELITY_GAPS.md), summarised in
[STATUS.md](STATUS.md#linux-and-windows). Where this file and those disagree, they win.

## Version matrix

| Piece | Version | Where it's pinned |
|---|---|---|
| Godot (floor) | **4.6** | `godot/project.godot` `config/features`, `godot/NovaSwift.gdextension` `compatibility_minimum` |
| Godot (developed against) | 4.7 | — |
| SwiftGodot | `main`, revision-locked | `godot/bridge/Package.swift` + `Package.resolved` |
| Swift toolchain | 6.3 | `.github/workflows/godot-linux-windows.yml` |

The Godot floor is not a taste call: it has to be **at least** the release
SwiftGodot's pinned revision generated its bindings from, because a GDExtension
that calls an interface function the host engine doesn't export takes the editor
down rather than degrading. It was left at `4.2` long after SwiftGodot's `main`
had moved on; that's now corrected. Move both files together whenever the
SwiftGodot pin moves.

`branch: "main"` is still a moving target on paper, but `Package.resolved`
locks the revision, so a plain `swift build` is reproducible — only an explicit
`swift package update` moves it. Pinning to a SwiftGodot tag remains the right
end state.

> The authoritative platform decision for Apple targets is
> [ARCHITECTURE.md](ARCHITECTURE.md) (native Swift + SpriteKit). This document
> is the *complementary* decision for **desktop Linux and Windows**, which
> SpriteKit cannot reach. It does not replace the Apple frontend; it adds a
> second, cross-platform frontend on top of the same Swift core.

## The problem

NOVA Swift is split into two halves:

| Half | Platforms | Status |
|---|---|---|
| **Core** — `NovaSwiftKit`, `NovaSwiftEngine`, `NovaSwiftStory`, `NovaSwiftNet` | portable Swift | builds on any Swift toolchain |
| **Frontend** — `app/NovaSwift/` (SwiftUI + SpriteKit) | Apple only | macOS / iPadOS / iOS / tvOS |

The simulation, data layer, and story runtime are plain Swift with almost no
Apple-framework coupling (an audit found exactly **one** unconditional
`import CoreGraphics`, in `ColorModels.swift`, needing only `CGPoint` — now
guarded). The Apple-only part is the *frontend*: SwiftUI for UI and SpriteKit
for rendering. Those two frameworks are what pin the game to Apple hardware.

To reach **Linux and Windows** we need a cross-platform host for windowing,
rendering, input, and audio — the exact job SpriteKit does today on Apple.

## Decision: Godot 4 host + SwiftGodot GDExtension bridge

We add a **second frontend** built on **Godot 4** and bridge it to the existing
Swift engine with a **[SwiftGodot](https://github.com/migueldeicaza/SwiftGodot)
GDExtension**. The simulation stays in Swift; Godot owns the screen.

```
┌──────────────────────────────────────────────────────────────┐
│  godot/  — Godot 4 project (GDScript + scenes)                │
│    Windowing · rendering · input · audio · UI                │
│    Linux · Windows · macOS  (one project, all three)         │
├──────────────────────────────────────────────────────────────┤
│  NovaSwift.gdextension  → loads the native bridge library    │
├──────────────────────────────────────────────────────────────┤
│  godot/bridge/  (own SPM package, builds a .so/.dll/.dylib)  │
│    SwiftGodot bridge: `NovaWorld` node + value marshalling.  │
│    Exposes the engine to GDScript as @Callable methods.      │
├───────────────────────────────┬──────────────────────────────┤
│  NovaSwiftEngine (Swift)      │  NovaSwiftKit (Swift)        │
│    the same simulation the    │    the same data layer the   │
│    Apple app runs             │    Apple app runs            │
└───────────────────────────────┴──────────────────────────────┘
```

### Why this over the alternatives

| Option | Verdict |
|---|---|
| **SwiftGodot GDExtension** (chosen) | ✅ Reuses the entire ~76-file Swift core unchanged. Godot handles Linux/Windows/macOS windowing, rendering, input, audio, and UI for free. One binary per platform + one shared Godot project. Swift ↔ Godot is a maintained, macro-driven binding. |
| **C-ABI core + full GDScript reimplementation** | ❌ Thinner bridge, but the whole UI/render layer is rewritten in GDScript and every engine value crosses a hand-rolled C boundary. More new code, more drift from the Swift source of truth. |
| **Full GDScript/Godot rewrite** | ❌ Discards the Swift engine that already reproduces EV Nova faithfully. Two engines to keep in sync forever. Non-starter. |

### Why Godot (not SDL/raylib/a custom loop)

Godot gives us a scene graph, a UI toolkit (`Control` nodes), input mapping,
audio, a text renderer, and export templates for all three desktop OSes in one
package — most of what `app/NovaSwift/` gets from SwiftUI+SpriteKit, but
cross-platform. A raw SDL loop would mean rebuilding all of that by hand.

## What "the bridge" is

`godot/bridge/` is its **own** Swift package (it depends on the root NovaSwift
package by path, so the Apple app's `swift build`/`swift test` never see
SwiftGodot). It compiles to a **dynamic library** (`.so` on Linux, `.dll` on
Windows, `.dylib` on macOS) that Godot loads through
`godot/NovaSwift.gdextension`. It depends on `NovaSwiftEngine` (which pulls in
`NovaSwiftKit`) and exposes one Godot-visible class:

### `NovaWorld` (extends `Node2D`)

A thin, allocation-light wrapper around the engine's `World`. GDScript calls it
every frame. Its surface (see `godot/bridge/Sources/NovaSwiftGodot/NovaWorld.swift`):

- **World setup**
  - `load_game(base_dir) -> bool` — discovers + merges the player's own EV Nova
    data via `GameLibrary` (BYO-data, same as the Apple app).
  - `make_world(system_id) -> bool` — after `load_game`, populates a real system
    through `GameSession.makeWorld` (NPCs from the `düde`/`flët` spawn table).
- **Input** — `set_intent(turn_left, turn_right, thrust, reverse, afterburner,
  fire_primary, fire_secondary)` maps a frame of Godot input onto the engine's
  `ControlIntent`.
- **Tick** — `step(dt)` feeds one display frame into a **fixed 30 Hz
  accumulator** and runs whole ticks out of it, exactly as `GameScene.update`
  does on Apple. This matters for fidelity, not just tidiness: `World.step`
  integrates flight, reloads, AI re-planning and spawn cadence *per call*, so
  driving it with a raw frame delta makes the same ship handle differently at
  60 Hz and 144 Hz. `render_alpha() -> float` reports how far the frame sits
  into the next pending tick; every pose below is already eased by it off the
  engine's own `snapshotRenderState()` slots, so a 30 Hz sim glides on a 144 Hz
  display instead of stepping.
- **Readback** (for rendering, packed to avoid per-entity Variant churn)
  - `player_position() -> Vector2`, `player_angle() -> float`,
    `player_velocity() -> Vector2`, `player_shield_fraction() -> float`,
    `player_armor_fraction() -> float`, `player_is_alive() -> bool`
  - `ship_count() -> int` and `ship_transforms() -> PackedFloat32Array`
    (`[x, y, angle, kind]` per live ship, player first) so GDScript can draw all
    ships from one array.
  - `ship_visuals() -> PackedFloat32Array` — `[cloak, ionize, thrusting]` per
    live ship, same order, for the cloak dissolve, the ionization tint and the
    engine-glow overlay.
- **Combat entities** — the things that make a fight visible. All packed, all
  render-interpolated where the engine keeps a snapshot slot for them.
  - `projectile_transforms() -> PackedFloat32Array` (`[x, y, facing]` per live
    shot) and `projectile_styles() -> PackedInt32Array`
    (`[graphicSpinID, spins, translucent]`, same order).
  - `beam_segments() -> PackedFloat32Array` — 13 floats per live beam:
    `[x0, y0, x1, y1, width, alpha, r, g, b, coronaR, coronaG, coronaB,
    coronaFalloff]`. Both colors cross the bridge because real EV Nova beams
    ship no sprite art at all — the core→corona gradient *is* the authored look,
    and a `width` of 0 means "corona only, no core".
  - `asteroid_transforms() -> PackedFloat32Array` (`[x, y, radius, angle]`) and
    `asteroid_styles() -> PackedInt32Array` (`[roidTypeID, spriteFrame]`).
- **Event drains** — both genuinely drain, handing over what has accumulated
  since the last call and emptying the buffer. `World.events` is cleared at the
  top of every `step`, so reading it directly both loses the first tick's events
  on a two-tick frame and re-reports the last tick's events forever on a frame
  that doesn't tick at all (which is every frame while docked).
  - `drain_events() -> PackedStringArray` — one string per `WorldEvent`
    (weaponFired, shipDestroyed, …) for the message log and sound hooks.
  - `drain_effects() -> PackedFloat32Array` — the subset that wants to be
    *drawn*, `effect_stride()` floats per row: `[kind, x, y, p0, p1, r, g, b]`.
    Kinds: 0 explosion, 1 shield hit, 2 armor hit, 3 asteroid debris, 4 ship
    dying, 5 ship destroyed, 6 weapon fired. This is what carries the *position*
    an event happened at — the name-only drain never could.
  - `system_background_color() -> PackedFloat32Array` — the system's authored
    `sÿst.BkgndColor` as `[r, g, b]`, so nebula systems don't clear to black.
- **Real-data render queries** (empty/sentinel until data is loaded, so the frontend
  calls them unconditionally)
  - `has_game() -> bool`, `player_ship_type() -> int`,
    `ship_type_name(ship_type) -> String`.
  - `ship_sprite_frames() -> PackedInt32Array` — `[shipType, spriteFrame]` per
    live ship, same order as `ship_transforms()`, so the frontend picks the right
    pre-rotated sprite frame.
  - `jump_radius() -> float`, `body_transforms() -> PackedFloat32Array`
    (`[x, y, radius, kind]` per stellar body) and `body_spob_ids() ->
    PackedInt32Array` for the system's planets/stations/gates.
- **Sprite export** (raw RGBA — the decoders are pure Swift, no CoreGraphics, so
  this is fully cross-platform; GDScript builds an `Image`/`ImageTexture` once per
  resource and caches it). One *kinded* accessor rather than a method pair per art
  type, since every one of these resolves through the same `spïn` → `rlëD` path
  and marshals identically — only the lookup varies:
  - `sprite_info(kind, id) -> PackedInt32Array` = `[frameW, frameH, frameCount,
    columns, rows, surfaceW, surfaceH, animationRate]`.
  - `sprite_rgba(kind, id) -> PackedByteArray` = the RGBA8 surface (6-wide frame
    grid; frame *i* is at cell `(i % 6, i / 6)`).
  - `kind`: 0 hull · 1 engine glow · 2 shield · 3 running lights · 4 weapon glow ·
    5 spöb · 6 destroyed spöb · 7 weapon shot art (by `spïn` id) · 8 `bööm`
    explosion · 9 `röid` rock · 10 starfield tile. The values are API; GDScript
    mirrors them as `SPRITE_*` constants and they must not be reordered.
  - `animationRate` is the `bööm`'s authored playback rate and 0 for every other
    kind (they're rotation sheets indexed by heading, not timed animations).
    FrameAdvance *R* means *R*/100 × 30 fps, so a frame lasts 100/(30*R*) seconds.

The bridge is **stateless glue**: no game logic lives here. Anything the bridge
does that isn't marshalling is a bug — new behavior belongs in the engine, where
the Apple app gets it too.

## Vertical slice (what runs today)

`godot/` is a minimal but real Godot project. `Main.tscn` / `Main.gd`
instantiates a `NovaWorld`, feeds keyboard input into `set_intent` each frame,
calls `step(delta)`, and renders the result. There is no data-free mode (the old
demo world was removed): without EV Nova data the shell shows only the Data
Setup wizard, see "Game data import" below.

- **Real data** — once EV Nova data is found (`NOVA_DATA_DIR` env var, the repo's
  git-ignored `data/base/`, or the managed folder the importer fills), it `load_game` + `make_world(-1)`s a real
  system and draws **actual hull, planet, shot, rock and explosion sprites**
  decoded by `NovaSwiftKit`, plus the jump-radius ring. Sprites are the engine's
  own RGBA decode uploaded as Godot textures (cached per `(kind, id)`).

Either way, the arrow keys fly the ship with the engine's real Newtonian
momentum — you swing the nose and keep drifting, exactly like the Apple build,
because it *is* the same `World.step`.

This proves the full loop — **Godot input → Swift `ControlIntent` → `World.step`
→ Swift readback → Godot rendering** — works on Linux and Windows, over both a
synthetic world and the player's real data. It is not the finished game; it is
the foundation the real UI is built on next.

### Division of labour in the frontend

`Main.gd` lays out pixels and does small numeric formatting; it never decides
game state. Targeting, hostility, weapon readiness, fuel, sensor range, landing
eligibility and the whole combat entity set are engine calls. The one thing the
frontend owns outright is the **transient particle layer**: the engine says "an
explosion happened here, this big, playing this `bööm`", and how that reads on
screen is presentation. Anything past that belongs in the engine, where the
Apple app inherits it too.

### In-flight interactions (hail · board/plunder · escorts)

`godot/screens/Interactions.gd` + NovaWorld's `// MARK: Interactions` section.
All rules are shared Swift, extracted from the Apple `GameContainerView`/`GameScene`
(which still carry their own copies; nothing under `app/` was changed):
`FlightComm` (ship hail + stellar comm: `OriginalComms`, `StellarComm`,
`PaymentWindow`, `PersEncounter`; STR# 150/2002/3000/3001/3002 strings, bribes,
Request Assistance / Beg For Mercy, Demand Tribute / Release, domination
persisted through `StoryEngine`), `FlightPlunder` (board range, loot buttons,
panic self-destruct, `World.resolveCapture` odds, Use as Escort / Take Command)
and `FlightEscorts` (`EscortCommandPanel`, group orders, Release, roster respawn
and loss). The frontend pauses the sim while a dialog is up. Keys (Controls.gd):
Y hail (Alt-Y the selected stellar), B board, E the Escort Commands panel, F/D/V/C/
Alt-C escort attack/defend/hold/formation/return — the original's own keys (the Apple
app's `KeyBindings.defaults`); pad D-pad ← hail, → board. Known gaps: `pêrs`
LinkMission offers from a hail/board are not presented; the Escorts window has no
Upgrade/Sell (shipyard marks).

### Flight controls checklist (keyboard + pad)

Every flight action of the Apple app's `GameAction` set has an InputMap action in
`Controls.gd` and a hotkey pass in `Main._process_hotkeys` (or `NavScreens` / `Interactions`
/ `StoryScreens`), asserted end to end by `tests/controls_selfcheck.gd` (key/pad tables,
then each action through Main.gd -> bridge -> engine). Tab and ` both step the ship target
(Shift back, Alt-` escorts only); the cycle is the original's (`Ship_FindNextPlayerCycleTarget`:
slot order, every ship outside the squad, no range limit, past the last it clears to "No
Target" and the next press starts over). `\` / Shift-`\` step the armed hyperspace link
(`StarMapRoute.cycleLink`, shared) and raise the route mini map (`screens/RouteMiniMap.gd`;
`-` / `=` zoom it for ~8 s, as `routeMapShownAt`/`routeMapUnitsPerPixel`); Return dismisses
the status message. Pad: X cycles targets (the Apple `PadBindings`: X=targetNext,
Y=nearestHostile). Port-only Apple extras with no original key (camera view/zoom, ship-info
card, Evasive) are not bound in Godot. `docs/GODOT_SETTINGS_KEYS.md` lists the rebind keys.

### Controller cursor (`godot/ui/PadCursor.gd`, autoload)

Mirrors the Apple app's stick cursor (`ControllerCursor.swift`, docs/CONTROLS.md "The UI cursor") so every menu, dialog
and docked screen is reachable from a pad with no per-screen code. It draws a pointer on a high `CanvasLayer` (400, above
PadKeyboard) and **synthesises mouse events** (`Input.parse_input_event`), so hover styles, sliders, `ItemList`s and custom
`_gui_input` all respond.

**Focus follows the pointer.** As the pointer moves onto a focusable control it takes keyboard/pad focus (so the Classic
and NovaSwift focus highlights always mark what is under the pointer, and A can never press a control the pointer has
left). Over empty space focus is lifted and parked; the next d-pad press resumes from it. Regression check:
`tests/pad_cursor_grid_selfcheck.gd` (run it windowed as well; a Retina window has a 2x final transform).

**Clicks are deferred.** Pad A's synthetic mouse press/release is sent with `call_deferred`, not from inside the
joypad event's own dispatch: in a real window a mouse event parsed and flushed mid-dispatch is dropped (headless
delivers it, so headless tests can't catch this). `tests/pad_cursor_real_a_selfcheck.gd` drives a real joypad A through
`Input.parse_input_event`; run it windowed.

- **Left stick** moves the pointer (radial dead zone from `Controls.stick_deadzone`, squared response, ~1.1 viewport heights/s
  at full tilt x the speed setting, slowed to 45% over anything clickable). While the cursor is *available* the left stick is
  removed from `ui_up/down/left/right`, so it no longer also walks focus; the **d-pad** still does, and a d-pad focus change
  glides the pointer (0.1 s) to the focused control.
- **A** presses/releases a left mouse button at the pointer (holding drags sliders / scroll bars). It is consumed *only* when
  the pointer is over a clickable control (button, field, list, slider, scroll bar, tab bar, scripted `STOP` control with a
  `_gui_input`, or any control with meta `pad_clickable`); over empty space A falls through to `ui_accept`. **B** stays `ui_cancel`.
- **Right stick** sends mouse-wheel events at the pointer (6-18 per second by deflection), scrolling `ScrollContainer`s and lists.
- **Last input wins**: a real mouse move (> 2 px) or a key hides the pointer; the next stick motion shows it at the last mouse
  position, else the focused control's centre. Its own events are recognised (`is_synthetic`) so PadKeyboard / the Classic
  nav tracker do not mistake them for a mouse.
- **Coordinates**: the pointer is in viewport coordinates; events are sent in window coordinates via
  `get_viewport().get_final_transform()` (canvas_items stretch + aspect expand).
- **Suppression** (`PadCursor.suppress(reason)` / `release(reason)`; any reason hides it): `"flight"` (Main.gd, plain flight with
  the HUD, A fires weapons), `"map"` (galaxy map has its own stick cursor), `"intro"` (new-pilot intro), `"keyboard"` (PadKeyboard
  open). All set from `Main._cursor_state`, except `"keyboard"` (PadCursor listens to PadKeyboard's signals).
- **Settings** -> Controls: *Controller cursor* (`input/pad_cursor`, default on) and *Controller cursor speed*
  (`input/cursor_speed`, 0.4-2.0, default 1.0).
- Test: `tests/pad_cursor_selfcheck.gd` (hooks `debug_move_to`, `debug_press_a`, `debug_scroll`).

### Action wheels (`godot/ActionWheels.gd`, `godot/ui/ActionWheel.gd`)

Steam-style radial menus so the whole flight action set is reachable from a pad (mirrors the Apple app's
`ActionWheels.swift` / `ActionWheelOverlay.swift`; user-facing notes in docs/CONTROLS.md). LB = Combat & Fleet, RB = Targeting & Nav,
Back = Info & View.

- **Data** (`ActionWheels.gd`): `wheels` (id, title, trigger, slots 4..12, anchor), `uncovered()` (Flight actions with no pad
  button/axis and in no slot; the defaults leave it empty), slot angle math (slot 0 on top, clockwise), persistence in
  `settings.cfg [wheels]` (only customised wheels + `pause`; `Prefs.load_all/save`).
- **Tap vs hold**: `Controls.register` strips each trigger button off the Flight-group actions (`Controls.wheel_triggers`, recorded
  in `Controls.wheel_taps`); `ActionWheel.gd` owns the button. Release < 0.22 s without the stick = tap, fired with
  `Input.action_press` and released next frame (node priority -100, so Main's `is_action_just_pressed` sees it once);
  held, or the right stick pushed past 0.5 after the press = open. B cancels (Main keeps `fire_secondary` suppressed),
  self-destruct latches until any pad press. Map zoom (LB/RB) and docked `shop_sell_qty` are untouched (not Flight group);
  `map_close` gained Back so it still closes the map.
- **Main hooks**: `_wheel = ActionWheel.new()` in `_ready` (+ three Callables, `fired`/`cancelled` signals); in `_process` `_wheel.live`
  is cleared at the top and set right after `_cursor_state(true)`; `_wheel.pausing()` returns early like the map does (sim
  stopped, wheel keeps running), and an open wheel suspends right-stick aim.
- **Escort groups**: while the Escort Commands panel is up, the wheel containing `escort_panel` becomes `ESCORT_WHEEL`
  (groups 1-5 + panel), which is how a pad picks a group.
- **Editor**: Controls Editor tab "Action Wheels" (`screens/controls_editor/WheelsPage.gd`).
- Check: `tests/action_wheel_selfcheck.gd`.

### Flight travel (selected stellar · landing clearance · gates · escorts across jumps)

NovaWorld's `// MARK: Flight travel` (state in `Flight.swift`) mirrors what the Apple
`GameScene`/`GameContainerView` do around the travel channel, all on shared code:

- **Keys** (Controls.gd) are the original's table; `Controls.layout` ("original" default,
  "modern" = `modernKeyBindings`) is Settings → Controls. Chorded pairs (R/Alt-R, N/Alt-N,
  `/Shift-`/Alt-`, W/Alt-W, Y/Alt-Y) are tested chord-first because Godot also matches the
  plain key. Targeting calls the original's `World.cyclePlayerTarget` /
  `selectNearestEngaged` / `selectNearestHostileThreat` (snd 152/153 from the bridge).
- **Selected stellar**: 1–4 (`select_nav_stellar`), N clears, a new selection disarms the
  armed jump and H re-arms it (`StarMapRoute.selectHyperspace`), the Nav panel readout
  (`nav_readout`: STR# 2002 #342–346), a bracket on the selected body. Hail-stellar and Land
  use it. When nothing is selected, Land falls back to the nearest body the Swift helper treats as approachable. That pick is `PlayerLanding.nearestTravelStellar` (UI-06): WRITTEN, NOT BUILT (2026-10-13), 16 nav slots and a 500 px gate radius as in the original.
- **Landing** (`press_land`, UI-08): the Godot path calls the same helpers as the Apple app. First press requests through `LandedServices.landingClearance` / `refusalMessage`, then the clearance line on reaching ±250 px; second press lands inside the square envelope (`PlayerLanding`). The fee is charged on touchdown. The fixes that bring those helpers in line with the executable are WRITTEN, NOT BUILT (2026-10-13): the clearance ladder and the fee also cover hypergates and wormholes (EC-04, EC-05), and a paid bribe is one approach, not a lasting permit (EC-25; the waiver applies to a selected hypergate). `FlightComm.bribeWaiverStellar` is the Swift value the helper reads (it replaces `bribedStellars`).
- **Gates** (`press_land` on a gate): a wormhole draws its exit with `NovaGame.wormholeExit` (OS-06); a hypergate goes through `LandedServices.landingClearance`, the fee is charged by `chargeGateFee` before the map opens (EC-04, EC-05, EC-25), then the map opens in gate mode. These replace `wormholeExitCandidates` and `SpobRes.playerMayUseGate`; WRITTEN, NOT BUILT (2026-10-13). Arrival routing after a hypergate the pilot is allowed to use still follows the shared gate path: no fuel, no days, the far gate emits the ship on its emergence angle (`World.placePlayerEmergingFromGate`) with the wing coming out of it.
- **Map**: nebula art (`nav_nebulae` + `pict_rgba`, active explored ones, additive), Find
  (`nav_find` = `StarMapFind`), gate spokes (opt-in), `nav_map_closed` re-syncs the route.
- **Escorts across jumps**: `FlightEscorts.carryThroughJump` / `respawn` — disabled escorts
  are lost, the rest keep shields/armor/fuel/ammo and drop in behind their slot (about 892 px,
  or out of the gate); a launch refills them. Freighters share cargo on loss/drop.
- **NPC death sounds**: `DeathBurstSounds` — nine bursts 0.2 s apart (jittered ±22 px) plus
  the final blast, each the bööm's sound (`GameScene.beginNPCDeathSequence`). The visual
  bursts are still the single generic dying/destroyed effect.

Headless check: `godot/tests/fidelity_selfcheck.gd`.

## Cross-platform status of the core

An audit of `NovaSwiftKit` + `NovaSwiftEngine` (the two libraries the bridge
needs) found the core almost entirely portable:

- ✅ `NovaSwiftEngine` — no Apple-framework imports at all. Pure Swift +
  Foundation + Dispatch (all available on Linux/Windows).
- ✅ `NovaSwiftKit/SpriteSheet+Image.swift` — already `#if
  canImport(CoreGraphics)`-guarded; the CGImage helpers simply compile out
  off-Apple (Godot decodes sprites its own way).
- ✅ `NovaSwiftKit/ColorModels.swift` — **fixed**: was an unconditional
  `import CoreGraphics` for `CGPoint`; now imports Foundation (which provides
  `CGPoint` on Linux/Windows) with CoreGraphics guarded.
- ✅ `NovaSwiftKit/SpriteDiskCache.swift` — **fixed**, and this was the one that
  mattered. The decoded-sprite cache compressed its records with
  `NSData.compressed(using: .lzfse)`, which exists only where Apple's Compression
  framework does — `swift-corelibs-foundation` has no such member. It failed
  *every* Linux and Windows CI job, in `NovaSwiftKit`, which the bridge builds
  before it ever reaches `NovaSwiftEngine`: the Godot layer could not be compiled
  off Apple at all, and the workflow was demoted to manual-only rather than stay
  permanently red. The record header's version byte now doubles as a codec tag —
  `0x01` LZFSE, `0x02` raw — so Apple keeps the compression and other platforms
  store the surface uncompressed. Both are readable on Apple; off Apple an LZFSE
  record is treated as a cache miss and re-decoded, which only comes up if a
  cache directory is carried between platforms.

This is exactly the class of gap the audit's "almost entirely portable" verdict
couldn't catch by reading imports: nothing about `import Foundation` says which
half of Foundation you get. CI is the mechanism, and it only works while it's
allowed to run — the workflow is back on push/PR now that it can pass.

## Build & CI

- `scripts/build-gdextension.sh` — builds the `NovaSwiftGodot` dynamic library
  for the host platform and copies it into `godot/bin/`.
- `.github/workflows/godot-linux-windows.yml` — a reference workflow that compiles the core + bridge on
  Linux and Windows. It is **not used**: no pushes or dispatches, no CI builds. Packages are built locally
  (see [`PACKAGING.md`](PACKAGING.md)).

Godot **export templates** turn `godot/` + the platform library into shippable
`.x86_64` (Linux) and `.exe` (Windows) builds; wiring the export presets into CD
is described in [`PACKAGING.md`](PACKAGING.md) (presets, `scripts/package-macos.sh`,
`scripts/package-linux-docker.sh`, `scripts/package-windows.ps1`, Steam Deck setup). The in-game auto-updater
(`godot/updater/`, signed releases, stable and experimental channels) is in [`UPDATER.md`](UPDATER.md); it is built
and not yet tested end to end.

## Milestones

1. **Foundation + slice** — bridge target, `NovaWorld`, demo world, flyable
   slice, build script, CI. ✅
2. **Real data path** — sprite upload from `NovaSwiftKit` decode into Godot
   textures; render real ships/planets from the player's data via `make_world`.
   ✅ *confirmed on-toolchain (macOS).*
3. **HUD & flight** — radar, status bar, target lock, weapons firing/FX, sound
   from `drain_events`. ✅ *radar (ships and stellars), status bars, target
   panel, weapon readout, message log; and the whole combat entity set now
   renders — projectiles with their real `wëap` `spïn` art (rotation sheets
   indexed by heading, spinning strips animated), beams as a core→corona
   gradient, `röid` rocks, `bööm` explosion animations, impact sparks and
   asteroid debris, engine-glow exhaust, the cloak dissolve, the ionization
   tint, and the system's own `sÿst.BkgndColor`.* **Sound works**
   (`NovaWorld`'s "Audio" section, `godot/audio/GameAudio.gd`): `sound_info`/
   `sound_pcm` hand over the decoded `snd ` as 16-bit mono PCM (cached as an
   `AudioStreamWAV` per id); the event → sound table (weapon fire per wëap
   rules, bööm explosions, cloak, docking, chatter, Warp up/out, Red Alert,
   Klaxxon, the interface beeps) is the shared `SoundCues`, and the original's
   16-voice list (priority ranking, 8 audible, stacking guards, the 200 px /
   850²/d² distance law, mono) is the shared `SoundVoiceBoard` — a separate
   `drain_sound_cues` returns per-voice commands for 16 `AudioStreamPlayer`s, so
   `drain_events`/`drain_effects` are untouched. Beeps play on the pilot menu and
   galaxy map (title-menu music and the rest of the sound pass came later; see
   "Sound sites" in GODOT_FIDELITY_GAPS.md). Headless check: `godot/tests/audio_selfcheck.gd`.
   The staggered NPC death-burst sounds are in (`DeathBurstSounds`). Not yet: a
   volume UI (`GameAudio.master_volume`/`sfx_volume`/`ui_volume` exist), beeps
   on the flight target keys, and the Apple app still keeps its own copy of the
   event table in `GameScene`.
4. **Screens** — galaxy map, landing, spaceport (trade/outfit/shipyard), pilot
   save/load — GDScript `Control` UI over the same engine/story calls the Apple
   app makes. **Landing/launch done and confirmed on-toolchain** (`canLandNow`/
   `nearestLandableSpobID`/`attemptLand`/`launch`, mirroring
   `GameScene.updateLanding`/`reloadForDeparture`). The architecture gap that
   used to block this is **resolved**: the transaction math (`buyCargo`,
   `sellCargo`, `cargoFree`, outfit/ship pricing) was extracted out of the
   Apple-only `PilotStore` into the portable `PilotEconomy`
   (`Sources/NovaSwiftStory/PilotEconomy.swift`), so `PilotStore` is now a thin
   `ObservableObject` wrapper and the bridge calls the same code rather than
   reimplementing it. **The spaceport works** (`godot/screens/Spaceport.gd`
   over NovaWorld's "Spaceport (outfitter/shipyard)" section): the landing screen
   (the spöb's landing PICT — decoded portably by `PICT.decode`, with the PICT-id
   rules in `NovaGame.landscapePictID`/`outfitPictID`/`shipPictID` — its `dësc`
   text, and only the services its flags offer), Trade Center (`tradeRows`:
   reputation/domination scale, disasters, junk rows; click = 10 t, typed
   quantity prompt), Outfitter and Shipyard (+ Ship Info), Recharge, Leave. The
   rule decisions the Apple views used to own — outfitter/shipyard stock, sell-only
   listings, Buy enablement, `LockState`, rank-scaled net price, refuel and the
   auto-refueller — moved into shared `SpaceportShops`/`ItemLocking`
   (`NovaSwiftStory`) and the Apple views now call them. Fuel is now the pilot's
   real tank across land/launch (refuelling is paid), and a visit's days
   (+1 launch, +1 outfitter trade, +4 ship purchase) tick on launch. Bar, Mission BBS and escort hiring are in the story runtime below. **Galaxy map + hyperjump work** (`NovaWorld`'s
   "Navigation & hyperjump" section, `godot/screens/GalaxyMap.gd`,
   `HyperjumpFx.gd`, `NavScreens.gd`): fog-of-war systems coloured by
   government, links, the original's click/Shift+click route rules (plus the
   opt-in auto-route enhancement), fuel/multi-jump from `PilotEconomy`, and the
   engine's own `PlayerHyperjump` maneuver followed by an in-place world rebuild
   that carries the player's ship (fuel/damage/cargo) and marks the destination
   explored. The portable pieces were lifted out of the Apple `NavigationModel`/
   `GameScene`/`GovernmentPalette` into `StarMapNavigator` (+ `World.
   hyperspaceRefusal`), `GovernmentMapPalette` and `HyperjumpCommit` (the pilot
   side of an arrival), which the Apple app now calls too. Gamepad: stick cursor
   with snapping, D-pad next-system, A plot, Y add hop, B close. Nebula art, Find,
   the hypergate picker, opt-in gate spokes and escorts following a jump (damage
   carried) are in — see "Flight travel". Not yet: the reduced-flashing option. **Pilot save/load works** (`NovaWorld`'s "Pilots & saves"
   section + `godot/screens/PilotMenu.gd`): the bridge reads and writes the very
   same `<uuid>.evpilot` files as the Apple app through `PilotArchive`, and the
   create/persist/prepare-for-play/migrate steps were lifted out of the Apple-only
   `PilotRoster`/`AppModel`/`PilotStore` into the portable `PilotSaves`
   (`Sources/NovaSwiftStory/PilotSaves.swift`; `PilotNames` moved alongside). A
   startup screen lists pilots, creates one from a `chär` scenario (name via
   keyboard or the dice button), loads or deletes (with confirm), fully on
   keyboard and gamepad via Godot focus navigation. Saves follow the original's
   cadence (`PilotSaveReason`): on creation and on launch (docked at that
   stellar, so a reload lifts off from it) and on quit; the in-flight
   `frequentAutosave` enhancement and Strict Play permadeath are not wired.
   `godot/tests/pilot_selfcheck.gd` exercises create → save → list → load →
   delete headlessly.
5. **Story runtime** — missions, crons and story text. ✅ *(except gambling, escort hiring and a few polish items below.)*
   `GodotGameServices` (`godot/bridge/.../Story.swift`) is the bridge's
   `GameServices` (the Apple `AppGameServices`); NovaWorld's "Story & missions"
   section builds `StoryEngine`s over the live pilot and marshals. Landing runs the
   engine's landing pass (cargo, completion text and pay, `OnSuccess` bits); launch
   ticks the visit's days with services attached (crons, tribute, deadlines), then
   the launch pass; a hyperjump arrival ticks its days and runs the flight pass.
   Offers: the main spaceport rolls one on landing, each shop on opening (and on
   the 30+Rand(30)-tick idle timer), the Bar on its patron timer, all through
   `nextLaneOffer`/`present`. Screens: **Mission BBS** and **Bar** (+ **Holovid**) in
   `Spaceport.gd`, modal story texts / offers and the **Player Info / Mission Info**
   window (P, I; pause menu) in `screens/StoryScreens.gd`. In flight, mission ships
   spawn through the shared `FlightMissions` (system match, ShipStart, aux budget),
   goal/loss/aux events and the fail-if-disabled/boarded flags feed the engine
   from `collectEvents`, escort/observe sightings run every 3 s, and a time limit
   fails on launch/arrival. The glue was lifted out of the Apple `GameContainerView`
   into `Sources/NovaSwiftStory/FlightMissions.swift` (+ `SpaceportStory`), which
   the Apple app now calls; `HyperjumpCommit.apply` takes optional services.
   Headless checks: `tests/story_selfcheck.gd` (accept a BBS delivery, jump, land,
   pay + text, calendar advance) and `tests/story_menu_check.gd` (offer modal
   owns input, BBS/bar/info focus). Gambling, hire escort, jettison and in-flight `pêrs` offers are wired through the same helpers as the Apple app. The gambling reset fix (the previous winner resets when the bar opens, `barOpened`) is WRITTEN, NOT BUILT (EC-26, 2026-10-13). The outfitter bank promotion and visit-scoped items (`outfitterOpen` / `outfitterClose`, EC-09, EC-28) are likewise WRITTEN, NOT BUILT. Mission-offer `dësc` movies are wired (see "Total-conversion add-ons").
6. **Packaging** — Godot export presets and local package scripts: macOS arm64 and Linux x86_64 built and verified headless; Windows script written, not run; auto-updater built, not tested end to end.

## Non-goals

- Not replacing the Apple frontend. `app/NovaSwift/` stays the shipping build for
  macOS/iPadOS/iOS; this is a parallel desktop frontend.
- Not forking the engine. The Swift core is the single source of truth; the Godot
  layer only renders and drives it.
- Still BYO-data. The Godot build reads the player's own EV Nova data exactly
  like every other NOVA Swift build; no game content is bundled.


## App shell (main menu, settings, pause, data setup)

`godot/screens/Shell.gd` owns the screens around the game and the flow between
them; `Main.gd` only asks `in_menu()` / `is_paused()` and reacts to
`pilot_chosen`. Flow: **no data** -> `DataSetup` wizard (the only screen; Quit + Settings; see
"Game data import" below) -> **main menu** -> `PilotMenu`
(New / Open, Back returns to the menu). **Pause** (`pause_menu` action: Esc / pad
Start, polled by Main only in plain flight, so the map, dialogs and docked UI keep
Esc/B) offers Resume, Settings, Save & Quit to Menu (`pilot_save_now`) and Quit
(`pilot_autosave`). Original fidelity: no hover sounds; confirm beep snd 150 only.

- **Settings** persist in `user://settings.cfg` via `Prefs.gd` (`[audio]`,
  `[video]`, `[input] deadzone`, `[data] dir/recent/import_plugins`, `[pilots]`, `[classic]`, `[keys]` rebinds). Volumes go into
  `GameAudio`'s existing `master/sfx/ui/muted`; `Controls.stick_deadzone` is the
  runtime dead zone; rebinds live in `Controls.overrides`, which `Controls.register()`
  layers over `BINDINGS` (so startup is `Prefs.load_all()` then `register()`).
  Rebinding captures the next key / pad button; a binding held by another action
  in the same group (Flight / Docked / Galaxy map) is swapped, as the Apple
  `PadBindings` does. Analog axes are fixed.
- **Title music**: the bridge exposes `title_music_name()` (STR# 130 #2); the
  frontend searches `Nova Plug-ins` then `Nova Files` for the bare name, `.mov`,
  `.mp3` (the order of `OriginalAudio.musicCandidates`) and plays an `.mp3` with
  `AudioStreamMP3` over the main menu only. `.mov` or no file = silence.
- **Display**: stretch aspect is `expand` so a 1280x800 Steam Deck screen gets the
  extra height instead of bars (the HUD and screens lay out from the viewport rect).
- Not done: game speed (`GameSpeedRules` is not bridged), About, the
  authentic (cölr/PICT) main menu art, per-pad glyph names beyond Xbox layout.

## Classic UI kit (`godot/ui/classic/`)

The Apple app renders the *authentic* EV Nova UI from the player's own data
(DLOG/DITL layouts, dialog PICT frames, three-state button art, `cölr` colours,
the `ïntf` status bar). The Godot screens used to be plain Controls; this kit is
the Godot side of the same thing. **Presentation setting** (`Prefs`
`[presentation]`, Settings > Presentation, mirrors Apple `GameSettings`):
`modern_menu` / `modern_dialogs` / `modern_hud`, all **false = Classic (default)**,
all true = Nova Swift. `Prefs.ui_mode()` / `apply_ui_mode()` give the preset;
`ClassicTheme.classic("dialogs"|"hud"|"menu")` is the one test a screen makes
("data loaded and that flag off"). The existing plain screens stay as the Nova
Swift option; a reskinned screen builds the Classic version when `classic(...)`
is true and keeps its old code path otherwise (see `screens/PauseMenu.gd`, the
worked example).

### Files

| File | Role |
|---|---|
| `ClassicTheme.gd` | static asset cache + look: `setup(nova)`, `pict(id)` -> Texture2D, `button_texture(width, state)`, `button_height()`, `palette()` / `color(key)` (cölr), `font_for("Charcoal"/"Geneva")`, `body_font()` (Arimo) / `chrome_font()` (Rubik), `string_at(strN, index1, fallback)`, `classic(kind)`, `FOCUS` colour |
| `ClassicButton.gd` | `ClassicButton.make(label, width, style)` -> TextureButton: real 3-state art (PICT 7500+3s / masks 7600+3s), cölr label font/colours, `^ & + -` vector glyphs, amber focus outline, `refused` signal on a greyed press, `text` alias. `Style.NATIVE` = the bevelled grey prompt button, `Style.CHECK` = X check box |
| `ClassicDialog.gd` | a DLOG/DITL dialog as a Control (below) |
| `AuthenticHUD.gd` | the `ïntf` status bar (below) |
| `fonts/` | Arimo + Rubik (SIL OFL, same files as `app/NovaSwift/Resources/Fonts`) as stand-ins for Geneva/Chicago and Charcoal, as in the Apple app |

### `ClassicDialog`

Preload it (`const ClassicDialog = preload("res://ui/classic/ClassicDialog.gd")`;
no `class_name`, like `Controls.gd`). Item indices are 0-based DITL indices, the
way the game and the Apple app address them.

```gdscript
# 1. any DLOG/DITL id; bind behaviour by index
var d = ClassicDialog.from_ditl(nova, 1011, {
    "frame_pict": 8531,                    # backdrop PICT: window = PICT size, art buttons
    "labels":  {0: "Done"},                # button / checkbox labels
    "texts":   {4: "Hello"},               # static text / edit initial text
    "actions": {0: func(): done()},        # buttons + clickable pictures
    "disabled": [2], "hidden": [5],
    "default_item": 0, "cancel_item": 3,   # Return / Esc, pad A.. / pad B
    "custom": {1: func(parent, rect): ...} # user items: build your own Control at rect
})
# 2. the original's two prompts (native white window, bevelled buttons)
ClassicDialog.confirm(nova, "Quit?")                   # DLOG 3002: OK=item 0, Cancel=item 4
ClassicDialog.text_prompt(nova, "Name?", "Ace")        # DLOG 3001: edit=item 4; edit_text(); prompt_answer()
# 3. the app's own dësc-frame dialog (8524/8525/8526) with art buttons
ClassicDialog.panel(nova, {"title": "Paused", "body_buttons": [{"label": "Resume", "action": cb}],
                           "footer_buttons": [{"label": "OK", "default": true}]})
ClassicDialog.modal(layer, d, 0.55)    # dim scrim + input block; d.close() frees it
```

Signals: `activated(index)`, `accepted` (default item), `cancelled` (cancel item).
Accessors: `item(index)`, `set_text`, `edit_text`, `focus_first()`, `fit()`; `add_button /
add_check / add_label / add_edit / add_picture(rect, index)` for hand-built layouts on
top of any chrome (`Chrome.NATIVE / PICT / PANEL / NONE`).

* **Scaling.** The Control is the window in 1:1 original pixels; `fit()` (run on
  ready and on viewport resize) scales it by `nova.classic_crisp_scale` (fit the
  viewport, never below 1x, capped 3x, **snapped down to 0.5 steps**) and centres on an
  integer pixel. The root is `TEXTURE_FILTER_NEAREST`, so PICTs stay sharp on 1280x720 and
  1280x800. Pass `"fit": false` to scale it yourself (e.g. inside a spaceport frame).
* **Focus.** Every button/edit gets `focus_neighbor_*` from DITL geometry
  (`classic_focus_neighbours`: nearest rect in each direction), the default item takes
  initial focus, and `ui_accept` presses the focused ClassicButton (Godot). `ui_cancel`
  activates the cancel item. The focus look is an amber outline + faint wash (art) or
  the dotted rect (native) -- visible with keyboard/pad, hidden after a mouse click.
* Items parked outside the window (the DITLs do this) are skipped, as the original does.
  Beep: a button press plays snd 150 via `nova.sound_beep(1)`.

### `AuthenticHUD`

`AuthenticHUD.new()` + `setup(nova)` -> full-rect, mouse-transparent Control; reads the
bridge every frame; `active` (Callable -> bool) hides it in menus/landed. Backdrop PICT
(700 in the base data, per-government `ïntf` via `classic_interface_id(ship_type)`)
anchored right and scaled to the viewport height; shield/armor/fuel bars at the exact
`ïntf` rects/colours (jump-metered fuel, `classic_fuel_bar`); radar (stellar rings, ship dots,
target blinks BrightRadar, player arrow); target name + shield/armor, secondary weapon +
ammo, nav readout (STR# 2002 text via `nav_readout`), cargo free + credits (`creditsHUD`
formatting), all in the `ïntf` font and bright/dim colours. `Main.gd` creates it
(`_sync_classic_hud`, a CanvasLayer at layer 5) when `classic("hud")` and skips its
primitive status bars / weapon / target / nav / radar; the land prompt and message log stay.
Also drawn (bridge `hud_target_info` / `hud_cargo_panel` / `hud_has_iff` / `ship_iff_classes` /
`radar_static_chance`, mirroring Apple `AuthenticHUDView`): the target's red silhouette (a
grey x tint shader on frame 0 of its hull), shïp subtitle, the status row (Shield: N % / Shields Down /
Disabled) with the govt TargetCode, IFF radar colours when an IFF outfit is fitted (grey / red /
green / blue, cyan player, black-filled scope), per-commodity cargo rows + Special, and radar
static. `bar_width(vp)` is the width the bar reserves; Main.gd centres the flight world in the
play area to its left (`_play_center`, also used for click-to-select and the land prompt), and the
message log / land prompt use the ïntf font and bright colour.
Classic also draws the original's ambient starfield (`Main._draw_original_stars`: <= 20 spïn-700 star
sprites, `star_count`, drift factor `star_factor`, wrapped across the view, `star_tint(system_murk())`,
hidden while murk < 0); Nova Swift keeps the plain dot field.

Murk (F1, `flight/`): every sprite Apple fogs is fogged by `MurkFog.level / 32` toward `sÿst.BkgndColor` through the `fill` layers:
stellars (`stellar_states` column 2), ship hulls (`ship_layers` 14/15, one blend slot shared with ionize and the gate wash) and,
since 2026-10-13, shots with their own art (bridge `projectile_fog()`, `FlightRenderer.fog_shots`, the `fill` layer after the shots
layer). The generic bolt, asteroids, cargo and effects are unfogged, as in Apple. Hyperspace warp-in and warp-out draw nothing
(Apple `applyEntrance(.warpIn)` / `warpOutNode`); only the gate fade (columns 19 / 20) and the launch / landing animations exist.
Test: `tests/murk_warp_selfcheck.gd`.

Title music named as a `.mov` (C5): `Movies.transcode_audio` / `convert_audio_async` / `audio_ready` pull the first audio track into
a cached WAV with ffmpeg and `TitleMusic` plays it once ready (silent without ffmpeg). The `playMovies` pref gates every movie path
(E3, `tests/play_movies_gate_selfcheck.gd`). S26: J refused while "Automatic route plotting" is on opens the map silently
(`NavScreens.engage_hyperjump`, `GalaxyMap.open(true)`).

### Main menu, pilot dialogs, galaxy map (Classic reskins)

* **Main menu** -- `ui/classic/ClassicMainMenu.gd` (a port of `AuthenticMainMenuView`): PICT 8000, logo
  (spïn 606), three shutter strips (608-610, snd 602/603), the six real buttons (spïn 600-605 at the
  cölr #128 positions; keys N O Q E P A; snd 600/601), rollover icon (spïn 607) and the pilot readout
  (shared `MainMenuReadout` via `classic_menu_readout`, targeting PICT added). Shown by `MainMenu.gd`
  when `classic("menu")`; Preferences emits `settings` -> NovaSwift's own Settings screen. "Game
  Data..." is a port-only button at the bottom-left. Native-size 1024x768 canvas, centred, no fill-scale.
  Bridge: `classic_main_menu`, `classic_spin_info/_tile_rgba`, `classic_menu_readout`, `sound_menu`,
  `classic_desc_text`. Not done: the "has been killed" / "Creating Pilot..." readout states.
* **Pilot dialogs** (see "Pilots as files" below for Open Pilot) -- `PilotMenu.gd` classic path (`over_menu` keeps the menu visible behind): New Pilot =
  DLOG/DITL 3102 (3101 with several scenarios) with gender / scenario as cycling buttons and Strict
  Play; a port-only **Random** button beside the gender control keeps name entry pad-friendly; OK
  asks the ship name in DLOG/DITL 3001 (`pilot_ship_name_prompt`, `pilot_create_strict`). Open Pilot is a file
  open (picker + compact recent list, below); delete = DLOG 3002 under Manage.
  `ClassicDialog.add_cycle` is the new pop-up stand-in.
* **Galaxy map** -- `GalaxyMap.gd` draws inside DLOG 2000 on PICT 8509 (item 2 = starmap, 5 = side panel,
  1 = status bar, buttons Done / Clear Route / Find / - / +, zoom 0.5..2.0 by 3/4) unless
  `Prefs presentation/fullscreen_galaxy_map` (Settings > Presentation; Classic = off, Enhanced =
  Classic + on, Nova Swift = on; `Prefs.UI_ENHANCED`, `Prefs.fullscreen_map()`). Text from
  `classic_map_info`. Frame buttons are pointer-only (pad A plots). Not done: Show/Hide Borders.
* A greyed `ClassicDialog` button press beeps snd 153 (`refused`).
* Test: `godot/tests/classic_reskin_selfcheck.gd` (also writes PNG previews).

### Pilots as files, Settings like Apple, the loading screen

**Pilots as files.** A pilot is a real `<uuid>.evpilot` (the Apple `PilotArchive` format, with its rotating
`Backups/` beside it) in a visible **Pilots folder** -- no hidden `user://` store. `screens/PilotFiles.gd`
resolves it: `$NOVA_PILOTS_DIR` (tests/portable) > Settings > Data & Advanced > Saved Games override
(`Prefs [pilots] dir`, changing it copies the pilots across, originals stay) > default
`<Documents>/NovaSwift/Pilots` (Windows `%USERPROFILE%\Documents`, macOS `~/Documents`, Linux/Steam Deck the
XDG documents dir, usually `~/Documents`) > `~/.local/share/NovaSwift/Pilots` when Documents is unwritable >
`user://pilots`. Documents rather than "next to the EV Nova data" because the data folder is frequently a
read-only or repo-internal copy. **Migration:** the first start copies `user://pilots` into the Pilots folder
(copy, originals kept; `Prefs [pilots] migrated`). `Shell.pilot_dir()` is the one place the folder is read.

**Open Pilot** (`PilotMenu.gd`, Classic and plain): "Choose Pilot File..." runs the OS file picker
(`PilotFiles.pick_file`, `FileDialog.use_native_dialog`, filters `.evpilot` + `.plt` + all) starting in the Pilots
folder; under it a compact recent list (`PilotFiles.recent_rows`: files opened lately, topped up with the newest
in the folder, one row per pilot; `Prefs [pilots] recent`), then New Pilot and **Manage** (the old per-pilot
Play/Delete list of the folder). `open_path(path)`: an `.evpilot` from anywhere is copied into the folder when
it is not already there (a newer copy already there wins) and loaded; an original EV Nova pilot (`.plt`,
MacBinary/AppleDouble/resource fork) shows a summary (`import_preview`, Apple's PilotImportView) and
`import_commit` saves it as "Imported from EV Nova" and plays it. **Gamepad:** the native picker cannot be
driven by a pad, so `PilotFiles.want_native()` is false (Godot's focus-navigable FileDialog is used) when a
pad is connected and navigation input is live (`ClassicTheme.nav_active`, which keyboard arrows also set) or on
Steam Deck game mode (`SteamDeck=1`, `SteamGamepadUI`, gamescope), and when the platform has no native dialogs.
Bridge (`// MARK: Pilot files`, logic in `PilotFiles.swift`): `pilot_file_path`, `pilot_inspect_file` (kind
evpilot/original/unknown), `pilot_open_file(dir, path)`, `pilot_import_preview(path)`, `pilot_import_commit(dir)`.
Tests: `tests/pilot_files_selfcheck.gd` (a synthetic `.plt` is built in GDScript; there is no on-disk fixture).

**Settings like Apple** (`Settings.gd`): amber title card, category sidebar (Interface = page "Presentation",
Controls, Graphics = "Video", Audio, Data & Advanced = "Support") with a pinned "Reset All Settings" (second
press confirms; a pad cannot answer a dialog), grouped sections (amber header, dark rounded group, muted
footer), amber check boxes and amber-track sliders (`ShellUI._style_controls`, so every shell screen shares
them), "title ... 70%" slider rows. Focus entering a sidebar entry shows its page; Right enters the page, Up/Left
from its first control returns. Data & Advanced holds Saved Games (shows the Pilots folder; Open, Change...,
Use the Default) above the Support/Developer block. **Original Preferences Window...** (Interface page, needs
game data) opens `screens/ClassicPreferences.gd`: DLOG/DITL 4003 through `ClassicDialog.from_ditl`, wired to
`Prefs [classic]` (Apple defaults: volume 5, brightness 3, all on but update checks). Live effects: the volume
arrows are the master volume in 1/8 steps (snd 154), Intro Music gates the title music; the other flags are stored
only (the Godot renderer has no counterpart yet). Key Settings opens the original's key table
(`screens/ClassicKeySettings.gd`, DLOG/DITL 4002 over backdrop PICT 139/133; WRITTEN, NOT BUILT): 34 cells = DITL items 4-37
in the Apple cell order (`ClassicKeySettings.CELLS`), a click selects, the next key press binds that cell's `Controls` action
(plain key, Alt chord, Shift chord or a bare modifier, written to `Controls.overrides`) and the selection steps on; duplicates are
allowed while editing and OK is refused with the first clashing cell outlined red; Cancel / Esc restores the overrides snapshot, Set
Default previews `overrides = {}`, 1-4, Caps Lock and F1-F5 are not capturable; OK saves (`Prefs.save()`) and re-registers the
InputMap. Cells for actions the port lacks (autopilot, two spares) stay blank; "More keys..." opens the NovaSwift Controls page.
The arrows are mouse-only (as in the original); pad players use the Audio sliders.

**Loading screen** (`screens/LoadingScreen.gd`, a port of Apple `LoadingView` + `Branding`): the launch key art
drifting behind seeded parallax stars (3 depths), the fire-lit gunmetal NOVA SWIFT wordmark with flickering
flames (`godot/assets/branding/`, copied from the app's asset catalog), corner brackets, phase / count / percent
readout, tips, and a bar that is the original's flat cölr ProgressBar in Classic and the amber segmented gauge in
Nova Swift. API on `Shell` (the plug-in reload and anything else can call it):

    Shell.show_loading("Reloading plug-ins")             # appears after 0.25 s if still wanted (no flash)
    Shell.show_loading("...", true)                      # immediate, for work known to be long
    Shell.set_loading_progress("Reading", 0.4, "3 / 7")  # real progress; without it the bar sweeps
    Shell.hide_loading()                                 # stays up >= 0.5 s once shown (no flicker)
    var ok = await Shell.load_data_async(dir)            # worker-thread data load with real phases

`load_data_async` uses the bridge's `load_game_async(dir)` / `load_status()` (`// MARK: Async data load`): the
merge runs on a worker thread, `load_status` returns JSON `{running, done, ok, phase, fraction}` and installs the
result on the main thread when it first sees `done` (call nothing else on the bridge in between). The
fraction is coarse (find files 0.04, read/merge 0.12, index 0.85) because `GameLibrary.merge` reports nothing
finer. `Main` boots with `Shell.start_async()` (`in_menu()` is true meanwhile); `start()` stays synchronous for
tests. A main-thread operation cannot animate the screen: pilot load and `make_world` take a few ms and do not
show it. Not verified visually (no windowed run).

### Bridge (`// MARK: Classic UI` in `NovaWorld.swift`, logic in `ClassicUI.swift`)

`classic_dialog(id)` -> JSON `{w,h,designW,designH,title,focus,items:[{i,kind,l,t,r,b,text,res,enabled}]}`
(kind: button/checkbox/static/edit/picture/icon/control/user) or `{}` ·
`classic_focus_neighbours(rects[l,t,r,b..])` -> `[up,down,left,right]` per rect ·
`classic_crisp_scale(frameW, frameH, viewW, viewH)` · `classic_button_height()` ·
`classic_button_rgba(width, state 0/1/2)` (composed art, no label) · `classic_colors()` (cölr JSON) ·
`classic_interface_id(ship_type)` · `classic_interface(id)` (ïntf JSON: bg PICT/size, rects `[l,t,r,b]`,
colours, fonts) · `classic_strings(id)` (STR#) · `classic_has_pict(id)` · `classic_bar_segment(l,t,w,h,a,b)` ·
`classic_fuel_bar()`. PICT pixels: the existing `pict_info` / `pict_rgba`.

### Shared code (`Sources/NovaSwiftKit/ClassicUIGeometry.swift`)

Foundation-only geometry/raster lifted out of the SwiftUI-only app code (the Apple app still has its own copies;
rewire later): `crispScale`, `centredOrigin`, `barSegment`, `fuelSplit`, `focusNeighbours`, and
`ThreeStateButtonRaster` (mask + compose the three slices into one RGBA button). Tests:
`Tests/NovaSwiftKitTests/ClassicUIGeometryTests.swift`. DLOG/DITL decoding, `ColrRes`, `IntfRes`,
`ThreeStateButton` were already portable.

### Recipe for reskinning a screen

1. `if ClassicTheme.classic("dialogs"):` build with `ClassicDialog` (or `from_ditl` + `frame_pict` for a
   spaceport frame, hand-placing live widgets via `custom` / `add_*`); else the old code.
2. Keep the screen's public signals/fields; ClassicButton is a `TextureButton` (not `Button`) --
   use `BaseButton` in type checks. It exposes `.text`.
3. Verify with `godot/tests/classic_ui_selfcheck.gd` as a model (headless renders nothing, so the test
   composes PNGs from the real PICTs/art with `Image.blend_rect`).

Test: `NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/classic_ui_selfcheck.gd`.

### Classic spaceport, comm and story screens

With Presentation > Dialogs on Classic (default) the docked / comm / story screens are the original DLOG/DITL
dialogs on their frame PICTs, mirroring the Apple app; "Nova Swift" keeps the old plain screens (same code, same
signals). Kit helper: `ui/classic/ClassicScreen.gd` (DITL rect lookup with stock fallback, text / scroll / picture /
flat focus rows, and the 4x5 `ItemGrid` of 83x54 tiles with row scrolling and d-pad navigation). Frames draw at their
native size at the shared crisp scale (windows stack over the hub, nothing is fitted to the screen).

| Screen | File | Frame PICT / DITL |
|---|---|---|
| Landing, Trade, Outfitter, Shipyard, Ship Info, quantity prompt, Bar, Holovid, Mission BBS | `screens/SpaceportClassic.gd` (dispatched from `Spaceport.gd`) | 8500/1000, 8510/1001, 8502/1002, 8501/1004, 8507+8506/1019+1005, native 172x72, 8503/1013, news PICT, 8505/1006 |
| Hire Escort, Gamble (choose + result) | `screens/BarScreens.gd` | 8501/1004, 8529/1023, 1015 |
| Hail (ship/planet), haggle, Plunder, capture + name prompts, Escorts window, Escort Commands panel | `screens/Interactions.gd` | 8511/1007, 8512/1009, 8514/1008, 8515/1011, DLOG 3002 / 3001, 8513/1022 |
| Story text, mission offer, Player Info, Mission Info | `screens/StoryScreens.gd` | 3003/3004 on 8524-8527, 8521-8523/1016, 8518-8520/1017, 8517/1012 |

Window stack in the spaceport: hub < one service window (scrim) < overlay (prompt, ship info, hire, gamble); only the top one
is focusable (`ClassicScreen.set_enabled`). Classic differences from the plain screens: a trade row / grid tile press selects (and
moves focus to Buy), the Buy / Sell buttons transact; Alt- or right-click on Buy / Sell (or Q / E) opens the quantity prompt;
Player Info has the original 4 tabs and Mission Info is its own dialog. Test: `tests/classic_spaceport_selfcheck.gd` (composes
PNG previews through `tests/UiCompose.gd`); `spaceport_menu_check` / `story_menu_check` take `NOVA_UI=modern` for the plain path.

### UI polish (focus, lists, messages, dësc dialog, Classic map)

* **No focus or hover outline.** The original has none, so the kit draws focus indication only while the last input
  was keyboard navigation or a gamepad (`ClassicTheme.nav_active`, fed by a `NavTracker` node under the tree root; any
  mouse / touch event clears it, a `ui_*` key or pad input sets it; `ClassicTheme.show_focus(control)`). It mirrors the
  Apple controller cursor's target treatment: an ART `ClassicButton` grows 1.07x (CursorClickable hover-grow), NATIVE
  and CHECK buttons get the original's dotted default ring, list `Row`s show the cölr `listHilite`, grid tiles use
  their gridBright selection box, the main menu shows its highlighted art frame, edit fields rely on the caret. The
  `ShellUI` theme (Settings, pause, data setup) swaps its amber ring in and out with the same signal.
* **List highlight offset (root cause).** A `Control` clamps `size` to its minimum at assignment time, and with the
  default 16 px theme font that minimum is 23 px, so every 10-13 px label (list cells, grid captions, DITL static
  text) was 23 px tall with its text centred ~5 px below a 13 px highlight. Kit helpers now set the theme overrides
  first and `size` last (also deferred). `ClassicScreen.Row` is a `BaseButton` (a `Button`'s font-line minimum had
  stretched rows too).
* **Shrink-to-fit, never "...".** `ClassicTheme.fit_size/fit_label` (Apple `NovaText(shrinkToFit:)`: one line, down to
  50 % of nominal in whole pixels) is used for grid captions and list cells; classic labels no longer trim.
* **Status line.** `Main.gd` shows ONE line (a new message replaces the old) at the bottom-left, 16 px in and 8 px up,
  clipped at sidebar + 50 px, `.hud` face (the ïntf status font, semibold, 14 pt, white, black shadow), 5 s with a
  0.6 s fade; the land prompt is centred over the play area on the same baseline, one line higher while a message is
  up (Apple `MessageLogView` / `ContextualActionsView`). The texts are the bridge's (`polishNote`: STR# 2002 #287
  disabled, #288 ship destroyed, #37 repair, #127/#128/#129 escorts, #374 stolen; "You are being scanned.";
  overlay messages). The Apple app narrates nothing for a target dying, docking or launching, so those invented lines
  are gone; the cannot-jump lines (#42, #36, #30, #31) arrive through the same channel.
* **`ClassicDialog.desc_dialog(nova, text, graphic_id, opts)`.** The generic dësc reader: DITL 3003 on PICT
  8524/8525/8526 (3004 on 8527 with a picture), shrunk by the shared `DescDialogLayout.shrink`
  (`desc_dialog_shrink`), measured wrapped white 12 pt text in a clipped pane that scrolls (wheel, Up/Down, PgUp/PgDn,
  right stick), OK at item 0, `<REG>` and `\r` resolved by `desc_dialog_text`. About Nova passes
  `about_nova_text(version)` (NovaSwift header + dësc 32767; version from `application/config/version`).
  `d.get_meta("desc")` exposes shrink / text height / rects for tests.
* **Classic galaxy map** follows `GalaxyMapView.drawMap`'s non-fullscreen branch: black disc plus 1 px (2 px zoomed)
  ring in the `OriginalMapMarker` colour (new shared `Sources/NovaSwiftStory/OriginalMapMarker.swift`, bridge
  `nav_marker_colors`), cyan current-system dot, eight green corner strokes on the selection, Geneva-9 white labels at
  (x+7, y+4) for explored / charted systems when zoom >= 1/1.1, linkGrey 1 px links from visited systems, green armed
  link, 2 px green route, gate-picker barbs. No help line under the frame. (Show Borders, mission-target markers and
  the floatingMap frame border were ported afterwards: see "Galaxy map: borders, mission marks, Tab cycle" below.)
* **No invented transaction text** in the Classic spaceport (no "Bought 3 t of ...", refuel, hire or gamble feedback):
  counts, credits and button states only.
* Selfcheck: `godot/tests/ui_polish_selfcheck.gd` (also counts engine errors with an `OS.add_logger` logger).

### Galaxy map: borders, mission marks, Tab cycle, gate-entry movie (2026-10-13)

**Built and tested on macOS (2026-10-13)** (Godot and the matching Apple edits). The Tab / `\` map cycle is an inference: the original handlers are not decompiled on their own.

* **Show / Hide Borders** (D1): the original's political overlay, built by the shared `PoliticalOverlay`
  (`Sources/NovaSwiftKit/PoliticalOverlay.swift`; new `discs(...)`, `build(...)`, `allied`, `rgba(game:)`, so Apple and Godot use one
  rule set) behind bridge `nav_borders(canvas_w, canvas_h, px_per_unit, center_x, center_y) -> PackedByteArray` (RGBA8, 2 px cells,
  `canvas/2` cells per axis; empty when nothing is painted). `GalaxyMap.gd` draws it nearest-filtered at 2x on a layer between the
  nebulae and the canvas, rebuilt when the view changes. Toggle: the Classic frame's DITL 2000 item 8 button (label STR# 150 #56 / #57),
  or `B` (also in the plain / fullscreen map, which uses the same overlay rather than Apple's soft glow). Persisted in `[map] show_borders`.
* **Mission-target markers** (D2): bridge `nav_mission_targets()` (`StoryEngine.missionDestinations`) -> `[{system,x,y,vis,names}]`;
  cicn 15000 drawn 16 px up and left of the system (`cicn_info` / `cicn_rgba`), the orange arrow when the art is absent. A target in the
  fog (`vis` 0) is added to the map's system table, so it is drawn (dim, unnamed) and pickable, as the Classic map does (0x004a8100).
  The plain map also prints the mission names next to the arrow. Apple's destination *preview* marker (cicn 15001) is not ported.
* **Tab / `\` cycling** (D3): on the open map Tab and `\` (Shift reverses) step the armed hyperspace link through the current
  system's links and select it (`GalaxyMap.cycle_link` -> bridge `nav_cycle_link(forward) -> system id | -1`, the in-flight step plus
  `nav.selected`). Add-hop moved from Tab to `E` (pad Y unchanged). Apple: `GameContainerView.handleDiscrete` routes the cycle key
  and the target-next/previous keys to `nav.cycleHyperspaceLink` while the map is open.
* **Floating-map frame** (D4): the in-flight route mini map frame uses the cölr FloatingMap colour.
* **Hypergate / wormhole entry movie**: decompiled `Stellar_EnterHypergate` 0x00456480 and `Stellar_EnterWormhole` 0x00456ca0 both call
  `FUN_0049e3c0(ship+0x6c + 0x80)` (= `Ui_LoadSelectionDialogResource` then `Ui_PlayMovieFileModal` 0x0049db00 with the dësc Flags
  0x0002 double size / 0x0004 blank screen) when the movies preference (`DAT_005914d3`) is on. `ship+0x6c` is the travel selection, so
  the movie is the dësc with the id of the **destination sÿst** (hypergate, picked in the map) or of the **wormhole's own spöb**.
  It plays *before* the transport (hypergate: right after the map closes; wormhole: right after the exit was chosen), is modal and
  skippable, shows no text. Shared lookup `GateTravelMovie` / `NovaGame.gateTravelMovieDesc(selection:)`. Apple:
  `DescMoviePlayback.gateClip` + `GameContainerView.performGateJump(movieSelection:)` (overlay `gateMovie`). Godot:
  `DescMovie.lookup_gate` / `play_gate`, bridge `NovaPlugins.gate_movie(id)`; the hypergate picker (`GalaxyMap._pick_gate_destination`)
  plays it before `gate_picker_choose`; wormholes use `set_gate_transport_deferred(true)` (set by `Main.gd`): `press_land` then returns
  `{result: "wormhole", movie_desc}` and `wormhole_enter_pending()` performs the transport after the clip. Media resolves through
  `TCAddOns.findMedia`. Base data has no such dësc records (TC / plug-in content), so nothing plays there.
* Self-checks: `godot/tests/map_features_selfcheck.gd`; Swift `Tests/NovaSwiftKitTests/GateTravelMovieTests.swift`.

### Story Map / Story Guide (`screens/StoryGuide.gd`)

Port of the Apple Story Guide (`StoryGuideView` / `StorylineFlowView` / `StorylineTagBadge`). Apple's current guide is a
**vertical flow** (the old pan/zoom node graph was removed), so that is what is ported: lane list on the left (government
swatch, title, progress, "n/N steps", grouped per plug-in with a source filter, "+N one-off jobs"), overview bar + the
selected campaign's flow on the right (branch indent + connector labels, status badges, YOU ARE HERE, expandable detail with
HOW TO UNLOCK blockers, "Can end here", jump chips, cross-storyline chips, Abort mission). Drawn in code in Apple's own dark
style in every presentation mode (Apple does not use the authentic chrome for it either). Input: stick / d-pad move Godot
focus between steps and the list, A / click opens detail, B / Esc closes, LB / RB or - / + zoom (0.8-1.6, rebuilds the flow
at scale), right stick / wheel scroll, X / Y or PageUp / PageDown switch storyline.

* **Shared code:** `Sources/NovaSwiftStory/StoryFlowLayout.swift` holds `buildStoryFlow`, `StoryFlowRow`, `StoryConnector`
  (labels + branch ranking), `CrossLink`, `StoryJump` and `StoryGuideLogic` (cross-links, current step, per-lane flow), moved
  out of `app/NovaSwift/Story/StoryFlow.swift` / `StoryGuideModel.swift` (Apple keeps only the SwiftUI tint / symbol and
  calls the shared code). Tests: `StoryFlowLayoutTests`.
* **Bridge (`// MARK: Story Map` in `NovaWorld.swift`, state in `Story.swift` `StoryMapState`):** `story_map_begin()` builds
  `StorylineAnalyzer.storyMap(for: pilot)` on a serial background queue, `story_map_ready()` polls, `story_map_lanes()` /
  `story_flow(key)` return JSON, `story_tag(mission_id)` / `story_tags_ready()` serve the badge table (prewarmed once off-thread
  through `StorylineTagCache`), `mission_abort` is the existing call. Test seams: `debug_set_bit(bit, on)`,
  `debug_complete_mission(id)`.
* **Entry:** pause menu "Story Map" (Classic and Nova Swift paths; `Shell._open_story_map` stacks the guide over the pause
  menu and restores it on close). Anywhere else: `StoryGuide.open(parent, nova, storyline_key)`.
* **Badge:** `StoryGuide.make_badge(nova, mission_id, host) -> Control|null` (amber book button, opens the guide on that lane;
  null when untagged, still prewarming, or `Prefs story/show_mission_storyline_tags` is off). Placement on mission rows is a
  follow-up for the files the reskin agent owned (BBS list row in `SpaceportClassic.gd` / `Spaceport.gd`, offer dialog and
  Mission Info in `StoryScreens.gd`): in each row builder add
  `var _b = StoryGuide.make_badge(nova, int(m.id), self); if _b != null: row.add_child(_b)` (+ `const StoryGuide = preload("res://screens/StoryGuide.gd")`).
  The tag table fills in after the first call, so rows built in the first seconds may lack it; rebuild or re-call on refresh.
* Not ported: the Apple `PilotSummary` header (unused by the current Apple view), a Settings toggle for the badge, plug-in
  display names (lanes show the plug-in id until plug-in loading, package 6, lands).
* Test: `tests/story_map_selfcheck.gd` (real data lanes/flow, progress change after completing a mission / setting a bit, badge,
  focus walk, detail, zoom, lane cycling, pause-menu open/close; `NOVA_UI=modern`, `NOVA_PREVIEW=<png>` writes a layout preview).

## Debug suite (`godot/debug/`, bridge `Debug.swift`)

Port of `app/NovaSwift/Debug/`. Developer UI in Apple's dev style (dark/green monospace), keyboard and pad navigable.

**Opening.** Gated by `Prefs developer/debug_mode` (= Apple `debugModeEnabled`; Settings > Support > Debug mode). With it on: **F12**, **Ctrl/Cmd+`**, **L3+R3**, pause menu > Debug Suite, Settings > Support > Open Debug Suite, or the corner chip (`>_` / fps). With it off none of these exist. **Report a Bug** is never gated (Settings > Support, pause menu). While open, Main.gd does not read flight input (`DevTools.captures_input()`) but the sim keeps running; Esc / pad B close, LB/RB or Ctrl+PgUp/PgDn switch tabs.

**Files.** `debug/DevTools.gd` (host, hotkeys, metrics, Godot log capture via `OS.add_logger`), `ConsolePane` (filters, search, history, Tab completion, hints, entity-link chips), `ToolsPane` (SELECTED/PERFORMANCE/CHEATS/WORLD/HD/STRESS/EDITORS), `StatePane` (game-state editor), `BitsPane` (NCB browser), `BrowserPane` (ships/outfits/govts), `ChecksPane` (diagnostics + self-tests), `ReportPane` (bug-report zip), `DevOverlay` (AI overlay + measurement grid), `DevSettingsPage`. Main.gd hooks: create `DevTools`, `_dbg_to_screen`, and the `captures_input()` early-out.

**Bridge.** `NovaDebug` (second `@Godot` class, registered beside `NovaWorld`) holds a `DebugConsole`, a `DebugLogBuffer` and a `FrameProfiler`, and reaches the engine through `dbg*` accessors in the `// MARK: Debug suite` extension at the end of `NovaWorld.swift`. All world-touching commands (god, fuel, heal, refuel, credits, spawn, ship, outfit, relation, bit, date, select, destroy, disable, capture, conquer, cycle, perf, ai, uidebug, ...) are registered there; extras for the state editor: `rebuild, outfits, rating, set, damage, escorts, hostiles, date set`. `hd` reports that HD is Apple-only.

**Shared code (Apple calls it too).** `NovaSwiftStory`: `DebugDiagnostics`, `DebugLiveTests`, `NCBIndex`, `DebugConsole` (registry/tokenizer/completion), `DebugLogBuffer`, `DebugPilotOps`, `BugReportText`. `NovaSwiftKit`: `FrameProfiler`/`PerfPhase`, `DevEntityRef`/`DevLogLinking`, `DebugLogSink`.

**Log capture.** Off-Apple the `FallbackLogger`s mirror every line into `DebugLogSink` -> ring buffer. On macOS the engine uses `os.Logger`, so the bridge tails `OSLogStore` on a utility thread. Godot's own log arrives through `DevLogger`. The buffer is always on (bug reports have history even with debug mode off).

**Bug report.** `bug_report_files()` returns report.txt / pilot.json / diagnostics.txt / console.log; `ReportPane.make_report` zips them with `ZIPPacker` into `Documents/NovaSwift/Diagnostics` (fallback `user://Diagnostics`, `NOVA_REPORT_DIR` overrides).

**Not ported.** HD/3D viewer and HD commands (NovaSwiftHD is Apple-only), PerfMonitor's os_signpost/mach memory counters (Godot `Performance` monitors are used), console "select a line -> run again/edit" action bar (history walk and Copy cover it), the right-click context menu on ships/planets (use the SELECTED section; mouse click-select works as in flight).

Verify: `NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/debug_suite_selfcheck.gd`.


## Plug-ins (work package 6)

Godot loads plug-ins exactly like the Apple app; the rules are shared code.

* **Shared (new)**: `Sources/NovaSwiftKit/PluginSet.swift` (`PluginSet.arrange/setEnabled/move`, `PluginEnableState`) is
  the enabled-flag / persisted-order / total-conversion logic that used to live inline in
  `GameDataController`; Apple now calls it (behaviour-identical). Discovery (`GameLibrary.discoverPlugins`), the original
  alphabetical rule vs the "manual plug-in order" enhancement (`originalPluginOrder`), TC handling and `merge` were already shared.
  Tests: `Tests/NovaSwiftKitTests/PluginSetTests.swift`.
* **Bridge**: `Plugins.swift` has `PluginRuntime` (state; `NovaWorld.loadGame` and `load_game_async` both call
  `PluginRuntime.shared.loadMerged`, so every `load_game` caller gets plug-ins) and the `NovaPlugins` class
  (`list/state/rescan/set_manual_order/set_enabled/move/reload/import_from/delete/install/catalog_*/image/...`, JSON strings).
  `NovaSwiftPluginStore` builds off-Apple (FoundationNetworking, ZIPFoundation, swift-crypto) and is linked into the bridge; the store's
  download/verify/unpack runs on Swift tasks and GDScript polls `catalog_state`. `PluginCatalog.bundled` (SwiftPM `Bundle.module`) is
  never touched in the bridge: the offline copy is `godot/data/PluginCatalog.json` (keep equal to
  `Sources/NovaSwiftPluginStore/Resources/PluginCatalog.json`; the self-check compares them), loaded with `set_bundled_catalog`.
* **Where it looks** (in order): `NOVA_PLUGINS_DIR` / `NOVASWIFT_PLUGINS` (dev); a "Nova Plug-ins" folder inside or next to the
  chosen data folder (the original install layout; base files under it are excluded from the base set); the user folder
  `<data root>/Plug-ins` (`~/.local/share/NovaSwift` or `$XDG_DATA_HOME/NovaSwift` on Linux/Deck, `~/Library/Application Support/NovaSwift`
  on macOS, `%APPDATA%\NovaSwift` on Windows; override `NOVA_PLUGIN_HOME`) where downloads and imports land; folders added with `add_dir`.
  The repo's `data/plugins` is deliberately not scanned (it would load every pooled plug-in into every test). State is JSON at
  `<data root>/plugins-state.json` (`NOVA_PLUGIN_STATE`, `set_state_file`).
* **UI**: `screens/Plugins.gd` (Installed / Browse / Load order, details, import, install/update/delete, Apply). Reached from the main
  menu ("Plug-ins" in the plain menu, a Classic extra button beside Game Data...; `MainMenu.plugins` signal -> `Shell._open_plugins`)
  and Settings > Plug-ins. Data reload goes through `Shell.load_data_async` (loading screen). Changes are batched and applied by Apply,
  Done, or automatically when an install finishes (Apple reloads after every toggle).
* **Story Map**: `story_map_lanes` now carries `pluginLabels`; `StoryGuide.plugin_label` shows plug-in names.
* `NOVA_PLUGIN_OFFLINE=1` stops the catalog from touching the network (CI, self-checks).
* Check: `NOVA_PLUGIN_OFFLINE=1 NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/plugins_selfcheck.gd`.

### Total-conversion add-ons, dësc movies, intro/GIF, fonts (2026-10-13)

* **Per-TC add-on list** (shared `Sources/NovaSwiftKit/TCAddOns.swift`, same as Apple): bridge `NovaPlugins.tc_addons()` (selected TC,
  its own plug-in files, `list`, `candidates` with `compat` recommended/neutral/unlikely), `tc_addon_add/remove/set_enabled/move`,
  `tc_addons_analyze()` (background record-overlap check). Persisted in `plugins-state.json` under `tcAddOns` (`{tcID: [{id,isEnabled}]}`,
  the Apple UserDefaults JSON). `Plugins.gd` Installed tab shows "Add-ons for <TC>"; a "Base game?" candidate needs a second press.
  Load order: Nova.rez, TC Nova Files, TC Plug-Ins (flat), add-ons in list order. Original rule unchanged without a list.
* **dësc movies everywhere the original plays them** (`Ui_LoadDescAndPlayMovie` 0x0049e3c0 / `Ui_RunTravelSelectionDialog` 0x004982a0 with
  param_3 = 1): `ui/DescMovie.gd` (`lookup`, `play`; Flags 1 after text, 2 double size, 4 fill screen; clips <= 12 MB convert on the spot).
  Wired: story texts (briefing / completion / failure / refusal / ship-done: `StoryScreens._open_text` via `story_text_info().desc`),
  docking (`Spaceport.open`, the stellar's own dësc), the new-pilot intro text (`IntroSequence`, `pilot_intro().desc`: `EV Intro.mp4` /
  `Override Intro.mp4`, dësc 20000, flags 4), main-menu X = Acknowledgements dësc 32766 (`EV Haikus.gif`). Ship/outfit info dësc do NOT
  play movies in the original (param_3 = 0). `.gif`/`.mp4`/`.mov`/`.qt` all go through `Movies.gd` (ffmpeg).
  `NovaPlugins.desc_movie` now works on a fresh handle (`PluginRuntime.world`, set by `loadGame`); before, only an attached handle answered.
* **Media folders** are the shared `TCAddOns.mediaDirectories` (`media_dirs`, `find_media`): TC add-ons, TC Plug-Ins, TC Nova Files, base.
  Imported zips extract every file (ARPIA2's `gasminer.mov` / `credits.mov` land in its `Plug-Ins`), checked by the harness.
* **TC fonts**: `font_files()` lists `.ttf/.otf` beside the TC's `Nova Files` (Sillycon.ttf); `ClassicTheme.font_for` registers them (key = family,
  "family style", file stem) so `ïntf.statusFont` "Sillycon Plain" resolves.
* **Harness**: scenarios "EV Override + Facelift (per-TC list)" (+ Extras) use `NOVA_PLUGCHECK_TCADDONS` instead of staging files and must match
  `merged-counts` with `NOVASWIFT_TC_ADDONS`; `novaswift-extract desc-movies` gives the media/font reference (`NOVA_PLUGCHECK_MEDIA`).

### Real plug-in verification (2026-10-13): `scripts/plugins-check.sh`

`scripts/plugins-check.sh [filter]` stages each plug-in of `data/plugins/` in a scratch folder (symlinks only; `data/`, the user's pilots,
prefs and `~/Library/Application Support/NovaSwift` are never touched; `Shields.zip` is unzipped to scratch) and runs
`godot/tests/plugins_load_selfcheck.gd` headless, parameterised by env vars (`NOVA_PLUGINS_DIR`, `NOVA_PLUGCHECK_ENABLE`, ...). Per scenario:

1. **Install/enable like the Plugins screen**: found through the plug-in folder rules, total conversions switched on with `set_enabled`,
   optional sub-items (EVO Extras, rEV Optionals) via manual order; then `reload()`.
2. **Parity with the shared Swift merge**: `novaswift-extract merged-counts <base> <plugdir> [ids]` (new subcommand, same
   `discoverPlugins -> PluginSet.arrange -> GameLibrary.merge` the Apple app runs) prints per-type counts; Godot must match the total, all 39
   type counts and the enabled set exactly.
3. **Assets**: every PICT / cicn / snd / shïp / spöb / bööm / röid the plug-in supplies (everything, under a TC) decodes through the bridge;
   shän overlay layers (shield / engine / lights / weapon / alt) are counted; title music and every dësc movie file resolve in the plug-in folders.
4. **Pilot flow** (`PLUGCHECK_ALL=1`: every chär start): new pilot, make world, take off, draw flight frames (missing hull / stellar / rock /
   starfield graphic or unplayable sound cue fails), land, open trade / outfitter / shipyard / bar / mission BBS through the real Spaceport
   screen, launch, open the galaxy map, hyperjump. No SCRIPT ERROR / engine ERROR or WARNING that the no-plug-in run does not also print.
5. **Phase 2, import**: each `*.zip` (and loose `.rez`) in `data/plugins` is installed through `NovaPlugins.import_from` and must reproduce the
   folder scenario's counts.

Results (all PASS after the fixes; "before" = first run of this harness on the tree as it was):

| Plug-in | Before | After | Notes |
|---|---|---|---|
| ARPIA2 | counts OK; ship 464 flagged | PASS | 10109 resources; 84 shïp, 153 spöb, 138 PICT; `shïp 464` has no shän in the data (warn, same in Apple); `gasminer.mov`/`credits.mov` are only inside ARPIA2.zip, not in the unpacked folder |
| Cold Fusion 1.0.1 | PASS | PASS | 8483; 96 stellar sprites, 204 PICT, 27 cicn |
| Collision Damage | PASS | PASS | 8493 |
| Dodge That | flow FAIL (2nd start has no hyperlink) | PASS | the 'Dodge That' start is a self-contained arena: jump is skipped with a warning |
| EV Classic (TC) | music not found in the TC folder | PASS | 2135; TC's own Plug-Ins (AI Rocket Hack, Manual Flares) load; `Nova Music.mp3` now comes from the TC's Nova Files |
| EV Override (TC) | music not found | PASS | 3454; also with EVO Facelift (+ FL Extras) placed in its Plug-Ins: 3602 / 3835 |
| EVO Extras (with / without Facelift) | PASS | PASS | optional sub-items, loaded by enabling them (manual order) |
| EVO Facelift 1.0.7 | PASS | PASS | 8534; 164 rlëD, engine/lights/weapon layers decode |
| Femme Fatale (TC) | music not found | PASS | 3245 |
| Polycon EV (TC) | music not found; 4 röid flagged | PASS | 4837; 41 shield layers; 4 röid types (135, 139, 142, 143) have no spïn 807/811/814/815 in the data (warn) |
| Preambles & Walkthrough | n/a | PASS | docs only, loads nothing (== base 8476) |
| The Frozen Heart (TC) | music / movies not found | PASS | 2754; its 43 dësc movies resolve in the TC's Nova Files |
| rEV 1.1 (+ Optionals) | PASS | PASS | 8580 / 8642 |
| Shields | PASS | PASS | 340 shän shield layers decode (`sprite_info(SHIELD, id)`); with ARPIA2: 341 |
| import of each zip / .rez | every zip FAILED ("Couldn't open this file as a plug-in") when the target path had a `//` | PASS | see fixes |

Fixes made for this:

* **Bridge `Plugins.swift`**: `NovaPlugins.media_dirs()` (the selected TC's own `Plug-Ins` + `Nova Files`, else the enabled plug-ins' folders,
  then the base data) and `desc_movie(id)`. `TitleMusic.locate` and `Movies.search_roots` use them, so a TC's `Nova Music.mp3` and the
  plug-in `.mov` files are found where Apple's `musicTrackURL`/`videoURL(named:)` find them (plug-ins before Nova Files). Before, Godot only
  looked under the base data folder, so every TC played the base music/none.
* **Zip import**: the install folder is now standardised (`PluginRuntime.installDir`). ZIPFoundation refuses entries whose path does not
  start with the normalised destination, so `NOVA_PLUGIN_HOME`/`set_install_dir` values containing `//` or `..` failed every zip install with a
  misleading "unsupported archive" message.
* **Shared `GameLibrary.bundles(forFolder:)`** (Apple behaviour change, intended): a game-folder style pack with no files of its own and no
  `Nova Files/` but a `Plug-Ins/` folder (ARPIA2.zip: `Play ARPIA2.nplay`, `Plug-Ins/`, `Extra ARPIA2 add-ons/`, `Pilots/`) now treats `Plug-Ins/`
  as the plug-in (loads by default, its `.mov` files are findable); the other subfolders stay opt-in. Before, everything in such a zip was an
  opt-in sub-item and nothing loaded. Test: `PluginCompatTests.testGameFolderStylePackLoadsItsPlugInsFolder`. `swift test` (427 tests) and the macOS
  `xcodebuild` (CODE_SIGNING_ALLOWED=NO) pass.
* **StoryScreens**: a mission offer whose dësc names a movie plays it (before the text, or after the button when dësc Flags 0x0001), skippable,
  needs ffmpeg (as `Movies.gd`); first sight starts the background conversion, like the race clips. Matches Apple `MissionBoardView`.
* `FlightSprites.misses` / `GameAudio.missing_sounds` record absent art and undecodable sounds for the harness.


## Flight rendering (`godot/flight/`) -- Apple Classic parity pass

`Main.gd` no longer draws the world. `flight/FlightRenderer.gd` (a `show_behind_parent` child) owns it and stacks `FlightLayer`s (one blend mode each: `mix`, `add`, `fill`) in the Apple scene's z order: world, murk fog, hulls, hull fog, additive glows, shots, additive fx, beams, fx. Main calls `_flight.frame(delta, bar_width, sim_ran)` once per frame after `nova.step`; the renderer snapshots every bridge readback once, moves the camera and advances effects.

Drawers: `FlightSprites` (decoded-sheet cache incl. cicn), `FlightCamera` (CameraRig port + shake), `StarfieldDrawer`, `StellarDrawer` (animated/destroyed stellars, murk, nav cursor cicn 10000-10007), `ShipDrawer` (shan layers, launch grow-in, landing ghosts, reticle cicn 10008-10023), `ShotDrawer` (art/rotation sheets, trails, corona beams, beam art, lightning), `EffectsDrawer` (boom sprites, flashes, SWParticles, smoke cicn, death sequence, area blasts, hit sprays).

Bridge additions (`FlightVisuals.swift`, section `// MARK: Flight visuals` in NovaWorld.swift): `ship_layers()` (stride `ship_layer_stride()` = 26: set, heading, fps, alt set, light/weapon-glow/shield/engine alphas, disabled, bank, opacity, tint, fog, blend, gate wash, ion, thrust, over-speed, gate flag), `stellar_states()`, `projectile_extra()`, `beam_weapons()`, `weapon_visual(id)`, `target_reticle()`, `stellar_dominated_visual(id)`, `player_max_speed()`, `cicn_info/cicn_rgba`, `set_flight_options()`, sprite kind 11 (shan alt layer), effect kinds 7-10 (disabled, area blast, launched, landed). Rules live in `Sources/NovaSwiftEngine/HullAnimator.swift` (Foundation-only port of `HullAnimation.swift` + shield flare) and the existing `StellarAnimator`, `MurkFog`, `OriginalRendering`. `World.addNPC` now seeds the render pose so an arriving ship is drawn at its spawn point.

Arrivals/departures follow Apple Classic exactly: a hyperspace jump-in draws nothing special (the engine's own 50 px/tick over-speed braking carries the ship in), departure just vanishes, gate emergence/entry is the white wash from the AI record, a launch grows in (0.08 to 1 over 0.5 s, fade 0.4 s), a landing shrinks into the stellar (0.5 s). The player's jump (`screens/HyperjumpFx.gd`) is the Mac look: 1.5 s fade to white after the cue, boom flash on arrival fading over 1.5 s, no streaks (the original draws none); Reduce flashing caps the white at 0.45; Classic Preferences Hyperspace Fx off = 0.1 s black flash.

Settings: Graphics > Flight View (`[graphics] camera_view/camera_zoom/screen_shake/reduce_flashing`); the Classic Preferences flags Engine Glows, Running Lights, Weapon Effects, Smoke Trails, Parallax, Ship Animations are honoured. Chase falls back to Ship up as in Apple without live 3D. Check: `godot/tests/flight_visuals_selfcheck.gd`.


## New-pilot flow (intro, training, hints, death, slots, autosave)

Ports Apple's `IntroSequenceView`, `Tutorial/`, `PilotGroupDetailView` / `PilotBackupsView`,
`GameContainerView.onPlayerDestroyed` and `frequentAutosave`. Shared Swift (new files in
`Sources/NovaSwiftStory`, Apple calls them too): `TutorialCurriculum.swift` (steps, wording per
control style, `TutorialProgression` state machine), `GameHintCatalog.swift` (`NovaHints`, the
should-show rule), `PilotGroups.swift` (slots, backup history, Strict Play group delete). Tests:
`Tests/NovaSwiftStoryTests/NewPilotFlowTests.swift`. Apple files changed (behaviour-identical
refactors only): `Tutorial/TutorialModel.swift` (types + wording moved; `TutorialCourse.build` keeps
its signature and supplies the control style / labels, `TutorialRun` mirrors a shared
`TutorialProgression`), `Tutorial/GameHints.swift` (`GameHint` = `NovaHint`, catalog and `shouldShow`
shared), `TutorialCoachView.swift` / `TutorialContainerView.swift` (import only).

Flow (`Shell.gd`): New Pilot (`PilotMenu.pilot_created`, only when a host listens) -> `IntroSequence.gd`
(chär intro PICTs, each `IntroPictDelay x 60 ms`, then the intro dësc text page; click / Enter / A
advance, Esc / B / the corner button skip) -> `Tutorial.make_offer` (first pilot only, Tutorial
hints on) -> play, or `start_training("play")`. Training swaps a throwaway pilot into the bridge
(`tutorial_begin` / `tutorial_end`): invulnerable, nothing saves, landing only completes the lesson
(no spaceport). The coach (`Tutorial.gd`) words the steps for the pad (button names) or the bound
keys and watches the flight at 5 Hz exactly like Apple. Buttons are mouse-only (A / Space fire the
ship): Enter / A continue manual cards, Backspace skips a step, Delete skips the tutorial, Esc /
Start opens the pause menu whose entry reads "Leave Training". Settings > Interface > Tutorial has
Tutorial hints, Show all hints again and (from the main menu) Flight Training (exit = main menu).

Hints (`Hints.gd`): the first-flight "Getting started" card and the spaceport / Mission BBS / Outfitter
banners, seen flags in Prefs `[hints]`. Dismissed by the X / Got it button or after 20 s (so pad and
keyboard players never need the mouse); the docked screen is read from Main's Spaceport `_screen`.

Death: Main's `_check_game_over` (2.2 s) calls `Shell.on_player_killed` -> bridge `pilot_killed`:
Strict Play deletes every slot and backup (`PilotGroups.deleteGroupAfterStrictPlayDeath`), else the
pilot is marked killed and the Classic menu readout shows "<name> has been killed" (STR# 2002 #277,
the Kenny easter egg) while Enter Ship only beeps (`classic_menu_readout_state`). While the New
Pilot dialog is up the readout says "Creating Pilot..." (#275). The menu readout now reads the
configured Pilots folder (it still read `user://pilots`).

Slots and backups (`PilotMenu.gd`): Manage > pilot > Slots & Backups -> group screen (play slot, New
Save Slot up to 3, delete slot, rename, View All Backups) -> backups browser (all slots, newest
first; picking one restores that slot, backing up the current state first, and plays it). Classic
panels or plain panels; focus navigation only.

Frequent autosave: Settings > Data & Advanced > Frequent autosave (Prefs `[gameplay]`,
`Prefs.apply_saving` -> `set_frequent_autosave`). Off = the original (launch / quit while landed /
event saves only). On adds land, jump and a 180 s in-flight heartbeat, and the in-flight position is
saved and restored (`PilotSaveReason.shouldSave`).

Verify: `godot/tests/new_pilot_flow_selfcheck.gd` (headless; NOVA_PILOTS_DIR scratch).

## Settings plumbing and the pad keyboard (2026-10-13)

* **Keys.** Every Apple `GameSettings` field with a Godot equivalent has a `Prefs.gd` key; `docs/GODOT_SETTINGS_KEYS.md` is the
  table (key, type, default, Apple label, wired or not). `Prefs.hub.changed(section, key)` fires on every `set_value`.
* **Engine.** `SettingsPlumbing.gd` (autoload) re-applies on `Prefs.hub.changed` and when a `NovaWorld` enters the tree:
  `Prefs.engine_settings()` -> `NovaWorld.apply_settings(json)` (bridge `Settings.swift` + the `// MARK: Settings plumbing`
  section in `NovaWorld.swift`). The rules are shared engine code (`Sources/NovaSwiftEngine/GameSettingsRules.swift`:
  difficulty / traffic / speed tables, `LandingRules`, `AutoLandPilot`, `ColorblindFilter`, nearest-first cycle), now called by
  the Apple app too. `settings_state()` reads back what the engine runs with. Game speed rides the fixed-step accumulator
  (`GameSpeedRules`, Caps Lock 2x via `set_caps_lock`); mouse aim is `set_mouse_aim(active, heading)`; auto-landing and the
  "Land here?" confirmation live in the bridge's `press_land` (`confirm` / `autoland` results, `pending_land_confirm`,
  `confirm_landing`).
* **Presentation.** Colorblind shader overlay (the engine's matrix), FPS counter, frame cap, UI scale, HUD opacity, smooth
  sprites, pause on focus loss: all in `SettingsPlumbing.gd`. `Main.gd` reads `Prefs.hud_scale()` / `hud_high_contrast()` /
  `show_radar()` for the primitive HUD.
* **Pad keyboard.** `ui/PadKeyboard.gd` (autoload): any `LineEdit` focused while the last input was a gamepad opens a key grid
  (suggestion chips, Shift, Del, Clear, Done/Cancel; A presses, B cancels, Y deletes, X spaces, Start commits). Optional
  per-field config: `PadKeyboard.attach(line_edit, {title, suggestions, style, auto})`. Style follows the presentation
  (Classic greys / NovaSwift dark and amber) unless given. Prefs `ui/pad_keyboard = off` disables the auto-open.
* **Check.** `NOVA_DATA_DIR=$PWD/data/base NOVA_PILOTS_DIR=<scratch> godot --headless --path godot -s res://tests/settings_plumbing_selfcheck.gd`.

## NovaSwift UI kit (`godot/ui/novaswift/`) and the Apple-style screens

NovaSwift's OWN screens (Settings, Plug-ins, the pause sidebar, the pilot roster / slots / backups / New Pilot, alerts,
Data Setup, the flight-training offer / coach, hint cards) are drawn with one kit that mirrors the Apple app's design
system (`app/NovaSwift/UI/NovaUITheme.swift`, `NovaFont.swift`, `NovaFormControls.swift`, `NovaDialog.swift`,
`NovaAlert.swift`, `PadGlyph.swift`). The kit is built from stock Controls + `StyleBoxFlat` + icon textures, so it
navigates by Godot focus alone and composes in the headless preview. The original EV Nova screens keep `ui/classic/`.

| File | What it is |
|---|---|
| `NovaTheme.gd` | tokens: `AMBER` (novaAmber 1.0/0.7/0.28), `ACCENT`, SwiftUI dark system colours (`RED GREEN ORANGE INDIGO TEAL`), `SECONDARY`/`TERTIARY` alphas, `CHIP_BG`, `FIELD_BG`, `GROUP_BG`, `CARD_BG` (primary 7 %), `SCRIM`; fonts `font(role, weight)` (title/heading = Rubik, body/caption/button/hud = Arimo, NovaFontRole sizes 28/20/15/13/15/14; `system()` = the SwiftUI system-font stand-in); `box(bg, radius, border, bw, pad)`; `icon(name, px, colour)`; `theme()` = the shared `Theme` (check box, slider, option chip, line edit, popup, scroll bar) with Apple's keyboard / pad focus treatment (amber ring only while the last input was keyboard / pad) |
| `NovaIcons.gd` | ~65 vector glyphs standing in for the SF Symbols the Apple screens use, rasterised to `ImageTexture`s (`Icons.texture(name, px, colour)`) |
| `NovaControls.gd` (`NC`) | builders: `section(parent, title, icon, footer) -> Group` (`add_row`), `toggle` (NovaToggleStyle), `slider` (NovaSlider row), `segmented` (NovaSegmentedPicker), `menu` / `option_chip` (NovaMenuPicker), `stepper`, `value_row`, `form_button`, `button(text, kind, cb, icon)` (kinds `primary bordered destructive form plain pill pill_default`), `icon_button`, `select_row` (NovaSelectRow), `chip`, `badge`, `card`, `card_button`, `search_field`, `text_field` (NovaTextField), `progress`, `label` / `caption` / `footer`, `pad_glyph` (PadGlyph), `grow_on_focus` (the controller cursor's hover-grow) |
| `NovaChrome.gd` | `dialog(host, {title, width, buttons}) -> {root, body, buttons, default, mode}` = NovaDialog; `card_frame(host, title, w, h, on_close) -> {root, card, body, done}` = DialogChrome (fixed 660 x 620, scaled down to fit, never up); `mode()` picks `classic` (original PICT 8524/8525/8526 frame + three-state button art), `modern` ("Modern dialog chrome": steel border, blue gradient + glow) or `plain` (no data) exactly as `NovaPanelBackground` does |
| `NovaAlert.gd` | `Alert.show(host, {title, message, text?, buttons: [{title, role: normal/cancel/destructive, cb}]})` = `.novaAlert`: cancel first, default = last normal button (never a delete), Esc / B = cancel, optional text field (callbacks taking an argument get its text) |
| `NovaInert.gd` | `Inert.hold(node)` / `Inert.release(token, fallback)`: how an overlay makes the screen beneath inert (out of focus navigation and the input path; animation and music keep running) and hands focus back to the control that opened it |
| `pilot/NovaPilotUI.gd` | pilot rows: `roster_row`, `roster_empty`, `roster_scroll`, `group_header`, `slot_row`, `backup_row`, `link_button`, `kv_row` (data-in / callbacks-out, fed with the bridge's `pilot_groups` / `pilot_group_history` rows) |

**Screens.** `screens/Settings.gd` (Apple SettingsView: sidebar + grouped sections, every row bound to the Prefs key in
`docs/GODOT_SETTINGS_KEYS.md`; rows with no Godot key persist under Prefs `[apple]` and are listed in `todo_rows`),
`screens/Plugins.gd` (PluginsView: gradient window, top bar, Browse / Installed / Load order, search, filter chips, card
grid, detail), `screens/PauseMenu.gd` (GameMenuView sidebar when `interface/sidebar_pause_menu`, else the original's pause
dialog), `screens/PilotMenu.gd` (roster / slots / backups / import / New Pilot via `_nd()`; Classic keeps the original
DLOG 3102 / 3001 for naming), `screens/DataSetup.gd`, `screens/Tutorial.gd` + `Hints.gd`.

**Overlays, not replacements.** `Shell._overlay_push(under)` / `_overlay_pop(token, under)`: Settings, Plug-ins, the Story
Map, Data Setup (from the menu) and the pilot dialogs stack over the main menu or the pause sidebar, which stay in the
tree, visible and animating but inert; closing returns focus to the opener. Only real route changes replace a screen.

**Check.** `NOVA_PLUGIN_OFFLINE=1 NOVA_UI_PREVIEW_DIR=/abs/dir NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/novaswift_ui_selfcheck.gd`
(rows per Settings page, prefs binding, focus, Plug-ins tabs, pause sidebar rows, pilot screens, alert, and PNG previews;
`tests/UiCompose.gd` draws StyleBoxFlat panels / buttons / sliders and text as width-accurate bars). Overlay stacking
(underlying screen visible + inert, focus restored) is asserted in `tests/shell_selfcheck.gd`.

## Original movies (`godot/Movies.gd`, `godot/ui/MoviePlayer.gd`)

The original's QuickTime clips live in `Nova Files/` and plug-in folders (`Race 1..4.mov` for bar race
betting, a `dësc` record's movie file, plug-in clips such as `Ring.mov`). Godot only decodes Ogg
Theora, so `Movies.gd` transcodes each clip **once** with an external `ffmpeg` into `user://movies/`
(keyed by name + hash of path/size/mtime, so a changed source re-converts; writes go to a `.part`
name and are renamed, so a crash never leaves a half-file in the cache):

- `ogv` when ffmpeg has the `libtheora` encoder (most Linux/Windows builds);
- otherwise a JPEG frame sequence + `movie.json` (+ `audio.wav` if the clip has sound). Homebrew's
  ffmpeg lacks libtheora, so macOS dev machines take this path. `MoviePlayer.gd` plays either kind.

ffmpeg is the bundled decode-only build first (beside the executable, then
`res://bin/ffmpeg/<platform>/` for editor runs; `scripts/build-mini-ffmpeg.sh`, no Theora, so it always
takes the frames path — see `docs/PACKAGING.md`), then `PATH`, `/opt/homebrew/bin`, `/usr/local/bin`,
`/usr/bin` (`ffmpeg.exe` on Windows). It is optional: when missing, or the conversion fails, `Movies.ready()/transcode()` return
`{}` and callers skip the clip exactly as the original does with its "QuickTime Movies" preference off
(`Ui_PlayMovieFileModal` 0x0049db00 returns at once). `Prefs [classic] play_movies` is that preference.

Where clips play:

- **Race betting** (`screens/BarScreens.gd`): after a bet the winner's `Race n.mov` plays in a 440x260
  black card with a Skip button (Apple `GamblingView.racingView`), then the result screen shows; credits
  update when the clip ends. Opening the Gambling screen starts background conversion of the four race
  clips (`Movies.convert_async`), so the first bet normally already has its clip; if the conversion is
  still running, the clip is skipped for that bet (the result appears at once). Skip = Enter/Space/Esc,
  pad A/B (`ui_accept`/`ui_cancel`), the button or a click; `finished` fires exactly once.
- Not yet wired in Godot (Apple plays them): the mission-offer `dësc` movie (`MissionBoardView`, 640x400
  overlay, before the text or after it per Flags 0x0001) and `.gif` movies. The pieces
  (`Movies.find_movie` + `MoviePlayer`) are reusable for them.

Self-check: `NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/movies_selfcheck.gd`
(conversion, cache hit, async, forced-missing ffmpeg, player skip). The libtheora branch is only
exercised on machines whose ffmpeg has the encoder.

## Live-world wiring (package A of `GODOT_FIDELITY_GAPS.md`, 2026-10-13)

The Apple container wires the persisted pilot into every world it builds and folds what happened in flight back into the
pilot through ~25 scene closures. That logic now lives in `Sources/NovaSwiftStory/WorldPilotLink.swift` (and
`GameSession.worldSeed` / the `configure:` hook of `GameSession.makeWorld`), and BOTH frontends call it; the bridge only
marshals (`makeConfiguredWorld`, `syncLiveStanding`, `gapsNote` in `NovaWorld.swift`).

| Item | Shared rule | Bridge call site |
|---|---|---|
| A1 legal record, crime rank revocation, combat rating | `WorldPilotLink.seedDiplomacy` (per-system record, rank shields), `.syncLive` -> `FlightComm.syncStanding` | `makeConfiguredWorld` (seed + drain the outgoing world first), `touchDown`, `completeHyperjump`, `writePilot` (every save), landing request, Player Info; pilot swaps drain into the outgoing pilot |
| A2 mining / scooping | `World.playerHoldHasRoom` set by `WorldPilotLink.configure`; `.collectMined` | `.asteroidMined` in `gapsNote` -> `gapsMined` (live hold + pilot cargo together) |
| A3 përs / hull gating, grudges, defeats | `.persSpawnEligible`, `.shipSpawnEligible`, `.note(event:)` | set BEFORE the initial population via the new `GameSession.makeWorld(configure:)` hook (Apple's own initial fill predates its wiring); `.personGrudge/.personDefeated` autosave as `.event` |
| A4 NPCs boarding the player | `.resolveBoarding`, `OriginalText.playerBoardedLine` | `.playerBoarded` -> `gapsPlayerBoarded` (status line STR# 2002 #391/#373/#392/#374 + snd 151) |
| A5 garrisons, reinforcements, stellar armor, escort orders | `.applyDefenseState`, `.syncLive` (garrison snapshot, `stellarArmor`), `.note` (`reinforcementRetriggerDays`) | same sync points as A1; `applyDefenseState` runs in the `configure:` hook |
| A6 bombs | `HazardOutfits.tick` (ModType 47/50) | `gapsHazardTick`, one call per 30 Hz flight tick |
| A7 Strict Play, per-day seed | `PlayerState.isStrictPlay` -> `World.strictPlay`; `GameSession.worldSeed(systemID:day:)` | `makeConfiguredWorld` |
| A8 launch/jump bookkeeping | `Munitions.record` on landing; `World.strandedFighterWarning` ("Wait for me!") at jump engage; mission aux-ship budget decrement was already in `storyNote` | `touchDown`, `beginHyperjump` |

Pilot save keys are the Apple ones (`systemReputation`, `combatRating`, `persGrudges`, `defeatedPers`, `stellarGarrisons`,
`reinforcementRetriggerDays`, `stellarStrengthLeft`, `escortCategoryOrders`, `strictPlay`), so pilots stay interchangeable.
(HailQuote broadcasts and the arrival/launch lines: package B below.) Note: the per-day seed makes the
ambient cast differ per visit (as on Apple); `interactions_selfcheck.gd` now retries its ship/stellar hail instead of
assuming the first NPC / nav stellar answers.

Test: `godot/tests/live_wiring_selfcheck.gd` (kill -> rating, crime -> legal record kept across rebuilds, mining incl.
full hold, përs defeat/grudge across save+reload, `AppearOn` gate, boarded credit loss, garrison/reinforcement/armor across
a jump and a reload, Strict Play, per-day seed, nonlethal + lethal bombs). The `debug_*` bridge methods it uses are test
seams only.

## Status line, messages and HUD icons (package B of `GODOT_FIDELITY_GAPS.md`, 2026-10-13)

All wording and rules were already shared Swift (`OriginalText`, `PersQuoteBroadcaster`, `RedAlertCue`, `RadarIFF`); the Apple
container posted them and the bridge never did. Nothing moved out of `app/`: the bridge now makes the same calls
(`godot/bridge/Sources/NovaSwiftGodot/StatusLine.swift` + the `// MARK: UI polish` glue in `NovaWorld.swift`).

| Item | Original (text / rule) | Godot |
|---|---|---|
| B1 arrival line | sÿst buoy = STR# 1000 (0x1e0 raw calls), else STR# 2002 #43-45 + system + #48 + date + ".", gate #46, wormhole #47, #49 no stellars, #164/#165 abandoned fighters (`OriginalText.arrival`, `NovaGame.systemMessageText`) | `postArrivalLine` at the end of `completeHyperjump` and `transportThroughGate`; the invented "Arrived in X" in `NavScreens.gd` is gone |
| B2 launch line | STR# 2002 #55-59 + stellar + #60 + date (`OriginalText.launch`); a staged mission `Q` replaces it (snd 154, 0x1f4 raw calls) | `launch()` |
| B3 HailQuote | pêrs HailQuote = STR# 7101 (or the `STR ` 5000+n override), 1/140 per raw call after 45 s, flags 0x0004/8/10/20/80/400/800, 0x1a4 raw calls (`PersQuoteBroadcaster`, 0x00433050) | `tickHailQuotes(dt:)` each `step`; waits while the frontend line is busy (`set_status_line_busy`) |
| B4 dismiss / clock | Return = slot 6; timers on raw sim calls | `dismiss_message` (done in the controls pass); the log now ages on SIM time (0 while docked / map / dialog / pause, scaled by `speed_multiplier()`) and each line carries its own length (`status_line_raw_calls(text)` + `hud_message_seconds`): buoy 0x1e0, `Q` 0x1f4, HailQuote 0x1a4, landing 0xfa, too far/fast 0x168, default 0xf0 |
| B5 `\` cycle | UI-15 | already in `Controls.gd`/`NavScreens.gd` (`cycle_hyperspace_link[_prev]`), asserted by `controls_selfcheck.gd` |
| B6 icons | cicn 18000+frame blink (top-right, only below volume 2/7, `RedAlertCue.blinkFrame`) and cicn 20000 "x2" (top-left, speed exactly 2x) | `Main._draw_alert_icons`; bridge `red_alert_blink_frame`, `set_alert_low_volume`, `x2_active`. The blink anchors at the right edge of the PLAYFIELD (window minus the sidebar) so the sidebar never hides it |
| B7 radar stellars | `RadarIFF.stellarColor` (0x00466030) when an IFF is fitted, else DimRadar; selected stellar blinks white | `AuthenticHUD._draw_radar` + bridge `radar_stellar_colors`, `body_ids` |
| B8 cannot-jump overlays | FL-23 0x0044aa70: #42, #36, #30, #31 are cleared when a jump engages | `Main._clear_cannot_jump_overlays` |

### Message position (the "scanned text is in the wrong place" report)

The one status line is the rect built by `FUN_0087550b` (0x0087550b) and filled by `NovaHud_ShowOverlayMessage` (0x0047e2d0, 12 pt,
colour DAT_00733b44 = white): left = window left + 25, right = window right - sidebar - 50, bottom = window bottom - 5, top = bottom - 4 - 26
(all x ui_scale). `DrawContext_DrawPascalStringInFilledRect` (0x004bcd30) puts the pen at (rect.left, rect.top + font ascent), so the text
HANGS FROM THE TOP of a 30 px rect, ~25 px above the window bottom, not 8 px above it. No drop shadow, no fade (the rect is refilled). Godot's
Classic HUD now does exactly that (`AuthenticHUD.message_rect`, `Main.message_rect/message_text_origin/message_font_px`); the Nova Swift
presentation keeps Apple's MessageLogView look (bottom-left, 16 px in, 8 px up, shadow). Scan lines ("... is scanning you", fines, contraband)
use the same line, so they moved with it.

FLAG for the Apple app (not changed here): `MessageLogView` in `GameContainerView.swift` still uses 16 px / 8 px padding and a 14 pt shadowed face for the
Classic presentation too; the decomp rect above would move it ~17 px up and 9 px right. The status-line colour/size there should follow the same rect.

Test: `godot/tests/status_line_selfcheck.gd` (rect geometry at three window sizes, arrival/launch/HailQuote text rebuilt from STR# 2002/1000/7101,
lengths, Return/pause clock, icons, IFF colours, FL-23 clear). Its `debug_arm_hail_quote`, `debug_red_alert_blink`, `debug_give_iff` bridge
methods are test seams.


## Game data import (Data Setup wizard)

Port of the Apple `DataSetupWizard` + `DataImporter`: bring-your-own-data, copied into a **managed folder** and played from there.

* **Gate.** With no valid game data (nothing in `Prefs.data_candidates()` loads) the shell opens `screens/DataSetup.gd` and *nothing
  else*: no main menu, pilots, Plug-ins, Story Map or Plug-in Editor. Allowed: the wizard, **Quit**, and **Settings** (display / controls /
  audio; its Support page has the Re-import button too). It cannot be dismissed (Esc/B do nothing on the first page). After a successful
  import `Shell._on_data_found` loads the folder behind the loading screen and goes straight to the main menu; a failed load sends the wizard to
  its failure page. Re-import: **Settings > Data & Advanced > Re-import / Change Game Data…** (opens on the source page, dismissable;
  *Preview Setup Wizard* replays the whole guide).
* **Flow.** welcome (legal framing: NOVA Swift never ships or downloads EV Nova's data) -> ownership -> (not yet: Getting EV Nova /
  Register your copy / Get it running, Decoder Ring + community Windows .zip links) -> "Where is my EV Nova?" platform guide (Windows CE
  install, Mac, **Steam Deck**: SD card `/run/media/...`, `~/Downloads`, Desktop-Mode copy; Linux/Wine) -> source -> inspect results ->
  import progress (cancel) -> success. "I already have my files" skips to the source page.
* **Source page.** *Browse…* is the in-app browser `ui/novaswift/DataFileBrowser.gd` (pad: d-pad/stick move, **A** open, **B** up,
  **Y** use this folder, **X** cancel; shortcut chips for Home / Downloads / Documents / Desktop / SD card & drives / scanner finds); *System
  Dialog…* (native `FileDialog`, desktops only, hidden on Steam Deck); a typed path; **Recent** sources (`[data] recent`); and installs the
  time-sliced `DataScanner.gd` found in Downloads/Documents/Desktop/Games/Wine/Program Files/removable media.
* **Importer (Swift, shared).** `Sources/NovaSwiftPluginStore/GameDataImport.swift` (NovaSwiftPluginStore, not Kit, because zip support
  lives there; the discovery helpers it shares with the Apple `DataImporter` are `Sources/NovaSwiftKit/GameFileDiscovery.swift`, which
  Apple now calls too: `importableFiles`, `missingEssentials`, audio/font/video extensions, with no behaviour change). Accepts a game
  folder (Windows/CE install with `EV Nova.exe`, Mac install with the `.app`, or just `Nova Files`), single `.rez`/`.ndat`/music/font/movie
  files and `.zip`s (looks through a wrapper folder). Copies resource containers, `Nova Music.mp3`, `Charcoal/Geneva.ttf`, `Race n.mov`,
  `EVNova.ini` flat into the managed folder, and **plug-in folders found alongside** (`Nova Plug-ins`, `Plug-Ins`...) into
  `<managed>/Nova Plug-ins/` where the plug-in runtime already looks (they are kept out of the base data). Inspection reports layout, version
  (`vers` resource text, else format/edition markers), file groups, missing Nova Data/Graphics/Ships/Sounds/Titles groups, classic
  resource-fork-only files (rejected with a hint to use the Windows zip), unreadable containers (BRGR/classic parse), missing essentials (same rule as
  Apple: ships/systems/planets/outfits/weapons + rlëD 8050 menu art). The import: disk-space check (size + 5 %/64 MB), copy into a hidden
  sibling temp dir with progress, **cancel**, validate the *copy*, then atomic rename (old data moved aside and restored on failure). A
  refused/failed/cancelled import leaves any previous data untouched.
* **Bridge** (`bridge/.../DataImport.swift` + `// MARK: Game data import` in NovaWorld.swift; JSON is snake_case):
  `data_import_inspect(path, deep) -> String`, `data_import_inspect_start(path) -> bool`, `data_import_inspect_status() -> String`
  (`{running, done, result}`), `data_import_inspect_cancel()`, `data_import_start(path, destination, include_plugins) -> bool`,
  `data_import_status() -> String` (`{running, done, ok, cancelled, phase, fraction, files_done/total, bytes_done/total, error, failed[],
  warnings[], resource_count, version}`), `data_import_cancel()`, `data_import_discard()`. `make_demo_world` and every GDScript demo path
  (`NOVA_DEMO`, *Run Demo*, `demo_chosen`) are gone; `NOVA_SKIP_PILOT_MENU=1` now needs data too.
* **Locations.** `Prefs.managed_data_dir()`: Linux/Steam Deck `$XDG_DATA_HOME` or `~/.local/share/NovaSwift/data`, Windows
  `%APPDATA%/NovaSwift/data`, macOS `~/Library/Application Support/NovaSwift/data`, fallback `user://data`. `NOVA_DATA_IMPORT_DIR`
  overrides the destination (tests); `NOVA_DATA_DIR` still wins the *search*. The updater never touches it (docs/UPDATER.md).
* **Check.** `NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/data_import_selfcheck.gd` (fake Windows-CE install made
  of symlinks to data/base in a scratch dir: scanner, inspect, deep inspect, import, refused re-import keeps old data, cancel, the no-data gate);
  `tests/shell_selfcheck.gd` covers the wizard from the shell. The bridge parts SKIP until the bridge is rebuilt.


## Errors and crash reporting (error boundary)

Godot opens a scene even when its script failed to compile; with `Main.gd` broken that meant an empty scene and a
per-frame `Nonexistent function 'in_menu' in base 'Nil'` flood. The Godot frontend now boots through an error boundary
that works when every game script is broken. None of these files preload a game script (only each other):

| File | Role |
|------|------|
| `godot/Boot.tscn` + `Boot.gd` | `run/main_scene`. Installs the Logger + watcher, handles updater mode, checks the GDExtension (`ClassDB.class_exists("NovaWorld")`), loads `Main.tscn` at runtime and verifies the instance has a compiled script with `recover_to_menu`; only then swaps Main in. Failure -> ErrorScreen with a plain-language message and packaged-build hints (missing `.so`/`.dll`/`.dylib`, Linux glibc, macOS quarantine). |
| `godot/ui/ErrorScreen.gd` | Plain Controls on the default theme. Title, message, hints, collapsible technical details (error, file:line, recent log), version/OS/renderer. Buttons: Continue anyway, Back to main menu, Retry, Report a bug, Copy details, Open logs folder, Save report bundle, Quit. Mouse, keyboard (Esc) and pad focus navigation. |
| `godot/ui/CrashLogger.gd` | `extends Logger`, `OS.add_logger`ed in Boot. Ring buffer (400 lines) + `user://logs/novaswift.log` (rotated at 2 MB, capped 4 MB/session); Godot's own `user://logs/godot.log` is on via `debug/file_logging`. Storm detector + toast event queue. |
| `godot/ui/ErrorWatch.gd` | Root-level node (survives scene changes, `PROCESS_MODE_ALWAYS`). Polls the logger each frame: storm -> pause the tree + ErrorScreen overlay; single error -> toast. |
| `godot/ui/ErrorReport.gd` | `sanitize()` (home dir / account name -> `~`), `build_issue_url()`, `save_bundle()`, `open_logs_folder()`. |

**Boot checks** (any failure shows the screen, nothing is half-started): GDExtension class missing -> "engine bridge is
missing or for the wrong platform"; `Main.tscn` missing/unloadable, root without a script, script that cannot
instantiate, or no `recover_to_menu` method -> "a game file failed to load" plus the error lines the load logged (the
parse error naming the file and line). Updater mode (`-- --updater ...`) is decided in Boot *before* anything else and
loads `updater/UpdaterMode.gd` / `UpdaterScene.gd` at runtime, so the updater never depends on Main compiling.

**Storm thresholds** (`CrashLogger`, 1 s window): the same error (file:line:function:text) 8 times, or a *script* error
raised from `_process`/`_physics_process`/`_draw`/`_input`/`_unhandled_input`/`_notification` 3 times. Either pauses the
tree and shows the overlay (Back to main menu / Continue anyway / Report); Continue and Back ignore that error for the
rest of the session. A single non-repeating error shows a small bottom-left toast "Something went wrong - Report" (at
most one per 8 s, 6 s on screen). Warnings are logged but never toast or trip.

**Main.gd guards**: `_ready` is split into `_ready_game()`; afterwards `_alive` is set only if every subsystem exists,
otherwise the fatal ErrorScreen opens (`ErrorWatch.show_fatal`). `_process`, `_draw`, `_unhandled_input` and
`_notification` return immediately while `_alive` is false. `Main.recover_to_menu()` is the "Back to main menu" hook.
The dev status label (`HUD`) is now created by `Main.gd` instead of living in `Main.tscn`.

**Reporting**: the "Report a bug" button opens `https://github.com/SirStig/NovaSwift/issues/new?title=&body=` prefilled
with version, OS, renderer, the error and the last 30 log lines (home paths -> `~`; URL capped at 6500 chars by
dropping the oldest lines first). "Save report bundle" zips `report.txt`, `novaswift.log`, `godot.log`, `settings.cfg`
and the newest pilot from `settings.cfg [pilots] recent` into `user://reports/` and reveals it. Settings > Support has
Report a Bug (the full Apple-style bundle, `debug/ReportPane.gd`, which now also has "Open GitHub issue" / "Logs
folder"), Report on GitHub and Open Logs Folder.

Limits: an engine-level failure (a broken *autoload* script such as `ui/PadKeyboard.gd`, or a GDExtension that crashes
natively) happens before Boot runs and cannot be caught from GDScript. Check:
`godot --headless --path godot -s res://tests/error_boundary_selfcheck.gd`.

## Plug-in Editor (Godot)

Full-screen editor opened from the main menu's **Plugin Editor** button (`screens/Shell.gd` swaps it in for the menu). The document, undo stack, schemas, galaxy math, story graph and linter are the shared `PluginDocument` behind the `NovaEditor` bridge class (`bridge/Sources/NovaSwiftGodot/Editor.swift`); `godot/editor/` only draws and forwards edits as JSON.

**Files.**
- `editor/PluginEditor.gd` — the shell. It has a top bar (Close, document name with an *Edited* chip, undo/redo, File menu, Save, validation badge, Test Run), a sidebar (8 tools, then resource types grouped by category with counts and `+changed` chips; empty types are hidden behind the eye toggle) and a status bar.
- The eight tools: Overview (tiles, changes grouped by type, a getting-started card and recents), Resources (searchable list + inspector), Galaxy Map, Star System, Story & Bits, Validation, Project & Export, Bundle Files.
- `editor/Inspector.gd` — resource inspector. It shows a header (name you can rename, type/ID/provenance chips, Duplicate / Change ID / Revert / Delete) and a diff card against the base game.
  - Forms are schema groups shown as collapsible cards with a jump bar. Parallel arrays (weapon / count / ammo) become slot tables.
  - Reference fields open a searchable resource picker with a jump arrow. Ranged enums open a ranged reference picker. Flags are a checkbox grid that keeps its bitmask between toggles.
  - Other kinds: STR# as editable rows, dësc with picture picker / movie / flags, a sprite viewer (zoom, frame scrubber, playback), sound with a waveform and playhead, and a lazily built raw-hex card plus a References card.
- `editor/EditorCanvas.gd` — pan/zoom base (wheel or pinch zooms about the cursor; two-finger scroll, middle/right drag or a drag on empty space pans). Built on it:
  - `GalaxyCanvas.gd` — select/drag systems; link mode toggles a hyperlink between two clicks, Shift keeps chaining.
  - `SystemCanvas.gd` — distance rings; drag stellars.
  - `StoryCanvas.gd` — labelled nodes, edges by kind, search dimming, "only my changes".
- `editor/Previews.gd` — `GraphicView` and `Waveform`.
- `editor/EditorTheme.gd` — colours, the editor theme copy, builders (button kinds, icon buttons, cards, chips, empty states, row buttons). It also holds the type → icon/category map and registers editor-only SVG glyphs into the shared `ui/novaswift/NovaSVG.gd` set.
  - Icons rasterise at the screen's backing scale and display at their logical size through `icon_max_width` / `icon_rect`.

**Edits.** Every control commits one undo step straight away: spin boxes on change, text fields on Return or focus loss, flags and enums on toggle or select. After each edit, `_on_edited()` refreshes the status, the type counts and the selected list row, and starts a debounced lint (0.8 s) that updates the top-bar badge.

**Shortcuts.** ⌘S / ⇧⌘S save / save as · ⌘Z / ⇧⌘Z / ⌘Y undo / redo · ⌘N new resource · ⌘D duplicate · ⌘F find in the current tool · ⌘R test run · ⌘O open · ⌘1–8 tools. Esc first releases a focused text field, then closes the editor (asking when the document is unsaved).

**Check.** `NOVA_DATA_DIR=$PWD/data/base godot --headless --path godot -s res://tests/plugin_editor_selfcheck.gd`. It drives every tool, every inspector kind (forms, text, string list, picture, sprite, sound, raw), an edit, New, Duplicate, the picker and undo.
