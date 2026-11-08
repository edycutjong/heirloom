// Tx-triple logger: origin (or CRON) tx -> reactive tx -> callback tx, with on-chain timestamps.
// Joins by data the contracts emit themselves (the RC logs the origin tx hash + a seq; the destination logs the seq),
// so it needs nothing but eth_getLogs on each chain. Output: evidence/triples.csv (append-only, first row per key wins).
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import type { AbiEvent, Log } from "viem";
import { chain, client } from "./chains.ts";

export const TRIPLE_COLUMNS = [
  "stage", "seq", "trigger_kind", "trigger_chain", "trigger_tx", "trigger_ts", "reactive_tx", "reactive_ts",
  "callback_chain", "callback_tx", "callback_ts", "last_activity_chain", "last_activity_tx", "instance", "note",
] as const;
export type TripleColumn = (typeof TRIPLE_COLUMNS)[number];
export type TripleRow = Record<TripleColumn, string>;

export type Hex = `0x${string}`;

const tsCache = new Map<string, number>();

/** Unix seconds of a block (cached). */
export async function blockTs(chainId: number, blockNumber: bigint): Promise<number> {
  const k = `${chainId}:${blockNumber}`;
  const hit = tsCache.get(k);
  if (hit !== undefined) return hit;
  const b = await client(chainId).getBlock({ blockNumber });
  const ts = Number(b.timestamp);
  tsCache.set(k, ts);
  return ts;
}

/** Block number + timestamp of a mined tx. */
export async function txInfo(chainId: number, hash: Hex): Promise<{ block: bigint; ts: number; status: string }> {
  const r = await client(chainId).getTransactionReceipt({ hash });
  return { block: r.blockNumber, ts: await blockTs(chainId, r.blockNumber), status: r.status };
}

/** eth_getLogs split into the chain's accepted block span. */
export async function getLogsChunked(
  chainId: number,
  q: { address: Hex; event: AbiEvent; fromBlock: bigint; toBlock?: bigint; args?: Record<string, unknown> },
): Promise<Log[]> {
  const c = client(chainId);
  const to = q.toBlock ?? (await c.getBlockNumber());
  const span = chain(chainId).logSpan;
  const out: Log[] = [];
  for (let from = q.fromBlock; from <= to; from += span + 1n) {
    const end = from + span > to ? to : from + span;
    const logs = await c.getLogs({ address: q.address, event: q.event, args: q.args as never, fromBlock: from, toBlock: end });
    out.push(...(logs as Log[]));
  }
  return out;
}

/** Build one row from known tx hashes (timestamps fetched from chain). */
export async function buildTriple(p: {
  stage: string;
  seq: string | number | bigint;
  triggerKind: "origin_log" | "cron";
  triggerChain: number;
  triggerTx: Hex;
  reactiveChain: number;
  reactiveTx: Hex;
  callback?: { chainId: number; tx: Hex };
  lastActivity?: { chainId: number; tx: Hex };
  instance: string;
  note?: string;
}): Promise<TripleRow> {
  const trig = await txInfo(p.triggerChain, p.triggerTx);
  const rx = await txInfo(p.reactiveChain, p.reactiveTx);
  const cb = p.callback ? await txInfo(p.callback.chainId, p.callback.tx) : undefined;
  return {
    stage: p.stage,
    seq: String(p.seq),
    trigger_kind: p.triggerKind,
    trigger_chain: String(p.triggerChain),
    trigger_tx: p.triggerTx,
    trigger_ts: String(trig.ts),
    reactive_tx: p.reactiveTx,
    reactive_ts: String(rx.ts),
    callback_chain: p.callback ? String(p.callback.chainId) : "",
    callback_tx: p.callback?.tx ?? "",
    callback_ts: cb ? String(cb.ts) : "",
    last_activity_chain: p.lastActivity ? String(p.lastActivity.chainId) : "",
    last_activity_tx: p.lastActivity?.tx ?? "",
    instance: p.instance,
    note: p.note ?? "",
  };
}

// ---- CSV (no quoting needed except notes; notes are quoted when they contain commas) ----

function cell(v: string): string {
  return /[",\n]/.test(v) ? `"${v.replace(/"/g, '""')}"` : v;
}

export function toCsvLine(row: TripleRow): string {
  return TRIPLE_COLUMNS.map((c) => cell(row[c] ?? "")).join(",");
}

export function parseCsvLine(line: string): string[] {
  const out: string[] = [];
  let cur = "";
  let q = false;
  for (let i = 0; i < line.length; i++) {
    const ch = line[i];
    if (q) {
      if (ch === '"' && line[i + 1] === '"') { cur += '"'; i++; }
      else if (ch === '"') q = false;
      else cur += ch;
    } else if (ch === '"') q = true;
    else if (ch === ",") { out.push(cur); cur = ""; }
    else cur += ch;
  }
  out.push(cur);
  return out;
}

export function readTriples(path: string): TripleRow[] {
  if (!existsSync(path)) return [];
  const [header, ...lines] = readFileSync(path, "utf8").split("\n").filter((l) => l.trim());
  const cols = parseCsvLine(header);
  return lines.map((l) => {
    const v = parseCsvLine(l);
    return Object.fromEntries(cols.map((c, i) => [c, v[i] ?? ""])) as TripleRow;
  });
}

/** Identity of a row: the first callback per (instance, stage, seq) wins, duplicates are dropped. */
export function rowKey(r: TripleRow): string {
  return `${r.instance}|${r.stage}|${r.seq}|${r.trigger_tx.toLowerCase()}|${r.reactive_tx.toLowerCase()}`;
}

/** Append rows that are not already present. Returns the number written. */
export function appendTriples(path: string, rows: TripleRow[]): number {
  const existing = readTriples(path);
  const seen = new Set(existing.map(rowKey));
  const fresh = rows.filter((r) => {
    const k = rowKey(r);
    if (seen.has(k)) return false;
    seen.add(k);
    return true;
  });
  const all = [...existing, ...fresh];
  writeFileSync(path, [TRIPLE_COLUMNS.join(","), ...all.map(toCsvLine)].join("\n") + "\n");
  return fresh.length;
}

/** Seconds between hops of a row (NaN when a leg is missing). */
export function hopSeconds(r: TripleRow): { triggerToReactive: number; reactiveToCallback: number; total: number } {
  const t = Number(r.trigger_ts), x = Number(r.reactive_ts), c = r.callback_ts ? Number(r.callback_ts) : NaN;
  return { triggerToReactive: x - t, reactiveToCallback: c - x, total: c - t };
}
