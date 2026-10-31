#!/usr/bin/env python3
"""Turn a Shotate click timeline (<video>.clicks.json) into turn-NNNNN/action.json folders.

The app-demo-video skill's zoom_from_clicks.py reads Cua recording turns; this lets it zoom a
Shotate recording to every click too. Points are already video pixels, so run the zoom with
--scale 1 --window-origin 0,0 --offset <printed offset>.

    python3 clicks_to_turns.py "Rec.clicks.json" /tmp/turns
"""
import json
import sys
from datetime import datetime, timedelta, timezone
from pathlib import Path


def main(argv):
    if len(argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    data = json.loads(Path(argv[0]).read_text())
    clicks = data.get("clicks") or []
    if not clicks:
        print("no clicks in " + argv[0], file=sys.stderr)
        return 1
    out = Path(argv[1])
    out.mkdir(parents=True, exist_ok=True)
    base = datetime(2000, 1, 1, tzinfo=timezone.utc)
    tools = {"left": "click", "right": "right_click", "other": "click"}
    for i, c in enumerate(clicks, 1):
        tool = "double_click" if c.get("count", 1) >= 2 and c.get("button") == "left" else tools.get(c.get("button"), "click")
        turn = out / f"turn-{i:05d}"
        turn.mkdir(exist_ok=True)
        stamp = (base + timedelta(seconds=float(c["t"]))).isoformat()
        (turn / "action.json").write_text(json.dumps({"timestamp": stamp, "tool": tool, "x": c["x"], "y": c["y"]}))
    print(json.dumps({"turns": str(out), "clicks": len(clicks), "offset": clicks[0]["t"], "size": data.get("size")}))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
