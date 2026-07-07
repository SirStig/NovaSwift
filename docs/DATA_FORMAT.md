# EV Nova Data Format Reference

Research notes for building a native parser for *Escape Velocity Nova* (Ambrosia Software /
Matt Burch). Covers the container format, resource types, and the RLE sprite encoding.

> Accuracy notes: field-level details below are cross-checked against the EV Nova Bible, the
> Macintosh resource-fork spec, and the NovaJS reference parser. Points I am not fully certain
> about are flagged with **(unverified)**.

---

## 1. The "EV Nova Bible"

The **Nova Bible** is the official developer document written by Matt Burch. It describes every
resource type and its fields, and is the canonical reference for plug-in authors.

Where to read it online:
- HTML (best maintained copy): https://andrews05.github.io/evstuff/guides/evnbible.html
- EVN Wiki overview: https://evn.fandom.com/wiki/Nova_Bible
- EV documentation hub: https://escape-velocity.games/docs

### Type-code spelling caveat (important for the parser)

Apple reserved all-lowercase-ASCII four-char codes for the system, so EV games deliberately use
four-char codes containing **extended Mac Roman characters** (umlauts/diaeresis). So the on-disk
codes are literally `shïp`, `wëap`, `oütf`, `mïsn`, `spöb`, `sÿst`, `gövt`, `spïn`, `dësc`, etc.
When you match type codes, compare the **raw 4 bytes in Mac Roman encoding**, not a UTF-8 or
ASCII-normalized spelling. (Mac Roman `ï`=0x95, `ë`=0x89, `ö`=0x9A, `ÿ`=0xD8, `ä`=0x8A,
`ü`=0x9F, `ö`=0x9A — verify each byte against a Mac Roman table when building the table.)

### Resource types (from the Nova Bible)

IDs start at **128** by convention (IDs below 128 are reserved). Each resource is identified by
its 4-char type + a signed 16-bit ID.

| Code   | Holds |
|--------|-------|
| `shïp` | Ship classes: performance, armament, AI, appearance, cost |
| `wëap` | Weapons: damage, ammo, guidance, rate of fire, linked explosion |
| `oütf` | Outfit items (equipment/upgrades sold at outfitters); can grant weapons/mods |
| `mïsn` | Missions: availability, cargo, special ships, rewards, bit conditions |
| `spöb` | Stellar objects (planets/stations): commodities, services, defense fleet |
| `sÿst` | Star systems: position on map, links, government, spöbs, asteroids |
| `gövt` | Governments: diplomatic relations, colors, enforcement, allies/enemies |
| `düde` | "Dude" = ship container: AI type, government, ship classes, booty odds |
| `flët` | Fleets: flagship + escort composition that populate systems |
| `përs` | Persons: named AI pilots (unique captains) with ship/weapons/greetings |
| `chär` | Character templates: starting ship, cash, date, legal status for new pilots |
| `crön` | Cron = time-dependent events (dates + control-bit conditions) |
| `jünk` | Junk = special/trade commodities with specific buy/sell locations |
| `öops` | "Oops" = planetary disasters that perturb commodity prices |
| `röid` | Asteroid types: strength, yield, fragmentation |
| `nëbu` | Nebulae: background images on the star map, optional event triggers |
| `ränk` | Ranks: player standing per government, salary, privileges |
| `spïn` | Sprite descriptor: ties an object to its rlë/PICT graphics + grid layout (see §3) |
| `shän` | Ship animation: banking frames, engine glow, shield, weapon-mount overlays |
| `bööm` | Explosion definitions: which sprite/sound to play, frame rate |
| `dësc` | Text descriptions (for planets, outfits, missions, ships, etc.) |
| `ïntf` | Interface: status-bar layout (radar, shields, fuel, target displays) |
| `cölr` | Colors/fonts/button placement for the UI |

Standard **Mac resource types** are also used (plain ASCII codes, no umlauts):

| Code   | Holds |
|--------|-------|
| `snd ` | Sound (note trailing space); classic Mac `'snd '` format |
| `PICT` | QuickDraw picture (bitmap graphics, e.g. landscapes, logos) |
| `cicn` | Color icon |
| `rlë8` | 8-bit (256-color, palette-indexed) RLE sprite sheet — see §3 |
| `rlëD` | 16-bit "deep" RLE sprite sheet (the format Nova actually ships) — see §3 |
| `STR#` | String list (indexed strings) |
| `TEXT` | Plain text |
| `vers` | Version resource (plug-in metadata) |

Tooling for inspecting/authoring these: **MissionComputer**, **ResEdit/Resorcerer** (classic
Mac), **EVNEW** (Windows), **RezEditor**, and the CLI **vasi/evnova-utils**.

---

## 2. Container / file format

### 2.1 Macintosh resource fork

On classic Mac OS, Nova data files and plug-ins store everything in the **resource fork**
(the data fork is empty). Big-endian throughout. Layout:

**Header — 16 bytes at offset 0:**

| Offset | Size | Field |
|--------|------|-------|
| 0  | u4 | Offset to resource **data** section |
| 4  | u4 | Offset to resource **map** |
| 8  | u4 | Length of data section |
| 12 | u4 | Length of map |

**Resource data section:** a sequence of resources; each is `u4 length` followed by `length`
bytes of raw resource data. A resource's data is located by adding its 3-byte data offset
(from the reference list) to the header's data-section offset.

**Resource map:**

| Offset | Size | Field |
|--------|------|-------|
| 0   | 16 bytes | (copy of the file header — usually ignored) |
| 16  | u4 | reserved (next-map handle) |
| 20  | u2 | reserved (file ref) |
| 22  | u2 | resource-fork attributes |
| 24  | u2 | offset to **type list**, from start of map |
| 26  | u2 | offset to **name list**, from start of map |

**Type list** (at map + typeListOffset):
- `u2 numTypes - 1` (count is stored minus one)
- then one 8-byte entry per type:
  - `4 bytes` type code (raw Mac Roman, e.g. `shïp`)
  - `u2` number of resources of this type **minus one**
  - `u2` offset to this type's **reference list**, measured **from the start of the type list**

**Reference list** (one contiguous run per type, in type-list order): 12 bytes per resource:
- `s2` resource ID
- `u2` offset to resource name (from start of name list), or `0xFFFF` if unnamed
- `u1` resource attributes
- `u3` (3-byte, big-endian) offset to this resource's data, from start of data section
- `u4` reserved (handle)

**Name list** (at map + nameListOffset): Pascal strings (1 length byte + bytes).

Spec sources:
- Kaitai spec (byte-exact, machine-readable): https://formats.kaitai.io/resource_fork/
- Inside Macintosh — Resource File Format: https://dev.os9.ca/techpubs/mac/MoreToolbox/MoreToolbox-99.html
- Wikipedia: https://en.wikipedia.org/wiki/Resource_fork

### 2.2 `.ndat` (cross-platform)

`.ndat` is **exactly the resource-fork bytes stored in the data fork** of an ordinary file (no
Mac fork needed). Parse it with the identical layout from §2.1 — just read the whole file as the
"resource fork" byte stream. Ambrosia migrated the Mac base data to `.ndat` so the same files
work on macOS, Windows, and Linux.

### 2.3 `.rez` — the "BRGR" Rez format (VERIFIED against real files)

**Correction (2026-07-07):** the `.rez` files distributed by the modern community (andrews05's
tooling, Graphite/ResForge, KDL) are **NOT** the old MacBinary/Windows container. They are the
**Graphite "Rez" extended format**, identified by a **`BRGR`** magic (0x42524752) at offset 0.
Confirmed by inspecting real files (The Frozen Heart TC: `E3 Data.rez`, `Override Essentials.rez`,
etc. — all start with `BRGR`). This is now the primary container we target, alongside classic
resource forks / `.ndat`.

Byte layout (per ResForge `RezFormat.swift` / burgerlib `brrezfile.cpp`) — **little-endian except
where noted**:

```
Root header (12 bytes)
  u32  signature      "BRGR" (read BIG-endian; == 0x42524752)
  u32  numGroups      == 1
  u32  headerLength    (<= file size)
Group header (12 bytes)
  u32  groupType      == 1
  u32  baseIndex       (resource indices are offset by this)
  u32  numEntries       N (last entry is the resource map itself)
Entry table: numEntries × 12 bytes
  u32  dataOffset       (absolute offset of this resource's raw bytes)
  u32  dataSize
  u32  nameOffset       (skipped — map is assumed the last entry)
Resource map (at offsets[last]) — read BIG-endian:
  u32  typeListOffset   (relative to mapOffset)
  u32  numTypes
  Type list: numTypes × 12 bytes
    u32/4cc  type          (raw Mac Roman four-char code, e.g. shïp)
    u32      resListOffset  (relative to mapOffset)
    u32      numResources
  Resource list: numResources × (10 + 256) bytes each
    u32   index         (subtract baseIndex → row in the entry table)
    u32   type          (duplicate; skip)
    i16   id
    char  name[256]     (NUL-terminated Mac Roman C string, fixed 256-byte field)
  → raw data at entryTable[index].dataOffset, length entryTable[index].dataSize
```

Note: resource IDs are `Int16` (signed), so negative IDs are possible. Data bytes are stored raw
(no per-resource length prefix — unlike the classic fork, whose data section prefixes each blob
with a u32 length).

Sources:
- ResForge `RezFormat.swift`: https://github.com/andrews05/ResForge (MIT — used as spec)
- burgerlib `brrezfile.cpp`: https://github.com/Olde-Skuul/burgerlib
- Graphite `libGraphite/rsrc/rez.cpp`: https://github.com/TheDiamondProject/Graphite
- (Old Windows/MacBinary `.rez` conversion, historical): https://evn.fandom.com/wiki/Windows_Plugin_Conversion_Tutorial

---

## 3. Sprites: `spïn`, `rlëD` / `rlë8`, `PICT`

### 3.1 How graphics are referenced

A **`spïn`** resource is the descriptor that links a game object to its graphics. It records the
sprite-sheet resource ID(s) and the **grid geometry**: tile width, tile height, and how many
tiles across / down the sheet is arranged (e.g. 36 rotation frames laid out in a 6×6 grid). The
actual pixels live in a `rlëD`/`rlë8` (or `PICT`) resource referenced by that ID.
(`spïn` field-level details: https://evn.fandom.com/wiki/Sp%C3%AFn — was paywalled during
research, confirm exact field offsets against MissionComputer or a real resource. **(unverified
field layout)**)

Sprites come as **sprite sheets**: N animation/rotation frames tiled into a grid, plus a matching
**mask** (black/white) marking transparent pixels. In `rlëD`/`rlë8` the mask/transparency is
encoded directly into the RLE stream (via transparent-run opcodes), so a separate mask resource
is only needed for `PICT`-based pipelines.

### 3.2 `rlëD` (16-bit) / `rlë8` (8-bit) RLE format

`rlë8` = 8-bit palette-indexed; `rlëD` = 16-bit direct color ("D" for deep). Nova ships `rlëD`.
Structure below is from the NovaJS reference decoder
(https://github.com/mattsoulanille/NovaJS, `novaparse/.../RledResource.ts`). Big-endian.

**Header:**

| Offset | Size | Field |
|--------|------|-------|
| 0 | u2 | frame width (px) |
| 2 | u2 | frame height (px) |
| 4 | u2 | bit depth (16 for `rlëD`) |
| 6 | u2 | (reserved / palette-related) **(unverified)** |
| 8 | u2 | number of frames |
| ...| | (remaining header bytes reserved) |

**Frame data** follows as a stream of **32-bit tokens**: the **high byte is the opcode**, the low
24 bits are a **count/length**:

| Opcode | Name | Meaning |
|--------|------|---------|
| `0x00` | End of frame | Frame finished; advance to next frame |
| `0x01` | Line start | Begin a new scanline; reset the x cursor to 0 |
| `0x02` | Pixel data | Count = number of **bytes** of literal pixel data that follow inline; copy them, then **pad to a 4-byte boundary** |
| `0x03` | Transparent run | Skip `count` bytes' worth of pixels (leave transparent); for 16-bit, pixels = count/2 |
| `0x04` | Pixel run | Repeat a single pixel value across `count`'s worth of pixels |

Decoding walks scanline by scanline: `Line start` resets x, then a mix of transparent/pixel/run
tokens fills the row until the next `Line start`; `End of frame` closes the frame. Repeat for
`frameCount` frames, each `width×height`.

**Pixel color (`rlëD`, 16-bit):** each pixel is a big-endian u2 in **x1-5-5-5** layout
(classic Mac 16-bit, a.k.a. `xRGB1555` / ARGB1555):
- bit 15: unused (treat alpha as opaque)
- bits 14-10: red (5 bits)
- bits 9-5: green (5 bits)
- bits 4-0: blue (5 bits)

Upscale 5→8 bits by `(v << 3) | (v >> 2)`. Transparency comes from the transparent-run opcodes,
not from a color key.
> Note: the NovaJS summary labeled this "RGB565," but the bit breakdown it uses (5/5/5 + 1 unused)
> is actually **555**, matching classic Mac 16-bit. Verify against real sprite output; if colors
> look shifted, re-check 555 vs 565.

**`rlë8` (8-bit):** same token machinery but pixels are 1-byte palette indices into a 256-color
CLUT (the classic Mac system/game palette). Modern engines only need `rlëD`.

Format background: https://opennovablog.wordpress.com/2017/05/27/run-length-encoding-rle-resources/
and https://opennovablog.wordpress.com/tag/sprites/

### 3.3 `PICT`

Standard QuickDraw picture format (opcodes + packed bitmap). Used for non-sprite art
(planet-landing images, backgrounds, logos). Many decoders exist; treat as a separate codepath
from RLE. For sprite objects that use PICT, a companion mask PICT supplies transparency.

---

## 4. How the base game ships its data & plug-ins

- **Load order:** base data first, then plug-ins **override/extend** it. A plug-in supplying a
  resource with the same type+ID as a base resource replaces it. Historically: **Nova Files /
  Nova Data** folder loaded first, then the **Nova Plug-ins** folder.
- **Base data is split across multiple files** (Ambrosia split it to keep any one resource file
  under the classic ~16 MB resource-fork practical limit). On Mac the base data files are
  resource-fork files; Ambrosia later migrated them to **`.ndat`** (§2.2) for cross-platform use.
  **(unverified: the exact base filenames — commonly cited as "Nova Data" / "Nova Graphics"
  numbered files; confirm against an actual install.)**
- **Plug-in file types/extensions:**
  - Classic Mac plug-ins: resource-fork files, usually **no extension** (Finder file type
    identifies them).
  - Cross-platform: **`.ndat`**.
  - Windows port: **`.rez`**.
- **"ares"** is a *different* Ambrosia game (Ares / Ares: Marathon-lineage), **not** part of
  EV Nova. Ignore for this port unless you specifically want its (different) format.

Reference tooling / clones worth studying for a parser:
- NovaJS (TypeScript parser + engine): https://github.com/mattsoulanille/NovaJS
- vasi/evnova-utils (Perl inspection tools): https://github.com/vasi/evnova-utils
- OpenNova project blog: https://opennovablog.wordpress.com/
- andrews05 EV stuff (Bible + tools): https://andrews05.github.io/evstuff/

---

## Sources

- EV Nova Bible: https://andrews05.github.io/evstuff/guides/evnbible.html
- EVN Wiki (Nova Bible, Plug-in, Spïn): https://evn.fandom.com/wiki/Nova_Bible ·
  https://evn.fandom.com/wiki/Plug-in · https://evn.fandom.com/wiki/Sp%C3%AFn
- Resource fork spec (Kaitai): https://formats.kaitai.io/resource_fork/
- Inside Macintosh — Resource File Format: https://dev.os9.ca/techpubs/mac/MoreToolbox/MoreToolbox-99.html
- Resource fork (Wikipedia): https://en.wikipedia.org/wiki/Resource_fork
- RLË resources (OpenNova): https://opennovablog.wordpress.com/2017/05/27/run-length-encoding-rle-resources/
- NovaJS RLE decoder (RledResource.ts): https://github.com/mattsoulanille/NovaJS
- Windows plug-in conversion: https://evn.fandom.com/wiki/Windows_Plugin_Conversion_Tutorial
