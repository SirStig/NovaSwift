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

Either way, arrow keys / WASD fly the ship with the engine's real Newtonian
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
Y hail (Alt-Y nearest stellar), B board, F/V/C/Alt-C escort attack/hold/formation/
return, plus X defend and G panel because the original D/E are taken by the
port's WASD / Q-E layout; pad D-pad ← hail, → board. Known gaps: `pêrs`
LinkMission offers from a hail/board are not presented; the Escorts window has no
Upgrade/Sell (shipyard marks); Godot has no planet selection, so the nearest
stellar stands in for the selected planet; landing is not gated on a bribe yet.

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
   Not yet: the staggered NPC death-burst sounds (one bang per `shipDying`), a
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
   with snapping, D-pad next-system, A plot, Y add hop, B close. Not yet:
   hypergate/wormhole links on the map, the nebula art, system search, escorts
   and mission ships following a jump, jump sounds and the reduced-flashing
   option. **Pilot save/load works** (`NovaWorld`'s "Pilots & saves"
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
5. **Story runtime** — bring `NovaSwiftStory` across for missions/crons/NCB.
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
