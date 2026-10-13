# Controls Editor (visual keyboard · controller · touch)

A NovaSwift settings screen — **not** an original-game dialog. The original's Key
Settings (DLOG, `ClassicKeySettingsView.swift`) stays as-is behind Classic
Preferences; this editor replaces the list-style Settings → Controls page on both
frontends. Bindings data, defaults, persistence keys and conflict rules are
unchanged — the editor is a new *view* over the existing models:

| | Apple | Godot |
|---|---|---|
| Keyboard map | `KeyBindings` (`app/NovaSwift/Input/KeyBindings.swift`), tokens `"w"`, `"opt+w"`, `"control"`… | `Controls.gd` `effective()/rebind()`, fields `keys / alt_keys / shift_keys` |
| Pad map | `PadBindings` / `PadButton` (`Input/PadBindings.swift`) | `Controls.gd` field `buttons` (JoyButton) |
| Sticks | fixed: left = steer/thrust, right = aim | same (axes never rebindable) |
| Touch layout | `TouchLayout` (new) → `TouchControlsOverlay` | n/a — Godot has no on-screen flight controls |

## Screen shape

Top: a 3-way tab — **Keyboard · Controller · Touch** (Touch only on iOS/iPadOS).
Every tab has a right/bottom **action list** (grouped by category, search field,
each row shows its current binding chip; unbound rows dimmed; conflicting rows red)
and a big **rendered device** that fills the rest.

Two ways to bind, both always available:
1. **Device first** — click/tap a key or button on the art → popover/panel lists
   what it does now (all layers) and an action picker to assign/unbind.
2. **Action first** — select an action row → its current key/button pulses on the
   art; then click a key/button on the art *or* press the physical key/button
   (capture, Esc cancels, pad capture times out after 6 s as today).

Hovering an action row highlights its key; hovering a key highlights its row.
Keys/buttons are tinted by the **category** of their bound action (Flight, Combat,
Targeting, Navigation, Interface, Camera — one fixed colour each, plus a legend).
Unbound keys are plain dark caps.

Footer: **Reset to defaults** (respects the modern-layout toggle as today),
Cancel / Done (Apple keeps the shadow-draft + refuse-on-conflict-at-OK rule
from `ControlsView.commitKeys`; Godot keeps its live swap-on-conflict rule).
Must be fully drivable by controller cursor (Apple: `CursorButton`, registry
rules in memory `novaswift-controller-cursor`) and Godot focus navigation.

## Keyboard tab

Rendered keyboard, drawn procedurally (no bitmap art) from a layout table of rows
of `(token, label, widthUnits)` with 1u = standard key width.

**Size presets** — exactly three, chosen by how many keys the player's board has
(a picker; persisted; default Full, except Compact on a Mac laptop):
- **Full** — F-row, nav cluster, arrows, numpad
- **Tenkeyless** — Full without the numpad
- **Compact** — laptop-style: F-row and arrows squeezed in, no nav cluster or numpad

Any binding on a key the chosen preset lacks (e.g. a numpad key on Compact) shows
in an "Off-keyboard bindings" strip under the board, so nothing is ever hidden.
No ISO variant.

Labels per platform: Apple shows ⌃ ⌥ ⌘ ⇧; Godot shows Ctrl / Alt / Shift / Super.

**Modifier layers**: a small segmented control **Base · Shift · Alt (⌥)** above the
board. Base shows plain-key bindings; Alt shows `opt+` (Apple) / `alt_keys`
(Godot); Shift shows `shift_keys` (Godot) / shifted characters like `~` (Apple
stores shifted glyphs as their own token — map `~`→\`, etc. onto the base key
for display). A key with bindings on another layer shows a tiny corner dot.
Modifier keys themselves are bindable as bare keys (Control fires secondary).

Each cap shows: key legend (top-left, small) + the bound action's short name
(centre, auto-shrinking, max 2 lines). Uncapturable keys (`KeyBindings.isCapturable`
false — 1–4, Caps Lock, F1–F5 on Apple) are drawn hatched/locked with a tooltip
explaining why; they still display their fixed role (nav 1–4).

## Controller tab

Procedurally drawn controller (vector paths — no vendor bitmaps or logos),
Steam-"controller configuration" style: the pad silhouette centred, every
control a hit-target, **callout labels with leader lines** out to the left/right
margins naming the bound action (fixed stick roles shown too, greyed, "Steer /
Thrust", "Aim").

**Styles** (picker; default = auto-detect from the connected pad, fallback Xbox):
- **Xbox** — offset sticks, A/B/X/Y (green/red/blue/yellow tint), View/Menu
- **PlayStation** — symmetric sticks, ✕ ○ □ △, Create/Options, touchpad
- **Nintendo Switch Pro** — B/A/Y/X positions swapped labels, −/+
- **Steam Deck** — wide handheld body with screen in the middle, sticks + d-pad
  + ABXY, L4/L5/R4/R5 back grips shown as "set in Steam Input" (not bindable
  here), trackpads greyed

Detection: Apple `GCController.current` (`productCategory` / `GCDualSenseGamepad`
/`GCXboxGamepad` etc.); Godot `Input.get_joy_name(0)` contains
"Steam Deck"/"PS"/"DualSense"/"DualShock"/"Xbox"/"Nintendo"/"Pro Controller".
Live input: pressing a physical button lights it on the art (also when not capturing).

Face-button labels follow the chosen style (on Apple prefer the element's
`sfSymbolsName`/`localizedName` when a pad of that family is connected).

## Touch tab (Apple iOS/iPadOS only)

Edit the on-screen flight cockpit:
- Live preview canvas at the device's aspect, showing every touch control at its
  current position over a dimmed starfield.
- **Drag** a control to move it (snaps to an 8pt grid and to screen edges / safe
  area; positions stored normalised + edge-anchored so they survive rotation and
  device changes).
- **Resize** per control (slider 0.6×–1.6×, or pinch) and global **opacity**
  (0.3–1.0) and global **scale**.
- **Action** per control: tap → picker of `GameAction`s (holds only offer
  continuous actions; taps offer discrete ones). **Add button** places a new
  custom tap button for any discrete action; custom ones can be **removed**;
  stock ones can be **hidden**.
- **Presets**: Default (exactly today's layout), Left-handed (mirrored),
  Minimal (turn + thrust + fire only). **Reset**.
- Persisted as `TouchLayout` (Codable) in UserDefaults
  (`com.novaswift.touchlayout.v1`); `TouchControlsOverlay` renders from it. The
  Default preset must reproduce today's arrangement so nobody's screen changes
  until they edit it. Tap-to-fly still hides the turn cluster.

## Not in scope
- Rebinding sticks/axes, per-pilot bindings, multiple saved keyboard profiles.
- Godot touch controls (no on-screen flight controls exist there to edit).
