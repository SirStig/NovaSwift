# Roadmap

What's next, roughly in order. For what already works, see
[STATUS.md](STATUS.md). For why, see [CHARTER.md](CHARTER.md).

## Now

### Close out the fidelity plan

All 177 items in [FIDELITY_PLAN.md](reverse-engineering/FIDELITY_PLAN.md) are
done. What's left:

- The deferred pieces listed in STATUS.md (hint chain, Player Info Tab cycling,
  map key cycling, gate hold for mission ships, jump-engage countdown).
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

Sound, the galaxy map, outfitter, shipyard, bar and mission board, saving, the
story runtime, then packaged builds. Developed in parallel; it doesn't block the
Apple builds. See [GODOT_LAYER.md](GODOT_LAYER.md).

### Multiplayer

Wider device testing, finer PvP options, and handing authority over when the
host drops. See [MULTIPLAYER.md](MULTIPLAYER.md).

### Plug-in toolkit

A full plug-in editor and HD extensions, so the community can build things the
original tools never allowed:

- An editor for every resource type, with ship, galaxy and mission editors,
  validation against the original's rules, "test in engine", and export to
  Windows and Mac plug-in formats.
- An optional HD layer beside any plug-in. **Working now:** high-resolution
  sprites and 3D models rendered into classic sprite frames, with effects, HD
  planets and HD ship pictures ([HD_PIPELINE.md](HD_PIPELINE.md)). **Next:**
  live 3D with real-time lighting, glTF import, better audio and music, and HD
  landing art. Gameplay never changes, and plain plug-ins still work in the
  original game.
- Publishing to the plug-in store, a command-line tool, templates and guides.

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
