import { defineConfig } from "vitest/config";

// Tauri serves the built files; the dev server runs on a fixed port it knows about.
export default defineConfig({
  clearScreen: false,
  server: { port: 1420, strictPort: true },
  build: { target: "es2022", outDir: "dist", emptyOutDir: true },
  test: { globals: true, environment: "node" },
});
