# Importing original EV Nova pilots

How NovaSwift reads a player's original pilot file and turns it into a native
`.evpilot` save. Code: `Sources/NovaSwiftStory/EVNovaPilotFile.swift` (container
and cipher), `EVNovaPilotImport.swift` (field mapping), UI in
`app/NovaSwift/Pilots/PilotImportView.swift`. Addresses are for the EV Nova CE
Windows executable (sha256 `4fd5d9b4…`).

The source file is only ever read. Tests use synthetic pilots written by the
tests' own encoder.

## Functions

| Address | Name | Role |
|---|---|---|
| 0x004c7db0 | `PilotFile_SaveGame` | Save entry point; passes the landing stellar as a 0-based index. |
| 0x004c7dd0 | `PilotFile_SaveGameCore` | Writer: two size-prefixed blocks plus the ship name. |
| 0x004cb260 | `PilotFile_LoadSave` | Loader; restores every field below and returns "repairs applied" (-0x2e) when it had to drop unknown content. |
| 0x008725b0 | `PilotSave_DecodeBlock` | Leaves a block alone if its first little-endian word is below 0x800, otherwise runs the transform. |
| 0x0046f960 | block transform | The symmetric cipher, called with the key 0xb36a210f. |

## Cipher

Words of four bytes are read big-endian (on the little-endian Windows build the
key is byte-swapped to match), XORed with the key, written back, and the key
advances as `key = (key + 0xdeadbeef) ^ 0xdeadbeef`. The 0 to 3 trailing bytes
are XORed with the high byte of the current key, then the next, and so on. It is
its own inverse. Known answers (run through the original code under the oracle
emulator) are in `EVNovaPilotImportTests.testCipherMatchesOriginalExecutable`.

## Containers

- **Windows `.plt`**: `u32 size1 = 0xe952`, block 1, `u32 size2 = 0x66fe`,
  block 2, then the ship name as a NUL-terminated string. Little-endian.
  Both blocks are normally encrypted. Block 2 carries a version word (300) at offset 0. The loader rejects 0x6b and
  anything below 300. A plaintext block whose first word is 0x800 or more would
  be mistaken for ciphertext; real saves avoid this.
- **Classic Mac**: resource type `Np•L` (bytes 4e 70 95 4c), id 128 is block 1
  (0xe9b2 bytes), id 129 is block 2 (0x66fe bytes) and **the ship name is
  resource 129's name**. Scalars are big-endian, block 1 is always encrypted,
  block 2 is plain, and strings are Pascal strings. The file may be a bare
  resource fork, an AppleDouble file (`._name`, entry 2), a MacBinary file
  (resource fork at 128 + data length rounded up to 128), or on macOS the file's
  own `..namedfork/rsrc`.
- Windows-framed files that still hold a big-endian payload (Mac pilots run
  through a converter) are detected from the version word.

Mac block 1 has six extra bytes in each of the 16 mission records (stride 0x8ec
instead of 0x8e6): two at +0x20, one at +0x35 and three at the end. They are
removed after decrypting, giving the Windows layout. **This is not verified
against a real Mac pilot.** The reference converter's constants disagree with
the offsets its own notes give for later fields (0x8ea per record against 0xb81e
for the control bits); the importer follows the offsets and block sizes.

## Block 1 (0xe952 bytes) and where each field goes

Stellar and system ids in the file are 0-based indices; NovaSwift ids are the
resource ids (index + 128).

| Offset | Size | Field | Mapped to |
|---|---|---|---|
| 0x0000 | u16 | landing stellar, 0xffff = none | `landedSpob`, `currentSystem` (the system containing it). Position and heading are not saved by the original either. |
| 0x0002 | u16 | ship class | `shipType` |
| 0x0004 | u16 x6 | commodity tons | `cargo[0...5]` |
| 0x0010 | u16 | shield | ignored (the loader recomputes it); ships load at full shield and armor |
| 0x0012 | u16 | fuel | `fuel` |
| 0x0014/16/18 | u16 | month, day, year | `date` |
| 0x001a | u16 x0x800 | discovery level per system (1 arrived, 2 landed or charted) | `exploredSystems`, `landedSystems` |
| 0x101a | u16 x0x200 | owned count per outfit | `outfits` (weapons and ammo outfits included) |
| 0x141a | i16 x0x800 | legal record per system | `systemReputation` |
| 0x241a / 0x261a | u16 x0x100 | weapon banks mounted / loaded rounds, per wëap | raised into the installing / ammo outfit's count when the outfit array is lower |
| 0x281a | u32 | credits | `credits` |
| 0x281e | 16 x 0x14 | mission runtime flags: active, travel stellar reached, objective complete, failed (bytes), accept-time flags, deadline date | active mission list, `visitedTravelStellar`, `objectiveComplete`, `failed` |
| 0x295e | 16 x 0x8e6 | active missions (below) | `activeMissions` |
| 0xb7be | 10000 bytes | control bits | `setBits` (every nonzero byte) |
| 0xdece | u8 x0x800 | stellar dominated | `dominatedStellars` |
| 0xe6ce | u16 x0x40 | escort ship classes; 1000 or more means hired | `escorts` (hired pays the daily fee; below 1000 is free, imported as captured) |
| 0xe74e | u16 x0x40 | launched carrier fighters | not carried over (fighters restock from outfits) |
| 0xe7ce / 0xe84e | u16 x0x40 | escort upgrade mark / sale mark | `pendingUpgradeTo` (the hull's UpgradeTo) / `pendingSale` |
| 0xe8ce | u16 x0x40 | fighter voice-type modes | not carried over |
| 0xe94e | u32 | combat rating | `combatRating` |

Whether an escort is hired comes from the payroll routine (0x004232d0), which
charges only escorts whose flag at ship +0xbb is set; the loader sets that flag
exactly for class ids of 1000 or more. A mission-granted escort cannot be told
from a captured one in the file.

### Active mission record (0x8e6 bytes, packed)

The record is the runtime copy made by `Mission_PopulateMissionSlotFromDef`
(0x0043f8c0) and the loader copies it field by field. Offsets used:

| Offset | Meaning | Mapped to |
|---|---|---|
| +0x00, +0x04 | travel and return stellar (0-based) | `travelSpobID`, `returnSpobID` |
| +0x06, +0x30 | ship count, target count | `shipObjectivesRemaining` |
| +0x0a | ship goal (0 destroy, 1 disable, 2 board, 3 escort, 4 observe, 5 rescue, 6 chase off) | used for the remaining count |
| +0x10 | special ships' system (0xfffa = follow the player) | `shipSystemID` |
| +0x12, +0x14 | resolved cargo type and quantity | `resolvedCargoType`, `resolvedCargoQty` |
| +0x26 / +0x28 / +0x2a / +0x2c / +0x2e | destroyed / boarded / disabled / sighted / chased-off counters (identified from the objective evaluator 0x00443c60) | `shipsDestroyed`, `shipsBoarded`, `shipsDisabled`, `shipsSighted`, `shipsChasedOff` |
| +0x33 | carrying the mission cargo | `cargoPickedUp` |
| +0x45 | days left before the deadline (-32000 = none) | `deadline` = save date + days |
| +0x47..+0x51 | ship name and subtitle STR# ids and entries | `shipNameEntry`, `shipSubtitleEntry` |
| +0x4d | mission index (0-based mïsn) | `missionID` |
| +0x53, +0x55 | special ship type index, mission flags | `lockedShipType` when flag 0x0800 is set |
| +0x61, +0x6b | aux ship count, remaining | `auxShipsRemaining` |

Everything else in the record (briefing text ids, the six 255-byte script
strings, random rolls) is rebuilt from the mïsn definition by NovaSwift and is
not read. A slot whose mission is not in the loaded data is dropped with a
warning. The original does not store when a mission was accepted, so accept
dates become the pilot's current date.

## Block 2 (0x66fe bytes)

| Offset | Size | Field | Mapped to |
|---|---|---|---|
| 0x0000 | u16 | version, 300 | validation and byte-order detection |
| 0x0002 | u16 | Strict Play | `strictPlay` |
| 0x0004 | u16 | gender (1 = male) | `isMale` |
| 0x0006 | u16 x0x800 | defenders present per stellar | `stellarGarrisons` for non-dominated stellars that have defenders and whose count differs from the full count |
| 0x1006 | u16 x0x400 | përs alive and available | `defeatedPers` only when the përs' ActiveOn holds under the imported bits (the flag is also 0 for a përs that isn't active) |
| 0x1806 | u16 x0x400 | përs grudge | `persGrudges` |
| 0x2086 | u16 x0x800 | per-stellar annoyance counter | not carried over |
| 0x3086 | u8 | intro-seen latch | not carried over |
| 0x3088 | i16 x0x100 | **per öops: days left** (the earlier notes call these "def ids") | `activeDisasters` = save date + days |
| 0x3288 | u16 x0x100 | per öops: chosen stellar | `disasterStellars` (random-stellar disasters) |
| 0x3488 | u16 x0x80 | junk counts | `cargo[128 + index]` |
| 0x3590 / 0x3990 | i16 x0x200 | crön duration / holdoff counters, -1/-1 = inactive | `cronRuntime` with `active`, `duration`, `holdoff` |
| 0x3d90 | u16 x0x800 | per-system reinforcement cooldown | `reinforcementRetriggerDays` |
| 0x4d90 | u16 x0x800 | per-stellar regeneration countdown (1 or more = destroyed) | `destroyedStellars`, `stellarDestroyedOnDay` (backdated from the stellar's DeadTime) |
| 0x5d90 | i16 x4 | escort group-order commands (`g_target_category_command`, -1 = none; 0 formation, 1 defend, 2 attack, 3 return, 4 hold) | `escortCategoryOrders` (restored into `OriginalAI.categoryCommand`, saved with the pilot) |
| 0x5d98 | 0x40 | nickname | `nickname` |
| 0x5dd8 | u16 x3 | ship paint color | not carried over |
| 0x5dde | u16 x0x80 | active ranks | `activeRanks` |
| 0x5ede / 0x5eee | 15 | date prefix / suffix | `datePrefix`, `dateSuffix` |

Strings are C strings on Windows and Pascal strings on classic Mac; the importer
treats a field as Pascal when its first byte is a plausible length and the text
holds no NUL. The four words at 0x3588/0x358a/0x358c/0x358e are the
original's player stat-modifier globals (DAT_007353f6/f8/fa/fc; init 100). The
first pair is jittered +-1 within 85..115 and the second re-rolled to 90..110 on
each hyperjump (`Frame_JitterPlayerStatModifiers` 0x00431480,
`Frame_RerollPlayerStatModifiers` 0x00431500). Nothing in the decompile reads
them besides the save/load code, so they have no gameplay effect; they are not
imported and only noted in the summary if nonzero.

## What the importer does about missing content

Everything is resolved against the loaded data (base game plus enabled
plug-ins). Unknown ship classes fall back to the first ship; unknown outfits are
kept in the pilot but inactive (the app prunes them on load, as for any removed
plug-in); unknown missions, escorts, crön events, ranks, junk, systems and
stellars are dropped. Each case adds a line to the warnings shown before the
pilot is created.

## Verification and limits

- The cipher matches the original executable's transform on two vectors taken
  from the oracle emulator.
- The writer (0x004c7dd0) was not run under the emulator: it reaches into the
  file and resource layers, which the oracle does not model. The test encoder
  follows the writer's layout from the decompilation and the loader's read order
  instead, so a layout mistake shared by both would not be caught.
- Classic Mac layout is the least certain part (see above).
