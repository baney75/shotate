// Draws marks with the 2D canvas. Used both for the live editor and the exported PNG, so what you
// see is exactly what gets copied. Mirrors the macOS renderer.
import {
  LINE_HEIGHT, PAD_X, PAD_Y, type Doc, type Mark, type RGBA, type Rect, arrowLabel, control, css, fontSize, parameterAt,
  markFontSize, markRect, pointAt, removeThinRuns, rgba, strokeWidth, textLines, textOrStepRect,
} from "./model";

type Ctx = CanvasRenderingContext2D | OffscreenCanvasRenderingContext2D;

export const FONT = (size: number) => `600 ${size}px system-ui, "Segoe UI", Ubuntu, "Noto Sans", sans-serif`;

/** Black text on light colors, white on dark ones. */
export function ink(c: RGBA): RGBA {
  return 0.299 * c.r + 0.587 * c.g + 0.114 * c.b > 0.62 ? rgba(0.08, 0.08, 0.09) : rgba(1, 1, 1);
}

function roundRect(ctx: Ctx, r: Rect, radius: number) {
  ctx.beginPath();
  ctx.roundRect(r.x, r.y, r.w, r.h, Math.min(radius, r.w / 2, r.h / 2));
}

function shadow(ctx: Ctx, blur: number, dy: number) {
  ctx.shadowColor = "rgba(0,0,0,0.35)";
  ctx.shadowBlur = blur;
  ctx.shadowOffsetY = dy;
}

export function drawMark(ctx: Ctx, m: Mark, imageWidth: number) {
  const w = strokeWidth(m.size, imageWidth);
  const measure = (t: string, s: number) => { ctx.font = FONT(s); return ctx.measureText(t).width; };
  ctx.save();
  ctx.lineJoin = "round";
  ctx.lineCap = "round";
  const r = markRect(m);
  switch (m.tool) {
    case "box":
      ctx.strokeStyle = css(m.color);
      ctx.lineWidth = w;
      roundRect(ctx, r, w * 1.2);
      ctx.stroke();
      break;
    case "ellipse":
      ctx.strokeStyle = css(m.color);
      ctx.lineWidth = w;
      ctx.beginPath();
      ctx.ellipse(r.x + r.w / 2, r.y + r.h / 2, r.w / 2, r.h / 2, 0, 0, Math.PI * 2);
      ctx.stroke();
      break;
    case "highlight":
      ctx.fillStyle = css(m.color, 0.38);
      ctx.fillRect(r.x, r.y, r.w, r.h);
      break;
    case "redact":
      // A solid bar: pixelation and blur can sometimes be reversed; this cannot.
      ctx.fillStyle = "rgb(28,28,31)";
      roundRect(ctx, r, w);
      ctx.fill();
      break;
    case "arrow": {
      const a = m.start, b = m.end;
      const head = Math.max(w * 4.5, 10);
      // A curve stops where the head begins: split it at the point about the head's length from the
      // tip, and aim the head from there so line and head meet on its axis.
      let t = 1;
      if (m.bend) {
        t = parameterAt(m, head * 0.85, true);
      }
      const cut = m.bend ? pointAt(m, t) : a;
      const angle = Math.atan2(b.y - cut.y, b.x - cut.x);
      const base = { x: b.x - Math.cos(angle) * head * 0.85, y: b.y - Math.sin(angle) * head * 0.85 };
      const wing = head * 0.55;
      shadow(ctx, w * 1.2, w * 0.3);
      ctx.strokeStyle = ctx.fillStyle = css(m.color);
      ctx.lineWidth = w;
      ctx.beginPath();
      ctx.moveTo(a.x, a.y);
      if (m.bend) {
        const c = control(m);
        ctx.quadraticCurveTo(a.x + (c.x - a.x) * t, a.y + (c.y - a.y) * t, cut.x, cut.y);
      } else ctx.lineTo(base.x, base.y);
      ctx.stroke();
      ctx.beginPath();
      ctx.moveTo(b.x, b.y);
      ctx.lineTo(b.x - Math.cos(angle) * head + Math.cos(angle + Math.PI / 2) * wing,
                 b.y - Math.sin(angle) * head + Math.sin(angle + Math.PI / 2) * wing);
      ctx.lineTo(b.x - Math.cos(angle) * head - Math.cos(angle + Math.PI / 2) * wing,
                 b.y - Math.sin(angle) * head - Math.sin(angle + Math.PI / 2) * wing);
      ctx.closePath();
      ctx.fill();
      const label = arrowLabel(m, imageWidth, measure);
      if (label) { ctx.restore(); ctx.save(); drawMark(ctx, label, imageWidth); }
      break;
    }
    case "text": {
      const size = markFontSize(m, imageWidth);
      const box = textOrStepRect(m, imageWidth, measure);
      shadow(ctx, size * 0.3, size * 0.06);
      ctx.fillStyle = css(m.color);
      roundRect(ctx, box, size * 0.35);
      ctx.fill();
      ctx.shadowColor = "transparent";
      ctx.fillStyle = css(ink(m.color));
      ctx.font = FONT(size);
      ctx.textBaseline = "middle";
      textLines(m, size, measure).forEach((line, i) =>
        ctx.fillText(line, box.x + size * PAD_X, box.y + size * (PAD_Y / 2 + LINE_HEIGHT * (i + 0.5) + 0.04)));
      break;
    }
    case "step": {
      const size = fontSize(m.size, imageWidth);
      const disc = textOrStepRect(m, imageWidth, measure);
      const cx = disc.x + disc.w / 2, cy = disc.y + disc.h / 2;
      shadow(ctx, size * 0.25, size * 0.05);
      ctx.fillStyle = css(m.color);
      ctx.beginPath(); ctx.arc(cx, cy, disc.w / 2, 0, Math.PI * 2); ctx.fill();
      ctx.shadowColor = "transparent";
      ctx.strokeStyle = "rgba(255,255,255,0.9)";
      ctx.lineWidth = Math.max(1.5, w * 0.45);
      ctx.beginPath(); ctx.arc(cx, cy, disc.w / 2 - w * 0.25, 0, Math.PI * 2); ctx.stroke();
      ctx.fillStyle = css(ink(m.color));
      ctx.font = FONT(size * 1.05);
      ctx.textAlign = "center";
      ctx.textBaseline = "middle";
      ctx.fillText(String(m.number), cx, cy + size * 0.05);
      break;
    }
  }
  ctx.restore();
}

/** The most common color in the outermost ring of pixels; transparent edges stay transparent. */
export function edgeColor(data: ImageData): RGBA {
  const { width: w, height: h, data: px } = data;
  const buckets = new Map<number, { n: number; r: number; g: number; b: number }>();
  const visit = (x: number, y: number) => {
    const i = (y * w + x) * 4;
    const a = px[i + 3];
    const key = a === 0 ? -1 : ((px[i] >> 3) << 10) | ((px[i + 1] >> 3) << 5) | (px[i + 2] >> 3);
    const e = buckets.get(key) ?? { n: 0, r: 0, g: 0, b: 0 };
    buckets.set(key, { n: e.n + 1, r: e.r + px[i], g: e.g + px[i + 1], b: e.b + px[i + 2] });
  };
  for (let x = 0; x < w; x++) { visit(x, 0); visit(x, h - 1); }
  for (let y = 0; y < h; y++) { visit(0, y); visit(w - 1, y); }
  let best: [number, { n: number; r: number; g: number; b: number }] | null = null;
  for (const entry of buckets) if (!best || entry[1].n > best[1].n) best = entry;
  if (!best) return rgba(1, 1, 1);
  if (best[0] === -1) return rgba(0, 0, 0, 0);
  const n = best[1].n * 255;
  return rgba(best[1].r / n, best[1].g / n, best[1].b / n);
}

/** How the canvas grows past the image: the corner color, and each side's outermost column or row of
 *  pixels with thin detail taken out (see `removeThinRuns`), in the order left, right, top, bottom. */
export interface Edges { color: RGBA; strips: CanvasImageSource[] }

/** The cleaned edge strips of an image as RGBA bytes: left and right top to bottom, top and bottom
 *  left to right. */
export function edgeStrips(data: ImageData): Uint8ClampedArray[] {
  const { width: w, height: h, data: px } = data;
  const strip = (n: number, at: (i: number) => number) => {
    const out = new Uint8ClampedArray(n * 4);
    for (let i = 0; i < n; i++) out.set(px.subarray(at(i), at(i) + 4), i * 4);
    removeThinRuns(out);
    return out;
  };
  return [strip(h, (y) => y * w * 4), strip(h, (y) => (y * w + w - 1) * 4), strip(w, (x) => x * 4), strip(w, (x) => ((h - 1) * w + x) * 4)];
}

export function edges(data: ImageData): Edges {
  const { width: w, height: h } = data;
  const strips = edgeStrips(data).map((px, i) => {
    const c = new OffscreenCanvas(i < 2 ? 1 : w, i < 2 ? h : 1);
    c.getContext("2d")!.putImageData(new ImageData(px, c.width, c.height), 0, 0);
    return c;
  });
  return { color: edgeColor(data), strips };
}

/**
 * The image, plus the area a canvas grows into: each side stretches its cleaned edge strip, so a
 * title bar or a page background carries on without streaks, and the corners take the border color.
 */
export function drawBackground(ctx: Ctx, image: CanvasImageSource, doc: Doc, canvas: Rect, edges: Edges) {
  const W = doc.width, H = doc.height;
  if (canvas.x < 0 || canvas.y < 0 || canvas.x + canvas.w > W || canvas.y + canvas.h > H) {
    ctx.fillStyle = css(edges.color);
    ctx.fillRect(canvas.x, canvas.y, canvas.w, canvas.h);
    ctx.imageSmoothingEnabled = false;
    const [l, r, t, b] = edges.strips;
    const left = -canvas.x, right = canvas.x + canvas.w - W, top = -canvas.y, bottom = canvas.y + canvas.h - H;
    if (left > 0) ctx.drawImage(l, canvas.x, 0, left, H);
    if (right > 0) ctx.drawImage(r, W, 0, right, H);
    if (top > 0) ctx.drawImage(t, 0, canvas.y, W, top);
    if (bottom > 0) ctx.drawImage(b, 0, H, W, bottom);
    ctx.imageSmoothingEnabled = true;
  }
  ctx.drawImage(image, 0, 0, W, H);
}

/** The finished image: canvas background, marks in order, then the crop. */
export function flatten(image: CanvasImageSource, doc: Doc, border: Edges): OffscreenCanvas {
  const canvas = doc.canvas;
  const full = new OffscreenCanvas(canvas.w, canvas.h);
  const ctx = full.getContext("2d")!;
  ctx.translate(-canvas.x, -canvas.y);
  drawBackground(ctx, image, doc, canvas, border);
  for (const m of doc.marks) drawMark(ctx, m, doc.width);
  const crop = doc.effectiveCrop;
  if (!crop) return full;
  const out = new OffscreenCanvas(crop.w, crop.h);
  out.getContext("2d")!.drawImage(full, crop.x - canvas.x, crop.y - canvas.y, crop.w, crop.h, 0, 0, crop.w, crop.h);
  return out;
}
