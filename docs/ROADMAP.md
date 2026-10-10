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
nobody has to start over.

- Windows EV Nova CE `.plt` files. The format is known from the decompiled
  loader and writer: the data is stored in blocks XORed with a fixed key.
- Classic Mac EV Nova pilots, which keep the same data in the resource fork.
  Accept them as plain files, MacBinary or AppleDouble.
- Every saved field mapped across: date, credits, ship and name, outfits and
  ammo, cargo, escorts, active missions, control bits, explored systems, the
  per-system legal record, ranks, combat rating, crön, stellar and përs state,
  nickname and Strict Play. Anything without a counterpart is reported.
- Pilots that use plug-in content load with a warning if that plug-in isn't
  installed.
- An "Import EV Nova Pilot" button on the Pilots screen that shows what will be
  imported before creating the pilot. The original file is never changed.
- Tested by round-tripping synthetic pilots through the original's own save
  code in the emulator.

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
- An optional HD layer beside any plug-in: high-resolution sprites, 3D models
  (shown in 3D or baked into classic sprite sheets), better audio and music,
  and HD landing art. Gameplay never changes, and plain plug-ins still work in
  the original game.
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
