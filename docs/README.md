# Documentation

Start with the [root README](../README.md), then [CHARTER.md](CHARTER.md) for
what the project is and isn't.

- Does something work? [STATUS.md](STATUS.md). It is the only doc that tracks
  status.
- What's next? [ROADMAP.md](ROADMAP.md).
- How is the code laid out? [ARCHITECTURE.md](ARCHITECTURE.md).
- How do I add my game data? [GET_THE_DATA.md](GET_THE_DATA.md).

## Kinds of document

| Kind | Meaning |
|---|---|
| Reference | How something works today. If it disagrees with the code, the doc is wrong. |
| Spec | What the original game does, from the decompiled executable, the Nova Bible and real game data. Lives in [reverse-engineering/](reverse-engineering/README.md). |
| Plan | Something not built yet. |
| Charter | The goal and the rules everything else follows. |

## Index

Direction

- [CHARTER.md](CHARTER.md): the goal, fidelity first, bring your own data.
- [STATUS.md](STATUS.md): what works, how closely it matches, what's left.
- [ROADMAP.md](ROADMAP.md): what's next.

How it's built

- [ARCHITECTURE.md](ARCHITECTURE.md): modules and the engine decision.
- [DATA_FORMAT.md](DATA_FORMAT.md): container formats, resource types, sprite
  encoding.
- [GET_THE_DATA.md](GET_THE_DATA.md): supplying your own copy of EV Nova.

Game systems

- [AI.md](AI.md): NPC AI and spawning.
- [MISSIONS.md](MISSIONS.md): missions, `crön` events, control-bit scripting.
- [SHIP_SYSTEM.md](SHIP_SYSTEM.md): hull plus outfits into the ship you fly.

Platforms and features

- [CONTROLS.md](CONTROLS.md): controllers and touch.
- [TVOS.md](TVOS.md): Apple TV.
- [ICLOUD_SYNC.md](ICLOUD_SYNC.md): syncing imported game data.
- [MULTIPLAYER.md](MULTIPLAYER.md): host-authoritative co-op.
- [GODOT_LAYER.md](GODOT_LAYER.md): the Linux/Windows frontend.

Plans

- [MODERNIZATION.md](MODERNIZATION.md): optional extras over the original.
- [MOBILE_AND_PLUGINS.md](MOBILE_AND_PLUGINS.md): launcher and plug-in
  management.
- [PLUGIN_TOOLKIT.md](PLUGIN_TOOLKIT.md): planned plug-in editor and HD extensions.
- [EDITOR_AND_PLUGINS_SCOPE.md](EDITOR_AND_PLUGINS_SCOPE.md): resource and pilot
  editing.

Specs of the original game

- [reverse-engineering/](reverse-engineering/README.md), including
  [FIDELITY_PLAN.md](reverse-engineering/FIDELITY_PLAN.md), the item-by-item
  comparison with the original executable.

## Conventions

- The code is the authority for reference docs. When they drift, fix the doc.
- Status lives only in STATUS.md, so docs don't disagree about the same feature.
- Avoid dates in prose. Git has the history.
- Mark guesses as guesses.
