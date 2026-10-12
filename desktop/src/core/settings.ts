// The config file format, shared with the macOS app: ~/.config/shotate/config.json on Linux,
// %APPDATA%\shotate\config.json on Windows. The Rust side owns reading, writing and watching it;
// this module holds the parts the editor needs.
import { TOOLS, type Tool } from "./model";

export interface Config {
  saveFolder: string;
  copyOnCapture: boolean;
  showMenuBarIcon: boolean;
  shortcuts: Record<"captureArea" | "captureWindow" | "captureScreen", string>;
  commands: Record<string, string>;
  toolKeys: Record<string, string>;
  /** Absent means the channel this build came from. */
  updateChannel?: Channel;
  /** False means no automatic update checks (Check Now still works). */
  checkForUpdates: boolean;
}

export type Channel = "stable" | "nightly";

/** What this build knows about itself (baked in at compile time). */
export interface BuildInfo {
  version: string;
  commit: string;
  channel: Channel;
  date: string;
}

export interface UpdateStatus {
  current: BuildInfo;
  /** The channel being followed: the config's, or the build's own. */
  channel: Channel;
  checking: boolean;
  installing: boolean;
  /** Milliseconds since the epoch of the last successful check. */
  checkedAt: number | null;
  error: string | null;
  available: { version: string; notes: string; offer: "update" | "switchToStable"; label: string } | null;
}

export interface FolderPreset {
  id: "pictures" | "desktop" | "downloads";
  path: string;
}

const trimSlash = (p: string) => p.replace(/[\\/]+$/, "").replace(/\\/g, "/");

/** Which save-folder choice a path is: one of the presets, or "other". */
export function folderChoice(saveFolder: string, presets: FolderPreset[]): FolderPreset["id"] | "other" {
  const p = trimSlash(saveFolder.trim());
  return presets.find((f) => trimSlash(f.path) === p)?.id ?? "other";
}

/** "Shotate 0.12.0 · Stable · a3cab60" for About and Settings. */
export function buildLabel(b: BuildInfo): string {
  // Windows and Linux builds are previews: stable releases are macOS only for now.
  const channel = b.channel === "nightly" ? "Nightly preview" : "Stable";
  const commit = /^[0-9a-f]{7,}$/i.test(b.commit) ? ` · ${b.commit.slice(0, 7)}` : "";
  return `Shotate ${b.version} · ${channel}${commit}`;
}

/** "3 minutes ago", "just now", "2 days ago". */
export function ago(then: number, now: number): string {
  const s = Math.max(0, Math.round((now - then) / 1000));
  const unit = (n: number, word: string) => `${n} ${word}${n === 1 ? "" : "s"} ago`;
  if (s < 60) return "just now";
  if (s < 3600) return unit(Math.floor(s / 60), "minute");
  if (s < 86400) return unit(Math.floor(s / 3600), "hour");
  return unit(Math.floor(s / 86400), "day");
}

/** The status line under Updates in Settings. */
export function updateStatusLine(u: UpdateStatus, now: number): string {
  if (u.installing) return "Installing the update…";
  if (u.checking) return "Checking for updates…";
  if (u.available) {
    return u.available.offer === "switchToStable"
      ? `Stable ${u.available.version} is available.`
      : `Shotate ${u.available.version} is available.`;
  }
  if (u.error) return u.error;
  if (u.checkedAt === null) return `Shotate ${u.current.version}. Not checked yet.`;
  return `Shotate ${u.current.version} is up to date. Checked ${ago(u.checkedAt, now)}.`;
}

const isToolKey = (k: string) => /^[a-z]$/.test(k);

/** Tools added after people already had config files. A file that doesn't mention one predates it,
 *  so a key the person chose wins over its default, and the new tool takes a free letter. */
const LATE_TOOLS: Tool[] = ["pen"];

/**
 * Every tool's key, guaranteed unique so every tool stays reachable. A custom key is dropped (the
 * tool keeps its default) when it isn't a letter, when an earlier tool already claimed it, or when
 * it is the default of a tool without a custom key (unless that tool is newer than the file, see
 * `LATE_TOOLS`). Dropping one can expose another clash, so this repeats until nothing changes. Same
 * rules as the macOS app.
 */
export function resolveToolKeys(toolKeys: Record<string, string>): Record<Tool, string> {
  const custom = new Map<Tool, string>();
  for (const t of TOOLS) {
    const k = toolKeys[t.title.toLowerCase()]?.toLowerCase();
    if (k && isToolKey(k) && k !== t.key) custom.set(t.tool, k);
  }
  const yields = new Set(TOOLS.filter((t) => LATE_TOOLS.includes(t.tool) && toolKeys[t.title.toLowerCase()] === undefined).map((t) => t.tool));
  let changed = true;
  while (changed) {
    changed = false;
    const claimed = new Set<string>();
    for (const t of TOOLS) {
      const k = custom.get(t.tool);
      if (!k) continue;
      const stealsDefault = TOOLS.some((o) => o.tool !== t.tool && !custom.has(o.tool) && !yields.has(o.tool) && o.key === k);
      if (claimed.has(k) || stealsDefault) { custom.delete(t.tool); changed = true; } else claimed.add(k);
    }
  }
  const keys = Object.fromEntries(TOOLS.map((t) => [t.tool, custom.get(t.tool) ?? t.key])) as Record<Tool, string>;
  for (const t of TOOLS) {
    if (!yields.has(t.tool) || custom.has(t.tool) || ![...custom.values()].includes(t.key)) continue;
    const used = new Set(Object.values(keys));
    keys[t.tool] = [..."abcdefghijklmnopqrstuvwxyz"].find((l) => !used.has(l))!;
  }
  return keys;
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
