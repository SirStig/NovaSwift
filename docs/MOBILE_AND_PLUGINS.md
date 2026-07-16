# Mobile UX, Launcher & Plug-in Management

Design decisions for touch controls, the launcher/menu, and how plug-ins ship on
mobile. Locked 2026-07-07.

## 1. Touch controls (iPhone / iPad)

EV Nova is keyboard-driven (turn left/right, thrust, fire, secondary, target,
land, jump, map…). We map that to a touch scheme, with a controller option.

- **Flight (default "virtual cockpit"):**
  - Left thumb: a turn zone (drag left/right to rotate, or two on-screen arrows).
  - Right thumb: **thrust** button + **fire** button.
  - Secondary weapon, target-nearest, and afterburner as smaller buttons.
  - Optional **tilt-to-turn** and **tap-to-turn-toward** (point ship at tap) as
    accessibility/simplified modes.
- **Gestures:** pinch = zoom; two-finger tap = secondary fire; swipe up near a
  planet = land; dedicated buttons for **hyperspace jump** and **map**.
- **HUD is touch-native:** radar, target, shields/armor bars are tappable
  (tap a radar blip to target it).
- **Controller:** full MFi / PS / Xbox controller support on iOS & macOS
  (twin-stick: left = turn/thrust, right = aim/secondary).
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
2. **On-demand streamed install.** Tapping Install (`PluginStoreView.swift`)
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
