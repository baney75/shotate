# Shotate: notes for coding agents

## Checks

- macOS: `cd macos && swift build && swift test`; `make install` puts the build in ~/Applications.
- Windows/Linux app: `cd desktop && npx tsc --noEmit && npm test`.
- CI runs both on every PR.

## Anything the user sees on screen

Tests and CI prove the logic only. For a capture, cursor, panel, shortcut or paste change, do the
user's exact gesture live on the installed build (through Cua) and read the result back before
calling it fixed. If the person is using the Mac, don't send keys to the front app: a stray Return
can run a command in their terminal. Ask them to try it, and say "untested live" until then.
`screencapture -C` doesn't reliably draw the pointer over Shotate's overlay; don't use it as proof.

## Permissions

Setup (Welcome.swift) states, for each macOS permission, what it's for, what Shotate never does
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
