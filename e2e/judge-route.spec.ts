import { CLAIM, expect, test } from "./fixtures";

test.describe("/judge/ — the page built for one reader", () => {
  test("answers 200 with no credentials, no cookies and no session, and carries the claim sentence", async ({ playwright, baseURL }) => {
    const anon = await playwright.request.newContext({ baseURL, storageState: { cookies: [], origins: [] } });
    const res = await anon.get("/judge/", { maxRedirects: 0 });
    expect(res.status()).toBe(200);
    const html = await res.text();
    expect(html).toContain(CLAIM);
    expect(html, "no unfilled count placeholders").not.toMatch(/__[A-Z]+__/);
    await anon.dispose();
  });

  test("renders the claim, the six-step path, receipts, the real reproduce command and the limits", async ({ page }) => {
    await page.goto("/judge/");
    await expect(page.locator("#claim")).toHaveText(CLAIM);
    await expect(page.locator("ol.path > li")).toHaveCount(6);
    const explorer = page.locator('ol.path a[href^="https://lasna.reactscan.net/tx/"], ol.path a[href^="https://sepolia.basescan.org/tx/"]');
    expect(await explorer.count()).toBeGreaterThanOrEqual(12);
    await expect(page.locator("#repro").locator("..").locator("pre")).toContainText("PRIVATE_KEY=0x… pnpm exec tsx scripts/trigger-spoof.ts");
    await expect(page.locator("#limits").locator("..").locator("li")).toHaveCount(3);
    await expect(page.getByRole("link", { name: /Repository/ })).toHaveAttribute("href", "https://github.com/edycutjong/heirloom");
  });

  test("every receipt row has a value and a source", async ({ page }) => {
    await page.goto("/judge/");
    const rows = page.locator("#receipts ~ table tbody tr");
    expect(await rows.count()).toBeGreaterThanOrEqual(6);
    for (const v of await page.locator("#receipts ~ table td.v").allTextContents()) expect(v.trim()).toMatch(/\d/);
  });
});
