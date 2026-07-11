# Getting the game data

This port uses a **bring-your-own-data** model. EV Nova's base game data is
copyrighted and privately held (it was shareware, never released as freeware),
so it is **not** distributed with this project. You supply it from your own
legally-obtained copy. The port's job is to *read and run* your data.

> **Legal one-liner:** owning/registering EV Nova is fine; redistributing its
> data files is not. This repo never contains them (see `.gitignore`).

## 1. Get & register EV Nova (if you own it)

- EV Nova is no longer sold on any storefront (Ambrosia is defunct; not on
  Steam/GOG/App Store).
- If you own it, **Decoder Ring** — released 2023 by Ambrosia's former president
  Andrew Welch — generates valid registration codes on modern macOS. This is
  community-sanctioned for *registration* (not redistribution).
- To run the classic app on Apple Silicon, the community **"EV Nova mod 4"**
  macOS build works on current macOS. See <https://andrews05.github.io/evstuff/>.

## 2. Locate your data files

EV Nova data lives in the game's `Nova Files` folder as classic-Mac
**resource-fork** files, or as cross-platform **`.ndat`** files (same bytes, in
the data fork). Windows uses **`.rez`**.

Copy your data into:

```
data/base/          ← your EV Nova base data (*.ndat or resource-fork files)
data/plugins/       ← plug-ins / total conversions
```

Both folders are git-ignored — nothing here is ever committed.

## 3. Extracting a resource fork on modern macOS

Modern macOS can't use the old resource-fork APIs directly, but you have options:

- **This project's tool:** `novaswift-extract` reads resource-fork and `.ndat`
  directly (see `tools/extractor/`).
- Read a file's resource fork by appending `/..namedfork/rsrc` to its path.
- **ResForge** (<https://github.com/andrews05/ResForge>) — modern Swift editor
  with full EV Nova templates; good for inspecting/exporting by hand.
- **`.ndat` is the easy path** — it's the resource fork stored in a normal file,
  no fork trickery needed.

## 4. Free community plug-ins & total conversions (for testing and play)

These are **fan-made and freely downloadable**, and double as real test data for
the parser. They still require the base game to *play*, but their files are valid
Nova resource forks you can parse immediately.

`scripts/fetch-plugins.sh` downloads a curated set into `data/plugins/`:

- Polycon EV, The Frozen Heart, Femme Fatale, EV Classic for Nova,
  EV Override for Nova — from <https://andrews05.github.io/evstuff/>.
- Larger archives (ARPIA2, Anathema, Colosseum, …) are catalogued at
  <https://download.escape-velocity.games/> and the Internet Archive
  "Escape Velocity Plugin Collection".

**Redistribution caveat:** you may freely *download and play* these; *bundling*
one inside a shipped app is a per-author permission question — check each mod's
readme.
