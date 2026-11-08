// Rebuilds the evidence rows of one Heirloom instance from on-chain logs only and appends them to evidence/triples.csv.
//   callback stages (GRACE, CANCEL, EXPIRE, ATTEST, REVIVE): trigger -> reactive tx (CallbackSent, first send per seq) -> vault Ack(seq) on Base
//   reactive-only rows: VISIT (accepted heartbeat, no callback needed), REFUSED (spoof), TEARDOWN (EstateReleased / Retired / terminal Ack)
// The callback leg is checked, not assumed: the Base tx must go to the callback proxy and carry the vault's Ack(seq).
// Usage: ADDR=evidence/<instance>-addresses.txt tsx scripts/heirloom-triples.ts
import { readFileSync, writeFileSync } from "node:fs";
import { decodeEventLog, parseAbi, type Log } from "viem";
import { appendTriples, buildTriple, type Hex, type TripleRow } from "../packages/reactive-kit/ts/triples.ts";
import { chain, client } from "../packages/reactive-kit/ts/chains.ts";

// RC chain / destination chain: Lasna + Base Sepolia by default; RC_CHAIN=1597 BASE_CHAIN=8453 for a mainnet instance
const LASNA = Number(process.env.RC_CHAIN ?? 5318007), BASE_SEPOLIA = Number(process.env.BASE_CHAIN ?? 84532);
const CRON_EMITTER = "0x0000000000000000000000000000000000fffFfF";
const env = Object.fromEntries(
  readFileSync(process.env.ADDR ?? "evidence/p1b-e2e-addresses.txt", "utf8").trim().split("\n").map((l) => l.split("=") as [string, string]),
);
const RC = env.RC as Hex, VAULT = env.VAULT as Hex, INSTANCE = env.INSTANCE;

const rcAbi = parseAbi([
  "event Seen(uint256 indexed chainId, address indexed token, uint256 originTx)",
  "event SpoofRefused(uint256 indexed chainId, address indexed token, uint256 originTx, uint8 reason)",
  "event SpamBrake(uint256 indexed chainId, address indexed token, uint64 until)",
  "event CallbackSent(uint64 indexed seq, uint8 kind, uint8 tries)",
  "event CallbackStuck(uint64 indexed seq)",
  "event Acked(uint64 indexed seq, uint256 ackTx)",
  "event OwnerVersionAdopted(uint64 nonce, bytes32 actionId, uint256 ackTx)",
  "event PhaseChanged(uint8 from, uint8 to)",
  "event FreezeUsed(uint64 newDeadline)",
  "event CanaryArmed(uint256 indexed chainId)",
  "event CanaryBeat(uint256 indexed chainId, uint64 gap)",
  "event TornDown(uint256 trigger)",
]);
const vaultAbi = parseAbi([
  "event Ack(uint64 indexed seq, uint64 ownerNonce, bytes32 ownerActionId, bool terminal)",
  "event StateChanged(uint8 from, uint8 to, uint64 seq)",
  "event EstateReleased()",
  "event Retired()",
  "event OwnerActive(uint8 indexed kind, uint64 nonce, bytes32 actionId)",
]);
const KIND = ["ATTEST", "GRACE", "CANCEL", "EXPIRE", "REVIVE"];
const REASON = ["MALFORMED", "NOT_ALLOWLISTED", "NOT_OWNER", "ZERO_VALUE"];
const hex32 = (n: bigint) => ("0x" + n.toString(16).padStart(64, "0")) as Hex;

type D = { tx: Hex; block: bigint; index: number; name: string; args: Record<string, any> };

async function logs(chainId: number, address: Hex, from: bigint, abi: any): Promise<D[]> {
  const c = client(chainId);
  const to = await c.getBlockNumber();
  const span = chain(chainId).logSpan;
  const out: D[] = [];
  for (let f = from; f <= to; f += span + 1n) {
    const e = f + span > to ? to : f + span;
    for (const l of (await c.getLogs({ address, fromBlock: f, toBlock: e })) as Log[]) {
      try {
        const d = decodeEventLog({ abi, data: l.data, topics: l.topics as any }) as any;
        out.push({ tx: l.transactionHash as Hex, block: l.blockNumber!, index: l.logIndex!, name: d.eventName, args: d.args });
      } catch { /* not ours */ }
    }
  }
  return out;
}

async function cronTx(reactBlock: bigint): Promise<Hex | undefined> {
  const sys = await client(LASNA).getLogs({ address: CRON_EMITTER, fromBlock: reactBlock - 2n, toBlock: reactBlock });
  return sys.length ? (sys[sys.length - 1].transactionHash as Hex) : undefined;
}

async function main() {
  const rc = await logs(LASNA, RC, BigInt(env.LASNA_FROM), rcAbi);
  const vault = await logs(BASE_SEPOLIA, VAULT, BigInt(env.BASE_FROM), vaultAbi);
  const proxy = chain(BASE_SEPOLIA).callbackProxy!.toLowerCase();
  const byTx = new Map<Hex, D[]>();
  for (const d of rc) byTx.set(d.tx, [...(byTx.get(d.tx) ?? []), d]);
  const seenOrder = rc.filter((d) => d.name === "Seen");
  const lastActivityBefore = (block: bigint, idx: number) =>
    [...seenOrder].reverse().find((s) => s.block < block || (s.block === block && s.index <= idx));

  const rows: TripleRow[] = [];
  const firstSend = new Map<bigint, D>();
  const tries = new Map<bigint, number>();
  for (const d of rc.filter((x) => x.name === "CallbackSent")) {
    const seq = d.args.seq as bigint;
    if (!firstSend.has(seq)) firstSend.set(seq, d);
    tries.set(seq, Math.max(tries.get(seq) ?? 0, Number(d.args.tries)));
  }

  for (const [seq, d] of firstSend) {
    const stage = KIND[Number(d.args.kind)];
    const inTx = byTx.get(d.tx) ?? [];
    const seen = inTx.find((x) => x.name === "Seen");
    const brake = inTx.find((x) => x.name === "SpamBrake");
    const ack = vault.find((v) => v.name === "Ack" && v.args.seq === seq && !v.args.terminal);
    let callback: { chainId: number; tx: Hex } | undefined;
    let note = `seq ${seq}; tries ${tries.get(seq)}`;
    if (ack) {
      const t = await client(BASE_SEPOLIA).getTransaction({ hash: ack.tx });
      if (t.to?.toLowerCase() === proxy) callback = { chainId: BASE_SEPOLIA, tx: ack.tx };
      else note += `; Ack tx not via proxy (${t.to})`;
      const st = vault.find((v) => v.name === "StateChanged" && v.tx === ack.tx);
      if (st) note += `; vault ${st.args.from}->${st.args.to}`;
    } else note += "; no Ack found";
    const last = lastActivityBefore(d.block, d.index);
    const lastAct = last ? { chainId: Number(last.args.chainId), tx: hex32(last.args.originTx) } : undefined;
    if (seen || brake) {
      const trig = seen ?? brake!;
      const trigTx = seen ? hex32(seen.args.originTx) : undefined;
      if (!trigTx) continue;
      rows.push(await buildTriple({ stage, seq, triggerKind: "origin_log", triggerChain: Number(trig.args.chainId), triggerTx: trigTx,
        reactiveChain: LASNA, reactiveTx: d.tx, callback, lastActivity: lastAct, instance: INSTANCE, note }));
    } else {
      const ctx = await cronTx(d.block);
      if (!ctx) { console.warn(`seq ${seq}: no cron log near block ${d.block}`); continue; }
      rows.push(await buildTriple({ stage, seq, triggerKind: "cron", triggerChain: LASNA, triggerTx: ctx,
        reactiveChain: LASNA, reactiveTx: d.tx, callback, lastActivity: lastAct, instance: INSTANCE, note: note + "; trigger = Cron10 log on Lasna" }));
    }
  }

  for (const s of seenOrder) {
    if ((byTx.get(s.tx) ?? []).some((x) => x.name === "CallbackSent")) continue;
    const via = Number(s.args.chainId) === BASE_SEPOLIA && (s.args.token as string).toLowerCase() === VAULT.toLowerCase() ? "vault OwnerActive" : `token ${s.args.token}`;
    rows.push(await buildTriple({ stage: "VISIT", seq: "", triggerKind: "origin_log", triggerChain: Number(s.args.chainId), triggerTx: hex32(s.args.originTx),
      reactiveChain: LASNA, reactiveTx: s.tx, lastActivity: { chainId: Number(s.args.chainId), tx: hex32(s.args.originTx) }, instance: INSTANCE,
      note: `accepted heartbeat (${via}); ARMED so no callback needed` }));
  }
  for (const r of rc.filter((x) => x.name === "SpoofRefused")) {
    rows.push(await buildTriple({ stage: "REFUSED", seq: "", triggerKind: "origin_log", triggerChain: Number(r.args.chainId), triggerTx: hex32(r.args.originTx),
      reactiveChain: LASNA, reactiveTx: r.tx, instance: INSTANCE, note: `SpoofRefused ${REASON[Number(r.args.reason)]} token ${r.args.token}; lastSeen unchanged` }));
  }
  for (const t of rc.filter((x) => x.name === "TornDown")) {
    rows.push(await buildTriple({ stage: "TEARDOWN", seq: "", triggerKind: "origin_log", triggerChain: BASE_SEPOLIA, triggerTx: hex32(t.args.trigger),
      reactiveChain: LASNA, reactiveTx: t.tx, instance: INSTANCE, note: "vault EstateReleased/Retired/terminal Ack -> every subscription removed" }));
  }

  rows.sort((a, b) => Number(a.reactive_ts) - Number(b.reactive_ts));
  const n = appendTriples("evidence/triples.csv", rows);
  const summary = {
    instance: INSTANCE, rc: RC, vault: VAULT,
    callbackRows: rows.filter((r) => r.callback_tx).length,
    stages: Object.fromEntries([...new Set(rows.map((r) => r.stage))].map((s) => [s, rows.filter((r) => r.stage === s).length])),
    canaryBeats: rc.filter((x) => x.name === "CanaryBeat").length,
    freezeUsed: rc.filter((x) => x.name === "FreezeUsed").length,
    stuck: rc.filter((x) => x.name === "CallbackStuck").length,
    resends: [...tries.values()].filter((t) => t > 1).length,
  };
  writeFileSync(`evidence/${INSTANCE}-summary.json`, JSON.stringify(summary, null, 2) + "\n");
  console.log(`rows built ${rows.length}, appended ${n}`, summary);
}

main().catch((e) => { console.error(e); process.exit(1); });
