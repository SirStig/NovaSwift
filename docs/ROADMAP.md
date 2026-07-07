# Roadmap — faithful full port

**Goal:** reproduce EV Nova **as closely as possible** on a modern engine for
iOS / iPadOS / macOS — the original's feel, interface, controls, systems, AI,
missions and story — driven entirely by the **user's own game data** (bring your
own data; nothing copyrighted is bundled). Modern upgrades (resolution, touch,
controllers, quality-of-life) layered on top, but fidelity first.

This is a large, multi-phase effort. Status below is honest about what actually
works vs. what is stubbed.

## Done (foundation)
- ✅ **Data layer** (`EVNovaKit`): classic resource-fork / `.ndat` / `BRGR .rez`
  containers; plug-in override chain; typed decoders (shïp/oütf/wëap/sÿst/spöb/
  spïn/shän); `rlëD` sprite → texture. Reads the full real game.
- ✅ **Plug-in library**: discover/classify/enable-disable; bundled catalog + import.
- ✅ **Engine** (`EVNovaEngine`): Newtonian flight, multi-source input intents.
- ✅ **App shell**: multiplatform Xcode app, launcher, settings, game scene with
  real ship sprites + starfield + exhaust; touch/keyboard/mouse/controller input.

## Now (fidelity pass)
- 🔨 **Authentic controls**: full rebindable keybindings matching EV Nova's
  scheme; mouse used the way the original does (no auto-follow steering);
  full controller + touch. → `docs/CONTROLS.md`.
- 🔨 **UX correctness**: macOS title-bar/traffic-light safe area; fixed Settings/
  About layouts; **loading screens**; launcher visually distinct from game.
- ⏭ **Authentic UI from the user's assets** (the big one): decode `PICT` and the
  interface resources and render the **real EV Nova HUD, status bar, radar,
  menus and landing screens** from the player's own data — not our placeholder
  HUD. Includes the original **main menu** (toggle: modern launcher ↔ authentic).

## The full game (phased)
1. **Systems & space**: load a `sÿst`, place `spöb` planets/stations (real sprites),
   asteroids, the star background; hyperspace **jump** between systems; galaxy **map**.
2. **Interaction**: **land** on planets → spaceport, **commodity trading**/economy,
   **outfitting**, **shipyard**; save/load pilot files (`.plt`).
3. **Combat & ship system** — ✅ *core built* (`docs/SHIP_SYSTEM.md`): the full
   ship system — hull + **outfit** aggregation (`oütf` → effective stats), real
   shields/armor + recharge, **fuel** (100/jump) + hyperjump/afterburner drain,
   **cargo/storage**, resolved **weapon loadouts** with reload/ammo, projectiles/
   beams and shield-then-armor damage. Driven entirely from the user's data
   (`evnova-extract ship`/`outfit`), unit-tested, and surfaced on the HUD. ⏭ still
   to add: `bööm` explosion art, per-weapon `snd `, ion/heat/cloak simulation.
4. **AI** — ✅ *core built* (`docs/AI.md`, `EVNovaEngine`): NPC ships spawned from
   real `düde`/`flët`/`sÿst` tables, government (`gövt`) class-based standings &
   relations, warship patrols, trader travel + jump-out, escorts adopting a
   flagship's target, flee-when-outmatched, and real weapon combat
   (projectiles/beams, shield/armor, deaths). Validated on the real game via
   `evnova-extract ai` and unit-tested. ⏭ still to add: hailing/bribing/boarding,
   distress calls & reinforcements, disabling/plundering, `përs` named captains.
5. **Missions & story** (`mïsn`): bar missions, cargo/escort/combat/deliver,
   `crön` background events, `përs` characters, control bits, `dësc` text,
   ranks (`ränk`), the full main storyline(s).
   - 🔨 **Runtime built** (`EVNovaStory` module): verified `mïsn`/`crön`/`përs`/
     `ränk`/`dësc`/`STR#` decoders (checked against the real 791 missions); the
     NCB control-bit scripting engine (TEST + SET); mission availability →
     accept → objective tracking → completion + rewards; `crön` events on the
     galaxy clock; ranks/salary; `Codable` pilot save-state. Plugs into the rest
     of the game via the `GameServices` protocol (spawn ships, play sound, show
     text, swap hull) — a logging stub runs it headless today. Validated on real
     data via `evnova-extract story`/`mission`/`missions`; unit-tested. See
     `docs/MISSIONS.md`. ⏭ still to wire: special-ship spawning/kill-reporting to
     combat/AI, `përs` placement, `dësc` art to the UI.
6. **Audio**: `snd ` sound effects, music; **PICT** planet/landing/mission art;
   `ïntf` interface colors; `STR#`/`dësc` all text.
7. **Full options**: every EV Nova setting, difficulty, plus modern graphics/audio/
   accessibility; complete keybinding & mouse config; controller remapping.
8. **Plug-ins & tooling**: prebundled catalog + **user-installed plug-ins where supported**
   (desktop filesystem folder + mobile import), with load-order/override UI; an **in-app
   resource editor** (Mission Computer / ResForge-class: edit all game data, author new
   plug-ins, full sprite/PICT rendering) and **save-game (pilot) editing**. Requires a new
   *write path* in `EVNovaKit` (container serializers + per-type encoders). Scoped in
   `docs/EDITOR_AND_PLUGINS_SCOPE.md`.

## Cross-cutting
- Fidelity checks against the original behavior; golden-data tests.
- Performance (atlasing, culling); drop to Metal where SpriteKit limits.
- The base game data is always **user-supplied**; only original code + our own
  art (icon, placeholder HUD) ship in the repo.
