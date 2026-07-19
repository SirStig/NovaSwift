# Controller support

**Status: wired.** Full gamepad play — twin-stick flight, a rebindable action
map, and a controller-driven UI cursor — works today on macOS, iPadOS, iOS, and
is *required* on tvOS.

## What's wired

- **Twin-stick flight** — `GameControllerInput.swift` polls the connected
  `GCExtendedGamepad` every frame. The two thumbsticks are fixed, not
  rebindable, to match muscle memory from every other twin-stick game: left
  stick steers/thrusts (horizontal = turn, up = thrust, down = reverse), right
  stick is absolute aim (deflection past a deadzone sets `desiredHeading`
  directly, the same "aim where you point" model as a shooter).
- **Rebindable buttons** — every face button, shoulder, trigger, stick-click,
  d-pad direction, and Menu/Options is a `PadButton` (`PadBindings.swift`) the
  player can remap in the in-app Controls screen. Continuous actions (fire,
  throttle, afterburner) drive the per-frame flight intent; discrete actions
  (land, jump, open map, cycle target, …) fire once on the press edge, the
  same dispatch path the keyboard bindings use.
- **Any MFi / Xbox / PlayStation pad** — `GameController` framework, so
  anything Apple's controller stack recognizes works out of the box, and
  `PadButton.displayName(on:)` shows the *connected* controller's own labels
  (e.g. "Cross" on a DualSense) rather than generic Xbox-style letters.
  `PadGlyph.swift` renders the matching SF Symbol glyph in the Controls UI.
- **Adjustable stick deadzone** — a "Stick dead zone" setting controls how far
  a thumbstick must move off-center before it registers, exposed to both
  sticks.
- **A controller-driven cursor** — `ControllerCursor.swift` lets a gamepad
  drive the whole menu/UI layer (not just flight) via an on-screen cursor
  overlay, so a controller alone can navigate every screen. This is also what
  makes tvOS fully playable, since the Siri Remote can't fly a ship. Wired
  throughout flight, the spaceport/galaxy map paging, the tutorial, and haptics
  (`Launcher/ControlsView.swift`, `Tutorial/TutorialModel.swift`,
  `Game/Haptics.swift`, `Game/GameScene.swift`, `Spaceport/GridPaging.swift`,
  `Game/GalaxyMapView.swift`, `Game/GameContainerView.swift`).

## Where it lives

| Piece | File |
|---|---|
| Frame-by-frame polling, twin-stick mapping, discrete dispatch | `app/NovaSwift/Input/GameControllerInput.swift` |
| Bindable-button enum, persistence, display labels | `app/NovaSwift/Input/PadBindings.swift` |
| Controller-driven UI cursor overlay | `app/NovaSwift/Input/ControllerCursor.swift` |
| Button glyph rendering in the Controls UI | `app/NovaSwift/UI/PadGlyph.swift` |
| In-app remap screen | `app/NovaSwift/Launcher/ControlsView.swift` |

## Platform notes

- On **macOS / iPadOS / iOS**, a controller is optional — it's an alternative
  to touch or keyboard+mouse, all three keep working.
- On **tvOS**, it's mandatory: `RootView.swift` gates the whole app behind a
  `ControllerRequiredView` until an extended gamepad pairs (see
  [TVOS.md](TVOS.md)), matching the `GCSupportedGameControllers`
  (`ExtendedGamepad`) declaration in the tvOS `Info.plist`.

## What's left

- Wider testing across third-party pads (8BitDo, generic Bluetooth) beyond
  first-party Xbox/PlayStation/MFi controllers.
- No haptic-trigger (adaptive trigger) support yet — regular rumble only.
