# Status — the built-vs-wired connection map

> **Source of truth for what actually works.** Verified by tracing the running
> app (`app/EVNova/`) into the libraries (`Sources/`), not by reading library
> code in isolation. Definitions come from [`CHARTER.md`](CHARTER.md):
>
> - **Wired** — the running app drives it; the player experiences it.
> - **Built, not wired** — code exists and is tested, but the app never calls it
>   in the play loop. The player does **not** experience it.
> - **Missing** — not built, or a UI shell / "coming soon" placeholder only.
>
> Last verified: 2026-07-08 (audit of `main` working tree).

## The headline

We have a **real, connected vertical slice** — flight, combat/AI, navigation,
and the spaceport economy all run on the player's real data. The user-facing
gap is that **the systems that make it *EV Nova the game* — missions/story,
travel gates, and stakes — are either built-but-not-wired or missing.** You can
fly, fight, trade, and jump; you cannot yet play the story, run out of fuel, or
die.

## Wired ✅ (the player experiences this today)

| System | How it's wired | Key seam |
|---|---|---|
| **Flight sim** | `GameScene.update` drives `World.step` on the player's real hull+outfit stats | `GameScene.swift:243`, `World.swift:325` |
| **NPC spawning + AI + combat** | `GameSession.makeWorld` wires Galaxy → Diplomacy → Spawner → AIBrain → Combat; NPCs spawn from real `düde`/`flët`, fight, take real damage | `GameSession.swift:41` |
| **HUD + radar** | Live ship state (shield/armor/fuel/cargo/heading), real planet + NPC blips with real hostility color; authentic status bar from `ïntf` + backdrop PICT | `GameScene.swift:543`, `AuthenticHUDView.swift` |
| **Galaxy map + navigation** | Real `sÿst` coords/links, BFS course plotting, jump rebuilds destination with fresh NPCs | `NavigationModel.swift:45`, `GameContainerView.swift:160` |
| **Landing** | Range/speed-gated `attemptLand()` → `SpaceportView` | `GameScene.swift:58,298` |
| **Spaceport economy** | Trade / Outfitter / Shipyard use real prices & mutate a persistent credit/cargo/outfit balance saved to disk | `SpaceportScreens.swift`, `PilotStore.swift:105` |
| **Main menu** | Real PICT/rlëD assets at authentic `cölr` coordinates | `AuthenticMainMenuView.swift:32` |
| **Data layer** | Resource-fork/`.ndat`/`.rez` parsing, plug-in override chain, typed decoders, sprite decoding — reads the full real game | `EVNovaKit` (`NovaGame` used in 13 app files) |

## Built, not wired 🟡 (exists + tested, but the app never runs it)

**This is the project's biggest gap. All of this is fully implemented and
exercised only by the `evnova-extract` CLI and unit tests.**

| System | What's built | Why the player never sees it |
|---|---|---|
| **Mission/story runtime** | `StoryEngine` (mïsn/crön/NCB advancement), `NCBSet` (control-bit mutation), mission availability→accept→track→complete→reward | App never instantiates `StoryEngine` for play. Only `StorylineAnalyzer` runs it **read-only** to compute a static guide. |
| **`GameServices` seam** | Protocol the story engine uses to tell the UI to offer missions / show text / spawn ships | **No app type conforms to it.** Only `LoggingGameServices` (in the CLI) implements it. This is the missing plug. |
| **Pilot save format** | `PilotSave`, `PilotArchive`, `CombatRating` (classic-style archive) | App persists `PlayerState` as custom JSON instead (`PilotStore.swift`). Archive path never called by app. |
| **Pilot creation** | `PilotFactory` builds a pilot from a `chär` scenario | Used only by CLI (`main.swift:305`) + tests. |
| **Game calendar** | `GameDate` in-game date math | No app reference. |
| **Story guide UI** | `StoryGuideView`, `StorylineBrowserView`, `StoryGuidePresenter`, `StoryGuideModel` (in `app/EVNova/Story/`) | Not presented by any screen; also carries hardcoded sample data. Orphaned. |

## Missing / shells ❌ (not built, or placeholder only)

| Gap | Detail |
|---|---|
| **Missions & BBS in-game** | BBS frame asset exists (id 8505) but there is no mission BBS view, no mission button in the spaceport hub, no live mission logic. In-game "Mission Log" is a hardcoded "coming soon" alert. |
| **Fuel-gated travel** | `consumeJumpFuel()` exists in the engine but is **never called**. Jumps are free, instant, and possible from anywhere. The "N JUMPS" HUD readout is cosmetic. |
| **Player death / stakes** | Engine defers player death "to the app"; the app does nothing. No game-over, no respawn. Player is immortal. |
| **Repair economy** | Landing rebuilds the ship at full shields/armor/fuel — a free full repair anywhere. |
| **Targeting** | No target-lock; player fires straight ahead only (NPCs target correctly). |
| **New Pilot / multi-pilot / Save-Load UI** | All three menu buttons resume the same single save; `startNewPilot()` (reset+reroll) is never called. Save/Load menu items are "coming soon" stubs. |
| **Orphaned data** | `PersRes` (`përs` named NPCs) is parsed but has zero consumers anywhere. |

## Priority implication

Per [`CHARTER.md`](CHARTER.md), **a feature that isn't wired does not exist for
the player.** The highest-leverage work is therefore not building new systems —
it is:

1. **Wiring the mission/story runtime** into the live loop (an app-side
   `GameServices` conformer + `StoryEngine` in `GameScene`/`AppModel` + a real
   mission BBS). This is the single biggest "make it feel like EV Nova" move.
2. **Closing the stakes gaps** (fuel consumption, player death, paid repairs) —
   small, glaring, fast wins.
3. **Pilot management** (real New Pilot reset, multi-pilot, save/load UI).

See [`ROADMAP.md`](ROADMAP.md) for the sequenced plan.
