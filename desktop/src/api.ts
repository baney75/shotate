// The Rust commands the UI calls. Outside Tauri (a plain browser during development) the calls fall
// back to harmless stand-ins, so the editor can be opened and checked with `npm run dev`.
import type { Config } from "./core/settings";

const tauri = "__TAURI_INTERNALS__" in window;

async function call<T>(cmd: string, args: Record<string, unknown> = {}): Promise<T> {
  if (!tauri) return fallback(cmd, args) as T;
  const { invoke } = await import("@tauri-apps/api/core");
  return invoke<T>(cmd, args);
}

/** Sends bytes as a raw body (no JSON number arrays); text arguments travel URI-encoded in headers. */
async function callRaw<T>(cmd: string, bytes: Uint8Array, headers: Record<string, string>): Promise<T> {
  if (!tauri) return fallback(cmd, headers) as T;
  const { invoke } = await import("@tauri-apps/api/core");
  const encoded = Object.fromEntries(Object.entries(headers).map(([k, v]) => [k, encodeURIComponent(v)]));
  return invoke<T>(cmd, bytes, { headers: encoded });
}

function fallback(cmd: string, args: Record<string, unknown>): unknown {
  console.info("[dev] would call", cmd, args);
  if (cmd === "read_file") return fetch("/sample.png").then((r) => r.arrayBuffer());
  if (cmd === "get_config") return defaults;
  if (cmd === "platform") return "linux";
  if (cmd === "output_path") return "/home/you/Pictures/Screenshots/sample (edited).png";
  return null;
}

const defaults: Config = {
  saveFolder: "~/Pictures/Screenshots", copyOnCapture: true, showMenuBarIcon: true,
  shortcuts: { captureArea: "ctrl+shift+s", captureWindow: "", captureScreen: "" }, commands: {}, toolKeys: {},
};

export const api = {
  readFile: (path: string) => call<ArrayBuffer>("read_file", { path }),
  /** Saves PNG bytes; returns the path written (an opened image's edits go to a sibling copy). */
  savePng: (path: string, bytes: Uint8Array) => callRaw<string>("save_png", bytes, { path }),
  outputPath: (path: string, owns: boolean) => call<string>("output_path", { path, owns }),
  copyPng: (bytes: Uint8Array, path: string) => callRaw<void>("copy_png", bytes, { path }),
  copyText: (text: string) => call<void>("copy_text", { text }),
  trash: (path: string) => call<void>("trash", { path }),
  saveDialog: (name: string) => call<string | null>("save_dialog", { name }),
  getConfig: () => call<Config>("get_config"),
  setConfig: (config: Config) => call<void>("set_config", { config }),
  platform: () => call<string>("platform"),
  openConfig: () => call<void>("open_config"),
  overlayInfo: () => call<OverlayInfo>("overlay_info"),
  /** The frozen screenshot as raw RGBA (width × height × 4 bytes). */
  overlayPixels: () => call<ArrayBuffer>("overlay_pixels"),
  finishCapture: (rect: { x: number; y: number; w: number; h: number } | null) => call<void>("finish_capture", { rect }),
  capture: (mode: "area" | "window" | "screen") => call<void>("capture_cmd", { mode }),
  pauseShortcuts: (paused: boolean) => call<void>("pause_shortcuts", { paused }),
  autostart: (enable?: boolean) => call<boolean>("autostart", { enable }),
  openUrl: (url: string) => call<void>("open_url", { url }),
  closeWindow: () => call<void>("close_window"),
};

export interface OverlayInfo {
  width: number;
  height: number;
  /** Physical pixels per CSS pixel on this monitor. */
  scale: number;
  mode: "area" | "window";
  windows: { x: number; y: number; w: number; h: number; title: string }[];
}

export async function onEvent(name: string, handler: () => void) {
  if (!tauri) return;
  const { listen } = await import("@tauri-apps/api/event");
  await listen(name, handler);
}
