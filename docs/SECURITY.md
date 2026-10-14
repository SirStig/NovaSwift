# NovaSwift multiplayer: security

Threat model: a server on the public internet, anonymous players, malicious clients, a malicious system authority, UDP
spoofing/reflection and ordinary DDoS attempts. The server is a **relay**: it simulates nothing, so it cannot referee
gameplay. What it can do is stop people abusing the relay itself and each other (identity forgery, floods, chat abuse),
and every receiver validates what it is sent. Limits that cannot be fixed in a relay design are listed at the end.

Code map: `Sources/NovaSwiftNet/NetSecurity.swift` (QueryGuard, TokenBucket, NetLimits, NetValidation),
`CrossPlay.swift` (name/chat cleaning), `NetSession.swift` (receiver checks), `Sources/NovaSwiftENet/ENetHostTransport.swift`
(limits, tempbans), `Sources/NovaSwiftServerCore/` (`Moderation.swift`, `AdminService.swift`, `ServerUpdate.swift`),
Godot: `godot/net/NetProto.gd`, `NetTransport.gd`, `LanDiscovery.gd`; tests are listed per section.

## 1. UDP amplification (`NSQ1` status query)

A spoofed-source query that returns more bytes than it sent turns the server into a reflector. Rules (Swift `QueryGuard`,
Godot `NetProto.QueryGuard`, both responders):

| Request | Handling |
|---|---|
| `"NSQ1"` + version byte `0x02` (this build) or `0x01` (the public-list status prober) + zero padding, **512 to 2048 bytes**; clients send exactly **1200** | Answered with `NSB1` JSON of **at most `min(request length, 1200)` bytes**. If the full JSON (with plug-in list) is bigger it is trimmed to the compact form (`sig`, `pcount`, `tc`) and gets `"truncated":true`. |
| bare 4-byte `"NSQ1"` (builds before this change) | Only a ~30-byte `NSB1{"proto":1,"upgrade":true}` notice, max one per source IP per 5 s and 20/s overall. |
| anything else | Dropped without an answer. |

Per source IP: token bucket, burst 5, refill 2/s; the table is capped at 4096 sources (a full table refuses new sources
rather than evicting). Clients (Swift `ServerStatusQuery`, Godot `LanDiscovery`) send the 1200-byte request and, if
nothing came back after a third of the timeout, the bare query once (for servers older than this change). The protocol
number (`CrossPlayProtocol.version`) is **not** bumped: ENet gameplay is unchanged. Godot only: a version-3 request
(1300 bytes) asks a DTLS server for its certificate. Tests: `SecurityTests` (Net), `SecurityTests.testStatusQueryRulesOnTheWire`,
`godot/tests/net_security_selfcheck.gd`.

## 2. Connection and flood limits (ENet host)

* ENet itself: `maximumPacketSize` 128 KiB, `maximumWaitingData` 2 MiB, `duplicatePeers` = per-address cap.
* Per address: `max_connections_per_ip` (default 8 on the dedicated server; raise it behind NAT/Docker proxies).
* Handshake timeout 8 s; idle timeout 20 s; before `HELLO` only `HELLO`/`PING` are accepted (anything else is a violation).
* Per connection: 300 packets/s (burst 600), 512 KiB/s (burst 1 MiB). Packet kinds are size-capped: `HELLO` 32 KiB, `DATA`
  64 KiB, `CHAT`/`PING`/`REPORT` 1 KiB; unknown kinds are ignored. Over-limit packets are dropped and counted; 50
  violation points in 30 s kick the connection (oversize packet = 10 points).
* Abuse kicks: 3 kicks from one address in 10 minutes, or 10 failed handshakes/wrong passwords in a minute, put the
  address on a **temporary block for 10 minutes** (panel: Bans page, console `tempbans`). `127.0.0.1` is never blocked.
* Tests: `testRandomGarbageFromManyConnectionsNeverBreaksTheServer` (4000 garbage packets from several raw ENet
  connections plus 500 garbage datagrams at the status port), `testFloodingConnectionIsKicked`,
  `testOversizedPacketsAreKicked`, `testPerAddressConnectionLimit`.

## 3. Parsing

Every wire field is length- and range-capped: names 24 (server names 40), chat 200 characters, plug-in manifests 64 entries
in beacons/handshakes (256 in-session) with 128-character fields, `NSB1` replies 6144 bytes, trade offers 64 cargo / 256
outfit lines, snapshots 256 ships / 1024 shots, story bits 64 per message in `0...10000`. Malformed JSON or binary is dropped,
never fatal. Fuzz: `SessionSecurityTests.testFuzzedPacketsNeverCrashTheSession` (6000 mutated/garbage packets through
`NetSession`), the server garbage test above, the Godot fuzz in `net_security_selfcheck.gd`.

## 4. Admin panel

* Default bind **127.0.0.1** (also for the Linux installer, even on upgrade; Docker publishes it on the host's loopback). Reach it
  with `ssh -L 53737:localhost:53737 you@server`. Listening on all addresses is an explicit choice (`--admin-public`, or the
  setup wizard with a warning) and the panel then says it is exposed.
* **No built-in HTTPS.** Remote use needs an SSH tunnel or a TLS reverse proxy on the same machine (Caddy/nginx). Behind such a
  proxy set `X-Forwarded-Proto: https`: the session cookie then also gets `Secure`, and list the proxy's name in
  `NOVASWIFT_ADMIN_HOSTS`. A self-signed certificate was deliberately not built in (it needs a TLS library the server does not ship).
* Session cookie `HttpOnly; SameSite=Strict` (+`Secure` as above), 12-hour sessions, at most 64.
* CSRF: every write needs the `X-NS-Admin` header (a cross-site page cannot add it) **and** a same-origin `Origin`; the `Host`
  header must be an IP literal, localhost, this machine, the configured public address or `NOVASWIFT_ADMIN_HOSTS` (DNS rebinding).
* Login lockout: 5 wrong passwords lock an address out; the lock doubles each time (1 min ... 1 h); 60 failures/minute across all
  addresses slow everyone except localhost. Password change needs 12+ characters, three character kinds (or 20+), not a common
  password; it signs every session out.
* Headers on every response: `Content-Security-Policy` (scripts only from the panel itself), `X-Frame-Options: DENY`,
  `Referrer-Policy: no-referrer`, `nosniff`, `Cross-Origin-*` same-origin, `Cache-Control: no-store`. Panel script builds DOM from
  data with `esc()`/`textContent`; a test checks no player field is interpolated raw.
* **Audit log** (`logs/audit.log` + panel "Audit" page + console `audit`): logins, failures, every state-changing action with
  actor and address. Passwords and codes are never written.
* HTTP: 48 connections, 8 per address, 10 s to send a request head, 30 s for a body, 4 MiB bodies (600 MB uploads for plug-in files only).
* Tests: `testAdminSecurityHeadersAndCookieFlags`, `testAdminRefusesForeignHostAndCrossOriginWrites`,
  `testLoginBackoffDoublesAndStrongPasswordsAreRequired`, `testAuditLogRecordsActionsButNeverSecrets`, `testPanelScriptEscapesPlayerData`.

## 5. Plug-in downloads by the server

HTTPS only (HTTP links in the catalog are refused), 800 MB cap (stopped mid-download), SHA-256 checked against the catalog when
the entry has one (a warning is logged when it has none). Archives are validated before extraction: no `..` or absolute paths,
no symbolic links, at most 10 000 entries and 3 GB unpacked (ZIPFoundation also checks containment). Plug-ins are data files
(`.rez`/`.ndat`) that are only read; nothing downloaded is ever executed. Tests: `PluginInstallerTests` (zip-slip, absolute path,
symlink, entry bomb).

## 6. Self-update

The server installs an update only if: the asset URL is `https://github.com/SirStig/NovaSwift/releases/download/server-v<ver>/...`;
the release carries **`server-update.json` and `server-update.json.sig`**, an RSA-4096 PKCS#1 v1.5 SHA-256 signature made with the
**same key that signs game updates** (public key `godot/updater/update_pubkey.pem`, embedded in `ServerUpdate.swift`; a test
keeps them equal); the manifest names this platform's archive with its size and SHA-256 and a version newer than the running one;
the download matches. Unsigned or mis-signed releases are refused with a message; nothing is "installed anyway".

Release step (after `scripts/package-server.sh` and bumping `ServerVersion.current`):

```
scripts/release-sign.sh --server --version 0.2.0 \
  --asset linux-x86_64=dist/server/NovaSwiftServer-linux-x86_64.tar.gz \
  --asset linux-arm64=dist/server/NovaSwiftServer-linux-arm64.tar.gz \
  --asset macos-arm64=dist/server/NovaSwiftServer-macos-arm64.zip
# attach the archives, server-update.json and server-update.json.sig to the GitHub release tagged server-v0.2.0
```

`install-server.sh` verifies the same signature (openssl) when the release has one and warns when it does not (releases made before
signing). Under the hardened systemd unit the program file is read-only to the service, so **a service install upgrades by running the
installer again**; the panel's "Install update" works for portable installs (the folder is writable). Tests: `testUpdateSignatureVerification`,
`testEmbeddedUpdateKeyMatchesTheGameUpdaterKey`, `testOnlyOfficialReleaseAssetsAreTrusted`, `testUnsignedReleaseIsRefused`.

## 7. Service sandbox

`install-server.sh` writes a unit with `NoNewPrivileges`, empty `CapabilityBoundingSet`, `ProtectSystem=strict` +
`ReadWritePaths=<dir>/data`, `ProtectHome`, `PrivateTmp`, `PrivateDevices`, kernel/cgroup/clock/hostname protection,
`RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX AF_NETLINK`, `RestrictNamespaces/Realtime/SUIDSGID`, `LockPersonality`,
`MemoryDenyWriteExecute`, `SystemCallFilter=@system-service` (minus `@privileged @resources`), `LimitNOFILE=4096`, `TasksMax=256`,
`Restart=always` with `StartLimitBurst=10/300 s`, `LimitCORE=0` (no core dumps in the data folder) and `LimitNICE=40` (libdispatch sets thread priorities per QoS class; without an RLIMIT_NICE allowance an unprivileged service logs `Failed to set thread priority for worker thread ... errno=13` - this was the log noise on the live server; verified gone in a systemd container). `SystemCallErrorNumber=EPERM` turns a filtered call into an error instead of killing the process (`@resources` is therefore *not* denied: libdispatch needs `setpriority`). The program and scripts are root-owned; only `data/` belongs to the `novaswiftd` account.
Docker: UID 10001, `read_only: true`, tmpfs `/tmp`, `cap_drop: ALL`, `no-new-privileges`, pids/memory limits, admin port on the host's loopback.
Tests: `testSystemdUnitIsHardened` (directive check + `systemd-analyze verify` where present), `testDockerAndComposeAreLockedDown`.

## 8. Strings, chat, moderation

* Names: control, zero-width, bidi and tag characters stripped, whitespace collapsed, 24 characters, **no `[` `]`**, reserved and
  look-alike names refused (`Server`, `[Server]`, `S3rver`, `A d m i n`, `Admin2`, `Moderator`, ...) and made unique per session.
  Chat: same cleaning, 200 characters, newlines become spaces. **Display layers escape anyway**: Godot uses plain `Label`s (and
  `NetProto.escape_bbcode` for any future `RichTextLabel`), SwiftUI `Text(String)` is verbatim, the web panel escapes every field.
* The relay **rewrites identity**: relayed chat gets the server-known name and player id; presence for another player, `sessionRules`
  and `kick` from a client are dropped and counted. Receivers check again: presence and chat must come from their own sender, host-only
  messages only from the host (peer 1).
* Chat limits: 4 burst, 2/s sustained per player (server and receiving client), the same line three times in 10 s is dropped, repeated
  flooding kicks. Optional word filter (`word_filter` in `[moderation]`, off by default). Console/panel **mute** (by address and name,
  persisted in `server.cfg [mutes]`). **Block** (local, hides a player's chat; Godot overlay/hub and the Apple chat row's context menu)
  and **Report** (sends `K_REPORT 0x0A` `{id, reason, detail}`).
* Players: `/votekick <name>` (3+ players online, 51% of players but at least 2; configurable or off), `/report <name> [why]`, `/votes`, `/help`.
  3 distinct reporters (or 5 distinct "invalid data" reports) remove a player and count towards a temp block. Admin: kick/ban/mute/unmute/
  allow/disallow from the panel and console; **allowlist mode** (`[allowlist]`) makes the server invite-only; joins and leaves are announced in
  chat (`announce_joins`). Bans persist in `[bans]`.
* Receiver validation (`NetValidation`, `SystemSyncCoordinator`, `SystemSyncDriver`, `NetSession`): impossible snapshot entries (NaN/inf, coordinates
  beyond 1e6, speeds beyond 4000, unknown hull ids) are dropped; list sizes capped; snapshots only from the current system authority; input only
  from co-located players; story bits only from the authority of the shared system and in range; own health from a snapshot never exceeds the
  ship's maxima and, when `deathReal` is off, never kills; position "corrections" beyond 60 000 units are ignored; trade offers are range-checked and
  sanitized (`TradeRules`), each side's `swapCheck` re-validates its own holdings before commit; nothing can write another player's save (every
  save change is applied by the owner's own client). Repeated invalid messages are counted per peer and reported to the server (`K_REPORT`), which
  can remove the sender.

## 9. Known limits (be honest with players)

* **The system authority is a player.** A modified client that is the authority of a system can lie inside the plausible range: place NPCs, spawn
  loot, report hits, slow-walk others' health within limits, grief with story bits that are in range. The relay cannot see game state to referee it.
  Mitigations: validation above, reports/vote-kick, `safe` rules (nothing persists), and playing on a server whose admins you trust.
* Game traffic is **not encrypted** on the Apple/ENet path (the Godot DTLS option is Godot-to-Godot); the join password travels as a hash.
* ENet's connection handshake is not spoof-proof: a flood of forged connection attempts can fill the connecting slots until they time out. Use your
  provider's DDoS protection/firewall rate limits for volumetric attacks; this server only protects itself above the network layer.
* Per-address limits assume one address is one person group; NAT users share limits (raise `max_connections_per_ip`), and an address mute hides a
  whole shared address.
* The admin panel has no built-in TLS (see 4).
* The legacy bare `NSQ1` no longer returns a usable server entry, so very old clients show such servers as offline until they update.
