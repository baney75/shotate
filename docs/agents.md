# Yapshot for coding agents

The `yapshot` command lets a coding agent (or a script) take screenshots, record the screen,
annotate images for docs and export GIFs and MP4s, all through the running Yapshot app, which
holds the Screen Recording permission. Every command prints one JSON object; failures print
`{"error": "..."}` and exit 1.

## Turn it on

1. Install from source (`cd macos && make install`). This links `~/.local/bin/yapshot` (and
   `shotate`, the old name, which still works the same) and puts
   the `yapshot` skill in `~/.claude/skills`, `~/.codex/skills` and `~/.agents/skills` where those
   folders exist. Anything already there that isn't Yapshot's link is left alone.
2. In the menu bar icon's menu, turn on **Let Agents Control Yapshot** (or set
   `"agentControl": true` in `~/.config/yapshot/config.json`).
3. `yapshot status` should show `"agentControl": true` and `"screenRecording": true`.

`status` works with agent control off; everything else is refused.

## Commands

```sh
yapshot status
yapshot windows                                   # id, pid, app, bundleID, title, frame
yapshot capture window --app Safari --out ~/shots/safari.png
yapshot capture area --rect 100,120,800,500       # points, top-left origin, like Cua
yapshot capture screen --copy                     # --copy also puts it on the clipboard
yapshot record app --app "T3 Code" --for 20       # records 20 s and prints what it saved
yapshot record area --rect 0,0,1440,900           # returns at once...
yapshot stop                                      # ...stop waits until the file is saved
yapshot stop --any                                # also stops a recording the user started
yapshot open ~/shots/safari.png                   # opens the editor
yapshot annotate in.png out.png --marks marks.json
yapshot export rec.mp4 --gif --width 960 --fps 15 --from 2 --to 14
yapshot export rec.mp4 --mp4 --width 1920
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
  first and last frames, and up to 6 more, one 0.6 s after each click, skipped when it would land within 0.8 s of an earlier still, so a click within 0.8 s of the previous click with a still, or in the first half second, gets none; with no clicks, a few evenly spaced ones), `system.log`,
  `app-logs/` and `debug.md`.

`--out` must name something that isn't there yet: Yapshot never records over an existing file or
folder. `stop` ends only a recording an agent started unless you pass `--any`. If a recording
ends before an agent's `stop` (it failed, or the user stopped it), the next `stop` returns how it
ended, and `status` shows it as `lastRecording`.

A reply with both `video` and `warning` is a partial save: saving ran past 90 s, so Yapshot handed
over the video and folder as they were, and the stills and `debug.md` may still appear in the folder.
It exits 0. A reply with `video` and `error` kept what was written, but the recording failed (for
example, the video may be incomplete), and it exits 1.

`clicks.json` lists each mouse click while recording: `t` in seconds from the first frame, `x` and
`y` in video pixels from the top left. Only mouse buttons are noted, never keys.

A recording an agent starts doesn't touch the clipboard. ⇧⌘D copies `debug.md`.

## MCP server

`yapshot mcp` is an MCP server (Model Context Protocol, JSON-RPC over stdin and stdout, protocol
2025-06-18) for Claude Code, Codex, Cursor and Claude Desktop. It is local only: the agent starts
it as a child process on this Mac, and it opens no port and makes no network request.

```sh
yapshot mcp install                     # every client below
yapshot mcp install --client cursor     # or claude, codex, claude-desktop
yapshot mcp uninstall                   # takes the yapshot entry out again
```

| Client | What install does |
| --- | --- |
| Claude Code | Runs `claude mcp add --scope user yapshot -- <yapshot> mcp` when `claude` is on PATH |
| Codex | Adds `[mcp_servers.yapshot]` to `~/.codex/config.toml` |
| Cursor | Adds `mcpServers.yapshot` to `~/.cursor/mcp.json` |
| Claude Desktop | Adds `mcpServers.yapshot` to `~/Library/Application Support/Claude/claude_desktop_config.json` |

It touches only the `yapshot` entry, leaves one that is already there alone, replaces a `shotate`
entry (the old name) that runs this app's command, copies each file to
`<file>.yapshot-backup-<time>` before editing it, and prints what it did. **Connect to AI
Agents…** in Settings › Advanced does the same. Restart an open agent to pick it up.

| Tool | Arguments | Does |
| --- | --- | --- |
| `send_script` | `title`, `text` | Saves `<voice folder>/Scripts/<title>.md` and opens it in the teleprompter. Works with agent control off. If Yapshot isn't running, it saves and says so |
| `list_scripts` | | Name, modified date and word count of each script |
| `read_script` | `name` | The script's text |
| `delete_script` | `name` | Deletes it. Only a plain name in the Scripts folder: `../x` or `a/b` is refused |
| `list_voice_notes` | `limit` (20) | Newest first: name, file, path, date, duration, and `script` when read from one |
| `status` | | Running, agent control, voice and scripts folders |
| `capture` | `target` (screen, window, area, app), `app`, `window`, `title`, `rect`, `out` | A screenshot, as `yapshot capture` does. Needs agent control |

Voice notes and scripts are read from the folder directly, so those tools work without the app.
The teleprompter scrolls while a voice note records; when that note is saved, Yapshot writes the
script's name in its sidecar (`.meta/<file>.json`, `"script"`).

## How it works

`yapshot` is `Yapshot.app/Contents/MacOS/Yapshot --cli`. It posts a distributed notification with
the request, and the app writes its answer to
`~/Library/Application Support/Yapshot/agent/<id>.json`. Web pages can open `yapshot://` links but
can't post these notifications, which is why the agent commands aren't URLs. Any program running as
you can, though. Agent control being off by default stops accidental use; it doesn't stop a hostile
program running as you, which could also turn the setting on in the config file. The recording bar
always shows while a recording runs.
