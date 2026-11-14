import { expect, test } from "./fixtures";

test.describe("status card", () => {
  test("serves the static shell and the committed evidence snapshot", async ({ page, request }) => {
    const res = await page.goto("/status/");
    expect(res?.status()).toBe(200);
    await expect(page.locator("h1")).toHaveText("Heirloom");
    await expect(page.locator("#rows thead th")).toHaveCount(5);
    const snap = await request.get("/status/data/status.json");
    expect(snap.status()).toBe(200);
    const json = await snap.json();
    expect(json.instances.map((i: { id: string }) => i.id)).toEqual(expect.arrayContaining(["long-t", "demo"]));
  });

  test.describe("with the viem module reachable and every RPC down", () => {
    test.use({ allow: [/^https:\/\/esm\.sh\//] });
    test("falls back to the committed evidence and says so", async ({ page, request }) => {
      const probe = await request.get("https://esm.sh/viem@2.57.16", { timeout: 10_000 }).catch(() => null);
      test.skip(!probe?.ok(), "esm.sh unreachable from this runner; the shell test above still ran");
      await page.goto("/status/");
      await expect(page.locator("#label")).not.toHaveText("Loading…", { timeout: 20_000 });
      await expect(page.locator("#tbody tr").first()).toBeVisible();
    });
  });
});
