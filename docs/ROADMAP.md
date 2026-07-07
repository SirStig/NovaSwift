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
3. **Combat**: weapons (`wëap`) firing + projectiles/beams, shields/armor/damage,
   `bööm` explosions, energy/fuel, afterburners, ammo.
4. **AI (100%)**: NPC ships via `düde`/`flët`, government (`gövt`) standings &
   relations, fighters/escorts, fleeing/hailing/boarding, patrols, pirates,
   defense fleets — behaviors matching the original.
5. **Missions & story** (`mïsn`): bar missions, cargo/escort/combat/deliver,
   `crön` background events, `përs` characters, control bits, `dësc` text,
   ranks (`ränk`), the full main storyline(s).
6. **Audio**: `snd ` sound effects, music; **PICT** planet/landing/mission art;
   `ïntf` interface colors; `STR#`/`dësc` all text.
7. **Full options**: every EV Nova setting, difficulty, plus modern graphics/audio/
   accessibility; complete keybinding & mouse config; controller remapping.
8. **Plug-ins**: prebundled catalog + **user-installed plug-ins where supported**
   (desktop filesystem folder + mobile import), with load-order/override UI.

## Cross-cutting
- Fidelity checks against the original behavior; golden-data tests.
- Performance (atlasing, culling); drop to Metal where SpriteKit limits.
- The base game data is always **user-supplied**; only original code + our own
  art (icon, placeholder HUD) ship in the repo.
