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
After a later re-read, 16 of the plan's 179 items were reopened; all 16 are now implemented in code and awaiting build and test (see below).
Original behaviour is the default. The Linux/Windows frontend plays through on
macOS and is partway done; its status table is under
[Linux and Windows](#linux-and-windows). The auto-updater and the packaging
scripts are summarised there too.

Two labels recur below. **Built and tested** means the maintainer compiled it and
played it on macOS. **Written, not yet built** means the code is in the tree and was
only syntax-checked: the closing passes of 2026-10-13 (listed under "A few done
items") are in that state.

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

The plan has 179 items in eight areas, and all 179 are done. A later read of the executable had reopened 16 items whose heading said done (and added EC-27 and EC-28); all 16 were implemented in both apps on 2026-10-13 and are marked **DONE** (awaiting build/test) while the maintainer builds and tests them.

| Area | Items | Open |
|---|---:|---:|
| Flight, hyperjump, travel days (FL) | 23 | 0 |
| Weapons and damage (WP) | 27 | 0 |
| NPC AI, spawning, escorts (AI) | 43 | 0 |
| Economy, legal record, landed services (EC) | 28 | 0 |
| Missions and story (MS) | 24 | 0 |
| Outfit special systems (OS) | 14 | 0 |
| Player-facing rules: map, targeting, HUD, keys, saving (UI) | 18 | 0 |
| Data loading (LD) | 2 | 0 |

Completed 2026-10-13 (awaiting build and test): OS-06, EC-04, EC-05, EC-07, EC-09, EC-10, EC-11, EC-12, EC-25, EC-26, OS-08, AI-44, UI-06, MS-19, EC-27, EC-28. Each has a "Status 2026-10-13" line saying what was implemented; the "Still open" paragraph under it describes the gap that code was written to close. An older Done paragraph under the same heading is historical.

Implemented 2026-10-13, awaiting build and test (written in code, not compiled or run):

- OS-06: wormhole exit draw (`NovaGame.wormholeExit`, `SpobRes.hyperLinkSlots`). Stock wormhole HyperLink use is still unmeasured.
- EC-04: landing clearance now serves hypergates and wormholes; the invented gate permission helper is gone.
- EC-05: the landing fee is charged at gate entry, even when the hypergate then does nothing (`LandedServices.chargeGateFee`).
- EC-07: sell refusals follow the original (half price for units owned when the outfitter opened, full refund for units bought this visit).
- EC-09: stock fittings from the hull are tracked as a separate bank. This adds a `stockBank` field to the pilot save; old saves decode without it and treat everything as owned.
- EC-10: rank privilege bits (Flags 0x0100/0x0200) spread over allied governments, derelicts excluded.
- EC-11: a cancelled ship purchase no longer redraws the daily BuyRandom roll.
- EC-12: RequireGovt waiver scopes skip the bit test and allow the buy; owning one no longer short-circuits the lock state.
- AI-44: the hail beep follows the original cloak visibility threshold.
- EC-25: a bribe is one approach, not a permit (`bribeWaiverStellar`). Two recorded deviations: the waiver applies to a selected hypergate, and the hypergate fee is charged before the map opens.
- EC-26: the bar's previous gambling winner resets when the bar opens.
- EC-27: commodity overflow shrinks the six ordinary bins (`shrinkCargoToCapacity`).
- EC-28: chart, paint, amnesty and Flags 0x0010 limits last for the visit.
- OS-08: bomb fuse is reseeded on every recompute; a lethal bomb outranks a nonlethal one.
- MS-19: random cargo quantity uses the original's `floor` for negative values.
- UI-06: Land with no selection picks the nearest travel stellar the way the original does (16 nav slots, gate radius 500 px).

These 16 headings now read **DONE** (implemented 2026-10-13, awaiting build/test), and the grid has been regenerated from them: 671 of 671 portable gameplay functions are green or teal. If a build or test shows one of these fixes does not hold, its heading goes back to **OPEN** and the grid is regenerated.

A few done items left a small piece for later. These are the same on the Apple
app and the Godot frontend, because both call the shared engine. The closing passes
of 2026-10-13 wrote all of the following, **written, not yet built or tested**
(details at the end of the plan, "2026-10-13 closing pass"):

- UI-11: the invented status-line sentences were replaced with the original's
  STR# 2002 text or removed (contraband scan and fine, plunder, siphoned fuel,
  transferred rounds, salvage, domination, defender scrambles, escort losses, the
  wormhole prompt, "Your ship has been destroyed"), and the new-pilot travel hint
  chain (STR# 2002 #22-31) was added. The `përs` HailQuote broadcast got its
  player-class gates (flags 0x1000 / 0x2000 / 0x4000) and the announcement beep.
- UI-13: Tab / Shift-Tab page cycling in Player Info and the original cargo
  sentence with count words. Extras and Honors prose with `similar_to` grouping is
  in the working tree from a later edit (`PlayerInfoPages.swift`), also not built.
- UI-07: target cycling follows slot order (a freed slot is reused) and skips ships
  in AI state 0x15.
- Folding hulls (`shän` Flags 0x0002 and 0x0080): fold and unfold for takeoff,
  arrival, jump and the stop box, and the 0x0080 "unfolds to fire" rule.
- The eight decompile questions: six closed with no gap; two real gaps fixed (the
  `OnShipDone` auto-abort effects, and stale `<DL>` slot dates).
- Apple fixes: Classic status-message rectangle, music and ambient loops no longer
  scaled twice, ambient sound ID check `>= 128`.

Still deferred:

- UI-15: the map's Tab/backslash cycle was built and tested, but it is written from
  an inference. The two handlers sit inside the 0x004a3aa0 loop and are not
  decompiled on their own.
- AI-12: holding a mission ship at a gate.
- FL-23: the jump-engage countdown and the cannot-jump message auto-clear.
- Disabled-hull visuals (shän Flags 0x0010 pauses the animation, 0x0020 freezes the alt
  layer) and the Player Info Extras/Honors prose: written 2026-10-13, awaiting build/test
  (see "2026-10-13 leftovers" at the end of the plan).

Not gaps, checked against the code on 2026-10-13: Caps Lock 2× mode
(`GameSpeedRules`, `CapsLockState`, matches the frame loop at 0x00417600; nothing
else reads the key), the self-destruct cue sounds (arm 153, per-second 152, abort
and blast 151), tractor pull including a heavier ship holding a lighter one, combat
chatter (escort acknowledgement, new target, target died, hull Flags2 0x0010 mute),
miners after an assistance request, the carrier escort's weapon-1 range, the `chär`
Initial Record order, the extra carrier-jump cases (a fighter that cannot jump is
recovered, not lost) and the STR# 2002 #36 tractor refusal (never printed).

The plan also keeps a short list of open questions (mostly small constants that
still need an emulator run) and decisions for the maintainer, such as default
key bindings on macOS. See §6 and the end of the plan.

No decompiled code is in this repository. The specs describe behaviour in prose,
short formulas and constants, with the original function's address.

## The function grid

![One square per function in the original executable](branding/progress-blocks.svg?v=54f46d60)

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

The grid was regenerated on 2026-10-13 after the 16 reopened items were implemented and their headings marked **DONE** (awaiting build/test). Rule, reproducible with
`python3 scripts/reopen-progress.py`: a function that was green, is cited by at
least one plan item, and is cited by no item marked **DONE** is amber. An open
item is one whose heading is not **DONE** in the plan; there are none at present. Functions confirmed
by the line-by-line comparison (no citing item) stay green.

3,199 functions: 651 green, 33 teal (done differently by design), 0 amber, 0 red,
0 blue, 2,515 dark grey. Of the 697 gameplay functions, 519 are green, 24 teal
(NovaSwift's own save format, input layer, frame loop, and SwiftUI lists and
dialogs), 0 amber, and 154 drawing or debug plumbing: 671 of 671 portable functions.
All 179 plan items are marked **DONE**. The 16 completed on 2026-10-13 (listed above),
and the other 2026-10-13 closing-pass work, are implemented but not yet built and tested
by the maintainer; the grid shows them as done on that basis.

## Original bugs and quirks

The original executable is ground truth, including behaviour a reimplementation called a bug and changed. NovaSwift keeps those quirks. A `DeathDelay` of 0 or 1 does not leave an immortal ghost: NovaSwift uses a 1.8 s death instead, on purpose. Ships with `shän` Flags 0x0002 fold and unfold (written 2026-10-13, not yet built); landing needs no extra unfold. Fleet ships are spawned with empty holds. The kept quirks and the still-open questions are in §6 of [FIDELITY_PLAN.md](reverse-engineering/FIDELITY_PLAN.md).

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
[progress-blocks.svg](branding/progress-blocks.svg?v=54f46d60) for this page and
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

![NovaSwift's own features](branding/feature-blocks.svg?v=c70227e9)

NovaSwift's own features, one square per task: green done, amber partly done,
outline planned. Currently 165 done, 25 partly done, 28 planned. The list is kept
by hand in `site/assets/features.json`, with a pointer to the code for each
task. After editing it, run `python3 scripts/render-progress.py` to redraw
[feature-blocks.svg](branding/feature-blocks.svg?v=c70227e9) and the summary graphic.

Partly done, in short: the public online lobby list and iCloud game-data upload
need the CloudKit schema promoted to Production; multiplayer host migration
rebuilds the world rather than handing over; the `carryEncounter` session rule
is not used yet; no plug-ins ship inside the app; the Godot port's Linux build is only headless-verified, its Windows package has been run on one PC only and its auto-updater is untested end to end (table below); the Godot port's Key Settings dialog, `.mov` title music, shot murk fog, quick hyperjump and the S26 map rule are written but not yet built, and its LAN multiplayer, plug-in editor and HD packs are planned. Live 3D hulls are written but not yet checked on real devices. Multiplayer has not yet
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

The Godot frontend ([GODOT_LAYER.md](GODOT_LAYER.md)) runs the same engine and calls the same Swift helpers as the Apple app, so wherever a helper still differs from the executable, the open plan items apply on both frontends. The fixes for EC-04, EC-05, EC-25, OS-06, EC-26, OS-08 and UI-06 are written in both apps and in the Godot bridge, awaiting build and test. This section is only about frontend wiring. The row-by-row list is [GODOT_FIDELITY_GAPS.md](GODOT_FIDELITY_GAPS.md).

Packaging (local, no CI; see [PACKAGING.md](PACKAGING.md)): the macOS arm64 app is exported, ad-hoc signed and loads the extension headless. The Linux x86_64 / Steam Deck tarball is built in a `swift:6.3-jammy` container (`scripts/package-linux-docker.sh`), needs glibc 2.35 at most, resolves every library, and in a clean Ubuntu 22.04 container the exported binary loads the extension and parses the game data headless. It has not been run on a real Steam Deck or with a GPU. The Windows x86_64 package is built on a Windows 11 PC with the Swift 6.3.3 toolchain (`scripts/package-windows.ps1`; under Windows PowerShell 5.1 the script stops on a harmless Godot warning, so the same steps were run by hand) and has been run there with EV Nova CE data. It is attached to the v0.7.0-beta.2 release. It has not been run on other Windows machines. No flight visual has been checked on a real GPU on any of these. The local container runtime is Colima (vz with Rosetta); there is no GitHub CI.

Auto-updater ([UPDATER.md](UPDATER.md), `godot/updater/`): built. A signing key has been generated (the public key is in `godot/updater/`, the private key is outside the repository) and `scripts/release-sign.sh` signs release manifests. It offers Skip This Version / Later / Update Now, has a stable and an experimental channel (Settings ▸ Support ▸ Updates), and can return to stable from an experimental build. It has not been tested end to end: no signed release has been published and installed yet. It does not touch the Apple app.

| Subsystem | State |
|---|---|
| Flight, HUD, radar, targeting, landing, spaceport, story runtime, pilots, gamepad | Done, run on macOS |
| Live-world wiring (combat rating, scooping, përs spawn gating, pirates boarding the player, defence persistence, bombs, Strict Play) | Done and self-checked (package A) |
| Gate and wormhole clearance, fee and exit draw, bribe waiver, bar gambling reset, outfitter bank and visit-scoped items, nearest-stellar Land, bomb fuse, rank privileges (OS-06, EC-04, EC-05, EC-09, EC-10, EC-25, EC-26, EC-28, OS-08, UI-06) | Written 2026-10-13, not yet built or run (`godot/tests/fidelity_selfcheck.gd`, `gameplay_gaps_selfcheck.gd`) |
| Status line, messages, HUD icons | Done and self-checked (package B) |
| Controls and targeting checklist, performance (release bridge, sprite cache and prewarm, asteroid layout) | Done |
| Plug-ins: all 13 catalog plug-ins load with the same counts as the shared merge and pass `scripts/plugins-check.sh` | Done |
| Total-conversion add-on lists, `dësc` movies, intro movie and GIF, total-conversion fonts, bar race movies | Done, in both apps |
| Hypergate and wormhole entry movies | Done, built and run on macOS (both apps) |
| Galaxy map: borders, mission markers, Tab and backslash link cycle | Done, built and run on macOS. The cycle is an inference (handlers not decompiled) |
| Sound-parity fixes, spaceport ambient loop, brightness veil | Done, built and run on macOS |
| About-dialog picture | Done, built and run on macOS |
| Key Settings dialog (DITL 4002), title music from a `.mov`, shot murk fog, `playMovies` gate audit, NPC warp-effect check, map link-cycle and silent-J sounds (S25, S26) | Written 2026-10-13, not yet built or run (self-checks in `godot/tests/`) |
| Quick hyperjump enhancement and its charge loop (S12), original status-line text, travel hint chain, Player Info Tab cycling, `përs` quote gates | Written 2026-10-13, not yet built or run (`closing_pass_selfcheck.gd`, `status_text_closing_selfcheck.gd`) |
| macOS arm64 package | Built and verified headless |
| Linux x86_64 / Steam Deck package | Built and verified headless in containers; not run on a real Deck or GPU |
| Windows package | Built and run on one Windows 11 PC with EV Nova CE data; on the v0.7.0-beta.2 release |
| Auto-updater, experimental channel, release signing | Built; not tested end to end |
| Flight visuals on a real GPU | Not verified |

## Known gaps

- The 16 plan items completed 2026-10-13 (listed above): implemented, awaiting the maintainer's build and test. EC-09 adds a `stockBank` field to the pilot save (old saves still load).
- The deferred pieces listed above (UI-15's map cycling inference, AI-12, FL-23) and the closing-pass work that is written but not yet built.
- Open questions in §6 of the fidelity plan.
- Apple app, found against the decompile and fixed 2026-10-13 (written, not yet built): the Classic status-message rectangle, title music scaled by the volume step twice, the ambient and quick-hyperjump loops scaled by the Effects slider twice, and the ambient check (`>= 128`). The newest total-conversion and gate-movie edits were built and tested on macOS.
- Mission BBS and offer windows lack the original's map, Player Info and
  text-scroll keys.
- Presentation defaults that differ from the original (ship bar position,
  screen shake, storyline tags, tutorial hints) are kept on purpose and await a
  decision.
- Two cosmetic `cölr` fields have no target: `menuFont`/`menuFontSize` (our main
  menu labels are PICT art) and `progressBar` (our loading bar reflows).

Bugs go in the [issue tracker](https://github.com/SirStig/NovaSwift/issues).
