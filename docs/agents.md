# Shotate for coding agents

The `shotate` command lets a coding agent (or a script) take screenshots, record the screen,
annotate images for docs and export GIFs and MP4s, all through the running Shotate app, which
holds the Screen Recording permission. Every command prints one JSON object; failures print
`{"error": "..."}` and exit 1.

## Turn it on

1. Install from source (`cd macos && make install`). This links `~/.local/bin/shotate` and puts
   the `shotate` skill in `~/.claude/skills`, `~/.codex/skills` and `~/.agents/skills` where those
   folders exist. Anything already there that isn't Shotate's link is left alone.
2. In the menu bar icon's menu, turn on **Let Agents Control Shotate** (or set
   `"agentControl": true` in `~/.config/shotate/config.json`).
3. `shotate status` should show `"agentControl": true` and `"screenRecording": true`.

`status` works with agent control off; everything else is refused.

## Commands

```sh
shotate status
shotate windows                                   # id, pid, app, bundleID, title, frame
shotate capture window --app Safari --out ~/shots/safari.png
shotate capture area --rect 100,120,800,500       # points, top-left origin, like Cua
shotate capture screen --copy                     # --copy also puts it on the clipboard
shotate record app --app "T3 Code" --for 20       # records 20 s and prints what it saved
shotate record area --rect 0,0,1440,900           # returns at once...
shotate stop                                      # ...stop waits until the file is saved
shotate stop --any                                # also stops a recording the user started
shotate open ~/shots/safari.png                   # opens the editor
shotate annotate in.png out.png --marks marks.json
shotate export rec.mp4 --gif --width 960 --fps 15 --from 2 --to 14
shotate export rec.mp4 --mp4 --width 1920
```

`export` needs ffmpeg (`brew install ffmpeg`). `annotate` and `export` run without the app.

### Annotation marks

Image pixels, origin at the top left:

```json
[{"tool": "box", "rect": [40, 60, 300, 120], "color": "red"},
 {"tool": "arrow", "from": [520, 420], "to": [350, 150], "text": "Click Deploy"},
 {"tool": "step", "at": [360, 90]},
 {"tool": "text", "at": [40, 240], "text": "Then wait for the build", "width": 280},
 {"tool": "redact", "rect": [600, 20, 180, 30]}]
```

Tools: arrow, box, ellipse, highlight, redact, text, step, pen (`points`). Colors: red, amber,
blue, green, purple, white. Sizes: thin, medium, thick.

## What a recording saves

- `screen` and `area`: `<name>.mp4` and `<name>.clicks.json`.
- `app` (and ⇧⌘D): a folder `<name>/` with `<name>.mp4`, `<name>.clicks.json`, `stills/` (the
  first and last frames, and up to 6 more after clicks, or a few evenly spaced ones when there were none; a click within 0.8 s of an earlier still gets none), `system.log`,
  `app-logs/` and `debug.md`.

`--out` must name something that isn't there yet: Shotate never records over an existing file or
folder. `stop` ends only a recording an agent started unless you pass `--any`. If a recording
ends before an agent's `stop` (it failed, or the user stopped it), the next `stop` returns how it
ended, and `status` shows it as `lastRecording`.

A reply with both `video` and `warning` is a partial save: the video is there, but the stills and
`debug.md` ran late and may still appear in the folder.

`clicks.json` lists each mouse click while recording: `t` in seconds from the first frame, `x` and
`y` in video pixels from the top left. Only mouse buttons are noted, never keys.

A recording an agent starts doesn't touch the clipboard. ⇧⌘D copies `debug.md`.

## How it works

`shotate` is `Shotate.app/Contents/MacOS/Shotate --cli`. It posts a distributed notification with
the request, and the app writes its answer to
`~/Library/Application Support/Shotate/agent/<id>.json`. Web pages can open `shotate://` links but
can't post these notifications, which is why the agent commands aren't URLs. Any program running as
you can, though. Agent control being off by default stops accidental use; it doesn't stop a hostile
program running as you, which could also turn the setting on in the config file. The recording bar
always shows while a recording runs.
