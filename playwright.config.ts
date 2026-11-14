import { defineConfig, devices } from "@playwright/test";

// E2E against the GitHub Pages site exactly as pages.yml assembles it (scripts/build-site.sh → _site/), served
// locally. External requests are blocked per test (e2e/fixtures.ts), so a run needs no network, wallet or key.
const PORT = 4173;
export default defineConfig({
  testDir: "e2e",
  fullyParallel: true,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  reporter: process.env.CI ? [["list"], ["html", { open: "never" }]] : "list",
  use: { baseURL: `http://127.0.0.1:${PORT}`, trace: "retain-on-failure" },
  projects: [{ name: "chromium", use: { ...devices["Desktop Chrome"] } }],
  webServer: {
    command: `sh scripts/build-site.sh && python3 -m http.server ${PORT} --bind 127.0.0.1 --directory _site`,
    url: `http://127.0.0.1:${PORT}/`,
    reuseExistingServer: !process.env.CI,
    timeout: 60_000,
  },
});
