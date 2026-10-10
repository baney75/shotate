// The editable state of one screenshot, shared by the Windows and Linux editor. It mirrors the macOS
// app's SnapmarkCore (Swift) so both behave the same. Coordinates are image pixels with the origin
// at the top left (y grows downward), as the web canvas uses.

export type Tool = "select" | "arrow" | "box" | "ellipse" | "highlight" | "text" | "redact" | "step" | "crop";

export const TOOLS: { tool: Tool; title: string; key: string }[] = [
  { tool: "select", title: "Select", key: "v" },
  { tool: "arrow", title: "Arrow", key: "a" },
  { tool: "box", title: "Box", key: "r" },
  { tool: "ellipse", title: "Ellipse", key: "o" },
  { tool: "highlight", title: "Highlight", key: "h" },
  { tool: "text", title: "Text", key: "t" },
  { tool: "redact", title: "Redact", key: "b" },
  { tool: "step", title: "Step", key: "n" },
  { tool: "crop", title: "Crop", key: "c" },
];

export interface RGBA { r: number; g: number; b: number; a: number }
export const rgba = (r: number, g: number, b: number, a = 1): RGBA => ({ r, g, b, a });
export const css = (c: RGBA, alpha = c.a) =>
  `rgba(${Math.round(c.r * 255)}, ${Math.round(c.g * 255)}, ${Math.round(c.b * 255)}, ${alpha})`;

/** Readable on light and dark screenshots; the order matches keys 1-6. */
export const PALETTE: { name: string; color: RGBA }[] = [
  { name: "Red", color: rgba(0.91, 0.26, 0.29) },
  { name: "Amber", color: rgba(0.98, 0.75, 0.18) },
  { name: "Blue", color: rgba(0.3, 0.56, 0.98) },
  { name: "Green", color: rgba(0.27, 0.78, 0.47) },
  { name: "Purple", color: rgba(0.71, 0.45, 0.96) },
  { name: "White", color: rgba(1, 1, 1) },
];

export type StrokeSize = 1 | 2 | 3;

/** Scales with the image so marks look the same on small crops and full high-DPI screens. */
export function strokeWidth(size: StrokeSize, imageWidth: number): number {
  const base = Math.min(14, Math.max(4, imageWidth / 220));
  return base * [0.6, 1.0, 1.7][size - 1];
}

export function fontSize(size: StrokeSize, imageWidth: number): number {
  return Math.min(72, Math.max(22, imageWidth / 38)) * [0.8, 1.0, 1.35][size - 1];
}

export interface Point { x: number; y: number }
export interface Rect { x: number; y: number; w: number; h: number }

export const rectFrom = (a: Point, b: Point): Rect =>
  ({ x: Math.min(a.x, b.x), y: Math.min(a.y, b.y), w: Math.abs(b.x - a.x), h: Math.abs(b.y - a.y) });
export const inset = (r: Rect, d: number): Rect => ({ x: r.x + d, y: r.y + d, w: r.w - 2 * d, h: r.h - 2 * d });
export const contains = (r: Rect, p: Point) => p.x >= r.x && p.x <= r.x + r.w && p.y >= r.y && p.y <= r.y + r.h;
export const containsRect = (outer: Rect, r: Rect) =>
  r.x >= outer.x && r.y >= outer.y && r.x + r.w <= outer.x + outer.w && r.y + r.h <= outer.y + outer.h;
export function union(a: Rect, b: Rect): Rect {
  const x = Math.min(a.x, b.x), y = Math.min(a.y, b.y);
  return { x, y, w: Math.max(a.x + a.w, b.x + b.w) - x, h: Math.max(a.y + a.h, b.y + b.h) - y };
}
export function intersection(a: Rect, b: Rect): Rect | null {
  const x = Math.max(a.x, b.x), y = Math.max(a.y, b.y);
  const w = Math.min(a.x + a.w, b.x + b.w) - x, h = Math.min(a.y + a.h, b.y + b.h) - y;
  return w > 0 && h > 0 ? { x, y, w, h } : null;
}
export const integral = (r: Rect): Rect => {
  const x = Math.floor(r.x), y = Math.floor(r.y);
  return { x, y, w: Math.ceil(r.x + r.w) - x, h: Math.ceil(r.y + r.h) - y };
};

let nextId = 1;
export const newId = () => `m${nextId++}-${Math.random().toString(36).slice(2, 8)}`;

export interface Mark {
  id: string;
  tool: Tool;
  color: RGBA;
  size: StrokeSize;
  start: Point;
  end: Point;
  text: string;
  number: number;
  /** A label's font size in image pixels when it was sized by hand; unset follows `size`. */
  fontSize?: number;
  /** A label's wrapping width in image pixels (inside its padding); unset grows with the text. */
  textWidth?: number;
  /** The marks an arrow's ends are attached to. */
  startBinding?: Binding;
  endBinding?: Binding;
}

/** An arrow end attached to another mark: it follows that mark, at the same spot in its box. */
export interface Binding {
  id: string;
  /** Where in the target's box the end sits, as fractions of its width and height. */
  anchor: Point;
}

type MarkOpts = Partial<Pick<Mark, "size" | "text" | "number" | "id" | "fontSize" | "textWidth" | "startBinding" | "endBinding">>;

export function mark(tool: Tool, color: RGBA, start: Point, end: Point = start, opts: MarkOpts = {}): Mark {
  const m: Mark = { id: opts.id ?? newId(), tool, color, size: opts.size ?? 2, start, end, text: opts.text ?? "",
                    number: opts.number ?? 0 };
  for (const k of ["fontSize", "textWidth", "startBinding", "endBinding"] as const) if (opts[k]) (m as any)[k] = opts[k];
  return m;
}

/** The same mark with another's color and size (and, between labels, its text size). */
export function styled(m: Mark, o: Mark): Mark {
  const out: Mark = { ...m, color: o.color, size: o.size };
  if (m.tool === "text" && o.tool === "text") out.fontSize = o.fontSize;
  if (out.fontSize === undefined) delete out.fontSize;
  return out;
}

export const markRect = (m: Mark) => rectFrom(m.start, m.end);

/** The mark moved. A moved arrow lets go of what it was attached to. */
export function offset(m: Mark, dx: number, dy: number): Mark {
  const { startBinding: _s, endBinding: _e, ...rest } = m;
  return { ...rest, start: { x: m.start.x + dx, y: m.start.y + dy }, end: { x: m.end.x + dx, y: m.end.y + dy } };
}

/** Grab points for resizing: the two ends of an arrow, the four corners of a shape. */
export function handles(m: Mark): Point[] {
  switch (m.tool) {
    case "arrow": return [m.start, m.end];
    case "box": case "ellipse": case "highlight": case "redact":
      return [m.start, m.end, { x: m.start.x, y: m.end.y }, { x: m.end.x, y: m.start.y }];
    default: return [];
  }
}

/** The mark with handle `i` moved to `p`. A shape keeps the opposite corner fixed. */
export function moveHandle(m: Mark, i: number, p: Point): Mark {
  const h = handles(m);
  if (i < 0 || i >= h.length) return m;
  if (m.tool === "arrow") return i === 0 ? { ...m, start: p } : { ...m, end: p };
  const opposite = { x: h[i].x === m.start.x ? m.end.x : m.start.x, y: h[i].y === m.start.y ? m.end.y : m.start.y };
  return { ...m, start: opposite, end: p };
}

export function duplicate(m: Mark, d: number): Mark {
  return { ...offset(m, d, d), id: newId() };
}

export const Geometry = {
  /** Snap a drag end to 45-degree steps (Shift while drawing an arrow). */
  snap45(a: Point, b: Point): Point {
    const angle = Math.round(Math.atan2(b.y - a.y, b.x - a.x) / (Math.PI / 4)) * (Math.PI / 4);
    const len = Math.hypot(b.x - a.x, b.y - a.y);
    return { x: a.x + Math.cos(angle) * len, y: a.y + Math.sin(angle) * len };
  },
  /** Make a drag square (Shift while drawing a box or ellipse). */
  square(a: Point, b: Point): Point {
    const side = Math.max(Math.abs(b.x - a.x), Math.abs(b.y - a.y));
    return { x: a.x + (b.x >= a.x ? side : -side), y: a.y + (b.y >= a.y ? side : -side) };
  },
  segmentDistance(p: Point, a: Point, b: Point): number {
    const dx = b.x - a.x, dy = b.y - a.y, len2 = dx * dx + dy * dy;
    if (len2 === 0) return Math.hypot(p.x - a.x, p.y - a.y);
    const t = Math.max(0, Math.min(1, ((p.x - a.x) * dx + (p.y - a.y) * dy) / len2));
    return Math.hypot(p.x - (a.x + t * dx), p.y - (a.y + t * dy));
  },
  rectDistance(p: Point, r: Rect): number {
    const dx = Math.max(r.x - p.x, 0, p.x - (r.x + r.w));
    const dy = Math.max(r.y - p.y, 0, p.y - (r.y + r.h));
    return Math.hypot(dx, dy);
  },
};

/** Measures text width in pixels; the editor passes the canvas's, tests pass a fake. */
export type Measure = (text: string, size: number) => number;

/** The font size a text or step mark draws with: its own when sized by hand, else its preset. */
export const markFontSize = (m: Mark, imageWidth: number) => m.fontSize ?? fontSize(m.size, imageWidth);

/** A label's line height and the padding around its text, as multiples of the font size. */
export const LINE_HEIGHT = 1.25;
export const PAD_X = 0.45, PAD_Y = 0.27;

/** The lines a label draws: its own line breaks, plus word wrapping when it has a width. */
export function textLines(m: Mark, size: number, measure: Measure): string[] {
  const text = m.text || " ";
  const width = m.textWidth === undefined ? Infinity : Math.max(m.textWidth, size);
  const out: string[] = [];
  for (const para of text.split("\n")) {
    let line = "";
    for (const word of para.split(/(?<= )/)) {
      if (line && measure((line + word).trimEnd(), size) > width) { out.push(line.trimEnd()); line = ""; }
      // A word longer than the width breaks between characters.
      let w = word;
      while (!line && measure(w.trimEnd(), size) > width && w.length > 1) {
        let n = w.length - 1;
        while (n > 1 && measure(w.slice(0, n), size) > width) n--;
        out.push(w.slice(0, n));
        w = w.slice(n);
      }
      line += w;
    }
    out.push(line.trimEnd() || (para ? line : " "));
  }
  return out;
}

/** The label box for a text mark (its `start` is the top-left corner), or the disc for a step. */
export function textOrStepRect(m: Mark, imageWidth: number, measure: Measure): Rect {
  const size = markFontSize(m, imageWidth);
  if (m.tool === "step") {
    const r = size * 0.95;
    return { x: m.start.x - r, y: m.start.y - r, w: r * 2, h: r * 2 };
  }
  const lines = textLines(m, size, measure);
  const inner = m.textWidth === undefined ? Math.max(...lines.map((l) => measure(l, size))) : Math.max(m.textWidth, size);
  return { x: m.start.x, y: m.start.y, w: inner + size * PAD_X * 2, h: size * (LINE_HEIGHT * lines.length + PAD_Y) };
}

/** The label scaled so the bottom-right corner of its box follows `p`; the top-left corner stays put. */
export function resizeText(m: Mark, p: Point, imageWidth: number, measure: Measure): Mark {
  const r = textOrStepRect(m, imageWidth, measure);
  const scale = Math.max((p.x - r.x) / Math.max(r.w, 1), (p.y - r.y) / Math.max(r.h, 1));
  const old = markFontSize(m, imageWidth);
  const size = Math.min(Math.max(old * scale, 8), 600);
  const out: Mark = { ...m, fontSize: size };
  if (m.textWidth !== undefined) out.textWidth = m.textWidth * size / old;
  return out;
}

/** The label wrapping at the width that puts the right edge of its box at `x`. */
export function rewrapText(m: Mark, x: number, imageWidth: number): Mark {
  const size = markFontSize(m, imageWidth);
  return { ...m, textWidth: Math.max(size * 1.5, x - m.start.x - size * PAD_X * 2) };
}

/** A mark's grab points. A label has two: its bottom-right corner scales it, its right edge sets
 *  where it wraps. Shapes and arrows use `handles`. */
export function markHandles(m: Mark, imageWidth: number, measure: Measure): Point[] {
  if (m.tool !== "text") return handles(m);
  const r = textOrStepRect(m, imageWidth, measure);
  return [{ x: r.x + r.w, y: r.y + r.h }, { x: r.x + r.w, y: r.y + r.h / 2 }];
}

/** The mark with handle `i` (an index into `markHandles`) dragged to `p`. */
export function moveMarkHandle(m: Mark, i: number, p: Point, imageWidth: number, measure: Measure): Mark {
  if (m.tool !== "text") return moveHandle(m, i, p);
  return i === 0 ? resizeText(m, p, imageWidth, measure) : rewrapText(m, p.x, imageWidth);
}

/** Everything a mark paints, including stroke, arrowhead and shadow. */
export function extent(m: Mark, imageWidth: number, measure: Measure): Rect {
  const w = strokeWidth(m.size, imageWidth);
  if (m.tool === "text" || m.tool === "step") return inset(textOrStepRect(m, imageWidth, measure), -w);
  if (m.tool === "arrow") return inset(markRect(m), -Math.max(w * 4.5, 10));
  return inset(markRect(m), -w);
}

export function distance(p: Point, m: Mark, imageWidth: number, measure: Measure): number {
  const r = markRect(m);
  switch (m.tool) {
    case "arrow": return Geometry.segmentDistance(p, m.start, m.end);
    case "highlight": case "redact": return contains(r, p) ? 0 : Geometry.rectDistance(p, r);
    case "ellipse": {
      const a = Math.max(r.w / 2, 1), b = Math.max(r.h / 2, 1);
      const x = p.x - (r.x + r.w / 2), y = p.y - (r.y + r.h / 2);
      const f = (x * x) / (a * a) + (y * y) / (b * b) - 1;
      const g = Math.hypot(2 * x / (a * a), 2 * y / (b * b));
      return g > 0 ? Math.abs(f) / g : Math.min(a, b);
    }
    case "text": case "step": {
      const t = textOrStepRect(m, imageWidth, measure);
      return contains(t, p) ? 0 : Geometry.rectDistance(p, t);
    }
    default:
      if (contains(inset(r, -1), p)) {
        return Math.min(Math.abs(p.x - r.x), Math.abs(p.x - r.x - r.w), Math.abs(p.y - r.y), Math.abs(p.y - r.y - r.h));
      }
      return Geometry.rectDistance(p, r);
  }
}

type Snapshot = { marks: Mark[]; crop: Rect | null };

export class Doc {
  marks: Mark[] = [];
  crop: Rect | null = null;
  /** Bumps on every change, undo and redo, so callers can tell whether a saved copy is stale. */
  revision = 0;
  private undoStack: Snapshot[] = [];
  private redoStack: Snapshot[] = [];

  constructor(readonly width: number, readonly height: number, readonly measure: Measure) {}

  get bounds(): Rect { return { x: 0, y: 0, w: this.width, h: this.height }; }
  get isEdited() { return this.marks.length > 0 || this.crop !== null; }
  get canUndo() { return this.undoStack.length > 0; }
  get canRedo() { return this.redoStack.length > 0; }

  private checkpoint() {
    this.revision++;
    this.undoStack.push({ marks: this.marks, crop: this.crop });
    if (this.undoStack.length > 200) this.undoStack.shift();
    this.redoStack = [];
  }

  add(m: Mark) {
    this.checkpoint();
    const added = m.tool === "step" ? { ...m, number: this.nextStepNumber } : m;
    this.marks = this.resolveBindings([...this.marks, added]);
    return this.marks[this.marks.length - 1];
  }

  /** Replaces a mark. Arrows attached to it follow, in the same undo step. */
  update(m: Mark) {
    const i = this.marks.findIndex((x) => x.id === m.id);
    if (i < 0 || JSON.stringify(this.marks[i]) === JSON.stringify(m)) return;
    this.checkpoint();
    this.marks = this.resolveBindings(this.marks.map((x, j) => (j === i ? m : x)));
  }

  /** Removes a mark. Arrows attached to it stay where they are and let go. */
  remove(id: string) {
    if (!this.marks.some((m) => m.id === id)) return;
    this.checkpoint();
    this.marks = this.marks.filter((m) => m.id !== id).map((m) => {
      if (m.startBinding?.id !== id && m.endBinding?.id !== id) return m;
      const out = { ...m };
      if (out.startBinding?.id === id) delete out.startBinding;
      if (out.endBinding?.id === id) delete out.endBinding;
      return out;
    });
  }

  // Arrow bindings

  /** The box an arrow end can attach to, or null for marks that take no arrows. */
  bindableRect(m: Mark): Rect | null {
    switch (m.tool) {
      case "box": case "ellipse": case "highlight": case "redact": return markRect(m);
      case "text": case "step": return textOrStepRect(m, this.width, this.measure);
      default: return null;
    }
  }

  /** The attachment for an arrow end dropped at `p`: the topmost mark under it, other than `excluding`. */
  bindingAt(p: Point, tolerance: number, excluding: string | null, marks = this.marks): Binding | null {
    for (const m of [...marks].reverse()) {
      if (m.id === excluding) continue;
      const r = this.bindableRect(m);
      if (!r || r.w <= 0 || r.h <= 0 || !contains(inset(r, -tolerance), p)) continue;
      const clamp = (v: number) => Math.min(Math.max(v, 0), 1);
      return { id: m.id, anchor: { x: clamp((p.x - r.x) / r.w), y: clamp((p.y - r.y) / r.h) } };
    }
    return null;
  }

  /** The marks with every attached arrow end moved onto its target. Also used for live previews. */
  resolveBindings(marks: Mark[]): Mark[] {
    if (!marks.some((m) => m.startBinding || m.endBinding)) return marks;
    const rects = new Map(marks.map((m) => [m.id, this.bindableRect(m)]));
    const point = (b?: Binding) => {
      const r = b && rects.get(b.id);
      return r ? { x: r.x + b!.anchor.x * r.w, y: r.y + b!.anchor.y * r.h } : null;
    };
    return marks.map((m) => {
      const s = point(m.startBinding), e = point(m.endBinding);
      return s || e ? { ...m, start: s ?? m.start, end: e ?? m.end } : m;
    });
  }

  /** The boxes a dragged mark lines up with: the image and every other mark that has a box. */
  snapTargets(excluding: Set<string>, marks = this.marks): Rect[] {
    return [this.bounds, ...marks.filter((m) => !excluding.has(m.id)).map((m) => this.bindableRect(m)).filter((r): r is Rect => !!r)];
  }

  /** Moves a mark to the top (drawn last) or the bottom of the stack. */
  reorder(id: string, toFront: boolean) {
    const i = this.marks.findIndex((m) => m.id === id);
    if (i < 0 || this.marks.length < 2 || (toFront ? i === this.marks.length - 1 : i === 0)) return;
    this.checkpoint();
    const rest = this.marks.filter((m) => m.id !== id);
    this.marks = toFront ? [...rest, this.marks[i]] : [this.marks[i], ...rest];
  }

  setCrop(rect: Rect | null) {
    const clipped = rect ? intersection(integral(rect), this.canvas) : null;
    const value = clipped && clipped.w >= 4 && clipped.h >= 4 ? clipped : null;
    if (JSON.stringify(value) === JSON.stringify(this.crop)) return;
    this.checkpoint();
    this.crop = value;
  }

  undo() {
    const last = this.undoStack.pop();
    if (!last) return;
    this.revision++;
    this.redoStack.push({ marks: this.marks, crop: this.crop });
    ({ marks: this.marks, crop: this.crop } = last);
  }

  redo() {
    const next = this.redoStack.pop();
    if (!next) return;
    this.revision++;
    this.undoStack.push({ marks: this.marks, crop: this.crop });
    ({ marks: this.marks, crop: this.crop } = next);
  }

  get nextStepNumber() {
    return Math.max(0, ...this.marks.filter((m) => m.tool === "step").map((m) => m.number)) + 1;
  }

  /** The topmost mark under a point, using a tolerance in image pixels. */
  hitTest(p: Point, tolerance: number): Mark | undefined {
    return [...this.marks].reverse().find((m) => distance(p, m, this.width, this.measure) <= tolerance);
  }

  /** The image plus every mark that reaches past it, with a margin. Equal to `bounds` otherwise. */
  get canvas(): Rect { return this.canvasIncluding(this.marks); }

  canvasIncluding(marks: Mark[]): Rect {
    let r = this.bounds;
    for (const m of marks) {
      const e = extent(m, this.width, this.measure);
      if (!containsRect(this.bounds, e)) {
        const pad = Math.max(12, strokeWidth(m.size, this.width) * 2.5);
        r = union(r, inset(e, -pad));
      }
    }
    return integral(r);
  }

  /** The crop trimmed to the current canvas, or null when none is left. */
  get effectiveCrop(): Rect | null {
    const c = this.crop ? intersection(this.crop, this.canvas) : null;
    return c && c.w >= 4 && c.h >= 4 ? c : null;
  }
}

/** A snap guide: a vertical line at x = `at` (else horizontal at y = `at`), from `from` to `to` along it. */
export interface Guide { vertical: boolean; at: number; from: number; to: number }

/** Lining marks up with the image and with each other: an edge or center within a few pixels of
 *  another edge or center jumps to it, and a guide shows the match. */
export const Snap = {
  stops(r: Rect, vertical: boolean): number[] {
    return vertical ? [r.x, r.x + r.w / 2, r.x + r.w] : [r.y, r.y + r.h / 2, r.y + r.h];
  },
  best(own: number[], targets: Rect[], vertical: boolean, threshold: number): number {
    let best: number | null = null;
    for (const t of targets) {
      for (const a of Snap.stops(t, vertical)) {
        for (const b of own) if (Math.abs(a - b) <= threshold && Math.abs(a - b) < Math.abs(best ?? Infinity)) best = a - b;
      }
    }
    return best ?? 0;
  },
  guides(r: Rect, targets: Rect[]): Guide[] {
    const out: Guide[] = [];
    for (const vertical of [true, false]) {
      for (const t of targets) {
        for (const a of Snap.stops(t, vertical)) {
          if (!Snap.stops(r, vertical).some((v) => Math.abs(v - a) < 0.5)) continue;
          const from = vertical ? Math.min(r.y, t.y) : Math.min(r.x, t.x);
          const to = vertical ? Math.max(r.y + r.h, t.y + t.h) : Math.max(r.x + r.w, t.x + t.w);
          if (!out.some((g) => g.vertical === vertical && g.at === a && g.from === from && g.to === to)) out.push({ vertical, at: a, from, to });
        }
      }
    }
    return out;
  },
  /** How far to shift a box being moved so it lines up, and the guides to show. */
  move(r: Rect, targets: Rect[], threshold: number): { dx: number; dy: number; guides: Guide[] } {
    const dx = Snap.best(Snap.stops(r, true), targets, true, threshold);
    const dy = Snap.best(Snap.stops(r, false), targets, false, threshold);
    return { dx, dy, guides: Snap.guides({ ...r, x: r.x + dx, y: r.y + dy }, targets) };
  },
  /** A point being drawn or dragged (a corner or an arrow end), lined up, and the guides to show. */
  point(p: Point, targets: Rect[], threshold: number): { p: Point; guides: Guide[] } {
    const q = { x: p.x + Snap.best([p.x], targets, true, threshold), y: p.y + Snap.best([p.y], targets, false, threshold) };
    return { p: q, guides: Snap.guides({ x: q.x, y: q.y, w: 0, h: 0 }, targets) };
  },
};
