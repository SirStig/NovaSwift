# Plug-in toolkit

**Status: mostly planned.** The HD extension format, loader and model
rendering (Part 2, steps 6 to 8) are built; see [HD_PIPELINE.md](HD_PIPELINE.md).
The rest is not built yet except the pieces called out as existing.

The goal is to give plug-in makers tools the original game never had: a full
editor for every resource, and a way to ship HD art, 3D models and better audio
without breaking compatibility with the original game or with existing
plug-ins.

Two rules shape everything below:

1. **Original plug-ins stay first-class.** Anything the editor exports as a
   plain plug-in must load in the original EV Nova CE exactly as it loads in
   NovaSwift. HD and other NovaSwift-only content goes in a separate, optional
   layer that the original simply never sees.
2. **No base data is ever redistributed.** Authored plug-ins export only what
   the author changed or added. Exporting a full copy of base resources is
   possible but needs an explicit choice and shows a warning.

## Part 1: the plug-in editor

A Mission Computer / ResForge-class editor built into the app, on macOS and
iPad, working on the same `ResourceCollection` the engine plays, so "edit, then
fly it" is one click.

### Foundation (needed by everything else)

- **Write path in `NovaSwiftKit`.** Today the data layer only reads. Add
  mutable resources, writers for classic resource forks and `.rez`/`.ndat`, and
  an encoder for every resource type that is the exact inverse of its decoder.
  Round-trip tests (parse, write, compare bytes) are the spec.
- **One schema per resource type.** Field offsets, widths, enums and repeats
  described once and used for both decoding and editing. The verified layouts
  from the decompilation (`docs/reverse-engineering/`) are the source of truth,
  including the original's minimum record sizes and zero-padding.
- **Raw editing for everything.** A hex view for any type, so nothing is
  uneditable even before it has a friendly editor.

### Editors

- **Browser:** every type in base data and each plug-in, with search, override
  view ("this plug-in replaces base shïp 128"), duplicate, renumber and revert.
- **Ships, outfits, weapons:** form editors with live stats as the engine
  computes them (top speed, turn, DPS, mass, slots), sprite preview with
  `shän` layers, and a hardpoint editor that shows weapon and engine exit
  points on the sprite.
- **Galaxy editor:** drag systems, draw hyperlinks, place stellars, set
  governments, nebulae and fleets, with the real sprites and the political
  overlay.
- **Missions and story:** mission forms plus a control-bit graph built on the
  existing storyline analyzer (the same data behind the Story Guide). Shows
  which mission sets and tests each bit, dead ends, and unreachable missions.
  An NCB expression editor checks syntax against the original interpreter's
  rules.
- **Text and art:** `dësc`, `STR#`, `PICT`, `cicn`, `rlëD` and `spïn` with
  previews and import from PNG.
- **Validation:** a lint pass that applies the original's rules (id ranges,
  field limits, references to missing resources, flags that the original
  ignores) and explains each problem in plain language.
- **Test in engine:** launch the current unsaved document straight into a
  chosen system with a chosen ship, plus a weapons test range.

- **HD art and 3D models:** add an HD sprite or model to any resource, see it
  side by side with the classic art exactly as the game will draw it, and pack
  it into the plug-in file or a `.nsx` folder. The embed, extract and
  validation code already exists in NovaSwiftKit (`GraphicsPackEmbedding`,
  `GraphicsEnhancementCatalog`) for the editor to use.

### Export and sharing

- Export as Windows `.rez` (EV Nova CE) or as a classic Mac resource-fork
  plug-in, with Mac/Windows conversion both ways.
- Publish to the in-app plug-in store with a version, description,
  screenshots and dependencies (for example "requires EV Override for Nova").
- A command-line tool (growing out of `novaswift-extract`) for the same
  pack, unpack, convert and validate jobs, so authors can script builds.

## Part 2: HD plug-in extensions

An optional NovaSwift layer that sits beside a normal plug-in and upgrades how
its content looks and sounds. Gameplay never changes; every extension falls back
to the classic resource when it's missing or turned off.

- **Keyed to original resources.** Each extension asset says which resource it
  replaces (for example "HD art for spïn 700", "audio for snd 300"), so one HD
  pack can upgrade base data or any plug-in.
- **HD sprites:** higher resolution, any frame count, smooth rotation, and
  optional normal maps so ships pick up light from nearby stars.
- **3D models:** USDZ ships, stations and planets today; glTF import is
  planned. Two ways to use them:
  - render them live in 3D in the Enhanced and Nova Swift presentations, or
  - bake them into classic sprite sheets with a built-in renderer: set the
    lighting and camera once, get correctly framed `rlëD`/`spïn` output with
    all rotation frames. This also helps people making classic plug-ins, which
    was one of the hardest parts of plug-in art.
- **Audio:** high-quality weapon, engine and ambient sounds in modern formats,
  music per system or per government, and optional positional audio in the
  modern presentations.
- **Landing and planet art:** high-resolution landscapes and animated planets.
- **Packaging:** an extension ships as a `.nsx` folder next to the plug-in, or
  inside the plug-in file itself as resources the original game ignores
  (`novaswift-hd embed`). Either way the plug-in still works on the original
  game and in NovaSwift's Classic presentation.

## Part 3: expanded plug-ins

The long-term aim is that a plug-in can change anything in the game, not just
the data the original format covers. Each ability is opt-in, stored in a way
the original game ignores, and falls back cleanly when missing:

- **Rules and limits:** override values the original hard-codes (fleet sizes,
  jump timing, ranks and the like) from a plug-in.
- **Scripted events:** mission logic and events beyond what control bits can
  express.
- **Interface:** new screens and HUD layouts.
- **Effects:** custom particle effects and shaders.

Each needs a format, a loader with fallback, editor support and docs before it
ships; none is started yet.

## Part 4: help for the community

- Starter templates: a new ship, a new outfit, a new system, a short mission
  chain.
- Documentation of every resource field in plain language, generated from the
  same schemas the editor uses.
- Step-by-step guides for the common jobs (adding a ship, writing a mission
  chain, making an HD pack).

## Order of work

| Step | What | Depends on |
|---|---|---|
| 1 | Write path, schemas, round-trip tests | nothing |
| 2 | Browser, hex editor, previews, export | 1 |
| 3 | Ship/outfit/weapon editors, test in engine | 2 |
| 4 | Galaxy editor, mission and control-bit editor, validation | 2 |
| 5 | Store publishing, CLI, templates and docs | 2 |
| 6 | HD extension format and loader, with fallback (**built**: [HD_PIPELINE.md](HD_PIPELINE.md)) | 1 |
| 7 | HD sprites, audio, landing art | 6 |
| 8 | 3D model import and sprite baking (**built**), live 3D view | 6 |
| 9 | HD art in the editor: add, preview, pack into the plug-in | 3, 6 |
| 10 | Expanded plug-ins: rules, scripted events, interface, effects | 1, 2 |

The pilot converter on the [roadmap](ROADMAP.md) shares the write path and is
planned separately.
