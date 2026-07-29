# Roadmap

What's next, in priority order. For what already works, see
[STATUS.md](STATUS.md); for why any of it matters, see [CHARTER.md](CHARTER.md).

**Sequencing principle:** a feature that isn't wired doesn't exist for the
player. Wiring something that's already built beats starting something new.

## Now

### 1. AI, spawning and flight fidelity

The most visible remaining difference between this port and the original — and
the hardest, because EV Nova's AI was never open-sourced and there was nothing to
copy. This is quality-of-reconstruction work, not a missing feature.

- **Spawn cadence and density** (`Spawner.swift`). The ambient trickle toward
  `sÿst.AvgShips` is a heuristic. Tune it toward the original's real arrival
  rhythm and ship mix so traffic stops feeling too even.
- **Flight smoothness** (`AIBrain.swift`). Remove the wobble and overshoot in the
  hand-tuned turn/thrust steering so NPC flight reads as naturally as the
  original's.
- **Behaviour edge cases.** Implement the mission `ShipBehav` case that currently
  falls through to normal AI, and tighten the engagement/disengagement
  transitions.

Details in [AI.md](AI.md).

### 2. Junk and `öops` trading

The last corner of the economy. Both decoders work and nothing calls them.
Implement `öops` price disasters first, then junk trading — the design is already
written up in
[JUNK_OOPS_DESIGN.md](reverse-engineering/JUNK_OOPS_DESIGN.md), building on
[ECONOMY.md](reverse-engineering/ECONOMY.md).

Finishing this also unblocks `përs.showsDisasterInfo` and `öops.isNewsOnly`,
which have nothing to report until disasters exist.

### 3. Save format decision

Keep the native JSON `PlayerState`, or move to the built-but-unused
`PilotSave`/`CombatRating` classic-archive encoder. Pick one and delete the other
path.

## Next

### Combat and interaction depth

Deeper hailing and bribing, distress calls and reinforcements, guided-weapon
lock-tone and lock-loss nuance, and per-weapon `snd ` coverage. Named `përs`
captains, their hail quotes, link-missions and grudges are done; what's left is
the negotiation nuance around them.

### Audio and text coverage

Full `snd ` sound-effect and music coverage, and `STR#`/`dësc` text everywhere a
string is currently hardcoded.

### Options and accessibility

Every EV Nova setting plus difficulty, with modern graphics, audio and
accessibility options layered on top — opt-in, per the charter.

### Plug-in tooling

Load-order and override UI polish, then an in-app resource editor
(Mission Computer / ResForge class) and pilot editing. Both depend on a **write
path** in `NovaSwiftKit`, which today only parses. Scoped in
[EDITOR_AND_PLUGINS_SCOPE.md](EDITOR_AND_PLUGINS_SCOPE.md).

### Godot frontend

The Linux/Windows port in `godot/` runs on the same portable Swift engine.
Flight, HUD and landing/launch are wired; the galaxy map, spaceport screens and
story runtime are next. Developed in parallel — it doesn't gate anything above.
See [GODOT_LAYER.md](GODOT_LAYER.md).

## Ongoing

- **Fidelity checks** against original behaviour, backed by golden-data tests.
- **No hardcoded data in the play loop.** A charter anti-goal. Audit for
  placeholder data leaking into shipping screens.
- **Performance.** Atlasing and culling; drop to Metal where SpriteKit limits us.
- **Legal posture.** Base game data stays user-supplied. Only our own code and
  art ship in this repo.
