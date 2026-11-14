import { defineConfig } from "vitest/config";

// Unit tests for the TypeScript half of packages/reactive-kit. RPC access is mocked at the viem boundary, so the
// suite needs no network and no keys; the live paths are exercised by scripts/ against Lasna + Base Sepolia.
export default defineConfig({
  test: {
    include: ["packages/reactive-kit/ts/**/*.test.ts"],
    // trigger.test.ts changes the working directory to check the default evidence path; threads cannot chdir.
    pool: "forks",
    coverage: {
      provider: "v8",
      include: ["packages/reactive-kit/ts/**/*.ts"],
      exclude: ["packages/reactive-kit/ts/**/*.test.ts"],
      reporter: ["text", "text-summary", "json-summary", "lcov"],
      thresholds: { lines: 100, statements: 100, functions: 100, branches: 100 },
    },
  },
});
