import { ago, buildLabel, folderChoice, updateStatusLine, type Config, type FolderPreset, type UpdateStatus } from "./settings";

const presets: FolderPreset[] = [
  { id: "pictures", path: "~/Pictures/Screenshots" },
  { id: "desktop", path: "~/Desktop" },
  { id: "downloads", path: "~/Downloads" },
];

describe("save folder", () => {
  it("recognizes each preset, with or without a trailing slash", () => {
    expect(folderChoice("~/Pictures/Screenshots", presets)).toBe("pictures");
    expect(folderChoice("~/Desktop/", presets)).toBe("desktop");
    expect(folderChoice("~\\Downloads", presets)).toBe("downloads");
  });

  it("anything else is another folder", () => {
    expect(folderChoice("~/Pictures", presets)).toBe("other");
    expect(folderChoice("D:\\Shots", presets)).toBe("other");
  });
});

describe("config", () => {
  it("round-trips the update keys and keeps an absent channel absent", () => {
    const file = `{"saveFolder":"~/Downloads","copyOnCapture":true,"showMenuBarIcon":true,
      "shortcuts":{"captureArea":"ctrl+shift+s","captureWindow":"","captureScreen":""},"commands":{},"toolKeys":{},
      "checkForUpdates":false}`;
    const c = JSON.parse(file) as Config;
    expect(c.checkForUpdates).toBe(false);
    expect("updateChannel" in JSON.parse(JSON.stringify(c))).toBe(false);
    const nightly: Config = { ...c, updateChannel: "nightly" };
    expect(JSON.parse(JSON.stringify(nightly))).toEqual(nightly);
  });
});

const build = { version: "0.12.0", commit: "a3cab604f00ddba11c0ffee0123456789abcdef0", channel: "stable" as const, date: "2026-10-11T18:00:00Z" };
const status = (over: Partial<UpdateStatus> = {}): UpdateStatus => ({
  current: build, channel: "stable", checking: false, installing: false, checkedAt: null, error: null, available: null, ...over,
});

describe("updates", () => {
  it("labels the build with version, channel and short commit", () => {
    expect(buildLabel(build)).toBe("Shotate 0.12.0 · Stable · a3cab60");
    expect(buildLabel({ ...build, channel: "nightly", commit: "unknown" })).toBe("Shotate 0.12.0 · Nightly");
  });

  it("says how long ago", () => {
    const now = 10_000_000;
    expect(ago(now - 5_000, now)).toBe("just now");
    expect(ago(now - 60_000, now)).toBe("1 minute ago");
    expect(ago(now - 3 * 60_000, now)).toBe("3 minutes ago");
    expect(ago(now - 2 * 3_600_000, now)).toBe("2 hours ago");
    expect(ago(now - 86_400_000, now)).toBe("1 day ago");
  });

  it("writes the status line", () => {
    const now = Date.now();
    expect(updateStatusLine(status({ checkedAt: now - 3 * 60_000 }), now)).toBe("Shotate 0.12.0 is up to date. Checked 3 minutes ago.");
    expect(updateStatusLine(status(), now)).toBe("Shotate 0.12.0. Not checked yet.");
    expect(updateStatusLine(status({ checking: true }), now)).toBe("Checking for updates…");
    expect(updateStatusLine(status({ error: "Couldn't reach GitHub" }), now)).toBe("Couldn't reach GitHub");
    const available = { version: "0.12.1", notes: "https://github.com/baney75/shotate/releases/tag/v0.12.1", offer: "update" as const, label: "Update to Shotate 0.12.1" };
    expect(updateStatusLine(status({ available }), now)).toBe("Shotate 0.12.1 is available.");
    expect(updateStatusLine(status({ available: { ...available, offer: "switchToStable" } }), now)).toBe("Stable 0.12.1 is available.");
  });
});
