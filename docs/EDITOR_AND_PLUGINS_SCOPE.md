# Scope — Plug-in System, In-App Editor & Save-Game Editing

Status: **planning / not started.** This document scopes three related capabilities and
sequences them into milestones. Nothing here is built yet; it defines *what to build* and
*in what order*, and calls out the one architectural change everything depends on.

Related: `docs/MOBILE_AND_PLUGINS.md` (the runtime plug-in/loader design, already partly
built), `docs/DATA_FORMAT.md` (container + resource formats), `docs/ROADMAP.md` (phase 8).

---

## 0. The load-bearing fact: today the data layer is read-only

Everything currently in `EVNovaKit` **parses**. Nothing **writes**.

- `Resource` is an immutable value type (`let type/id/name/data`).
- `ClassicResourceFork.parse` and `RezContainer.parse` decode bytes → `ResourceCollection`.
  There are no matching `serialize` functions.
- The typed models (`ShipRes`, `SpinRes`, `ShanRes`, `SpobRes`, …) are **decode-only**
  views over raw `Data`; there is no encode path.
- The plug-in model exists but is runtime-only: `PluginBundle` + `ResourceCollection.overlay`
  build a read-only override chain. There is no notion of *authoring* a layer.
- There is no pilot/save-game code at all.

So an editor is not "a UI over existing code." **The prerequisite is a write path**: mutable
resources, container *serializers*, and per-type encoders that are exact inverses of the
decoders. That prerequisite (Milestone A) gates everything else. Get it byte-exact — a plug-in
that doesn't round-trip through the real game is worthless.

---

## 1. Goals

Three deliverables, launchable from the launcher's **"Editor"** entry (a peer of Play):

1. **Full plug-in support at runtime** (mostly designed already; finish it):
   prebundled catalog + user-installed plug-ins, load-order/override UI, conflict view.
2. **In-app resource editor** — a Mission Computer / ResForge-class tool with full sprite &
   PICT rendering: browse and edit **every** resource type in the base data or any plug-in;
   create new plug-ins from scratch; export a real `.rez`/`.ndat` a desktop copy of EV Nova
   can load. Structured field editors for the common types, hex fallback for everything.
3. **Save-game (pilot) editing** — open a `.plt`/pilot resource fork, decrypt it, edit
   cash/ship/outfits/legal-standing/mission-bits, re-encrypt, write it back.

Design principle: the editor edits the **same `ResourceCollection` model the engine plays**,
so "edit → preview in-engine" is cheap and authentic. No separate data model for the editor.

Non-goals (v1): collaborative/cloud editing; a scripting language beyond EV Nova's own
control-bit/`crön` system; importing non-EV formats.

---

## 2. Platform & legal constraints (shape the whole design)

- **iOS sandbox.** No drop-in folders. Import via `UIDocumentPicker`/share-sheet into the app
  container; export via the share sheet / "Save to Files". Editing happens on a **copy** in
  Application Support, never in place on an external file. macOS gets real file access +
  security-scoped bookmarks and can edit a file where it sits.
- **Base data is never bundled** (copyright). The editor can *open and modify* the user's own
  imported base data, but a plug-in the user makes must be exportable as a **diff layer** (only
  the resources they changed/added) so they never redistribute base content.
- **Redistribution of authored plug-ins is the user's act, not ours** — we just produce a valid
  file. But default export to *overlay-only* so a user doesn't accidentally bake copyrighted
  base resources into their plug-in. Warn if they force a full export.
- **Pilot files are the user's own saves.** Editing them is local-only; no legal issue, but
  flag clearly that editing a pilot can corrupt it and offer an automatic backup.

---

## 3. Architecture

### 3.1 New in `EVNovaKit` — the write path (Milestone A)

```
EVNovaKit/
  Resource.swift              (exists) — add a mutable editing model alongside
  Editing/
    EditableResource.swift    class: mutable type/id/name/attributes/data + dirty flag
    ResourceDocument.swift     an open editing session: a ResourceCollection + change log
                               + provenance (which layer each resource came from) + undo/redo
    ContainerWriter.swift      protocol: serialize(ResourceCollection) -> Data
    ClassicForkWriter.swift    inverse of ClassicResourceFork.parse (map/type/ref/name/data)
    RezWriter.swift            inverse of RezContainer.parse (BRGR: header/group/entries/map)
  Schema/
    ResourceSchema.swift       field-definition model (a "TMPL": name, type, size, enum, repeat)
    Schemas.swift              built-in schemas for shïp/oütf/wëap/sÿst/spöb/spïn/shän/…
    FieldCodec.swift           read/write a struct field ⇄ bytes at an offset per schema
  Pilot/
    PilotFile.swift            decrypt/parse + encrypt/write EV Nova pilot files
    PilotModel.swift           typed view: cash, ship, outfits, cargo, legal, mission bits
```

Key decisions:

- **Round-trip tests are the spec.** For every container and every resource type: parse a real
  resource → re-serialize → assert byte-identical (or field-identical where padding is free).
  Wire these into `Tests/EVNovaKitTests` as golden tests against the user's own data (never
  commit the bytes). This is how we know encoders are correct.
- **Schema-driven, not one-off.** Rather than hand-write an encoder per type, describe each
  resource type once as an ordered list of fields (offset, width, signedness, enum, string
  length, repeat count) — the same idea as ResEdit `TMPL` and MissionComputer's field defs.
  `FieldCodec` reads and writes any struct from its schema. The typed structs in
  `NovaModels.swift` become thin accessors over a schema-driven store. New types = new schema,
  not new code. Ship a **hex/raw editor** for any type without a schema so *everything* is
  at least editable.
- **Provenance & overlay-aware editing.** `ResourceDocument` knows, per `(type,id)`, whether a
  resource is base, from plug-in X, or newly authored. Editing a base resource inside a plug-in
  document creates an **override** in that plug-in's layer, leaving base untouched — exactly EV
  Nova's model. "Revert to base" and "this shadows base #128" are first-class.

### 3.2 New in the app — the editor UI (Milestones C–D)

```
app/EVNova/Editor/
  EditorRootView.swift        three-pane: type list · resource list · detail/inspector
  ResourceListView.swift      per-type list w/ id, name, search, add/dupe/delete
  Inspectors/
    HexInspector.swift        raw byte editor (fallback for any type)
    FieldInspector.swift      schema-driven form (generated from ResourceSchema)
    ShipInspector, SystemMapInspector (visual node graph of sÿst links + spöb layout),
    OutfitInspector, WeaponInspector, MissionInspector, DescTextInspector, SpinInspector…
  Rendering/
    SpritePreview.swift       reuse rlëD decode → animated frame preview
    PictPreview.swift         needs a PICT decoder (see M-B)
  PluginDocumentView.swift    new-plugin authoring: name/kind/vers, add resources, export
  PilotEditorView.swift       save-game editor
```

- Reuse `SpriteSheet+Image` for live sprite preview; the **System Map inspector** is the
  showcase editor — drag `spöb`s, draw `sÿst` hyperlinks, pick governments, all rendering
  from the user's real sprites.
- "**Test in engine**" button: spins up the engine on the current (unsaved) `ResourceDocument`
  so an author sees a ship/system live without leaving the editor.

### 3.3 Prerequisite decoders still missing

- **PICT decoder** (`docs/DATA_FORMAT.md` §3.3) — needed to render landing/planet/logo art in
  the editor and the game. Already on the roadmap; the editor makes it higher priority.
- **cicn / STR# / dësc** decode+encode — text and icon editing are table stakes for a plug-in
  tool.

---

## 4. Save-game (pilot) editing — the unknown that needs research first

EV Nova pilot files are a resource fork containing the pilot resources, **obfuscated** (a
simple reversible cipher, not real crypto — community pilot editors exist, so it's tractable).
Before committing UI:

1. **Research spike:** confirm the pilot resource type(s), field layout, and the exact
   deobfuscation (byte cipher / key). Validate by round-tripping the user's own pilot: decrypt
   → re-encrypt → byte-identical, and by making one known edit (e.g. cash) and loading it in a
   desktop EV Nova. Sources to check: existing open-source Nova pilot editors, the EVN Bible,
   evnova-utils. **Flag every field-layout assumption as unverified until a real pilot confirms.**
2. Only then build `PilotFile` + `PilotModel` + `PilotEditorView`.

Edit surface (v1): cash, current ship, installed outfits, cargo, legal standing per govt,
combat/kill stats, and mission control **bits** (the big one for testers/cheaters). Always
back up the original alongside the edited copy.

---

## 5. Milestones (dependency-ordered)

| M | Deliverable | Depends on | Notes |
|---|-------------|-----------|-------|
| **A** | **Write path**: mutable model, `ClassicForkWriter` + `RezWriter`, round-trip golden tests | — | The gate. No editor is real until parse↔serialize is byte-exact. |
| **B** | Schema system + `FieldCodec` + schemas for the top ~8 types; PICT/cicn/STR#/dësc decode+encode | A | Turns "raw bytes" into "fields". |
| **C** | Editor shell: 3-pane browser, hex inspector, sprite/PICT preview, save-as `.rez`/`.ndat` | A, B | Ships a *usable* raw+preview editor even before pretty inspectors. |
| **D** | Structured inspectors (ship/outfit/weapon/mission/dësc) + **visual System Map editor** + "Test in engine" | C | The Mission Computer / ResForge parity milestone. |
| **E** | **Plug-in authoring**: new overlay-only plug-in docs, provenance/override UI, export with `vers`, share sheet | C, D | Make-your-own-plugin. Overlay-only export protects base copyright. |
| **F** | Finish **runtime** plug-in mgmt: load-order editor, conflict/shadowing view, per-plug-in enable already exists — add ordering + dependency checks | (independent of A–E; can parallel) | Extends existing `PluginsView`. |
| **G** | **Save-game editor**: research spike → `PilotFile` → `PilotEditorView` | A (write path) | Gated on the research spike in §4. |

Ship value early: **A→C** already gives a real hex+preview editor that exports loadable plug-ins.
D/E make it pleasant; F/G are somewhat independent tracks.

---

## 6. Risks & open questions

- **Byte-exact serialization** of the classic fork (offset math, alignment, name-list packing)
  and BRGR Rez (the fixed 256-byte name field, `baseIndex`) is fiddly. Mitigation: round-trip
  golden tests from day one; study ResForge's writers (`RezFormat.swift`) and Graphite as the
  executable spec (both vendored in `third_party/`, MIT).
- **Schema accuracy.** Field layouts for many types are marked *(unverified)* in
  `DATA_FORMAT.md`. Each schema needs validation against a real resource + the EVN Bible before
  its structured editor is trustworthy. Until validated, that type stays hex-only.
- **Pilot format** — entirely unresearched here; §4 spike de-risks it.
- **iOS editing UX** on small screens for a dense inspector — likely iPad/macOS-first for the
  editor, with iPhone doing view/toggle/light edits.
- **PICT decoding** is its own mini-project (QuickDraw opcodes); scope it as a decode-first,
  encode-later (or re-embed original bytes) task — authors rarely need to *synthesize* PICTs,
  just import/replace them.

---

## 7. What "done" looks like

A user opens the launcher, taps **Editor**, opens their imported base data (read-only-safe),
creates a new plug-in, adds a ship with a real sprite and stats via a form, wires it into a
system on a visual map, hits **Test in engine** to fly it, exports a `.rez`, and shares it —
and separately opens their pilot save to fix a stuck mission bit. All on device, all from the
user's own data, nothing copyrighted ever bundled or redistributed by us.
