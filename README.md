<p align="center">
  <img src="docs/banner.png" alt="Snapmark: screenshot, mark it up, paste" width="100%">
</p>

<p align="center">
  <a href="https://github.com/baney75/snapmark/actions/workflows/ci.yml"><img src="https://github.com/baney75/snapmark/actions/workflows/ci.yml/badge.svg" alt="CI"></a>
  <a href="https://github.com/baney75/snapmark/releases/latest"><img src="https://img.shields.io/github/v/release/baney75/snapmark?color=e8434a" alt="Latest release"></a>
  <img src="https://img.shields.io/badge/macOS-13%2B-1f2937" alt="macOS 13 or later">
  <img src="https://img.shields.io/badge/Swift-native-f05138" alt="Native Swift">
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-3b82f6" alt="MIT license"></a>
</p>

<p align="center">
  <b>A fast, free screenshot tool for macOS with the annotation tools you actually use.</b><br>
  No account, no upsell, no network code. It lives in your menu bar and stays out of the way.
</p>

<p align="center">
  <img src="docs/editor.png" alt="The Snapmark editor with an arrow, a text label, a box, a redaction and numbered steps" width="860">
</p>

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/baney75/snapmark/main/install.sh | bash
```

That's the whole setup. The installer builds Snapmark from source with Apple's free command line
tools, puts it in `~/Applications`, and opens a short welcome window that walks you through the one
permission it needs. Because it's built on your Mac, there is no "unidentified developer" warning.

Requires macOS 13 Ventura or later, on Apple silicon or Intel.

## How it works

1. **Press ⇧⌘S** and drag over anything. Press Space while dragging to grab a whole window instead.
2. **Mark it up.** Arrows, boxes, highlights, text, numbered steps, crop and redaction.
3. **Press Return.** The image is on your clipboard, ready to paste into Slack, Mail, a pull request
   or a terminal, and a copy is saved to `~/Pictures/Screenshots`.

Captures are saved and copied the moment you take them, so closing the editor never loses anything.

## Features

| | |
| --- | --- |
| **Capture** | Area, window or full screen from a global shortcut, the menu bar, or `snapmark://` URLs |
| **Annotate** | Arrow, box, ellipse, highlight, text label, numbered step, crop |
| **Redact for real** | Redaction draws a solid bar. Blur and pixelation can sometimes be reversed; this can't |
| **Edit like a canvas** | New marks are selected as you draw them. Drag handles to resize, Delete to remove, ⌘D to duplicate, arrow keys to nudge, right-click for more |
| **Paste anywhere** | The clipboard gets PNG, TIFF and the file, so chat apps, documents, Finder and terminal tools such as Claude Code all accept it |
| **Safe with your files** | An image you open is never overwritten. Edits go to `name (edited).png` beside it |
| **Retina-correct** | Captures keep their real size when pasted, instead of doubling |
| **Menu bar only** | No Dock icon, no windows until you need one |
| **Private** | No network code, no analytics, no account. Your screenshots never leave your Mac |

## Keyboard

| Key | Tool | | Key | Action |
| --- | --- | --- | --- | --- |
| V | Select and move | | Return | Copy and close |
| A | Arrow (Shift snaps to 45°) | | Esc | Deselect, then close |
| R | Box (Shift for a square) | | Delete | Delete the selected mark |
| O | Ellipse | | ⌘D | Duplicate the selected mark |
| H | Highlight | | Arrow keys | Nudge (Shift: 10 points) |
| T | Text label | | ⌘] / ⌘[ | Bring to front / send to back |
| B | Redact | | ⌘Z / ⇧⌘Z | Undo / redo |
| N | Numbered step | | 1–6, [ ] | Color, smaller / larger |
| C | Crop | | ⇧⌘C | Copy the file path instead of the image |
| | | | ⌘S | Save a copy elsewhere |
| | | | ⌘⌫ | Move the capture to the Trash |

## Permissions

Snapmark needs exactly one permission, **Screen Recording**, and the welcome window asks for it with
one click. It needs nothing else: no Accessibility, no Input Monitoring. The global shortcut is
registered with `RegisterEventHotKey`, which macOS allows without extra permission.

macOS ties that permission to the app's code signature. Snapmark's installer creates a local signing
certificate the first time it runs, kept in its own keychain under
`~/Library/Application Support/Snapmark/Signing`. The certificate stays the same across updates, so
macOS remembers your choice. It is never added to your login keychain and is trusted for nothing else.

If captures ever come back blank, open the menu bar icon and choose **Allow Screen Recording…**.

## Settings

Menu bar icon › **Settings…** sets the save folder, the capture shortcut, clipboard behavior, the menu
bar icon and launch at login.

**Command shortcuts** let Snapmark's menu bar process own extra global shortcuts that run a shell
command, one per line:

```
cmd+shift+a = open -a Terminal
ctrl+option+n = ~/bin/new-note
```

Everything is scriptable:

```sh
open snapmark://capture            # area
open snapmark://capture/window
open snapmark://capture/screen
open "snapmark://open?path=$HOME/Desktop/shot.png"
open snapmark://settings
defaults write com.baney.snapmark captureShortcut "ctrl+shift+2"
```

## Uninstall

```sh
curl -fsSL https://raw.githubusercontent.com/baney75/snapmark/main/uninstall.sh | bash
```

This quits Snapmark and removes the app, its settings and its signing keychain. Your screenshots stay
where they are.

## Build from source

```sh
git clone https://github.com/baney75/snapmark.git && cd snapmark
make install      # build, sign, copy to ~/Applications, launch
make test         # unit tests for the drawing model and renderer
make selftest     # renders every annotation onto a sample image
```

The code is split in two. `Sources/SnapmarkCore` holds the document model, geometry and renderer,
with no windows, so it is fully unit-tested. `Sources/Snapmark` is the AppKit app. The live editor and
the exported PNG share one renderer, so what you see is exactly what gets copied.

## Contributing

Bug reports and pull requests are welcome. See [CONTRIBUTING.md](CONTRIBUTING.md). For security
issues, see [SECURITY.md](SECURITY.md).

## License

[MIT](LICENSE) © Donovan Baney
