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
> Last verified: 2026-07-08 (audit of `main` through commit `029ec8c`, plus
> in-flight uncommitted work called out explicitly below).

## The headline

We have a **real, connected vertical slice** — flight, combat/AI, navigation,
and the spaceport economy all run on the player's real data, and since the
last audit the game has gained real stakes on the *travel* side: jumps now
cost fuel, target-lock is real, and combat has live ionization and odds-based
AI decisions. The remaining user-facing gap has narrowed to one thing above
all others: **the mission/story campaign still doesn't run in the app.** The
Mission BBS has a button and a window now, but it's a placeholder — you can
fly, fight, trade, jump (and now run dry on fuel), but you still can't play
the story, lose your ship, or pay for repairs.

## Wired ✅ (the player experiences this today)

| System | How it's wired | Key seam |
|---|---|---|
| **Flight sim** | `GameScene.update` drives `World.step` on the player's real hull+outfit stats | `GameScene.swift:243`, `World.swift:325` |
| **NPC spawning + AI + combat** | `GameSession.makeWorld` wires Galaxy → Diplomacy → Spawner → AIBrain → Combat; NPCs spawn from real `düde`/`flët`, fight, take real damage | `GameSession.swift:41` |
| **Ionization** | Weapon `wëap.Ionization` charges `Ship.ionCharge` in live `World.step`; past `IonizeMax` the ship can't move (`controllable = !isIonized`) or fire (`cantFireWhileIonized`) | `World.swift:330-333,542` — real physics, but **no HUD indicator** yet, so the player can't see their own ion charge building |
| **Combat odds / armor-disable AI** | `AIBrain.power(_:)` drives odds-based flee/press decisions from live `combatStrength`/`shieldFraction`; disabled-hulk transition on armor loss | `AIBrain.swift:169`, `World.swift:684` — **NPC-only**: the disable path is explicitly gated `!ship.isPlayer`, so the player ship can never be disabled this way (ties to the player-death gap below) |
| **Target-lock** | Real `selectNearestTarget`/`selectNearestHostile`/`cycleTarget`/`clearTarget`, with an authentic HUD target readout and on-screen lock brackets | `GameScene.swift:533-560`, `AuthenticHUDView.swift:61` |
| **HUD + radar** | Live ship state (shield/armor/fuel/cargo/heading), real planet + NPC blips with real hostility color; authentic status bar from `ïntf` + backdrop PICT | `GameScene.swift:543`, `AuthenticHUDView.swift` |
| **Galaxy map + navigation + fuel-gated jumps** | Real `sÿst` coords/links, BFS course plotting; `jumpAlongRoute()` calls `consumeJumpFuel()` gated by `canAfford(hops:)` against the ship's real tank — jumps are no longer free or instant | `NavigationModel.swift:90-91`, `GameContainerView.swift:413` |
| **Landing** | Range/speed-gated `attemptLand()` → `SpaceportView` | `GameScene.swift:58,298` |
| **Spaceport economy + mission-gated item locking** | Trade / Outfitter / Shipyard use real prices and mutate a persistent credit/cargo/outfit balance saved to disk; outfits/ships the pilot hasn't unlocked (via `oütf.contribute`/`require`/`availBits`) are genuinely locked, not just hidden | `SpaceportScreens.swift`, `PilotStore.swift:105`, `ItemLocking.swift` |
| **Plug-in store** | In-app catalog browsing + download/install via `EVNovaPluginStore` (new library, backed by ZIPFoundation) | `Launcher/PluginsView.swift:28` → `Store/PluginStoreView.swift` |
| **Pilot save history** | `PilotArchive` backups + `PilotRoster` history; "Load Earlier Save" restores a prior snapshot | `PilotListView.swift:85-94` |
| **Main menu** | Real PICT/rlëD assets at authentic `cölr` coordinates | `AuthenticMainMenuView.swift:32` |
| **Data layer** | Resource-fork/`.ndat`/`.rez` parsing, plug-in override chain, typed decoders, sprite decoding — reads the full real game | `EVNovaKit` (`NovaGame` used across the app) |

## Built, not wired 🟡 (exists + tested, but the app never runs it)

**This is still the project's biggest gap.**

| System | What's built | Why the player never sees it |
|---|---|---|
| **Mission/story runtime** | `StoryEngine` (mïsn/crön/NCB advancement), `NCBSet` (control-bit mutation), mission availability→accept→track→complete→reward | App never instantiates `StoryEngine` for play — zero references to `StoryEngine(` anywhere in `app/EVNova`. Only `StorylineAnalyzer` runs it **read-only** to compute a static guide. The new Mission BBS window (below) renders on top of nothing. |
| **`GameServices` seam** | Protocol the story engine uses to tell the UI to offer missions / show text / spawn ships | **No app type conforms to it.** Only `LoggingGameServices` (`Sources/EVNovaStory/GameServices.swift:85`, used by the CLI) implements it. This is still the missing plug. |
| **Pilot save format** | `PilotSave`, `CombatRating` (classic-style archive fields) | App persists `PlayerState` as custom JSON instead (`PilotStore.swift`); the classic-archive encode path is unused by the app (though `PilotArchive`'s *backup/restore* mechanics are now used — see wired table). |
| **Pilot creation** | `PilotFactory` builds a pilot from a `chär` scenario | Used only by CLI (`main.swift:305`) + tests. `AppModel.startNewPilot()` exists but has **zero call sites** in the app. |
| **Game calendar** | `GameDate` in-game date math | No app reference. |
| **Story guide UI** | `StoryGuideView`, `StorylineBrowserView`, `StoryGuidePresenter`, `StoryGuideModel` (in `app/EVNova/Story/`) | Not presented by any screen; also carries hardcoded sample data. Orphaned. |

## Missing / shells ❌ (not built, or placeholder only)

| Gap | Detail |
|---|---|
| **Missions & BBS in-game** | The hub now has a real Mission BBS button and a window rendered on the authentic frame PICT 8505, but its content is a hardcoded placeholder ("No missions available at this time.") — it isn't backed by `StoryEngine` yet. In-game "Mission Log" is still a hardcoded "coming soon" alert (`GameMenuView.swift`). |
| **Player death / stakes** | Nothing checks player `armor <= 0`; the NPC disable/destroy path is explicitly `!ship.isPlayer`-gated. No game-over, no respawn. Player is immortal. |
| **Repair economy** | Landing/ship-rebuild resets shields/armor/fuel to full for free — still a free full heal, no paid mechanic. (Note: uncommitted WIP is adding a separate *paid ally-assistance* flow — hailing a friendly ship for an in-flight fuel/repair transfer — which is a different feature from spaceport repairs and not yet merged.) |
| **Targeting → weapon-lock nuance** | Target-lock itself is now wired (see above); guided-weapon lock-tone/lock-loss and point-defense-vs-guided interactions are the remaining depth items, tracked in `docs/AI.md`. |
| **New Pilot / multi-pilot UI** | `startNewPilot()` (reset+reroll) is still never called. Save history/restore now works, but there's no multi-pilot selection UI — all three main-menu save buttons resume the same single save. |
| **Orphaned data** | `PersRes` (`përs` named NPCs) is parsed but has zero consumers anywhere. |

## Priority implication

Per [`CHARTER.md`](CHARTER.md), **a feature that isn't wired does not exist for
the player.** The highest-leverage work is therefore not building new systems —
it is:

1. **Wiring the mission/story runtime** into the live loop (an app-side
   `GameServices` conformer + `StoryEngine` in `GameScene`/`AppModel`, and
   making the now-existing Mission BBS window actually show live missions
   instead of a placeholder). This is still the single biggest "make it feel
   like EV Nova" move.
2. **Closing the remaining stakes gaps** — player death/game-over and paid
   repairs are the two big glaring ones left (fuel and targeting are done).
3. **Pilot management** — real New Pilot reset and a multi-pilot selection UI
   (save/restore itself now works).

See [`ROADMAP.md`](ROADMAP.md) for the sequenced plan.
