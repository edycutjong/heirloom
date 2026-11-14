import { expect, test } from "./fixtures";

test.describe("pitch deck", () => {
  test("has 10 slides and steps with the keyboard", async ({ page }) => {
    await page.goto("/pitch/");
    await expect(page.locator(".frame")).toHaveCount(10);
    await expect(page.locator("#pos")).toHaveText("1 / 10");
    await page.keyboard.press("ArrowRight");
    await expect(page.locator("#pos")).toHaveText("2 / 10");
    await page.keyboard.press("End");
    await expect(page.locator("#pos")).toHaveText("10 / 10");
  });

  test("the last slide links the judge page and the latest release", async ({ page }) => {
    await page.goto("/pitch/#10");
    const last = page.locator('.frame[data-n="10"]');
    await expect(last.locator('a[href="../judge/"]')).toBeVisible();
    await expect(last.locator("[data-release]")).toHaveAttribute("href", "https://github.com/edycutjong/heirloom/releases/latest");
  });
});
