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

  test("release tag: the footer links the latest release", async ({ page }) => {
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

test.describe("release tag, stamped at build time", () => {
  test("landing, deck and judge page carry a version tag and make no runtime GitHub API call", async ({ page }) => {
    const apiCalls: string[] = [];
    page.on("request", (r) => { if (r.url().startsWith("https://api.github.com/")) apiCalls.push(r.url()); });
    for (const path of ["/", "/pitch/", "/judge/"]) {
      await page.goto(path);
      await page.waitForLoadState("networkidle");
      const tags = await page.locator("[data-release]").allTextContents();
      expect(tags.length).toBeGreaterThan(0);
      for (const t of tags) expect(t.trim()).toMatch(/^v\d+\.\d+\.\d+$/);
    }
    expect(apiCalls).toEqual([]);
  });
});

test.describe("architecture diagram", () => {
  test("every text run sits inside its box, clear of the border, in the page's own fonts", async ({ page }) => {
    await page.setViewportSize({ width: 1440, height: 900 });
    await page.goto("/");
    await page.evaluate(() => document.fonts.ready);
    const report = await page.evaluate(() => {
      const bad: string[] = [];
      document.querySelectorAll<SVGGElement>("#arch .ax-box").forEach((g) => {
        const r = (g.querySelector(".ax-card") as SVGRectElement).getBBox();
        g.querySelectorAll<SVGTextElement>("text").forEach((t) => {
          const b = t.getBBox();
          if (b.x < r.x + 8 || b.x + b.width > r.x + r.width - 8) bad.push(`${g.id}: "${t.textContent}" ${b.x.toFixed(0)}..${(b.x + b.width).toFixed(0)} in ${r.x}..${r.x + r.width}`);
        });
      });
      const fams = new Set([...document.querySelectorAll("#arch text")].map((t) => getComputedStyle(t).fontFamily.split(",")[0].replace(/"/g, "")));
      return { bad, fams: [...fams].sort() };
    });
    expect(report.bad).toEqual([]);
    expect(report.fams).toEqual(["Cutive Mono", "Work Sans"]);
  });

  test("the wire panel replays the loop while the diagram is on screen", async ({ page }) => {
    await page.goto("/");
    await page.locator("#arch").scrollIntoViewIfNeeded();
    await expect(page.locator("#ax-cap0")).toHaveText("1 / 4 · A TRANSFER");
    await expect(page.locator("#ax-l2")).toHaveClass(/lit/, { timeout: 3000 });
    await expect(page.locator("#ax-cap0")).toHaveText("2 / 4 · A $0 SPOOF", { timeout: 6000 });
    await expect(page.locator("#ax-refused")).toHaveClass(/on/, { timeout: 4000 });
  });

  test("reduced motion keeps the static diagram; phones get the stacked ledger instead", async ({ browser }) => {
    const base = test.info().project.use.baseURL;
    const still = await browser.newContext({ reducedMotion: "reduce", baseURL: base });
    let page = await still.newPage();
    await page.goto("/");
    await page.locator("#arch").scrollIntoViewIfNeeded();
    await page.waitForTimeout(1500);
    await expect(page.locator("#ax-cap0")).toHaveText("HOW TO READ IT");
    expect(await page.locator("#arch .lit, #arch .on").count()).toBe(0);
    await still.close();
    const phone = await browser.newContext({ viewport: { width: 390, height: 844 }, baseURL: base });
    page = await phone.newPage();
    await page.goto("/");
    await expect(page.locator("#arch")).toBeHidden();
    await expect(page.locator(".arch-phone .ap-card")).toHaveCount(8);
    await expect(page.locator(".arch-phone")).toBeVisible();
    await phone.close();
  });
});
