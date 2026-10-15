# NovaSwift Dedicated Server

A standalone, always-on multiplayer server. **No game, no EV Nova data, no pilot.** It runs the session host
role: the handshake gate (protocol, password, bans, capacity, gameplay plug-in set), the client-to-client relay,
rules, chat and moderation, `NSQ1` status replies and LAN beacons. Players in the same star system sync with each
other directly through it; the server simulates nothing. Apple, Linux, Steam Deck and Windows players share one server
(same wire as `docs/MULTIPLAYER.md`, "Cross-play").

You manage it from a web admin panel (`http://localhost:53737`). The first run starts a four-step wizard.

## 5-minute guides

### Your own PC (Windows, macOS, Linux)

1. Download `NovaSwiftServer-<system>` from [Releases](https://github.com/SirStig/NovaSwift/releases) (tag `server-v…`) and unpack it anywhere.
2. Windows: double-click `Start Server.bat`. macOS: `Start Server.command` (first time: right-click, Open). Linux: `./NovaSwiftServer`.
3. A console prints the admin address and an **admin password, once**. Your browser opens on the setup wizard
   (headless: open the printed address).
4. Answer the wizard (name, open/password + slots + rules, plug-ins, public listing).
5. Forward **UDP 53735 and 53736** on your router (or Settings > UPnP). Players use Quick Connect with the address on the dashboard.

### Linux VPS (Google Cloud e2-micro free tier, Hetzner, any Ubuntu/Debian)

1. Create the VM. In the **provider firewall** allow `udp:53735-53736` from anywhere. Leave 53737 closed.
2. `curl -fsSL https://raw.githubusercontent.com/SirStig/NovaSwift/main/packaging/server/install-server.sh | sudo bash`
   (x86_64 and arm64; creates a no-login `novaswiftd` service account, `/opt/novaswift-server`, a systemd unit with `Restart=always`, opens the
   ports in ufw when active, prints the URL and password). Flags: `--version X.Y.Z`, `--admin-public`, `--no-firewall`, `--uninstall`. The service runs sandboxed (see SECURITY.md) and the
   installer verifies the release signature when the release has one.
3. `ssh -L 53737:localhost:53737 you@vps`, then open `http://localhost:53737` and finish the wizard.
4. Upgrade: run the same command again (settings, plug-ins and password are kept) or use Settings > Updates.

### Docker

```
cd packaging/server && docker compose up -d && docker compose logs novaswift | head -30
```
`packaging/server/Dockerfile` is multi-arch (`docker buildx build --platform linux/amd64,linux/arm64 -f packaging/server/Dockerfile .`).
`./data` holds `server.cfg`, `plugins/` and `logs/`. The compose file publishes the admin panel on `127.0.0.1` only.

### Raspberry Pi (4/5, 64-bit OS)

Use the Linux installer (it picks the arm64 build), forward UDP 53735-53736 to the Pi (give it a fixed LAN address),
open the panel at `http://<pi>:53737` from your network.

## Files and where they live

`server.cfg`, `plugins/`, `logs/server.log`, `cache/` are created in the **folder the program sits in** when it is writable
(a downloaded archive is fully portable), else in the platform data folder (`~/Library/Application Support/NovaSwiftServer`,
`$XDG_DATA_HOME/novaswift-server` or `~/.local/share/novaswift-server`, `%APPDATA%\NovaSwiftServer`). Override with `--data DIR`
or `NOVASWIFT_SERVER_DIR`. A development build in `.build/` never uses its own folder.

### server.cfg

INI, generated with comments on the first run; the panel rewrites it on save (hand edits are kept, comments are regenerated;
restart after editing by hand). Sections: `[server]` name, description, port (53735), max_players, password, motd, region,
lan_announce, upnp. `[rules]` preset (safe/full/custom) and the custom switches, game_speed. `[admin]` port (53737), bind
(`127.0.0.1` default, or `0.0.0.0`), password_hash, setup_done. `[plugins]` enabled (catalog ids and local folder names). `[public]` listed,
address, owner, contact, website. `[updates]` check, auto_update. `[bans]` `ip = note`.

The admin password is generated on the first start, printed once, and stored as a salted, iterated SHA-256 hash.
`--reset-admin-password` makes a new one. The default server name is `<hostname>'s NovaSwift server`, shortened to the
24-character limit.

### Command line

`--data DIR`, `--port N`, `--admin-port N` (both are saved to server.cfg), `--no-browser`, `--no-stdin`,
`--reset-admin-password`, `--quiet`, `--version`, `--help`. Console commands: `status`, `players`, `kick <id|name> [reason]`,
`ban <id|name>`, `unban <ip>`, `mute <id|name>`, `unmute <name|ip>`, `allow <ip>`, `disallow <ip>`, `tempbans`, `audit`, `say <text>`, `rules [safe|full]`, `plugins`, `quit`, `help`.

## The admin panel

Dashboard (status, uptime, players, bandwidth, version, address + Copy), Players (kick, ban, message, announce), Settings
(everything above; most apply live: name, password, slots up to the current capacity, rules, plug-ins; changing the port or
raising slots above the original capacity reopens the game port; the panel's own port/bind need a restart), Plug-ins,
Public listing, Network, Logs (live tail), Bans.

Security (details: [docs/SECURITY.md](SECURITY.md)): the panel binds **127.0.0.1 by default** (reach it with an SSH tunnel; "other computers"
is an explicit opt-in in the wizard / `--admin-public` with a warning). Login is a cookie session (`HttpOnly; SameSite=Strict`, `Secure`
behind an HTTPS proxy), every write needs `X-NS-Admin` and a same-origin `Origin`, the `Host` header is checked, wrong passwords lock an address
out with doubling waits, new passwords must be strong, every response carries CSP/frame/referrer headers, and admin actions are written to
`logs/audit.log` (panel: Audit). There is no built-in HTTPS: use a tunnel or a TLS reverse proxy. The Linux installer does not open 53737.

Moderation: the panel and console can kick, ban, mute, allow-list (invite-only mode); players can `/votekick`, `/report`, block locally. Flooding,
forged messages and oversize packets are dropped and repeat offenders are blocked for ten minutes. Settings > Moderation holds the knobs
(`[moderation]` in server.cfg: `vote_kick`, `vote_kick_percent`, `allowlist_mode`, `word_filter`, `max_connections_per_ip`, `announce_joins`).

## Plug-ins without the game

Plug-ins > Browse catalog lists `catalog.json` from NovaSwift-Plugins (cached; offline shows the last copy). Turning one on
downloads it with the same `PluginDownloader` / `PluginInstaller` as the game (checksum checked) into `plugins/<id>/`. The server
then computes the manifest **from the files** with `PluginGameplay` (the code the game uses): gameplay plug-ins are *required*
(compared by gameplay-only content hash), art/sound-only ones are detected and listed as *optional*; a total conversion and its
add-ons are advertised. The manifest feeds the handshake gate, the `NSB1` status reply (`plugins`, `tc`, `addons`, `sig`) and the
public-listing entry, so joining players get the one-click **Install & Join**. **Add a file** uploads a `.zip`/`.rez`/`.ndat`
for a non-catalog plug-in; it is marked "players must get this themselves". Verified: a Godot client's `arpia2` manifest hash
equals the server's hash of the same files.

## Public listing

The panel's Public listing page checks you are ready, generates the `servers.json` entry (id, name, host, port, region,
description, owner, rules, plugins with hashes, `totalConversion`/`tcAddons`, maxPlayers, added) and opens the GitHub edit page of
`servers/servers.json` in SirStig/NovaSwift-Plugins (editing there creates the pull request). Nothing is uploaded automatically.

## Network

Needs UDP 53735 (game) and 53736 (pings = game port + 1). The Network page shows local addresses, looks up the public IP over
HTTPS (api.ipify.org, with fallbacks), warns on CGNAT (100.64.0.0/10), tries UPnP (SSDP + SOAP AddPortMapping, UDP) and runs a
local `NSQ1` self-test. A real outside-in reachability test is impossible without a helper service: test from a phone on mobile
data or ask a friend. Tailscale/ZeroTier tip is shown on the page.

## Updates

The server checks GitHub releases tagged `server-v<version>` (every 12 h; Settings toggle) and shows a notice with the link. "Install
update" (or the opt-in `auto_update`) installs a release only if it carries a valid signature (`server-update.json` + `.sig`, the same RSA key as
the game updater) and the download matches the signed checksum; it replaces the program file and takes effect after a restart. A sandboxed
service install has a read-only program file: upgrade it by running the installer again.

## Building

```
swift build -c release --product novaswift-server          # binary: .build/release/novaswift-server
scripts/package-server.sh                                  # dist/server/*.tar.gz and .zip (Docker for the Linux ones)
scripts/embed-server-web.py                                # after editing Sources/NovaSwiftServerCore/Web/*
```
Layout: `Sources/NovaSwiftServer` (main), `Sources/NovaSwiftServerCore` (config, game server, plug-in manager, HTTP, admin API,
network tools, updates, console; `Web/` is the panel source, `AdminAssets.swift` its generated embedding), tests in
`Tests/NovaSwiftServerTests`. Additive changes to shared code: `ENetHostTransport` (`dedicated`, `reconfigure`, `bannedIPs`,
byte counters), `LANBeaconService.broadcastBeacons`, and Linux fixes in `UDPDiscovery` interface enumeration.

## Status

Released on GitHub as `server-v1.0.0-beta.1` (2026-10-14), for Linux x86_64, Linux arm64, macOS arm64 and Windows x86_64. Its version now matches the game's, and its update check uses semver ordering (`1.0.0-beta.1` < `1.0.0`). The previous release was `server-v0.1.0`. The maintainer runs the official server, "NovaSwift Official West", on a Google Cloud VM.

Tested: config/auth/HTTP/plug-in/handshake unit tests (36); the real server against the Swift ENet client and two real headless
Godot clients (`net_e2e_client.gd`: handshake, presence, co-located sync, chat, trade, authority handoff - PASS). Built for Linux
arm64 and x86_64, macOS arm64, and Windows x86_64; the Windows build runs. On Windows the socket code (`NovaSwiftENet/UDPDiscovery.swift`,
`HTTPServer.swift`, `NetworkTools.swift`) has Winsock paths (`Sock.swift`), a polling timer replaces libdispatch read
sources, and zips go through the system `tar.exe` because ZIPFoundation does not build there. The Linux installer runs the
official server (Google Cloud e2-micro, Ubuntu 22.04); the Docker image was not built. Networking is dual-stack IPv4/IPv6 (set `bind_address` under `[server]` to pin one address; IPv6 bans and rate limits apply per /64). Not yet: TLS for the panel,
DTLS (the vendored ENet has none), IPv6 for the admin panel (IPv4 only), automatic outside-in reachability checks.
