// Day-1 probe evidence: rebuilds evidence/triples.csv (PROBE rows), evidence/probe-roundtrip.csv and
// evidence/probe-cron.csv from on-chain logs only. Usage: pnpm triples  (reads evidence/probe-addresses.txt + probe-origins.csv)
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { parseAbiItem, type AbiEvent } from "viem";
import { getLogsChunked, buildTriple, appendTriples, blockTs, readTriples, hopSeconds, parseCsvLine, type Hex } from "../packages/reactive-kit/ts/triples.ts";
import { chain, client } from "../packages/reactive-kit/ts/chains.ts";

const LASNA = 5318007, BASE_SEPOLIA = 84532;
const env = Object.fromEntries(
  readFileSync(process.env.ADDR_FILE ?? "evidence/probe-addresses.txt", "utf8").trim().split("\n").map((l) => l.split("=") as [string, string]),
);
const RC = env.PROBE_RC as Hex, CB = env.PROBE_CB as Hex;
const origins = readFileSync("evidence/probe-origins.csv", "utf8").trim().split("\n").slice(1).map(parseCsvLine)
  .map(([chainId, kind, tx, block]) => ({ chainId: Number(chainId), kind, tx: tx as Hex, block: BigInt(block) }));

const ev = (s: string) => parseAbiItem(s) as AbiEvent;
const CallbackSent = ev("event CallbackSent(uint256 indexed seq, uint256 originChainId, uint256 originTx)");
const AckSeen = ev("event AckSeen(uint256 indexed seq, uint256 rvmInjected, uint256 destTx)");
const CronTick = ev("event CronTick(uint256 indexed n, uint256 cronBlock, uint256 reactBlock, uint256 at, uint256 gapSeconds)");
const CronOff = ev("event CronOff(uint256 ticks, bool viaReact)");
const Pinged = ev("event Pinged(address indexed rvm, uint256 indexed seq, uint256 originChainId, uint256 originTx, uint256 receivedAt)");
const CallbackFailure = ev("event CallbackFailure(address indexed target, bytes payload)");
const CRON10_TOPIC = "0x04463f7c1651e6b9774d7f85c85bb94654e3c46ca79b0c16fb16d4183307b687";

const hex32 = (n: bigint) => ("0x" + n.toString(16).padStart(64, "0")) as Hex;
type L = { transactionHash: Hex; blockNumber: bigint; args: Record<string, bigint | string | boolean>; topics: Hex[]; data: Hex };

async function main() {
  const lasnaFrom = BigInt(process.env.LASNA_FROM ?? "7853600");
  const baseFrom = process.env.BASE_FROM ? BigInt(process.env.BASE_FROM) : origins.filter((o) => o.chainId === BASE_SEPOLIA).reduce((m, o) => (o.block < m ? o.block : m), 2n ** 62n);
  const baseTo = baseFrom + BigInt(process.env.BASE_SPAN ?? "1500");

  const sent = (await getLogsChunked(LASNA, { address: RC, event: CallbackSent, fromBlock: lasnaFrom })) as unknown as L[];
  const acks = (await getLogsChunked(LASNA, { address: RC, event: AckSeen, fromBlock: lasnaFrom })) as unknown as L[];
  const pings = (await getLogsChunked(BASE_SEPOLIA, { address: CB, event: Pinged, fromBlock: baseFrom, toBlock: baseTo, args: { rvm: RC } })) as unknown as L[];
  const proxy = chain(BASE_SEPOLIA).callbackProxy!;
  const fails = (await getLogsChunked(BASE_SEPOLIA, { address: proxy, event: CallbackFailure, fromBlock: baseFrom, toBlock: baseTo, args: { target: CB } })) as unknown as L[];

  const rows = [];
  const RT_HEADER = "rc,seq,callback_requested_tx,requested_ts,callback_tx,callback_ts,ack_seen_tx,ack_seen_ts,injected_rvm,request_to_callback_s,request_to_ack_s";
  const rt: string[] = [];
  for (const s of sent) {
    const seq = s.args.seq as bigint;
    const originTx = hex32(s.args.originTx as bigint);
    const originChain = Number(s.args.originChainId);
    const origin = origins.find((o) => o.tx.toLowerCase() === originTx.toLowerCase());
    const ping = pings.find((p) => (p.args.seq as bigint) === seq);
    // CallbackFailure data = abi.encode(bytes payload); payload = selector | rvm | seq | ...
    const word = (f: L, i: number) => BigInt("0x" + f.data.slice(2 + 128 + 8 + 64 * i, 2 + 128 + 8 + 64 * (i + 1)));
    const fail = fails.find((f) => word(f, 0) === BigInt(RC) && word(f, 1) === seq);
    const cbTx = ping?.transactionHash ?? fail?.transactionHash;
    const note = [
      origin?.kind ?? "",
      ping ? `injected first arg = ${ping.args.rvm}` : "",
      fail ? "callback reverted on purpose; proxy emitted CallbackFailure(target indexed, payload)" : "",
    ].filter(Boolean).join("; ");
    rows.push(await buildTriple({
      stage: fail ? "PROBE_CALLBACK_FAILURE" : "PROBE", seq, triggerKind: "origin_log", triggerChain: originChain, triggerTx: originTx,
      reactiveChain: LASNA, reactiveTx: s.transactionHash, callback: cbTx ? { chainId: BASE_SEPOLIA, tx: cbTx } : undefined,
      lastActivity: { chainId: originChain, tx: originTx }, instance: process.env.INSTANCE ?? "probe", note,
    }));
    const ack = acks.find((a) => (a.args.seq as bigint) === seq);
    if (ping && ack) {
      const reqTs = await blockTs(LASNA, s.blockNumber), cbTs = await blockTs(BASE_SEPOLIA, ping.blockNumber), ackTs = await blockTs(LASNA, ack.blockNumber);
      rt.push([RC, seq, s.transactionHash, reqTs, ping.transactionHash, cbTs, ack.transactionHash, ackTs, ping.args.rvm, cbTs - reqTs, ackTs - reqTs].join(","));
    }
  }
  const n = appendTriples("evidence/triples.csv", rows);
  const RT = "evidence/probe-roundtrip.csv";
  const prev = existsSync(RT) ? readFileSync(RT, "utf8").trim().split("\n").slice(1).filter((l) => l.toLowerCase().startsWith("0x") && !l.toLowerCase().startsWith(RC.toLowerCase())) : [];
  writeFileSync(RT, [RT_HEADER, ...prev, ...rt].join("\n") + "\n");

  // CRON: tick reacts + the system cron() tx in the same Lasna block
  const ticks = (await getLogsChunked(LASNA, { address: RC, event: CronTick, fromBlock: lasnaFrom })) as unknown as L[];
  const offs = (await getLogsChunked(LASNA, { address: RC, event: CronOff, fromBlock: lasnaFrom })) as unknown as L[];
  const cron: string[] = ["n,react_tx,react_block,react_ts,cron_data_word,gap_s,system_cron10_tx"];
  for (const t of ticks) {
    const sys = (await client(LASNA).getLogs({ address: "0x0000000000000000000000000000000000fffFfF", fromBlock: t.blockNumber - 1n, toBlock: t.blockNumber }))
      .filter((x) => x.topics[0] === CRON10_TOPIC);
    cron.push([t.args.n, t.transactionHash, t.blockNumber, t.args.at, t.args.cronBlock, t.args.gapSeconds, sys.map((x) => x.transactionHash).join("|")].join(","));
  }
  for (const o of offs) cron.push(`# CronOff ticks=${o.args.ticks} viaReact=${o.args.viaReact} tx=${o.transactionHash}`);
  if (ticks.length) writeFileSync("evidence/probe-cron.csv", cron.join("\n") + "\n");

  for (const r of readTriples("evidence/triples.csv")) {
    const h = hopSeconds(r);
    console.log(`${r.stage} seq=${r.seq} chain=${r.trigger_chain} origin->reactive=${h.triggerToReactive}s reactive->callback=${h.reactiveToCallback}s total=${h.total}s`);
  }
  console.log(`triples appended: ${n}; roundtrip rows: ${rt.length}; cron ticks: ${ticks.length}; failures: ${fails.length}`);
}

main().catch((e) => { console.error(e); process.exit(1); });
