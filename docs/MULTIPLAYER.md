# Multiplayer

Almost everything described here is built and covered by tests (the
`carryEncounter` rule is declared but not used yet). What hasn't happened is
verification on real hardware over a real network: the netcode and sync logic are
proven headlessly (two live `World`s talking over a loopback transport) and the
app-side wiring compiles, but nobody has played a session end to end on two
machines. Known gaps are listed at the bottom.

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
Bonjour. The public lobby list rides CloudKit, which Apple also hosts. There is no
NovaSwift backend to run or pay for.

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

### Finding a game online

Three ways in, in order of how most people will actually use them:

1. **Invite a friend** — the primary path. `GKMatchmakerViewController` sends it;
   the friend's app receives it through `GKLocalPlayerListener`. Registering that
   listener (`GameCenterManager.authenticate`) is what makes an accepted invite
   reach the app *at all* — without it GameKit sends and accepts the invite
   normally and simply never tells the app, so the invite appears to do nothing.
   The listener is registered at authentication rather than from a screen, because
   an invite can be accepted while the player is in flight or outside the app.
2. **Public lobby list** — see below.
3. **Quick Match** — auto-match, bucketed by `playerGroup` = `PluginManifest.groupID`
   so only identical content auto-matches. An empty queue is normal for a game this
   size and is reported as such (`queryPlayerGroupActivity`), not as an error.

### The lobby directory, and why it isn't Game Center

**GameKit cannot browse open matches over the internet.** There is no such API:
`queryActivity` returns only a count, and `startBrowsingForNearbyPlayers` is local
Wi-Fi only. So a browsable lobby list has to live somewhere else, and that is
CloudKit's **public database** (`OnlineLobbyDirectory`) — Apple-hosted, so the
"no servers" rule holds.

CloudKit carries **discovery only** — an advert and a knock at the door. It never
carries gameplay. A host accepting a knock sends a real Game Center invite, and the
match, the transport, and every byte of simulation still ride `GKMatch`. The
directory is therefore off the hot path: if CloudKit is unavailable, invites and
Quick Match keep working and only the browsable list degrades.

- **Accept-gated.** Listing a lobby doesn't admit anyone. A join writes a
  `JoinRequest`; the host's invite is the only thing that forms a match. A stranger
  can't pull themselves in, and all they ever learn is a `gamePlayerID`.
- **Opt-in.** Hosting is invite-only unless the player ticks "List this lobby
  publicly", since publishing exposes their pilot name to everyone.
- **Host is explicit.** A `GKMatch` has no host, so `OnlineRole` establishes one,
  and the rule must be one **both peers compute the same answer with**. An invite
  supplies that shared fact (the inviter hosts; each side knows which it was);
  auto-match has no invite, so both fall back to lowest `gamePlayerID`. Getting
  this wrong is silent: two hosts broadcast conflicting rules and mutually kick
  over plug-ins, while *zero* hosts means nobody broadcasts and everyone quietly
  keeps seeded `.safe` rules — the host's chosen stakes vanish with no error.
  Separate from per-system sim **authority**, which stays id-based.
- **Adverts are published before the match exists.** `minPlayers = 2`, so a host
  flying alone has no `GKMatch` and no session at all. Publishing therefore hangs
  off opening the lobby, not off session start — anything gated on a match could
  only advertise a lobby *after* someone had joined it, so nobody could ever find
  it to join. `publishOnlineLobby` is deliberately independent of `session`.

#### CloudKit setup this depends on (not doable from code)

The container is `iCloud.com.houseofkac.novaswift`, and the entitlement needs
`CloudKit` under `com.apple.developer.icloud-services` (alongside `CloudDocuments`).
In the CloudKit Dashboard, the **public** database needs:

| Record type | Fields | Indexes |
|---|---|---|
| `Lobby` | `name`, `hostName`, `hostPlayerID` (String), `playerCount`, `maxPlayers`, `pluginCount`, `allowPvP`, `isOpen` (Int64), `pluginSignature` (String), `updatedAt` (Date/Time) | `isOpen` queryable, `updatedAt` queryable + sortable |
| `JoinRequest` | `lobbyID`, `playerID`, `playerName`, `pluginSignature` (String), `createdAt` (Date/Time) | `lobbyID` queryable, `createdAt` queryable + sortable |

Development schema is created by first write; **Production needs the schema
promoted in the Dashboard** or release builds see nothing.

**The security model shapes the code.** The public database gives `_world` read but
reserves write to a record's `_creator`. Consequences, all load-bearing:

- A host **cannot** delete or modify a guest's `JoinRequest`. Answering a knock is
  therefore local (`dismissedRequests`), the guest deletes its own record once it's
  in or cancels, and orphans age out after `requestExpiry`.
- `dismissedRequests` maps id → the `createdAt` it answered, **not** a bare id set.
  A knock's record name is deterministic per (lobby, player), so a declined player
  reuses it when they knock again; remembering the id alone would filter the new
  knock too and blacklist them from that lobby permanently.
- There is **no rejection signal** — the host can't write anything the guest can
  read. A guest's `.waiting` therefore times out (`requestExpiry`) rather than
  waiting forever; it can't distinguish declined from ignored, and says so.
- `Lobby` record names are **random UUIDs**, never the host's `gamePlayerID`, with
  the id in a field. Record names are public and only the creator can write them,
  so an id-derived name is squattable: anyone could create it first and lock that
  player out of publishing forever.
- Stale `Lobby` adverts (host crashed mid-heartbeat) are filtered by `updatedAt`
  rather than deleted, for the same reason.

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

## Godot (LAN / IP / dedicated server)

The Godot desktop build (Linux, Steam Deck, Windows) runs the **same** `NetSession` +
Layer-2 sync as the Apple app. Only the transport differs, and it is split in two:

| Layer | Owner | What |
|---|---|---|
| Sockets, discovery, lobby UI, dedicated-server mode | GDScript | Godot ENet (`ENetMultiplayerPeer`): LAN broadcast discovery, direct `IP:port`, player-hosted dedicated servers |
| Session, presence, rules, chat, trade signals, plug-in gate, per-system authority, snapshots/inputs | Swift (`NovaSwiftNet` + `NovaSwiftSync`) | identical to Apple |

Swift pieces (all shared, no Apple-only code):

- `Sources/NovaSwiftNet/ExternalTransport.swift` - a `Transport` whose bytes are pumped by
  the frontend: `receive(from:data:)`, `peerConnected(id:name:)`, `peerDisconnected(id:)`,
  `drainOutgoing()`. Peer ids are Godot multiplayer peer ids; the player id string is
  `String(peer_id)`. `reliable` maps to ENet reliable, `unreliable` to unreliable
  (snapshots / inputs). A broadcast is one packet with `to = -1`.
- `Sources/NovaSwiftSync/SystemSyncDriver.swift` - the role logic that used to live in the
  app's `MultiplayerSession` (authority = smallest co-located id, mirrors, handoff,
  stakes, per-tick `syncPreStep` / `syncPostStep`). The Apple app now calls it too.
- `godot/bridge/Sources/NovaSwiftGodot/Net.swift` + the `// MARK: Multiplayer` block in
  `NovaWorld.swift` - the GDScript API below.

### Topology requirement

`NetSession` assumes it can address any connected peer (trade, per-client snapshots,
kicks). With ENet use Godot's `MultiplayerPeer` with server relay (the default): the
server is peer id `1`, clients see each other through it, and `peer_connected` fires on
every client for every other client. Report each of those via `net_peer_joined`. The
host (`is_host = true`) must be peer `1`; guests assume the host is peer `1` for the
plug-in compatibility gate. A **dedicated server** is a host with no pilot: call
`net_begin` and pump, but never `make_world`/`step` - it relays presence, rules and
chat and appears in nobody's roster.

### NovaWorld API (snake_case)

| Call | Notes |
|---|---|
| `net_begin(local_peer_id, display_name, is_host, rules_json) -> bool` | `rules_json` `""` = host full-stakes / guest safe. Lenient object: `{"preset":"safe"\|"full"}` and/or any of `pvp_damage_real, death_real, friendly_fire, allow_pvp, allow_trade, carry_encounter, game_speed_multiplier`. Replaces a live session. |
| `net_end()` | Leaves; a final packet (kick) stays drainable. |
| `net_peer_joined(peer_id, name)` / `net_peer_left(peer_id)` | Feed ENet/Godot connect/disconnect. Idempotent. |
| `net_receive(peer_id, data: PackedByteArray)` | Feed each received packet. |
| `net_outgoing() -> Array` | `[{to:int (-1 = all), reliable:bool, data:PackedByteArray}]`; call every frame after `step`. |
| `net_state() -> String` | `{active,is_host,local_id,players:[{id,name,system_id,ship,in_my_system,is_authority}],authority_id,syncing,rules,errors}` (`errors` returned once). |
| `net_events() -> String` | Drained JSON array: `player_joined`/`player_left {id,name}`, `chat {id,name,text,local}`, `rules_changed`, `trade {kind,...}`, `ncb_bits`, `kicked`, `version_mismatch`, `plugin_mismatch {missing,extra,wrong_version,as_host}`. |
| `net_chat(text)`, `net_set_rules(rules_json)` (host only) | |
| `net_kick(peer_id, ban)` (host only, extra) | |
| `net_ready_manifest() -> String` | `{plugins:[{id,name,contentHash}],signature,count}` - compare signatures for the lobby list. |

`NovaWorld.step()` runs `syncPreStep` / `syncPostStep` around every 30 Hz sim tick while a
session is active, exactly like the Apple game loop; with no session it is a no-op.
Co-located remote players appear as ordinary ships in the world, so they render through
the normal ship arrays. Presence is announced on the first `step()` after `make_world`
and on every system change. Not yet bridged: trade UI (invites are auto-declined and
surfaced as events) and co-op NCB story propagation (received bits arrive as `ncb_bits`
events; the authority does not yet send them).

### Playing online on Linux / Steam Deck / Windows

The Godot build plays multiplayer over three kinds of connection, all through
**Multiplayer** on the main menu (or in the pause menu): the same hub on Classic and
Nova Swift presentations, with mouse, keyboard and gamepad (Steam Deck) support.

| Tab | What it does |
|---|---|
| **Host Game** | Name, port (default **53735/udp**), max players, rules (Safe / Full stakes / Custom toggles for PvP, real damage, friendly fire, permadeath, trading), optional password, "visible on the local network". Your game keeps running normally; players who enter your star system play it with you. |
| **Join** | Type `host`, `host:port` or `[ipv6]:port`, plus the password if there is one. Recent servers are listed; "Save to favourites" keeps one. |
| **Public** | The community server directory (see below): every listed server is live-pinged for online/offline, players, version match, password and latency; sort by ping; filters for compatible / has players / region; Join or "Add to Saved". |
| **LAN** | Games and dedicated servers on your network, found by UDP beacons (port 53736). |
| **Saved** | Favourites, Minecraft-style, with live ping and player counts (a UDP status query to game port + 1). |
| **Session** | While connected: players (ping, system, authority), the host's Kick / Ban, rules (host can flip Safe / Full), chat, Leave. |

In flight, **T** opens chat (with the modern key layout: **/**), Enter sends, Esc closes; on
a gamepad use Menu > Multiplayer. Toasts announce joins, leaves, rule changes and kicks.
Trade invites are surfaced (the bridge has no trade send API yet, so the dialog is a
notice and the invite is declined).

**Hosting at home (internet).** Forward **UDP 53735** (or your chosen port) on your router
to the machine running the game, allow it in the firewall (Windows prompts the first time;
on Linux `sudo ufw allow 53735/udp`), and give friends your public IP (search "what is my
IP") with the port. Optionally also forward UDP 53736 so your server answers pings in
friends' Saved list. On a LAN nothing needs forwarding: friends see you under **LAN** or
join your local address (shown on the Host tab). Steam Deck: same as Linux, in Desktop or
Game mode.

**What must match.** Everyone needs the same NovaSwift version and the same enabled plug-ins
(compared by content hash). A mismatch is refused with the reason shown on the hub: version,
protocol, wrong / missing password, server full, plug-ins (the bridge's diff names what to
install, disable or update), banned, timeout. The password is sent hashed and game traffic is
not encrypted: fine for friends and LANs.

**Dedicated server ("like Minecraft").** A headless process that hosts a session without a
pilot or a window; players join by address.

```
scripts/run-dedicated-server.sh --name "My Server" --port 53735 --max-players 8 --rules safe --password secret
# or, from a source checkout / packaged build:
godot --headless --path godot -- --server --port 53735 --name "My Server"
./NovaSwift --headless -- --server --config /path/to/server.cfg
```

Options: `--server --port N --name "..." --password X --max-players N --rules safe|full
--config FILE --data DIR --log FILE --no-lan --no-stdin`, plus `--public --upnp --region --owner --contact --description --address --website` (see "Host a public server in 5 minutes"); `godot/net/server.cfg` is a documented
example (`[server]`, and `[rules]` for custom stakes); the command line overrides the file. The
server needs EV Nova data (`NOVA_DATA_DIR`, `--data`, or the folder the game already imported),
announces itself on the LAN, writes `user://logs/server.log` and a status line every 60 s, and reads
console commands on stdin: `help`, `status`, `players`, `kick <id|name> [reason]`, `ban <id|name>`,
`say <text>`, `rules safe|full`, `quit`. (Under systemd, pass `--no-stdin`; `Ctrl-C` / SIGTERM stop
it.) Port forwarding is the same as for hosting.

**How the server participates.** `ServerMain` opens an ENet server (peer id **1**) and calls
`net_begin(1, "[Server]", true, rules)` on its own `NovaWorld`, then pumps it each frame. It never
calls `make_world` or `step`: no pilot, no presence, never in a star system, so it is never a
system's authority and appears in nobody's roster. It carries the session rules, chat, moderation
and the plug-in gate; per-system authority stays with the co-located players. If a bridge refuses
or predates the `net_*` API, the server falls back to a plain relay (joinable, transport chat).

**Wire.** `godot/net/NetTransport.gd` runs a star topology over ENet (channel 0 reliable, channel 1
unreliable). The server relays client-to-client game bytes (`[0x10][int32 peer][payload]`), and
tells every client about every other client (`PEER_JOIN` / `PEER_LEFT`), which the client feeds to
`net_peer_joined` / `net_peer_left`, so `NetSession` can address any peer. Handshake: HELLO
(protocol, game version, name, password hash, `net_ready_manifest`) -> WELCOME or REJECT. Timeouts:
10 s to connect, 8 s to finish the handshake, 20 s of silence (clients ping every 2 s). Frames are
pumped by the `NetService` autoload, which is inert when no session is active.

**Known gaps.** The pause menu freezes the local sim (`Main.gd` stops calling `step`), so a paused
player stops sending snapshots; `net_outgoing` is drained once per frame before `step` (one frame of
latency); the stdin console cannot be joined at exit, so the server ends its own process after
flushing the log; NAT traversal / relays are not provided (forward the port or use a VPN such as
Tailscale / ZeroTier); no encryption; trade is a stub.

### Public server directory

There is no backend of ours. Public dedicated servers are listed in a JSON file in a GitHub repo, the same
way plug-ins are: [`servers/servers.json` in SirStig/NovaSwift-Plugins](https://github.com/SirStig/NovaSwift-Plugins/tree/main/servers)
(schema `servers.schema.json`, checker `servers/validate.py`, instructions `servers/README.md`). To list a
server you open a pull request adding an entry (`id`, `name`, `host`, `port`, `region`, `description`,
`owner{name,contact}`, `rules`, `plugins[{id,name,contentHash}]`, `maxPlayers`, `added`, `website`).

The **Public** tab (`godot/net/ServerDirectory.gd`) downloads
`https://raw.githubusercontent.com/SirStig/NovaSwift-Plugins/main/servers/servers.json` (HTTPS only), caches it
in `user://server_directory.json` with its `ETag` (a revalidation answered `304` just renews it) and refreshes
at most every 24 h or on **Refresh**; offline it shows the cached copy. The file is only a list of addresses.
Everything live (online, players/max, version, password, latency) comes from a UDP status query to each
entry (`LanDiscovery.query`, game port + 1; 53736 for the default port), so a stale or dishonest entry shows
as Offline. Rows sort online-first by ping; **Compatible only** hides servers on another game version.
Hostnames are resolved once and remembered, and at most 60 entries are queried per cycle.

### Host a public server in 5 minutes

1. **Run it.** On any always-on machine with your EV Nova data (Linux box, Raspberry Pi 5, a spare PC, a VPS):
   `scripts/run-dedicated-server.sh --name "My Server" --max-players 12 --rules safe --public --region eu --owner "You" --contact "discord: you#0001" --description "Friendly 24/7 server"`
   (`--address play.example.com` if you have a DNS name; `--port N` to change 53735).
2. **Open the ports.** Players need **UDP 53735** (the game); the directory's live ping needs **UDP 53736**
   (game port + 1). Forward both on your router to the machine and allow them in its firewall
   (`sudo ufw allow 53735:53736/udp`; Windows prompts the first time). A VPS only needs the firewall rule.
   - **UPnP:** add `--upnp` (or tick **Open the port on my router (UPnP)** in Host Game) to ask the router to
     do the forwarding for you. It's opt-in because many routers have UPnP switched off and some ISPs put you
     behind carrier-grade NAT (an address starting `100.64`-`100.127`, or a router "WAN" address different from
     what "what is my IP" shows), where forwarding is impossible. The server prints what happened.
   - **Can't forward?** Use [Tailscale](https://tailscale.com) or ZeroTier: everyone joins your `100.x.y.z`
     address, no forwarding at all (fine for friends; a public listing needs a real public address, so use a VPS).
3. **Check it.** `scripts/run-dedicated-server.sh --check [--port N] [--address HOST]` prints your public
   address, warns about CGNAT, and sends a real status query (`NSQ1`) to see whether it is reachable. Many routers can't
   loop back to their own public address, so the best test is from another network (or ask a friend to look
   at the Public/Saved tab).
4. **List it.** `--public` printed a ready-to-paste JSON entry (including the content hash of every plug-in your
   server runs) and the link to the instructions. Paste it into `servers/servers.json` in a fork of
   NovaSwift-Plugins, run `python3 servers/validate.py`, open the pull request. Players see it in the Public tab
   once it is merged. To be found sooner, share `host:port`: **Join** or **Saved** works immediately.

`--public` only prints; it never uploads anything. Long-running: `systemd` unit with `--no-stdin`, or `tmux`.

### Cross-play with the Apple app

**Status.** Godot players and the Apple app currently cannot meet: Apple uses Game Center (internet) and
Multipeer (nearby), Godot uses ENet. The wire layer for closing that gap now exists and is tested, with **no
Apple UI yet**:

- `Sources/CENet` - ENet 1.3.18 (MIT, Lee Salzman) vendored as a SwiftPM C target (headers + `module.modulemap`).
  Godot's networking is the same upstream protocol, so no wrapper or fork is needed.
- `Sources/NovaSwiftENet/ENetTransport.swift` - a client `Transport` that joins a Godot host or dedicated server
  by IP:port. It owns the ENet socket, performs the NetProto handshake, answers pings, relays through the
  server, and feeds an inner `ExternalTransport` so `NetSession` runs unchanged. It lives in its own target
  and library (`NovaSwiftENet`) instead of behind a compile flag: nothing links ENet unless the app imports it.
- `Tests/NovaSwiftENetTests` - handshake, peer list, reliable/unreliable relay, rejection (version/password),
  kick/leave, timeout, against a protocol-faithful stub server on loopback; plus `testAgainstLiveGodotServer`
  (`NOVASWIFT_ENET_INTEROP=host:port NOVASWIFT_ENET_VERSION=<server game version> swift test --filter testAgainstLiveGodotServer`),
  which was run against a real headless Godot dedicated server: handshake, WELCOME, ping/pong and clean
  leave all work. (Note: `swift test` builds every test target, so run it from a package that only contains the
  ENet targets if another target is mid-edit.)

**Not done (needs app work, deliberately left alone):** hosting from Apple over ENet; a `MultiplayerSession`
path that creates `ENetTransport` + `NetSession`; a server browser/IP:port screen on iOS / macOS / tvOS (the
Public directory fetch + UDP status query are small: `URLSession` + a `NWConnection`/BSD UDP socket sending
`NSQ1`, see below); sharing the plug-in gate (`ENetTransport.manifestJSON(PluginManifest)` already produces the
format Godot compares). Entitlements: outgoing UDP needs nothing on macOS (sandbox: *Outgoing Connections*) or
iOS; iOS/tvOS ask for Local Network permission only for LAN addresses. Also still open: both frontends must
share the same `NovaSwiftNet` protocol version and enabled plug-ins, and the galaxy is the *host's* (as on
Apple today).

**The wire spec an Apple client must match** (everything below is implemented by `ENetTransport`):

1. *Transport.* UDP, ENet 1.3.x, **IPv4**, default port **53735**. Connect with **3 channels** and the ENet
   *connect data* = your chosen peer id, a random 32-bit integer **>= 2** (Godot's `ENetMultiplayerPeer`
   uses it as your peer id and resets the connection if it is < 2 or already in use). The server is peer
   **1**. No ENet compression, no checksum. Godot adds no framing of its own: an ENet packet is exactly the
   application packet below.
2. *Channels.* ENet channel **0** = reliable; ENet channel **2** = unreliable (`UNSEQUENCED |
   UNRELIABLE_FRAGMENT`). (Godot: `SYSCH_RELIABLE=0`, `SYSCH_UNRELIABLE=1`, user channel 1 = ENet 2.) The server
   treats anything not on channel 2 as reliable when relaying.
3. *Packet.* First byte = kind; control kinds carry a UTF-8 JSON object (<= 64 KiB); `DATA` carries game
   bytes. Kinds: `0x01 HELLO`, `0x02 WELCOME`, `0x03 REJECT`, `0x04 PEER_JOIN`, `0x05 PEER_LEFT`, `0x06 KICK`,
   `0x07 PING`, `0x08 PONG`, `0x09 CHAT`, `0x10 DATA` (`NetProto.gd`).
4. *Handshake.* After ENet connects the client sends **HELLO** `{proto: 1, version: <game version string>, name,
   pw: sha256hex("novaswift:" + password) or "", manifest: <net_ready_manifest JSON or "">}`. The server answers
   **WELCOME** `{your_id, server_name, host_name, has_local_player, rules (JSON string), peers:[{id,name}], max,
   proto}` or **REJECT** `{code, message, detail}` with `code` in `proto | version | password | full | plugins |
   banned | bad_request`, then drops the connection. Client timeouts: 10 s to connect, 8 s for the handshake, 20 s of
   silence; the client sends **PING** `{t, rtt}` unreliably every 2 s and the server returns **PONG** `{t}`.
5. *Version and plug-in gate.* `version` must equal the server's `application/config/version` exactly (the
   Apple build must report the Godot project's version string, currently `0.7.0-beta.1`), and `proto` must be 1.
   `manifest` is the `net_ready_manifest()` JSON `{plugins:[{id,name,contentHash}], signature, count}`; the server
   compares canonical forms (sorted keys), so the plug-in set and **content hashes** must be identical.
6. *Game data.* `DATA` = `0x10` + **int32 little-endian peer id** + payload (the same `NetSession` bytes as
   Apple's other transports). Client -> server the id is the **destination** (`-1` = everyone else, `1` =
   server only); server -> client it is the **source**. The server relays client-to-client packets, preserves
   reliability, and also hands `-1`/`1` traffic to its own session. Peers are announced by `WELCOME.peers`,
   `PEER_JOIN {id,name}` and `PEER_LEFT {id,reason}`; the server (peer 1) is always a participant, a dedicated
   server simply has no pilot. `NetSession` player ids are the decimal peer ids (`ExternalTransport`).
7. *Moderation / chat.* `KICK {reason}` precedes a disconnect; `CHAT {id,name,text}` is only used when the
   bridge has no chat of its own (normal chat is `NetSession` chat inside `DATA`).
8. *Status query (for browsing, no connection needed).* UDP datagram `NSQ1` to **53736** for the default port,
   otherwise **game port + 1**; the reply is `NSB1` + JSON `{name, players, max, ver, pw, port, rules,
   dedicated}`. Latency = round trip. A LAN host broadcasts the same `NSB1` beacon to 255.255.255.255:53736
   every 2 s.
9. *Directory.* `GET https://raw.githubusercontent.com/SirStig/NovaSwift-Plugins/main/servers/servers.json`
   (`ETag`, refresh <= 24 h), then status-query each entry. The Apple browser should reuse the same file so
   both frontends show one list.

**Plan to finish it:** (1) `MultiplayerSession` gets a third mode "Join by address" that builds `ENetTransport`
and `NetSession(transport: transport.inner...)` inside the `.connected` event, then drives `service()` from the
game loop (or `startPumping()`); (2) a small Swift `ServerDirectory` (URLSession + UDP status query) mirroring
`ServerDirectory.gd`; (3) a Public/LAN/Saved/IP view in the Apple hub, controller-cursor aware on tvOS;
(4) an Apple-side version constant shared with the Godot project's `config/version` (release script check);
(5) optional later: let the Apple app host over ENet too (an ENet server loop around `ExternalTransport`) so iOS can
host for Godot players.
