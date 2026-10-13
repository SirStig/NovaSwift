# Mobile UX, Launcher & Plug-in Management

Design decisions for touch controls, the launcher/menu, and how plug-ins ship on
mobile.

> **Design, partly built.** See [STATUS.md](STATUS.md) for what's live.

## 1. Touch controls (iPhone / iPad)

EV Nova is keyboard-driven (turn left/right, thrust, fire, secondary, target,
land, jump, map…). We map that to a touch scheme, with a controller option.

- **Flight (default "virtual cockpit"):**
  - Left thumb: a turn zone (drag left/right to rotate, or two on-screen arrows).
  - Right thumb: **thrust** button + **fire** button.
  - Secondary weapon, target-nearest, and afterburner as smaller buttons.
  - Optional **tilt-to-turn** and **tap-to-turn-toward** (point ship at tap) as
    accessibility/simplified modes.
- **Gestures (planned, not built):** pinch to zoom in flight, two-finger tap for
  secondary fire, swipe up near a planet to land. Pinch zoom works on the galaxy
  map only.
- **HUD (planned):** tap a radar blip to target it.
- **Controller:** MFi / PlayStation / Xbox controllers on every platform, with
  remapping and an on-screen cursor for menus (see [CONTROLS.md](CONTROLS.md)).
- Control scheme + button layout + sensitivity live in Settings (below).
- Implementation: an input-abstraction layer (`ControlIntent` — turnLeft,
  turnRight, thrust, firePrimary, …) that touch, keyboard, and controller all
  feed. The engine only ever sees `ControlIntent`, never raw input.

## 2. Launcher / main menu

A native SwiftUI launcher shown before/around the game scene:

- **Play / Continue** (resume last pilot), **New Pilot**.
- **Scenario / Plug-ins** — pick the active scenario (base EV Nova or a total
  conversion) and toggle individual plug-ins on/off (see §3).
- **Settings** — controls (scheme, layout, sensitivity, invert), graphics
  (resolution scale, effects, starfield density), audio (music/SFX volume),
  gameplay (difficulty, autopilot), accessibility (colorblind, larger HUD).
  Persisted via `UserDefaults` / a `Settings` model.
- **Import Data** — first-run + anytime flow to bring in the user's owned EV Nova
  base data (see §4).
- **About / Credits / Legal.**

Settings and the enabled-plug-in set are persisted and read by the engine at
scene start (and hot-reapplied where cheap).

## 3. Plug-ins on mobile: browsable store + on-demand install (+ import)

**Problem:** desktop EV Nova users drop plug-in files into a folder. iOS sandboxes
the filesystem, so we can't rely on that as the primary mechanism.

**As shipped today:**
1. **A bundled, metadata-only store.** `PluginCatalog.json` (~23 entries) plus
   their screenshots ship inside the app bundle and load from `Bundle.module`
   (`PluginCatalog.swift`), so **browsing** the store — names, authors,
   descriptions, screenshots — works fully offline. Every entry currently has
   `prebundled: false` (`PluginCatalogEntry.prebundled`): no plug-in's actual
   game data ships in the bundle, only its catalog listing.
2. **On-demand streamed install.** Tapping Install (`app/NovaSwift/Plugins/`)
   streams the archive directly from the original third-party host —
   `andrews05`'s EV Stuff mirror or `download.escape-velocity.games` — via
   `PluginDownloader`, straight into the app's plug-ins directory
   (`PluginInstaller`). The app never mirrors or redistributes the file itself;
   nothing beyond JSON + screenshots is bundled. This needs network and is the
   primary mechanism for actually playing a catalog plug-in.
3. **User import** (iOS *does* allow this): `UIDocumentPicker` / share-sheet /
   Files "Open in" / AirDrop can bring a `.rez`/`.ndat`/`.zip` plug-in into the
   app's container, so power users aren't limited to the catalog.
4. A **`PluginCatalogEntry`** (`PluginCatalogEntry.swift`) describes each catalog
   entry: id, name, author, kind, requiresBase, description, sourceURL,
   screenshotNames, etc. The launcher/store renders this; once a plug-in is
   installed (by download or import), the engine loads the enabled set as an
   **override chain** over the base data (via `ResourceCollection.overlay`, in a
   defined order — base first, then enabled plug-ins). *Not* to be confused with
   `NovaSwiftNet.PluginManifest`, an unrelated type: the set of enabled-plugin
   `(id, contentHash)` pairs exchanged at multiplayer session join to detect
   desync (see `docs/MULTIPLAYER.md`).

**True prebundling — a real plug-in's data shipped read-only in the app,
enable/disable-only, no download needed — is a still-unbuilt option.**
`GameDataController` already has the hook for it (a `bundledPluginsDir` that
checks `Bundle.main` for a `Plugins/` resource folder, plus `isPrebundled(_:)`
to mark such plug-ins non-deletable), but no `Plugins/` folder exists anywhere
in the app target today, so the hook is currently a no-op. That's a direct
consequence of the redistribution caveat below, not an oversight: we can't ship
a plug-in's bytes in the bundle until its author has cleared that, so for now
every catalog entry stays `prebundled: false` and is fetched on demand instead.

**Load order & conflicts:** base → gameplay patches → (at most one) total
conversion, applied in a deterministic order; later layers override by
`(type, id)`. Total conversions are treated as mutually exclusive "scenarios"
(you play *one* TC at a time); small gameplay plug-ins can stack.

**Add-ons for a total conversion (per-TC plug-in list, 2026-10-13).** The original rule: Nova runs
from a data root `9:`; `nv_WinMain` 0x004d2a80 opens `Nova.rez`, then
`Resource_ValidateInstallFolders` 0x004bd160 loads `9:Nova Files` (`nv_LoadFilesInFolder` 0x0046f500,
top-level `.rez` only, directories skipped via `FileEnumerator_NextMatchingExt` 0x004f1d70) and, when
the registration gate is open, `Nova Plug-Ins` (`FUN_0087265d` 0x0087265d, falling back to `Plug-Ins`).
A total conversion is run by pointing the data root at *its* folder, so its own `Nova Files` +
`Plug-Ins` replace the stock ones, only `Nova.rez` is shared, and the user's global plug-ins are
never seen. Playing EVO Facelift on EV Override therefore meant copying its files into
`EV Override for Nova/Plug-Ins/`. We keep that rule (global plug-ins are not loaded under a TC) and add
the same thing without copying: `TCAddOns` (`Sources/NovaSwiftKit/TCAddOns.swift`) keeps, per TC id, an
ordered list of installed plug-ins (`[tcID: [{id,isEnabled}]]`). Load order: `Nova.rez` -> the TC's
`Nova Files` -> the TC's own `Plug-Ins` files (flat, by file name, as the original) -> the listed
add-ons in list order (each add-on's files by name); later wins. `PluginBundle.addOnIDs` carries the
enabled list into `GameLibrary.resolveLayers`, so merge, fingerprint, graphics catalog and the editor
all see it. A user who never touches the list gets exactly the original behaviour. Persistence:
Apple `UserDefaults` key `com.novaswift.plugins.tcaddons.v1`; Godot `plugins-state.json` key `tcAddOns`
(same JSON). UI: Plug-ins > Installed shows "Add-ons for <TC>" while a TC is on (add / remove /
enable / reorder, rows under it say "Not loaded under <TC>"). Suggestions (never automatic):
`TCAddOns.compatibility` (name / folder / read-me mentions the TC's aliases: EVO for EV Override,
or another installed TC's name -> "made for X") and `TCAddOns.overlap` (records of the plug-in that
replace TC records by the same name = made for it; by a different name = made for the base game).
A "Base game?" plug-in asks for a second confirmation but can still be added. Media follows the
same folders: `TCAddOns.mediaDirectories` (the TC's add-ons, Plug-Ins, Nova Files, then base) feeds
music, `dësc` movies and the TC's font files (`Sillycon.ttf`).

**⚠ Redistribution caveat (why we don't prebundle today):** community plug-ins
are free to *download and play*, but *bundling* their data in a shipped app
needs each author's permission — which is exactly why the catalog above ships
as metadata + on-demand download rather than prebundled content. For any given
plug-in we either (a) obtain per-author permission and flip it to
`prebundled: true` in a real `Plugins/` bundle folder, or (b) leave it
download/import-only, which is the default and current state for the whole
catalog. Base game data is **never** bundled (copyright).

## 4. The base-data problem on mobile (important)

Plug-ins and total conversions **require the copyrighted EV Nova base data**,
which we cannot bundle. So every mobile user must import their **own** owned copy
once:

- **Import flow:** launcher → "Import EV Nova Data" → `UIDocumentPicker` to select
  their `Nova Files` folder / `.ndat` / the game archive (or receive via
  AirDrop / Files / iTunes file sharing). We copy it into the app's
  Application Support container and index it.
- After import, any installed or imported plug-ins "light up" (they have a base
  to override); the store catalog is browsable even before import, but
  installing a `requiresBase` entry is gated on it.
- Until import, nothing is playable (no prebundled content ships, per §3); the
  UI clearly explains the BYO-data requirement.
- macOS: same importer, plus the option to point at an existing install.

This keeps us on clean legal footing (BYO base data) while giving mobile users a
rich, browsable plug-in store to install from on demand.
