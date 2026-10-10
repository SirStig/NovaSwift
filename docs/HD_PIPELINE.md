# HD sprites and 3D models

NovaSwift can draw high-resolution art and 3D models in place of EV Nova's
original sprites. The upgrade ships as an optional layer next to a normal
plug-in, so the plug-in itself still works unchanged in the original game.

What it changes and what it doesn't:

- **Presentation only.** Frame counts, frame order, logical sprite size,
  hit-boxes (the classic collision masks), weapon exit points and all gameplay
  stay exactly the original's.
- **Opt-in.** Settings → Graphics → *HD graphics from plug-ins* (off by
  default). *Extra-sharp HD* switches from 2× to 4× detail.
- **Falls back cleanly.** Anything missing, invalid or not ready yet draws the
  classic sprite, and the reason is logged.

## What an enhancement targets

Every enhancement is keyed to a **sprite id**: the id the original sprite
loader resolves (`Sprite_CreateFromSpriteSheetResources` 0x00474ab0). That is
the `rlëD` with that id, or the PICT sprite sheet with that id. For example:

| To upgrade | Use the sprite id from |
|---|---|
| a ship's hull | its `shän` base image (`BaseImage`) |
| a planet or station | its `spïn` sprite id (`spöb` Graphic → `spïn` → sprite id) |
| an asteroid, shot or explosion | its `spïn` sprite id |

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
an earlier one's upgrade. This form suits small assets. Large models belong in
a sidecar folder instead (this form keeps every byte in memory).

### As a sidecar folder (`.nsx`)

A folder named `<anything>.nsx` holding `manifest.json` and the asset files.
The original game never looks inside folders.

- **Inside a plug-in's folder, or beside a loose `Name.rez` with the same base
  name:** it belongs to that plug-in and turns on and off with it.
- **On its own in the plug-ins folder:** it's a standalone HD pack.

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
| `bake.yaw` | model | extra turn about +Y, degrees |
| `bake.bankRoll` | model | roll for the banking sets, degrees (default 30) |
| `bake.fit` | model | fraction of the classic footprint to fill (default 1) |
| `bake.light` | model | key-light direction `[x, y, z]` (screen: right, up, toward viewer) |
| `bake.exposure` | model | light multiplier |
| `bake.scale` | model | cap on render detail |
| `bake.atmosphere` | model | planets: rim-glow colour `[r, g, b]`. Also switches to a single-sun light |

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
- A Godot-side loader. The catalog is portable; the CLI can pre-render models
  into `sprite` atlases for frontends without a 3D renderer.
