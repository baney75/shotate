import { Doc, Geometry, PALETTE, mark, handles, moveHandle, duplicate, markRect, markFontSize, resizeText, textOrStepRect } from "./model";
import { resolveToolKeys, shortcutLabel } from "./settings";
import { TOOLS } from "./model";

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
