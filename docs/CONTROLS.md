# Controller support

**Status: complete.** Full gamepad play — twin-stick flight, a rebindable action
map, and a controller-driven UI cursor that reaches every screen, dialog,
sheet and alert — on macOS, iPadOS and iOS, and *required* on tvOS.

## The controls at a glance

| | In flight | In menus / dialogs (the cursor) |
|---|---|---|
| Left stick | Turn + thrust / reverse (fixed) | Move the cursor |
| Right stick | Absolute aim (fixed) | Scroll / pan what's under the cursor (lists, outfit & ship grids, the star map) |
| D-pad | Bindable (default: jump, land, hail, board) | Snap to the next button in that direction (hold to repeat); past the last one, scroll |
| Ⓐ | Bindable (default: fire primary) | Press what the cursor is over (held on a slider: drag) |
| Ⓑ | Bindable (default: fire secondary) | Back / cancel — what Esc does, plus Close/Back/Skip/Done-type buttons |
| Menu | Bindable (default: game menu) | The dialog's default button — what Return does |
| Triggers | Bindable (default: throttle) | Zoom on the star map |
| Everything else | Bindable | — |

## Flight

`GameControllerInput.swift` polls the connected `GCExtendedGamepad` every
frame. The two thumbsticks are fixed, not rebindable, to match twin-stick
muscle memory: left steers/thrusts, right is absolute aim (`desiredHeading`).
Every button is a `PadButton` (`PadBindings.swift`) the player can remap;
continuous actions (fire, throttle, afterburner) drive the per-frame intent,
discrete ones (land, jump, map, target…) fire once on the press edge through
the same dispatch as the keyboard.

While a menu, map, dialog or panel owns the screen the pad produces an empty
flight intent — the cursor has the sticks and buttons. When flight takes the
pad back, any button still held (the Ⓐ that just pressed OK, the Ⓑ that just
backed out) is ignored until released, so closing a dialog never fires a
weapon. On a DualSense the triggers get light adaptive resistance while
flying and a free pull in menus.

## The UI cursor

`ControllerCursor.swift` is a **geometry registry**, not a real hit test:
controls register their drawn frame, and the overlay's 60 Hz loop hit-tests
the cursor point against them.

**Registering controls.** `.cursorClickable { }`, `CursorButton`,
`.buttonStyle(.novaPlain)`, `.novaBorderedButton()`/`.novaProminentButton()`,
and the `NovaFormControls` wrappers (`NovaToggleStyle`, `NovaSlider`,
`NovaSegmentedPicker`, `NovaMenuPicker`) all register. `NovaTextField` and
`.padTextEntry(…)` open the pad keyboard (`PadKeyboard.swift`; the system
fullscreen keyboard on tvOS). Scrollables use `.cursorScrollable()`;
self-scrolling views (the paged outfit/ship grids, the star map) use
`.cursorPannable { delta in … }`. **Stock SwiftUI `Toggle`/`Picker`/`Slider`/
`Button(.plain)`, bare `.onTapGesture` and `.contextMenu` register nothing** —
use the wrappers.

**Only what's on top is live.** Three scopes keep the cursor from acting on
hidden UI:

- **Hosts.** A sheet or full-screen cover is a separate presentation (the root
  cursor draws under it on iOS/tvOS and in another window on macOS), so every
  sheet's content carries `.cursorHost()`, which gives it its own cursor, pad
  keyboard and alert layer. Only the topmost host runs.
- **Layers.** `.cursorModal()` on an in-hierarchy overlay (a dialog, a panel
  over the HUD, a scrim'd popup) lifts it one layer; only the highest occupied
  layer is pressable or scrollable, and only its Ⓑ/Menu keys fire. `NovaDialog`,
  `DialogChrome`, the pad keyboard and classic prompts do this themselves.
- **Suspension.** While a rebind capture or the tvOS system keyboard owns the
  pad, the cursor is inert.

**Ⓑ and Menu.** `.cursorCancel(action)` / `.cursorDefault(action)` register a
screen's back and confirm actions; the newest one on the live layer wins.
`novaDialogKeys` (the original's Return/Esc items) registers both, and
`NovaDialog` maps Ⓑ to its back-type button (Cancel / Close / Back / Skip / Not
Now / Done / Leave…) or a single-button notice's OK — keyboard Esc stays
faithful to the original.

**Alerts.** System `.alert`/`.confirmationDialog` are drawn by the OS where the
cursor can't reach, so the app uses `.novaAlert(…)` (`UI/NovaAlert.swift`) — the
same choice in `NovaDialog` chrome, presented by the host it was raised in, above
every layer.

**Any resolution.** Hit frames are read in drawn space — every ancestor
`scaleEffect` and `novaPlace` offset is already folded into
`frame(in: .global)`, so frames are registered verbatim and never adjusted (see
the long note on `cursorScaleEffect`). The overlay converts between its local
space and global space, so safe-area and form-sheet insets don't shift it.
Cursor speed scales with the surface diagonal (a full-tilt sweep takes the same
time on a phone and a 4K TV), slows over a pressable control, and a small hit
slop keeps tiny chrome reachable on big screens. A resize, rotation or window
change keeps the cursor at the same relative spot.

**Debugging alignment.** With the UI debug overlay on (⇧⌘D), every live hit
frame is outlined: green buttons, cyan tracks, dashed orange scrollables. They
should sit exactly on the drawn controls.

## Remapping

The in-app Controls screen (`Launcher/ControlsView.swift`) rebinds any button:
select a binding, press the new button. The cursor is parked during capture so
the press doesn't also click; capture cancels itself after 6 s; ✕ unbinds.
`PadButton.displayName(on:)` / `PadGlyph` show the *connected* controller's own
names and SF Symbols ("Cross" on a DualSense, Ⓐ on Xbox).

## Where it lives

| Piece | File |
|---|---|
| Flight polling, twin-stick mapping, held-button guard, adaptive triggers | `app/NovaSwift/Input/GameControllerInput.swift` |
| Bindable-button enum, persistence, display labels | `app/NovaSwift/Input/PadBindings.swift` |
| Cursor registry, hosts/layers, Ⓑ/Menu keys, the cursor overlay | `app/NovaSwift/Input/ControllerCursor.swift` |
| Scroll / pan registry | `app/NovaSwift/Input/CursorScroll.swift` |
| Pad keyboard + `.padTextEntry` | `app/NovaSwift/Input/PadKeyboard.swift` |
| Controller-operable alerts | `app/NovaSwift/UI/NovaAlert.swift` |
| Cursor-aware form controls | `app/NovaSwift/UI/NovaFormControls.swift` |
| Button glyphs, connected-pad state | `app/NovaSwift/UI/PadGlyph.swift` |
| Remap screen | `app/NovaSwift/Launcher/ControlsView.swift` |

## Platform notes

- **macOS / iPadOS / iOS:** a controller is optional, alongside touch or
  keyboard + mouse; all of them keep working at once.
- **tvOS:** required. `RootView.swift` gates the app behind a
  `ControllerRequiredView` until an extended gamepad pairs (see
  [TVOS.md](TVOS.md)), matching the `GCSupportedGameControllers`
  (`ExtendedGamepad`) declaration in the tvOS `Info.plist`. The root view parks
  the focus engine and swallows the system Menu/B exit command; Ⓑ/Menu reach
  dialogs through the cursor's key registrations instead.

## Known limits

- Built on GameController's extended-gamepad profile, so any pad Apple's stack
  recognizes (Xbox, PlayStation, MFi, most 8BitDo/Bluetooth pads in their
  Xbox/Switch modes) works; third-party pads haven't had dedicated hardware
  testing.
- Debug/developer tools (`app/NovaSwift/Debug/`) are mouse/keyboard-first; most
  register with the cursor, but they're not part of the controller guarantee.
