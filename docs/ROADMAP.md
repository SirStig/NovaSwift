# Roadmap

What's next, roughly in order. For what already works, see
[STATUS.md](STATUS.md). For why, see [CHARTER.md](CHARTER.md).

## Now

### Close out the fidelity plan

[FIDELITY_PLAN.md](reverse-engineering/FIDELITY_PLAN.md) has 179 items. 163 are done. 16 were reopened after a later read of the executable: OS-06, EC-04, EC-05, EC-07, EC-09, EC-10, EC-11, EC-12, EC-25, EC-26, OS-08, AI-44, UI-06, MS-19, EC-27, EC-28. All 16 are now implemented in code (both apps) and awaiting build and test; their headings stay **OPEN** until then. What's left:

- Build and test those 16 items, then flip their headings to DONE and regenerate the grid. [STATUS.md](STATUS.md) lists them. EC-09 adds a `stockBank` pilot-save field.
- Build and test the closing-pass work that is written but not yet built (status-line
  sentences and hint chain, Player Info Tab cycling, target-cycling order and
  AI-state filter, folding hulls, `përs` quote gates, the Apple-app fixes listed
  in STATUS.md), then the pieces still deferred there (gate hold for mission
  ships, jump-engage countdown).
- The plan's open questions: run the remaining routines in the emulator
  (perishable cargo decay, the legal-record flood split, outfitter cancel and
  the day flag, bar re-offer timing) and the static reads (engine glow states,
  NPC gravity, asteroid frame seed).
- The maintainer decisions at the end of the plan: presentation defaults,
  macOS key bindings, autosave details, Strict Play scope.
- More oracle-backed tests. Many AI behaviours are covered by unit traces, not
  emulator output yet.

### Hardening

Bug fixes and performance as more people play on more devices. Testers can send
a diagnostics bundle from Settings ▸ Support ▸ Report a Bug.

## Next

### Pilot converter

Import pilots from the original game and turn them into NovaSwift saves, so
nobody has to start over. Mostly done; the details are in
[reverse-engineering/PILOT_IMPORT.md](reverse-engineering/PILOT_IMPORT.md).

Done:

- Windows EV Nova CE `.plt` files (XOR-obfuscated blocks, decoded from the
  original's loader).
- Classic Mac pilots from a plain resource-fork file, AppleDouble, MacBinary or
  (on macOS) the file's own resource fork.
- Date, credits, ship and name, outfits and ammo, cargo and junk, fuel, escorts
  and their upgrade/sale marks, active missions (destinations, counters, cargo),
  the 10,000 control bits, explored and landed systems, the per-system legal
  record, ranks, combat rating, crön, disasters, destroyed and dominated
  stellars, përs kills and grudges, nickname, Strict Play.
- Content missing from the loaded data (usually a plug-in) gives a warning, not
  a failure.
- "Import EV Nova Pilot…" on the Pilots screen shows a summary with warnings and
  the fields that aren't carried over, then creates the pilot. The original file
  is only read.
- Tests use synthetic pilots written by the tests' own encoder.

Left:

- Mac pilots: the six padding bytes in each mission record come from the format
  notes and haven't been checked against a real Mac pilot. Windows is the
  reliable path.
- The tests don't run the original's saver in the emulator; only the cipher is
  checked against the original executable.
- No counterpart in NovaSwift yet: ship paint color, escort group-order
  commands, per-planet domination-day counters, the launched-fighter list, and
  mission accept dates (the original doesn't save them).

### Godot frontend for Linux and Windows

The frontend calls the shared engine and plays through on macOS. Built and tested on macOS: gate movies, map borders and markers, sound parity, brightness, About picture. Packages: macOS arm64 and Linux x86_64 (Steam Deck) are built and verified headless in containers; the Windows script is written and needs a Windows PC with Swift. The auto-updater ([UPDATER.md](UPDATER.md)) is built and not yet tested end to end. What remains, in order: build and test the 2026-10-13 closing pass (status-line text and travel hints, Player Info cycling, quick hyperjump in Godot, Key Settings, `.mov` title music, shot murk fog, folding hulls), run the packages on a real Steam Deck and a Windows PC, test the updater with a signed experimental release, and check flight visuals on a real GPU. The row-by-row list is [GODOT_FIDELITY_GAPS.md](GODOT_FIDELITY_GAPS.md). It does not block the Apple builds. The state table is in [STATUS.md](STATUS.md#linux-and-windows); the design is in [GODOT_LAYER.md](GODOT_LAYER.md).

### Multiplayer

Wider device testing, finer PvP options, and handing authority over when the
host drops. See [MULTIPLAYER.md](MULTIPLAYER.md).

### Plug-in toolkit

The goal: anything in the game can be changed or added by a plug-in, and
building one is easy. Classic plug-ins keep working in the original game; the
new abilities sit on top of them.

- **A plug-in editor**, a modern Mission Computer: every classic resource type,
  ship, galaxy and mission editors, validation against the original's rules,
  "test in engine", and export to Windows and Mac plug-in formats. It also
  handles the new HD art and 3D models: add them, preview them as the game
  will draw them, and pack them into the plug-in file.
- **HD art and 3D models.** Working now: high-resolution sprites and 3D models
  drawn into the classic sprite frames, with engine glow, lights and weapon
  flash, HD planets and HD ship pictures. Packs can sit beside a plug-in or
  inside its `.rez`, so an existing plug-in such as Arpia 2 can be repacked
  with HD art and still load in the original game. See
  [HD_PIPELINE.md](HD_PIPELINE.md). Nova Reimagined, a full graphics overhaul
  of the base game, is being built with it.
- **Live 3D.** Models drawn in real time with real lighting (nearby stars,
  weapon fire) instead of pre-rendered frames, for players who want it.
- **Expanded plug-ins.** New abilities the original format never had: changing
  the game's fixed rules and limits, scripted events and mission logic, new
  interface screens and HUD layouts, and custom effects and shaders. Each one
  is optional and ignored by the original game.
- Publishing to the plug-in store, a command-line tool, templates, example
  plug-ins and guides.

The plan is in [PLUGIN_TOOLKIT.md](PLUGIN_TOOLKIT.md).

### Optional extras

All off by default and never replacing the original:

- An optional smarter AI behind the same seam as the original AI.
- More accessibility options.

See [MODERNIZATION.md](MODERNIZATION.md).

## Always

- New behaviour that differs from the original goes behind an Enhancement,
  off by default.
- No hardcoded game data in the play loop.
- No game data in the repo. Base data stays user-supplied.
- No decompiled code in the repo. Specs only.
