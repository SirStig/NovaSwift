# Auto-updater (Godot desktop: Linux x86_64 incl. Steam Deck, Windows x86_64)

Code: `godot/updater/`. Release tooling: `scripts/release-sign.sh`. Self-check: `godot/tests/updater_selfcheck.gd`.

Releases are made by hand on GitHub (`SirStig/NovaSwift`); there is no CI. The Apple app is not touched by any of this.

**Status (2026-10-14).** Signed manifests (`update.json` + `update.json.sig`) are published with GitHub releases, starting with v0.7.0-beta.2. An end-to-end in-app update (an installed build offered, downloaded and installed a newer release) has not yet been verified.

## What the player sees

1. The main menu opens. At most once per 24 h (`updates/last_check`), and only if **Settings > Support > Updates >
   Check for updates** (or the original Preferences window's "Check For Updates") is on, the game asks
   `https://api.github.com/repos/SirStig/NovaSwift/releases` for the newest `vX.Y.Z[-pre]` release.
2. If one is newer than `config/version` (semver; never a downgrade except Return to stable; experimental releases only with **Experimental updates**;
   a release must carry `update.json` + `update.json.sig`; a version the player skipped stays quiet) a dialog appears over the
   menu (Nova Swift kit; Classic-styled in Classic mode; pad-operable): version, scrollable release notes,
   **Skip This Version / Later / Update Now**. Nothing is downloaded before **Update Now**.
3. Update Now: download the signed manifest, verify it, download the platform archive with a progress bar and Cancel,
   verify size + SHA-256, unpack, then the game restarts into the installer and comes back as the new version.
4. Offline, GitHub rate limits (403), 5xx and malformed JSON are silent for the automatic check (retry >= 1 h later,
   else next day). **Check Now** always answers (up to date / offer / the error).
5. Where installing cannot work -- macOS, a read-only install folder, Flatpak / AppImage / Snap, a Steam-managed copy --
   the prompt offers **Open Download Page** instead.

## Channels: stable and experimental

* Settings > Support > Updates > **Experimental updates** (pref `updates/beta`, key kept from the old "Include beta versions"; default
  off) also offers test builds that "may be unstable or break saves". Prompts for them carry a red "Experimental build - may be
  unstable" badge in both the Classic and Nova Swift styles; stable prompts do not.
* A release is experimental if GitHub's **pre-release** flag is set OR its tag has a semver suffix (`v1.3.0-experimental.1`,
  `-beta.2`, `-rc.1`). The signed `update.json` may also carry `"channel": "stable" | "experimental"`; once verified it
  **wins** over the flag and the tag, so editing the GitHub release cannot relabel a build. The game verifies the manifest
  before showing the prompt, and refuses an experimental manifest when Experimental updates is off.
* **Labelling a release:** `scripts/release-sign.sh --version 1.3.0-experimental.1` signs `channel: experimental`
  (the default whenever the version has a suffix; stable otherwise). Override with `--channel experimental|stable`. Also tick
  "Set as a pre-release" on GitHub (the game treats the flag as experimental when the manifest names no channel). To make a
  plain-numbered build experimental, use `--channel experimental` (then the tag must still be newer than stable users' version).
* **Return to stable:** if Experimental updates is turned off while running an experimental build (a pre-release version, or one
  installed from an experimental manifest), the next check offers "Return to stable X.Y.Z" = the newest stable release, labelled
  as going back, with a warning that saves from the newer build may not load. It is the only downgrade the updater ever
  performs, only on explicit choice ("Return to Stable"; "Stay on This Build" declines), and the target's signed channel must be
  stable. A stable release newer than the running build is a normal update instead.

## Trust model (threat model)

* The transport is HTTPS to `api.github.com`, `github.com`, `objects.githubusercontent.com`,
  `release-assets.githubusercontent.com` or `github-releases.githubusercontent.com` only. Redirects are followed by hand
  and every hop is re-checked (https, port 443, allow-listed host, no userinfo).
* **Transport is not trusted for integrity.** Every installable release has `update.json` (the manifest) and
  `update.json.sig` (raw RSA PKCS#1 v1.5 / SHA-256 signature of the exact manifest bytes). The game embeds the RSA public
  key (`godot/updater/update_pubkey.pem` and its `UpdatePubKey.gd` mirror, which is what actually ships in the .pck) and
  verifies with `Crypto.verify` BEFORE reading anything from the manifest. The manifest then carries each platform archive's
  exact name, size and SHA-256; the download is rejected unless all three match. Archive contents are only extracted after
  that. A compromised GitHub account / release without the private key can therefore not push code; it can only withhold
  updates or offer a replayed older signed manifest -- which is refused because the signed `version` must equal the release
  tag and be newer than the running version.
* The private key lives only at `~/.config/novaswift/update_signing_key.pem` (mode 600). Losing it means a game build with
  a new public key must be distributed by hand once; leaking it means the same. Back it up offline.
* A build with the placeholder public key is an **unsigned build**: it never checks for or installs updates.
* Archives are screened for path traversal (`..`, absolute, drive, backslash paths) on top of tar's own protections.
* Not covered: a compromised developer machine, and an attacker who can already write to the install folder.

## Install: updater mode

The game cannot overwrite its own running executable, so the same binary doubles as the installer.

1. Staging: the archive is unpacked to `<install>/.update_new` (same filesystem as the swap, which also proves the folder is
   writable). Required files from the signed manifest (`launcher`, `required`) must exist and be non-empty.
2. Hand-off: the game copies its own executable and `.pck` to `user://update/run/` and starts that copy as
   `<copy> -- --updater --install-dir D --staging S --pid P --relaunch LAUNCHER --from V --to V`, then quits.
   `Main.gd` checks `UpdaterMode.requested()` first thing and shows only `UpdaterScene` (plain Controls): no `NovaWorld`, no
   bridge class, nothing from the GDExtension is touched. The libraries are not beside the copy, so the engine logs a
   failed extension load there, which is non-fatal.
3. The updater waits for `P` to exit (30 s), then swaps **file by file**: every file the package contains that already exists
   is moved to `<install>/.update_bak/<path>`, the new files are moved in (rename; copy + delete across filesystems;
   retried on Windows for locks), exec bits are kept. A journal (`.update_bak/journal.json`) lists both sets. Any failure rolls
   everything back exactly (also automatically at the next updater run if the machine died mid-swap).
   Files in the install folder that the new package does not ship are left alone; `data`, `Pilots`, `plugins`, `user` and
   `portable.txt` are never touched. (Pilots live in the Pilots folder / `user://`, prefs in `user://settings.cfg`, game data in
   `~/.local/share/NovaSwift/data` -- none inside the install folder.) The folder-rename approach was rejected: it needs a
   writable parent and breaks when a launcher, indexer or antivirus holds the folder.
4. The updater writes `user://update/state.json` (`installed` or `failed`) and starts the launcher (`NovaSwift.sh` on Linux,
   `NovaSwift.exe` on Windows) -- the old version after a failure. On Steam Deck Game Mode this is the same script Steam
   points at, started from a descendant of the original process.
5. The new game, once its main menu is up, reads the state: `installed` and `config/version == to` deletes `.update_bak`
   and says "NovaSwift updated"; `failed` shows the error and that the previous version was restored.

## Release steps (manual)

One time:

```
scripts/release-sign.sh --init        # private key -> ~/.config/novaswift/update_signing_key.pem (600), public key -> godot/updater/
# commit godot/updater/update_pubkey.pem + UpdatePubKey.gd, then build at least one release carrying them
```

Every release `X.Y.Z` (or `X.Y.Z-experimental.N`; tick "pre-release" on GitHub for experimental ones):

1. Set `config/version="X.Y.Z"` in `godot/project.godot` (pre-release builds carry the full `X.Y.Z-beta.N`), commit, tag `vX.Y.Z`.
2. Build the packages (`scripts/package-linux*.sh`, the Windows script). Names are free but must be file-name safe; the
   archives need `NovaSwift.sh` + `NovaSwift.x86_64` + `NovaSwift.pck` (Linux) or `NovaSwift.exe` + `NovaSwift.pck` (Windows),
   either at the top or inside ONE wrapper folder (`NovaSwift/`). Build tars on Linux or with `COPYFILE_DISABLE=1` (no `._*`).
3. Sign:
   ```
   scripts/release-sign.sh --version X.Y.Z \
     --asset linux-x86_64=godot/export/NovaSwift-linux-x86_64.tar.gz \
     --asset windows-x86_64=godot/export/NovaSwift-windows-x86_64.zip
   ```
   It checks the archives' layout, writes `update.json` + `update.json.sig` next to the first asset, and re-verifies the
   signature against the repo's public key (it refuses if the private key does not match it).
4. Create the GitHub release `vX.Y.Z` and attach: the archive(s), `update.json`, `update.json.sig`. Beta: mark pre-release.
5. A release without `update.json` + `.sig` is invisible to the updater (users get nothing, nobody gets a broken offer).
   To pull a bad release: delete or un-publish it (the previous one is then the newest); to supersede, publish a higher version.

Testing without touching users: publish `vX.Y.Z-experimental.N` (pre-release); only players with Experimental updates on see it.

## Recovery

* Update failed: nothing to do -- the old version is restored and the next start explains why.
* Half-installed (power cut during the swap): run `NovaSwift.sh` again if it starts; otherwise the old files are in
  `<install>/.update_bak/` (same relative paths) with `journal.json`; the next updater run rolls back automatically, or copy
  them back by hand. Re-download from the releases page as a last resort -- pilots and settings are outside the install folder.
* Stale `.update_new` / `user://update/` leftovers are removed on the next start.
* To stop all update traffic: Settings > Support > Updates > Check for updates off.

## Files

| File | Role |
|---|---|
| `Semver.gd` | parse / compare (semver 2.0) |
| `UpdateConfig.gd` | repo, host allow-list, platform key, public key, "can check / can install" probes |
| `UpdateChecker.gd` | pick the release to offer from the API JSON; release-notes cleanup |
| `UpdateManifest.gd` | manifest parse / validation, signature verify, size + sha256 check |
| `UpdateHttp.gd` | HTTPS transport: manual redirects, resume, stall watchdog, cancel |
| `UpdateInstall.gd` | extract, payload validation, swap / rollback / recovery, state note |
| `UpdateController.gd` | schedule, dialogs, download pipeline (owned by `Shell`, group `nova_updater`) |
| `UpdaterMode.gd` / `UpdaterScene.gd` | updater-mode args, hand-off, the installer window |
| `update_pubkey.pem` / `UpdatePubKey.gd` | public key (placeholder until `--init`) |
