# Yapshot: notes for coding agents

The product is Yapshot (repo baney75/yapshot), formerly Shotate (renamed in this release) and
Snapmark before that (renamed in 0.12.0). The bundle ID `com.baney.snapmark`, the local folders
`~/Projects/snapmark` and `~/Projects/shotate`, the Swift targets and folders `ShotateCore` and
`Shotate`, the `shotate` command alias and a few internal identifiers keep the old names only as
code. Never call the app Snapmark or Shotate in prose, PRs or commits.

## Checks

- macOS: `cd macos && swift build && swift test`; `make install` puts the build in ~/Applications.
- Windows/Linux app: `cd desktop && npx tsc --noEmit && npm test`.
- CI runs both on every PR.

## Releasing

1. In a PR, bump `VERSION`, `desktop/package.json`, `desktop/package-lock.json` (its top two
   `version` fields), `desktop/src-tauri/Cargo.toml` and the app's entry in `Cargo.lock`, and turn
   `## Unreleased` in CHANGELOG.md into `## X.Y.Z (YYYY-MM-DD)`, one section per heading.
2. After it merges, tag the merge commit and push the tag: `git tag -a vX.Y.Z <sha> -m "Yapshot X.Y.Z"`
   then `git push origin vX.Y.Z`. release.yml makes a draft from that changelog section, builds, and
   publishes it as Latest. Stable is macOS only; Windows and Linux follow Nightly.
3. Read back `releases/latest/download/manifest.json`: channel `stable`, the new version, the tag's commit.

Nightly rebuilds itself from main at 06:17 UTC; `gh workflow run nightly.yml -f force=true` rebuilds it now.

## Anything the user sees on screen

Tests and CI prove the logic only. For a capture, cursor, panel, shortcut or paste change, do the
user's exact gesture live on the installed build (through Cua) and read the result back before
calling it fixed. If the person is using the Mac, don't send keys to the front app: a stray Return
can run a command in their terminal. Ask them to try it, and say "untested live" until then.
`screencapture -C` doesn't reliably draw the pointer over Yapshot's overlay; don't use it as proof.

## Permissions

Setup (Welcome.swift) states, for each macOS permission, what it's for, what Yapshot never does
with it, and its live status. Keep every sentence there true: before changing a claim, grep the
sources (`AXUIElement`, event taps, `SCStream`, `URLSession`) to confirm it. A new permission or
network call gets its own plain line in setup before it ships.

## Regressions

- **2026-10-13, ⌘V paste chooser (PR #15).** Merged on green tests; Donovan found it didn't work.
  The option was off in his config, screenshots taken before turning it on were never remembered,
  and an `NSMenu` popped up from a background app looked unfinished and wasn't reliable at taking
  keys. Fixed in PR #16: recent screenshots are always remembered, and the chooser is a
  nonactivating key panel like the capture overlay. Live check: turn the option on, take two
  captures, press ⌘V in a text field, see the panel, press 2, and the second screenshot pastes;
  again, and click a card instead. Follow-up from Donovan: a click on a card must paste (the panel
  accepts the first click) into the field you were typing in (the paste goes to the app ⌘V was
  pressed in), it only applies to screenshots within 3 seconds of each other, the choice clears
  after a minute, and a switch in the panel and the menu bar turns it off.
- **2026-10-14, tool letters after a capture.** After ⇧⌘S and a drag, macOS kept the previous app
  active (`NSApp.activate` was declined), so editor letters went to that app. Opening an image from
  Finder activates normally, so the bug hid there. The editor is now a nonactivating panel. Live
  check: with another app in front, press the capture shortcut, drag a region, press A without
  clicking, and the Arrow tool is selected.
