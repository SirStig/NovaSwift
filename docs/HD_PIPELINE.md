# HD sprites and 3D models

NovaSwift can draw high-resolution art and 3D models in place of EV Nova's
original sprites. The upgrade ships as an optional layer next to a normal
plug-in, so the plug-in itself still works unchanged in the original game.

What it changes and what it doesn't:

- **Presentation only.** Frame counts, frame order, logical sprite size,
  hit-boxes (the classic collision masks), weapon exit points and all gameplay
  stay exactly the original's.
- **Opt-in.** Settings → Graphics → *HD graphics from plug-ins* (off by
  default). *Extra-sharp HD* switches from 2× to 4× detail. When HD art turns
  up while it's off (a plug-in installed from the Plugins screen, or a pack
  found on load), the game asks once: *Enable HD Graphics?*
- **Falls back cleanly.** Anything missing, invalid or not ready yet draws the
  classic sprite, and the reason is logged.

## What an enhancement targets

Every enhancement is keyed to a **sprite id**: the id the original sprite
loader resolves (`Sprite_CreateFromSpriteSheetResources` 0x00474ab0). That is
the `rlëD` with that id, or the PICT sprite sheet with that id. For example:

| To upgrade | Use the sprite id from | Frames are | Use |
|---|---|---|---|
| a ship's hull | its `shän` base image (`BaseImage`) | headings (+ banking/lit sets) | `model` or `sprite` |
| a hull's engine, light or weapon glow | its `shän` overlay images | match the hull | usually derived from the hull's model (see Effects) |
| a planet or station | `spöb` Graphic → `spïn` → sprite id | one still frame | `model` or `sprite` |
| an animated stellar (hypergate, wormhole) | the same | an animation loop | `sprite` only |
| an asteroid | `röid` → `spïn` (röid id + 672) → sprite id | headings (a tumble) | `model` or `sprite` |
| a shot (missile, bolt) | `wëap` Graphic → `spïn` → sprite id | headings, or an animation for spinning shots | `model` for headings, else `sprite` |
| an explosion | `bööm` Graphic → `spïn` → sprite id | an animation | `sprite` only |
| the starfield | `spïn` #700 → sprite id | star variants | `sprite` only |

A `model` is always rendered as a turn: frame *n* is heading *n* × 360° /
frames. So any sheet whose frames are an animation rather than headings
(explosions, animated stellars, the starfield) has to ship as a pre-rendered
`sprite` atlas.

Wherever the game draws that sprite, the enhancement draws instead. Every ship
that shares the art (variants, for example) gets the upgrade too.

## Two kinds of asset

**`sprite`: an HD atlas.** A PNG with the classic sheet's exact layout (same
frame count and order, 6 frames per row by default) drawn at `scale` pixels per
classic pixel. Use it for hand-painted or pre-rendered art.

**`model`: a 3D model** (USDZ). NovaSwift renders it into the classic frame
layout the way the original sprites were made: a fixed camera looking down at
the ship, the key light fixed at the upper left, and the ship turning
underneath. It renders every heading, plus the bank-left and bank-right sets
for banking hulls. The model is sized automatically so it covers the classic
sprite's footprint. Renders are cached per device, so each model is rendered
once.

Model files: USDZ is the standard (also `.usd`/`.usda`/`.usdc`, `.scn`, `.dae`
and `.obj`). glTF, FBX and `.blend` aren't read directly: export USDZ from
Blender (File → Export → Universal Scene Description) or convert with Apple's
Reality Converter. A rejected format is named in the log and in `preview`.

Model conventions: Y up, nose toward +Z (glTF/USD), any units. Use `bake.yaw`
for models that face another way. Physically based materials (base colour,
metalness, roughness, normal, emission) carry through.

## Effects

A hull's effects keep working with a model. The game still decides *when*
they show: engine glow while thrusting, running lights blinking to the
`shän` pattern, the weapon flash and its decay. The model supplies *what*
they look like, rendered into the hull's own classic overlay sprites so they
line up with the model:

| Layer | Classic overlay it replaces | Default part names |
|---|---|---|
| `engine` | `shän` engine glow | `engine`, `thruster`, `exhaust` |
| `lights` | `shän` running lights | `light`, `beacon`, `nav_` |
| `weapons` | `shän` weapon glow | `weapon`, `muzzle` |

Two ways to say what glows:

- **Named parts.** Name a part or its material with one of the strings above
  (or set `"layers": {"engine": ["Nozzle"]}`). In the hull render the part's
  glow is off; in the layer render only its glow shows, and the rest of the
  hull hides whatever is behind it.
- **Emitters.** For models with no separate parts (a single scanned or
  generated mesh), list soft glows by position:
  `"effects": [{"layer": "engine", "at": [0.13, 0, -0.93], "radius": 0.09, "color": [0.65, 0.85, 1]}]`.
  Positions are in the model's fitted space: centred, nose toward +Z, the
  widest horizontal extent spanning −1…1.

If the classic hull has no overlay for a layer, that layer's glow is rendered
into the hull, always on (so a model's running lights still show on a hull
the original drew without them). Classic overlays a model doesn't replace are
hidden, because they're pixel-matched to the classic art. The alternating-
sprite layer is always hidden under a model. Effect layers render at half the
hull's detail: glows are soft, and it saves three quarters of their memory.

Everything else carries over without help from the pack:

- Shots, explosions, asteroids, debris and shield bubbles are sprites, so a
  pack can upgrade them by sprite id too.
- Ionisation, cloak and damage tints are shaped from the hull's own texture,
  so they follow the HD art automatically.
- Thruster flames and beams are drawn by the engine itself.
- Weapon exit points stay the original's (they're gameplay). The model is
  fitted to the classic footprint, so put gun barrels where the classic art
  had them.

## Shipping it

### Inside the plug-in file

Two resource types the original game never asks for, so the file still loads
there unchanged:

- **`NSgx` #<sprite id>**: a UTF-8 JSON descriptor (fields below).
- **`NSbl` #<any id>**: the asset bytes (PNG or USDZ). The descriptor points
  to it with `"blob": <id>`.

They follow the normal plug-in override order, so a later plug-in can replace
an earlier one's upgrade. In-file assets must be PNG or USDZ.

To put a pack inside an existing plug-in (say, HD art for Arpia 2) and ship it
as one file:

```
novaswift-hd embed "Arpia 2.rez" "Arpia HD.nsx" "Arpia 2 HD.rez"
novaswift-hd unembed "Arpia 2 HD.rez" "Arpia HD.nsx"   # back to an editable folder
```

The repacked file still loads unchanged in the original game. Embedding again
replaces the art for the same sprites rather than duplicating it. The whole file
is read into memory, so very large packs are better as a sidecar.

### As a sidecar folder (`.nsx`)

A folder named `<anything>.nsx` holding `manifest.json` and the asset files.
The original game never looks inside folders.

- **Anywhere inside a plug-in's folder** (for example `My Plug-in/Graphics/My HD.nsx`),
  **or beside a loose `Name.rez` with the same base name:** it belongs to that
  plug-in and turns on and off with it. With nested plug-in folders, the
  innermost one owns the pack.
- **On its own, or in a folder with no plug-in files** (a graphics-only
  download such as Nova Reimagined): a standalone HD pack. It applies whenever
  HD graphics are on; remove the folder to remove it.

Packs are found up to four folders deep below a plug-ins folder, which covers
the plug-in manager's layout (`<plug-in id>/<the zip's own folder>/My.nsx`).
Folders inside a pack are never searched.

Sidecars apply after in-file descriptors, in plug-in load order; standalone
packs apply last, by name. A later layer wins the same sprite id.

```json
{
  "format": 1,
  "name": "Nova Reimagined",
  "author": "…",
  "license": "MIT",
  "graphics": [
    { "kind": "model",  "sprite": 1010, "file": "starbridge.usdz" },
    { "kind": "model",  "sprite": 2002, "file": "ocean_world.usdz",
      "bake": { "yaw": 180, "pitch": 12, "atmosphere": [0.30, 0.75, 0.85] } },
    { "kind": "sprite", "sprite": 2300, "file": "station@4x.png", "scale": 4 }
  ]
}
```

File paths are relative to the `.nsx` folder and must stay inside it.

## Descriptor fields

| Field | Kinds | Meaning |
|---|---|---|
| `kind` | all | `"sprite"` or `"model"` |
| `sprite` | sidecar | sprite id (in-file: the `NSgx` resource id) |
| `file` / `blob` | all | sidecar path / `NSbl` id |
| `scale` | sprite | pixels per classic pixel (default 2) |
| `columns` | sprite | frames per row (default 6) |
| `frameCount` | sprite | optional check; must equal the classic sheet's |
| `overlays` | all | `"keep"` or `"hide"` the classic overlays the asset doesn't replace. Default: `hide` for models, `keep` for sprites |
| `live` | model | allow drawing live in 3D (planned presentation) |
| `layers` | model | effect layer → part-name substrings (see Effects) |
| `effects` | model | emitters: `layer`, `at` [x, y, z], `radius` (default 0.06), `color` [r, g, b] |
| `bake.pitch` | model | camera elevation in degrees (default 38; 12 suits planets) |
| `bake.yaw` | model | extra turn about +Y, degrees, for models whose nose isn't +Z |
| `bake.tilt` | model | turn about X before `yaw`, degrees: ±90 fixes Z-up exports. On a non-hull rotation sheet (asteroids) a partial tilt makes the turn read as a tumble |
| `bake.rotate` | model | full up-axis fix `[x, y, z]` degrees, applied in that order before `yaw`. Overrides `tilt` |
| `bake.orientation` | model | exact 3×3 rotation, row-major, mapping the model's axes onto (wingspan, height, nose). Overrides `rotate` and `tilt`. Written by `novaswift-hd orient` |
| `bake.bankRoll` | model | roll for the banking sets, degrees (default 30) |
| `bake.fit` | model | fraction of the classic footprint to fill (default 1) |
| `bake.light` | model | key-light direction `[x, y, z]` (screen: right, up, toward viewer) |
| `bake.exposure` | model | light multiplier |
| `bake.scale` | model | cap on render detail |
| `bake.atmosphere` | model | planets: rim-glow colour `[r, g, b]`. Also switches to a single-sun light |
| `bake.spin` | model | reserved for live 3D drawing (degrees per second); ignored for now |

## Making a pack

1. Find the sprite id (see the table above). `novaswift-extract ship <Nova Files> <id>`
   and `novaswift-extract list <file> spïn` help.
2. Make the art: a USDZ model (Y up, nose +Z), or a PNG atlas at 2× or 4× in
   the classic sheet's layout.
3. Put it in `<Name>.nsx/` with a `manifest.json`, inside your plug-in's
   folder (or on its own for a graphics-only pack).
4. Check it: `novaswift-hd preview <Nova Files> <your plug-ins folder> <out>`
   resolves the pack exactly as the game does, reports anything it rejects,
   and writes classic-vs-HD comparison sheets.
5. In the game, turn on Settings → Graphics → *HD graphics from plug-ins*.
   The developer console's `hd` command shows what was found and loaded.

Zip the plug-in folder as usual; the plug-in manager installs it as is.

When listing it in the plug-in catalog, add the tag `HD Graphics` (shown as a
badge and searchable) and set `minNovaSwiftVersion`, since the original game
ignores the pack. An HD pack for someone else's plug-in should list that
plug-in under `dependencies`.

## Performance

Measured with the Nova Reimagined demo (one 108-frame hull and four planets) on
an M-series Mac, via `novaswift-hd preview`:

| Detail | First load (render) | Later loads (cache) | Texture memory |
|---|---|---|---|
| 2× | 0.88 s | 18 ms | 5 MB |
| 4× | 0.74 s | 48 ms | 21 MB |

All preparation happens on the loading screen ("Preparing HD graphics"). In
flight, each upgraded sheet is a single GPU texture whose frames are
sub-rectangles, so ships of one hull still batch. A sprite that isn't ready
draws classic and is prepared in the background. Atlases are capped at
8192 px a side (the floor for every supported GPU), lowering the scale if
needed.

## Tools

`novaswift-hd` (macOS):

- `preview <Nova Files> <plug-ins dir> <out> [scale]`: resolve every
  enhancement the way the app does and report timings and memory. Writes
  classic-vs-HD comparison images.
- `model <Nova Files> <model.usdz> <ship id | s<sprite id>> <out> [yaw] [pitch] [r,g,b]`:
  render one model against the sprite it replaces.
- `planet <surface map.png> <out.usdz>`: wrap an equirectangular map on a sphere.
- `asteroid <seed> <r,g,b> <out.usdz> [rock|ice|pitted]`: a procedural rock tinted to a colour.
- `refsheet <Nova Files> <ship id> <out.png>`: the classic hull from several angles, as a
  reference for artists or image models.
- `orient <Nova Files> <model.usdz> <ship id>`: find the rotation that best matches a
  generated model to the classic sprite; prints `best orientation a,b,…` for `bake.orientation`.
- `portrait <model.usdz> <out.png> [yaw]`: the three-quarter UI portrait the game makes
  for hull models (shipyard, hail, target display).
- `embed` / `unembed`: move a pack into or out of a plug-in file (see above).
- `projectile <missile|rocket|torpedo|hellhound> <body r,g,b> <trim r,g,b> <out.usdz>`:
  a procedural shot model.
- `sheetinfo <Nova Files> <sprite id>…`: frame size and count of classic sheets.
- `probe`: an orientation test model.

`RezWriter` (NovaSwiftKit) writes `.rez` files for the in-file form.

## Code map

- `Sources/NovaSwiftKit/GraphicsEnhancements.swift`: descriptor, manifest,
  catalog and layering, `.nsx` discovery (Foundation only, portable).
- `Sources/NovaSwiftHD/`: `HDAtlas` (load, check, resample), `ModelStage` (the
  camera and light rig), `ModelBaker`, `HDBakeCache`, `HDAssetPipeline`,
  `SpriteLayouts`. Apple only (SceneKit, which Apple has soft-deprecated; the
  renderer sits behind `HDAssetPipeline`, so it can move to RealityKit).
- `app/NovaSwift/Data/HDGraphics.swift`: runtime layer (prewarm, textures,
  overlay hiding). `SpriteTextures` is the single place it hooks in.

## Not done yet

- Live 3D presentation (smooth rotation and real lighting via `SK3DNode`) for
  models marked `live`.
- HD for interface art, landing pictures and the shipyard/outfitter images.
- A plug-in editor (a modern Mission Computer) covering the classic resource
  types and these HD/3D additions. The embed, extract and validation code lives
  in NovaSwiftKit so the editor can use it directly.
- A Godot-side loader. The catalog is portable; the CLI can pre-render models
  into `sprite` atlases for frontends without a 3D renderer.
