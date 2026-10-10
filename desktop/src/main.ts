// One page, several windows: the query string says which view this window shows.
import "./styles.css";
import { api } from "./api";
import { startEditor } from "./editor";
import { startOverlay } from "./overlay";
import { startSettings } from "./settings-view";
import { startWelcome } from "./welcome";

const q = new URLSearchParams(location.search);
const root = document.getElementById("app")!;
const view = q.get("view") ?? "editor";

const start = {
  editor: () => startEditor(root, q.get("file") ?? "sample.png", q.get("owns") === "1"),
  overlay: () => startOverlay(root),
  settings: () => startSettings(root),
  welcome: () => startWelcome(root),
}[view] ?? (() => startEditor(root, "sample.png", false));

start().catch((err) => {
  // A broken overlay must never strand a full-screen, always-on-top window.
  if (view === "overlay") { void api.finishCapture(null); return; }
  root.innerHTML = `<div class="page"><h2>Snapmark couldn't open this view</h2><p class="note"></p></div>`;
  root.querySelector(".note")!.textContent = String(err);
});
