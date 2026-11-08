import { test } from "node:test";
import assert from "node:assert/strict";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { appendTriples, hopSeconds, parseCsvLine, readTriples, toCsvLine, TRIPLE_COLUMNS, type TripleRow } from "./triples.ts";
import { percentile } from "./latency.ts";
import { assertSameNetworkClass, chain } from "./chains.ts";

const row = (o: Partial<TripleRow>): TripleRow =>
  Object.fromEntries(TRIPLE_COLUMNS.map((c) => [c, o[c] ?? ""])) as TripleRow;

test("csv round-trips notes with commas and quotes", () => {
  const r = row({ stage: "PROBE", seq: "1", note: 'a, "b", c' });
  assert.deepEqual(parseCsvLine(toCsvLine(r)), TRIPLE_COLUMNS.map((c) => r[c]));
});

test("appendTriples keeps the first row per (instance, stage, seq, trigger)", () => {
  const p = join(mkdtempSync(join(tmpdir(), "kit-")), "t.csv");
  const a = row({ stage: "GRACE", seq: "1", trigger_tx: "0xAA", instance: "demo", callback_tx: "0x01" });
  const dup = { ...a, trigger_tx: "0xaa", callback_tx: "0x02" };
  assert.equal(appendTriples(p, [a]), 1);
  assert.equal(appendTriples(p, [dup, row({ stage: "GRACE", seq: "2", instance: "demo" })]), 1);
  const rows = readTriples(p);
  assert.equal(rows.length, 2);
  assert.equal(rows[0].callback_tx, "0x01");
  assert.equal(readFileSync(p, "utf8").split("\n")[0], TRIPLE_COLUMNS.join(","));
});

test("hopSeconds and missing legs", () => {
  const h = hopSeconds(row({ trigger_ts: "100", reactive_ts: "101", callback_ts: "103" }));
  assert.deepEqual(h, { triggerToReactive: 1, reactiveToCallback: 2, total: 3 });
  assert.ok(Number.isNaN(hopSeconds(row({ trigger_ts: "1", reactive_ts: "2" })).total));
});

test("percentile is nearest-rank (always an observed value)", () => {
  assert.equal(percentile([5, 1, 3, 2, 4], 50), 3);
  assert.equal(percentile([5, 1, 3, 2, 4], 95), 5);
  assert.equal(percentile([7], 95), 7);
  assert.ok(Number.isNaN(percentile([], 50)));
});

test("chains: testnet and mainnet are never mixed", () => {
  assert.doesNotThrow(() => assertSameNetworkClass([5318007, 84532, 11155111, 1301]));
  assert.throws(() => assertSameNetworkClass([5318007, 8453]));
  assert.equal(chain(84532).logSpan, 180n);
});
