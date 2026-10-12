# Shotate updates: stable and nightly channels

## Channels
- **Stable**: GitHub releases tagged `vX.Y.Z` (not prerelease). Created by `.github/workflows/release.yml` on tag push.
- **Nightly**: one rolling prerelease tagged `nightly`, rebuilt by `.github/workflows/nightly.yml` from `main` only, daily (06:17 UTC) when `main` has commits newer than the current nightly, and on manual dispatch. The app's version is `X.Y.(Z+1)+nightly.YYYYMMDDHHMM` where X.Y.Z is `VERSION`; installers carry the plain `X.Y.(Z+1)` inside (npm drops build metadata), so Linux package installs use `--reinstall`/`--replacepkgs`, and their file names carry `X.Y.(Z+1)-nightly.YYYYMMDDHHMM` so each night's files are distinct. MSI is skipped for nightly. The previous nightly stays downloadable while a new one builds: installers are uploaded alongside the old ones under new names, the manifest is uploaded last, then the tag moves and leftover files are removed.

## Manifest (the only thing clients fetch to check)
Every release (stable and nightly) has an asset `manifest.json`, written by the last CI job after all installers are uploaded:

```json
{
  "channel": "stable",
  "version": "0.12.0",
  "commit": "<40-hex sha the release was built from>",
  "date": "2026-10-11T18:00:00Z",
  "notes": "https://github.com/baney75/shotate/releases/tag/v0.12.0",
  "assets": {
    "windows-x64": {"name": "Shotate_0.12.0_x64-setup.exe", "url": "https://github.com/...", "sha256": "..."},
    "linux-x64-deb": {...}, "linux-arm64-deb": {...},
    "linux-x64-rpm": {...}, "linux-arm64-rpm": {...},
    "linux-x64-appimage": {...}, "linux-arm64-appimage": {...}
  }
}
```

Fetch URLs (no GitHub API, so no rate limit):
- stable: `https://github.com/baney75/shotate/releases/latest/download/manifest.json`
- nightly: `https://github.com/baney75/shotate/releases/download/nightly/manifest.json`

## What a build knows about itself
- `version` (VERSION / package.json; nightly CI rewrites it), `commit` (git sha), `channel` ("stable" if built from a `v*` tag matching VERSION, else "nightly"), `date` (build time, ISO 8601 UTC).
- macOS: `bundle.sh` writes `ShotateCommit`, `ShotateChannel`, `ShotateBuildDate` into Info.plist. Desktop: compile-time env (`SHOTATE_COMMIT`, `SHOTATE_CHANNEL`, `SHOTATE_BUILD_DATE`) set by build.rs from git / CI.

## Config (shared format, both apps)
- `"updateChannel": "stable" | "nightly"`. When the key is absent, default to the build's own channel.
- `"checkForUpdates": true` (default true). False means no network request at all.

## Decision rule (identical in both apps, unit-tested)
`offer(local, remote, channel)`:
- Ignore a manifest whose `channel` differs from the selected channel.
- If `remote.commit == local.commit`: no update.
- Stable selected: offer if `semver(remote.version) > semver(local.version)`, or if local.channel is "nightly" (label it "Switch to Stable X.Y.Z").
- Nightly selected: offer if `remote.date > local.date` (a newer stable you installed after the last nightly is not downgraded).
- Semver: compare numeric X.Y.Z and prerelease per semver; build metadata (`+nightly…`) is ignored, since nightlies compare by date.

## When to check
On launch (after ~10 s) and every 24 h while running, if `checkForUpdates`; always on "Check Now". One HTTPS GET to github.com, no identifiers, no cookies. Failures are silent for automatic checks and shown for manual ones.

## How an update installs (same route the app was installed by)
- **macOS** (built from source so Screen Recording stays granted): needs the command line tools (`xcode-select -p`). Validate the manifest's version, commit and channel, fetch the release's commit (stable: tag `vX.Y.Z`; nightly: the manifest's commit) into a temp dir, then run `macos/scripts/bundle.sh --install` detached; the values reach the script as arguments, and any failure opens `shotate://update-failed?token=…` with a per-install token (`nohup`, own session), logging to `~/Library/Logs/Shotate/update.log`. `bundle.sh --install` quits the running app by bundle ID, installs and relaunches. If the tools are missing, show the one-line install command instead.
- **Windows**: download the setup .exe to temp, verify sha256, then run a fixed PowerShell script (by absolute path) that reads the setup and app paths from environment variables, waits for the silent install, relaunches Shotate and deletes the download.
- **Linux AppImage** (`$APPIMAGE` set): download next to it, verify sha256, chmod +x, atomically rename over `$APPIMAGE`, relaunch, quit.
- **Linux .deb/.rpm** (exe under /usr): download, verify, run `/usr/bin/pkexec /usr/bin/apt-get install -y --reinstall --allow-downgrades <file.deb>` or `/usr/bin/pkexec /usr/bin/rpm -U --oldpackage --replacepkgs <file.rpm>` (switching to Stable can be a downgrade), then relaunch and quit. Without pkexec, open the release page.

## UI (both apps)
- Settings › General › **Updates**: channel picker (Stable, recommended / Nightly, built every day from the newest code, may have rough edges), "Check for updates automatically" checkbox, **Check Now** button, a status line ("Shotate 0.12.0 is up to date. Checked 3 minutes ago." / "Shotate 0.12.1 is available." + **Install Update** + "What's new" link).
- Menu bar / tray menu: **Check for Updates…** always; when an update is known, **Update to Shotate 0.12.1…** near the top.
- Manual check result or menu click: a dialog with version, "What's new" link, **Install Update** / **Later**.
- About shows version, channel and short commit.

## Installers
- `install.sh`: `SHOTATE_CHANNEL=nightly` (or `bash -s -- --nightly`) picks nightly. macOS stable clones the latest `v*` tag (from the `releases/latest` redirect), nightly clones `main`. Linux stable uses `releases/latest`, nightly uses `releases/tags/nightly`.
- `install.ps1`: `$env:SHOTATE_CHANNEL = "nightly"` before running.
- Re-running the installer is always a valid update.
