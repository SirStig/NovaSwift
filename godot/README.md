# NOVA Swift — Godot desktop frontend (Linux / Windows / macOS)

This directory is the cross-platform desktop frontend for NOVA Swift. It hosts
the game in **Godot 4** and drives the existing Swift engine through a
**SwiftGodot GDExtension**. It's the path to Linux and Windows, which the Apple
SwiftUI/SpriteKit app (`app/NovaSwift/`) can't reach.

Full design: [`../docs/GODOT_LAYER.md`](../docs/GODOT_LAYER.md).

## Layout

```
godot/
  project.godot          Godot 4 project
  NovaSwift.gdextension  loads the native bridge library per platform
  Main.tscn / Main.gd    the flight frontend (ships, shots, beams, rocks, HUD)
  Prefs.gd               settings store (user://settings.cfg: volumes, video, dead zone, rebinds, data dir)
  screens/Shell.gd       app shell flow: data setup -> main menu -> pilot menu; pause menu; settings
  screens/MainMenu.gd    New Pilot / Open Pilot / Settings / Game Data / Quit (+ title music)
  screens/Settings.gd    Audio / Video / Controls (full key + pad rebinding)
  screens/PauseMenu.gd   Esc / Start in flight: Resume / Settings / Save & Quit to Menu / Quit
  screens/DataSetup.gd   "where is your EV Nova data?" + folder picker + Run Demo
  screens/ShellUI.gd     shared theme (visible focus ring) + builders
  screens/PilotMenu.gd   pilot screen (list / new / load / delete)
  screens/Spaceport.gd   docked UI: landing, Bar, Mission BBS, Trade Center, Outfitter, Shipyard, Recharge
  screens/StoryScreens.gd story texts, mission offers, Player Info / Mission Info (P / I)
  screens/Interactions.gd  in-flight hail, board/plunder, capture and escort dialogs + Escort Commands panel
  audio/TitleMusic.gd    main-menu music (STR# 130 #2 mp3; .mov/missing = silence)
  audio/GameAudio.gd     sound: snd -> AudioStreamWAV cache + 16-voice player pool
  tests/                 headless self-checks (godot --headless -s res://tests/…)
  icon.png               app icon
  bin/                   built bridge libraries land here (git-ignored)
  bridge/                the Swift ↔ Godot bridge (its own SPM package)
    Package.swift
    Sources/NovaSwiftGodot/
      NovaSwiftGodot.swift   GDExtension entry point
      NovaWorld.swift        Godot node wrapping the engine's World
```

## Build & run

Requires a [Swift toolchain](https://swift.org/download/) (6.3) and
[Godot 4.6+](https://godotengine.org/download) — developed against 4.7. The
floor tracks the Godot release SwiftGodot's pinned revision binds to; see the
version matrix in [`../docs/GODOT_LAYER.md`](../docs/GODOT_LAYER.md).

```bash
# 1 · build the native bridge into godot/bin/
scripts/build-gdextension.sh          # from the repo root (release by default; pass 'debug' for a debug build)

# 2 · open this folder in Godot 4.2+ and press Play (F5),
#     or run headless-less from the CLI:
godot --path godot
```

### App shell

Startup shows the **main menu** (Open Pilot / New Pilot / Settings / Game Data… /
Quit) when data is found, else a **data-setup** screen with a folder picker, a
rescan and *Run Demo*. Data is searched in: `NOVA_DATA_DIR`, the folder saved in
settings, the repo's `data/base`, `user://data`, and `~/.local/share/NovaSwift/data`
(Linux / Steam Deck). **Esc** / pad **Start** in flight opens the pause menu
(Resume · Settings · Save & Quit to Menu · Quit). Settings
(`user://settings.cfg`) cover volumes + mute, fullscreen / vsync / window scale,
stick dead zone, and rebinding of every action's key and pad button (conflicts
swap; Defaults resets). Everything is focus-navigable (d-pad / A / B). Headless
check: `godot --headless --path godot -s res://tests/shell_selfcheck.gd`.
`NOVA_SKIP_PILOT_MENU=1` / `NOVA_DEMO=1` bypass the shell.

### Two modes (chosen automatically)

- **Real data** — point it at your own EV Nova data and it renders **actual hull
  and planet sprites** in a real system:
  ```bash
  NOVA_DATA_DIR=/path/to/your/EVNova/data godot --path godot
  ```
  If `NOVA_DATA_DIR` is unset it also checks the repo's git-ignored `data/base/`.
- **Demo** — with no data found, it builds a **data-free demo world** (a ship you
  fly plus a ring of drifting hulls, drawn as primitives). Always runs.

With real data a **pilot screen** comes first (up/down or d-pad to move, Enter /
A to select, Esc / B to go back): pick a pilot to Play or Delete, or create a
New Pilot (choose scenario, type a name or press Random name). Pilots are saved
as `.evpilot` files in Godot's `user://pilots` (same format as the Apple app) at
each launch and on quit. `NOVA_SKIP_PILOT_MENU=1` skips the screen (throwaway
pilot).

Controls are the original's keys, exactly as the Apple app ships them: **arrows** fly
(you swing the nose and keep drifting — that's the engine's real physics), **Z**
afterburner, **Space** fire primary, **Ctrl** fire secondary, **W** / **Alt-W** next /
previous secondary (**S** clears it), **`** / **Shift-`** / **Alt-`** cycle ship targets
(escorts only with Alt), **R** nearest hostile, **Alt-R** nearest ship, **N** clear the
travel selection (**Alt-N** the ship target), **1–4** select the system's nav stellars,
**L** land, **Y** / **Alt-Y** hail the target / the selected stellar, **B** board, **H**
re-arm the route, **E** the Escort Commands panel (then **1–5** pick a group) with
**F** attack · **D** defend · **V** hold · **C** formation · **Alt-C** return to hangar,
**P** Player Info, **I** Mission Info. Settings → Controls has a "Modern key layout"
switch (the Apple app's `modernKeyBindings`: Shift burns, Return fires secondaries, Tab /
R / T / U target, P pauses), off by default, and every key is rebindable. Landing is the
original's two presses on the **selected** stellar (the nearest one if none is selected):
the first requests clearance — a refusal (standing, `Require`, landing fee) says why and
drops the selection; a bribe from the hail window (**Alt-Y**) buys it — the second sets
down. Landing on a hypergate (when cleared) opens the galaxy map in gate mode to pick a
destination; a wormhole flings you through. Docked (screens/Spaceport.gd, all by focus
navigation): arrows / d-pad move, **Enter**/A press (buy), **S**/X sell,
**Q**/Y buy-quantity prompt (**I**/Y ship info in the shipyard), **E**/RB
sell-quantity prompt, **Esc**/B back out — from the landing screen, launch.

Navigation: **M** (pad Back/Select) opens the galaxy map, **J** (pad D-pad up)
engages the hyperdrive along the plotted course. On the map: click (pad **A**)
plots — arms a jump to a linked system, as in the original; **Shift+click**
(pad **Y**) adds a hop; **T** (pad **X**) toggles the auto-route enhancement;
wheel / **+ −** (pad **LB/RB**) zoom, right-drag / arrows (pad right stick) pan,
pad left stick moves a cursor that snaps to systems and the D-pad hops to the
next one; **C** recentres; **F** (pad **L3**) finds a system by name; **M** / **Esc** (pad
**B**) close. Nebula art is drawn; hypergate / wormhole spokes show only in the gate picker
unless Settings → Video "Gate links on the galaxy map" (an enhancement) is on. Headless check:
`NOVA_SKIP_PILOT_MENU=1 NOVA_SELFTEST=nav godot --headless --path godot`
plots a 2-hop route and flies both jumps (`NOVA_SELFTEST=map` drives the screen).

Sound: weapon fire, explosions, docking, jump cues, alarms and the interface
beeps play from your data's `snd ` resources, with the original's voice limits
and distance falloff (all decided in the shared Swift core; `audio/GameAudio.gd`
only plays what the bridge's `drain_sound_cues()` says). Check headlessly:
`godot --headless --path godot -s res://tests/audio_selfcheck.gd`.

## What this proves

The slice exercises the whole loop on Linux/Windows/macOS:

```
Godot input → Swift ControlIntent → World.step → Swift readback → Godot render
```

`World.step` here is the *same* simulation the Apple app runs. From this
foundation the real frontend (sprites from the player's data, HUD, galaxy map,
spaceport, story) is built up in GDScript over the same engine calls — see the
milestones in [`../docs/GODOT_LAYER.md`](../docs/GODOT_LAYER.md).

## Note on the current status

Confirmed on-toolchain 2026-07-18: the bridge builds clean with
`scripts/build-gdextension.sh` (Swift 6.3) and a headless `godot --path godot`
run loads real EV Nova data, builds a system, and steps the simulation with no
errors, on macOS. Linux/Windows are not yet verified locally — CI
(`.github/workflows/godot-linux-windows.yml`) tracks the core's Linux/Windows
compilation and the bridge build there.

Until recently that CI could never have gone green: `NovaSwiftKit`'s decoded-
sprite cache used LZFSE through `NSData.compressed(using:)`, an Apple-only
Foundation facility, so every Linux and Windows job died before the bridge was
even reached. That's fixed (`Sources/NovaSwiftKit/SpriteDiskCache.swift` now
tags each record with its codec and stores raw off Apple) and the workflow is
back on push/PR. The first green Linux run is what will actually confirm the
core compiles off Apple end to end — the LZFSE failure masked everything
downstream of it, so more platform edges may surface behind it.

Missions: the Mission BBS and Bar are on the landing screen (A/Enter selects, **A** key /
pad **X** accepts a BBS listing); offers also pop on landing and when opening shops.
**P** (or the pause menu) opens Player Info, **I** Mission Info (abort there). Headless:
`godot --headless --path godot -s res://tests/story_selfcheck.gd` (and `story_menu_check.gd`).

Gameplay gaps closed (see `screens/BarScreens.gd`, the bridge's `// MARK: Gameplay gaps`): the
bar's **Hire Escort** browser (daily fees are paid at each launch and per jump day; the Escorts
window's **Upgrade / Sell** marks are processed by the fleet pass when you leave a shipyard
stellar) and **Gamble** (Galaxy Racing Network; the holovid clip isn't played), a përs's
LinkMission offer over a hail or boarding, in-flight contraband scans (jünk `ScanMask` vs the
scanner's `ScanFine` / `SmugPenalty`) and junk events, **U** cloak, **Alt-X** eject (escape pod →
respawn after the pod's flight), **Alt-−** self-destruct (hold), jettison pods drawn, and a
left-click in flight selects the ship / stellar under the pointer. A destroyed pilot with no pod
returns to the main menu (unsaved). Headless: `tests/gameplay_gaps_selfcheck.gd`.
