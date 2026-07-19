# iCloud syncing for game data

**Status: wired.** "Import once, play everywhere" — after you import your EV
Nova data on one device, NOVA Swift can back it up to your own private iCloud
and restore it automatically on your other devices, so you don't have to
re-run the Data Setup wizard (or the [tvOS web importer](TVOS.md)) on every
Mac, iPad, iPhone, and Apple TV you own.

This syncs the **base game data** you imported (your `.ndat`/`.rez`, sound,
fonts, etc.) — not pilot saves, which are a separate system
(`PilotArchive`/`PilotRoster`, see [STATUS.md](STATUS.md)).

## How it works

`GameDataCloudSync.swift` talks to a single CloudKit container
(`iCloud.com.houseofkac.novaswift`), using **only the player's private
database** — never the public one, and never shared with anyone else,
including us. It's the same act as the player dropping the files into their
own iCloud Drive.

- **Upload** — after any successful import (and cheaply re-checked on every
  launch), the imported data set is zipped and saved as a `CKAsset` on one
  well-known record (`GameDataArchive` / `base-game-data`). A SHA-256
  fingerprint over relative paths and file sizes (`GameDataArchiver`) means
  this is a no-op unless the local data actually changed — no needless
  re-uploads.
- **Restore** — a device with no local data checks for that record and offers
  to restore it. **tvOS restores automatically** with no prompt, since it
  doubles as tvOS's self-heal path when the system purges its caches-only
  sandbox (see [TVOS.md](TVOS.md)).
- **Failure handling** — sync problems (offline, not signed into iCloud,
  quota exceeded) are surfaced as a friendly, non-fatal status message; local
  play and every other import path keep working regardless. Sync is a
  convenience layer, never a requirement.

## Where it lives

| Piece | File |
|---|---|
| Upload / restore / status | `app/NovaSwift/Data/GameDataCloudSync.swift` |
| Zip/unzip + fingerprint utility (shared with the web importer) | `Sources/NovaSwiftPluginStore/GameDataArchiver.swift` |
| iCloud/CloudKit entitlements | `app/NovaSwift/NovaSwift.entitlements`, `NovaSwift-tvOS.entitlements` |

## Before a release build can use this

The CloudKit schema for the `GameDataArchive` record type is currently only
registered in the **Development** environment (CloudKit learns it
automatically the first time a Development build saves a record). It must be
promoted to **Production** in the CloudKit Dashboard before a TestFlight/App
Store build can rely on sync working — the exact same one-time step the
multiplayer lobby's record types need (see
[MULTIPLAYER.md](MULTIPLAYER.md)).

## What's left

- CloudKit Production schema promotion (see above) — blocks this from working
  outside Development builds.
- No UI yet for a player to see straightforward "synced ✓" / "last synced
  <date>" status outside error states — `GameDataCloudSync.remote` already has
  the data, it just isn't surfaced everywhere it could be.
- No conflict handling beyond "newest upload wins" (deliberate — a player has
  exactly one base data set) — this isn't meant to reconcile *different*
  imports from two devices at once, only to carry one data set between them.
