import { expect, test } from "./fixtures";

for (const { name, width, height } of [
  { name: "phone", width: 375, height: 812 },
  { name: "tablet", width: 768, height: 1024 },
  { name: "desktop", width: 1440, height: 900 },
]) {
  test(`no horizontal scroll on landing and judge page (${name} ${width}px)`, async ({ page }) => {
    await page.setViewportSize({ width, height });
    for (const path of ["/", "/judge/"]) {
      await page.goto(path);
      const overflow = await page.evaluate(() => document.documentElement.scrollWidth - document.documentElement.clientWidth);
      expect(overflow, `${path} overflows by ${overflow}px`).toBeLessThanOrEqual(0);
    }
  });
}
