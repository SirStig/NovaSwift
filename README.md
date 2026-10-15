# NOVA Swift

![NOVA Swift](docs/branding/logo-banner.png?v=brand2)

NOVA Swift is a reimplementation of the Escape Velocity Nova engine (Ambrosia
Software, 2002), written in Swift from a reverse-engineered reading of the
original executable. It runs natively on macOS, iPadOS, iOS and tvOS, with a
Godot frontend for Linux, Steam Deck and Windows (public beta).

It is not an emulator or a wrapper. The engine reads the game data from your
own copy of EV Nova and plays it. No game data is included.

[Website](https://sirstig.github.io/NovaSwift/) ·
[Download](https://sirstig.github.io/NovaSwift/download.html) ·
[TestFlight beta](https://testflight.apple.com/join/3FBzwwq1) ·
[Releases](https://github.com/SirStig/NovaSwift/releases) ·
[Plug-in catalog](https://github.com/SirStig/NovaSwift-Plugins) ·
[Issues](https://github.com/SirStig/NovaSwift/issues)

Guides, screenshots and feature write-ups live on the website. This page is
for the source tree.

## Fidelity

The reference is the Windows release, EV Nova CE. Its executable was
disassembled and decompiled, and each gameplay system was compared against
NovaSwift and rewritten to match: flight, hyperjump and travel days, weapons
and damage, the NPC AI state machine, spawning, per-system legal record, the
economy, outfitter and shipyard, missions and control-bit scripting, the star
map, targeting, landing, Player Info, saving and Strict Play. Where a formula
was unclear, the original routine was run under emulation and its output
compared.

Original behaviour is the default. Anything that changes the rules is an opt-in
Enhancement and is off unless you turn it on.

No decompiled code is in this repository. The findings are written up as specs
with function addresses in [docs/reverse-engineering/](docs/reverse-engineering/README.md).

![Functions compared and matching, by part of the original. Green matches the original; teal is done differently on purpose.](docs/branding/fidelity-summary.svg?v=fb690c58)

One block is roughly 5% of that part of the original code: compared and
matching or fixed to match (green), or handled differently on purpose, such as the
save format and controls (teal). Every row is now complete: 671 of 671 portable
functions. The number at the end of a row is matching functions out of the
functions to port, not a progress percentage. This tracks how much has been
checked, not how finished the game is. All 179 plan items are done. NovaSwift
is in beta and has bugs. If something plays differently from the original, please
[open a fidelity issue](https://github.com/SirStig/NovaSwift/issues/new/choose).
The function-by-function view is in [docs/STATUS.md](docs/STATUS.md) and on the
[website](https://sirstig.github.io/NovaSwift/progress.html).

<details>
<summary>Features beyond the original, and parts of the original that aren't needed</summary>

![NovaSwift's own features](docs/branding/features-summary.svg?v=fc6fbd12)

![Parts of the original NovaSwift doesn't need](docs/branding/not-needed-summary.svg?v=0f518ead)

</details>

## Building

Requires a Mac with Xcode. `data/base/` is git-ignored, so your game data stays
on your machine.

```bash
git clone https://github.com/SirStig/NovaSwift.git
cd NovaSwift
scripts/setup.sh                # open-source dependencies
# copy your EV Nova data into data/base/ (see docs/GET_THE_DATA.md)
scripts/fetch-plugins.sh        # optional: free community plug-ins
swift build && swift test       # command-line check
open app/NovaSwift.xcodeproj    # pick a target and Run
```

### Linux, Steam Deck and Windows

The data layer, simulation and story runtime are portable Swift. The Godot 4
frontend, bridged with [SwiftGodot](https://github.com/migueldeicaza/SwiftGodot),
runs the same `World.step` as the Apple build.

Prebuilt Godot packages are on
[GitHub Releases](https://github.com/SirStig/NovaSwift/releases). The current
build is 1.0.0-beta.1.

- `NovaSwift-linux-x86_64.tar.gz`: Linux x86_64 and Steam Deck.
- `NovaSwift-macos-arm64.zip`: macOS on Apple silicon, for testing. On a Mac,
  the native app is the one to use. It is not notarised, so right-click the app
  and choose Open the first time.
- `NovaSwift-windows-x86_64.zip`: Windows 10/11 x86_64. Extract it anywhere and
  run `NovaSwift.exe`. The build is not code-signed, so SmartScreen may warn the
  first time: choose More info, then Run anyway.

Install and first-run steps are on the
[download page](https://sirstig.github.io/NovaSwift/download.html). To build it
yourself, see [docs/PACKAGING.md](docs/PACKAGING.md). Design notes are in
[docs/GODOT_LAYER.md](docs/GODOT_LAYER.md); what works is in
[docs/STATUS.md](docs/STATUS.md#linux-and-windows).

## Repository layout

```
docs/                    Charter, status, roadmap, architecture, formats, RE specs
Sources/
  NovaSwiftKit/          Resource parsing, typed decoders, sprite/PICT codecs, plug-in editing
  NovaSwiftEngine/       Simulation: flight, combat, AI, spawning, diplomacy
  NovaSwiftStory/        Missions, crön events, NCB scripting, pilots, economy
  NovaSwiftNet/          Multiplayer transports (Game Center, local Wi-Fi), sessions, cross-play protocol
  NovaSwiftENet/         ENet client, host and LAN discovery (cross-play with the Godot builds)
  NovaSwiftSync/         Multiplayer world-state sync
  NovaSwiftHD/           HD sprites, 3D models and HD packs
  NovaSwiftPluginStore/  Plug-in catalog, download and install
  NovaSwiftServer/       Standalone dedicated server (+ NovaSwiftServerCore)
  novaswift-extract/     Command-line inspector and test harness
Tests/                   Unit tests per library
app/NovaSwift/           SwiftUI/SpriteKit app, including the Plug-in Editor
godot/                   Godot 4 frontend and SwiftGodot bridge
data/base/               Your EV Nova data (git-ignored)
```

## Documentation

[docs/README.md](docs/README.md) is the index. Start with the
[Charter](docs/CHARTER.md), [Status](docs/STATUS.md),
[Roadmap](docs/ROADMAP.md) and
[Architecture](docs/ARCHITECTURE.md).

## Contributing

Bug reports, fidelity reports and pull requests are welcome; the issue tracker
has templates for each. Plug-ins go to
[NovaSwift-Plugins](https://github.com/SirStig/NovaSwift-Plugins). Please don't
attach or commit EV Nova data files.

## Legal

EV Nova and its data are copyrighted by their owners. This project does not
redistribute them.

- Game data: you need your own copy of EV Nova. NOVA Swift only reads it.
- Community plug-ins: the catalog links to public downloads. A plug-in is only
  rehosted when its readme allows redistribution, and authors can ask for removal.
- Code: open source, see [LICENSE](LICENSE).

The reverse-engineering docs describe behaviour in prose, short formulas and
constants. No decompiled code is included.

NOVA Swift is a fan preservation and interoperability project in the spirit of
OpenRA, OpenTTD and devilutionX. It is not affiliated with or endorsed by
Ambrosia Software, ATMOS or the original authors.
