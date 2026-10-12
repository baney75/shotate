import { Doc, Geometry, LINE_HEIGHT, PALETTE, Snap, mark, markHandles, handles, moveHandle, moveMarkHandle, duplicate, markRect, markFontSize, offset, resizeText, rewrapped, styled, textLines, textOrStepRect } from "./model";
import { resolveToolKeys, shortcutLabel } from "./settings";
import { TOOLS, arrowLabel, calloutAnchor, curveBounds, endNear, midpoint, parameterAt, pinned, pointAt, removeThinRuns } from "./model";
import { edgeStrips } from "./render";

const measure = (text: string, size: number) => text.length * size * 0.6;
const red = PALETTE[0].color;

describe("document", () => {
  it("undo and redo restore marks and crop", () => {
    const doc = new Doc(400, 300, measure);
    doc.add(mark("box", red, { x: 0, y: 0 }, { x: 50, y: 50 }));
    doc.setCrop({ x: 10, y: 10, w: 100, h: 80 });
    expect(doc.crop).not.toBeNull();
    doc.undo();
    expect(doc.crop).toBeNull();
    doc.undo();
    expect(doc.marks).toHaveLength(0);
    doc.redo(); doc.redo();
    expect(doc.marks).toHaveLength(1);
    expect(doc.crop).not.toBeNull();
  });

  it("numbers steps upward and keeps counting after a delete", () => {
    const doc = new Doc(400, 300, measure);
    const a = doc.add(mark("step", red, { x: 10, y: 10 }));
    const b = doc.add(mark("step", red, { x: 20, y: 20 }));
    expect([a.number, b.number]).toEqual([1, 2]);
    doc.remove(a.id);
    expect(doc.add(mark("step", red, { x: 30, y: 30 })).number).toBe(3);
  });

  it("hit-tests the topmost mark", () => {
    const doc = new Doc(400, 300, measure);
    doc.add(mark("highlight", red, { x: 0, y: 0 }, { x: 100, y: 100 }));
    const top = doc.add(mark("redact", red, { x: 40, y: 40 }, { x: 60, y: 60 }));
    expect(doc.hitTest({ x: 50, y: 50 }, 2)?.id).toBe(top.id);
    expect(doc.hitTest({ x: 300, y: 250 }, 2)).toBeUndefined();
  });

  it("grows the canvas only for marks past the edge, and shrinks back on undo", () => {
    const doc = new Doc(400, 300, measure);
    doc.add(mark("box", red, { x: 100, y: 100 }, { x: 200, y: 200 }));
    expect(doc.canvas).toEqual(doc.bounds);
    doc.add(mark("arrow", red, { x: 300, y: 150 }, { x: 520, y: 150 }));
    expect(doc.canvas.w).toBeGreaterThan(520);
    expect(doc.canvas.y).toBe(0);
    expect(doc.canvas.h).toBe(300);
    doc.undo();
    expect(doc.canvas).toEqual(doc.bounds);
  });

  it("trims a crop when the canvas shrinks under it", () => {
    const doc = new Doc(100, 100, measure);
    const box = doc.add(mark("box", red, { x: 150, y: 10 }, { x: 190, y: 50 }));
    doc.setCrop({ x: 120, y: 10, w: 60, h: 40 });
    expect(doc.effectiveCrop).not.toBeNull();
    doc.remove(box.id);
    expect(doc.effectiveCrop).toBeNull();
  });

  it("reorder is undoable and ignores no-ops", () => {
    const doc = new Doc(400, 300, measure);
    const a = doc.add(mark("box", red, { x: 0, y: 0 }, { x: 10, y: 10 }));
    const b = doc.add(mark("ellipse", red, { x: 0, y: 0 }, { x: 20, y: 20 }));
    doc.reorder(a.id, true);
    expect(doc.marks.map((m) => m.id)).toEqual([b.id, a.id]);
    const rev = doc.revision;
    doc.reorder(a.id, true);
    expect(doc.revision).toBe(rev);
    doc.undo();
    expect(doc.marks.map((m) => m.id)).toEqual([a.id, b.id]);
  });
});

describe("geometry", () => {
  it("snaps arrows to 45 degrees and squares shapes", () => {
    const p = Geometry.snap45({ x: 0, y: 0 }, { x: 100, y: 90 });
    expect(p.x).toBeCloseTo(p.y, 6);
    expect(Geometry.square({ x: 0, y: 0 }, { x: 30, y: -80 })).toEqual({ x: 80, y: -80 });
  });

  it("dragging a corner keeps the opposite corner fixed", () => {
    const m = mark("box", red, { x: 10, y: 10 }, { x: 100, y: 60 });
    expect(handles(m)).toHaveLength(4);
    expect(markRect(moveHandle(m, 2, { x: 0, y: 80 }))).toEqual({ x: 0, y: 10, w: 100, h: 70 });
    const arrow = mark("arrow", red, { x: 0, y: 0 }, { x: 50, y: 50 });
    expect(moveHandle(arrow, 1, { x: 70, y: 20 }).start).toEqual({ x: 0, y: 0 });
    expect(handles(mark("text", red, { x: 0, y: 0 }, undefined, { text: "x" }))).toHaveLength(0);
  });

  it("duplicates get a new identity", () => {
    const m = mark("box", red, { x: 0, y: 0 }, { x: 10, y: 10 });
    const d = duplicate(m, 8);
    expect(d.id).not.toBe(m.id);
    expect(d.start).toEqual({ x: 8, y: 8 });
  });
});

describe("settings", () => {
  it("keeps every tool reachable under any remap", () => {
    const letters = ["a", "b", "c", "v", "r", "x", "1", "", "bb"];
    for (let i = 0; i < 2000; i++) {
      const keys: Record<string, string> = {};
      for (const t of TOOLS) if (Math.random() < 0.5) keys[t.title.toLowerCase()] = letters[Math.floor(Math.random() * letters.length)];
      const resolved = resolveToolKeys(keys);
      expect(new Set(Object.values(resolved)).size).toBe(TOOLS.length);
    }
    expect(resolveToolKeys({ arrow: "w", box: "a", ellipse: "r" })).toMatchObject({ arrow: "w", box: "a", ellipse: "r" });
    expect(resolveToolKeys({ arrow: "v" }).arrow).toBe("a");
  });

  it("labels shortcuts the way Windows and Linux write them", () => {
    expect(shortcutLabel("ctrl+shift+s")).toBe("Ctrl+Shift+S");
    expect(shortcutLabel("cmd+option+2")).toBe("Ctrl+Alt+2");
    expect(shortcutLabel("")).toBe("");
  });
});

describe("text labels", () => {
  it("scale from their corner about the top-left and keep a hand size through duplication", () => {
    const label = mark("text", red, { x: 100, y: 200 }, { x: 100, y: 200 }, { text: "Hello" });
    const r = textOrStepRect(label, 1000, measure);
    const big = resizeText(label, { x: r.x + r.w * 2, y: r.y + r.h }, 1000, measure);
    const br = textOrStepRect(big, 1000, measure);
    expect(big.fontSize).toBeCloseTo(markFontSize(label, 1000) * 2);
    expect(br.x).toBeCloseTo(r.x);
    expect(br.y).toBeCloseTo(r.y);
    expect(resizeText(label, { x: 0, y: 0 }, 1000, measure).fontSize).toBe(8);
    expect(duplicate(big, 5).fontSize).toBe(big.fontSize);
    const doc = new Doc(1000, 600, measure);
    doc.add(big);
    expect(doc.hitTest({ x: br.x + br.w - 2, y: br.y + br.h / 2 }, 0)?.id).toBe(big.id);
  });
});

describe("annotation", () => {
  it("wraps labels at their width and grows them downward from the top-left", () => {
    const one = mark("text", red, { x: 100, y: 100 }, { x: 100, y: 100 }, { text: "Deploy the build now" });
    const r1 = textOrStepRect(one, 1000, measure);
    const wrapped = { ...one, textWidth: (r1.w - markFontSize(one, 1000) * 0.9) / 2 };
    const r2 = textOrStepRect(wrapped, 1000, measure);
    expect(textLines(wrapped, markFontSize(one, 1000), measure).length).toBeGreaterThan(1);
    expect(r2.h).toBeGreaterThan(r1.h * 1.5);
    expect(r2.y).toBe(100);
    const broken = { ...one, text: "Deploy\nnow" };
    expect(textOrStepRect(broken, 1000, measure).h).toBeCloseTo(r1.h + markFontSize(one, 1000) * LINE_HEIGHT);
    // The side handle sets the width; the corner scales width and font together.
    const side = moveMarkHandle(wrapped, 1, { x: r2.x + r2.w + 50, y: r2.y + r2.h / 2 }, 1000, measure);
    expect(side.textWidth).toBeCloseTo(wrapped.textWidth + 50);
    const corner = moveMarkHandle(wrapped, 0, { x: r2.x + r2.w * 2, y: r2.y + r2.h }, 1000, measure);
    expect(corner.textWidth! / wrapped.textWidth).toBeCloseTo(corner.fontSize! / markFontSize(wrapped, 1000));
  });

  it("keeps arrows attached to the marks they point at", () => {
    const doc = new Doc(1000, 600, measure);
    const box = doc.add(mark("box", red, { x: 100, y: 100 }, { x: 300, y: 200 }));
    const b = doc.bindingAt({ x: 300, y: 150 }, 0, null)!;
    expect(b.id).toBe(box.id);
    expect(b.anchor).toEqual({ x: 1, y: 0.5 });
    expect(doc.bindingAt({ x: 600, y: 400 }, 0, null)).toBeNull();
    const arrow = doc.add(mark("arrow", red, { x: 600, y: 400 }, { x: 300, y: 150 }, { endBinding: b }));
    doc.update(offset(box, 50, -20));
    expect(doc.marks[1].end).toEqual({ x: 350, y: 130 });
    expect(doc.marks[1].start).toEqual({ x: 600, y: 400 });
    expect(doc.resolveBindings([offset(doc.marks[0], 10, 0), doc.marks[1]])[1].end).toEqual({ x: 360, y: 130 });
    doc.undo();
    expect(doc.marks[1].end).toEqual({ x: 300, y: 150 });
    expect(offset(arrow, 5, 5).endBinding).toBeUndefined();
    doc.remove(box.id);
    expect(doc.marks[0].endBinding).toBeUndefined();
    expect(doc.marks[0].end).toEqual({ x: 300, y: 150 });
  });

  it("snaps dragged marks to edges and centers", () => {
    const targets = [{ x: 0, y: 0, w: 1000, h: 600 }, { x: 100, y: 100, w: 200, h: 100 }];
    const s = Snap.move({ x: 104, y: 400, w: 50, h: 50 }, targets, 6);
    expect(s.dx).toBe(-4);
    expect(s.dy).toBe(0);
    expect(s.guides.some((g) => g.vertical && g.at === 100)).toBe(true);
    expect(Snap.move({ x: 473, y: 400, w: 50, h: 20 }, targets, 6).dx).toBe(2);
    const far = Snap.move({ x: 120, y: 400, w: 50, h: 50 }, targets, 6);
    expect([far.dx, far.dy, far.guides.length]).toEqual([0, 0, 0]);
    expect(Snap.point({ x: 297, y: 203 }, targets, 6).p).toEqual({ x: 300, y: 200 });
  });

  it("pastes a style without moving or retyping the mark", () => {
    const source = mark("text", PALETTE[3].color, { x: 0, y: 0 }, { x: 0, y: 0 }, { size: 3, text: "A", fontSize: 40 });
    const target = mark("text", red, { x: 9, y: 9 }, { x: 9, y: 9 }, { text: "B" });
    const out = styled(target, source);
    expect([out.color, out.size, out.fontSize, out.text, out.start]).toEqual([source.color, 3, 40, "B", target.start]);
  });
});

describe("restyling and wrapping details", () => {
  it("keeps a wrapping label's lines when a paste or preset changes its font", () => {
    const label = mark("text", red, { x: 0, y: 0 }, { x: 0, y: 0 }, { text: "Release notes go here", textWidth: 200 });
    const big = mark("text", red, { x: 0, y: 0 }, { x: 0, y: 0 }, { text: "x", fontSize: 90 });
    const pasted = rewrapped(styled(label, big), label, 1000);
    expect(pasted.textWidth! / 200).toBeCloseTo(90 / markFontSize(label, 1000));
    expect(textLines(pasted, 90, measure)).toEqual(textLines(label, markFontSize(label, 1000), measure));
    const hand = { ...label, fontSize: 50 };
    expect(styled(hand, mark("box", red, { x: 0, y: 0 })).fontSize).toBeUndefined();
  });

  it("breaks lines after hyphens as well as spaces", () => {
    const m = mark("text", red, { x: 0, y: 0 }, { x: 0, y: 0 }, { text: "state-of-the-art", textWidth: 55 });
    expect(textLines(m, 10, measure)).toEqual(["state-of-", "the-art"]);
    expect(textLines({ ...m, text: "a\n\nb" }, 10, measure)).toEqual(["a", " ", "b"]);
  });
});

describe("arrows", () => {
  it("bend from their middle handle, and the curve is what hits", () => {
    const doc = new Doc(600, 300, measure);
    const arrow = mark("arrow", red, { x: 100, y: 100 }, { x: 500, y: 100 });
    expect(handles(arrow)).toHaveLength(3);
    expect(handles(arrow)[2]).toEqual({ x: 300, y: 100 });
    const bent = moveHandle(arrow, 2, { x: 260, y: 180 });
    expect(bent.bend).toBeCloseTo(80);
    expect(midpoint(bent).y).toBeCloseTo(180);
    expect(midpoint(bent).x).toBeCloseTo(300);
    doc.add(bent);
    expect(doc.hitTest({ x: 300, y: 178 }, 6)?.id).toBe(bent.id);
    expect(doc.hitTest({ x: 300, y: 100 }, 6)).toBeUndefined();
    expect(curveBounds(bent).y + curveBounds(bent).h).toBeCloseTo(180);
    expect(doc.canvas).toEqual(doc.bounds);
    // The bend is relative, survives moving and copying, and dragging back to the line clears it.
    expect(moveHandle(bent, 1, { x: 500, y: 140 }).bend).toBeCloseTo(80);
    expect(duplicate(bent, 5).bend).toBeCloseTo(80);
    expect(moveHandle(bent, 2, { x: 300, y: 100 }).bend).toBeUndefined();
  });

  it("get a label at a double-clicked end that they point at, in one undo step", () => {
    const doc = new Doc(1000, 600, measure);
    const arrow = doc.add(mark("arrow", red, { x: 100, y: 300 }, { x: 400, y: 300 }));
    expect(endNear(arrow, { x: 405, y: 302 }, 10)).toBe(1);
    expect(endNear(arrow, { x: 98, y: 300 }, 10)).toBe(0);
    expect(endNear(arrow, { x: 250, y: 300 }, 10)).toBeNull();
    const anchor = calloutAnchor(arrow, 1);
    expect(anchor).toEqual({ x: 0, y: 0.5 });
    const label = pinned(mark("text", red, { x: 0, y: 0 }, { x: 0, y: 0 }, { text: "Here" }), arrow.end, anchor, 1000, measure);
    const r = textOrStepRect(label, 1000, measure);
    expect(r.x).toBeCloseTo(400);
    expect(r.y + r.h / 2).toBeCloseTo(300);
    const before = doc.revision;
    doc.addCallout(label, arrow.id, 1, anchor);
    expect(doc.revision).toBe(before + 1);
    expect(doc.marks[0].endBinding?.id).toBe(label.id);
    doc.update(offset(label, 30, 40));
    expect(doc.marks[0].end).toEqual({ x: 430, y: 340 });
    doc.undo(); doc.undo();
    expect(doc.marks.map((m) => m.id)).toEqual([arrow.id]);
    expect(doc.marks[0].endBinding).toBeUndefined();
    // Pointing down the screen, the label hangs below the tip.
    const down = mark("arrow", red, { x: 100, y: 100 }, { x: 110, y: 400 });
    expect(calloutAnchor(down, 1)).toEqual({ x: 0.5, y: 0 });
    expect(calloutAnchor(down, 0)).toEqual({ x: 0.5, y: 1 });
  });

  it("carry a label on the middle of the curve", () => {
    const doc = new Doc(1000, 600, measure);
    const arrow = doc.add(mark("arrow", red, { x: 100, y: 300 }, { x: 700, y: 300 }, { bend: 120, text: "Step two" }));
    expect(arrowLabel({ ...arrow, text: "" }, 1000, measure)).toBeNull();
    const r = textOrStepRect(arrowLabel(arrow, 1000, measure)!, 1000, measure);
    expect(r.x + r.w / 2).toBeCloseTo(400);
    expect(r.y + r.h / 2).toBeCloseTo(420);
    expect(doc.hitTest({ x: r.x + 3, y: r.y + 3 }, 0)?.id).toBe(arrow.id);
    // The middle handle sits just outside the label, and dragging it moves the curve by as much.
    const h = markHandles(arrow, 1000, measure)[2];
    expect(h.x).toBeCloseTo(400);
    expect(h.y).toBeGreaterThan(r.y + r.h);
    expect(moveMarkHandle(arrow, 2, { x: h.x, y: h.y + 30 }, 1000, measure).bend).toBeCloseTo(150);
    // Dragged across to the other side, the handle stays under the pointer there.
    const flipped = moveMarkHandle(arrow, 2, { x: 400, y: 100 }, 1000, measure);
    expect(flipped.bend!).toBeLessThan(0);
    expect(markHandles(flipped, 1000, measure)[2].y).toBeCloseTo(100);
  });

  it("meet their head on long curves", () => {
    const arrow = mark("arrow", red, { x: 0, y: 0 }, { x: 2000, y: 0 }, { bend: 200 });
    const q = pointAt(arrow, parameterAt(arrow, 49.7, true));
    expect(Math.hypot(q.x - 2000, q.y)).toBeCloseTo(49.7, 2);
    expect(parameterAt(arrow, 5000, true)).toBe(0);
  });
});

describe("growing the canvas", () => {
  it("takes thin detail off the edge strips but keeps bands and gradients", () => {
    // A 100-pixel strip: a gradient, a 2-pixel red line, then a wide gray band.
    const px = new Uint8ClampedArray(400);
    for (let i = 0; i < 100; i++) px.set(i < 60 ? [50, 50 + i, 80, 255] : [230, 230, 230, 255], i * 4);
    px.set([255, 0, 0, 255, 255, 0, 0, 255], 30 * 4);
    removeThinRuns(px);
    expect([...px.subarray(30 * 4, 30 * 4 + 4)]).toEqual([50, 79, 80, 255]);
    expect(px[10 * 4 + 1]).toBe(60);
    expect(px[90 * 4]).toBe(230);
    // A strip with no wide band at all becomes its most common color.
    const busy = new Uint8ClampedArray(800);
    for (let i = 0; i < 200; i++) busy.set(i % 8 < 5 ? [240, 240, 240, 255] : [20, 20, 20, 255], i * 4);
    removeThinRuns(busy);
    expect(busy.every((v, i) => (i % 4 === 3 ? v === 255 : v === 240))).toBe(true);
    // Edge strips come off each side of the image.
    const data = new Uint8ClampedArray(4 * 4 * 4);
    for (let i = 0; i < 16; i++) data.set([i * 3, 0, 0, 255], i * 4);
    const [l, r, t, b] = edgeStrips({ width: 4, height: 4, data } as ImageData);
    const reds = (s: Uint8ClampedArray) => [0, 1, 2, 3].map((i) => s[i * 4]);
    expect(reds(l)).toEqual([0, 12, 24, 36]);
    expect(reds(r)).toEqual([9, 21, 33, 45]);
    expect(reds(t)).toEqual([0, 3, 6, 9]);
    expect(reds(b)).toEqual([36, 39, 42, 45]);
  });
});
