export type OverlayRect = { x: number; y: number; w: number; h: number };

/**
 * Single-shot dismiss guard for the fullscreen capture overlay. Guarantees that Esc, the Cancel
 * button, right-click, load failures, or a completed selection invoke `finishCapture` at most once.
 */
export function createOverlayDismiss(finishCapture: (rect: OverlayRect | null) => Promise<void> | void) {
  let done = false;
  return {
    get isDone() {
      return done;
    },
    finish(rect: OverlayRect | null): Promise<void> | void {
      if (done) return;
      done = true;
      return finishCapture(rect);
    },
  };
}

/**
 * Runs overlay setup with an automatic dismiss fallback if loading overlay metadata or pixels fails,
 * so a failed IPC call never strands an always-on-top fullscreen window.
 */
export async function loadOverlayOrDismiss<T>(
  load: () => Promise<T>,
  dismiss: () => Promise<void> | void,
): Promise<T | null> {
  try {
    return await load();
  } catch {
    await dismiss();
    return null;
  }
}
