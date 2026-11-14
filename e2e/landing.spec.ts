import { expect, test } from "./fixtures";

test.describe("landing page", () => {
  test("loads with the headline, the testnet disclosure and the three surfaces linked", async ({ page }) => {
    const res = await page.goto("/");
    expect(res?.status()).toBe(200);
    await expect(page.locator("h1")).toContainText("silence pays your heir.");
    await expect(page.locator(".netline")).toContainText("Mainnet: not deployed, no mainnet transactions");
    for (const href of ["pitch/", "status/", "judge/"]) expect(await page.locator(`a[href="${href}"]`).count()).toBeGreaterThan(0);
  });

  test("the For judges call-to-action opens /judge/", async ({ page }) => {
    await page.goto("/");
    await page.locator(".hero .cta").getByRole("link", { name: "For judges" }).click();
    await expect(page).toHaveURL(/\/judge\/$/);
    await expect(page.locator("h1")).toHaveText("Heirloom in one page.");
  });

  test("release tag: keeps the build-time text when the GitHub API is unreachable", async ({ page }) => {
    await page.goto("/");
    const rel = page.locator("footer [data-release]");
    await expect(rel).toHaveAttribute("href", "https://github.com/edycutjong/heirloom/releases/latest");
    await expect(rel).not.toHaveText("");
  });
});

test.describe("hero access card", () => {
  test("the markup alone shows the finished demo: every row, RELEASED and the paid stub", async ({ browser }) => {
    const ctx = await browser.newContext({ javaScriptEnabled: false, baseURL: test.info().project.use.baseURL });
    const page = await ctx.newPage();
    await page.goto("/");
    await expect(page.locator("#card .row")).toHaveCount(9);
    await expect(page.locator("#card .released")).toBeVisible();
    await expect(page.locator("#card .stub .paid")).toHaveText("PAID");
    await ctx.close();
  });

  test("the replay runs the clock to the release and ends on the finished state", async ({ page }) => {
    await page.goto("/");
    await page.locator("#replay").click();
    await expect(page.locator("#card")).toHaveClass(/armed/);
    await expect(page.locator("#card")).toHaveClass(/\brel\b/, { timeout: 20_000 });
    await expect(page.locator("#card .clock")).toHaveText("18:26:59 UTC");
    await expect(page.locator("#card .row.on")).toHaveCount(9);
  });

  test("reduced motion: no autoplay, the finished state stays put", async ({ page }) => {
    await page.emulateMedia({ reducedMotion: "reduce" });
    await page.goto("/");
    await page.waitForTimeout(1500);
    await expect(page.locator("#card")).not.toHaveClass(/armed/);
    await expect(page.locator("#card .q-time")).toHaveText("10:32");
  });
});

test.describe("release tag from the GitHub API", () => {
  test("replaces the fallback on landing, deck and judge page", async ({ page }) => {
    await page.route("https://api.github.com/repos/edycutjong/heirloom/releases/latest", (r) =>
      r.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ tag_name: "v7.7.7" }) }),
    );
    for (const path of ["/", "/pitch/", "/judge/"]) {
      await page.goto(path);
      await expect(page.locator("[data-release]").first()).toHaveText("v7.7.7");
    }
  });

  test("regression: a non-version tag_name in the API reply is ignored, not printed", async ({ page }) => {
    await page.route("https://api.github.com/repos/edycutjong/heirloom/releases/latest", (r) =>
      r.fulfill({ status: 200, contentType: "application/json", body: JSON.stringify({ tag_name: "<b>x</b>" }) }),
    );
    await page.goto("/judge/");
    await expect(page.locator("footer [data-release]")).not.toContainText("<b>");
  });
});
