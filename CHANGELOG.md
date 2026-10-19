# Changelog

## Unreleased

### Fixed
- Tool letters (V, A, P, R…) work right after a capture. macOS often left the app you were in
  active, so the letters went there instead of the editor.
- A tool key changed in Settings works in editors that are already open.
- Closing the last editor gives focus back to the app you were in. Shotate used to stay in
  front with no window, so your next keys went nowhere.

### Changed
- **Drawing past the edge looks like the screenshot goes on.** Text or a bar cut by the edge no
  longer smears across the new space. Where an edge has no clear background, such as a photo, the
  new space continues its colors softly, and corners match the edges that meet there.
- **Setup explains every permission.** A Permissions section says what Screen Recording (required)
  and Accessibility (optional, only for choosing what to paste) are used for, what Shotate never
  does with them, and whether each is allowed right now, with a button to allow it. It also says
  plainly that screenshots never leave your Mac and that Shotate only goes online on its own to check
  for updates, at launch and once a day. The capture shortcut can be changed right there too.
- The editor opens on Select instead of Arrow, so a click on a new screenshot never drops an
  arrow by accident. Press A for arrows.

### Added
- **Record the screen** (macOS 15 and later). ⇧⌘R records an area you drag (or press Space and
  click a window); ⌃⇧⌘R records the whole screen the pointer is on. A small bar shows the time and
  a Stop button, and a red outline marks a recorded area; neither shows up in the video. Press any
  record shortcut again or click Stop, and the MP4 is saved next to your screenshots, copied as a
  file, and shown in Finder. Quitting mid-recording saves it first. Video only, no sound.
- **Record an app and its log.** ⇧⌘D, then click a window: Shotate records only that app's windows
  and streams what it writes to the system log, debug messages included. When you stop, the log
  is on your clipboard as text and saved beside the video.
- **⌃⇧⌘S captures the full screen** in new setups.
- Two Shotate shortcuts set to the same keys now say so, instead of one silently not working, and a
  shortcut new in this version starts off if your config already uses its keys.
- Point at a tool to see its key; keep pointing for a second to see its name too.
- **Choose which screenshot to paste** (macOS, off by default). Turn it on in setup, Settings or
  the menu bar menu. Take screenshots within 3 seconds of each other and, for the next minute,
  ⌘V opens a panel of them, newest first and numbered; click one, press its number, or use the
  arrow keys and Return, and Shotate pastes it where you were typing. A switch in the panel
  turns it off. Anything else you copy pastes as
  usual. Shotate types the paste for you, so turning it on asks for Accessibility.
- The editor's drag-out button shows an open hand when you point at it, so it's clear the
  screenshot can be dragged into another app.
- The crosshair shows the moment a capture starts, instead of an arrow until the mouse moves.
- **Pen.** Press P and draw freehand. With a drawing tablet the line is thin where you press lightly
  and full where you press hard. Hold still at the end of a stroke and it becomes the line, box or
  ellipse you meant; a line's end keeps following the pen until you lift it.
- **Curved arrows.** A selected arrow has a third handle in its middle: drag it to bend the arrow,
  or drag it back to the line to straighten it. The curve keeps its shape when an attached end moves.
- **Arrow labels.** Double-click an arrow's end to type a label there; the arrow points at it and
  follows it when you move it. Double-click anywhere else along an arrow to label its middle; the
  label rides on the arrow, and clearing its text removes it.

### Fixed
- **Drawing past the edge looks like the screenshot carries on.** Lines, text and icons that touch
  the edge no longer streak across the new space; wide bands such as a title bar or a page background
  still continue. The editor also zooms out while you drag past the edge, so the mark stays in sight.

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
