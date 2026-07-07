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

## 3. Plug-ins on mobile: prebundle + toggle (+ import)

**Problem:** desktop EV Nova users drop plug-in files into a folder. iOS sandboxes
the filesystem, so we can't rely on that as the primary mechanism.

**Decision:**
1. **Prebundle a curated catalog** of freely-distributable community plug-ins and
   total conversions inside the app, each **individually toggleable** in the
   launcher. This is the primary mobile mechanism.
2. **Also support user import** (iOS *does* allow this): `UIDocumentPicker` /
   share-sheet / Files "Open in" / AirDrop can bring a `.rez`/`.ndat`/`.zip`
   plug-in into the app's container. So power users aren't limited to the bundle.
3. A **`PluginManifest`** describes each catalog entry (id, display name, author,
   kind = totalConversion | patch | gameplay, requires-base flag, description,
   file list). The launcher renders this; the engine loads the enabled set as an
   **override chain** over the base data (via `ResourceCollection.overlay`, in a
   defined order — base first, then enabled plug-ins).

**Load order & conflicts:** base → gameplay patches → (at most one) total
conversion, applied in a deterministic order; later layers override by
`(type, id)`. Total conversions are treated as mutually exclusive "scenarios"
(you play *one* TC at a time); small gameplay plug-ins can stack.

**⚠ Redistribution caveat (must resolve before App Store):** community plug-ins
are free to *download and play*, but *bundling* them in a shipped app needs each
author's permission. For development we gather the free catalog; for release we
either (a) obtain per-author permission, or (b) fall back to import-only for any
plug-in we can't clear. Base game data is **never** bundled (copyright).

## 4. The base-data problem on mobile (important)

Plug-ins and total conversions **require the copyrighted EV Nova base data**,
which we cannot bundle. So every mobile user must import their **own** owned copy
once:

- **Import flow:** launcher → "Import EV Nova Data" → `UIDocumentPicker` to select
  their `Nova Files` folder / `.ndat` / the game archive (or receive via
  AirDrop / Files / iTunes file sharing). We copy it into the app's
  Application Support container and index it.
- After import, the bundled plug-ins "light up" (they have a base to override).
- Until import, only content that ships with full permission (if any) is
  playable; the UI clearly explains the BYO-data requirement.
- macOS: same importer, plus the option to point at an existing install.

This keeps us on clean legal footing (BYO base data) while giving mobile users a
rich, toggle-able plug-in library out of the box.
