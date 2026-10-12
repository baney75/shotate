// Settings for Windows and Linux. Windows gets the Windows 11 Settings layout (navigation on the
// left, cards of rows on the right); Linux gets the GNOME one (a centered view switcher above
// boxed lists). Every change applies at once and writes the config file; edits to the file (by
// hand or by an agent) show up here live.
import { api, onEvent } from "./api";
import { credits, wireLinks } from "./credits";
import { icon } from "./icons";
import { TOOLS } from "./core/model";
import {
  buildLabel, folderChoice, resolveToolKeys, shortcutLabel, updateStatusLine,
  type Config, type FolderPreset, type UpdateStatus,
} from "./core/settings";

const PANES = [["general", "General", "gear"], ["shortcuts", "Shortcuts", "keyboard"],
               ["commands", "Commands", "terminal"], ["advanced", "Advanced", "sliders"]] as const;

const esc = (s: string) =>
  s.replace(/&/g, "&amp;").replace(/"/g, "&quot;").replace(/</g, "&lt;").replace(/>/g, "&gt;");

/** One settings row: an icon, a title with an optional description, and its controls. */
const row = (ic: string, title: string, detail: string, controls: string) => `
  <div class="row">${ic ? icon(ic) : ""}<div class="label"><b>${title}</b>${detail ? `<span>${detail}</span>` : ""}</div>
  <div class="controls">${controls}</div></div>`;

const FOLDER_NAMES: Record<FolderPreset["id"], string> = { pictures: "Pictures › Screenshots", desktop: "Desktop", downloads: "Downloads" };


const toggle = (id: string, on: boolean, label: string) =>
  `<button class="switch" role="switch" id="${id}" aria-checked="${on}" aria-label="${label}"></button>`;

export async function startSettings(root: HTMLElement) {
  let config = await api.getConfig();
  const presets = await api.folderPresets();
  let updates = await api.updateStatus();
  let pane: string = PANES[0][0];
  // Command rows being edited, including half-filled ones that aren't saved yet.
  let drafts: { keys: string; command: string }[] = Object.entries(config.commands).sort().map(([keys, command]) => ({ keys, command }));
  // The config this window wrote last; its own change event doesn't re-render (and lose focus or drafts).
  let lastWritten = "";
  // Ends an in-progress shortcut recording; global shortcuts come back.
  let stopRecording: (() => void) | null = null;

  const save = async (change: (c: Config) => void) => {
    change(config);
    try {
      await api.setConfig(config);
    } catch (err) {
      alert(String(err));
    }
    config = await api.getConfig();
    lastWritten = JSON.stringify(config);
  };

  const render = async () => {
    stopRecording?.();
    const title = PANES.find(([id]) => id === pane)![1];
    root.innerHTML = `
      <div class="shell">
        <nav class="nav" role="tablist" aria-label="Settings">
          <div class="brand"><img src="/icon.png" alt="">Shotate</div>
          ${PANES.map(([id, t, ic]) => `<button class="tab" role="tab" data-pane="${id}" aria-selected="${id === pane}">${icon(ic)}${t}</button>`).join("")}
          <div class="grow"></div>
        </nav>
        <main class="page"><h1>${title}</h1>${await body()}</main>
      </div>`;
    root.querySelectorAll<HTMLButtonElement>(".tab").forEach((t) => t.addEventListener("click", () => { pane = t.dataset.pane!; void render(); }));
    wire();
    wireLinks(root);
  };

  const body = async () => {
    switch (pane) {
      case "general": {
        const login = await api.autostart();
        const choice = folderChoice(config.saveFolder, presets);
        const folders = presets.map((f) =>
          `<option value="${f.id}"${choice === f.id ? " selected" : ""}>${FOLDER_NAMES[f.id]}</option>`).join("");
        return `
          <div class="card">
            ${row("save", "Save screenshots to", esc(config.saveFolder),
                  `<select id="folder" aria-label="Save screenshots to">${folders}
                     ${choice === "other" ? `<option value="current" selected>${esc(config.saveFolder)}</option>` : ""}
                     <option value="other">Other folder…</option></select>`)}
            ${row("path", "Copy every capture to the clipboard", "Paste it anywhere the moment you take it.",
                  toggle("copy", config.copyOnCapture, "Copy every capture to the clipboard"))}
          </div>
          <div class="card">
            ${row("capture", "Show Shotate in the system tray", "The tray menu has every capture mode, Open Image and Settings.",
                  toggle("tray", config.showMenuBarIcon, "Show Shotate in the system tray"))}
            ${row("check", "Open Shotate when I log in", "So the capture shortcut always works.",
                  toggle("login", login, "Open Shotate when I log in"))}
          </div>
          <p class="note">Captures are saved and copied the moment you take them. Opened images are never overwritten; edits go to a copy beside them.</p>
          <div class="section">Updates</div>
          <div class="card">
            ${row("check", "Update channel", "Windows and Linux get Nightly preview builds, made every day from the newest code. Stable releases are macOS only for now.",
                  `<span class="value">Nightly preview</span>`)}
            ${row("path", "Check for updates automatically", "Once a day, one request to GitHub. Nothing about you is sent.",
                  toggle("auto-update", config.checkForUpdates, "Check for updates automatically"))}
            <div id="update-row">${updateRow()}</div>
          </div>
          ${credits()}`;
      }
      case "shortcuts": {
        const keys = resolveToolKeys(config.toolKeys);
        const rows = [["captureArea", "Capture area", "Drag over anything. Space switches to a window."],
          ["captureWindow", "Capture window", "Click the window you want."],
          ["captureScreen", "Capture full screen", "The screen under the pointer."]] as const;
        return `
          <div class="section">Global shortcuts</div>
          <div class="card">${rows.map(([id, title, detail]) => row("", title, detail, `
            <button class="btn recorder" data-shortcut="${id}">${esc(shortcutLabel(config.shortcuts[id])) || "Record shortcut"}</button>
            ${config.shortcuts[id] ? `<button class="btn" data-clear="${id}" aria-label="Turn off ${title}">Clear</button>` : ""}`)).join("")}
          </div>
          <p class="note">Click a shortcut, then press the keys. These work from any app.${
            document.documentElement.dataset.platform === "linux-wayland"
              ? " On Wayland your desktop owns global shortcuts: add one in its keyboard settings that runs <code>shotate --capture</code>." : ""}</p>
          <div class="section">Editor tool keys</div>
          <div class="card keys">${TOOLS.map((t) => `<div class="key-row"><span>${icon(t.tool)}${t.title}</span>
            <input type="text" class="key" maxlength="1" data-tool="${t.title.toLowerCase()}" value="${keys[t.tool].toUpperCase()}" aria-label="${t.title} key"></div>`).join("")}</div>
          <p class="note">One letter per tool. A letter another tool already uses is ignored, so every tool stays reachable. Digits 1–6 always pick colors.</p>`;
      }
      case "commands":
        return `
          <p class="note" style="margin:0 2px 14px">Run any shell command from a global shortcut, such as opening a terminal or a notes script.</p>
          <div class="card" id="cmds">${drafts.length ? drafts.map((d, i) => cmdRow(d.keys, d.command, i)).join("")
            : row("terminal", "No command shortcuts yet", "Add one to launch a script from anywhere.", "")}</div>
          <div style="margin-top:12px"><button class="btn" id="add">${icon("plus")}Add command shortcut</button></div>`;
      default:
        return `
          <div class="card">
            ${row("sliders", "Config file", "Every setting lives in one JSON file. Edit it yourself or let a script or AI agent change it; Shotate applies changes the moment it's saved.",
                  `<button class="btn" id="open-config">Edit…</button>`)}
          </div>
          <div class="section">Command line</div>
          <div class="card">
            ${row("terminal", "Capture and open from scripts", "<code>shotate --capture</code> · <code>--capture-window</code> · <code>--capture-screen</code> · <code>--open FILE</code> · <code>--settings</code>", "")}
          </div>`;
    }
  };

  /** The version, the status line, and Check Now / Install Update. */
  const updateRow = () => {
    const a = updates.available;
    const busy = updates.checking || updates.installing;
    const status = esc(updateStatusLine(updates, Date.now()));
    return row("", esc(buildLabel(updates.current)), `<span id="update-status" role="status">${status}</span>`, `
      ${a ? `<a class="link" href="${esc(a.notes)}" data-url="${esc(a.notes)}">What's new</a>
             <button class="primary" id="install-update"${busy ? " disabled" : ""}>Install Update</button>` : ""}
      <button class="btn" id="check-now"${busy ? " disabled" : ""}>Check Now</button>`);
  };

  /** Redraws only the update row, so a status change never steals focus elsewhere. */
  const refreshUpdates = (fresh: UpdateStatus) => {
    updates = fresh;
    const slot = root.querySelector<HTMLElement>("#update-row");
    if (!slot) return;
    slot.innerHTML = updateRow();
    wireUpdates();
    wireLinks(slot);
  };

  const wireUpdates = () => {
    root.querySelector("#check-now")?.addEventListener("click", async () => {
      refreshUpdates({ ...updates, checking: true });
      refreshUpdates(await api.checkUpdates());
    });
    root.querySelector("#install-update")?.addEventListener("click", async () => {
      refreshUpdates({ ...updates, installing: true });
      try {
        await api.installUpdate();
      } catch (err) {
        alert(String(err));
      }
      refreshUpdates(await api.updateStatus());
    });
  };

  const cmdRow = (keys: string, command: string, i: number) => `
    <div class="row" data-row="${i}">
      <button class="btn recorder" data-cmdkey="${i}">${esc(shortcutLabel(keys)) || "Set shortcut"}</button>
      <input type="text" data-cmd="${i}" value="${esc(command)}" placeholder="xdg-open ~/notes" aria-label="Command" style="flex:1;min-width:0">
      <button class="btn" data-remove="${i}" aria-label="Remove">${icon("trash")}</button>
    </div>`;

  /** Saves complete rows; incomplete ones stay on screen as drafts. */
  const saveCommands = () => save((c) => {
    c.commands = {};
    for (const d of drafts) if (d.keys && d.command.trim()) c.commands[d.keys] = d.command.trim();
  });

  const flip = (id: string, apply: (on: boolean) => Promise<unknown>) => {
    const b = root.querySelector<HTMLButtonElement>(`#${id}`);
    b?.addEventListener("click", async () => {
      const on = b.getAttribute("aria-checked") !== "true";
      b.setAttribute("aria-checked", String(on));
      await apply(on);
    });
  };

  const wire = () => {
    const $ = <T extends HTMLElement>(sel: string) => root.querySelector<T>(sel);
    $<HTMLSelectElement>("#folder")?.addEventListener("change", async (e) => {
      // "current" is the custom folder already in use; "other" always opens the picker, even when a
      // custom folder is set, because it is a separate option from that folder.
      const id = (e.target as HTMLSelectElement).value;
      if (id === "current") return;
      const preset = presets.find((f) => f.id === id);
      const folder = preset ? preset.path : await api.pickFolder();
      if (folder) await save((c) => { c.saveFolder = folder; });
      await render();  // a cancelled picker puts the select back on the folder in use
    });
    flip("auto-update", (on) => save((c) => { c.checkForUpdates = on; }));
    wireUpdates();
    flip("copy", (on) => save((c) => { c.copyOnCapture = on; }));
    flip("tray", (on) => save((c) => { c.showMenuBarIcon = on; }));
    flip("login", (on) => api.autostart(on));
    $("#open-config")?.addEventListener("click", () => void api.openConfig());
    root.querySelectorAll<HTMLButtonElement>("[data-shortcut]").forEach((b) => record(b, (v) =>
      save((c) => { c.shortcuts[b.dataset.shortcut as keyof Config["shortcuts"]] = v; }).then(render)));
    root.querySelectorAll<HTMLButtonElement>("[data-clear]").forEach((b) => b.addEventListener("click", () =>
      save((c) => { c.shortcuts[b.dataset.clear as keyof Config["shortcuts"]] = ""; }).then(render)));
    root.querySelectorAll<HTMLInputElement>("input.key").forEach((inp) => {
      inp.addEventListener("input", () => { inp.value = inp.value.replace(/[^a-z]/gi, "").slice(-1).toUpperCase(); });
      inp.addEventListener("change", () => save((c) => { c.toolKeys[inp.dataset.tool!] = inp.value.toLowerCase(); }).then(render));
    });
    root.querySelectorAll<HTMLButtonElement>("[data-cmdkey]").forEach((b) => record(b, (v) => {
      drafts[Number(b.dataset.cmdkey)].keys = v;
      void saveCommands().then(render);
    }));
    root.querySelectorAll<HTMLInputElement>("[data-cmd]").forEach((i) => {
      i.addEventListener("input", () => { drafts[Number(i.dataset.cmd)].command = i.value; });
      i.addEventListener("change", () => void saveCommands());
    });
    root.querySelectorAll<HTMLButtonElement>("[data-remove]").forEach((b) => b.addEventListener("click", () => {
      drafts.splice(Number(b.dataset.remove), 1);
      void saveCommands().then(render);
    }));
    $("#add")?.addEventListener("click", () => {
      drafts.push({ keys: "", command: "" });
      void render().then(() => root.querySelector<HTMLInputElement>(`[data-cmd="${drafts.length - 1}"]`)?.focus());
    });
  };

  /** Click, then press keys: the shortcut is written the way the config file stores it. */
  const record = (b: HTMLButtonElement, done: (value: string) => void) => {
    b.addEventListener("click", () => {
      stopRecording?.();
      const label = b.textContent ?? "";
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
      const stop = () => {
        window.removeEventListener("keydown", onKey, true);
        window.removeEventListener("blur", cancel);
        b.classList.remove("recording");
        stopRecording = null;
        void api.pauseShortcuts(false);
      };
      // Leaving the window (or switching panes) ends recording, so shortcuts never stay paused.
      const cancel = () => { stop(); b.textContent = label; };
      stopRecording = cancel;
      window.addEventListener("keydown", onKey, true);
      window.addEventListener("blur", cancel);
    });
  };

  await onEvent("config-changed", async () => {
    const fresh = await api.getConfig();
    if (JSON.stringify(fresh) === lastWritten) return;  // our own write
    config = fresh;
    drafts = Object.entries(config.commands).sort().map(([keys, command]) => ({ keys, command }));
    await render();
  });
  await onEvent("update-status", async () => refreshUpdates(await api.updateStatus()));
  // Keeps "Checked 3 minutes ago" current.
  setInterval(() => {
    const line = root.querySelector("#update-status");
    if (line) line.textContent = updateStatusLine(updates, Date.now());
  }, 30_000);
  window.addEventListener("beforeunload", () => stopRecording?.());
  await render();
}
