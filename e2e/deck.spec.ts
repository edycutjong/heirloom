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

  test.describe("slide controls at 16:9 (the recording size)", () => {
    test.use({ viewport: { width: 1366, height: 768 } });
    test("never sit on footer text while awake, and hide after 2.5 s idle", async ({ page }) => {
      for (const n of [1, 6, 10]) {
        await page.goto(`/pitch/#${n}`);
        await page.mouse.move(400, 300);
        await expect(page.locator("body")).toHaveClass(/\bawake\b/);
        const hits = await page.evaluate(() => {
          const foot = [...document.querySelectorAll(".frame.on .foot span, .frame.on .foot a")]
            .filter((e) => getComputedStyle(e).visibility === "visible").map((e) => e.getBoundingClientRect());
          return [...document.querySelectorAll(".ctl button, .ctl span")].filter((c) => {
            const r = c.getBoundingClientRect();
            return foot.some((f) => r.left < f.right && r.right > f.left && r.top < f.bottom && r.bottom > f.top);
          }).length;
        });
        expect(hits, `slide ${n}`).toBe(0);
      }
      await expect(page.locator("body")).toHaveClass(/\bidle\b/, { timeout: 4_000 });
      await expect(page.locator(".ctl")).toHaveCSS("opacity", "0");
    });
  });

  test.describe("slide controls with a letterbox band", () => {
    test.use({ viewport: { width: 1440, height: 1100 } });
    test("stay visible in the band below the stage", async ({ page }) => {
      await page.goto("/pitch/");
      await expect(page.locator("body")).toHaveClass(/\broomy\b/);
      await page.waitForTimeout(3_000);
      await expect(page.locator("body")).not.toHaveClass(/\bidle\b/);
      await expect(page.locator("#next")).toBeVisible();
    });
  });
});
