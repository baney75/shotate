// The editable state of one screenshot, shared by the Windows and Linux editor. It mirrors the macOS
// app's ShotateCore (Swift) so both behave the same. Coordinates are image pixels with the origin
// at the top left (y grows downward), as the web canvas uses.

export type Tool = "select" | "arrow" | "pen" | "box" | "ellipse" | "highlight" | "text" | "redact" | "step" | "crop";

export const TOOLS: { tool: Tool; title: string; key: string }[] = [
  { tool: "select", title: "Select", key: "v" },
  { tool: "arrow", title: "Arrow", key: "a" },
  { tool: "pen", title: "Pen", key: "p" },
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
  /** How far an arrow's middle sits off the straight line between its ends, in image pixels, to the
   *  left of the direction it points. Unset is straight. Kept relative so a curve keeps its shape
   *  when an attached end moves. */
  bend?: number;
  /** A pen stroke's points, in the order drawn. `start` and `end` are its first and last. */
  points?: Point[];
  /** A pen's pressure at each point (0-1) when drawn with a tablet; unset draws an even line. */
  pressures?: number[];
}

/** An arrow end attached to another mark: it follows that mark, at the same spot in its box. */
export interface Binding {
  id: string;
  /** Where in the target's box the end sits, as fractions of its width and height. */
  anchor: Point;
}

type MarkOpts = Partial<Pick<Mark, "size" | "text" | "number" | "id" | "fontSize" | "textWidth" | "startBinding" | "endBinding" | "bend">>;

export function mark(tool: Tool, color: RGBA, start: Point, end: Point = start, opts: MarkOpts = {}): Mark {
  const m: Mark = { id: opts.id ?? newId(), tool, color, size: opts.size ?? 2, start, end, text: opts.text ?? "",
                    number: opts.number ?? 0 };
  for (const k of ["fontSize", "textWidth", "startBinding", "endBinding", "bend"] as const) if (opts[k]) (m as any)[k] = opts[k];
  return m;
}

/** The same mark with another's color and size, and a label takes a label's text size. Use
 *  `rewrapped` afterwards so a wrapping label's width scales with its new font. */
export function styled(m: Mark, o: Mark): Mark {
  const out: Mark = { ...m, color: o.color, size: o.size };
  if (m.tool === "text") out.fontSize = o.tool === "text" ? o.fontSize : undefined;
  if (out.fontSize === undefined) delete out.fontSize;
  return out;
}

/** `next` with its wrap width scaled by how much its font grew from `old`, so it keeps its lines. */
export function rewrapped(next: Mark, old: Mark, imageWidth: number): Mark {
  if (next.textWidth === undefined) return next;
  return { ...next, textWidth: next.textWidth * markFontSize(next, imageWidth) / markFontSize(old, imageWidth) };
}

/** The box a mark covers; a pen stroke's is the box around its points. */
export function markRect(m: Mark): Rect {
  if (m.tool !== "pen" || !m.points?.length) return rectFrom(m.start, m.end);
  const xs = m.points.map((p) => p.x), ys = m.points.map((p) => p.y);
  const x = Math.min(...xs), y = Math.min(...ys);
  return { x, y, w: Math.max(...xs) - x, h: Math.max(...ys) - y };
}

/** A pen stroke through `points`. */
export function stroke(points: Point[], color: RGBA, size: StrokeSize, pressures?: number[]): Mark {
  const m = mark("pen", color, points[0], points[points.length - 1], { size });
  m.points = points;
  if (pressures?.length) m.pressures = pressures;
  return m;
}

/** The width a pen draws at a point with tablet pressure `p` (0-1): thin when light, a little past
 *  the stroke size when pressed hard. About the stroke size at a natural 0.6. */
export const penWidth = (w: number, p: number) => w * (0.25 + 1.25 * Math.min(Math.max(p, 0), 1));

/** The mark moved. A moved arrow lets go of what it was attached to. */
export function offset(m: Mark, dx: number, dy: number): Mark {
  const { startBinding: _s, endBinding: _e, ...rest } = m;
  const out: Mark = { ...rest, start: { x: m.start.x + dx, y: m.start.y + dy }, end: { x: m.end.x + dx, y: m.end.y + dy } };
  if (m.points) out.points = m.points.map((p) => ({ x: p.x + dx, y: p.y + dy }));
  return out;
}

// Arrow geometry: an arrow is a quadratic curve from `start` to `end` whose middle sits `bend`
// pixels off the chord.

/** The unit vector to the left of the chord, or zero for an arrow with no length. */
function normal(m: Mark): Point {
  const dx = m.end.x - m.start.x, dy = m.end.y - m.start.y, len = Math.hypot(dx, dy);
  return len > 0 ? { x: -dy / len, y: dx / len } : { x: 0, y: 0 };
}
const chordMidpoint = (m: Mark): Point => ({ x: (m.start.x + m.end.x) / 2, y: (m.start.y + m.end.y) / 2 });

/** The curve's control point. A quadratic passes halfway to its control point at its middle. */
export function control(m: Mark): Point {
  const n = normal(m), c = chordMidpoint(m), b = m.bend ?? 0;
  return { x: c.x + n.x * b * 2, y: c.y + n.y * b * 2 };
}

/** The point halfway along the arrow: where its label sits and where its curve handle is. */
export function midpoint(m: Mark): Point {
  const n = normal(m), c = chordMidpoint(m), b = m.bend ?? 0;
  return { x: c.x + n.x * b, y: c.y + n.y * b };
}

/** The point at `t` (0 at `start`, 1 at `end`) along the curve. */
export function pointAt(m: Mark, t: number): Point {
  const c = control(m), u = 1 - t;
  return { x: u * u * m.start.x + 2 * u * t * c.x + t * t * m.end.x, y: u * u * m.start.y + 2 * u * t * c.y + t * t * m.end.y };
}

/** The curve as a polyline, fine enough for hit testing and bounds. */
export function curvePoints(m: Mark): Point[] {
  return m.bend ? Array.from({ length: 33 }, (_, i) => pointAt(m, i / 32)) : [m.start, m.end];
}

/** The box around the arrow's line, curve included. */
export function curveBounds(m: Mark): Rect {
  const pts = curvePoints(m);
  const xs = pts.map((p) => p.x), ys = pts.map((p) => p.y);
  const x = Math.min(...xs), y = Math.min(...ys);
  return { x, y, w: Math.max(...xs) - x, h: Math.max(...ys) - y };
}

/** The bend that puts the arrow's middle at the point on the curve's axis nearest `p`. */
export function bendThrough(m: Mark, p: Point): number {
  const n = normal(m), c = chordMidpoint(m);
  return (p.x - c.x) * n.x + (p.y - c.y) * n.y;
}

/** The `t` at which the curve is `distance` from its start (or, with `fromEnd`, from its tip), in a
 *  straight line. Halving the interval is exact enough at any length; the far end when shorter. */
export function parameterAt(m: Mark, distance: number, fromEnd: boolean): number {
  const anchor = fromEnd ? m.end : m.start;
  const gap = (t: number) => { const q = pointAt(m, t); return Math.hypot(q.x - anchor.x, q.y - anchor.y); };
  // `near` is the end at the anchor, `far` the other; the gap shrinks toward `near`.
  let near = fromEnd ? 1 : 0, far = fromEnd ? 0 : 1;
  if (gap(far) <= distance) return far;
  for (let i = 0; i < 30; i++) {
    const t = (near + far) / 2;
    if (gap(t) < distance) near = t; else far = t;
  }
  return (near + far) / 2;
}

/** Which end (0 start, 1 end) is within `tolerance` of `p`, the nearer if both, or null. */
export function endNear(m: Mark, p: Point, tolerance: number): number | null {
  const ds = Math.hypot(p.x - m.start.x, p.y - m.start.y), de = Math.hypot(p.x - m.end.x, p.y - m.end.y);
  return Math.min(ds, de) <= tolerance ? (de < ds ? 1 : 0) : null;
}

/** Where a label for end `i` (0 start, 1 end) attaches, as a fraction of its box: the side that faces
 *  back along the arrow, so the label sits beyond the end and the arrow meets its edge. */
export function calloutAnchor(m: Mark, i: number): Point {
  const tip = i === 0 ? m.start : m.end, c = control(m);
  const dx = tip.x - c.x, dy = tip.y - c.y;
  return Math.abs(dx) >= Math.abs(dy) ? { x: dx >= 0 ? 0 : 1, y: 0.5 } : { x: 0.5, y: dy >= 0 ? 0 : 1 };
}

/** Grab points for resizing: the two ends and the middle of an arrow, the four corners of a shape. */
export function handles(m: Mark): Point[] {
  switch (m.tool) {
    case "arrow": return [m.start, m.end, midpoint(m)];
    case "box": case "ellipse": case "highlight": case "redact":
      return [m.start, m.end, { x: m.start.x, y: m.end.y }, { x: m.end.x, y: m.start.y }];
    default: return [];
  }
}

/** The mark with handle `i` moved to `p`. A shape keeps the opposite corner fixed. */
export function moveHandle(m: Mark, i: number, p: Point): Mark {
  const h = handles(m);
  if (i < 0 || i >= h.length) return m;
  if (m.tool === "arrow") {
    if (i === 0) return { ...m, start: p };
    if (i === 1) return { ...m, end: p };
    const { bend: _b, ...rest } = m;
    const bend = bendThrough(m, p);
    return bend ? { ...rest, bend } : rest;
  }
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
    // Words end after a space or a hyphen, where the editor and the macOS app also break.
    for (const word of para.match(/[^ -]+[ -]*|[ -]+/g) ?? [""]) {
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

/** `label` moved so the point at `anchor` (fractions of its box) sits on `p`. A label grows right and
 *  down from its top-left corner as it gets text; pinning keeps it on its spot instead. */
export function pinned(label: Mark, p: Point, anchor: Point, imageWidth: number, measure: Measure): Mark {
  const r = textOrStepRect(label, imageWidth, measure);
  const start = { x: p.x - anchor.x * r.w, y: p.y - anchor.y * r.h };
  return { ...label, start, end: start };
}

/** The label an arrow carries in its middle, as a text mark, or null when it has none. */
export function arrowLabel(m: Mark, imageWidth: number, measure: Measure): Mark | null {
  if (m.tool !== "arrow" || !m.text) return null;
  const label = mark("text", m.color, { x: 0, y: 0 }, { x: 0, y: 0 }, { id: m.id, size: m.size, text: m.text });
  return pinned(label, midpoint(m), { x: 0.5, y: 0.5 }, imageWidth, measure);
}

/** How far a labeled arrow's middle handle sits from its middle, along its normal: just outside the
 *  label, on the side the arrow bends to, so the handle doesn't cover the text. 0 without a label. */
function labelClearance(m: Mark, imageWidth: number, measure: Measure): number {
  const label = arrowLabel(m, imageWidth, measure);
  if (!label) return 0;
  const r = textOrStepRect(label, imageWidth, measure), n = normal(m);
  const side = (m.bend ?? 0) < 0 ? -1 : 1;
  return side * (Math.abs(n.x) * r.w / 2 + Math.abs(n.y) * r.h / 2 + markFontSize(label, imageWidth) * 0.3);
}

/** The bend that puts a labeled arrow's middle handle (which sits `k` past the middle, on the side the
 *  arrow bends to) under a pointer `proj` off the chord. Inside the label's reach it is straight. */
export const bendForHandle = (proj: number, k: number) => (proj >= k ? proj - k : proj <= -k ? proj + k : 0);

/** A mark's grab points. A label has two: its bottom-right corner scales it, its right edge sets
 *  where it wraps. An arrow's middle handle clears its label. Shapes use `handles`. */
export function markHandles(m: Mark, imageWidth: number, measure: Measure): Point[] {
  if (m.tool === "arrow") {
    const k = labelClearance(m, imageWidth, measure), mid = midpoint(m), n = normal(m);
    return [m.start, m.end, { x: mid.x + n.x * k, y: mid.y + n.y * k }];
  }
  if (m.tool !== "text") return handles(m);
  const r = textOrStepRect(m, imageWidth, measure);
  return [{ x: r.x + r.w, y: r.y + r.h }, { x: r.x + r.w, y: r.y + r.h / 2 }];
}

/** The mark with handle `i` (an index into `markHandles`) dragged to `p`. */
export function moveMarkHandle(m: Mark, i: number, p: Point, imageWidth: number, measure: Measure): Mark {
  if (m.tool === "arrow" && i === 2) {
    const { bend: _b, ...rest } = m;
    const bend = bendForHandle(bendThrough(m, p), Math.abs(labelClearance(m, imageWidth, measure)));
    return bend ? { ...rest, bend } : rest;
  }
  if (m.tool !== "text") return moveHandle(m, i, p);
  return i === 0 ? resizeText(m, p, imageWidth, measure) : rewrapText(m, p.x, imageWidth);
}

/** Everything a mark paints, including stroke, arrowhead and shadow. */
export function extent(m: Mark, imageWidth: number, measure: Measure): Rect {
  const w = strokeWidth(m.size, imageWidth);
  if (m.tool === "text" || m.tool === "step") return inset(textOrStepRect(m, imageWidth, measure), -w);
  if (m.tool === "arrow") {
    const r = inset(curveBounds(m), -Math.max(w * 4.5, 10));
    const label = arrowLabel(m, imageWidth, measure);
    return label ? union(r, extent(label, imageWidth, measure)) : r;
  }
  return inset(markRect(m), -(m.tool === "pen" ? w * 1.5 : w));
}

export function distance(p: Point, m: Mark, imageWidth: number, measure: Measure): number {
  const r = markRect(m);
  switch (m.tool) {
    case "arrow": {
      const label = arrowLabel(m, imageWidth, measure);
      if (label && contains(textOrStepRect(label, imageWidth, measure), p)) return 0;
      const pts = curvePoints(m);
      return Math.min(...pts.slice(1).map((q, i) => Geometry.segmentDistance(p, pts[i], q)));
    }
    case "highlight": case "redact": return contains(r, p) ? 0 : Geometry.rectDistance(p, r);
    case "pen": {
      const pts = m.points ?? [m.start];
      const d = pts.length === 1 ? Math.hypot(p.x - pts[0].x, p.y - pts[0].y)
        : Math.min(...pts.slice(1).map((q, i) => Geometry.segmentDistance(p, pts[i], q)));
      return Math.max(0, d - strokeWidth(m.size, imageWidth) / 2);
    }
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

  /** Adds `label` and attaches end `i` (0 start, 1 end) of `arrow` to it at `anchor`, in one undo step. */
  addCallout(label: Mark, arrow: string, i: number, anchor: Point): Mark {
    if (!this.marks.some((m) => m.id === arrow)) return this.add(label);
    this.checkpoint();
    const b = { id: label.id, anchor };
    const marks = this.marks.map((m) => (m.id !== arrow ? m : i === 0 ? { ...m, startBinding: b } : { ...m, endBinding: b }));
    this.marks = this.resolveBindings([...marks, label]);
    return this.marks[this.marks.length - 1];
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

/** Paints over the short runs of similar neighboring pixels in a one-pixel strip of RGBA bytes, with
 *  the pixel beside them, so only wide bands and gradients are left. The canvas grows by stretching
 *  each edge's strip: this keeps a title bar or page background carrying on while a line, text or an
 *  icon touching the edge doesn't streak. A run is short below 2% of the strip (at least 6 pixels).
 *  A strip with no wide band at all becomes its most common color. */
export function removeThinRuns(px: Uint8ClampedArray) {
  const n = px.length / 4;
  if (n < 2) return;
  const similar = (a: number, b: number) => [0, 1, 2, 3].every((c) => Math.abs(px[a * 4 + c] - px[b * 4 + c]) <= 12);
  const runs: [number, number][] = [];
  let from = 0;
  for (let i = 1; i <= n; i++) if (i === n || !similar(i - 1, i)) { runs.push([from, i]); from = i; }
  const minRun = Math.min(n, Math.max(6, Math.floor(n / 50)));
  const long = runs.filter(([a, b]) => b - a >= minRun);
  if (long.length === runs.length) return;
  if (!long.length) {
    // All detail, like an edge through a column of text: one plain color, the most common.
    const key = (i: number) => [0, 1, 2, 3].map((c) => px[i * 4 + c] >> 3).join();
    const counts = new Map<string, number>();
    for (let i = 0; i < n; i++) counts.set(key(i), (counts.get(key(i)) ?? 0) + 1);
    const top = [...counts].reduce((a, b) => (b[1] > a[1] ? b : a))[0];
    let at = 0;
    while (key(at) !== top) at++;
    const fill = px.slice(at * 4, at * 4 + 4);
    for (let i = 0; i < n; i++) px.set(fill, i * 4);
    return;
  }
  const src = px.slice();
  const copy = (from: number, to: number) => { for (let c = 0; c < 4; c++) px[to * 4 + c] = src[from * 4 + c]; };
  for (const [a, b] of runs) {
    if (b - a >= minRun) continue;
    // The last pixel of the long run before it, else the first of the one after.
    const before = long.filter(([, e]) => e <= a).pop(), after = long.find(([s]) => s >= b);
    const fill = before ? before[1] - 1 : after ? after[0] : -1;
    if (fill >= 0) for (let i = a; i < b; i++) copy(fill, i);
  }
}

/** What a held pen stroke becomes (see `inkShape`). */
export type InkShape = { kind: "line"; a: Point; b: Point } | { kind: "box" | "ellipse"; rect: Rect };

/** Turns a hand-drawn stroke into the clean shape it was meant to be, as when a pen pauses at the end
 *  of a stroke: a nearly straight stroke becomes a line, a closed one a box or an ellipse, whichever
 *  it lies closer to. Anything else stays as drawn (null). */
export function inkShape(pts: Point[]): InkShape | null {
  if (pts.length < 3) return null;
  const first = pts[0], last = pts[pts.length - 1];
  const xs = pts.map((p) => p.x), ys = pts.map((p) => p.y);
  const rect = { x: Math.min(...xs), y: Math.min(...ys), w: Math.max(...xs) - Math.min(...xs), h: Math.max(...ys) - Math.min(...ys) };
  const diag = Math.hypot(rect.w, rect.h);
  if (diag < 8) return null;
  let length = 0;
  for (let i = 1; i < pts.length; i++) length += Math.hypot(pts[i].x - pts[i - 1].x, pts[i].y - pts[i - 1].y);
  const chord = Math.hypot(last.x - first.x, last.y - first.y);
  // Straight: it never strays far from the line between its ends. Measured by distance, not by length,
  // because a shaky hand adds length without leaving the line.
  const stray = Math.max(...pts.map((p) => Geometry.segmentDistance(p, first, last)));
  if (chord > diag * 0.9 && stray < chord * 0.06) return { kind: "line", a: first, b: last };
  // Closed: it ends near where it began and went most of the way around its box.
  if (chord >= diag * 0.3 || length <= diag * 1.8 || rect.w <= 4 || rect.h <= 4) return null;
  const a = rect.w / 2, b = rect.h / 2, cx = rect.x + a, cy = rect.y + b;
  let ellipse = 0, box = 0;
  for (const p of pts) {
    const x = (p.x - cx) / a, y = (p.y - cy) / b;
    ellipse += Math.abs(Math.hypot(x, y) - 1);
    box += 1 - Math.max(Math.abs(x), Math.abs(y));
  }
  return { kind: box < ellipse ? "box" : "ellipse", rect };
}
