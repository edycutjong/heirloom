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

// CronTopics.sol values -> tier names (the note must name the instance's real tier, never a hard-coded one).
const CRON_TIER: Record<string, string> = {
  "0xf02d6ea5c22a71cffe930a4523fcb4f129be6c804db50e4202fb4e0b07ccb514": "Cron1",
  "0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687": "Cron10",
  "0xb49937fb8970e19fd46d48f7e3fb00d659deac0347f79cd7cb542f0fc1503c70": "Cron100",
  "0xe20b31294d84c3661ddc8f423abb9c70310d0cf172aa2714ead78029b325e3f4": "Cron1000",
  "0xd214e1d84db704ed42d37f538ea9bf71e44ba28bc1cc088b2f5deca654677a56": "Cron10000",
};
const topicHex = (t: bigint) => `0x${t.toString(16).padStart(64, "0")}` as Hex;

/** The CRON log that triggered a react: only this instance's tier topics, latest in the 3-block window. */
async function cronTx(reactBlock: bigint, topics: Hex[]): Promise<{ tx: Hex; tier: string } | undefined> {
  const sys = (await client(LASNA).getLogs({ address: CRON_EMITTER, fromBlock: reactBlock - 2n, toBlock: reactBlock }))
    .filter((l) => topics.includes((l.topics[0] ?? "").toLowerCase() as Hex));
  const l = sys[sys.length - 1];
  return l ? { tx: l.transactionHash as Hex, tier: CRON_TIER[(l.topics[0] as string).toLowerCase()] ?? "Cron" } : undefined;
}

async function main() {
  const rc = await logs(LASNA, RC, BigInt(env.LASNA_FROM), rcAbi);
  const topicAbi = parseAbi(["function cronTopic() view returns (uint256)", "function graceCronTopic() view returns (uint256)"]);
  const [cronT, graceT] = await Promise.all((["cronTopic", "graceCronTopic"] as const).map((functionName) =>
    client(LASNA).readContract({ address: RC, abi: topicAbi, functionName }) as Promise<bigint>));
  const cronTopics = [cronT, graceT].filter((t) => t !== 0n).map(topicHex);
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
    // A brake-only CANCEL/REVIVE has no Seen: its origin log is the refused transfer that tripped the brake.
    const refused = brake ? [...inTx].reverse().find((x) => x.name === "SpoofRefused" && x.index < brake.index) : undefined;
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
    // A row joins by seq: with resends, the delivering attempt is not necessarily the first request. Say so.
    if (ack && (tries.get(seq) ?? 1) > 1) note += "; Ack after a resend: reactive_tx is the FIRST attempt, callback_tx the delivered one";
    const last = lastActivityBefore(d.block, d.index);
    const lastAct = last ? { chainId: Number(last.args.chainId), tx: hex32(last.args.originTx) } : undefined;
    if (seen || brake) {
      const trig = seen ?? brake!;
      const trigTx = seen ? hex32(seen.args.originTx) : refused ? hex32(refused.args.originTx) : undefined;
      if (!trigTx) { console.warn(`seq ${seq}: brake without a SpoofRefused in ${d.tx}; row skipped`); continue; }
      if (!seen) note += "; trigger = the refused transfer that tripped the spam brake";
      rows.push(await buildTriple({ stage, seq, triggerKind: "origin_log", triggerChain: Number(trig.args.chainId), triggerTx: trigTx,
        reactiveChain: LASNA, reactiveTx: d.tx, callback, lastActivity: lastAct, instance: INSTANCE, note }));
    } else {
      const ctx = await cronTx(d.block, cronTopics);
      if (!ctx) { console.warn(`seq ${seq}: no cron log near block ${d.block}`); continue; }
      rows.push(await buildTriple({ stage, seq, triggerKind: "cron", triggerChain: LASNA, triggerTx: ctx.tx,
        reactiveChain: LASNA, reactiveTx: d.tx, callback, lastActivity: lastAct, instance: INSTANCE,
        note: `${note}; trigger = ${ctx.tier} log on ${LASNA === 1597 ? "Reactive" : "Lasna"}` }));
    }
  }

  for (const s of seenOrder) {
    if ((byTx.get(s.tx) ?? []).some((x) => x.name === "CallbackSent")) continue;
    // an owner-version adoption (vault Ack carrying a newer owner nonce) also emits Seen; its trigger is the callback tx
    const adopted = (byTx.get(s.tx) ?? []).some((x) => x.name === "OwnerVersionAdopted");
    const via = adopted ? "vault version adopted from an Ack (trigger_tx is the callback tx)"
      : Number(s.args.chainId) === BASE_SEPOLIA && (s.args.token as string).toLowerCase() === VAULT.toLowerCase() ? "vault OwnerActive" : `token ${s.args.token}`;
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
