# Multiplayer

Status: **Built and playable** (2026-07-16). Every feature described below exists in
the codebase and is covered by tests. What has *not* happened is runtime verification
on real hardware over a real network — the netcode and sync logic are proven
headlessly (two live `World`s talking over a loopback transport), and the app-side
wiring compiles, but nobody has yet sat down at two machines and played a session
end to end. Known gaps are listed in "What isn't done" at the bottom.

## What multiplayer is

Play alongside friends while **each player runs their own persistent galaxy and
pilot save**. You each fly freely through your own game. When two or more players
are in the **same star system**, that system is synced completely — ships, combat,
projectiles, events — so you genuinely play together: help each other, fight
together, or fight each other. When you're in different systems, nothing heavy is
synced; you each just play your own game. The canonical flow is "I'm stuck, come
help me": your friend jumps to your system and drops in.

**We host no servers.** Internet play rides Apple's Game Center infrastructure
(Apple runs matchmaking and the relay). Local play uses the LAN directly via
Bonjour. There is no NovaSwift backend to run or pay for.

## Core model

| Topic | How it works |
|---|---|
| **Galaxies** | Independent. Every player always plays their own real save; multiplayer is an overlay, never a merge. Nobody is forced to co-locate. |
| **Shared system** | If ≥2 players are in the same system, it's synced completely. One co-located player is that system's **authority**; the others are clients for it. |
| **Separated systems** | No ship/combat/event sync — only the lightweight presence layer (who's in which system) stays live. |
| **Alone in a system** | You are trivially your own authority. No networking, no clients; it runs exactly like single-player. |
| **Authority** | Per-system and dynamic — the smallest co-located player id wins. Deterministic, so both sides agree with no negotiation. |
| **Stakes** | `SessionRules` governs inter-player interactions: is PvP damage real, is death real, friendly fire, PvP allowed, trade allowed, session game speed. Presets: `.safe` (sparring) and `.fullStakes`. |
| **Interactions** | Co-op combat, PvP, shared mission progress, and credit/cargo/outfit trade. |
| **Story** | The shared world runs the **authority's** storyline. Personal services (outfitter, shipyard, re-arm, escorts, salary, rank, combat rating) resolve against each player's **own** save. NCB bit merges are additive and non-destructive: you only *gain* bits you earn together. |
| **Connection** | Game Center for internet play, MultipeerConnectivity for local Wi-Fi. One `Transport` protocol, swappable backends. |

### Why Game Center, and why no lockstep

Peer-to-peer over the internet needs NAT traversal, which needs a rendezvous server
and usually a TURN relay. We won't run those, so Game Center's `GKMatch` is the only
"host nothing, works over the internet" option on Apple platforms — Apple provides
matchmaking and relay for free, up to 16 players. A "direct join code" would be
layered on top of Game Center via programmatic matchmaking, not a separate
serverless path; a code that bypasses Game Center only ever works on a LAN. Internet
play requires the `com.apple.developer.game-center` entitlement, which is present in
`app/NovaSwift/NovaSwift.entitlements`.

The engine is strongly deterministic (seeded `SplitMix64`, no wall-clock, no ambient
RNG — `Sources/NovaSwiftEngine/RNG.swift`), so lockstep would be *possible*. We don't
use it: lockstep is fragile across join-in-progress and authority handoff, and needs
perfect fixed-tick sync, whereas our loop is variable-`dt` and frame-coupled to
SpriteKit. Host-authoritative state-sync is simpler and more robust, and the client
side is cheap because the renderer only reads world state and drains events — it
never mutates the sim.

## The two sync layers

### Layer 1 — Presence (always on, all players, low rate)

Every player broadcasts `PlayerPresence { playerID, name, currentSystemID,
shipTypeHint }` on each system change plus a slow heartbeat. It costs a few bytes per
jump and is the *only* thing synced when players are apart. It drives the galaxy-map
friend markers and co-location detection: when your `currentSystemID` matches another
player's, Layer 2 engages for that system.

### Layer 2 — System simulation sync (co-located players only)

Host-authoritative per system. The authority owns the live `World` — NPC traffic,
combat, projectiles, events, domination, defenses. Every other co-located player is a
client: it streams its `ControlIntent` up (~30 Hz, unreliable), predicts its own ship
locally, and renders the authority's streamed world. Snapshots come down at ~20 Hz
(unreliable); events, handshakes, chat, trade, and NCB updates ride a reliable
channel.

A client pauses its own spawner (`World.spawningPaused`) and clears its AI
(`removeAINPCs()`), then mirrors the authority's NPCs from each snapshot as
`networkMirror` ships (`spawnNetworkMirror`) built from the real hull via
`Galaxy.makeShip(shipTypeID:)` with the real government, so hostiles read hostile.
The client's **own ship health is authoritative** — adopted from the snapshot, so the
authority's combat really damages it — while its position stays locally predicted and
drift-blended back (`SystemSyncCoordinator.reconcileOwnShip`).

Projectiles and beams are echoed for visuals: the snapshot carries live shots and
beams, and the client re-seeds them each snapshot as `visualOnly` copies that fly
straight and expire without collision or damage, dead-reckoned between snapshots. A
client skips its own shots (matched by owner id) since it already fired those
locally. Explosions the authority produces ride in `WorldSnapshot.effects` and are
flushed into the client's event stream after its step, so everyone sees the same
booms.

### Authority handoff

The first player in a system is its authority; the smallest co-located player id wins
re-election. A player jumping into an occupied system requests a snapshot, loads it,
and becomes a client. When the authority leaves a still-occupied system, authority
re-elects deterministically and the new authority rebuilds its world
(`needsResync`) — a brief hiccup. When the last player leaves, the system reverts to
plain single-player for whoever enters next.

Because every player has their own galaxy, *your* system X and *my* system X can
differ (different spawns, domination state, economy, mission progress). The
authority's version is canonical for a shared encounter; a visitor temporarily sees
and interacts with the authority's X, and their own galaxy's X is untouched. That's
what keeps co-location an overlay rather than a merge.

## Architecture

```
   Layer 1 (presence)  ── always on, all peers, ~1 msg per jump ──────────────┐
                                                                               │
   PlayerA @ Sys X (authority)      PlayerB @ Sys Y (alone, own authority)     │
        │  snapshot ▼   ▲ input          │  (no net traffic)                   │
        │             PlayerC @ Sys X (client of A)                            │
        └──────── Layer 2: Sys X synced among {A, C} ───────────────────────┘

   When B jumps into A's system:  B ⇢ presence → A's snapshot → B mirrors A's
   world and becomes a client.  Now {A, B, C} all synced in Sys X.
   If A then jumps away:  authority re-elects to B or C and rebuilds.
```

### `Sources/NovaSwiftNet` — the wire

- **`Transport.swift`** — the `Transport` protocol (connect/disconnect/send on a
  channel/receive callback/peer lifecycle), `TransportDelegate`, `NetChannel`
  (reliable vs unreliable), `LobbyDescriptor`.
- **`LoopbackTransport.swift`** — in-process, for testing full handshakes with no
  devices and no entitlement.
- **`MultipeerTransport.swift`** — `MCSession` over Bonjour for same-network play,
  with host/join modes: a host advertises a *named* lobby via `discoveryInfo` and a
  joiner invites only the chosen host id, so separate groups on one network never
  merge. `MultipeerLobbyBrowser` lists nearby lobbies.
- **`GameKitTransport.swift`** — wraps a `GKMatch` for internet play; peer id is the
  `gamePlayerID`. Reliable/unreliable map to `GKMatch.SendDataMode`.
- **`Messages.swift`** — every wire type: `PlayerPresence`, `NetIntent`,
  `InputFrame`, `ShipNetState`, `ProjectileNetState`, `BeamNetState`,
  `EffectNetState`, `WorldSnapshot`, `ChatMessage`, `NCBUpdate`, `TradeOffer`,
  `TradeSignal`, the `NetMessage` envelope, and `NetCodec`.
- **`NetSession.swift`** — owns the transport, lobby role, peer roster, presence
  table, `SessionRules` propagation, chat log, host moderation (kick/ban, with
  `bannedIDs` refusing presence), and the Layer-2 send/receive calls
  (`sendInput`/`sendSnapshot`/`broadcastSnapshot`, `onInput`/`onSnapshot` tagged with
  the sending peer).
- **`SessionRules.swift`** — the stakes struct and its presets.
- **`PluginManifest.swift`** — plug-in compatibility. Each enabled plug-in is an id +
  display name + content hash, so players match on the same *version*, not just the
  same name. A joiner whose manifest differs from the host's is blocked with a diff
  telling them what to install, disable, or update (`PluginMismatch`). The manifest's
  FNV-1a `signature` is the cheap lobby-list compatibility hint and its `groupID`
  becomes the Game Center `playerGroup`, so auto-match only pairs identical content.
  This matters because a mismatched plug-in set would silently desync the shared
  galaxy — the same ship/outfit/system id would mean different things on each side.

### `Sources/NovaSwiftSync` — the bridge

`SystemSyncCoordinator` runs both sides. As authority: `receiveInput`, `applyInputs`,
`snapshot(of:)`, `syncClients`. As client: `apply(_:to:)` with mirror
inject/update/remove, `reconcileOwnShip` drift-blending, `flushEffects`, plus
stale-input dropping and `promoteToAuthority` for handoff. It also maps
`NetIntent ⇄ ControlIntent` and builds `WorldSnapshot`s recipient-agnostically (each
`ShipNetState` is tagged with a `playerID`).

### `Sources/NovaSwiftEngine` — N externally-driven ships

The engine originally assumed exactly one externally-controlled ship. It's now
generalized, additively and without breaking the single-player path:

- `Ship.remotePlayer: RemotePlayerInfo?` marks another player's ship;
  `Ship.networkMirror` marks a mirrored NPC; `isPlayerControlled` distinguishes.
- `World.remoteIntents: [EntityID: ControlIntent]` drives remote ships;
  `spawnRemotePlayer` / `remotePlayerShips` / `spawnNetworkMirror` / `removeAINPCs`
  manage them, and `removeShip` clears intents.
- `World.spawningPaused`, `pvpAllowed`, `friendlyFireAllowed`, `pvpDamageReal`, and
  `playerDeathReal` are the session-rule hooks the sim reads.

This preserves the symmetry the engine already had — a player and an AI are both just
a `ControlIntent` plus `Ship.step`. A remote player is simply a ship whose intent
arrives over the wire.

### App layer — `app/NovaSwift/Multiplayer`

`MultiplayerSession` is the observable on `AppModel` that owns the session: it
computes the per-system authority, drives a `SystemSyncCoordinator`, exposes
`syncPreStep`/`syncPostStep` (which `GameScene` calls around `world.step`, no-op
unless ≥2 players share the system), pushes the session rules into the world each
frame, and runs the trade state machine.

The UI is one **Multiplayer** menu button opening `MultiplayerHubView` (Local /
Online tabs), which leads to `HostSetupView` (lobby name + stakes preset + toggles) or
a nearby-lobby list, and `PluginMismatchView` when content doesn't match. In session,
`LobbyRosterView` shows the player list with host/you badges, rules pills, per-player
kick/ban/trade menus, and Return-to-Flight / Leave. `GameCenterMatchmaking.swift`
wraps `GKMatchmakerViewController` for both UIKit and AppKit; `GameCenterManager`
authenticates at launch from `RootView`. `TradeView` is a two-column GIVE/RECEIVE
window with steppers over your held items, a live mirror of the partner's offer, and a
dual-accept bar (side-by-side on wide screens, stacked on a phone).
`ChatOverlayView` is the in-game chat cluster with an unread badge. Everything is
responsive across iPhone/iPad/Mac.

Identity is consistent everywhere: a friend's ship wears an in-world nameplate under
the hull, a named and colour-coded radar blip on both HUDs (the co-op blip bypasses
the IFF gate so a friend never disappears), and a galaxy-map presence marker offset
from the mission arrows. All three read one palette
(`GalaxyMapView.playerColor(for:)`), so a given friend is the same colour in every
view.

## Chat

Session-wide text chat between everyone in the session, on the reliable channel and
**independent of co-location** — you can message a friend before you've met up ("come
help me at Sol"), which is the whole point. `ChatMessage` embeds `senderName` so old
messages still render their author after that player disconnects. `NetSession` keeps
an oldest-first `chatLog` of sent and received messages and fires `onChat` per
message; `sendChat(_:)` trims blank input, appends locally, and broadcasts.

## Stakes / SessionRules

Because everyone plays their own galaxy, each player's own save always persists.
`SessionRules` governs only inter-player interactions while co-located:

```swift
struct SessionRules {
    var pvpDamageReal:       Bool    // enforced — World.swift
    var deathReal:           Bool    // enforced — World.swift
    var friendlyFire:        Bool    // enforced — splash-damage gate
    var allowPvP:            Bool    // enforced — canHit gate
    var allowTrade:          Bool    // enforced — MultiplayerSession
    var carryEncounter:      Bool    // DECLARED ONLY — see "What isn't done"
    var gameSpeedMultiplier: Double  // enforced — the host's speed, session-wide
    // Presets: .safe (sparring — PvP allowed, nothing hurts), .fullStakes (all real)
}
```

The host sets the preset and toggles when opening the lobby; each joiner sees them.
`.fullStakes` means your ship is your real ship: damage and death are real in your own
game, and trades move real items between real saves. Co-op partners share a government
so they're un-hittable allies until PvP is switched on.

`gameSpeedMultiplier` is a rule rather than a local preference for a real reason: each
device used to apply its own `GameSettings.gameSpeed`, which let two sims silently
drift apart whenever two players had picked different speeds. Pushing the host's value
to every guest puts the whole lobby's ships, weapons, and regen on one clock.

## Persistence

There is no working-copy save and no forced save-merge — everyone is always in their
own persistent galaxy. Interaction outcomes apply per `SessionRules`. The authority's
galaxy is the canonical sim for a shared encounter; a visitor's own galaxy state
elsewhere is never touched.

## Story, control bits (NCB), and the per-player services split

The principle: **the shared world runs the authority's storyline; personal progression
stays personal; nothing is ever overwritten; you can only gain, and only by earning it
together.** This is what makes "a more-progressed friend joins a less-progressed host,
or vice versa" work without clobbering either save.

Everything splits into two buckets by what kind of thing it is.

**Authority-driven — the shared, in-space world.** Resolved against the authority's
NCB/story state: which NPCs and fleets spawn, planet states, domination, stellar
defenses, ambient traffic, and which missions and story beats are live in the shared
world. All physical, in-space, synced reality.

**Per-player — personal services.** Resolved against each player's own save, visible
only to them: outfitter inventory and shipyard availability (gated by their own
NCBs/tech/rank/government status), ammo and re-arm, escort hiring, salary, credits,
combat rating, ranks. Two co-located players landing on the same authority-owned
planet each get an independent personal spaceport driven by their own save — the
planet's identity and world state is the authority's, but the shop contents are yours.
The reasoning: a more-progressed player who joins a less-progressed host must still be
able to buy and re-arm what their own story unlocked, and a less-progressed player
must not be blocked or spoiled by the host's further-along state.

This falls out almost free from the existing architecture: landing already renders a
per-player local overlay (`landedSpobID` in each client's own `GameContainerView`,
over its own `PilotStore`), and the outfitter/shipyard gating functions all take the
`pilot`/`PlayerState` as an explicit input, so they're trivially routable per player.

### How NCB merging works

1. **Non-destructive** — joining never clears or removes bits from anyone.
2. **No passive inheritance** — joining a more-progressed player does not copy their
   pre-existing bits to you, and joining a less-progressed one costs you nothing.
3. **Earn-together is additive** — bits set by missions and events you actually
   participate in during shared play are unioned into each participating player's own
   set.

In code: the authority's set-bit changes are captured as a frame diff of
`PlayerState.setBits`, sent per-participant on the reliable channel as `NCBUpdate`,
and unioned into each co-located partner's own vector (`AppModel.onRemoteBitsEarned`
→ `setBits.formUnion` + save). The baseline is seeded at session start and re-seeded
whenever you aren't the authority, so pre-existing and solo-earned bits never leak.

**Accepted consequence:** a lagging player can acquire a later mission's bits out of
order relative to their own solo storyline, because they earned it together. That's
intended. The guard is that story logic depending on an earlier prerequisite bit
degrades gracefully — a mission whose condition isn't met simply doesn't fire for that
player rather than corrupting state.

## Trade

Two players can swap credits, cargo, and outfits when `SessionRules.allowTrade` is on.
`TradeOffer` and `TradeSignal` (invite/decline/offer/accept/cancel) ride the reliable
channel via `NetSession.sendTrade`/`onTrade`. `MultiplayerSession` runs a two-sided
state machine (`inviteTrade`/`accept`/`updateMyOffer`/`setTradeAccepted`/`cancel`);
any change to either offer resets both acceptances, and when both sides have accepted,
each applies the swap to its own save through `AppModel.onTradeCommitted`. It's
started from the lobby roster's per-player Trade button and shown as a flight overlay.

## Testing

**Automated:** roughly 66 test functions. `Tests/NovaSwiftNetTests` (~46) covers
Layer-2 sync, chat, the message codec, plug-in manifests, presence, loopback,
multipeer, moderation, and trade. `Tests/NovaSwiftSyncTests` (13) covers the
coordinator, including `testTwoWorldsSyncPlayersEndToEnd` — a genuine integration test
that runs two real `World`s and two `NetSession`s over a loopback network and verifies
a friend's ship appears and moves in the other player's world and that each client's
inputs drive its ship authoritatively on the authority. It also covers authority
handoff, drift-blending, shot/beam echoes, and stale-input dropping.
`Tests/NovaSwiftEngineTests/RemotePlayerTests.swift` (14) covers the engine hooks.

**Two copies on one Mac:**

    scripts/run-two.sh

Builds once, launches instance 1 normally and instance 2 with `NOVASWIFT_INSTANCE=2`.
That env var (see `AppInstance.swift`) gives instance 2 its own pilot roster and saves
(`…/Application Support/NovaSwift-2`) and its own selected-pilot default, while both
share the game data you already imported — so no re-import and no save corruption. The
secondary tags its co-op name (`Captain #2`) so you can tell them apart in presence and
chat. In each window: start or resume a pilot → **Multiplayer** → host or join a local
lobby. They discover each other over Bonjour, no Game Center needed. Put both pilots in
the same star system to see each other's ship and fly together; chat works session-wide
regardless of location. Ctrl-C the script to quit both. For a true two-device test, run
one copy on a second Mac or iPad on the same Wi-Fi — same flow, no env var.

## What isn't done

- **No real-hardware runtime verification.** Nothing here has been played on two
  machines or over a real Game Center match. The sync logic is proven headlessly and
  the app wiring compiles, but the first live session will surface things tests can't.
  This is the biggest outstanding item.
- **`carryEncounter` is declared but never read.** It's a field on `SessionRules` with
  a doc comment and a value in both presets, and nothing in the engine, app, or tests
  ever consults it. It also has no toggle in `HostSetupView`, so a host can't set it
  independently of a preset. Kills and loot in an authority's system currently do not
  carry back to a visitor's own galaxy regardless of what this says. Either implement
  it or delete the field.
- **Authority handoff rebuilds instead of promoting.** When the authority leaves,
  re-election is deterministic and correct, but the new authority rebuilds its world
  rather than promoting the mirror it already holds, so NPCs re-roll and there's a
  visible hiccup. Seamless mirror-promotion is a refinement, not a blocker.
- **Bandwidth is untuned.** No delta compression and no interest management; snapshots
  ship full state. Fine for small groups, unexamined at higher player counts. `GKMatch`
  allows 16 players and nothing hard-codes 2, but nothing has been measured either.
- **Residual story edge case:** a planet or outfitter whose very *existence* is
  bit-gated and differs between authority and visitor. The rule is that personal
  services always use the local player's bits (you see your own outfitter even at the
  authority's planet) while the planet's world identity stays the authority's, but this
  hasn't been exercised.

## Key files

**Netcode:** `Sources/NovaSwiftNet/` — `Transport.swift`, `LoopbackTransport.swift`,
`MultipeerTransport.swift`, `GameKitTransport.swift`, `Messages.swift`,
`NetSession.swift`, `SessionRules.swift`, `PluginManifest.swift`.

**Sync bridge:** `Sources/NovaSwiftSync/` — `SystemSyncCoordinator.swift`.

**Engine:** `Sources/NovaSwiftEngine/World.swift` — `Ship.networkMirror`,
`Ship.remotePlayer`, `World.remoteIntents`, `spawningPaused`, `pvpAllowed`,
`spawnRemotePlayer`, `spawnNetworkMirror`, `removeAINPCs`. Determinism lives in
`RNG.swift`; world construction in `GameSession.makeWorld`.

**App:** `app/NovaSwift/Multiplayer/` — `MultiplayerSession.swift`,
`MultiplayerHubView.swift`, `MultiplayerLobbyViews.swift`, `TradeView.swift`,
`ChatOverlayView.swift`, `GameCenterMatchmaking.swift`. Sync is driven from
`GameScene.update`; presence markers live in `GalaxyMapView.swift`; the entitlement is
in `app/NovaSwift/NovaSwift.entitlements`.

**Story seams:** `PlayerState.setBits` (`Sources/NovaSwiftStory/PlayerState.swift`)
with `setBit`/`clearBit`/`isBitSet`; `StoryEngine.evaluate(test:)` / `apply(set:)` —
one `StoryEngine` owns one `PlayerState`, so authority-vs-local routing is just a
question of which engine a query evaluates against. Mission gating:
`StoryEngine.isEligible(_:at:spobID:)`. Shop gating: `NovaEconomy.outfitsSold(at:day:)`
/ `shipsSold(at:day:)` for tech level, `NovaGame.lockState(for:pilot:…)`
(`app/NovaSwift/Spaceport/ItemLocking.swift`) for story/rank/govt locks. Bridge:
`Sources/NovaSwiftStory/GameServices.swift`, app conformer
`app/NovaSwift/Story/AppGameServices.swift` — the world-affecting callbacks that would
need elevating to the authority are `spawnMissionShips`, `setStellarDestroyed`,
`movePlayer`, `changePlayerShip`, `leaveStellar`, `showNews`.
