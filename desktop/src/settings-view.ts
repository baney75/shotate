// Settings for Windows and Linux: the same panes as the macOS app. Every change applies at once and
// writes the config file; edits to the file (by hand or by an agent) show up here live.
import { api, onEvent } from "./api";
import { credits, wireLinks } from "./credits";
import { icon } from "./icons";
import { TOOLS } from "./core/model";
import { resolveToolKeys, shortcutLabel, type Config } from "./core/settings";

const PANES = [["general", "General", "gear"], ["shortcuts", "Shortcuts", "keyboard"],
               ["commands", "Commands", "terminal"], ["advanced", "Advanced", "sliders"]] as const;

export async function startSettings(root: HTMLElement) {
  let config = await api.getConfig();
  let pane: string = PANES[0][0];

  const save = async (change: (c: Config) => void) => {
    change(config);
    await api.setConfig(config);
    config = await api.getConfig();
  };

  const render = async () => {
    root.innerHTML = `
      <div style="display:grid;grid-template-rows:auto 1fr;height:100%">
        <nav class="tabs" role="tablist">${PANES.map(([id, title, ic]) =>
          `<button class="tab" role="tab" data-pane="${id}" aria-selected="${id === pane}">${icon(ic)}${title}</button>`).join("")}</nav>
        <main class="page">${await body()}</main>
      </div>`;
    root.querySelectorAll<HTMLButtonElement>(".tab").forEach((t) => t.addEventListener("click", () => { pane = t.dataset.pane!; void render(); }));
    wire();
    wireLinks(root);
  };

  const body = async () => {
    switch (pane) {
      case "general": {
        const login = await api.autostart();
        return `
          <div class="form">
            <label>Save captures to:</label><div class="row"><input type="text" id="folder" value="${attr(config.saveFolder)}" style="width:260px"></div>
            <label>Options:</label>
            <div>
              <label class="row"><input type="checkbox" id="copy" ${config.copyOnCapture ? "checked" : ""}> Copy every capture to the clipboard</label>
              <label class="row"><input type="checkbox" id="tray" ${config.showMenuBarIcon ? "checked" : ""}> Show Snapmark in the system tray</label>
              <label class="row"><input type="checkbox" id="login" ${login ? "checked" : ""}> Open Snapmark when I log in</label>
            </div>
          </div>
          <hr class="sep"><p class="note">Captures are saved and copied the moment you take them. Opened images are never overwritten; edits go to a copy beside them.</p>
          <hr class="sep">${credits()}`;
      }
      case "shortcuts": {
        const keys = resolveToolKeys(config.toolKeys);
        const rows = [["captureArea", "Capture area"], ["captureWindow", "Capture window"],
          ["captureScreen", "Capture full screen"]] as const;
        return `
          <h2>Global shortcuts</h2>
          <div class="form">${rows.map(([id, title]) => `<label>${title}:</label>
            <div class="row"><button class="btn recorder" data-shortcut="${id}">${shortcutLabel(config.shortcuts[id]) || "Record Shortcut"}</button>
            ${config.shortcuts[id] ? `<button class="btn" data-clear="${id}" title="Turn off">Clear</button>` : ""}</div>`).join("")}</div>
          <p class="note">Click a shortcut, then press the keys. These work from any app. On Linux with Wayland, set shortcuts in your desktop's keyboard settings to run <code>snapmark --capture</code>.</p>
          <hr class="sep"><h2>Editor tool keys</h2>
          <div class="keys">${TOOLS.map((t) => `<span class="row">${icon(t.tool)} ${t.title}</span>
            <input class="key" maxlength="1" data-tool="${t.title.toLowerCase()}" value="${keys[t.tool].toUpperCase()}">`).join("")}</div>
          <p class="note">One letter per tool. A letter another tool already uses is ignored, so every tool stays reachable. Digits 1–6 always pick colors.</p>`;
      }
      case "commands": {
        const entries = Object.entries(config.commands).sort();
        return `
          <p class="note">Run any shell command from a global shortcut, such as opening a terminal or a notes script.</p>
          <div id="cmds">${entries.length ? "" : '<p class="note">No command shortcuts yet.</p>'}${entries.map(([k, v], i) => cmdRow(k, v, i)).join("")}</div>
          <button class="btn" id="add">Add Command Shortcut</button>`;
      }
      default:
        return `
          <h2>Config file</h2>
          <p class="note">Every setting lives in one JSON file. Edit it yourself or let a script or AI agent change it; Snapmark applies changes the moment the file is saved.</p>
          <div class="row"><button class="btn" id="open-config">Edit Config File…</button></div>
          <hr class="sep"><h2>Command line</h2>
          <p class="note"><code>snapmark --capture</code> · <code>--capture-window</code> · <code>--capture-screen</code> · <code>--open FILE</code> · <code>--settings</code></p>`;
    }
  };

  const cmdRow = (keys: string, command: string, i: number) => `
    <div class="row" data-row="${i}" style="margin-bottom:8px">
      <button class="btn recorder" data-cmdkey="${i}" data-value="${attr(keys)}">${shortcutLabel(keys) || "Set Shortcut"}</button>
      <input type="text" data-cmd="${i}" value="${attr(command)}" placeholder="xdg-open ~/notes" style="width:260px">
      <button class="btn" data-remove="${i}">Remove</button>
    </div>`;

  const saveCommands = () => save((c) => {
    c.commands = {};
    root.querySelectorAll<HTMLElement>("[data-row]").forEach((row) => {
      const k = row.querySelector<HTMLElement>("[data-cmdkey]")!.dataset.value ?? "";
      const v = row.querySelector<HTMLInputElement>("[data-cmd]")!.value.trim();
      if (k && v) c.commands[k] = v;
    });
  });

  const wire = () => {
    const $ = <T extends HTMLElement>(sel: string) => root.querySelector<T>(sel);
    $("#folder")?.addEventListener("change", (e) => save((c) => { c.saveFolder = (e.target as HTMLInputElement).value; }));
    $("#copy")?.addEventListener("change", (e) => save((c) => { c.copyOnCapture = (e.target as HTMLInputElement).checked; }));
    $("#tray")?.addEventListener("change", (e) => save((c) => { c.showMenuBarIcon = (e.target as HTMLInputElement).checked; }));
    $("#login")?.addEventListener("change", (e) => void api.autostart((e.target as HTMLInputElement).checked));
    $("#open-config")?.addEventListener("click", () => void api.openConfig());
    root.querySelectorAll<HTMLButtonElement>("[data-shortcut]").forEach((b) => record(b, (v) =>
      save((c) => { c.shortcuts[b.dataset.shortcut as keyof Config["shortcuts"]] = v; }).then(render)));
    root.querySelectorAll<HTMLButtonElement>("[data-clear]").forEach((b) => b.addEventListener("click", () =>
      save((c) => { c.shortcuts[b.dataset.clear as keyof Config["shortcuts"]] = ""; }).then(render)));
    root.querySelectorAll<HTMLInputElement>("input.key").forEach((inp) => inp.addEventListener("change", () =>
      save((c) => { c.toolKeys[inp.dataset.tool!] = inp.value.toLowerCase(); }).then(render)));
    root.querySelectorAll<HTMLButtonElement>("[data-cmdkey]").forEach((b) => record(b, (v) => {
      b.dataset.value = v; b.textContent = shortcutLabel(v) || "Set Shortcut"; void saveCommands();
    }));
    root.querySelectorAll<HTMLInputElement>("[data-cmd]").forEach((i) => i.addEventListener("change", () => void saveCommands()));
    root.querySelectorAll<HTMLButtonElement>("[data-remove]").forEach((b) => b.addEventListener("click", () => {
      root.querySelector(`[data-row="${b.dataset.remove}"]`)?.remove(); void saveCommands();
    }));
    $("#add")?.addEventListener("click", () => {
      const cmds = $("#cmds")!;
      cmds.querySelector(".note")?.remove();
      cmds.insertAdjacentHTML("beforeend", cmdRow("", "", Date.now()));
      wire();
    });
  };

  /** Click, then press keys: the shortcut is written the way the config file stores it. */
  const record = (b: HTMLButtonElement, done: (value: string) => void) => {
    if (b.dataset.wired) return;
    b.dataset.wired = "1";
    b.addEventListener("click", () => {
      b.classList.add("recording");
      b.textContent = "Type shortcut…";
      void api.pauseShortcuts(true);
      const onKey = (e: KeyboardEvent) => {
        e.preventDefault();
        if (["Control", "Shift", "Alt", "Meta"].includes(e.key)) return;
        stop();
        if (e.key === "Escape") { void render(); return; }
        if (e.key === "Backspace" || e.key === "Delete") { done(""); return; }
        const mods = [e.ctrlKey && "ctrl", e.altKey && "alt", e.shiftKey && "shift", e.metaKey && "super"].filter(Boolean);
        const key = e.code.startsWith("Key") ? e.code.slice(3).toLowerCase() : e.code.startsWith("Digit") ? e.code.slice(5)
          : /^F\d+$/.test(e.code) ? e.code.toLowerCase() : e.code === "Space" ? "space" : e.code === "PrintScreen" ? "printscreen" : "";
        if (!key || (mods.length === 0 && key !== "printscreen")) { void render(); return; }
        done([...mods, key].join("+"));
      };
      const stop = () => { window.removeEventListener("keydown", onKey, true); void api.pauseShortcuts(false); };
      window.addEventListener("keydown", onKey, true);
    });
  };

  await onEvent("config-changed", async () => { config = await api.getConfig(); await render(); });
  await render();
}

const attr = (s: string) => s.replace(/&/g, "&amp;").replace(/"/g, "&quot;");
