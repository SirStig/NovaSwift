# Roadmap

What's next, roughly in order. For what already works, see
[STATUS.md](STATUS.md). For why, see [CHARTER.md](CHARTER.md).

## Now

### Close out the fidelity plan

[FIDELITY_PLAN.md](reverse-engineering/FIDELITY_PLAN.md) has 179 items. All 179 are done, built and tested, including the 16 reopened after a later read of the executable and the 2026-10-13 closing pass; the grid reads 671 of 671. What's left:

- The pieces still deferred in [STATUS.md](STATUS.md): the gate hold for mission
  ships (AI-12), the jump-engage countdown (FL-23), and decompiling the map's
  Tab/backslash handlers to confirm the UI-15 inference.
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

In public beta: v1.0.0-beta.1 (2026-10-14) ships for Linux x86_64 / Steam Deck, Windows x86_64 and macOS arm64; the earlier betas were played on real hardware on all three. The Windows and macOS builds are not code-signed or notarised. What remains: verify the auto-updater by updating an installed build from a signed release, finish the early desktop plug-in editor, bring HD graphics packs to the desktop build, and keep fixing what testers report. The row-by-row list is [GODOT_FIDELITY_GAPS.md](GODOT_FIDELITY_GAPS.md). The state table is in [STATUS.md](STATUS.md#linux-and-windows); the design is in [GODOT_LAYER.md](GODOT_LAYER.md).

### Multiplayer

Multiplayer is released: LAN, direct IP, public servers, the dedicated server (with IPv6), and Apple-to-desktop cross-play over ENet, where the Apple app hosts and joins. The official server, NovaSwift Official West, is running. Next: play Game Center sessions on real devices, give the Godot client auto-reconnect (the Apple app has it), add IPv6 to the server admin panel, promote the CloudKit schema for the public lobby list, finer PvP options, and handing authority over when the host drops without rebuilding the world. See [MULTIPLAYER.md](MULTIPLAYER.md).

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
