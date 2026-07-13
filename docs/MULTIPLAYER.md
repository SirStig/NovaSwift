# Multiplayer — Design & Implementation Spec

Status: **Design (2026-07-13, rev 2)** — decisions made; implementation not yet started.

## Goal

Play alongside friends in a shared multiplayer session while **each player runs
their own persistent galaxy and pilot save**. You each fly freely through your
own game; when two or more players are in the **same star system**, that system
is synced 100% (all ships, combat, events) so you truly play together — help each
other, fight together, or fight each other. When you're in different systems,
nothing heavy is synced; you just each play your own game. The canonical "I'm
stuck, come help me" flow: your friend jumps to your system and drops in.

**Constraint: we host no servers.** Internet play uses Apple's Game Center
infrastructure (Apple runs matchmaking + relay). Local play uses the LAN
directly. We host nothing.

## Decisions

| Topic | Decision |
|---|---|
| **Model** | **Independent galaxies + per-system sync.** Every player always plays their own real save. Multiplayer is an overlay. No forced co-location — everyone roams freely. |
| **Co-located system** | If ≥2 players are in the **same** system, it's synced 100% — all ships, events, combat. One co-located player is that system's **authority**; others are clients for it. |
| **Separated systems** | No ship/combat/event sync. Only the lightweight **presence** layer (who's in which system) stays live. |
| **Joining an occupied system** | On jump-in, the joiner does a snapshot handshake with the system's authority, then renders its live world. A **short loading screen** here is acceptable. |
| **Authority** | Per-system and **dynamic**. First co-located player (or the lobby host if present) is authority; migrates to a remaining player if the authority leaves. |
| **Stakes** | Each player's own save always persists (they're in their own galaxy). `SessionRules` governs **inter-player interactions**: PvP damage real?, death real?, trades allowed, friendly fire. Presets from *Safe/sparring* → *Full stakes*. |
| **Interactions** | Co-op combat + PvP + shared missions + trade / item hand-off. |
| **Story / progression** | Shared world runs the **authority's** storyline/missions; **personal services** (outfitter, shipyard, re-arm/ammo, escort hiring, salary, rank, combat rating) resolve against each player's **own** save. NCB merges are **non-destructive & additive**: no overwrite, no passive inheritance — you only *gain* bits you **earn together**. |
| **Connection** | Game Center invite (internet) + direct join code (on Game Center) + local Wi-Fi (Multipeer). One `Transport` protocol, swappable backends. |

## The one hard technical truth

Peer-to-peer over the **internet** requires NAT traversal (hole-punching), which
requires a rendezvous/signaling server and often a TURN relay. We will not run
those. Apple's turnkey escape hatch is **Game Center (`GKMatch`)**: Apple runs
matchmaking *and* relay for free, up to 16 players in a match, with a real-time
send/receive transport.

- **Internet play ⇒ Game Center is the backbone.** Only "we host nothing, works
  over the internet" option on Apple platforms.
- **Direct join code** is layered on top of Game Center (a code resolves to a
  `GKMatch` via programmatic matchmaking), *not* a separate serverless internet
  path. A pure non-Game-Center code only works on a local network.
- **Local Wi-Fi ⇒ MultipeerConnectivity**, no infrastructure, lowest latency.
- **Prerequisite:** internet play needs Game Center enabled in App Store Connect
  + the `com.apple.developer.game-center` entitlement. Config, not code.

## Two-layer sync model

The whole design is two independent layers with very different rates and scopes.

### Layer 1 — Presence (always on, all players, low-rate)

Every player broadcasts, on each system change (and a slow heartbeat):

```
PresenceUpdate { playerID, name, currentSystemID, shipTypeHint, lastSeenTick }
```

Cheap (a few bytes per jump). It is the *only* thing synced when players are
apart. It powers:

- **Galaxy-map markers** — show where each friend is (see UI below).
- **Co-location detection** — when your `currentSystemID` matches another
  player's, Layer 2 engages for that system.

Broadcast to all peers (mesh via `GKMatch`); the lobby host may relay presence
as a star topology if mesh chatter grows at higher player counts.

### Layer 2 — System simulation sync (only co-located players)

Engages only among the players physically in one system. Host-authoritative
**per system**:

- One co-located player is the **authority** for that system. It owns the live
  `World` — NPC traffic, combat, projectiles, events, domination, defenses.
- Every other co-located player is a **client** for that system: streams its
  `ControlIntent` up, predicts its own ship locally, and renders the authority's
  streamed world (interpolating other ships/projectiles).
- **Alone in a system ⇒ you are trivially your own authority.** No networking,
  no clients — it runs exactly like single-player today.

Rates: input up ~30 Hz (unreliable), snapshots down ~20 Hz (unreliable, delta-
compressed), events + handshakes reliable.

### Dynamic authority

- **Assignment:** the first player in a system is its authority. If the lobby
  host is among the co-located players, it can hold authority for stability.
- **Join-in:** a player jumping into an occupied system requests a full snapshot
  from the current authority, loads it (short loading screen OK), then becomes a
  client for that system.
- **Handoff:** when the authority leaves a still-occupied system, authority
  migrates to a remaining co-located player. Because the sim is deterministic and
  that player already holds a full mirror, it **promotes its mirror to
  authoritative** and keeps simulating. A brief hiccup / loading is acceptable.
- **Empty:** when the last player leaves a shared system, it reverts to plain
  single-player for whoever enters next.

### Canonical world when co-located

Every player has their own galaxy, so *your* system X and *my* system X can
differ (different NPC spawns, domination state, economy, mission progress).
Default rule: **the authority's version of the system is canonical for that
shared encounter.** Visitors temporarily see and interact with the authority's X;
their own galaxy's X is untouched unless a `SessionRules` toggle says a specific
outcome carries back. This keeps co-location an *overlay*, not a merge.

## Why host-authoritative (not lockstep)

The engine is strongly deterministic (seeded `SplitMix64`, no wall-clock, no
ambient RNG — `Sources/NovaSwiftEngine/RNG.swift`), so lockstep is *possible*. We
don't use it: lockstep is fragile across join-in-progress and dynamic authority
handoff, and needs perfect fixed-tick sync (our loop is variable-`dt`, frame-
coupled to SpriteKit). Host-authoritative state-sync is simpler and robust, and
our render/sim split makes the client side cheap: the renderer only *reads* world
state and drains events, never mutates the sim (`World.swift:707-708`).

## UI features

1. **Minimap player blips + names.** When co-located, remote players are real
   ships in the authority's roster, so they appear on the minimap automatically.
   Give player ships a distinct blip color and a short name label. (Not shown when
   apart — they aren't in your system, which is correct.)
2. **In-world nameplate.** Render the player's name under their ship sprite in
   the main view. Presentation-only, reads the ship's control-source + name.
3. **Galaxy-map presence markers.** From Layer 1 presence, place a marker on each
   friend's current system. Must be **visually distinct from the mission marker
   and must not occlude it** — render as an offset avatar/ring (e.g. small
   pilot chip beside the system, layered under mission markers, with its own
   color per player). Drawn from `PresenceUpdate.currentSystemID`.

## Architecture

```
   Layer 1 (presence)  ── always on, all peers, ~1 msg per jump ──────────────┐
                                                                               │
   PlayerA @ Sys X (authority)      PlayerB @ Sys Y (alone, own authority)     │
        │  snapshot ▼   ▲ input          │  (no net traffic)                   │
        │             PlayerC @ Sys X (client of A)                            │
        └──────── Layer 2: Sys X synced 100% among {A, C} ───────────────────┘

   When B jumps X→X-of-A:  B ⇢ JoinSystem → A sends snapshot → B loads (short
   loading screen) → B becomes client of A.  Now {A, B, C} all synced in Sys X.
   If A then jumps away:   authority migrates to B or C (mirror promotion).
```

### Transport layer (new)

`protocol Transport` — connect / disconnect / send(channel, bytes) / receive
callback / peer lifecycle. Backends:

- `GameKitTransport` — `GKMatch` for internet (friend invite + join-code
  matchmaking). Reliable/unreliable → `GKMatch.SendDataMode`.
- `MultipeerTransport` — `MCSession` over Bonjour for same-network play.
- `LoopbackTransport` — in-process, for unit-testing full handshakes with no
  devices or entitlement.

Message framing, ordering, and channel semantics live in a `NetChannel`
abstraction (reliable: presence, handshake, events, trade; unreliable: input,
snapshots).

### Session & roles

- `NetSession` — owns the transport, the lobby role, the peer roster, the
  presence table (playerID → system), and `SessionRules`.
- `SystemNet` — per-occupied-system sync coordinator: tracks who's here, who's
  authority, and runs Layer 2 for this system. Created when a system gains a 2nd
  player; torn down when it drops below 2.

### Engine change: one → N externally-driven ships

Today `World` assumes exactly one externally-controlled ship (`player`, id 0,
single `World.intent`); all others are AI (`brain != nil`). Generalize:

- Add `enum ControlSource { case local; case remote(PeerID); case ai }` to
  `Ship`. AI = `brain != nil`; local + remote = `brain == nil`, intent from
  different sources.
- Replace single `World.intent` with per-ship intent — `World.intents:
  [EntityID: ControlIntent]` (id 0 = local player). In `World.step`, each
  `brain == nil` ship applies its intent (`fireWeapons` + `Ship.step`); AI keeps
  `brain.think`.
- Remote-player ships enter via the existing seam
  **`World.addNPC(_:arrival:)`** (`World.swift:830`) with `brain == nil`,
  `control == .remote(peer)`, built from the joiner's real loadout via
  `galaxy.makeLoadedShip(...)`. Nameplate + minimap color key off `control`.

This preserves the "player and AI are the same `ControlIntent` + `Ship.step`"
symmetry the engine already has (`World.swift:4-7`): a remote player is a ship
whose intent arrives over the wire.

### Message protocol

Presence (reliable, low-rate, all peers):
- `PresenceUpdate { playerID, name, currentSystemID, shipTypeHint }`

Co-located, Client → Authority (unreliable, ~30 Hz):
- `InputFrame { tick, seq, intent: ControlIntent }`

Co-located, Authority → Client (unreliable, ~20 Hz, delta-compressed):
- `WorldSnapshot { tick, ships: [ShipNetState], projectiles: [...], beams: [...],
  ackInputSeq }` — `ShipNetState` = id, control-source, name, position, velocity,
  angle, shield, armor, ionization, cloak, current-target, flags.

Reliable, co-located:
- `JoinSystem { pilotSummary, shipLoadout }` / `JoinAccept { sessionRules,
  systemID, worldSeed, initialSnapshot }`
- `AuthorityHandoff { systemID, newAuthority, tick }`
- `WorldEvent { ... }` — mirrors `World.drainEvents()` so clients fire correct
  SFX/VFX (arrivals, destructions, explosions, mission beats).
- `TradeOffer` / `TradeResult`, `ChatMessage`.

### Latency hiding (client side)

- **Own ship:** client-side prediction — apply local intent immediately, keep an
  input history, reconcile against the snapshot that acks each input seq (replay
  unacked inputs on correction).
- **Everyone else:** snapshot interpolation with a ~100 ms buffer; brief
  extrapolation on packet loss.

## Stakes / SessionRules

Because everyone plays their own galaxy, each player's own save always persists.
`SessionRules` governs only **inter-player interactions** while co-located:

```
struct SessionRules {
    var pvpDamageReal:   Bool   // damage from another player actually hurts your ship
    var deathReal:       Bool   // being destroyed by/near another player is real death
    var friendlyFire:    Bool   // co-op partners can hit each other
    var allowPvP:        Bool
    var allowTrade:      Bool
    var carryEncounter:  Bool   // do outcomes in an authority's system (kills, loot)
                                // carry back to a visitor's own galaxy
    // Presets: .safe (pvpDamageReal=false, deathReal=false — sparring),
    //          .fullStakes (all real), .custom
}
```

Host sets the preset/toggles when opening the lobby; each joiner sees and accepts
them. `.fullStakes` means your ship is your real ship — damage and death are real
in your own game; trades move real items between real saves.

## Persistence model

- No "working-copy save" and no forced save-merge — everyone is always in their
  own persistent galaxy.
- Interaction outcomes apply per `SessionRules` (damage/death real or not; trades
  move real items; `carryEncounter` decides whether kills/loot in an authority's
  system reach a visitor's own galaxy).
- The authority's galaxy is the canonical sim for a shared encounter; a visitor's
  own galaxy state elsewhere is never touched.

## Story, control bits (NCB) & the per-player services split

Principle: **the shared world runs the authority's storyline; personal
progression stays personal; nothing is ever overwritten; you can only *gain* — and
only by earning it together.** This resolves the "a more-progressed friend joins a
less-progressed host (or vice versa)" problem without merging or clobbering either
save.

Everything splits into two buckets by *what kind of thing it is*:

### A. Authority-driven — the shared, in-space world

Resolved against the **authority's** NCB / story state:

- Star-system setup: which NPCs/fleets spawn, spöb (planet) states, domination,
  stellar defenses, ambient traffic.
- Which missions / story beats are "live" in the shared world — everyone together
  experiences the authority's storyline while co-located.
- All physical, in-space, synced reality.

### B. Per-player — personal services (yours only, even at the authority's planet)

Resolved against **each player's own** save/NCB state, visible only to that
player:

- Outfitter inventory & shipyard availability (gated by that player's own NCBs /
  tech / rank / government status).
- Ammo / re-arm for their existing weapons.
- Escort hiring, salary, credits.
- Combat rating, ranks.

These are personal economy/UI interactions — you land, you shop. Two co-located
players landing on the same (authority-owned) planet each get an **independent
personal spaceport UI** driven by their own save. The planet's *identity and world
state* (which planet, its domination) is the authority's; the *shop contents* are
yours.

Rationale: a more-progressed player who joins a less-progressed host must still be
able to buy / re-arm / upgrade what their own story unlocked; a less-progressed
player must not be blocked or spoofed by the host's further-along state.

### NCB merge rules (strict)

1. **Non-destructive** — joining never clears or removes bits from anyone.
2. **No passive inheritance** — joining a more-progressed player does NOT copy
   their pre-existing bits to you, and joining a less-progressed one costs you
   nothing. Separate progress is untouched in both directions.
3. **Earn-together is additive** — bits SET by missions/events you actually
   participate in during shared play are unioned into each participating player's
   own NCB set. Progress made together counts for each of you.
4. Rewards (credits / outfits / ship) from shared missions follow `SessionRules`
   (e.g. `carryEncounter`).

**Accepted consequence:** a lagging player can acquire a later mission's bits
"out of order" relative to their own solo storyline (they earned it together).
This is intended. Guard only that story logic which hard-depends on an earlier
prerequisite bit **degrades gracefully** — a mission whose condition isn't met
simply won't fire for that player, rather than corrupting state.

### Engine mapping

- NCB state is per-pilot (each save's own bit-set). The design adds a **"which
  NCB context does this query use"** routing decision at the story/services seam:
  shared-world queries (system/spöb/mission-availability) resolve against the
  **authority's** bit-set; personal-service queries (outfitter/shipyard/rank/…)
  resolve against the **local** player's bit-set.
- Shared-mission bit-sets are applied **per participant** (set-union into each
  player's own bits), never a wholesale copy of the authority's set.
- Seam lives in NovaSwiftStory (NCB engine) + the spaceport/interaction layer +
  the `GameServices` bridge. Exact functions confirmed in "Key files & seams."

## Phasing

Each phase is independently demoable.

- **P0 — Netcode spine + presence.** `Transport` (+ `LoopbackTransport`,
  `MultipeerTransport`, `GameKitTransport`); `NetSession`; lobby/invite/join-
  code/local discovery; message framing + channels; **Layer 1 presence**.
  *Demo:* friends connect; each sees the others' live positions on the **galaxy
  map** as they jump around — no system sync yet.
- **P1 — See each other in a shared system (read-only).** Co-location handshake
  + `SystemNet`; authority streams its player ship; joiner renders a remote ship
  with **nameplate** + **minimap blip**. Proves Layer 2 wire + snapshot +
  interpolation + render-from-received-state.
- **P2 — Fly together.** Generalize `World` to N externally-driven ships; inject
  the joiner's ship via `addNPC`; client sends `InputFrame`, authority simulates
  + streams the roster; client predicts its own ship. *Actually playing together.*
- **P3 — Interact.** Combat/damage/event sync (co-op + PvP under `SessionRules`);
  shared-mission participation (guest ship counts toward the authority's mission
  triggers) with the per-player services split + additive NCB merge (see "Story,
  control bits (NCB) & the per-player services split"); trade / credit + item
  hand-off, rules-gated.
- **P4 — Robustness & polish.** Dynamic authority handoff; join-into-occupied-
  system loading screen; disconnect/rejoin; bandwidth tuning (delta compression,
  interest management); UI (lobby, invite, rules screen, in-game roster/chat,
  galaxy-map marker polish).

## Key files & seams (today)

- Sim entry: `World.step(_:)` — `Sources/NovaSwiftEngine/World.swift:1084`.
- Frame clock: `GameScene.update(_:)` — `app/NovaSwift/Game/GameScene.swift:924`.
- Ship model / player id 0: `World.swift:135`, `:711`, `:474`.
- Intent abstraction: `ControlIntent` — `World.swift:8`; input merge —
  `app/NovaSwift/Input/InputController.swift`.
- Injection seam: `World.addNPC(_:arrival:)` — `World.swift:830`.
- World build / system: `GameSession.makeWorld` —
  `Sources/NovaSwiftEngine/GameSession.swift:23`; system rebuild on jump —
  `app/NovaSwift/Game/GameContainerView.swift:966`.
- Determinism: `Sources/NovaSwiftEngine/RNG.swift` (seeded, no wall-clock).
- Save/pilot store: `app/NovaSwift/Game/PilotStore.swift` (`@Published var state:
  PlayerState`, `:18`).
- Galaxy map (for presence markers) & minimap (for player blips): in
  `app/NovaSwift` — locate exact views during P0/P1.

### Story / NCB & services seams (confirmed — for the per-player split)

- **NCB bit-set (per-pilot):** `PlayerState.setBits: Set<Int>` —
  `Sources/NovaSwiftStory/PlayerState.swift:294`. Mutate via `setBit/clearBit/
  toggleBit` (`:347-351`); test via `isBitSet(_:)` (`:451`, conforms
  `NCBTestContext`). Expression engine: `Sources/NovaSwiftStory/NCBExpression.swift`
  (`NCBTest.evaluate` `:69`, `NCBSet.parse` `:239`). Engine seam:
  `StoryEngine.evaluate(test:)` (`StoryEngine.swift:50`) / `apply(set:)` (`:56`).
  **One `StoryEngine` owns one `PlayerState`** (`StoryEngine.swift:18`) — so
  authority-vs-local routing = which engine/`PlayerState` a query evaluates against.
- **Mission availability / bit-setting:** `StoryEngine.isEligible(_:at:spobID:)`
  (`StoryEngine.swift:220`, gates on `availBits`/`Require`/rating/legal/ship);
  `completeMission` applies `onSuccess` bits via `apply(set:)` (`:459`); crons via
  `runCronHook` (`:834`).
- **Outfitter/shipyard gating (two layers):** tech-level inventory —
  `NovaEconomy.outfitsSold(at:day:)` / `shipsSold(at:day:)`
  (`Sources/NovaSwiftKit/NovaEconomy.swift:247`, `:268`); story/rank/govt locks —
  `NovaGame.lockState(for:pilot:…)` (`app/NovaSwift/Spaceport/ItemLocking.swift:63`,
  `:74`), gating on `availBits`+`Require`/Contribute (incl. active ranks). UI:
  `SpaceportScreens.swift` OutfitterView `:217` / ShipyardView `:404`. **All take
  the `pilot`/`PlayerState` as explicit input ⇒ trivially routable per-player.**
- **Rank / combat rating / salary (per-pilot):** `PlayerState.combatRating` (`:222`),
  `legalRecord` (`:223`), `activeRanks: Set<Int>` (`:224`, rank resource ids, NOT
  bits — activated by NCB SET ops). Salary paid in `StoryEngine.payDailySalaries()`
  (`:735`). Rank price discount: `PilotStore.rankPriceMultiplier(govt:game:)`
  (`PilotStore.swift:245`).
- **GameServices bridge:** `Sources/NovaSwiftStory/GameServices.swift:16`; app
  conformer `app/NovaSwift/Story/AppGameServices.swift:12`. Pure `PlayerState`
  mutations (credits/bits/ranks/outfits) stay client-local; the **world-affecting
  callbacks to elevate to the authority** are `spawnMissionShips`,
  `setStellarDestroyed`, `movePlayer`, `changePlayerShip`, `leaveStellar`,
  `showNews`.
- **Landing → spaceport UI is already a per-player local overlay:**
  `landedSpobID` `@State` in each client's own `GameContainerView`
  (`GameContainerView.swift:582`, rendered `:782`), over its own `PilotStore`. Two
  co-located players landing on the same spöb each get an **independent personal
  spaceport** — the per-player services split is essentially free here.

## Open questions

1. **Cross-galaxy shared missions** — RESOLVED by the "Story, control bits (NCB)
   & the per-player services split" section above (authority-driven world +
   per-player personal services + strict non-destructive/additive NCB merge).
   Residual edge: a spöb/outfitter whose very *existence* is bit-gated and differs
   between authority and visitor — default: personal services always use the local
   player's bits (you see your own outfitter even at the authority's planet), while
   the planet's world identity/state stays the authority's. Finalize in P3.
2. **Authority selection policy** — first-in vs. lobby-host-priority vs. lowest-
   latency. Start with "lobby host if present, else first-in"; revisit if handoff
   churn is bad.
3. **Player count** — v1 targets small groups (GKMatch allows 16); the N-ship
   generalization must not hard-code 2. Bandwidth/interest-management scaling is a
   P4 concern.
4. **PvP + co-op friendly-fire edges** — governed by `SessionRules`; finalize in
   P3.
