// Fire a fresh loop against a live Heirloom instance from ANY wallet: a zero-value transferFrom(owner, you, 0) on the
// instance's USDC (Base Sepolia). It is not the owner's activity, so the reactive contract must refuse it:
//   origin tx (this script) -> a REFUSED react on Lasna (SpoofRefused event, a few seconds later). Only the owner can fire a real heartbeat.
// Usage: PRIVATE_KEY=0x… tsx scripts/trigger-spoof.ts [--instance long-t] [--dry-run]
//   PRIVATE_KEY: any Base Sepolia key with a little ETH (a transfer of 0 USDC costs well under 0.0001 ETH). Never commit it.
//   --dry-run: simulate with eth_call, print the plan, send nothing. Needs no key (uses the zero-address-safe default sender).
import { readFileSync } from "node:fs";
import { createWalletClient, http, parseAbi, type Hex } from "viem";
import { privateKeyToAccount } from "viem/accounts";
import { chain, client } from "../packages/reactive-kit/ts/chains.ts";

const args = process.argv.slice(2);
const flag = (n: string) => args.includes(`--${n}`);
const opt = (n: string, d: string) => { const i = args.indexOf(`--${n}`); return i >= 0 && args[i + 1] ? args[i + 1] : d; };
const instance = opt("instance", "long-t");
const env = Object.fromEntries(readFileSync(`evidence/${instance}-addresses.txt`, "utf8").split("\n").filter((l) => l.includes("=")).map((l) => l.split("=") as [string, string]));
const owner = env.OWNER as Hex, usdc = env.USDC_BASE as Hex, rc = env.RC as Hex;
const abi = parseAbi(["function transferFrom(address,address,uint256) returns (bool)"]);

const pk = process.env.PRIVATE_KEY as Hex | undefined;
if (!pk && !flag("dry-run")) { console.error("set PRIVATE_KEY (any Base Sepolia wallet that is NOT the owner), or pass --dry-run"); process.exit(2); }
const account = pk ? privateKeyToAccount(pk) : undefined;
const from = account?.address ?? "0x000000000000000000000000000000000000dEaD";
if (account && account.address.toLowerCase() === owner.toLowerCase()) { console.error("that key is the owner: this would be a real heartbeat, not a spoof"); process.exit(2); }

const base = client(84532);
console.log(`instance ${instance}\n  reactive contract (Lasna): ${rc}\n  owner: ${owner}\n  token: Base Sepolia USDC ${usdc}\n  you: ${from}`);
await base.simulateContract({ address: usdc, abi, functionName: "transferFrom", args: [owner, from, 0n], account: from });
console.log("simulation ok: transferFrom(owner, you, 0) does not revert");
if (flag("dry-run")) { console.log("--dry-run: nothing sent"); process.exit(0); }

const wallet = createWalletClient({ account: account!, chain: undefined, transport: http(chain(84532).defaultRpc) });
const hash = await wallet.writeContract({ address: usdc, abi, functionName: "transferFrom", args: [owner, from, 0n], chain: null });
console.log(`origin tx: ${chain(84532).explorerTx}${hash}`);
await base.waitForTransactionReceipt({ hash });
console.log(`mined. Within seconds the reactive contract logs SpoofRefused for this tx; see its transactions: https://lasna.reactscan.net/address/${rc}`);
