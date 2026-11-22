import { describe, expect, test } from "vitest";
import { mkdtempSync, readFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { appendTriples, hopSeconds, parseCsvLine, readTriples, toCsvLine, TRIPLE_COLUMNS, type TripleRow } from "./triples.ts";
import { percentile } from "./latency.ts";
import { assertSameNetworkClass, chain } from "./chains.ts";

const row = (o: Partial<TripleRow>): TripleRow =>
  Object.fromEntries(TRIPLE_COLUMNS.map((c) => [c, o[c] ?? ""])) as TripleRow;

describe("reactive-kit (pure helpers)", () => {
  test("csv round-trips notes with commas and quotes", () => {
    const r = row({ stage: "PROBE", seq: "1", note: 'a, "b", c' });
    expect(parseCsvLine(toCsvLine(r))).toEqual(TRIPLE_COLUMNS.map((c) => r[c]));
  });

  test("appendTriples upserts per (instance, stage, seq, reactive tx); a re-join fixes, never blanks, a row", () => {
    const p = join(mkdtempSync(join(tmpdir(), "kit-")), "t.csv");
    const a = row({ stage: "GRACE", seq: "1", trigger_tx: "0xAA", reactive_tx: "0xR1", instance: "demo", callback_tx: "0x01" });
    const rejoin = { ...a, reactive_tx: "0xr1", trigger_tx: "0xBB", callback_tx: "" };
    expect(appendTriples(p, [a])).toBe(1);
    expect(appendTriples(p, [rejoin, row({ stage: "GRACE", seq: "2", reactive_tx: "0xR2", instance: "demo" })])).toBe(1);
    const rows = readTriples(p);
    expect(rows.length).toBe(2);
    expect(rows[0].trigger_tx, "the corrected trigger replaces the stale one in place").toBe("0xBB");
    expect(rows[0].callback_tx, "a leg the re-join missed is kept").toBe("0x01");
    expect(readFileSync(p, "utf8").split("\n")[0]).toBe(TRIPLE_COLUMNS.join(","));
  });

  test("appendTriples: the callback leg is replaced only by an earlier callback (a replayed Ack never wins)", () => {
    const p = join(mkdtempSync(join(tmpdir(), "kit-")), "t.csv");
    const base = { stage: "CANCEL", seq: "4", reactive_tx: "0xR4", instance: "demo", callback_chain: "84532" };
    appendTriples(p, [row({ ...base, trigger_tx: "0xAA", callback_tx: "0xAPPLY", callback_ts: "200" })]);
    appendTriples(p, [row({ ...base, trigger_tx: "0xBB", callback_tx: "0xREPLAY", callback_ts: "260" })]);
    let r = readTriples(p)[0];
    expect(r.callback_tx, "a later (replay) Ack does not replace the applying one").toBe("0xAPPLY");
    expect(r.callback_ts).toBe("200");
    expect(r.trigger_tx, "non-callback fields still take the re-join").toBe("0xBB");
    appendTriples(p, [row({ ...base, callback_tx: "0xEARLIER", callback_ts: "150" })]);
    r = readTriples(p)[0];
    expect(r.callback_tx, "an earlier callback repairs a row that had locked in a replay").toBe("0xEARLIER");
    expect(r.callback_ts).toBe("150");
    const q = join(mkdtempSync(join(tmpdir(), "kit-")), "t.csv");
    appendTriples(q, [row({ ...base, callback_tx: "" })]);
    appendTriples(q, [row({ ...base, callback_tx: "0xFILL", callback_ts: "300" })]);
    expect(readTriples(q)[0].callback_tx, "a blank callback leg is filled").toBe("0xFILL");
  });

  test("appendTriples: a re-join that misses the Ack keeps the note of the row that cites one", () => {
    const p = join(mkdtempSync(join(tmpdir(), "kit-")), "t.csv");
    const base = { stage: "EXPIRE", seq: "7", reactive_tx: "0xaa", instance: "demo" };
    appendTriples(p, [row({ ...base, callback_chain: "84532", callback_tx: "0xcb", callback_ts: "100", note: "seq 7; tries 1; vault 1->2" })]);
    appendTriples(p, [row({ ...base, note: "seq 7; tries 1; no Ack found" })]);
    const r = readTriples(p)[0];
    expect(r.callback_tx).toBe("0xcb");
    expect(r.note, "the kept leg keeps its note").toBe("seq 7; tries 1; vault 1->2");
    const q = join(mkdtempSync(join(tmpdir(), "kit-")), "t.csv");
    appendTriples(q, [row({ ...base, note: "seq 7; no Ack found" })]);
    appendTriples(q, [row({ ...base, note: "seq 7; still none" })]);
    expect(readTriples(q)[0].note, "a row without a leg takes the newer note").toBe("seq 7; still none");
  });

  test("hopSeconds and missing legs", () => {
    const h = hopSeconds(row({ trigger_ts: "100", reactive_ts: "101", callback_ts: "103" }));
    expect(h).toEqual({ triggerToReactive: 1, reactiveToCallback: 2, total: 3 });
    expect(Number.isNaN(hopSeconds(row({ trigger_ts: "1", reactive_ts: "2" })).total)).toBe(true);
  });

  test("percentile is nearest-rank (always an observed value)", () => {
    expect(percentile([5, 1, 3, 2, 4], 50)).toBe(3);
    expect(percentile([5, 1, 3, 2, 4], 95)).toBe(5);
    expect(percentile([7], 95)).toBe(7);
    expect(Number.isNaN(percentile([], 50))).toBe(true);
  });

  test("chains: testnet and mainnet are never mixed", () => {
    expect(() => assertSameNetworkClass([5318007, 84532, 11155111, 1301])).not.toThrow();
    expect(() => assertSameNetworkClass([5318007, 8453])).toThrow(/mixed testnet and mainnet/);
    expect(chain(84532).logSpan).toBe(180n);
  });
});
