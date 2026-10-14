// The annotation editor for Windows and Linux. Same behavior as the macOS editor: a new mark is
// selected as soon as it is drawn, selected shapes show resize handles, Esc steps back one level
// (tool → Select → no selection → copy and close), and marks past the edge grow the canvas. An
// arrow's middle handle bends it; double-clicking an arrow's end adds a label it points at, and
// double-clicking along it labels its middle. The pen draws freehand (with a tablet's pressure);
// holding still at the end of a stroke turns it into the line, box or ellipse it was meant to be.
import { api } from "./api";
import { icon } from "./icons";
import {
  Doc, Geometry, LINE_HEIGHT, PAD_X, PAD_Y, PALETTE, Snap, TOOLS, calloutAnchor, css, curveBounds, duplicate, endNear, inset, mark,
  markFontSize, markHandles, midpoint, moveMarkHandle, pinned, rewrapped, styled, type Binding, type Guide, type RGBA, union,
  intersection, inkShape, markRect, stroke,
  moveHandle, offset, strokeWidth, textOrStepRect, type Mark, type Point, type Rect, type StrokeSize, type Tool,
} from "./core/model";
import { FONT, drawBackground, drawMark, edges, flatten, ink, type Edges } from "./core/render";
import { resolveToolKeys } from "./core/settings";

export async function startEditor(root: HTMLElement, file: string, owns: boolean) {
  const bytes = await api.readFile(file);
  const image = await createImageBitmap(new Blob([bytes]));
  const probe = new OffscreenCanvas(image.width, image.height).getContext("2d")!;
  probe.drawImage(image, 0, 0);
  // Captures are taken at this screen's scale; it is the best guess for an opened image too.
  const border = edges(probe.getImageData(0, 0, image.width, image.height), window.devicePixelRatio || 1);
  const measureCtx = new OffscreenCanvas(1, 1).getContext("2d")!;
  const measure = (t: string, s: number) => { measureCtx.font = FONT(s); return measureCtx.measureText(t).width; };
  const doc = new Doc(image.width, image.height, measure);
  const keys = resolveToolKeys((await api.getConfig()).toolKeys);
  new Editor(root, file, owns, doc, image, border, keys);
}

class Editor {
  tool: Tool = "select";
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
  /** How far a drag may widen the frozen view. */
  dragLimit: Rect | null = null;
  input: HTMLTextAreaElement | null = null;
  editingId: string | null = null;
  textAt: Point = { x: 0, y: 0 };
  textFontSize: number | undefined;
  textWidth: number | undefined;
  /** Keeps the label being typed on a spot: the point, and where on the label's box it sits. */
  textPin: { at: Point; anchor: Point } | null = null;
  /** The arrow end a new label is for, attached to it when the label is committed. */
  callout: { arrow: string; end: number } | null = null;
  /** The color a new label takes when it is not the current color: a callout's arrow's color. */
  textColor: RGBA | null = null;
  /** Snap guides to draw while dragging. */
  guides: Guide[] = [];
  /** The mark an arrow end being dragged would attach to, outlined as a drop target. */
  bindTarget: string | null = null;
  /** The style Ctrl+Alt+C copied, which Ctrl+Alt+V puts on the selection and on new marks. */
  copiedStyle: Mark | null = null;
  /** A box being dragged with the Text tool to place and size a new label. */
  textBox: Rect | null = null;
  /** A label pressed with the Text tool: released in place it opens for editing, dragged it moves. */
  pressedLabel: Mark | null = null;
  savedRevision = 0;
  savedCopy: string | null = null;
  finished = false;
  /** Set while finishing, so a second Enter can't save and copy twice. */
  finishing = false;
  /** Set while a confirm dialog is open; the editor's keys stay out of its way. */
  modal = false;

  stage!: HTMLElement;
  canvas!: HTMLCanvasElement;
  status!: HTMLElement;
  buttons: Record<string, HTMLButtonElement> = {};

  constructor(private root: HTMLElement, private file: string, private owns: boolean, private doc: Doc,
              private image: ImageBitmap, private border: Edges,
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
        <div class="toolbar" role="toolbar" aria-label="Annotation tools">
          <div class="group">${tools}</div>
          <div class="sep"></div>
          <div class="swatches">${colors}</div>
          <div class="sep"></div>
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
    // Arrows attached to a mark being dragged follow it live.
    if (this.live) marks = this.doc.resolveBindings(marks);
    const canvas = this.doc.canvasIncluding(marks);

    ctx.save();
    ctx.shadowColor = "rgba(0,0,0,0.35)";
    ctx.shadowBlur = 14 * this.ppp * s;
    ctx.shadowOffsetY = 2 * this.ppp * s;
    ctx.fillStyle = css(this.border.color.a === 0 ? { r: 1, g: 1, b: 1, a: 1 } : this.border.color);
    ctx.fillRect(canvas.x, canvas.y, canvas.w, canvas.h);
    ctx.restore();
    drawBackground(ctx, this.image, this.doc, canvas, this.border);
    for (const m of marks) {
      // An arrow whose label is open shows the editor in place of its label.
      if (m.id !== this.editingId) drawMark(ctx, m, this.doc.width);
      else if (m.tool === "arrow") drawMark(ctx, { ...m, text: "" }, this.doc.width);
    }

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
    if (this.guides.length) {
      ctx.save();
      ctx.strokeStyle = "rgb(250,77,140)";
      ctx.lineWidth = this.ppp;
      ctx.beginPath();
      for (const g of this.guides) {
        ctx.moveTo(g.vertical ? g.at : g.from, g.vertical ? g.from : g.at);
        ctx.lineTo(g.vertical ? g.at : g.to, g.vertical ? g.to : g.at);
      }
      ctx.stroke();
      ctx.restore();
    }
    if (this.textBox) {
      const b = this.textBox;
      ctx.save();
      ctx.strokeStyle = css(this.color);
      ctx.lineWidth = 1.5 * this.ppp;
      ctx.setLineDash([5 * this.ppp, 3 * this.ppp]);
      ctx.strokeRect(b.x, b.y, b.w, b.h);
      ctx.restore();
    }

    const outline = (m: Mark) => {
      const r = m.tool === "text" || m.tool === "step" ? textOrStepRect(m, this.doc.width, this.doc.measure)
        : m.tool === "arrow" ? curveBounds(m) : markRect(m);
      return inset(r, -(4 * this.ppp + strokeWidth(m.size, this.doc.width) / 2));
    };
    ctx.lineWidth = 1.5 * this.ppp;
    const hover = marks.find((m) => m.id === this.hoverId && m.id !== this.selectedId);
    if (hover) {
      const r = outline(hover);
      ctx.strokeStyle = "rgba(59,130,246,0.5)";
      ctx.strokeRect(r.x, r.y, r.w, r.h);
    }
    const target = marks.find((m) => m.id === this.bindTarget);
    if (target) {
      const r = outline(target);
      ctx.save();
      ctx.strokeStyle = "#3b82f6";
      ctx.lineWidth = 2.5 * this.ppp;
      ctx.strokeRect(r.x, r.y, r.w, r.h);
      ctx.restore();
    }
    const sel = marks.find((m) => m.id === this.selectedId && m.id !== this.editingId);
    if (sel) {
      ctx.strokeStyle = "#3b82f6";
      if (sel.tool !== "arrow") { const r = outline(sel); ctx.strokeRect(r.x, r.y, r.w, r.h); }
      const side = 8 * this.ppp;
      for (const h of this.handlesOf(sel)) {
        ctx.beginPath();
        ctx.arc(h.x, h.y, side / 2, 0, Math.PI * 2);
        ctx.fillStyle = "#fff";
        ctx.fill();
        ctx.stroke();
      }
    }
  }

  // MARK: Pointer

  handlesOf(m: Mark): Point[] { return markHandles(m, this.doc.width, this.doc.measure); }

  moveHandleOf(m: Mark, i: number, p: Point): Mark {
    return moveMarkHandle(m, i, p, this.doc.width, this.doc.measure);
  }

  /** The box a mark lines up by when snapping. */
  snapRect(m: Mark): Rect { return this.doc.bindableRect(m) ?? markRect(m); }

  /** `p` lined up with the image and the other marks, unless Ctrl is held. Updates the guides. */
  snapped(p: Point, e: PointerEvent, excluding: string[]): Point {
    if (e.ctrlKey || e.metaKey) { this.guides = []; return p; }
    const r = Snap.point(p, this.doc.snapTargets(new Set(excluding)), 6 * this.ppp);
    this.guides = r.guides;
    return r.p;
  }

  /** Where an arrow end at `p` attaches: the mark under it, outlined while dragging. */
  bindAt(p: Point, arrow: string): Binding | null {
    const b = this.doc.bindingAt(p, 2 * this.ppp, arrow);
    this.bindTarget = b?.id ?? null;
    return b;
  }

  handleAt(p: Point): number | null {
    const m = this.live ?? this.selected;
    if (!m) return null;
    const i = this.handlesOf(m).findIndex((h) => Math.hypot(h.x - p.x, h.y - p.y) <= 7 * this.ppp);
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
      this.dragLimit = inset(this.frozen, -0.5 * Math.max(this.doc.width, this.doc.height));
      const p = this.toImage(e);
      const tol = 8 * this.ppp;
      const clicks = this.countClick(p);
      if (clicks === 2 && this.tool !== "step" && this.tool !== "crop" && this.tool !== "pen" && this.labelArrow(p)) { this.draw(); return; }
      const h = this.handleAt(p);
      if (h !== null && this.selected) { this.dragHandle = h; this.live = this.selected; return; }
      switch (this.tool) {
        case "select": {
          const hit = this.doc.hitTest(p, tol);
          this.select(hit?.id ?? null);
          if (hit) {
            this.dragOrigin = p;
            if (clicks === 2 && hit.tool === "text") this.beginText(hit.start, hit);
          }
          break;
        }
        case "text": {
          const hit = this.doc.hitTest(p, tol);
          this.dragOrigin = p;
          if (hit?.tool === "text") { this.select(hit.id); this.pressedLabel = hit; }
          else { this.select(null); this.textBox = { x: p.x, y: p.y, w: 0, h: 0 }; }
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
        case "pen":
          this.select(null);
          this.draft = stroke([p], this.color, this.size, e.pointerType === "pen" ? [e.pressure] : undefined);
          this.penSnap = "none";
          this.restartPenHold(p);
          break;
        default: {
          this.select(null);
          const start = this.tool === "arrow" ? p : this.snapped(p, e, []);
          this.guides = [];
          this.draft = mark(this.tool, this.color, start, start, { size: this.size });
          if (this.tool === "arrow") {
            const b = this.doc.bindingAt(p, 2 * this.ppp, null);
            if (b) this.draft.startBinding = b;
          }
        }
      }
      this.draw();
    });

    c.addEventListener("pointermove", (e) => {
      let p = this.toImage(e);
      if (!c.hasPointerCapture(e.pointerId)) {
        const onHandle = this.handleAt(p) !== null;
        let hit = (this.tool === "select" || this.tool === "text") && !onHandle ? this.doc.hitTest(p, 6 * this.ppp) : undefined;
        if (this.tool === "text" && hit?.tool !== "text") hit = undefined;
        if ((hit?.id ?? null) !== this.hoverId) { this.hoverId = hit?.id ?? null; this.draw(); }
        c.style.cursor = onHandle ? "nwse-resize" : this.tool === "select" ? (hit ? "grab" : "default")
          : this.tool === "text" ? (hit ? "grab" : "text") : "crosshair";
        return;
      }
      if (this.dragHandle === 2 && this.live?.tool === "arrow") {
        // The middle handle bends the arrow. Close to straight snaps straight, so a curve can be undone.
        const base = this.selected ?? this.live;
        const bent = this.moveHandleOf(base, 2, p);
        if (Math.abs(bent.bend ?? 0) < 6 * this.ppp) delete bent.bend;
        this.guides = [];
        this.live = bent;
      } else if (this.dragHandle !== null && this.live) {
        const base = this.selected ?? this.live;
        if (e.shiftKey) { this.guides = []; this.bindTarget = null; }
        if (e.shiftKey && base.tool !== "text") {
          const fixed = base.tool === "arrow" ? (this.dragHandle === 0 ? base.end : base.start)
            : moveHandle(base, this.dragHandle, p).start;
          p = base.tool === "arrow" ? Geometry.snap45(fixed, p) : Geometry.square(fixed, p);
        }
        if (base.tool === "arrow") {
          // An arrow end attaches to the mark it's dropped on; elsewhere it snaps.
          const b = e.shiftKey ? null : this.bindAt(p, base.id);
          if (!b && !e.shiftKey) p = this.snapped(p, e, [base.id]); else this.guides = [];
          const m = this.moveHandleOf(base, this.dragHandle, p);
          const key = this.dragHandle === 0 ? "startBinding" : "endBinding";
          if (b) m[key] = b; else delete m[key];
          this.live = m;
        } else {
          if (base.tool !== "text" && !e.shiftKey) p = this.snapped(p, e, [base.id]);
          this.live = this.moveHandleOf(base, this.dragHandle, p);
        }
      } else if (this.textBox && this.dragOrigin) {
        p = this.snapped(p, e, []);
        const o = this.dragOrigin;
        this.textBox = { x: Math.min(o.x, p.x), y: Math.min(o.y, p.y), w: Math.abs(p.x - o.x), h: Math.abs(p.y - o.y) };
      } else if ((this.tool === "select" || this.tool === "text") && !this.live && this.dragOrigin
                 && Math.hypot(p.x - this.dragOrigin.x, p.y - this.dragOrigin.y) < 3 * this.ppp) {
        // A mark only starts to move past a few points, so a slightly shaky click doesn't nudge it,
        // snap it or let go of an arrow's attachments (and a pressed label still opens for editing).
        return;
      } else if ((this.tool === "select" || this.tool === "text") && this.dragOrigin && this.selected) {
        c.style.cursor = "grabbing";
        let moved = offset(this.selected, p.x - this.dragOrigin.x, p.y - this.dragOrigin.y);
        if (e.ctrlKey || e.metaKey) this.guides = [];
        else {
          const snap = Snap.move(this.snapRect(moved), this.doc.snapTargets(new Set([this.selected.id])), 6 * this.ppp);
          moved = offset(moved, snap.dx, snap.dy);
          this.guides = snap.guides;
        }
        this.live = moved;
      } else if (this.tool === "crop" && this.dragOrigin) {
        const o = this.dragOrigin;
        this.cropDraft = { x: Math.min(o.x, p.x), y: Math.min(o.y, p.y), w: Math.abs(p.x - o.x), h: Math.abs(p.y - o.y) };
      } else if (this.draft && this.tool === "pen") {
        // Tablets report more points than events; take them all for a smooth line.
        const events = e.getCoalescedEvents?.() ?? [];
        for (const ev of events.length ? events : [e]) this.drawPen(this.toImage(ev), ev);
      } else if (this.draft) {
        const d: Mark = { ...this.draft };
        if (d.tool === "arrow") {
          const b = e.shiftKey ? null : this.bindAt(p, d.id);
          if (b) { d.endBinding = b; this.guides = []; } else { delete d.endBinding; this.bindTarget = null; }
        }
        if (e.shiftKey) { p = d.tool === "arrow" ? Geometry.snap45(d.start, p) : Geometry.square(d.start, p); this.guides = []; }
        else if (!d.endBinding) p = this.snapped(p, e, []);
        this.draft = { ...d, end: p };
      }
      this.followDrag(e);
      this.draw();
    });

    // A cancelled pointer (the system took over a pen or touch) ends the drag like a release, so a
    // stroke is kept rather than left hanging.
    const release = () => {
      const pressed = this.pressedLabel, box = this.textBox;
      this.pressedLabel = null;
      this.textBox = null;
      this.guides = [];
      this.bindTarget = null;
      if (this.live) {
        this.doc.update(this.live);
        this.live = null;
        this.changed();
      } else if (pressed && this.doc.marks.some((m) => m.id === pressed.id)) {
        const current = this.doc.marks.find((m) => m.id === pressed.id)!;
        this.beginText(current.start, current);
      } else if (box) {
        // A drag sets the width the label wraps at, from its top-left corner; a click starts a
        // label that grows with its text, centered on the click.
        const font = markFontSize(mark("text", this.color, box, box, { size: this.size }), this.doc.width);
        if (box.w > 12 * this.ppp) this.beginText({ x: box.x, y: box.y }, null, Math.max(font * 1.5, box.w - font * PAD_X * 2));
        else this.beginText({ x: box.x, y: box.y - font * (LINE_HEIGHT + PAD_Y) / 2 }, null);
      } else if (this.tool === "crop" && this.cropDraft) {
        const d = this.cropDraft;
        if (d.w >= 4 * this.ppp && d.h >= 4 * this.ppp) this.doc.setCrop(d);
        this.cropDraft = null;
        this.changed();
      } else if (this.draft && this.tool === "pen") {
        // A stroke stays unselected, so writing doesn't flash an outline after every line.
        this.endPenHold();
        this.doc.add(this.draft);
        this.draft = null;
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
    };
    c.addEventListener("pointerup", release);
    c.addEventListener("pointercancel", release);

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
        this.commitText();
        if (this.finished || this.doc.revision === this.savedRevision) return;
        e.preventDefault();
        await this.closeAsking();
      })).catch(() => {});
  }

  /** The press before this one, to count double-clicks: pointer events don't reliably carry a count. */
  lastPress: { at: Point; time: number; count: number } | null = null;

  /** 2 for the second press of a double-click (close in time and place), else 1. */
  countClick(p: Point): number {
    const now = performance.now(), last = this.lastPress;
    const count = last && last.count === 1 && now - last.time < 450 && Math.hypot(p.x - last.at.x, p.y - last.at.y) < 6 * this.ppp ? 2 : 1;
    this.lastPress = { at: p, time: now, count };
    return count;
  }

  /** Widens the frozen view when a drag reaches past it, so a mark drawn off the edge stays in sight.
   *  Only while the pointer is inside the view: outside, every widening would map it further out and
   *  widen again. It also stops at half the image's size past where the drag began. */
  followDrag(e: PointerEvent) {
    const v = this.canvas.getBoundingClientRect();
    if (!this.frozen || !this.dragLimit || e.clientX < v.left || e.clientX > v.right || e.clientY < v.top || e.clientY > v.bottom) return;
    let marks = this.doc.marks;
    if (this.live) marks = marks.map((m) => (m.id === this.live!.id ? this.live! : m));
    if (this.draft) marks = [...marks, this.draft];
    const c = this.doc.canvasIncluding(this.doc.resolveBindings(marks)), f = this.frozen;
    if (c.x >= f.x && c.y >= f.y && c.x + c.w <= f.x + f.w && c.y + c.h <= f.y + f.h) return;
    this.frozen = intersection(union(f, inset(c, -0.07 * Math.max(this.doc.width, this.doc.height))), this.dragLimit) ?? f;
  }

  // MARK: Pen

  /** Fires when the pen holds still mid-stroke, to turn the stroke into a shape. */
  penHold: number | null = null;
  /** Where the pen last moved enough to restart the hold. */
  penHoldAnchor: Point = { x: 0, y: 0 };
  /** What a held stroke became: a line whose end still follows the pen, or a shape that stays put. */
  penSnap: "none" | "line" | "shape" = "none";

  /** Adds `p` to the stroke being drawn, or moves the end of a stroke that became a line. */
  drawPen(p: Point, e: PointerEvent) {
    const d = this.draft;
    if (!d || this.penSnap === "shape") return;
    if (this.penSnap === "line") { this.draft = { ...d, points: [d.points![0], p], end: p }; return; }
    const pts = d.points!, last = pts[pts.length - 1];
    if (Math.hypot(p.x - last.x, p.y - last.y) < this.ppp) return;
    const next: Mark = { ...d, points: [...pts, p], end: p };
    if (d.pressures) next.pressures = [...d.pressures, e.pressure];
    this.draft = next;
    // Small shakes don't count as moving, so a hand holding still on a tablet still holds.
    if (Math.hypot(p.x - this.penHoldAnchor.x, p.y - this.penHoldAnchor.y) > 3 * this.ppp) this.restartPenHold(p);
  }

  restartPenHold(p: Point) {
    this.penHoldAnchor = p;
    if (this.penHold !== null) clearTimeout(this.penHold);
    this.penHold = window.setTimeout(() => this.penHeld(), 500);
  }

  endPenHold() {
    if (this.penHold !== null) clearTimeout(this.penHold);
    this.penHold = null;
    this.penSnap = "none";
  }

  /** The pen held still: the stroke becomes the shape it looks like, if any. */
  penHeld() {
    const d = this.draft;
    if (!d || d.tool !== "pen" || this.penSnap !== "none") return;
    const shape = inkShape(d.points ?? []);
    if (!shape) return;
    if (shape.kind === "line") {
      this.draft = stroke([shape.a, shape.b], d.color, d.size);
      this.penSnap = "line";
    } else {
      const r = shape.rect;
      this.draft = mark(shape.kind, d.color, { x: r.x, y: r.y }, { x: r.x + r.w, y: r.y + r.h }, { size: d.size });
      this.penSnap = "shape";
    }
    this.draw();
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

  /** Double-clicking an arrow labels it. Near a free end it opens a new label for that end, which the
   *  arrow then points at; near an end that already points at a label, that label. Anywhere else
   *  along it (or near an end attached to a shape), the label in its middle. Returns false when the
   *  topmost mark under `p` is not an arrow, so a label or shape there keeps its own double-click. */
  labelArrow(p: Point): boolean {
    const arrow = this.doc.hitTest(p, 8 * this.ppp);
    if (arrow?.tool !== "arrow") return false;
    const end = endNear(arrow, p, 10 * this.ppp);
    if (end !== null) {
      const id = (end === 0 ? arrow.startBinding : arrow.endBinding)?.id;
      const bound = this.doc.marks.find((m) => m.id === id);
      if (bound?.tool === "text") { this.select(bound.id); this.beginText(bound.start, bound); return true; }
      if (!bound) {
        this.select(null);
        this.callout = { arrow: arrow.id, end };
        this.textPin = { at: end === 0 ? arrow.start : arrow.end, anchor: calloutAnchor(arrow, end) };
        this.textColor = arrow.color;
        this.beginText({ x: 0, y: 0 }, null);
        return true;
      }
    }
    this.select(arrow.id);
    this.beginText({ x: 0, y: 0 }, arrow);
    return true;
  }

  /** The label being edited, as it would be with `text`. An arrow's label sits on its middle. */
  editingMark(text: string): Mark {
    const base = this.doc.marks.find((m) => m.id === this.editingId);
    const m = mark("text", base?.color ?? this.textColor ?? this.color, this.textAt, this.textAt,
                   { size: base?.size ?? this.size, text, fontSize: this.textFontSize, textWidth: this.textWidth });
    const pin = base?.tool === "arrow" ? { at: midpoint(base), anchor: { x: 0.5, y: 0.5 } } : this.textPin;
    return pin ? pinned(m, pin.at, pin.anchor, this.doc.width, this.doc.measure) : m;
  }

  /** Opens the label editor with its top-left corner at `at`. A `wrap` width makes it wrap. */
  beginText(at: Point, editing: Mark | null, wrap?: number) {
    this.textAt = at;
    this.textFontSize = editing?.fontSize;
    this.textWidth = editing?.textWidth ?? wrap;
    this.editingId = editing?.id ?? null;
    const size = markFontSize(this.editingMark(""), this.doc.width) * this.scale;
    const color = editing?.color ?? this.textColor ?? this.color;
    const input = document.createElement("textarea");
    input.className = "label-input";
    input.value = editing?.text ?? "";
    input.placeholder = "Type, then Enter";
    input.spellcheck = false;
    // The editor lays text out like the drawn label: the same font, padding, line height and wrap width.
    Object.assign(input.style, {
      font: FONT(size), lineHeight: `${size * LINE_HEIGHT}px`, padding: `${size * PAD_Y / 2}px ${size * PAD_X}px`,
      background: css(color, 0.92), color: css(ink(color)),
    });
    const fit = () => {
      const r = textOrStepRect(this.editingMark(input.value || input.placeholder), this.doc.width, this.doc.measure);
      const v = this.toView({ x: r.x, y: r.y });
      Object.assign(input.style, {
        left: `${v.x}px`, top: `${v.y}px`, height: `${r.h * this.scale}px`,
        width: `${r.w * this.scale + (this.textWidth === undefined ? 2 : 0)}px`,
      });
    };
    fit();
    input.addEventListener("input", fit);
    input.addEventListener("keydown", (e) => {
      e.stopPropagation();
      // Enter commits; Shift+Enter or Alt+Enter starts a new line.
      if (e.key === "Enter" && e.altKey) { e.preventDefault(); input.setRangeText("\n", input.selectionStart, input.selectionEnd, "end"); fit(); }
      else if (e.key === "Enter" && !e.shiftKey) { e.preventDefault(); this.commitText(); }
      if (e.key === "Escape") { e.preventDefault(); this.cancelText(); }
    });
    this.stage.append(input);
    input.focus();
    input.setSelectionRange(input.value.length, input.value.length);
    requestAnimationFrame(() => input.focus());
    this.input = input;
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
      // Clearing an arrow's label removes the label, not the arrow.
      if (!text && editing.tool !== "arrow") this.doc.remove(editing.id);
      else { this.doc.update({ ...editing, text }); this.select(editing.id); }
    } else if (text && !this.editingId) {
      // An open label that was undone meanwhile has nothing to update.
      const label = this.editingMark(text);
      const m = this.callout && this.textPin
        ? this.doc.addCallout(label, this.callout.arrow, this.callout.end, this.textPin.anchor)
        : this.doc.add(label);
      this.select(m.id);
    }
    this.editingId = null;
    this.resetLabelPlacement();
    this.changed();
  }

  resetLabelPlacement() {
    this.textPin = null;
    this.callout = null;
    this.textColor = null;
  }

  cancelText() {
    this.input?.remove();
    this.input = null;
    this.editingId = null;
    this.resetLabelPlacement();
    this.draw();
  }

  // MARK: Commands

  select(id: string | null) {
    this.selectedId = id;
    this.refresh();
  }

  setTool(t: Tool) {
    this.commitText();
    this.resetTextPress();
    // A mark mid-drag belongs to the tool that started it; switching drops it.
    this.endPenHold();
    this.draft = null;
    this.tool = t;
    this.select(null);
    this.draw();
  }

  /** Puts the copied style on the selection and on new marks. */
  pasteStyle() {
    const s = this.copiedStyle;
    if (!s) return;
    const i = PALETTE.findIndex((p) => css(p.color) === css(s.color));
    if (i >= 0) this.colorIndex = i;
    this.size = s.size;
    const m = this.selected;
    if (m) {
      this.doc.update(rewrapped(styled(m, s), m, this.doc.width));
      this.changed();
    }
    this.refresh();
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
    if (m?.tool === "text") {
      // A preset replaces a hand-set size, and the wrap width scales with it.
      const { fontSize: _f, ...rest } = m;
      this.doc.update(rewrapped({ ...rest, size: s }, m, this.doc.width));
      this.changed();
    } else if (m) { this.doc.update({ ...m, size: s }); this.changed(); }
    this.refresh();
  }

  async action(a: string) {
    const m = this.selected;
    switch (a) {
      case "delete": if (m) { this.doc.remove(m.id); this.select(null); this.changed(); } break;
      case "duplicate": if (m) { const d = duplicate(m, 12 * this.ppp); this.doc.add(d); this.select(d.id); this.changed(); } break;
      case "front": if (m) { this.doc.reorder(m.id, true); this.changed(); } break;
      case "back": if (m) { this.doc.reorder(m.id, false); this.changed(); } break;
      case "undo": this.commitText(); this.resetTextPress(); this.doc.undo(); this.select(null); this.changed(); break;
      case "redo": this.commitText(); this.resetTextPress(); this.doc.redo(); this.select(null); this.changed(); break;
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
    if (this.modal || this.input || ["INPUT", "TEXTAREA"].includes((e.target as HTMLElement).tagName)) return;
    const ctrl = e.ctrlKey || e.metaKey;
    const k = e.key.toLowerCase();
    const done = () => { e.preventDefault(); return; };
    if (ctrl && e.altKey && (e.code === "KeyC" || e.code === "KeyV")) {
      done();
      if (e.code === "KeyC") { if (this.selected) this.copiedStyle = this.selected; return; }
      return this.pasteStyle();
    }
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

  /** Forgets a Text-tool press in progress, so releasing it later does nothing. */
  resetTextPress() {
    this.pressedLabel = null;
    this.textBox = null;
    this.live = null;
    this.dragOrigin = null;
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
      this.toast(`Shotate couldn't save this image: ${err}`);
      return null;
    }
  }

  async finish(copyImage: boolean, copyPath: boolean) {
    if (this.finished || this.finishing) return;
    this.finishing = true;
    const path = await this.saveEdits();
    if (!path) { this.finishing = false; return; }
    try {
      if (copyImage) await api.copyPng(await this.png(), path);
      if (copyPath) await api.copyText(path);
    } catch (err) {
      this.finishing = false;
      this.toast(`Shotate couldn't copy the image. It is saved at ${path}. (${err})`);
      return;
    }
    this.finished = true;
    await api.closeWindow();
  }

  async saveCopy() {
    const name = this.file.split(/[\\/]/).pop() ?? "Shotate.png";
    const target = await api.saveDialog(name.replace(/\.\w+$/, "") + ".png");
    if (!target) return;
    try { await api.savePng(target, await this.png()); this.toast(`Saved ${target}`); }
    catch (err) { this.toast(`Shotate couldn't save ${target}: ${err}`); }
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
    this.modal = true;
    return new Promise((resolve) => {
      const settle = (i: number) => { this.modal = false; m.remove(); window.removeEventListener("keydown", esc, true); resolve(i); };
      const m = document.createElement("div");
      m.className = "dialog";
      m.setAttribute("role", "alertdialog");
      m.innerHTML = `<b>${escapeHtml(title)}</b><p class="note">${escapeHtml(detail)}</p><div class="actions"></div>`;
      const row = m.querySelector(".actions")!;
      choices.forEach((c, i) => {
        const b = document.createElement("button");
        b.className = i === 0 ? "primary" : "btn";
        b.textContent = c;
        b.onclick = () => settle(i);
        row.append(b);
      });
      const esc = (e: KeyboardEvent) => {
        if (e.key === "Escape") { e.stopPropagation(); settle(-1); }
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

const escapeHtml = (s: string) => s.replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" })[c]!);
