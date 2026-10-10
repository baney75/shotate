// Full-screen area picker. Rust captures the monitor first and shows it here frozen, so menus and
// tooltips stay put while you choose. Drag to select; Space switches to picking a whole window;
// Enter takes the full screen; Esc cancels. Rects go back in physical pixels of this monitor.
import { api } from "./api";

type R = { x: number; y: number; w: number; h: number };

export async function startOverlay(root: HTMLElement) {
  const info = await api.overlayInfo();
  const pixels = new Uint8ClampedArray(await api.overlayPixels());
  const img = await createImageBitmap(new ImageData(pixels, info.width, info.height));
  root.innerHTML = `<div class="overlay"><canvas></canvas><div class="hint"></div></div>`;
  const canvas = root.querySelector("canvas")!;
  const hint = root.querySelector<HTMLElement>(".hint")!;
  let windowMode = info.mode === "window";
  let start: { x: number; y: number } | null = null;
  let sel: R | null = null;
  let hover: R | null = null;
  const s = info.scale; // physical pixels per CSS pixel

  const setHint = () => {
    hint.textContent = windowMode ? "Click a window · Space: drag an area · Esc: cancel"
      : "Drag to capture · Space: pick a window · Enter: full screen · Esc: cancel";
  };

  const draw = () => {
    const dpr = window.devicePixelRatio || 1;
    canvas.width = innerWidth * dpr;
    canvas.height = innerHeight * dpr;
    const ctx = canvas.getContext("2d")!;
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.drawImage(img, 0, 0, innerWidth, innerHeight);
    const focus = windowMode ? hover : sel;
    ctx.fillStyle = "rgba(0,0,0,0.45)";
    ctx.beginPath();
    ctx.rect(0, 0, innerWidth, innerHeight);
    if (focus) ctx.rect(focus.x, focus.y, focus.w, focus.h);
    ctx.fill("evenodd");
    if (focus) {
      ctx.strokeStyle = "#ffffff";
      ctx.lineWidth = 1.5;
      ctx.strokeRect(focus.x + 0.5, focus.y + 0.5, focus.w - 1, focus.h - 1);
      if (!windowMode) {
        const label = `${Math.round(focus.w * s)} × ${Math.round(focus.h * s)}`;
        ctx.font = "600 12px system-ui, sans-serif";
        const tw = ctx.measureText(label).width + 12;
        const ly = focus.y > 26 ? focus.y - 24 : focus.y + focus.h + 6;
        ctx.fillStyle = "rgba(20,20,22,0.85)";
        ctx.beginPath(); ctx.roundRect(focus.x, ly, tw, 20, 5); ctx.fill();
        ctx.fillStyle = "#fff";
        ctx.fillText(label, focus.x + 6, ly + 14);
      }
    }
  };

  const windowAt = (x: number, y: number) =>
    info.windows.map((w) => ({ x: w.x / s, y: w.y / s, w: w.w / s, h: w.h / s }))
      .find((w) => x >= w.x && x <= w.x + w.w && y >= w.y && y <= w.y + w.h) ?? null;

  const finish = (r: R | null) =>
    api.finishCapture(r && { x: Math.round(r.x * s), y: Math.round(r.y * s), w: Math.round(r.w * s), h: Math.round(r.h * s) });

  canvas.addEventListener("pointerdown", (e) => {
    if (e.button === 2) return void finish(null);
    if (windowMode) { if (hover) void finish(hover); return; }
    canvas.setPointerCapture(e.pointerId);
    start = { x: e.clientX, y: e.clientY };
    sel = { ...start, w: 0, h: 0 };
  });
  canvas.addEventListener("pointermove", (e) => {
    if (windowMode) { hover = windowAt(e.clientX, e.clientY); draw(); return; }
    if (!start) return;
    // Pointer capture reports positions past the screen edge; keep the selection on this monitor.
    const x = Math.max(0, Math.min(innerWidth, e.clientX)), y = Math.max(0, Math.min(innerHeight, e.clientY));
    sel = { x: Math.min(start.x, x), y: Math.min(start.y, y), w: Math.abs(x - start.x), h: Math.abs(y - start.y) };
    draw();
  });
  canvas.addEventListener("pointerup", () => {
    if (windowMode || !start) return;
    start = null;
    if (sel && sel.w >= 4 && sel.h >= 4) void finish(sel);
    else { sel = null; draw(); }
  });
  canvas.addEventListener("contextmenu", (e) => e.preventDefault());
  window.addEventListener("keydown", (e) => {
    if (e.key === "Escape") void finish(null);
    if (e.key === "Enter") void finish({ x: 0, y: 0, w: innerWidth, h: innerHeight });
    if (e.key === " ") { windowMode = !windowMode; sel = null; start = null; setHint(); draw(); }
  });
  window.addEventListener("resize", draw);
  setHint();
  draw();
}
