# Roadmap

Milestones are ordered so each produces something demonstrable and de-risks the
next. "Demo" = a concrete thing you can see/run.

## M0 — Foundation ✅ (in progress)
- Repo structure, README, license, `.gitignore` (no game data committed).
- Research locked: data format, engine decision, legal model.
- `docs/DATA_FORMAT.md`, `docs/ARCHITECTURE.md`, this roadmap.
- Fetch reference repos + a **free total-conversion plug-in as a test fixture**.

## M1 — Read the data (the load-bearing milestone) ✅
Swift `EVNovaKit` container layer complete:
- ✅ `ClassicResourceFork` parser (resource-fork + `.ndat`; big-endian).
- ✅ `RezContainer` parser (the `BRGR` Rez format modern community plug-ins use).
- ✅ `ResourceFile` format auto-detection; `FourCharCode` with correct Mac Roman
  handling of accented type codes; plug-in override chain (`overlay`).
- ✅ `evnova-extract` CLI (`types` / `list` / `info`) + hermetic unit tests.
- ✅ **Verified on real data:** reads The Frozen Heart TC — 38 `shïp`, 81 `oütf`,
  41 `wëap`, 191 `sÿst`, 205 `spöb`, etc.
- ⏭ *Remaining:* decode individual resource *bodies* into typed structs
  (`shïp`/`oütf`/`wëap`/`sÿst`/`spöb` field layouts) — starts M1.5, overlaps M2.

## M2 — See the art 🟡 (rlëD done)
- ✅ `rlëD` RLE decoder → `SpriteSheet` (RGBA) → `CGImage`/PNG. Verified: real
  Nova ship sprites (24–180px, 36–384 frames) decode pixel-perfect; colour is
  1-5-5-5 (confirmed, not 565). Hermetic unit tests + `evnova-extract sprites`.
- ⏭ `rlë8` (8-bit palettised) decoder; `PICT` decoder (planet/UI art); wire
  `spïn`/`shän` so a sprite's frame geometry & rotation count are read from data
  rather than inferred.

## M2.5 — Plug-in library & data loading ✅
- ✅ `GameLibrary`: discover base resource files + plug-in bundles (folders or
  loose `.rez`/`.ndat`), auto-classify (total conversion / patch / gameplay),
  and merge base + **enabled** plug-ins into one `ResourceCollection` via the
  `(type,id)` override chain. `PluginBundle` is Codable (persistable enabled set).
- ✅ `evnova-extract library <base> <plugins>` shows the override effect.
- ✅ Verified on the full free catalog (12 plug-ins/TCs incl. **ARPIA2**,
  Polycon, Frozen Heart): base 8,362 → 11,585 resources with all enabled.
- ✅ Mobile/launcher/plug-in design captured in `docs/MOBILE_AND_PLUGINS.md`.

## M3 — Fly a ship
- SwiftUI + SpriteKit skeleton on iOS & macOS.
- Starfield, one ship sprite cycling its rotation frames, Newtonian thrust/turn.
- Touch controls (iPad) + keyboard (Mac).
- **Demo:** fly a ship around an empty system on device/simulator.

## M4 — A living system
- Load a `sÿst`: planets (`spöb`), asteroids, other ships (`düde`/`flët`) with basic AI.
- Radar/HUD, target selection, hyperspace jump between systems, galaxy map.
- **Demo:** jump across a few systems; NPCs fly around.

## M5 — Interaction loop
- Land on planets: spaceport, commodity trading (economy), outfitting, shipyard.
- Weapons + combat + shields/armor + damage + explosions (`bööm`).
- Save/load pilot files.
- **Demo:** buy a ship, outfit it, trade for profit, win a dogfight.

## M-Launcher — Menu, settings & mobile controls (parallel track)
See `docs/MOBILE_AND_PLUGINS.md`.
- SwiftUI launcher: Play/Continue/New Pilot, Scenario+Plug-in toggles, Settings,
  Import Data, About/Legal.
- `ControlIntent` input abstraction; touch scheme (turn/thrust/fire zones,
  tap-to-target), MFi/controller, keyboard — all feed the same intents.
- Settings model (controls/graphics/audio/gameplay/accessibility), persisted.
- **Base-data import flow** (BYO owned data via Files/share-sheet/AirDrop) — the
  mobile answer to "no drop-in plug-in folder"; plug-ins ship prebundled + toggle.

## M6 — Story
- Mission engine (`mïsn`): bar missions, cargo/escort/combat, `crön` background
  events, `përs` characters, `dësc` text, control-bit logic.
- Full plug-in / total-conversion loading & override chain.
- **Demo:** play the opening EV Nova storyline; load a TC (e.g. Polycon).

## Cross-cutting (ongoing)
- Test fixtures from freely-distributed plug-ins; golden-file tests vs `evnova-utils` dumps.
- On-device data import flow (user brings their EV Nova data).
- Performance: texture atlasing, culling; drop to Metal where SpriteKit limits.
