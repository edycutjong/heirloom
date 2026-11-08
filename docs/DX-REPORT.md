# DX report — Reactive Network Omni, measured

A friction log and measurement record from building Heirloom. Every number here comes from a transaction listed in
`evidence/` or from a command shown below. Day 1 = 2026-11-08 (UTC), Lasna (5318007) with Base Sepolia (84532),
Ethereum Sepolia (11155111) and Unichain Sepolia (1301) as origins, and Base Sepolia as the destination.

Pinned: `reactive-lib-omni` `3ade0dc`, `reactive-test-lib` `2ff9b2a`, `forge-std` `f3dae6e`, solc 0.8.29.

## Day-1 probe contracts

| Contract | Chain | Address |
|---|---|---|
| `ProbeCallback` | Base Sepolia | `0x90721E018E2246a6555755D63418686a1A04FD9f` |
| `ProbeReactive` #1 | Lasna | `0xe4A0Bf147c9C8390ea4e7C915e7801606c171909` |
| `ProbeReactive` #2 | Lasna | `0x6818e87Ee5AC613F90848aD54A31bBEc825647C9` |

Both reactive contracts were drained after the run. Source: `src/probe/`; replayed locally by `test/Probe.t.sol`.

## Findings

### 1. reactive-test-lib does not drive Omni contracts as-is → adapter in reactive-kit
The Test Lib's mock system contract sits at the legacy `0x…fffFfF`, calls `react()` from there, and collects callbacks
from the legacy `Callback` event. Omni's `AbstractReactive` accepts `react()` only from `0x8888…8888`, and Omni
contracts request callbacks through `SYSTEM.requestCallbackV_1_0`, so the Test Lib simulator never reaches them.
The kit therefore etches its own `OmniSystemMock` at `0x8888…8888` and keeps the Test Lib's `MockCallbackProxy` and
result types (`packages/reactive-kit/src/test/`). Two more Test Lib mismatches:
- its CRON constants are placeholders: they share the first 4 bytes with the network's topics and differ after that
  (`test_testlib_cron_topics_are_placeholders`);
- it injects the deployer as the callback's first argument; the network injects the requesting RC (finding 2).

### 2. The injected first callback argument is the requesting reactive contract
All 7 successful probe callbacks carried the RC's own address as the first argument (`Pinged.rvm` = the RC;
`evidence/triples.csv`, `evidence/probe-roundtrip.csv`). The Omni callback docs say this; the Test Lib docs say
"deployer". Consequence: a destination's `callbackSender` is the RC address, and `onlyCallbackSender(rvm)` must be
checked against the injected argument.

### 3. Wildcard subscriptions work (G1), re-recorded
The P0c throwaway contract `0x9332D26FC3d4EF187D4936683897D13d473A9Cdb` (subscription: chain 0, contract 0,
`Deposit(address,uint256)`, topic1 = deployer) reacted again on Day 1 to a 1-wei WETH deposit on Base Sepolia:
origin `0x0bdc7650e02f6d785d7f02dfe1921ef5bd594270879c8a1ee94cc926ec51e57d`, reactive tx
`0x799cb0d91ce653e6c7a7c5594ac43cb80d1b15fde42709053613db12a466b068` (log chainId 84532, emitter `0x4200…0006`).
Heirloom still subscribes per (chain, token): cost stays bounded and a spoof cannot reach the RC from an unwatched token.

### 4. All three origin chains deliver; zero-value spoofs reach `react()`
- `Transfer(from = owner)` from Base Sepolia, Ethereum Sepolia and Unichain Sepolia USDC each produced a full triple
  (rows `PROBE` seq 1–3).
- Circle USDC accepts `transfer(to, 0)` and a third party's `transferFrom(owner, spoofer, 0)` with no balance and no
  allowance (simulated on all three chains). The live spoof (seq 4, origin
  `0x8507b70bf5e8cbd5012c7e5326a1d00e00a83aa0708bb07f31d39977d20d2ee2`) reached `react()` with `topic1 = owner`.
  So anyone can make a watched owner "look active" for free: the production filter must require `value > 0` and an
  owner token allowlist before anything else in `react()`. No WETH pivot is needed for the spoof test.

### 5. CRON on Lasna
- Emitter `0x…fffFfF`; the Cron10 log sits in a block divisible by 10 and the RC's react lands in the next block.
- The Cron log's `data` is empty (`0x`); the docs describe a `number` parameter. Read `block.number` instead.
- Cron10 gaps between reacts: 10 s, 11 s, 11 s (`evidence/probe-cron.csv`).
- A `react()` can unsubscribe its own CRON subscription: `CronOff(ticks = 4, viaReact = true)` in tx
  `0x8caa9b05045780d64b0153caa961c18390f142e5d489f817e9e2aa6a50ef6a50`. Arming a fast CRON only during grace and
  dropping it from inside `react()` is therefore possible without an owner transaction.

### 6. CallbackFailure: emitted by the destination proxy, target indexed
Forcing one callback to revert (seq 5) produced, on Base Sepolia, a log from the callback proxy
`0x476F44b11F5C942c58f4c8E3d0300E5710743585`: `CallbackFailure(address indexed target, bytes payload)`
(topic0 `0xc8313f69…99db`, tx `0x8e4b4956b695caae98540ae2896090ccdfe209ea8976fde7e8bdea595658a55c`). `payload` is the
full calldata with the injected RC address already in place. Because `target` is indexed, an RC can subscribe to its
own destination's failures only. Decoded from the real log in `CallbackFailureWatchTest`.

### 7. State written by a reverting callback is rolled back (probe bug, kept as a lesson)
The probe's `failNext` flag was cleared inside the callback that reverts, so the revert undid the clear and the next
callback (seq 6) failed too. Anything a destination wants to remember about a failure must be recorded by the RC
(e.g. via `CallbackFailure`) or by a separate successful call. Covered by `test_forced_revert_rolls_back_its_own_flag`.

### 8. Latency
Block timestamps (1 s resolution, `evidence/probe-roundtrip.csv`, 7 callbacks): callback request on Lasna → callback
block on Base Sepolia = 2 s in all 7; request → Ack observed back on Lasna = 2 s in all 7.

Wall clock (`evidence/latency-wallclock.csv`, 3 complete samples, 500 ms polling, Base Sepolia origin):

| origin mined → reactive log seen | origin mined → callback log seen | send → callback log seen |
|---|---|---|
| 3158 ms | 3714 ms | 5624 ms |
| 2102 ms | 4963 ms | 7844 ms |
| 2242 ms | 4587 ms | 7303 ms |

Cross-chain block timestamps are not synchronised: in 5 of the first 9 rows of `evidence/triples.csv` (the P1a probe rows) the Lasna reactive
block is stamped one second *before* its origin block. Hop latencies must come from the wall-clock observer, not from timestamp deltas.
Three samples are not a distribution; P1b adds more before any figure is published.

### 9. Cost (Lasna)
- RC #1: 0.1815152 lREACT for 16 reacts (6 of them requesting a callback, 6 Ack reacts, 4 CRON reacts).
- RC #2: 0.0754485 lREACT for 6 reacts (3 requesting a callback, 3 Ack reacts).
- Callbacks on Base Sepolia: 0.0000059 ETH for 9 callbacks (7 succeeded, 2 failed); a failed callback is billed too.

### 10. Tooling friction
- `forge create --constructor-args` is variadic: flags placed after it (e.g. `--json`) are swallowed as arguments.
  Put `--constructor-args` last. `--json` output is pretty-printed over several lines.
- `sepolia.base.org` caps `eth_getLogs` at 200 blocks; the kit's logger chunks Base Sepolia at 180.
- `cast tx` on a Lasna reactive transaction returns empty `from`/`to`; read the RC's logs to identify reactive txs.
- Lasna faucet: a 0.03 SepETH `request(address)` to the Ethereum Sepolia faucet `0x9b9BB25f…f434` (tx
  `0x517457f954ac03da8ab3d4b40ecf724da0ac9dcfb27f5ca682e84aca7a2eab09`) took the deployer's Lasna balance from
  0.2410 to 3.3910 lREACT.

## P1c findings (2026-11-09)
- **Lasna gas is 100 gwei**, so deploying the ≈ 20 KB `HeirloomReactive` costs ≈ 0.45 lREACT in gas alone, before any reserve. `forge create` / `eth_estimateGas` fail with
  `contract creation code storage out of gas` (or `gas required exceeds: 2004211`) when `balance − value` cannot cover `gas × price`: the error names gas, the cause is the balance. Keep `balance ≥ reserve + ~0.6 lREACT`, or pass `--gas-limit 5800000 --gas-price 100gwei` (`LASNA_GAS_LIMIT` in `script/heirloom-deploy.sh`; `forge`'s default fee headroom otherwise trips the node's 1-ether tx-fee cap).
- **Instances that share an owner and token cross-react.** A heartbeat or zero-value spoof by the owner on a token that several RCs watch (`Transfer` with `topic1 = owner`) wakes every one of those RCs, and each one is billed. Running the demo scenario made the long-T RC count the demo's heartbeats and refuse the demo's spoof. Cost measurements are therefore taken over quiet windows (`costFrom` in `deployments/testnet.json`), and a tester's own instance should use its own owner wallet.
- **Cron100 idle cost on Lasna** ≈ 0.013 lREACT/min for a live RC with two callbacks in flight (measured from reserve samples 18:11 → 18:12, instance `demo`); Cron10 ≈ 0.09/min (P1b). Long-lived instances should use Cron1000 / Cron10000.
- **`cast call --create` is a real, signer-less deploy simulation** against Lasna and Base (it reverts on `BadConfig`), which is what `scripts/deploy-mainnet.sh` uses for its dry run (`forge create` without `--broadcast` still demands a signer).
