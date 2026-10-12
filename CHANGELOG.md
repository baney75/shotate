# Changelog

## Unreleased

### Changed
- **Stable releases are macOS only for now**, because the Mac app is the one each release is tested
  on. Windows and Linux get preview builds from the nightly channel: their installers install it,
  and their app follows it. The 0.12.0 and 0.13.0 releases no longer list Windows or Linux
  installers. A Windows or Linux copy of 0.13.0 opens the release page when the next release comes
  out; run the install command once to move it to the preview.

## 0.13.0 (2026-10-11)

### Added
- **Updates, with a Stable and a Nightly channel.** Shotate checks GitHub once a day and offers
  **Update to Shotate x.y.z…** in its menu; one click installs it and restarts. Pick Stable (tested
  releases) or Nightly (built every day from the newest code) in Settings › General, check now, or
  turn checking off. The install commands take the channel too (`--nightly`). On macOS updates are
  built on your Mac, so the Screen Recording permission stays; on Windows and Linux the installer's
  SHA-256 is checked before it runs. The check downloads one small file and sends nothing about you.
- **Save to Downloads or Desktop.** Settings › General › Save captures to now offers Pictures ›
  Screenshots, Desktop, Downloads or any other folder.
- About shows the build's channel and commit.

## 0.12.0 (2026-10-11)

### Changed
- **Snapmark is now Shotate.** Many screenshot tools already share the old name. Shotate is
  screenshot and annotate in one word. It has a new icon, the red marker loop you'd draw around the
  thing that matters, and a new home at github.com/baney75/shotate (old links redirect).
  Updating keeps everything: the macOS Screen Recording permission, Open at login, your settings
  (copied from `~/.config/snapmark` to `~/.config/shotate`), your shortcuts and your screenshots.
  Installing Shotate, by any method, replaces the old Snapmark app so only one copy runs. `snapmark://` links still work on macOS, and on Linux a
  shortcut bound to `snapmark --capture` keeps working (the command is now `shotate --capture`).

### Added
- **Wrapping text.** Drag with the Text tool to set the width a label wraps at; drag a label's side
  handle to rewrap it. ⌥Return (Shift+Enter on Windows and Linux) starts a new line. Labels grow
  downward from their top-left corner.
- **Snapping.** Moving, drawing and resizing line marks up with the edges and centers of the image
  and of other marks, with guide lines. Hold ⌘ (Ctrl) to place freely.
- **Attached arrows.** An arrow end dropped on a mark stays attached when that mark moves or
  resizes, in the same undo step. Dragging the whole arrow detaches it.
- **Copy and paste style.** ⌥⌘C copies the selected mark's color and size, ⌥⌘V puts them on the
  selection and on new marks (Ctrl+Alt+C / Ctrl+Alt+V on Windows and Linux).

### Changed
- **Text is easier to place and size.** Click with the Text tool to start a label centered on the
  click. The typing field looks like the finished label and grows as you type, instead of a bar
  across the whole window. Drag a label (with Text or Select) to move it, click it to edit, and drag
  its corner handle to scale it to any size. The size buttons still set the presets.
- **Captures land instantly on macOS.** Shotate now captures with ScreenCaptureKit and its own
  area picker instead of macOS's screencapture tool, which took 0.4 to 3 seconds to write each
  capture. Area capture freezes the screen when you press the shortcut, so the editor opens as soon
  as you let go of the mouse. Drag for an area, press Space to switch to picking a window, and Esc or
  a right-click cancels. macOS 13 still uses screencapture.
- **Faster on macOS.** The editor opens about 0.6 s sooner after a 5K capture: Snapmark keeps
  screencapture's PNG instead of encoding the image twice more on the main thread, and Copy & Close
  copies the saved file instead of rendering and encoding again. Marks that aren't moving are drawn
  once and reused, so a drag redraws only what moves (a 40-mark frame drops from about 47 ms to
  7 ms), and labels are laid out once instead of on every pointer move and redraw.

### Fixed
- **Shadows in the editor match the saved image.** Arrow, label and step shadows were sized in
  screen points, so on a large capture the editor showed them several times bigger than the PNG.

## 0.11.0 (2026-10-10)

### Added
- **Windows and Linux.** A new Tauri app (Rust plus a TypeScript canvas editor) with the same tools,
  keys and behavior as the macOS app: area, window and full-screen capture from a full-screen picker,
  canvas-style editing, drawing past the edge, the stepped Esc, a tray icon, global shortcuts, launch
  at login, and the same `config.json` format, reloaded live.
- One-line installs: `install.sh` now also installs the `.deb`, `.rpm` or AppImage on Linux, and
  `install.ps1` installs on Windows without an administrator prompt.
- Releases ship a Windows installer (.exe and .msi), Linux packages for x64 and arm64 (.deb, .rpm,
  .AppImage), and the macOS zip.
- `snapmark --capture` and friends on Windows and Linux, for binding keys on Wayland.

### Changed
- The macOS app moved to `macos/`. The install command is unchanged.

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
- Draw past the edge: marks outside the screenshot grow the canvas, filled with the screenshot's
  border color (like Shottr).
- Esc steps back: from a drawing tool to Select, then clears the selection, then copies and closes.
- A standard macOS Settings window with General, Shortcuts, Commands and Advanced panes, click-to-record
  shortcuts, editor tool keys, one row per command shortcut, and instant apply.
- Relaunch that reliably comes back (LaunchServices starts the new copy) and reopens the welcome window.
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
