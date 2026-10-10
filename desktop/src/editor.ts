// The annotation editor for Windows and Linux. Same behavior as the macOS editor: a new mark is
// selected as soon as it is drawn, selected shapes show resize handles, Esc steps back one level
// (tool → Select → no selection → copy and close), and marks past the edge grow the canvas.
import { api } from "./api";
import { icon } from "./icons";
import {
  Doc, Geometry, PALETTE, TOOLS, css, duplicate, fontSize, handles, inset, mark, moveHandle,
  offset, strokeWidth, textOrStepRect, type Mark, type Point, type Rect, type StrokeSize, type Tool,
} from "./core/model";
import { FONT, drawBackground, drawMark, edgeColor, flatten } from "./core/render";
import { resolveToolKeys } from "./core/settings";

export async function startEditor(root: HTMLElement, file: string, owns: boolean) {
  const bytes = await api.readFile(file);
  const image = await createImageBitmap(new Blob([bytes]));
  const probe = new OffscreenCanvas(image.width, image.height).getContext("2d")!;
  probe.drawImage(image, 0, 0);
  const border = edgeColor(probe.getImageData(0, 0, image.width, image.height));
  const measureCtx = new OffscreenCanvas(1, 1).getContext("2d")!;
  const measure = (t: string, s: number) => { measureCtx.font = FONT(s); return measureCtx.measureText(t).width; };
  const doc = new Doc(image.width, image.height, measure);
  const keys = resolveToolKeys((await api.getConfig()).toolKeys);
  new Editor(root, file, owns, doc, image, border, keys);
}

class Editor {
  tool: Tool = "arrow";
  colorIndex = 0;
  size: StrokeSize = 2;
  selectedId: string | null = null;
  hoverId: string | null = null;
  draft: Mark | null = null;
  live: Mark | null = null;
  dragOrigin: Point | null = null;
  dragHandle: number | null = null;
  cropDraft: Rect | null = null;
  frozen: Rect | null = null;
  input: HTMLInputElement | null = null;
  editingId: string | null = null;
  textAt: Point = { x: 0, y: 0 };
  savedRevision = 0;
  savedCopy: string | null = null;
  finished = false;

  stage!: HTMLElement;
  canvas!: HTMLCanvasElement;
  status!: HTMLElement;
  buttons: Record<string, HTMLButtonElement> = {};

  constructor(private root: HTMLElement, private file: string, private owns: boolean, private doc: Doc,
              private image: ImageBitmap, private border: ReturnType<typeof edgeColor>,
              private keys: Record<Tool, string>) {
    this.build();
    this.bind();
    this.refresh();
    new ResizeObserver(() => this.draw()).observe(this.stage);
  }

  // MARK: Layout

  build() {
    const tools = TOOLS.map((t) =>
      `<button class="tbtn" data-tool="${t.tool}" title="${t.title} (${this.keys[t.tool].toUpperCase()})">${icon(t.tool, t.title)}</button>`).join("");
    const colors = PALETTE.map((p, i) =>
      `<button class="swatch" data-color="${i}" title="${p.name} (${i + 1})" aria-label="${p.name}" style="background:${css(p.color)}"></button>`).join("");
    const sizes = ([1, 2, 3] as StrokeSize[]).map((s) =>
      `<button class="tbtn" data-size="${s}" title="${["Small", "Medium", "Large"][s - 1]} ([ and ] change size)">` +
      `<span class="dot" style="width:${3 + s * 3}px;height:${3 + s * 3}px"></span></button>`).join("");
    this.root.innerHTML = `
      <div class="editor">
        <div class="toolbar">
          <div class="group">${tools}</div>
          <div class="row">${colors}</div>
          <div class="group">${sizes}</div>
          <div class="spacer"></div>
          <div class="group">
            <button class="tbtn" data-act="delete" title="Delete the selected mark (Delete). Ctrl+Backspace moves the capture to the Trash.">${icon("trash", "Delete")}</button>
            <button class="tbtn" data-act="undo" title="Undo (Ctrl+Z)">${icon("undo", "Undo")}</button>
            <button class="tbtn" data-act="redo" title="Redo (Ctrl+Shift+Z)">${icon("redo", "Redo")}</button>
            <button class="tbtn" data-act="path" title="Copy the file path and close (Ctrl+Shift+C)">${icon("path", "Copy path")}</button>
            <button class="tbtn" data-act="save" title="Save a copy as… (Ctrl+S)">${icon("save", "Save a copy")}</button>
          </div>
          <button class="primary" data-act="copy" title="Copy the image and close (Enter)">Copy &amp; Close</button>
        </div>
        <div class="stage"><canvas></canvas></div>
        <div class="status"><span></span><span>Enter or Esc copies and closes · Ctrl+Z undo</span></div>
      </div>`;
    this.stage = this.root.querySelector(".stage")!;
    this.canvas = this.root.querySelector("canvas")!;
    this.status = this.root.querySelector(".status span")!;
    for (const b of this.root.querySelectorAll<HTMLButtonElement>("button")) {
      const k = b.dataset.tool ?? b.dataset.color ?? b.dataset.size ?? b.dataset.act;
      if (k) this.buttons[(b.dataset.tool ? "tool:" : b.dataset.color ? "color:" : b.dataset.size ? "size:" : "") + k] = b;
    }
  }

  /** The area shown, in image pixels: the canvas plus a margin to draw into. Holds still mid-drag. */
  get layout(): Rect {
    if (this.frozen) return this.frozen;
    const margin = 0.07 * Math.max(this.doc.width, this.doc.height);
    return inset(this.doc.canvas, -margin);
  }
  get scale() {
    const l = this.layout;
    return Math.min(this.stage.clientWidth / l.w, this.stage.clientHeight / l.h);
  }
  get origin(): Point {
    const l = this.layout, s = this.scale;
    return { x: (this.stage.clientWidth - l.w * s) / 2 - l.x * s, y: (this.stage.clientHeight - l.h * s) / 2 - l.y * s };
  }
  get ppp() { return 1 / this.scale; } // image pixels per CSS pixel

  toImage(e: { clientX: number; clientY: number }): Point {
    const r = this.canvas.getBoundingClientRect(), o = this.origin;
    return { x: (e.clientX - r.left - o.x) * this.ppp, y: (e.clientY - r.top - o.y) * this.ppp };
  }
  toView(p: Point): Point {
    const o = this.origin;
    return { x: o.x + p.x * this.scale, y: o.y + p.y * this.scale };
  }

  get selected(): Mark | undefined { return this.doc.marks.find((m) => m.id === this.selectedId); }
  get color() { return PALETTE[this.colorIndex].color; }

  // MARK: Drawing

  draw() {
    const dpr = window.devicePixelRatio || 1;
    const W = this.stage.clientWidth, H = this.stage.clientHeight;
    if (this.canvas.width !== Math.round(W * dpr) || this.canvas.height !== Math.round(H * dpr)) {
      this.canvas.width = Math.round(W * dpr);
      this.canvas.height = Math.round(H * dpr);
    }
    const ctx = this.canvas.getContext("2d")!;
    ctx.setTransform(1, 0, 0, 1, 0, 0);
    ctx.clearRect(0, 0, this.canvas.width, this.canvas.height);
    const o = this.origin, s = this.scale;
    ctx.setTransform(dpr * s, 0, 0, dpr * s, dpr * o.x, dpr * o.y);

    let marks = this.doc.marks;
    if (this.live) marks = marks.map((m) => (m.id === this.live!.id ? this.live! : m));
    if (this.draft) marks = [...marks, this.draft];
    const canvas = this.doc.canvasIncluding(marks);

    ctx.save();
    ctx.shadowColor = "rgba(0,0,0,0.35)";
    ctx.shadowBlur = 14 * this.ppp * s;
    ctx.shadowOffsetY = 2 * this.ppp * s;
    ctx.fillStyle = css(this.border.a === 0 ? { r: 1, g: 1, b: 1, a: 1 } : this.border);
    ctx.fillRect(canvas.x, canvas.y, canvas.w, canvas.h);
    ctx.restore();
    drawBackground(ctx, this.image, this.doc, canvas, this.border);
    for (const m of marks) if (m.id !== this.editingId) drawMark(ctx, m, this.doc.width);

    const crop = this.cropDraft ?? this.doc.effectiveCrop;
    if (crop) {
      ctx.save();
      ctx.fillStyle = "rgba(0,0,0,0.55)";
      ctx.beginPath();
      ctx.rect(canvas.x, canvas.y, canvas.w, canvas.h);
      ctx.rect(crop.x, crop.y, crop.w, crop.h);
      ctx.fill("evenodd");
      ctx.strokeStyle = "rgba(255,255,255,0.9)";
      ctx.lineWidth = this.ppp;
      ctx.setLineDash([6 * this.ppp, 4 * this.ppp]);
      ctx.strokeRect(crop.x, crop.y, crop.w, crop.h);
      ctx.restore();
    }

    const outline = (m: Mark) => {
      const r = m.tool === "text" || m.tool === "step" ? textOrStepRect(m, this.doc.width, this.doc.measure)
        : { ...rectOf(m) };
      return inset(r, -(4 * this.ppp + strokeWidth(m.size, this.doc.width) / 2));
    };
    ctx.lineWidth = 1.5 * this.ppp;
    const hover = marks.find((m) => m.id === this.hoverId && m.id !== this.selectedId);
    if (hover) {
      const r = outline(hover);
      ctx.strokeStyle = "rgba(59,130,246,0.5)";
      ctx.strokeRect(r.x, r.y, r.w, r.h);
    }
    const sel = marks.find((m) => m.id === this.selectedId && m.id !== this.editingId);
    if (sel) {
      ctx.strokeStyle = "#3b82f6";
      if (sel.tool !== "arrow") { const r = outline(sel); ctx.strokeRect(r.x, r.y, r.w, r.h); }
      const side = 8 * this.ppp;
      for (const h of handles(sel)) {
        ctx.beginPath();
        ctx.arc(h.x, h.y, side / 2, 0, Math.PI * 2);
        ctx.fillStyle = "#fff";
        ctx.fill();
        ctx.stroke();
      }
    }
  }

  // MARK: Pointer

  handleAt(p: Point): number | null {
    const m = this.live ?? this.selected;
    if (!m) return null;
    const i = handles(m).findIndex((h) => Math.hypot(h.x - p.x, h.y - p.y) <= 7 * this.ppp);
    return i >= 0 ? i : null;
  }

  bind() {
    const c = this.canvas;
    c.addEventListener("pointerdown", (e) => {
      if (e.button !== 0) return;
      // Stops the browser's mousedown focus change, which would steal focus from a new text label.
      e.preventDefault();
      c.setPointerCapture(e.pointerId);
      this.closeMenu();
      // Commit a label first: it may grow the canvas, and the layout must settle before mapping this click.
      if (this.input) this.commitText();
      this.frozen = this.layout;
      const p = this.toImage(e);
      const tol = 8 * this.ppp;
      const h = this.handleAt(p);
      if (h !== null && this.selected) { this.dragHandle = h; this.live = this.selected; return; }
      switch (this.tool) {
        case "select": {
          const hit = this.doc.hitTest(p, tol);
          this.select(hit?.id ?? null);
          if (hit) {
            this.dragOrigin = p;
            if (e.detail === 2 && hit.tool === "text") this.beginText(hit.start, hit);
          }
          break;
        }
        case "text": {
          const hit = this.doc.hitTest(p, tol);
          this.beginText(hit?.tool === "text" ? hit.start : p, hit?.tool === "text" ? hit : null);
          break;
        }
        case "step": {
          const m = this.doc.add(mark("step", this.color, p, p, { size: this.size }));
          this.select(m.id);
          this.changed();
          break;
        }
        case "crop":
          this.select(null);
          this.dragOrigin = p;
          this.cropDraft = { x: p.x, y: p.y, w: 0, h: 0 };
          break;
        default:
          this.select(null);
          this.draft = mark(this.tool, this.color, p, p, { size: this.size });
      }
      this.draw();
    });

    c.addEventListener("pointermove", (e) => {
      let p = this.toImage(e);
      if (!c.hasPointerCapture(e.pointerId)) {
        const onHandle = this.handleAt(p) !== null;
        const hit = this.tool === "select" && !onHandle ? this.doc.hitTest(p, 6 * this.ppp) : undefined;
        if ((hit?.id ?? null) !== this.hoverId) { this.hoverId = hit?.id ?? null; this.draw(); }
        c.style.cursor = onHandle ? "crosshair" : this.tool === "select" ? (hit ? "grab" : "default")
          : this.tool === "text" ? "text" : "crosshair";
        return;
      }
      if (this.dragHandle !== null && this.live) {
        const base = this.selected ?? this.live;
        if (e.shiftKey) {
          const fixed = base.tool === "arrow" ? (this.dragHandle === 0 ? base.end : base.start)
            : moveHandle(base, this.dragHandle, p).start;
          p = base.tool === "arrow" ? Geometry.snap45(fixed, p) : Geometry.square(fixed, p);
        }
        this.live = moveHandle(base, this.dragHandle, p);
      } else if (this.tool === "select" && this.dragOrigin && this.selected) {
        c.style.cursor = "grabbing";
        this.live = offset(this.selected, p.x - this.dragOrigin.x, p.y - this.dragOrigin.y);
      } else if (this.tool === "crop" && this.dragOrigin) {
        const o = this.dragOrigin;
        this.cropDraft = { x: Math.min(o.x, p.x), y: Math.min(o.y, p.y), w: Math.abs(p.x - o.x), h: Math.abs(p.y - o.y) };
      } else if (this.draft) {
        if (e.shiftKey) p = this.draft.tool === "arrow" ? Geometry.snap45(this.draft.start, p) : Geometry.square(this.draft.start, p);
        this.draft = { ...this.draft, end: p };
      }
      this.draw();
    });

    c.addEventListener("pointerup", () => {
      if (this.live) {
        this.doc.update(this.live);
        this.live = null;
        this.changed();
      } else if (this.tool === "crop" && this.cropDraft) {
        const d = this.cropDraft;
        if (d.w >= 4 * this.ppp && d.h >= 4 * this.ppp) this.doc.setCrop(d);
        this.cropDraft = null;
        this.changed();
      } else if (this.draft) {
        const d = this.draft;
        this.draft = null;
        if (Math.hypot(d.end.x - d.start.x, d.end.y - d.start.y) > 3 * this.ppp) {
          this.doc.add(d);
          this.select(d.id);
          this.changed();
        }
      }
      this.dragOrigin = null;
      this.dragHandle = null;
      this.frozen = null;
      this.draw();
    });

    c.addEventListener("pointerleave", () => { if (this.hoverId) { this.hoverId = null; this.draw(); } });
    c.addEventListener("contextmenu", (e) => this.contextMenu(e));
    window.addEventListener("keydown", (e) => this.key(e));
    window.addEventListener("pointerdown", (e) => { if (!(e.target as Element).closest(".menu")) this.closeMenu(); });

    for (const [k, b] of Object.entries(this.buttons)) {
      b.addEventListener("click", () => {
        if (k.startsWith("tool:")) this.setTool(k.slice(5) as Tool);
        else if (k.startsWith("color:")) this.setColor(Number(k.slice(6)));
        else if (k.startsWith("size:")) this.setSize(Number(k.slice(5)) as StrokeSize);
        else this.action(k);
      });
    }
    import("@tauri-apps/api/window").then(({ getCurrentWindow }) =>
      getCurrentWindow().onCloseRequested(async (e) => {
        if (this.finished || this.doc.revision === this.savedRevision) return;
        e.preventDefault();
        await this.closeAsking();
      })).catch(() => {});
  }

  // MARK: Context menu

  menu: HTMLElement | null = null;
  closeMenu() { this.menu?.remove(); this.menu = null; }

  contextMenu(e: MouseEvent) {
    e.preventDefault();
    this.commitText();
    const hit = this.doc.hitTest(this.toImage(e), 8 * this.ppp);
    if (hit) this.select(hit.id);
    if (!this.selectedId) return;
    this.closeMenu();
    const m = document.createElement("div");
    m.className = "menu";
    m.innerHTML = `<button data-a="delete">Delete<kbd>Del</kbd></button><button data-a="duplicate">Duplicate<kbd>Ctrl+D</kbd></button>
      <hr><button data-a="front">Bring to Front<kbd>Ctrl+]</kbd></button><button data-a="back">Send to Back<kbd>Ctrl+[</kbd></button>`;
    m.style.left = `${Math.min(e.clientX, innerWidth - 200)}px`;
    m.style.top = `${Math.min(e.clientY, innerHeight - 150)}px`;
    m.addEventListener("click", (ev) => {
      const a = (ev.target as HTMLElement).closest("button")?.dataset.a;
      if (a) this.action(a);
      this.closeMenu();
    });
    document.body.append(m);
    this.menu = m;
  }

  // MARK: Text

  beginText(at: Point, editing: Mark | null) {
    const v = this.toView(at);
    const size = fontSize(editing?.size ?? this.size, this.doc.width) * this.scale;
    const input = document.createElement("input");
    input.className = "label-input";
    input.value = editing?.text ?? "";
    input.placeholder = "Type, then Enter";
    Object.assign(input.style, {
      left: `${v.x}px`, top: `${v.y}px`, height: `${size * 1.5}px`, font: FONT(size),
      background: css(editing?.color ?? this.color, 0.92), width: `${Math.max(200, this.stage.clientWidth - v.x - 12)}px`,
    });
    input.addEventListener("keydown", (e) => {
      e.stopPropagation();
      if (e.key === "Enter") { e.preventDefault(); this.commitText(); }
      if (e.key === "Escape") { e.preventDefault(); this.cancelText(); }
    });
    this.stage.append(input);
    input.focus();
    requestAnimationFrame(() => input.focus());
    this.input = input;
    this.textAt = at;
    this.editingId = editing?.id ?? null;
    this.draw();
  }

  commitText() {
    const input = this.input;
    if (!input) return;
    const text = input.value.trim();
    input.remove();
    this.input = null;
    const editing = this.doc.marks.find((m) => m.id === this.editingId);
    if (editing) {
      if (!text) this.doc.remove(editing.id);
      else { this.doc.update({ ...editing, text }); this.select(editing.id); }
    } else if (text) {
      const m = this.doc.add(mark("text", this.color, this.textAt, this.textAt, { size: this.size, text }));
      this.select(m.id);
    }
    this.editingId = null;
    this.changed();
  }

  cancelText() {
    this.input?.remove();
    this.input = null;
    this.editingId = null;
    this.draw();
  }

  // MARK: Commands

  select(id: string | null) {
    this.selectedId = id;
    this.refresh();
  }

  setTool(t: Tool) {
    this.commitText();
    this.tool = t;
    this.select(null);
    this.draw();
  }

  setColor(i: number) {
    this.colorIndex = i;
    const m = this.selected;
    if (m) { this.doc.update({ ...m, color: this.color }); this.changed(); }
    this.refresh();
  }

  setSize(s: StrokeSize) {
    this.size = s;
    const m = this.selected;
    if (m) { this.doc.update({ ...m, size: s }); this.changed(); }
    this.refresh();
  }

  async action(a: string) {
    const m = this.selected;
    switch (a) {
      case "delete": if (m) { this.doc.remove(m.id); this.select(null); this.changed(); } break;
      case "duplicate": if (m) { const d = duplicate(m, 12 * this.ppp); this.doc.add(d); this.select(d.id); this.changed(); } break;
      case "front": if (m) { this.doc.reorder(m.id, true); this.changed(); } break;
      case "back": if (m) { this.doc.reorder(m.id, false); this.changed(); } break;
      case "undo": this.commitText(); this.doc.undo(); this.select(null); this.changed(); break;
      case "redo": this.commitText(); this.doc.redo(); this.select(null); this.changed(); break;
      case "copy": await this.finish(true, false); break;
      case "path": await this.finish(false, true); break;
      case "save": await this.saveCopy(); break;
      case "trash": await this.trash(); break;
    }
  }

  nudge(dx: number, dy: number) {
    const m = this.selected;
    if (!m) return;
    this.doc.update(offset(m, dx * this.ppp, dy * this.ppp));
    this.changed();
  }

  key(e: KeyboardEvent) {
    if (this.input || (e.target as HTMLElement).tagName === "INPUT") return;
    const ctrl = e.ctrlKey || e.metaKey;
    const k = e.key.toLowerCase();
    const done = () => { e.preventDefault(); return; };
    if (ctrl) {
      if (k === "z") return done(), this.action(e.shiftKey ? "redo" : "undo");
      if (k === "y") return done(), this.action("redo");
      if (k === "c") return done(), this.action(e.shiftKey ? "path" : "copy");
      if (k === "s") return done(), this.action("save");
      if (k === "d") return done(), this.action("duplicate");
      if (k === "]") return done(), this.action("front");
      if (k === "[") return done(), this.action("back");
      if (k === "backspace" || k === "delete") return done(), this.action("trash");
      return;
    }
    if (e.altKey) return;
    const step = e.shiftKey ? 10 : 1;
    switch (e.key) {
      case "Enter": return done(), this.action("copy");
      case "Escape":
        // Esc steps back one level at a time: drawing tool → Select → no selection → copy and close.
        done();
        if (this.tool !== "select") this.setTool("select");
        else if (this.selectedId) { this.select(null); this.draw(); }
        else this.action("copy");
        return;
      case "Delete": case "Backspace": return done(), this.action("delete");
      case "ArrowLeft": return done(), this.nudge(-step, 0);
      case "ArrowRight": return done(), this.nudge(step, 0);
      case "ArrowUp": return done(), this.nudge(0, -step);
      case "ArrowDown": return done(), this.nudge(0, step);
      case "[": return done(), this.setSize(Math.max(1, this.size - 1) as StrokeSize);
      case "]": return done(), this.setSize(Math.min(3, this.size + 1) as StrokeSize);
    }
    const tool = (Object.entries(this.keys) as [Tool, string][]).find(([, key]) => key === k)?.[0];
    if (tool) return done(), this.setTool(tool);
    const n = Number(e.key);
    if (n >= 1 && n <= PALETTE.length) return done(), this.setColor(n - 1);
  }

  // MARK: Output

  async png(): Promise<Uint8Array> {
    const blob = await flatten(this.image, this.doc, this.border).convertToBlob({ type: "image/png" });
    return new Uint8Array(await blob.arrayBuffer());
  }

  /** Saves changes made since the last save and returns the file that now holds the image. */
  async saveEdits(): Promise<string | null> {
    this.commitText();
    if (this.doc.revision === this.savedRevision) return this.savedCopy ?? this.file;
    const revision = this.doc.revision;
    try {
      const target = this.savedCopy ?? (await api.outputPath(this.file, this.owns));
      const written = await api.savePng(target, await this.png());
      this.savedRevision = revision;
      if (!this.owns || written !== this.file) this.savedCopy = written;
      this.refresh();
      return written;
    } catch (err) {
      this.toast(`Snapmark couldn't save this image: ${err}`);
      return null;
    }
  }

  async finish(copyImage: boolean, copyPath: boolean) {
    if (this.finished) return;
    const path = await this.saveEdits();
    if (!path) return;
    try {
      if (copyImage) await api.copyPng(await this.png(), path);
      if (copyPath) await api.copyText(path);
    } catch (err) {
      this.toast(`Snapmark couldn't copy the image. It is saved at ${path}. (${err})`);
      return;
    }
    this.finished = true;
    await api.closeWindow();
  }

  async saveCopy() {
    const name = this.file.split(/[\\/]/).pop() ?? "Snapmark.png";
    const target = await api.saveDialog(name.replace(/\.\w+$/, "") + ".png");
    if (!target) return;
    try { await api.savePng(target, await this.png()); this.toast(`Saved ${target}`); }
    catch (err) { this.toast(`Snapmark couldn't save ${target}: ${err}`); }
  }

  async trash() {
    this.commitText();
    const target = this.owns ? this.file : this.savedCopy;
    const ok = await this.confirm(target ? `Move ${target.split(/[\\/]/).pop()} to the Trash?` : "Discard your annotations?",
      this.owns ? "You can restore it from the Trash." : "The original image is not touched.",
      [target ? "Move to Trash" : "Discard", "Cancel"]);
    if (ok !== 0) return;
    if (target) {
      try { await api.trash(target); } catch (err) { this.toast(`Couldn't move it to the Trash: ${err}`); return; }
    }
    this.finished = true;
    await api.closeWindow();
  }

  async closeAsking() {
    this.commitText();
    const choice = await this.confirm("Keep your annotations?",
      this.owns ? "The capture is already saved; this only affects your edits." : "Edits are saved as a copy next to the original.",
      ["Save", "Discard", "Cancel"]);
    if (choice === 2 || choice === -1) return;
    if (choice === 0 && !(await this.saveEdits())) return;
    if (choice === 1 && this.owns && this.savedRevision !== 0) {
      // Put an owned capture back to the clean original if an earlier save wrote marks into it.
      const clean = new OffscreenCanvas(this.image.width, this.image.height);
      clean.getContext("2d")!.drawImage(this.image, 0, 0);
      const blob = await clean.convertToBlob({ type: "image/png" });
      await api.savePng(this.file, new Uint8Array(await blob.arrayBuffer()));
    }
    this.finished = true;
    await api.closeWindow();
  }

  /** A small in-window dialog; resolves to the index of the chosen button, or -1 on Esc. */
  confirm(title: string, detail: string, choices: string[]): Promise<number> {
    return new Promise((resolve) => {
      const m = document.createElement("div");
      m.className = "menu";
      Object.assign(m.style, { left: "50%", top: "30%", transform: "translateX(-50%)", padding: "16px", width: "340px" });
      m.innerHTML = `<b>${escapeHtml(title)}</b><p class="note">${escapeHtml(detail)}</p><div class="row" style="justify-content:flex-end"></div>`;
      const row = m.querySelector(".row")!;
      choices.forEach((c, i) => {
        const b = document.createElement("button");
        b.className = i === 0 ? "primary" : "btn";
        b.textContent = c;
        b.onclick = () => { m.remove(); window.removeEventListener("keydown", esc, true); resolve(i); };
        row.append(b);
      });
      const esc = (e: KeyboardEvent) => {
        if (e.key === "Escape") { e.stopPropagation(); m.remove(); window.removeEventListener("keydown", esc, true); resolve(-1); }
      };
      window.addEventListener("keydown", esc, true);
      document.body.append(m);
      (row.firstElementChild as HTMLElement)?.focus();
    });
  }

  toast(text: string) {
    const t = document.createElement("div");
    t.className = "toast";
    t.textContent = text;
    this.stage.append(t);
    setTimeout(() => t.remove(), 4000);
  }

  // MARK: State

  changed() {
    this.draw();
    this.refresh();
  }

  refresh() {
    for (const t of TOOLS) this.buttons[`tool:${t.tool}`]?.setAttribute("aria-pressed", String(t.tool === this.tool));
    PALETTE.forEach((_, i) => this.buttons[`color:${i}`]?.setAttribute("aria-pressed", String(i === this.colorIndex)));
    for (const s of [1, 2, 3]) this.buttons[`size:${s}`]?.setAttribute("aria-pressed", String(s === this.size));
    this.buttons.delete.disabled = !this.selected;
    this.buttons.undo.disabled = !this.doc.canUndo;
    this.buttons.redo.disabled = !this.doc.canRedo;
    const where = this.savedCopy ?? this.file;
    this.status.textContent = !this.owns && !this.savedCopy ? "Edits will be saved next to the original"
      : this.doc.revision !== this.savedRevision ? `Unsaved edits · ${where}` : `Saved to ${where}`;
  }
}

const rectOf = (m: Mark): Rect => ({
  x: Math.min(m.start.x, m.end.x), y: Math.min(m.start.y, m.end.y),
  w: Math.abs(m.end.x - m.start.x), h: Math.abs(m.end.y - m.start.y),
});

const escapeHtml = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);
