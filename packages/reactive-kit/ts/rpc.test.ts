// RPC-facing helpers with viem's public client mocked at the module boundary: no network, no keys.
import { afterEach, beforeEach, describe, expect, test, vi } from "vitest";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { AbiEvent } from "viem";

const fake = vi.hoisted(() => ({
  getBlockNumber: vi.fn(),
  getLogs: vi.fn(),
  getBlock: vi.fn(),
  getTransactionReceipt: vi.fn(),
  waitForTransactionReceipt: vi.fn(),
}));
const viemMock = vi.hoisted(() => ({
  createPublicClient: vi.fn(() => fake),
  http: vi.fn((url: string) => ({ url })),
}));
vi.mock("viem", async (orig) => ({ ...(await orig<typeof import("viem")>()), ...viemMock }));

const { CHAINS, chain, client } = await import("./chains.ts");
const { observe } = await import("./latency.ts");
const { requireEnv, trigger, ORIGINS_HEADER } = await import("./trigger.ts");
const { blockTs, txInfo, getLogsChunked, buildTriple, readTriples, appendTriples, toCsvLine, TRIPLE_COLUMNS } =
  await import("./triples.ts");

const EVENT = { type: "event", name: "Ping", inputs: [] } as const satisfies AbiEvent;
const ADDR = "0x00000000000000000000000000000000000000aa" as const;
const tx = (n: number) => `0x${n.toString(16).padStart(64, "0")}` as const;

beforeEach(() => {
  for (const f of Object.values(fake)) f.mockReset();
});

describe("chains", () => {
  test("chain() throws on an unknown id instead of guessing an RPC", () => {
    expect(() => chain(1)).toThrow("unknown chain 1");
    expect(chain(5318007).name).toBe("Reactive Lasna");
    expect(Object.keys(CHAINS)).toHaveLength(6);
  });

  test("client() reads the RPC from the chain's env var, falls back to the public default, and caches per chain", () => {
    process.env.BASE_RPC = "https://rpc.example/base";
    delete process.env.REACTIVE_RPC;
    client(8453);
    client(8453);
    client(1597);
    const urls = viemMock.http.mock.calls.map((c) => c[0]);
    expect(urls).toContain("https://rpc.example/base");
    expect(urls).toContain("https://mainnet-rpc.rnk.dev/");
    expect(urls.filter((u) => u === "https://rpc.example/base")).toHaveLength(1);
    delete process.env.BASE_RPC;
  });
});

describe("latency.observe", () => {
  test("a leg far behind head is scanned span by span (never more than the chain's getLogs span) without sleeping", async () => {
    const span = chain(84532).logSpan;
    let calls = 0;
    fake.getBlockNumber.mockImplementation(async () => (calls++ < 2 ? 100n : 600n)); // start blocks, then head far ahead
    const ranges: [bigint, bigint][] = [];
    fake.getLogs.mockImplementation(async ({ address, fromBlock, toBlock }: { address: string; fromBlock: bigint; toBlock: bigint }) => {
      if (address === ADDR) return [{ transactionHash: tx(7), args: {} }]; // reactive leg: found at once
      ranges.push([fromBlock, toBlock]);
      return fromBlock > 100n + span ? [{ transactionHash: tx(9), args: {} }] : []; // callback: second span only
    });
    const s = await observe({
      send: async () => tx(1),
      reactive: { chainId: 5318007, address: ADDR, event: EVENT, match: () => true },
      callback: { chainId: 84532, address: "0x00000000000000000000000000000000000000bb", event: EVENT, match: () => true },
      pollMs: 60_000, // a sleep would time the test out
      timeoutMs: 5_000,
    });
    expect(ranges[0]).toEqual([100n, 100n + span]);
    expect(ranges[1][0]).toBe(101n + span);
    expect(ranges.every(([f, e]) => e - f <= span)).toBe(true);
    expect(s.callbackTx).toBe(tx(9));
  });

  test("captures start blocks before sending, then times the reactive and callback legs", async () => {
    const order: string[] = [];
    let head = 10n;
    fake.getBlockNumber.mockImplementation(async () => {
      order.push("head");
      return head;
    });
    fake.getLogs.mockImplementation(async ({ fromBlock }: { fromBlock: bigint }) => [
      { transactionHash: tx(Number(fromBlock)), args: { seq: 1n } },
    ]);
    const s = await observe({
      send: async () => {
        order.push("send");
        head = 11n;
        return tx(1);
      },
      reactive: { chainId: 5318007, address: ADDR, event: EVENT, match: () => true },
      callback: { chainId: 84532, address: ADDR, event: EVENT, match: () => true },
      pollMs: 1,
      timeoutMs: 1_000,
    });
    expect(order.slice(0, 3)).toEqual(["head", "head", "send"]);
    expect(s.originTx).toBe(tx(1));
    expect(s.reactiveTx).toBe(tx(10));
    expect(s.callbackTx).toBe(tx(10));
    expect(s.reactiveSeenAtMs).not.toBeNull();
    expect(s.callbackSeenAtMs).not.toBeNull();
    expect(s.pollMs).toBe(1);
  });

  test("polls past a head that has not reached the start block and past non-matching logs", async () => {
    const heads = [5n, 4n, 5n, 6n];
    fake.getBlockNumber.mockImplementation(async () => heads.shift() ?? 6n);
    fake.getLogs
      .mockResolvedValueOnce([{ transactionHash: tx(99), args: {} }])
      .mockResolvedValueOnce([{ transactionHash: tx(6), args: { hit: true } }]);
    const s = await observe({
      send: async () => tx(2),
      reactive: { chainId: 5318007, address: ADDR, event: EVENT, match: (l) => l.args?.hit === true },
      pollMs: 1,
      timeoutMs: 1_000,
    });
    expect(fake.getLogs).toHaveBeenCalledTimes(2);
    expect(fake.getLogs.mock.calls[1][0].fromBlock).toBe(6n);
    expect(s.reactiveTx).toBe(tx(6));
    expect(s.callbackTx, "no callback leg was asked for").toBeNull();
  });

  test("a leg that never shows up times out to null, and the callback is not waited for", async () => {
    fake.getBlockNumber.mockResolvedValue(1n);
    fake.getLogs.mockResolvedValue([]);
    const s = await observe({
      send: async () => tx(3),
      reactive: { chainId: 5318007, address: ADDR, event: EVENT, match: () => true },
      callback: { chainId: 84532, address: ADDR, event: EVENT, match: () => true },
      pollMs: 1,
      timeoutMs: 15,
    });
    expect(s.reactiveTx).toBeNull();
    expect(s.reactiveSeenAtMs).toBeNull();
    expect(s.callbackTx).toBeNull();
    expect(s.callbackSeenAtMs).toBeNull();
  });

  test("defaults: 500 ms poll and a 180 s budget when the caller sets neither", async () => {
    fake.getBlockNumber.mockResolvedValue(7n);
    fake.getLogs.mockResolvedValue([{ transactionHash: tx(7), args: {} }]);
    const s = await observe({
      send: async () => tx(4),
      reactive: { chainId: 5318007, address: ADDR, event: EVENT, match: () => true },
    });
    expect(s.pollMs).toBe(500);
    expect(s.reactiveTx).toBe(tx(7));
  });
});

describe("trigger", () => {
  let dir: string;
  beforeEach(() => {
    dir = mkdtempSync(join(tmpdir(), "kit-trigger-"));
  });

  test("requireEnv refuses a missing key and points at ~/.config, never the repo", () => {
    delete process.env.HEIRLOOM_TEST_KEY;
    expect(() => requireEnv("HEIRLOOM_TEST_KEY")).toThrow(/never commit it/);
    process.env.HEIRLOOM_TEST_KEY = "set";
    expect(requireEnv("HEIRLOOM_TEST_KEY")).toBe("set");
    delete process.env.HEIRLOOM_TEST_KEY;
  });

  test("records one origins.csv row per mined origin tx and writes the header once", async () => {
    fake.waitForTransactionReceipt.mockResolvedValue({ status: "success", blockNumber: 42n });
    const out = join(dir, "origins.csv");
    const a = await trigger({ chainId: 84532, kind: "heartbeat", instance: "demo", send: async () => tx(5), out });
    await trigger({ chainId: 84532, kind: "spoof", instance: "demo", send: async () => tx(6), out });
    expect(a.block).toBe(42n);
    expect(a.minedAtMs).toBeGreaterThanOrEqual(a.sentAtMs);
    const lines = readFileSync(out, "utf8").trim().split("\n");
    expect(lines[0]).toBe(ORIGINS_HEADER);
    expect(lines).toHaveLength(3);
    expect(lines[1].split(",").slice(0, 4)).toEqual(["84532", "heartbeat", tx(5), "42"]);
    expect(lines[2].split(",").at(-1)).toBe("demo");
  });

  test("a reverted origin tx throws and is not logged as evidence", async () => {
    fake.waitForTransactionReceipt.mockResolvedValue({ status: "reverted", blockNumber: 1n });
    const out = join(dir, "origins.csv");
    await expect(trigger({ chainId: 84532, kind: "spoof", instance: "x", send: async () => tx(7), out })).rejects.toThrow(
      /origin tx reverted/,
    );
    expect(existsSync(out)).toBe(false);
  });

  describe("default output path", () => {
    const cwd = process.cwd();
    afterEach(() => process.chdir(cwd));
    test("writes to evidence/origins.csv relative to the working directory", async () => {
      fake.waitForTransactionReceipt.mockResolvedValue({ status: "success", blockNumber: 9n });
      mkdirSync(join(dir, "evidence"));
      process.chdir(dir);
      await trigger({ chainId: 84532, kind: "heartbeat", instance: "demo", send: async () => tx(8) });
      expect(readFileSync(join(dir, "evidence", "origins.csv"), "utf8")).toContain(tx(8));
    });
  });
});

describe("triples (RPC side)", () => {
  test("blockTs caches per (chain, block) so a re-join does not refetch", async () => {
    fake.getBlock.mockResolvedValue({ timestamp: 1_700_000_000n });
    expect(await blockTs(84532, 123n)).toBe(1_700_000_000);
    expect(await blockTs(84532, 123n)).toBe(1_700_000_000);
    expect(fake.getBlock).toHaveBeenCalledTimes(1);
  });

  test("txInfo returns block, timestamp and receipt status", async () => {
    fake.getTransactionReceipt.mockResolvedValue({ blockNumber: 500n, status: "success" });
    fake.getBlock.mockResolvedValue({ timestamp: 1_700_000_500n });
    expect(await txInfo(84532, tx(9))).toEqual({ block: 500n, ts: 1_700_000_500, status: "success" });
  });

  test("regression: getLogsChunked never asks Base Sepolia for more than its 180-block span (sepolia.base.org caps at 200)", async () => {
    fake.getLogs.mockImplementation(async ({ fromBlock }: { fromBlock: bigint }) => [{ blockNumber: fromBlock }]);
    const logs = await getLogsChunked(84532, { address: ADDR, event: EVENT, fromBlock: 0n, toBlock: 400n });
    const spans = fake.getLogs.mock.calls.map((c) => [c[0].fromBlock, c[0].toBlock]);
    expect(spans).toEqual([
      [0n, 180n],
      [181n, 361n],
      [362n, 400n],
    ]);
    expect(logs).toHaveLength(3);
  });

  test("getLogsChunked reads to the chain head when no toBlock is given", async () => {
    fake.getBlockNumber.mockResolvedValue(50n);
    fake.getLogs.mockResolvedValue([]);
    await getLogsChunked(5318007, { address: ADDR, event: EVENT, fromBlock: 10n, args: { seq: 1n } });
    expect(fake.getLogs).toHaveBeenCalledWith(expect.objectContaining({ fromBlock: 10n, toBlock: 50n, args: { seq: 1n } }));
  });

  test("buildTriple fills all three legs from chain timestamps", async () => {
    fake.getTransactionReceipt.mockImplementation(async ({ hash }: { hash: string }) => ({
      blockNumber: BigInt(parseInt(hash.slice(-4), 16)) + 1000n,
      status: "success",
    }));
    fake.getBlock.mockImplementation(async ({ blockNumber }: { blockNumber: bigint }) => ({ timestamp: blockNumber * 10n }));
    const r = await buildTriple({
      stage: "GRACE",
      seq: 3n,
      triggerKind: "cron",
      triggerChain: 5318007,
      triggerTx: tx(1),
      reactiveChain: 5318007,
      reactiveTx: tx(2),
      callback: { chainId: 84532, tx: tx(3) },
      lastActivity: { chainId: 1301, tx: tx(4) },
      instance: "demo",
      note: "armed",
    });
    expect(r).toMatchObject({
      stage: "GRACE",
      seq: "3",
      trigger_kind: "cron",
      trigger_chain: "5318007",
      trigger_ts: "10010",
      reactive_ts: "10020",
      callback_chain: "84532",
      callback_tx: tx(3),
      callback_ts: "10030",
      last_activity_chain: "1301",
      last_activity_tx: tx(4),
      note: "armed",
    });
  });

  test("buildTriple leaves the callback and last-activity legs blank for reactive-only stages", async () => {
    fake.getTransactionReceipt.mockResolvedValue({ blockNumber: 2000n, status: "success" });
    fake.getBlock.mockResolvedValue({ timestamp: 5n });
    const r = await buildTriple({
      stage: "REFUSED",
      seq: 1,
      triggerKind: "origin_log",
      triggerChain: 84532,
      triggerTx: tx(5),
      reactiveChain: 5318007,
      reactiveTx: tx(6),
      instance: "long-t",
    });
    expect([r.callback_chain, r.callback_tx, r.callback_ts, r.last_activity_chain, r.last_activity_tx, r.note]).toEqual([
      "", "", "", "", "", "",
    ]);
  });
});

describe("triples (CSV edge cases)", () => {
  test("readTriples on a missing file is empty, and a short row pads missing cells with blanks", () => {
    const d = mkdtempSync(join(tmpdir(), "kit-csv-"));
    expect(readTriples(join(d, "none.csv"))).toEqual([]);
    const p = join(d, "short.csv");
    writeFileSync(p, `${TRIPLE_COLUMNS.join(",")}\nGRACE,1\n`);
    const [r] = readTriples(p);
    expect(r.stage).toBe("GRACE");
    expect(r.note).toBe("");
  });

  test("toCsvLine writes an absent field as an empty cell", () => {
    const partial = { stage: "VISIT" } as unknown as Parameters<typeof toCsvLine>[0];
    expect(toCsvLine(partial)).toBe("VISIT" + ",".repeat(TRIPLE_COLUMNS.length - 1));
  });

  test("regression: a callback leg with an unparseable or missing timestamp never displaces a stored one", () => {
    const d = mkdtempSync(join(tmpdir(), "kit-csv-"));
    const p = join(d, "t.csv");
    const blank = Object.fromEntries(TRIPLE_COLUMNS.map((c) => [c, ""]));
    const key = { ...blank, stage: "EXPIRE", seq: "1", reactive_tx: "0xR", instance: "i" };
    appendTriples(p, [{ ...key, callback_tx: "0xFIRST", callback_ts: "100" } as never]);
    appendTriples(p, [{ ...key, callback_tx: "0xNOTS", callback_ts: "" } as never]);
    appendTriples(p, [{ ...key, callback_tx: "0xNAN", callback_ts: "soon" } as never]);
    appendTriples(p, [{ ...key, note: undefined, callback_tx: "0xLATER", callback_ts: "900" } as never]);
    expect(readTriples(p)[0].callback_tx).toBe("0xFIRST");
    const q = join(d, "u.csv");
    appendTriples(q, [{ ...key, callback_tx: "0xSTORED", callback_ts: "" } as never]);
    appendTriples(q, [{ ...key, callback_tx: "0xNEXT", callback_ts: "50" } as never]);
    expect(readTriples(q)[0].callback_tx, "a stored leg without a timestamp is kept").toBe("0xSTORED");
  });
});
