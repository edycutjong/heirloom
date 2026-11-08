// One wall-clock sample of the probe loop: zero-value USDC transfer on Base Sepolia -> RC CallbackSent on Lasna ->
// ProbeCallback Pinged on Base Sepolia. Appends to evidence/latency-wallclock.csv.
// Key from DEPLOYER_PRIVATE_KEY in the environment (source ~/.config/reactive/testnet-deployer.env); never stored here.
import { appendFileSync, existsSync, readFileSync, writeFileSync } from "node:fs";
import { createWalletClient, http, parseAbi, parseAbiItem, type AbiEvent } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { baseSepolia } from "viem/chains";
import { observe } from "../packages/reactive-kit/ts/latency.ts";
import { client } from "../packages/reactive-kit/ts/chains.ts";
import type { Hex } from "../packages/reactive-kit/ts/triples.ts";

const env = Object.fromEntries(readFileSync(process.env.ADDR_FILE ?? "evidence/probe-addresses.txt", "utf8").trim().split("\n").map((l) => l.split("=")));
const RC = env.PROBE_RC as Hex, CB = env.PROBE_CB as Hex;
const USDC = "0x036CbD53842c5426634e7929541eC2318f3dCF7e" as const;
const OUT = "evidence/latency-wallclock.csv";

async function main() {
  const pk = process.env.DEPLOYER_PRIVATE_KEY as Hex | undefined;
  if (!pk) throw new Error("DEPLOYER_PRIVATE_KEY not set");
  const account = privateKeyToAccount(pk);
  const wallet = createWalletClient({ account, chain: baseSepolia, transport: http(process.env.BASE_SEPOLIA_RPC) });
  let originTx: Hex | undefined;
  const s = await observe({
    send: async () => {
      const hash = await wallet.writeContract({ address: USDC, abi: parseAbi(["function transfer(address,uint256) returns (bool)"]), functionName: "transfer", args: [account.address, 0n] });
      await client(84532).waitForTransactionReceipt({ hash, pollingInterval: 250 });
      originTx = hash;
      return hash;
    },
    reactive: {
      chainId: 5318007, address: RC,
      event: parseAbiItem("event CallbackSent(uint256 indexed seq, uint256 originChainId, uint256 originTx)") as AbiEvent,
      match: (l) => BigInt(l.args?.originTx as bigint) === BigInt(originTx ?? 0),
    },
    callback: {
      chainId: 84532, address: CB,
      event: parseAbiItem("event Pinged(address indexed rvm, uint256 indexed seq, uint256 originChainId, uint256 originTx, uint256 receivedAt)") as AbiEvent,
      match: (l) => BigInt(l.args?.originTx as bigint) === BigInt(originTx ?? 0),
    },
    pollMs: 500,
  });
  if (!existsSync(OUT)) writeFileSync(OUT, "origin_tx,reactive_tx,callback_tx,send_to_mined_ms,mined_to_reactive_seen_ms,mined_to_callback_seen_ms,send_to_callback_seen_ms,poll_ms\n");
  const d = (a: number | null, b: number) => (a === null ? "" : String(a - b));
  appendFileSync(OUT, [s.originTx, s.reactiveTx ?? "", s.callbackTx ?? "", s.originMinedAtMs - s.sentAtMs, d(s.reactiveSeenAtMs, s.originMinedAtMs), d(s.callbackSeenAtMs, s.originMinedAtMs), d(s.callbackSeenAtMs, s.sentAtMs), s.pollMs].join(",") + "\n");
  console.log(JSON.stringify(s));
}
main().catch((e) => { console.error(e); process.exit(1); });
