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

// The native look for this OS (see styles.css). It never blocks or breaks startup: a failed lookup
// keeps the default look, and the overlay must reach its error guard below no matter what.
api.platform().then((p) => { document.documentElement.dataset.platform = p; }, () => {});

const start = {
  editor: () => startEditor(root, q.get("file") ?? "sample.png", q.get("owns") === "1"),
  overlay: () => startOverlay(root),
  settings: () => startSettings(root),
  welcome: () => startWelcome(root),
}[view] ?? (() => startEditor(root, "sample.png", false));

if (view === "editor") root.innerHTML = `<div class="center"><div><div class="spinner" style="margin:0 auto 12px"></div>Opening image…</div></div>`;

start().catch((err) => {
  // A broken overlay must never strand a full-screen, always-on-top window.
  if (view === "overlay") { void api.finishCapture(null); return; }
  root.innerHTML = `<div class="center"><div><b>Snapmark couldn't open this</b><p class="note"></p>
    <button class="btn" id="close-view">Close</button></div></div>`;
  root.querySelector(".note")!.textContent = String(err);
  root.querySelector("#close-view")!.addEventListener("click", () => void api.closeWindow());
});
