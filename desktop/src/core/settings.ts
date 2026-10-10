// The config file format, shared with the macOS app: ~/.config/snapmark/config.json on Linux,
// %APPDATA%\snapmark\config.json on Windows. The Rust side owns reading, writing and watching it;
// this module holds the parts the editor needs.
import { TOOLS, type Tool } from "./model";

export interface Config {
  saveFolder: string;
  copyOnCapture: boolean;
  showMenuBarIcon: boolean;
  shortcuts: Record<"captureArea" | "captureWindow" | "captureScreen", string>;
  commands: Record<string, string>;
  toolKeys: Record<string, string>;
}

const isToolKey = (k: string) => /^[a-z]$/.test(k);

/**
 * Every tool's key, guaranteed unique so every tool stays reachable. A custom key is dropped (the
 * tool keeps its default) when it isn't a letter, when an earlier tool already claimed it, or when
 * it is the default of a tool without a custom key. Dropping one can expose another clash, so this
 * repeats until nothing changes. Same rules as the macOS app.
 */
export function resolveToolKeys(toolKeys: Record<string, string>): Record<Tool, string> {
  const custom = new Map<Tool, string>();
  for (const t of TOOLS) {
    const k = toolKeys[t.title.toLowerCase()]?.toLowerCase();
    if (k && isToolKey(k) && k !== t.key) custom.set(t.tool, k);
  }
  let changed = true;
  while (changed) {
    changed = false;
    const claimed = new Set<string>();
    for (const t of TOOLS) {
      const k = custom.get(t.tool);
      if (!k) continue;
      const stealsDefault = TOOLS.some((o) => o.tool !== t.tool && !custom.has(o.tool) && o.key === k);
      if (claimed.has(k) || stealsDefault) { custom.delete(t.tool); changed = true; } else claimed.add(k);
    }
  }
  return Object.fromEntries(TOOLS.map((t) => [t.tool, custom.get(t.tool) ?? t.key])) as Record<Tool, string>;
}

/** "ctrl+shift+s" as people on this platform write it: "Ctrl+Shift+S". */
export function shortcutLabel(text: string): string {
  if (!text) return "";
  const names: Record<string, string> = {
    cmd: "Ctrl", command: "Ctrl", ctrl: "Ctrl", control: "Ctrl", shift: "Shift", alt: "Alt", option: "Alt",
    opt: "Alt", super: "Super", win: "Win", meta: "Super", space: "Space", return: "Enter", escape: "Esc",
    tab: "Tab", printscreen: "PrtSc",
  };
  return text.split("+").map((p) => names[p.trim().toLowerCase()] ?? p.trim().toUpperCase()).join("+");
}
