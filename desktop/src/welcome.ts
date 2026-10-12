// First launch on Windows and Linux. No permission prompt is needed there (except the Wayland
// screenshot portal, which asks on its own), so this is a quick tour plus launch-at-login.
import { api } from "./api";
import { credits, wireLinks } from "./credits";
import { icon } from "./icons";
import { buildLabel, shortcutLabel } from "./core/settings";

export async function startWelcome(root: HTMLElement) {
  const [config, platform, login, build] = await Promise.all([api.getConfig(), api.platform(), api.autostart(), api.buildInfo()]);
  const keys = shortcutLabel(config.shortcuts.captureArea);
  const wayland = platform === "linux-wayland";
  const capture = wayland
    ? "Wayland lets your desktop own global shortcuts: add one in your keyboard settings that runs <code>shotate --capture</code>."
    : keys ? `Press ${keys} and drag. Space switches to picking a whole window.` : "Use the tray icon, or set a shortcut in Settings.";
  root.innerHTML = `
    <div class="page"><div class="welcome">
      <img src="/icon.png" alt="">
      <h1>Welcome to Shotate</h1>
      <p>Capture, mark up, and paste in a few seconds.</p>
      <p class="note" id="build"></p>
      <div class="card">
        <div class="row">${icon("capture")}<div class="label"><b>Capture from anywhere</b><span>${capture}</span></div></div>
        <div class="row">${icon("pen")}<div class="label"><b>Mark it up, press Enter</b><span>The image is copied and saved. Esc steps back, then copies and closes.</span></div></div>
        <div class="row">${icon("gear")}<div class="label"><b>Lives in your system tray</b><span>Every capture mode, Open Image and Settings are one click away.</span></div></div>
      </div>
      <div class="actions">
        <label class="grow"><button class="switch" role="switch" id="login" aria-checked="${login}" aria-label="Open Shotate when I log in"></button>Open at login</label>
        <button class="btn" id="done">Done</button><button class="primary" id="try">Try a capture</button>
      </div>
      ${credits()}
    </div></div>`;
  root.querySelector("#build")!.textContent = buildLabel(build);
  const login$ =root.querySelector<HTMLButtonElement>("#login")!;
  login$.addEventListener("click", () => {
    const on = login$.getAttribute("aria-checked") !== "true";
    login$.setAttribute("aria-checked", String(on));
    void api.autostart(on);
  });
  root.querySelector("#done")!.addEventListener("click", () => void api.closeWindow());
  root.querySelector("#try")!.addEventListener("click", async () => { await api.closeWindow(); await api.capture("area"); });
  wireLinks(root);
}
