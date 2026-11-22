// Recomputes the numbers the status page and README quote, from chain reads + the committed CSVs only. Idempotent:
//   evidence/status.json   per instance: state, days live, heartbeats, spoofs refused, callbacks, REACT balance, measured REACT/day -> /month
//   evidence/cost.json     the cost lines (REACT only; a dollar figure needs a second price source, so usd stays null)
//   evidence/triples.json  evidence/triples.csv as JSON (the status page's primary source)
//   evidence/cost-history.csv  append-only balance samples (ts,instance,balance_react) the REACT/day slope is measured from
// Instances come from deployments/testnet.json (hand-written config: ids, labels, funded/reclaimed REACT).
// Usage: tsx scripts/evidence-status.ts   (RPCs: LASNA_RPC, BASE_SEPOLIA_RPC, else the public defaults)
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { decodeEventLog, formatEther, parseAbi, type Log } from "viem";
import { chain, client } from "../packages/reactive-kit/ts/chains.ts";
import { readTriples } from "../packages/reactive-kit/ts/triples.ts";

type Hex = `0x${string}`;
interface Inst { id: string; label: string; addresses: string; fundedReact: number; reclaimedReact?: number; note?: string; costFrom?: number }
const cfg: { network: string; rcChain?: number; baseChain?: number; instances: Inst[] } = JSON.parse(readFileSync(process.env.DEPLOYMENTS ?? "deployments/testnet.json", "utf8"));
const LASNA = cfg.rcChain ?? 5318007, BASE_SEPOLIA = cfg.baseChain ?? 84532;
const SUFFIX = process.env.DEPLOYMENTS?.includes("mainnet") ? "-mainnet" : "";

const rcAbi = parseAbi([
  "event Seen(uint256 indexed chainId, address indexed token, uint256 originTx)",
  "event SpoofRefused(uint256 indexed chainId, address indexed token, uint256 originTx, uint8 reason)",
  "event CallbackSent(uint64 indexed seq, uint8 kind, uint8 tries)",
  "event Acked(uint64 indexed seq, uint256 ackTx)",
  "event FreezeUsed(uint64 newDeadline)",
  "event CanaryBeat(uint256 indexed chainId, uint64 gap)",
  "event SpamBrake(uint256 indexed chainId, address indexed token, uint64 until)",
  "event TornDown(uint256 trigger)",
  "event OwnerVersionAdopted(uint64 nonce, bytes32 actionId, uint256 ackTx)",
  "function phase() view returns (uint8)",
  "function lastSeen() view returns (uint64)",
  "function lastChain() view returns (uint256)",
  "function lastOriginTx() view returns (bytes32)",
  "function deadline() view returns (uint64)",
  "function graceEndsAt() view returns (uint64)",
  "function runwayDays() view returns (uint32)",
  "function T() view returns (uint64)",
]);
const vaultAbi = parseAbi([
  "function state() view returns (uint8)",
  "function heir() view returns (address)",
  "function claimReadyAt() view returns (uint64)",
  "function claimDelay() view returns (uint64)",
  "function depositCap() view returns (uint256)",
]);
const PHASE = ["ARMED", "GRACE", "EXPIRED", "DONE"];
const VSTATE = ["ARMED", "GRACE", "CLAIMABLE", "CLAIM_PENDING", "RELEASED", "RETIRED"]; // HeirloomTypes.VaultState, verbatim

const lasna = client(LASNA), base = client(BASE_SEPOLIA);
const tsOf = async (c: typeof lasna, block: bigint) => Number((await c.getBlock({ blockNumber: block })).timestamp);
async function tryRead<T>(f: () => Promise<T>): Promise<T | null> { try { return await f(); } catch { return null; } }

async function rcLogs(address: Hex, from: bigint) {
  const to = await lasna.getBlockNumber();
  const span = chain(LASNA).logSpan;
  const out: { name: string; args: any }[] = [];
  for (let f = from; f <= to; f += span + 1n) {
    const e = f + span > to ? to : f + span;
    for (const l of (await lasna.getLogs({ address, fromBlock: f, toBlock: e })) as Log[]) {
      try { const d = decodeEventLog({ abi: rcAbi, data: l.data, topics: l.topics as any }) as any; out.push({ name: d.eventName, args: d.args }); } catch { /* foreign */ }
    }
  }
  return out;
}

const hist = `evidence/cost-history${SUFFIX}.csv`;
if (!existsSync(hist)) writeFileSync(hist, "ts,instance,balance_react\n");
const samples = readFileSync(hist, "utf8").trim().split("\n").slice(1).map((l) => l.split(","));
const now = Math.floor(Date.now() / 1000);
const out: any[] = [];

for (const inst of cfg.instances) {
  const env = Object.fromEntries(readFileSync(inst.addresses, "utf8").trim().split("\n").map((l) => l.split("=") as [string, string]));
  const RC = env.RC as Hex, VAULT = env.VAULT as Hex;
  const log = await rcLogs(RC, BigInt(env.LASNA_FROM));
  const count = (n: string) => log.filter((d) => d.name === n).length;
  const refusedBy: Record<string, number> = {};
  for (const d of log.filter((x) => x.name === "SpoofRefused")) refusedBy[d.args.reason] = (refusedBy[d.args.reason] ?? 0) + 1;
  const tornDown = count("TornDown") > 0;
  const deployedTs = await tsOf(lasna, BigInt(env.LASNA_FROM));
  const read = <N extends string>(name: N) => tryRead(() => lasna.readContract({ address: RC, abi: rcAbi, functionName: name as any } as any) as Promise<any>);
  const phase = tornDown ? 3 : await read("phase");
  const [lastSeen, lastChain, lastOrigin, deadline, T] = await Promise.all([read("lastSeen"), read("lastChain"), read("lastOriginTx"), read("deadline"), read("T")]);
  const vstate = await tryRead(() => base.readContract({ address: VAULT, abi: vaultAbi, functionName: "state" }) as Promise<number>);
  const bal = Number(formatEther(await lasna.getBalance({ address: RC })));
  const lastTs = Math.max(0, ...samples.filter((x) => x[1] === inst.id).map((x) => Number(x[0])));
  if (!tornDown && now - lastTs >= 300) appendFileSync(hist, `${now},${inst.id},${bal}\n`); // idempotent: reruns within 5 min add nothing

  // measured REACT/day: slope of the balance samples while the balance only falls (a top-up ends the window)
  const mine = samples.filter((s) => s[1] === inst.id && Number(s[0]) >= (inst.costFrom ?? 0)).map((s) => [Number(s[0]), Number(s[2])] as [number, number]);
  if (!tornDown) mine.push([now, bal]);
  let win = mine.slice(-1);
  for (let i = mine.length - 2; i >= 0 && mine[i][1] >= mine[i + 1][1]; i--) win = [mine[i], ...win];
  const spanS = win.length > 1 ? win[win.length - 1][0] - win[0][0] : 0;
  const MIN_WINDOW_S = 6 * 3600; // shorter windows miss ATTEST / heartbeat bursts
  const reactPerDay = !tornDown && spanS >= MIN_WINDOW_S ? ((win[0][1] - win[win.length - 1][1]) / spanS) * 86400 : null;
  const lifeEnd = tornDown ? undefined : now;
  const spent = inst.reclaimedReact !== undefined ? inst.fundedReact - inst.reclaimedReact : inst.fundedReact - bal;
  out.push({
    id: inst.id, label: inst.label, note: inst.note ?? null, network: cfg.network,
    rc: RC, vault: VAULT, owner: env.OWNER, heir: env.HEIR,
    phase: phase === null ? null : PHASE[Number(phase)], vaultState: vstate === null ? null : VSTATE[Number(vstate)],
    tornDown, T: T === null ? Number(env.T) : Number(T),
    lastSeen: lastSeen === null ? null : Number(lastSeen), lastChain: lastChain === null ? null : Number(lastChain),
    lastOriginTx: lastOrigin, deadline: deadline === null ? null : Number(deadline),
    deployedAt: deployedTs, daysLive: lifeEnd ? +((lifeEnd - deployedTs) / 86400).toFixed(3) : null,
    // an owner-version adoption emits one Seen whose originTx is a proxy callback, not owner activity
    heartbeats: count("Seen") - count("OwnerVersionAdopted"), versionAdoptions: count("OwnerVersionAdopted"), spoofsRefused: count("SpoofRefused"), refusedByReason: refusedBy,
    callbacksSent: new Set(log.filter((d) => d.name === "CallbackSent").map((d) => String(d.args.seq))).size,
    acked: count("Acked"), freezesUsed: count("FreezeUsed"), canaryArrivals: count("CanaryBeat"), brakes: count("SpamBrake"),
    balanceReact: +bal.toFixed(6), fundedReact: inst.fundedReact, spentReactReported: +spent.toFixed(6), // funded/reclaimed are hand-recorded in deployments/*.json, not measured by this script
    reactPerDay: reactPerDay === null ? null : +reactPerDay.toFixed(6),
    reactPerMonth: reactPerDay === null ? null : +(reactPerDay * 30).toFixed(4), reactPerMonthBasis: reactPerDay === null ? null : "extrapolated from the measured window",
    fundedThrough: reactPerDay && reactPerDay > 0 ? new Date((now + (bal / reactPerDay) * 86400) * 1000).toISOString().slice(0, 10) : null,
    costWindowHours: +(spanS / 3600).toFixed(2),
  });
}

// the kit parser handles the writer's quoting (a note with a comma is a quoted CSV cell)
const rows = readTriples("evidence/triples.csv");
writeFileSync("evidence/triples.json", JSON.stringify(rows, null, 1) + "\n");
writeFileSync(`evidence/status${SUFFIX}.json`, JSON.stringify({ generatedAt: new Date().toISOString(), network: cfg.network, instances: out }, null, 1) + "\n");
writeFileSync(`evidence/cost${SUFFIX}.json`, JSON.stringify({
  generatedAt: new Date().toISOString(), unit: cfg.rcChain === 1597 ? "REACT" : "REACT (testnet lREACT)", usd: null,
  usdNote: "no dollar figure: it needs a second REACT price source",
  lines: out.map((i) => ({ id: i.id, reactPerDay: i.reactPerDay, reactPerMonth: i.reactPerMonth, windowHours: i.costWindowHours, balanceReact: i.balanceReact, fundedThrough: i.fundedThrough })),
}, null, 1) + "\n");
console.log(`status.json: ${out.length} instances; triples.json: ${rows.length} rows`);
for (const i of out) console.log(`  ${i.id}: ${i.phase}/${i.vaultState} live ${i.daysLive ?? "ended"} d, ${i.heartbeats} heartbeats, ${i.spoofsRefused} refused, ${i.callbacksSent} callbacks, ${i.balanceReact} REACT${i.reactPerMonth ? `, ${i.reactPerMonth}/month` : ""}`);
