# Plugin Editor — build contract

The in-game plugin creator/editor described in [PLUGIN_TOOLKIT.md](PLUGIN_TOOLKIT.md),
built out. This file is the shared contract the implementation follows.

## Product rules

- **macOS only.** All editor UI is wrapped in `#if os(macOS)`. iOS, iPadOS and
  tvOS never show the entry point. The core write path in `NovaSwiftKit` is
  platform-neutral plain data code and is unit-tested.
- **Entry point:** a "Plugin Editor" button next to the "Plugins" button on
  both main menus (authentic + modern). It switches `AppModel.screen` to
  `.editor` — the editor *replaces* the game UI, it is not a sheet/overlay.
  Closing it returns to `.mainMenu`.
- **Diff layers only.** A plugin document holds only the resources the author
  added or overrode. Base data is context, never written out unless the author
  forces a full export (with a warning).
- **Original compatibility.** Plain exports (`.rez`, classic resource fork) must
  load in EV Nova CE. NovaSwift-only content (`NSgx`/`NSbl` HD/3D) is an extra
  layer the original ignores.
- **Clean UI.** Mac-native three-pane layout, dark theme with the game's amber
  accent, no clutter: sidebar (types / tools) · list · inspector + live preview.

## Layers

### 1. Core write path — `Sources/NovaSwiftKit/Editing/`

| File | Role |
|---|---|
| `PluginDocument.swift` | Working layer over a read-only base: put/remove/duplicate/renumber/revert, provenance (`.base`, `.new`, `.override`, `.otherPlugin(id)`), next-free-id, undo/redo, change counter, cached effective (base ⊕ layer) collection, open/save |
| `ClassicForkWriter.swift` | Inverse of `ClassicResourceFork.parse` (`RezWriter` already covers BRGR) |
| `ResourceSchema.swift`, `FieldCodec.swift` | TMPL-style field model + big-endian read/write |
| `ResourceSchemas*.swift` | Schemas for every EV Nova type (offsets from the decoders in `NovaModels.swift` & co., `docs/reverse-engineering/`, the Nova Bible, `~/Projects/evnova-re/audit/raw/resource_field_layouts.tsv`) |
| `TextResourceCodec.swift` | `STR#`, `STR `, `dësc` encode/decode |
| `ResourceReferences.swift` | Reference graph (outgoing + "used by") from schema `ref` fields |
| `PluginLinter.swift` | Validation: dangling refs, id ranges, field limits, NCB syntax, missing sprites |

### 2. Graphics codecs — `Sources/NovaSwiftKit/Editing/Graphics/`

rlëD encoder (exact inverse of `RLED.decode`), PICT v2 encoder (readable by
`PICT.decode` and QuickDraw), cicn encoder, PNG/CGImage → sprite-sheet import
(grid or per-frame, rotation count), spïn helpers, HD/3D pack authoring via
`GraphicsPackEmbedding`.

### 3. App UI — `app/NovaSwift/Editor/` (all `#if os(macOS)`)

- `EditorModel` (ObservableObject wrapping `PluginDocument`), `PluginEditorView` shell.
- Resource browser + schema-driven inspector + hex fallback + previews
  (animated sprites with rotation scrubber, PICT, text, sounds, shän layers,
  hardpoints, HD/3D side-by-side).
- Galaxy map editor (drag systems, draw/erase hyperlinks, govt colours,
  nebulae) and star-system editor (place stellars with real sprites).
- Live preview: an embedded `GameScene` running the effective collection,
  reloaded in place as edits land.
- Test run: full game session on base ⊕ document with a debug panel
  (spawn ships/fleets, give outfits, set bits, jump anywhere, god mode,
  start missions) built on the existing console commands.
- Lint panel, NCB/bit graph, export (rez / classic / HD pack).

## Working rules for contributors (agents)

- Another agent may be editing this tree. **No repo-wide git writes** (`stash`,
  `checkout .`, `reset --hard`, `add -A`). Don't commit.
- New app files are picked up automatically (Xcode synchronized groups) — never
  edit `project.pbxproj`.
- Build with your own scratch path to avoid lock fights:
  `swift build --scratch-path /tmp/nsed-<name>` /
  `swift test --scratch-path /tmp/nsed-<name> --filter <Suite>`;
  app: `xcodebuild -project app/NovaSwift.xcodeproj -scheme NovaSwift -configuration Debug -destination 'platform=macOS' -derivedDataPath /tmp/nsed-app-<name> CODE_SIGNING_ALLOWED=NO build`.
- Never launch or screenshot the app.
- Real game data (for round-trip tests, never committed) is under `data/EV Nova/`
  (git-ignored); tests that need it must skip cleanly when absent.
