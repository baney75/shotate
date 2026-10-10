# Changelog

## 0.10.0 (2026-10-10)

### Fixed
- Captures and edits failed to save or copy ("No IDATs written"). The image was decoded lazily from a
  temporary file that Snapmark had already deleted. Images now load fully into memory.
- Save, copy and open errors are now shown instead of failing silently.
- The welcome window kept appearing after permission was granted: macOS had stored the grant for an
  older build's signature. **Allow…** now clears Snapmark's own stale entry and asks again, and the
  welcome window opens only on first launch or when a capture needs it.
- macOS asked for Screen Recording again after every update. Snapmark now signs itself with a stable
  local certificate, so the permission sticks.

### Added
- One plain config file, `~/.config/snapmark/config.json`, for people and agents alike. Snapmark
  reloads it the moment it changes. It holds shortcuts for area, window and full-screen capture,
  command shortcuts, and the editor's tool keys. Existing settings move into it automatically.
- About Snapmark, with credits to Donovan Baney (@baney75).
- A welcome window that sets up Screen Recording in one click, with live status and a relaunch button.
- Canvas-style editing: new marks are selected as you draw them, with resize handles, a hover outline,
  a Delete button, a right-click menu, ⌘D duplicate, ⌘[ / ⌘] ordering and arrow-key nudging.
- ⌘⌫ moves an unwanted capture to the Trash.
- A configurable capture shortcut in Settings.
- The clipboard now also offers TIFF for older apps.
- `uninstall.sh`, a release workflow, contributor docs and a new banner.

### Changed
- Snapmark stays in the menu bar only; it no longer shows a Dock icon while editing.
- Esc deselects the current mark before it closes the editor.
- A refreshed toolbar with stroke-size dots, a status line showing where the image was saved, and a
  Copy & Close button.

## 0.9.0 (2026-10-10)

First public release.

- Area, window and full-screen capture with ⇧⌘S and a menu bar menu
- Arrow, box, ellipse, highlight, text label, redact (solid bar), numbered step, crop
- Select, move, recolor, resize and delete marks; undo and redo
- Copy the image or its file path; drag out; save a copy
- Opened images are never overwritten; edits go to `name (edited).png`
- Retina captures keep their real size when pasted elsewhere
- Command shortcuts, `snapmark://` URLs, Finder Open With, launch at login
- Universal (Apple silicon and Intel), builds from source with one command
