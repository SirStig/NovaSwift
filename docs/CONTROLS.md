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
| LB / RB / Options | Tap = bound action; **hold = action wheel** (default) | Cursor keys as bound |
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

## Action wheels

Far more actions exist than buttons, so a pad can open **action wheels**:
Steam-style radial menus. **Hold** a wheel's trigger button, **flick the right
stick** toward a slot, **release** to use it. Slot 0 is at the top, then
clockwise. The wheel opens low on the side of the hand holding its trigger
(LB / Options wheels bottom-left, RB wheel bottom-right), clear of the ship at
screen centre (`UI/ActionWheelOverlay.swift`). By default **the game pauses**
while a wheel is open; Settings ▸ Controls ▸ *Pause while an action wheel is
open* turns that off so time keeps running (the wheels are a NovaSwift input
layer, so there is no original behaviour to match). While paused the pad is
polled by a small timer (`GameControllerInput.wheelPump`), because a frozen
SKScene stops calling `update`.

| Wheel | Trigger | Slots (clockwise from top) |
|---|---|---|
| Combat & Fleet | LB | Cloak, Escorts: Aggressive / Defensive / Evasive / Hold / Formation / Return to Hangar, Recall Fighters, Open Escorts, Clear Secondary, Eject, Self-Destruct |
| Targeting & Nav | RB | Target Nearest, Cycle Target Backward, Cycle Escorts, Clear Ship Target, Nav 1-4, Hail Planet, Hyperspace Destination, Cycle Hyperspace Destination, Autopilot |
| Info & View | Options (galaxy-map button) | Player Info, Mission Info, Ship Info, Dismiss Message, Change Camera View, Camera Zoom In / Out, Route Map Zoom In / Out, Pause |

**Tap vs hold.** A wheel trigger is dual-use. Released within 0.22 s without
the right stick pushed (a stick already aiming when the button went down
doesn't count), it is a tap and does the button's normal bound action
(LB/RB still cycle secondary weapons, Options still opens the map), fired on
release. Held longer, or with the right stick pushed past half, the wheel
opens. While it is open the right stick selects a slot instead of aiming (the
pick is sticky: recentring the stick keeps it); the left stick and triggers
keep flying (when the pause setting is off). Releasing the trigger uses the highlighted slot; releasing without
ever picking one does nothing. **Ⓑ cancels** (and that press does not fire the
secondary weapon). Only one wheel is open at a time, and a wheel closes without
firing if a menu or dialog takes the pad. A button bound to a held control
(fire, afterburner, thrust) can't be a trigger.

**Self-destruct latches.** The original needs the key held for five seconds.
Picking it from a wheel can't be held, so it latches: the self-destruct command
stays on until **any pad button is pressed**, which aborts it.

**Customizing.** Controls ▸ Controller ▸ *Action Wheels* edits each wheel's
trigger button and slots (4-12 per wheel; pick any fire-once action, add,
remove, reorder), with *Reset wheels to defaults*. Saved under
`com.novaswift.actionwheels.v1`.

**Coverage guarantee.** With the default buttons plus the default wheels, every
`GameAction` is reachable from the controller (turning and throttle ride the
sticks and triggers). If a custom setup leaves any action unreachable, the
editor lists them in a warning. `ActionWheels.uncovered(bindings:wheels:)`
computes it, and the tests assert the defaults leave nothing out.

### Godot (Linux / Windows / Steam Deck)

Same wheels and defaults; see GODOT_LAYER.md.

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
| Action wheel model, defaults, coverage check, slot icons, overlay state | `app/NovaSwift/Input/ActionWheels.swift` |
| Wheel radial overlay (mounted over flight) | `app/NovaSwift/UI/ActionWheelOverlay.swift` |
| Wheel editor (Controller tab) | `app/NovaSwift/Launcher/ControlsEditor/ActionWheelsEditor.swift` |
| Wheel tests | `app/NovaSwiftTests/ActionWheelTests.swift` |
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
