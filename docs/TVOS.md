# tvOS — NOVA Swift on Apple TV

**Status: wired.** NOVA Swift runs on Apple TV today. `Package.swift` declares
`.tvOS(.v16)` alongside macOS and iOS, and the app ships tvOS-specific
entitlements, layout, and a couple of Apple-TV-only conveniences described
below.

## Controller-required by design

The Siri Remote can't fly a ship, and the whole UI is cursor-driven (see
[CONTROLS.md](CONTROLS.md)), so NOVA Swift **requires an extended gamepad on
tvOS**. `RootView.swift` shows a full-screen `ControllerRequiredView` the
moment the app launches with no gamepad paired, and it lifts itself
automatically the instant one connects — no restart needed. This matches the
`GCSupportedGameControllers` (`ExtendedGamepad`) declaration in the tvOS
`Info.plist`, so tvOS itself won't launch the app without also prompting for a
controller.

Once a pad is connected, the controller-driven cursor overlay
(`ControllerCursor.swift`) drives every menu and screen, and flight uses the
same twin-stick mapping as every other platform.

## 10-foot UI

Because a TV is viewed from across the room, tvOS gets its own layout pass
rather than a scaled-up phone UI: bigger dialogs and typography, no
touch/drag gestures, a custom `Stepper` replacement, and focus-engine
handling tuned for the Siri Remote's swipe surface (`PlatformCompat.swift`,
`NovaFormControls.swift`, `NovaDialog.swift`, `NovaDebug.swift`,
`GalaxyMapView.swift`, `GridPaging.swift`, `TouchControlsOverlay.swift`,
`Launcher/LauncherView.swift`, `Launcher/AuthenticMainMenuView.swift`).
`RootView.swift` also keeps SwiftUI's focus engine parked on a single
focusable root and swallows unhandled Menu/B presses, since tvOS otherwise
treats an unclaimed Menu press as "suspend the app" — which would quit to the
Home Screen the instant a player pressed their bound Menu button.

Game Center matchmaking (multiplayer's online transport, see
[MULTIPLAYER.md](MULTIPLAYER.md)) uses the same UI on tvOS as iOS/macOS.

## Getting your game data onto an Apple TV

An Apple TV has no Files app and no way to browse to a folder on your Mac, so
the normal "point the wizard at your EV Nova install" flow doesn't work
there. Two ways around that:

1. **iCloud auto-restore** — if you've already imported your data on another
   device and it's synced to your private iCloud (see
   [ICLOUD_SYNC.md](ICLOUD_SYNC.md)), the Apple TV build checks for it and
   restores automatically on first launch. This is also how the app
   self-heals if tvOS purges its sandboxed cache, since tvOS apps only get a
   caches-only storage directory (`NovaStorage.swift`) that the system can
   clear under storage pressure at any time.
2. **The local web importer** — if there's nothing in iCloud yet, the Data
   Setup wizard's Apple TV step spins up a tiny local HTTP server
   (`WebImportServer.swift`) on the Apple TV itself, on port **8017**, and
   shows the address to type into any browser on your Mac, PC, or phone —
   `http://<your-tv's-ip>:8017`. That page is a plain drag-and-drop uploader:
   drop your **Nova Files** folder (or the `.ndat`/`.rez` files inside it,
   plus optionally the soundtrack and fonts) and each file streams straight
   from your browser to the Apple TV over your local network. Nothing
   touches the internet — it's the same LAN your Apple TV and computer are
   already on, and the server only accepts a fixed allow-list of EV Nova file
   extensions (`.ndat`, `.rez`, `.mp3`, `.m4a`, `.aiff`, `.wav`, `.ttf`,
   `.otf`, `.mov`, `.mp4`, `.m4v`).

Once either path lands data on the Apple TV, the wizard reloads it exactly
like every other platform, and (if iCloud is signed in) the freshly-imported
data uploads back to the player's private iCloud so the next device — or the
next time tvOS purges the cache — restores automatically.

## Where it lives

| Piece | File |
|---|---|
| tvOS platform declaration | `Package.swift` |
| Controller-required gate | `app/NovaSwift/App/RootView.swift` |
| tvOS storage handling (caches-only sandbox) | `app/NovaSwift/App/NovaStorage.swift` |
| iCloud auto-restore on tvOS | `app/NovaSwift/App/AppModel.swift` |
| tvOS entitlements (iCloud/CloudKit) | `app/NovaSwift/NovaSwift-tvOS.entitlements` |
| Local web import server | `app/NovaSwift/Data/WebImportServer.swift` |
| Wizard panel that hosts it | `app/NovaSwift/Launcher/DataSetupWizard.swift` (`TVWebImportPanel`) |

## What's left

- Wider real-hardware testing (different Apple TV generations, different
  third-party controllers) beyond the initial bring-up.

tvOS is on TestFlight today, on the same public link as macOS/iPadOS/iOS —
see the README's [Beta / TestFlight](../README.md#beta--testflight) section.
