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

rlëD encoder (exact inverse of `RLED.decode`), `RLE8` decoder / `RLE8Encoder` (8-bit
palette-indexed twin; spec and decomp addresses in `RLE8Decoder.swift`), PICT v2 encoder (readable by
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
- Live preview: an embedded `GameScene` running the effective collection; edits adopt the new
  catalog and reload the system in place in the same scene (a new scene only when the camera
  ship's shïp/shän changed). Stellar sprites in the layout canvas and the galaxy inspector's
  stellar list animate (all frames, spöb delay/bias/flags, 12 fps, visible stellars only) and
  show HD art when HD is on.
- Test run: full game session on base ⊕ document with a debug panel
  (spawn ships/fleets, give outfits, set bits, jump anywhere, god mode,
  start missions) built on the existing console commands.
- Lint panel, NCB/bit graph, export (rez / classic / HD pack).
- Changes view (`Changes/`, the landing tool for an opened plug-in): what the plug-in adds /
  overrides by category, one-line field diffs (`ResourceDiff`), HD/3D attachments resolved to
  their owners (`EditorHDIndex` over `SpriteOwnerIndex`), conflicts, and a Bundle Files pane.
  The inspector shows a "Changes vs. base" panel (per-field revert) on overrides, and DITL/DLOG
  open in a to-scale layout editor that patches item rects via `DialogCodec`.

## Plug-in shapes

What "a plug-in" is on disk decides how it opens and what Save writes. Opening goes through
`PluginBundleLoader` (Kit, off-main) which scans the folder into a `PluginLayout`, parses every
file concurrently and hands `PluginDocument.open(files:)` the parsed files. Every layer resource
remembers its **source file** (`sourceFiles`, `sourceFile(of:)`, undoable `setSourceFile`,
`targetFile` for where new resources go; keys are paths relative to the plug-in folder, packs are
`pack:<path>.nsx`). `EditorModel.bundle` (folder, files in load order, packs, other files,
total-conversion flag, installed id) is filled on every open / save-as; `EditorModel.conflicts`
(other enabled plug-ins defining the same key, in load order) is computed in the background after
open and save, with per-file key sets cached by path + size + mtime (`EditorConflictScanner`).

- **Single file** (`.rez`, `.ndat`, classic fork): one source file. Save/Save As/Export behave as
  before. Editor metadata (`NSmd`) lives in this file.
- **Multi-file** (e.g. ARPIA2's 7 `.rez`): files merge into one layer in load order (later wins);
  a resource a later file overrides is kept aside and written back to its own file. Save rewrites
  only files that changed (others stay byte-identical), each in its original format (rez vs
  classic), into the same folder; all files are written to temporaries first, then moved into
  place. Unknown types are preserved untouched. Metadata is stored in the primary file only (the
  first file that isn't named like a Graphics/Sounds file). Save As offers "Save to Folder" (all
  files, new folder) or "Merge into One File". Export Copy / Install always produce one file.
  New resources go to `targetFile`, else by type (sprites/PICT to a "...Graphics..." file, sounds
  to a "...Sounds..." file, the rest to the primary file). Save As "Save to Folder" into a new
  folder also copies `bundle.otherFiles` (fonts, movies, music, pilots, `.nplay`, readmes, images),
  keeping relative paths and never overwriting an existing file, off-main with progress.
- **`.nsx` graphics pack** (folder with `manifest.json` + PNG/USDZ, e.g. Nova Reimagined): its
  entries are embedded into the layer as `NSgx`/`NSbl` (blob ids renumbered into the layer's id
  space), tagged with source `pack:<name>.nsx`. Save writes the pack back as an `.nsx` folder via
  `GraphicsPackEmbedding.extract` (only if it changed; name/author/license carried over) and never
  into a `.rez`, unless **Embed HD in plug-in file** is on (Project tab), which folds the HD
  resources into the data file instead. A graphics-only plug-in opens with its entries visible
  as NSgx resources. Open... accepts an `.nsx` folder directly. A pack inside a plug-in folder
  (or beside a loose file) opens with that plug-in.
- **Total conversion** (folder with its own `Nova Files/` + `Plug-Ins/`): the layer is the
  conversion's own `Nova Files` followed by its `Plug-Ins`, each file tracked separately, and the
  base is empty (`bundle.isTotalConversion`). A conversion replaces the stock scenario, whose ids
  mean different things there, so the stock game is never mixed in; the one exception is
  `Nova.rez`, which the original shares with every scenario, loaded as base only when the
  conversion doesn't ship its own. Conflicts are not computed for a conversion (global plug-ins
  don't load under one).
- **Save / Export / Install** snapshot the document on the main actor (`makeExportJob`,
  `makeSavePlan`) and encode + write in a detached task behind `busyText`; errors land in
  `errorText`. Panels stay on the main actor.
- **Recovery autosave** (60 s, dirty documents) writes a recovery bundle under
  `NovaSwift/Editor/Recovery`: `recovery.json` (source files in order, formats, `targetFile`,
  bundle info, installed id) + `bundle/` (every source file and `.nsx` pack at its relative path,
  metadata in the primary file). Restore reloads it through `PluginBundleLoader`, so resources keep
  their files and `model.bundle` comes back. A document with no tracked sources uses the old
  single `recovery.rez`.
- **Conflicts** refresh ~1 s after the last data edit (debounced on `dataRevision`): other
  plug-ins' key sets are cached per file, so it is a set intersection with the layer keys.
- **Renumber** can also move the schema's implicit companions (`shän` = `shïp` id, `dësc` /
  `PICT` offsets) in the same undo step (`moveCompanions`); `PluginDocument.companionPlan` drives
  the checkbox list in the sheet.
- `dsïg` #128 (an editor/version signature, 2-4 bytes, one per file) is registered as a raw
  type, "Editor Signature". The game ignores it; it is preserved per file on save.

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

## Responsiveness rules (UI contributors)

- The first frame after any click must render without waiting on data. Anything derived
  (merged view, reference graph, browse lists, sidebar counts, spec stats, sprite/atlas
  decodes, lint) is computed off the main actor from `Sendable` snapshots and published back;
  until then the surface shows `SkeletonBar/List/Form` or `EditorLoadingOverlay`
  (`Shell/EditorLoadingViews.swift`), and after edits it keeps the stale result with an
  `EditorRefreshStrip`.
- `EditorModel.dataReady` / `referencesReady` gate the merged view and `document.references`
  (built in the background on open; patched incrementally afterwards). Never touch
  `document.references` or `NovaGame(...)` inside a `body`.
- Derived caches key off `EditorModel.dataRevision` (resource data only), not `revision`
  (which also bumps on Save/metadata edits). `EditorBrowseCache` holds per-type browse rows
  with precomputed lowercase names; `SpecCache.compute` runs engine/catalog work serialised
  per revision (`Galaxy` isn't thread-safe).
- `PluginDocument.beginGroup/endGroup/withGroup` coalesce a burst into one `onChange` (one
  revision bump, one reference-graph update).

## Status (2026-10-12)

Built: everything above. Entry point (both menus, macOS only) → full-window
editor with resource browser, schema inspector for 23 types (verified
byte-exact against every stock record), hex/text/graphic/sound editors with
PNG/WAV import, ship/weapon/outfit overviews on the engine's own stat math,
shän hardpoint editor, HD/3D attach + `.nsx` export, galaxy map and star
system editors with an embedded live `GameScene` preview, Story & Bits
(control-bit index, mission flow graph, mission/crön cards), validation,
save/open/install in `.rez` or classic format, and a test run with a full
debug panel (spawn ships/fleets, outfits, bits, missions, jumps, time scale,
god mode, console).

Known gaps:
- A resource overridden by a later file of the same plug-in stays hidden after deleting the winner
  (the earlier copy is kept).
- Install still hands the encoded file to `GameDataController.importPlugin` on the main actor
  (encoding and the temp write are off-main). Building a save plan / recovery snapshot
  (`makeSavePlan`) is O(layer) on the main actor, once per save or 60 s autosave.
- `rlë8` (8-bit sprites) decodes with the Mac system palette and an inferred repeat opcode: the
  original only loads rlë8 on an 8-bit display, no shipped data has one, so both are unverified
  against real files. The game never uses rlë8 (it is a direct-colour renderer, like the original
  at 16/32-bit), so only the editor previews/imports it.
- "Embed HD in plug-in file" does not delete a stale `.nsx` folder already on disk.
- Test run: landing is the REAL spaceport (`SpaceportView`: trade, outfitter, shipyard, bar, mission
  BBS) on the in-memory sandbox pilot, with the story runtime (mission scripts, crön ticks on
  every jump / visit / "+days", ShipSyst mission ships, Mission Info, objective list), hail and
  board dialogs. Still not simulated: the landing-clearance exchange, bribes / paid assistance /
  Demand Tribute and escort commands in the comm windows, capturing from the plunder dialog
  (use the panel's Capture), hypergates / wormholes, domination, and `Q`-style launches while a
  story move is pending (a docked `M`/`N` launches into a freshly built ship). Storyline badges
  in the BBS come from the loaded game's tag table, not the edited data.
- HD/3D art: editor games install the document's `NSgx`/`NSbl` (incl. `.nsx` packs loaded into it)
  over the user's installed packs into the shared `HDGraphics` (the game's own layer is restored
  ~4 s after the last editor game closes). A big pack's first prewarm can take a while (bakes are
  cached); the user's HD setting is honoured.
- Weapon DPS assumes every submunition lands and counts only the schema's fixed-offset
  companions for Renumber (a `spïn`'s sprite is a stored field, so its references are rewritten
  but the sprite resource itself is not moved).
- Story "unreachable" check evaluates each availability test with a port of the game's NCB test
  interpreter (`NCBProbe`: `&`, `|`, `!`, `( )`, `[ ]`), treating every bit as clear-able and as
  settable once a reachable source raises it. It is still per-bit independent (no ordering in
  time: `b1 & !b1` is caught, "set by the same mission that needs it clear" is not), and the
  copy of the interpreter must be kept in step with `NCBTest` (NovaSwiftStory).
- Exported PICT/cicn/`snd ` are verified only against our own decoders, not
  QuickDraw or EV Nova CE.
- The app is sandboxed: saving needs `files.user-selected.read-write` +
  `files.bookmarks.app-scope` (added to NovaSwift.entitlements).
