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

### Godot frontend for Linux and Windows

Sound, the galaxy map, outfitter, shipyard, bar and mission board, saving, the
story runtime, then packaged builds. Developed in parallel; it doesn't block the
Apple builds. See [GODOT_LAYER.md](GODOT_LAYER.md).

### Multiplayer

Wider device testing, finer PvP options, and handing authority over when the
host drops. See [MULTIPLAYER.md](MULTIPLAYER.md).

### Plug-in tooling

An in-app resource editor and pilot editor. Both need a write path in
`NovaSwiftKit`, which only reads today. Scoped in
[EDITOR_AND_PLUGINS_SCOPE.md](EDITOR_AND_PLUGINS_SCOPE.md).

### Optional extras

All off by default and never replacing the original:

- HD art and audio packs layered over the originals.
- An optional smarter AI behind the same seam as the original AI.
- More accessibility options.

See [MODERNIZATION.md](MODERNIZATION.md).

## Always

- New behaviour that differs from the original goes behind an Enhancement,
  off by default.
- No hardcoded game data in the play loop.
- No game data in the repo. Base data stays user-supplied.
- No decompiled code in the repo. Specs only.
