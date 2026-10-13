# Status

What works today and how closely it matches the original. This is the one place
for detailed status. If another doc disagrees, this one is right, and the other
doc should be fixed.

## Summary

The whole game is playable on macOS, iPadOS, iOS and tvOS: start a pilot from any
`chär` scenario, fly, fight, trade, outfit, buy ships, take missions, play the
storylines through, board and capture ships, dominate planets, hire escorts, and
die with the original's consequences. Plug-ins and total conversions load in the
original's order.

Gameplay has been checked against the original executable, system by system.
After a later re-read, 16 of the plan's 179 items are open again (see below).
Original behaviour is the default. The Linux/Windows frontend plays through on
macOS and is partway done; its status table is under
[Linux and Windows](#linux-and-windows).

Where each kind of fact lives: plan items and open questions in
[FIDELITY_PLAN.md](reverse-engineering/FIDELITY_PLAN.md); frontend gaps in the
Godot port in [GODOT_FIDELITY_GAPS.md](GODOT_FIDELITY_GAPS.md). This page
summarises both, and its counts are the ones the README and the website quote.

## How fidelity was checked

The Windows executable of EV Nova CE (3,199 functions) was decompiled to
pseudo-C. Each function was assigned to a subsystem (flight, weapons, AI and so
on) from its name, the strings and resource types it touches, and its callers
and callees. 718 were first tagged as gameplay code; the grid below counts 697 in gameplay groups once drawing and debug plumbing is split out.

We then compared NovaSwift with that code area by area and wrote down every
difference as an item in
[FIDELITY_PLAN.md](reverse-engineering/FIDELITY_PLAN.md). Each item gives the
original behaviour with function addresses, the NovaSwift code it affects, and a
test. Where reading the code was not enough to pin a formula (the random number
generator, thrust and top speed, the control-bit test and set interpreters), the
original routine was run on its own in an emulator and NovaSwift was tested
against its output.

The plan has 179 items in eight areas. 163 are done. 16 are open: a later read of the executable reopened items whose heading said done, and added EC-27 and EC-28.

| Area | Items | Open |
|---|---:|---:|
| Flight, hyperjump, travel days (FL) | 23 | 0 |
| Weapons and damage (WP) | 27 | 0 |
| NPC AI, spawning, escorts (AI) | 43 | 1 |
| Economy, legal record, landed services (EC) | 28 | 11 |
| Missions and story (MS) | 24 | 1 |
| Outfit special systems (OS) | 14 | 2 |
| Player-facing rules: map, targeting, HUD, keys, saving (UI) | 18 | 1 |
| Data loading (LD) | 2 | 0 |

Open: OS-06, EC-04, EC-05, EC-07, EC-09, EC-10, EC-11, EC-12, EC-25, EC-26, OS-08, AI-44, UI-06, MS-19, EC-27, EC-28. The first paragraph under an open heading is the current gap. An older Done paragraph under the same heading is historical.

A few done items leave a small piece for later. These are the same on the Apple
app and the Godot frontend, because both call the shared engine:

- UI-11: about 20 status-line sentences the original does not print in those
  situations (contraband, plunder "Took N credits", siphoned fuel, transferred
  rounds, domination, defender scrambles, escort losses, "You are being scanned",
  the wormhole prompt, "Your ship has been destroyed"), and the original's
  new-pilot hint chain (STR# 2002 #22-31; overlaps NovaSwift's tutorial hints).
- UI-13: Tab / Shift-Tab page cycling in Player Info, and count words for junk cargo.
- UI-07: target cycling has no AI-state 0x15 filter, and a freed target slot is
  reused instead of keeping spawn order.
- UI-15: the map's Tab/backslash cycle is written from an inference. The two
  handlers sit inside the 0x004a3aa0 loop and are not decompiled on their own.
- AI-12: holding a mission ship at a gate.
- FL-23: the jump-engage countdown and the cannot-jump message auto-clear.

Not gaps, checked against the code on 2026-10-13: Caps Lock 2× mode
(`GameSpeedRules`, `CapsLockState`, matches the frame loop at 0x00417600), the
self-destruct cue sounds (arm 153, per-second 152, abort and blast 151), tractor
pull including a heavier ship holding a lighter one, and combat chatter (escort
acknowledgement, new target, target died, hull Flags2 0x0010 mute). Two things are
still unread: the `përs` HailQuote broadcast gates (flags 0x0400 and 0x0800, the
player-class gates, the ambush trigger), and eight smaller decompile questions
listed in the plan's "Reopened" section.

The plan also keeps a short list of open questions (mostly small constants that
still need an emulator run) and decisions for the maintainer, such as default
key bindings on macOS. See §6 and the end of the plan.

No decompiled code is in this repository. The specs describe behaviour in prose,
short formulas and constants, with the original function's address.

## The function grid

![One square per function in the original executable](branding/progress-blocks.svg?v=67e937bb)

One square per function in the EV Nova CE executable, grouped by subsystem.

| Colour | Meaning |
|---|---|
| Green | Checked against NovaSwift and matching: either it matched when compared, or the difference has been fixed. |
| Teal | Done differently by design: NovaSwift does the same job its own way (for example its own save format and input layer), with the same result for the player. |
| Amber | Checked and found to differ; the fix is in progress. |
| Red | Checked and found to differ from the original; not fixed yet. |
| Blue | Gameplay code, decompiled and assigned a role, but not yet checked against NovaSwift. |
| Outline | Gameplay code whose role is still unknown. |
| Dark grey | Nothing to port: C runtime, QuickTime, image and audio libraries, networking, blitters, Windows glue, the shareware nag, plus drawing and debug plumbing found during checking. |

The grid was redrawn after the 16 items were reopened. Rule, reproducible with
`python3 scripts/reopen-progress.py`: a function that was green, is cited by at
least one plan item, and is cited by no item marked **DONE** is amber. The 16 open
items are the ones whose heading is not **DONE** in the plan. Functions confirmed
by the line-by-line comparison (no citing item) stay green.

3,199 functions: 638 green, 33 teal (done differently by design), 13 amber, 0 red,
0 blue, 2,515 dark grey. Of the 697 gameplay functions, 506 are green, 24 teal
(NovaSwift's own save format, input layer, frame loop, and SwiftUI lists and
dialogs), 13 amber, and 154 drawing or debug plumbing. The 13 amber functions are
the ones only OS-06, EC-07, EC-09, EC-12, EC-26, MS-19 and UI-06 cite. The other
open items cite functions that other, finished items also cite, so those squares
stay green: green means "matched when compared", and an open item can concern only
one slice of a function. The tooltips list each square's citing items, taken from
the plan as it stood at the last full redraw; a few may name an item that no longer
lists that address.

## Original bugs and quirks

The original executable is ground truth, including behaviour a reimplementation called a bug and changed. NovaSwift keeps those quirks. A `DeathDelay` of 0 or 1 does not leave an immortal ghost: NovaSwift uses a 1.8 s death instead, on purpose. Ships with `shän` Flags 0x0002 do not fold or unfold for hyperspace or landing. Fleet ships are spawned with empty holds. The kept quirks and the still-open questions are in §6 of [FIDELITY_PLAN.md](reverse-engineering/FIDELITY_PLAN.md).

That is a measure of how much code has been compared, not a promise that the
game plays identically or is bug-free. A comparison can miss timing, ordering
and interaction effects that only show up in play, and NovaSwift is still in
beta. Reports of anything that plays differently from the original are the
most useful feedback.

A function is checked in one of two ways: a completed item in
FIDELITY_PLAN.md cites its address, or a line-by-line comparison of its
decompiled code against NovaSwift found it matching or found a difference that
has since been fixed. A function cited only by open items is amber, not green.

The grid is drawn from the function map, the addresses cited in
FIDELITY_PLAN.md and the line-by-line comparison results. Those are read by a
generator in the private reverse-engineering workspace (it needs the decompiled
export, which is not in this repository). It writes
[progress-blocks.svg](branding/progress-blocks.svg?v=67e937bb) for this page and
`site/assets/progress.json` for the website's interactive version. In this
repository, `scripts/reopen-progress.py` applies the amber rule to that data,
recomputes every count, and redraws the grid and the summary chart. Run it after
the generator, because the generator has no amber state for open items. The site
shows each function's name, address, size, subsystem and citing items.

## Enhancements

Where NovaSwift used to behave differently from the original and the old
behaviour was worth keeping, it became an option in Settings ▸ Enhancements. All
are off by default:

| Enhancement | What it changes |
|---|---|
| Manual plug-in order | Choose which plug-ins load and in what order. The original loads every installed plug-in alphabetically. |
| Frequent autosave | Save on every jump, every few minutes and when the app is backgrounded. The original saves only when you leave a spaceport. |
| Quick hyperjump | Jump after a short turn and burst. The original brakes to a stop and spins up for the length of its warp sound. |
| Forgiving landing | Land from a wider circle at higher speed, with no clearance step. |
| Automatic route plotting | Tap any system to plot the shortest route. The original plots one jump per click. |
| Nearest-first targeting | Target cycling starts with the closest ship. The original goes in arrival order. |
| Modern key layout | Return fires secondaries, Shift is the afterburner, P pauses. |
| Tight formations | Escorts and fleets hold formation exactly. In the original they fly on their own hull's momentum. |

Differences with no value of their own were simply fixed, with no option: for
example the old commodity table, full refunds on sold outfits, and gate travel
costing a day.

## Beyond the original

![NovaSwift's own features](branding/feature-blocks.svg?v=5aa50c06)

NovaSwift's own features, one square per task: green done, amber partly done,
outline planned. Currently 163 done, 22 partly done, 28 planned. The list is kept
by hand in `site/assets/features.json`, with a pointer to the code for each
task. After editing it, run `python3 scripts/render-progress.py` to redraw
[feature-blocks.svg](branding/feature-blocks.svg?v=5aa50c06) and the summary graphic.

Partly done, in short: the public online lobby list and iCloud game-data upload
need the CloudKit schema promoted to Production; multiplayer host migration
rebuilds the world rather than handing over; the `carryEncounter` session rule
is not used yet; no plug-ins ship inside the app; the Godot port's Linux build is only headless-verified and its Windows build is not built yet (table below); the Godot port's Key Settings dialog, `.mov` title music, shot murk fog and the S26 map rule are written but not yet built, and its LAN multiplayer, plug-in editor and HD packs are planned. Live 3D hulls are written but not yet checked on real devices. Multiplayer has not yet
been played end to end on two real devices. The plug-in importer can't open
StuffIt archives that use the newer compression methods, and most catalog
entries have no icon yet. Classic Mac pilot import still needs testing against
more real pilots. Smooth rotation only applies to HD ships.

HD graphics and 3D models work in game: HD sprite sheets, 3D models rendered
into every frame (with engine glow, running lights and weapon flash), HD
planets, and HD ship pictures in the shipyard and target display. Still to do:
glTF import, live 3D with real-time lighting, lighting from nearby stars, HD
landing pictures and interface art, sound and music packs, and HD in the Linux
and Windows build.

None of these change the game's rules:

- Presentation presets: Classic, Enhanced, Nova Swift, with per-item overrides.
- Story Guide and storyline map, storyline tags on missions, tutorial hints,
  a flight-training range.
- Touch controls; complete controller support — remapping, an on-screen cursor that reaches every screen, sheet, dialog and alert (Ⓑ back, d-pad snapping, right-stick scrolling), DualSense adaptive triggers ([CONTROLS.md](CONTROLS.md)).
- Apple TV build with a 10-foot UI ([TVOS.md](TVOS.md)).
- iCloud sync of imported game data ([ICLOUD_SYNC.md](ICLOUD_SYNC.md)).
- Plug-in store and manager.
- Co-op multiplayer over local Wi-Fi or Game Center, with host-set rules
  ([MULTIPLAYER.md](MULTIPLAYER.md)).
- HD graphics and 3D models from plug-ins, drawn in place of the original
  sprites with the original hit-boxes, frames and exit points
  ([HD_PIPELINE.md](HD_PIPELINE.md)). Off by default.
- Debug suite: searchable logs (tap a line to copy, re-run or filter it),
  frame-time breakdown, inspector, console.
- Bug reports: Settings ▸ Support ▸ Report a Bug collects the pilot, a log and
  a self-test.

## Linux and Windows

The Godot frontend ([GODOT_LAYER.md](GODOT_LAYER.md)) runs the same engine and calls the same Swift helpers as the Apple app, so wherever a helper still differs from the executable, the open plan items apply on both frontends (EC-04, EC-05, EC-25, OS-06, EC-26, OS-08, UI-06). This section is only about frontend wiring. The row-by-row list is [GODOT_FIDELITY_GAPS.md](GODOT_FIDELITY_GAPS.md).

Packaging (local, no CI; see [PACKAGING.md](PACKAGING.md)): the macOS arm64 app is exported, ad-hoc signed and loads the extension headless. The Linux x86_64 / Steam Deck tarball is built in a `swift:6.3-jammy` container (`scripts/package-linux-docker.sh`), needs glibc 2.35 at most, resolves every library, and in a clean Ubuntu 22.04 container the exported binary loads the extension and parses the game data headless. It has not been run on a real Steam Deck or with a GPU. The Windows package script (`scripts/package-windows.ps1`) is written but has not been run: it needs a Windows PC with the Swift toolchain. No flight visual has been checked on a real GPU on any of these.

| Subsystem | State |
|---|---|
| Flight, HUD, radar, targeting, landing, spaceport, story runtime, pilots, gamepad | Done, run on macOS |
| Live-world wiring (combat rating, scooping, përs spawn gating, pirates boarding the player, defence persistence, bombs, Strict Play) | Done and self-checked (package A) |
| Status line, messages, HUD icons | Done and self-checked (package B) |
| Controls and targeting checklist, performance (release bridge, sprite cache and prewarm, asteroid layout) | Done |
| Plug-ins: all 13 catalog plug-ins load with the same counts as the shared merge and pass `scripts/plugins-check.sh` | Done |
| Total-conversion add-on lists, `dësc` movies, intro movie and GIF, total-conversion fonts, bar race movies | Done, in both apps |
| Hypergate and wormhole entry movies | Done, built and run on macOS (both apps) |
| Galaxy map: borders, mission markers, Tab and backslash link cycle | Done, built and run on macOS. The cycle is an inference (handlers not decompiled) |
| Sound-parity fixes, spaceport ambient loop, brightness veil | Done, built and run on macOS |
| About-dialog picture | Done, built and run on macOS |
| Key Settings dialog (DITL 4002), title music from a `.mov`, shot murk fog, `playMovies` gate audit, NPC warp-effect check, map link-cycle and silent-J sounds (S25, S26) | Written 2026-10-13, not yet built or run (self-checks in `godot/tests/`) |
| Sound S12 (`quickHyperjump` charge loop) | Open: the enhancement itself is not ported to Godot |
| Linux, Windows and Steam Deck builds; flight visuals on a real GPU | Not verified |

## Known gaps

- The 16 open plan items listed above.
- The deferred pieces listed above (UI-11, UI-13, UI-07, UI-15's map cycling, AI-12, FL-23).
- Open questions in §6 of the fidelity plan.
- Ships with `shän` flag 0x0002 do not fold and unfold for hyperspace or
  landing.
- Apple app, found against the decompile and not yet fixed: the Classic status-message rectangle (ours is 16/8 px with a 14 pt shadow; the original is left + 25, bottom - 5, 30 px, 12 pt white, no shadow); title music is scaled by the volume step twice (step/8 squared); the ambient and quick-hyperjump loops are scaled by the Effects slider twice; the ambient check is `>= 0` where the original requires `>= 128`. The newest total-conversion and gate-movie edits in the Apple app have not been compiled yet.
- Mission BBS and offer windows lack the original's map, Player Info and
  text-scroll keys.
- Presentation defaults that differ from the original (ship bar position,
  screen shake, storyline tags, tutorial hints) are kept on purpose and await a
  decision.
- Two cosmetic `cölr` fields have no target: `menuFont`/`menuFontSize` (our main
  menu labels are PICT art) and `progressBar` (our loading bar reflows).

Bugs go in the [issue tracker](https://github.com/SirStig/NovaSwift/issues).
