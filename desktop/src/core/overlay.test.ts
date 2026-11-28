import { describe, expect, it, vi } from "vitest";
import { createOverlayDismiss, loadOverlayOrDismiss } from "./overlay";

describe("overlay dismiss", () => {
  it("invokes finishCapture at most once across Esc, close button, and failure paths", () => {
    const finishCapture = vi.fn();
    const overlay = createOverlayDismiss(finishCapture);

    expect(overlay.isDone).toBe(false);
    overlay.finish(null);
    expect(overlay.isDone).toBe(true);
    overlay.finish(null);
    overlay.finish({ x: 1, y: 2, w: 30, h: 40 });

    expect(finishCapture).toHaveBeenCalledTimes(1);
    expect(finishCapture).toHaveBeenCalledWith(null);
  });

  it("delivers a selected rect once and ignores subsequent cancels", () => {
    const finishCapture = vi.fn();
    const overlay = createOverlayDismiss(finishCapture);
    const rect = { x: 10, y: 20, w: 300, h: 200 };

    overlay.finish(rect);
    overlay.finish(null);

    expect(finishCapture).toHaveBeenCalledTimes(1);
    expect(finishCapture).toHaveBeenCalledWith(rect);
  });

  it("auto-dismisses when loading overlay metadata or pixels throws", async () => {
    const finishCapture = vi.fn();
    const overlay = createOverlayDismiss(finishCapture);

    const result = await loadOverlayOrDismiss(
      async () => {
        throw new Error("no capture in progress");
      },
      () => overlay.finish(null),
    );

    expect(result).toBeNull();
    expect(overlay.isDone).toBe(true);
    expect(finishCapture).toHaveBeenCalledTimes(1);
    expect(finishCapture).toHaveBeenCalledWith(null);
  });

  it("does not dismiss twice if user presses Esc before a failing load rejects", async () => {
    const finishCapture = vi.fn();
    const overlay = createOverlayDismiss(finishCapture);
    let rejectLoad!: (err: Error) => void;
    const loading = loadOverlayOrDismiss(
      () =>
        new Promise<string>((_, reject) => {
          rejectLoad = reject;
        }),
      () => overlay.finish(null),
    );

    // User hits Esc before IPC resolves.
    overlay.finish(null);
    rejectLoad(new Error("closed"));
    await loading;

    expect(finishCapture).toHaveBeenCalledTimes(1);
    expect(finishCapture).toHaveBeenCalledWith(null);
  });
});
