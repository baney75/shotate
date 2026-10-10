// First launch on Windows and Linux. No permission prompt is needed there (except the Wayland
// screenshot portal, which asks on its own), so this is a quick tour plus launch-at-login.
import { api } from "./api";
import { credits, wireLinks } from "./credits";
import { icon } from "./icons";
import { shortcutLabel } from "./core/settings";

export async function startWelcome(root: HTMLElement) {
  const [config, platform, login] = await Promise.all([api.getConfig(), api.platform(), api.autostart()]);
  const keys = shortcutLabel(config.shortcuts.captureArea);
  const wayland = platform === "linux-wayland";
  const capture = wayland
    ? "Wayland lets your desktop own global shortcuts: add one in your keyboard settings that runs <code>snapmark --capture</code>."
    : keys ? `Press ${keys} and drag. Space switches to picking a whole window.` : "Use the tray icon, or set a shortcut in Settings.";
  root.innerHTML = `
    <div class="page"><div class="welcome">
      <img src="/icon.png" alt="">
      <h1>Welcome to Snapmark</h1>
      <p class="note">Capture, mark up, and paste in a few seconds.</p>
      <div class="card">
        <div class="item">${icon("capture")}<div><b>Capture from anywhere</b><span>${capture}</span></div></div>
        <div class="item">${icon("pen")}<div><b>Mark it up, press Enter</b><span>The image is copied and saved. Esc steps back, then copies and closes.</span></div></div>
        <div class="item">${icon("gear")}<div><b>Lives in your system tray</b><span>Settings, Open Image and the capture modes are one click away.</span></div></div>
      </div>
      <div class="row" style="justify-content:space-between">
        <label class="row"><input type="checkbox" id="login" ${login ? "checked" : ""}> Open Snapmark when I log in</label>
        <div class="row"><button class="btn" id="done">Done</button><button class="primary" id="try">Try a Capture</button></div>
      </div>
      ${credits()}
    </div></div>`;
  root.querySelector("#login")!.addEventListener("change", (e) => void api.autostart((e.target as HTMLInputElement).checked));
  root.querySelector("#done")!.addEventListener("click", () => void api.closeWindow());
  root.querySelector("#try")!.addEventListener("click", async () => { await api.closeWindow(); await api.capture("area"); });
  wireLinks(root);
}
