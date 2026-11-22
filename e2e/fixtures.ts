import { test as base, expect } from "@playwright/test";

/** The one-sentence claim: the elevator pitch, verbatim, on /judge/, JUDGE.md and the README. */
export const CLAIM =
  "When your wallet goes quiet, silence pays your heir. A Reactive dead-man's switch: no keeper, no check-in required, spoofs refused.";

/** Pages with every non-local request aborted (fonts are self-hosted; explorers, RPCs and the GitHub API are not
 *  needed to render). A test that wants the network opts in with `allow`. */
export const test = base.extend<{ allow: RegExp[] }>({
  allow: [[], { option: true }],
  page: async ({ page, allow }, use) => {
    await page.route(/^https?:\/\//, (route) => {
      const url = route.request().url();
      if (url.startsWith("http://127.0.0.1") || allow.some((r) => r.test(url))) return route.continue();
      return route.abort();
    });
    await use(page);
  },
});
export { expect };
