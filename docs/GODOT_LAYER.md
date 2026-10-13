# Godot Layer — Linux / Windows support

**In progress.** The foundation, a runnable vertical slice, and the flight
renderer are in. Verified on-toolchain (macOS, Swift 6.3 + Godot 4.7): the bridge
builds clean, a headless run loads real EV Nova data, builds a system, and steps
the simulation without errors. Linux and Windows themselves are still unverified
— CI is what will catch platform-specific gaps.

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
  - `make_demo_world()` — builds a bare physics `World` with a synthetic player
    ship and a few drifting NPCs. **Runs with no EV Nova data**, so the slice is
    playable out of the box and the bridge is provable end-to-end.
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
- **Real-data render queries** (empty/sentinel in the demo world, so the frontend
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
calls `step(delta)`, and renders the result. It picks one of two modes at
startup:

- **Real data** — if EV Nova data is found (`NOVA_DATA_DIR` env var, else the
  repo's git-ignored `data/base/`), it `load_game` + `make_world(-1)`s a real
  system and draws **actual hull, planet, shot, rock and explosion sprites**
  decoded by `NovaSwiftKit`, plus the jump-radius ring. Sprites are the engine's
  own RGBA decode uploaded as Godot textures (cached per `(kind, id)`).
- **Demo** — otherwise a data-free physics world: a ship you fly plus drifting
  hulls, drawn as primitives. Always runs, no data required.

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
  use it (Land falls back to the nearest approachable stellar when none is selected).
- **Landing** (`press_land`, UI-08): first press requests — `LandedServices.landingClearance`
  / `refusalMessage` (MinStatus, `Require`, ranks, landing fee, domination, **bribes** from
  `FlightComm.bribedStellars`), "No response." for uninhabited, the request line, then the
  clearance line on reaching ±250 px; second press lands inside the square envelope
  (`PlayerLanding`) or says too far / too fast / cloaked. The fee is charged on touchdown.
  The old `attempt_land` / `can_land_now` stay as the forgiving test seam.
- **Gates** (`press_land` on a gate): a wormhole transports at once (`wormholeExitCandidates`);
  a hypergate the pilot may use (`SpobRes.playerMayUseGate`, stock gates need positive
  standing with the "Hypergate" govt) opens the map in gate mode (`gate_picker_state`,
  `gate_picker_choose`) — no fuel, no days, the far gate emits the ship on its emergence
  angle (`World.placePlayerEmergingFromGate`) with the wing coming out of it.
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
- `.github/workflows/godot-linux-windows.yml` — compiles the core + bridge on
  Linux and Windows using the official Swift toolchain, so regressions in
  cross-platform compilation are caught on every push. `core-linux` is the
  required signal; the full-package, Windows and bridge jobs are informational
  (`continue-on-error`). It ran manual-only for a while — see the LZFSE entry
  above — and is back on push/PR.

Godot **export templates** turn `godot/` + the platform library into shippable
`.x86_64` (Linux) and `.exe` (Windows) builds; wiring the export presets into CD
is described in [`PACKAGING.md`](PACKAGING.md) (presets, `scripts/package-linux.sh`,
CI `package-*` jobs, Steam Deck setup).

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
   galaxy map; no music (the Apple app only plays the title-menu track, and this
   frontend has no main menu). Headless check: `godot/tests/audio_selfcheck.gd`.
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
   (+1 launch, +1 outfitter trade, +4 ship purchase) tick on launch. Bar, Mission
   BBS and escort hiring are still to build. **Galaxy map + hyperjump work** (`NovaWorld`'s
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
   owns input, BBS/bar/info focus). Not yet: Gambling, Hire Escort, the jettison
   pods, in-flight `pêrs` mission offers (use `storyState.services` from the hail
   code), the storyline-tag badge / map destination shortcut, `dësc` movies.
6. **Packaging** — Godot export presets + CD for Linux/Windows artifacts.

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
`pilot_chosen` / `demo_chosen`. Flow: **no data** -> `DataSetup` (folder picker via
Godot's non-native `FileDialog`, rescan, *Run Demo*) -> **main menu** -> `PilotMenu`
(New / Open, Back returns to the menu). **Pause** (`pause_menu` action: Esc / pad
Start, polled by Main only in plain flight, so the map, dialogs and docked UI keep
Esc/B) offers Resume, Settings, Save & Quit to Menu (`pilot_save_now`) and Quit
(`pilot_autosave`). Original fidelity: no hover sounds; confirm beep snd 150 only.

- **Settings** persist in `user://settings.cfg` via `Prefs.gd` (`[audio]`,
  `[video]`, `[input] deadzone`, `[data] dir`, `[keys]` rebinds). Volumes go into
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
- Not done: game speed (`GameSpeedRules` is not bridged), Plugins, About, the
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
Not drawn yet (no bridge data): target ship silhouette, shïp subtitle + govt code, IFF
colours, per-commodity cargo rows, radar static.

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
