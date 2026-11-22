<div align="center">
  <img src="docs/assets/brand/icon-animated.svg" alt="Heirloom mark: the card's stamps stop, RELEASED lands, the heir stub tears free" width="112">
  <h1>Heirloom</h1>
  <p><em>A dead-man's switch for a self-custody wallet. It reads silence across chains, so there is no keeper and no check-in required.</em></p>

  <img src="docs/assets/brand/readme-hero-animated.svg" alt="Heirloom — releases a vault on Base to your heir once your wallet goes quiet across chains. The card's violet stamps stop; a non-owner wallet's $0 row is refused; silence outlasts grace; the oxblood RELEASED stamp lands." width="100%">

  <p>Every on-chain and security claim below links to a transaction or a test. Testnet only so far: Reactive Lasna with Base Sepolia. The mainnet deploy is scripted (with a dry-run mode) and not yet run.</p>

  <p><a href="https://edycutjong.github.io/heirloom/judge/"><b>For judges</b></a> · <a href="https://edycutjong.github.io/heirloom/">Landing page</a> · <a href="https://edycutjong.github.io/heirloom/pitch/">Pitch deck</a> · <a href="https://edycutjong.github.io/heirloom/status/">Live status card</a> (GitHub Pages, published from <code>docs/</code> and <code>status/</code>)</p>

  <br/>

  [![For Judges](https://img.shields.io/badge/For_Judges-30--second_path-8E2B1D?style=for-the-badge)](https://edycutjong.github.io/heirloom/judge/)
  [![Built for Reactive Omni Buildathon](https://img.shields.io/badge/DoraHacks-Reactive_Omni_Buildathon-4A3E8C?style=for-the-badge)](https://dorahacks.io/hackathon/reactive-omni-buildathon/detail)

  <br/>

  ![Solidity](https://img.shields.io/badge/Solidity-0.8.29-363636?style=flat&logo=solidity)
  ![TypeScript](https://img.shields.io/badge/TypeScript-3178C6?style=flat&logo=typescript&logoColor=white)
  ![Foundry](https://img.shields.io/badge/Foundry-tested-orange?style=flat)
  [![License](https://img.shields.io/badge/License-MIT-yellow)](https://opensource.org/licenses/MIT)
  [![CI](https://github.com/edycutjong/heirloom/actions/workflows/ci.yml/badge.svg)](https://github.com/edycutjong/heirloom/actions/workflows/ci.yml)
  [![CodeQL](https://github.com/edycutjong/heirloom/actions/workflows/codeql.yml/badge.svg)](https://github.com/edycutjong/heirloom/actions/workflows/codeql.yml)
  [![Release](https://img.shields.io/github/v/release/edycutjong/heirloom?sort=semver)](https://github.com/edycutjong/heirloom/releases/latest)

</div>

---

## 📸 See it in Action

<p align="center"><img src="docs/assets/broll/heartbeat.gif" alt="Live testnet run: the owner's terminal sends one test dollar on Base Sepolia (tx 0x14f5…0b7e, mined 2.4 s after send) and waits; after a labelled cut of 3.0 s of that wait it prints lastSeen 18:08:42 → 23:34:23 UTC, seen 3.1 s after mined, and timer reset; the long-T status card then shows Last seen 8 s ago and a new deadline of 2027-02-06 23:34:23 UTC, in 90 days" width="880"></p>
<p align="center"><em>Recorded live on 2026-11-08 at 23:34 UTC, at real speed with cuts only (one is labelled on screen: 3.0 s of waiting). The owner's transfer <a href="https://sepolia.basescan.org/tx/0x14f59c3e646105a46fea7d9b1c7a3c7e3fff53749d22c85cda84728e2b490b7e"><code>0x14f5…0b7e</code></a> was mined 2.4 s after send, and 3.1 s later the reactive contract on Lasna had moved <code>lastSeen</code> to 23:34:23 and the deadline to 2027-02-06 (<a href="evidence/video-live-runs.csv"><code>evidence/video-live-runs.csv</code></a>).</em></p>

## 💡 The Problem & Solution

### The Problem

If you die with funds in a self-custody wallet, nobody gets them. A dead-man's switch fixes that, but the usual designs either need you to press a check-in button on a schedule (forget once and the switch fires on a living owner), or they watch one chain, or they rely on a keeper someone has to keep paying and trusting.

### The Solution

Heirloom treats **absence as the signal**. Your wallet keeps doing what it does; a Reactive Network contract watches your token activity on several chains and starts a countdown only when it stops.

- **No button.** Any value-carrying `Transfer` of an allowlisted token out of the owner's address on a watched chain counts as being alive.
- **Spoofs are refused.** A zero-value `transferFrom(owner, anyone, 0)` is the cheapest way for a stranger to fake or hide activity, so the filter is the first thing a `Transfer` log meets in `react()`, and every refusal is logged (`SpoofRefused`).
- **A canary guards against a deaf network.** An owner-independent Chainlink feed proves the network can still hear a chain; a gap in it freezes the countdown once, capped, instead of releasing on a silence nobody measured.
- **Small, reversible, claimed by the heir.** A vault on Base holds a capped deposit; the owner can withdraw at any time before release; release needs a two-step claim (`initiateClaim`, then `finalizeClaim` after `claimDelay`); anyone may press either step and the payout goes only to the heir.

States: `ARMED → GRACE → CLAIMABLE → CLAIM_PENDING → RELEASED`. Any watched owner activity (an allowlisted-token transfer or a vault action) during GRACE cancels it.

## 🏗️ Architecture & Tech Stack

| Layer | Choice |
|---|---|
| Reactive contract | `HeirloomReactive` on Reactive Lasna, built on `reactive-lib-omni` (`AbstractReactive`) |
| Destination | `HeirloomVault` on Base Sepolia, `AbstractCallback`, both guards on `sync()` |
| Tests | Foundry with the Reactive Network's Test Lib, via an Omni adapter in `packages/reactive-kit` |
| Scripts | TypeScript with viem, run with `tsx` |
| Status page | static `status/` (HTML + one ES module), read-only live chain reads plus the heir's claim panel |

<p align="center"><img src="docs/architecture.png" alt="Heirloom architecture, one loop across three chains. 1: the owner's allowlisted token transfers on Ethereum Sepolia and Base Sepolia reach the reactive contract as subscribed logs; a stranger's $0 transfer is refused (example transactions from the demo and long-t instances). On Reactive Lasna, HeirloomReactive.react() 2: filters first (SpoofRefused) and stamps lastSeen, 3: times the silence on Cron ticks through the Phase values ARMED, GRACE and EXPIRED (EXPIRED makes the vault CLAIMABLE), with a Chainlink canary on Base Sepolia whose gap past maxGap freezes the clock once, and 4: calls back to Base with requestCallbackV_1_0, held until the vault's Ack. On Base Sepolia the callback proxy calls sync(rvm, snapshot) on HeirloomVault, whose VaultState returns to ARMED on an owner action or sync(), moves to GRACE and CLAIMABLE by sync(), CLAIM_PENDING by initiateClaim and RELEASED by finalizeClaim after claimDelay; the vault emits OwnerActive and Ack back to react(). 5: anyone may press either claim step and the payout goes only to the heir." width="100%"></p>

The diagram source is [`docs/architecture/architecture.html`](docs/architecture/architecture.html).

## 🏆 Reactive Network Integration

The reactive contract is the engine, not an add-on: the loop does not exist without it.

<p align="center"><img src="docs/assets/broll/crosschain-callback.gif" alt="Status card, demo instance: on the Grace cancelled row, boxes mark the origin tx 0x2082…ef00 on Base Sepolia, the reactive tx 0x99bb…99fe on Lasna and the callback tx 0x217b…90ce on Base Sepolia; then rows from that reactive tx's Reactscan page, captured 2026-11-16: its full hash, its callback to Base Sepolia (84532) passing requested, relayed, sent, included, confirmed and posted, and the destination tx 0x217b43e3…f390ce, which is the callback hash on the card" width="880"></p>
<p align="center"><em>Recorded testnet run, 2026-11-08 (demo instance, T = 5 min): one grace cancel, three real transactions. The owner's transfer <a href="https://sepolia.basescan.org/tx/0x2082f0bc5c04108e8393bb2b58451b5a58c90a057aa0ccc6a2e2d8aee05def00"><code>0x2082…ef00</code></a> on Base Sepolia, the reactive transaction <a href="https://lasna.reactscan.net/tx/0x99bb1f2241f3b067a91e4130343e0d8a6bfe8245aa658b4e639329c4ed2899fe"><code>0x99bb…99fe</code></a> on Lasna, and its callback <a href="https://sepolia.basescan.org/tx/0x217b43e3027b9ead0bf1f1af33137ab12b8a9a4f69c4202fec9d82bf62f390ce"><code>0x217b…90ce</code></a> into the vault on Base Sepolia. The Reactscan rows were captured from the live explorer on 2026-11-16.</em></p>

| Capability | Where it is used |
|---|---|
| `SYSTEM.subscribe` / `unsubscribe` | enumerated per (chain, token, `Transfer`, topic1 = owner); the allowlist, spam brake, canary arming and teardown all change subscriptions at runtime |
| `requestCallbackV_1_0` | GRACE, CANCEL, EXPIRE, ATTEST and REVIVE callbacks to the vault (REVIVE is covered by tests; no live REVIVE triple yet), `gasLimit` 1,000,000 |
| CRON topics | the only clock (silence, grace, attest); one tier chosen at deploy, an optional faster tier can run during grace (unused on the testnet instances); attest is weekly on long-t |
| Self-unsubscribe | `react()` removes its own subscriptions on teardown; the finished demo instance holds 0 filters on Lasna (command in [DEMO.md](DEMO.md)) |
| Callback proxy guards | `sync()` checks both the proxy caller and the injected first argument (the reactive contract) |
| Reactive Test Lib | the whole loop (log → `react()` → callback) runs in `forge test` |

Measured platform facts, including what did not work as documented, are in [docs/DX-REPORT.md](docs/DX-REPORT.md).

## ⛓️ Live Deployment

Testnet instances; [DEMO.md](DEMO.md) links every callback row and the main reactive-only rows, and every row is in [`evidence/triples.csv`](evidence/triples.csv):

| | Reactive contract (Lasna) | Vault (Base Sepolia) |
|---|---|---|
| demo (T = 5 min) | [`0xa3d92EAefb2fc4C972d6Ee524c24F38A93739B8b`](https://lasna.reactscan.net/address/0xa3d92EAefb2fc4C972d6Ee524c24F38A93739B8b) | [`0x51365bb9560dDfA4236fd62d4eF2CB61f78edDBA`](https://sepolia.basescan.org/address/0x51365bb9560dDfA4236fd62d4eF2CB61f78edDBA) |
| long-t (T = 90 days) | [`0x80b56204D8860a6B46c08deCd9F01DD1881F9DC6`](https://lasna.reactscan.net/address/0x80b56204D8860a6B46c08deCd9F01DD1881F9DC6) | [`0x8C37E79420Cd16e46E4D9FFd4541a87FfFa4e7Be`](https://sepolia.basescan.org/address/0x8C37E79420Cd16e46E4D9FFd4541a87FfFa4e7Be) |

The demo instance ran the full scenario on live networks: grace twice, one cancel by owner activity, one expiry, the claim, teardown; 5 of 5 callbacks acknowledged (`evidence/status.json`), 0 resends (`evidence/demo-summary.json`). The 11-08 demo and the 90-day instance predate the last fixes; on 2026-11-22 the `demo-head` instance repeated the whole lifecycle from `201eb1e`, the current contract source, with a third wallet pressing the claim ([DEMO.md](DEMO.md#the-same-lifecycle-at-head-2026-11-22)). **Try it yourself:** [`scripts/trigger-spoof.ts`](scripts/trigger-spoof.ts) fires a spoof from any wallet and you watch the reactive contract refuse it ([DEMO.md](DEMO.md#fire-a-fresh-loop-yourself)).

<p align="center"><img src="docs/assets/broll/release-payout.gif" alt="Demo instance after the owner went quiet: the status card's heir stub shows heir 0x440E…438b, a claim delay of 7 min 30 s and the line Released: every estate token was paid to the heir; Blockscout shows the finalizeClaim transaction succeeding and transferring 4 tHTD, the testnet test-dollar token, from the vault 0x51…dDBA to the heir 0x44…438b; the card's oxblood RELEASED stamp presses in and holds" width="880"></p>
<p align="center"><em>Recorded testnet run, 2026-11-08 (demo instance). After grace ran out and the 7 min 30 s claim delay passed, <code>finalizeClaim</code> <a href="https://sepolia.basescan.org/tx/0x13d8677c445bbfb41a63e33b3405c218bec83b6af7c50018ca34d739caf580d3"><code>0x13d8…80d3</code></a> paid all 4 tHTD in the vault to the heir (tHTD is the project's testnet token, "Heirloom Test Dollar", <a href="src/testnet/TestDollar.sol"><code>src/testnet/TestDollar.sol</code></a>).</em></p>

## 📊 Engineering Rigor

| Check | Result |
|---|---|
| Contract tests (`forge test`) | 169 passed, 0 failed |
| Shared kit tests (`FOUNDRY_PROFILE=kit forge test`) | 27 passed, 0 failed |
| TypeScript tests (`pnpm test:ts`) | 27 passed, 0 failed |
| Coverage, `src/` contracts (`forge coverage`, forge 1.9.0, gated in CI) | lines 616/616, functions 91/91, branches 203/204: the one left is the `if (c.armed) return;` guard at `src/HeirloomReactive.sol:509`, which no caller can reach (the gate allows it by name and fails if it ever becomes reachable) |
| Coverage, kit contracts (`FOUNDRY_PROFILE=kit forge coverage`) | lines 64/64, functions 20/20, branches 17/17 |
| Coverage, TypeScript kit (`pnpm test:coverage`, thresholds 100) | lines 131/131, functions 29/29, branches 111/111 |
| Rows in `evidence/triples.csv` | 58 (31 with a callback leg: 22 from Heirloom instances (19 CRON-triggered, 3 owner-transfer CANCELs) and 9 from day-1 probes, 2 of them deliberately failed; 27 reactive-only) |

### Attacks defeated

<p align="center"><img src="docs/assets/broll/spoof-refused.gif" alt="Live testnet run from a stranger's wallet 0x144C…57F8: a terminal excerpt shows trigger-spoof.ts, transferFrom(owner, you, 0) simulating without a revert, and the origin tx 0xb476…f55f; then rows from Reactscan, captured 2026-11-16: Lasna transaction 0x433b24f1…5069ee18, its origin transaction 0xb476…f55f, the origin Transfer to 0x144C…4057F8 with value 0, and a log from the reactive contract whose topic 0 is 0xbea89ef3…f21c657, the SpoofRefused event; then the long-T status card, read about 9 minutes later, with the 23:35:02 row struck through as Refused · zero value while Last seen stays at the owner's 23:34:23 visit" width="880"></p>
<p align="center"><em>Recorded live on 2026-11-08 at 23:35 UTC. A stranger's zero-value transfer <a href="https://sepolia.basescan.org/tx/0xb476a67684d8f6406de291b91dcb1636d30af9b8ae674ed3438974629a4bf55f"><code>0xb476…f55f</code></a> is refused on Lasna in <a href="https://lasna.reactscan.net/tx/0x433b24f19ebddbb164ff15c3e92e638ddb6d7947ade8f910fa81e82e5069ee18"><code>0x433b…ee18</code></a>: topic 0 of its log, <code>0xbea89ef3…</code>, is keccak256 of <code>SpoofRefused(uint256,address,uint256,uint8)</code> (<a href="src/HeirloomReactive.sol#L144"><code>src/HeirloomReactive.sol:144</code></a>). The Reactscan rows were captured on 2026-11-16; the card was read about 9 minutes after the spoof. This is a second spoof run; JUDGE.md step 4 cites the 20:22 UTC run.</em></p>

| Control | Why it is load-bearing | Test |
|---|---|---|
| Zero-value spoof refused | a stranger cannot fake life with `transferFrom(owner, x, 0)` | `test_spoof_zero_value` (`test/HeirloomReactive.t.sol:23`) |
| Token allowlist | a worthless token's transfer cannot reset the clock | `test_spoof_not_allowlisted` (`:33`) |
| Spoof does not cancel a grace | one spoofed transfer cannot reset the clock or cancel a grace; a sustained spray can only delay a release, never cause one (Known limit 1) | `test_spoof_in_grace_does_not_cancel` (`:254`) |
| Filter runs first | a refused react stays under a fixed gas ceiling, so spam is cheap to refuse | `test_refused_react_gas_ceiling` (`:57`) |
| Spam brake | refused reacts are billed; without a bound spam could drain the reserve and silence the contract | `test_spam_brake` (`:76`) |
| Freeze once, capped | a canary outage delays a release once and cannot be chained | `test_freeze_not_twice` (`:275`) |
| Both callback guards | only the proxy, relaying this reactive contract, can move the vault | `test_sync_direct_call_reverts`, `test_sync_wrong_rvm_reverts` (`test/HeirloomVault.t.sol:23`, `:29`) |
| Resend with backoff | a callback lost in an outage is retried, then slows down | `test_resend_delivers_after_outage` (`test/HeirloomReactive.t.sol:437`) |

### Known limits

1. **An active spam brake holds a grace.** Safety over liveness: spam can delay a release, never cause one.
2. **Approved spenders count as life.** Any value-carrying `Transfer` from the owner counts, including one made by a spender holding a standing allowance. That can only delay a release. Allowlist tokens that have no standing allowances.
3. **Cross-chain revive is best effort.** The vault owner's own action is the synchronous cancel.
4. **Top-up.** Fund the reactive contract with a transfer plus `coverDebt()` (or the system contract's `depositTo(address)`); a plain transfer does not clear its debt. The 90-day testnet instance hit exactly this: its build predates `coverDebt()`, it stalled in debt, and `depositTo` revived it on 2026-11-22 (see DEMO.md, Instances).
5. **Watch-set drift after an origin reorg.** An orphaned Base `setAllowlist(.., false)` can leave the reactive contract unsubscribed until the next `setAllowlist`. Documented at the ALLOWLIST branch of `react()`. Related: the vault binds the Base callback proxy at construction and has no setter, so if Reactive ever rotated that proxy the heir path would stop; the owner's `withdraw` and `retire` keep working.
6. **No mainnet evidence yet.** Cost per month is not published: the measured window is too short, and a dollar figure needs a second price source. The canary gaps in `evidence/canary-gaps.json` cover about 23 h of Ethereum feeds (medians 3,612 s and 3,636 s); a multi-day measurement is still open.
7. **Native ETH and silent grace.** Native ETH transfers emit no ERC-20 `Transfer` log, so they are not proof of life; hold WETH-style tokens. Nobody is notified when a grace window opens, so choose T above your longest normal quiet stretch. Until notifications ship, a living owner can watch the vault itself: every vault state change emits `StateChanged`, so an explorer address alert on the vault warns of a grace window.

## 🚀 Getting Started

### Prerequisites

[Foundry](https://book.getfoundry.sh/), Node 20+ and pnpm.

### Installation

```sh
git clone --recurse-submodules https://github.com/edycutjong/heirloom && cd heirloom
pnpm install
pnpm exec tsx scripts/trigger-spoof.ts --dry-run   # simulate a spoof against the live long-t instance
PRIVATE_KEY=0x… pnpm exec tsx scripts/trigger-spoof.ts   # the real thing: any Base Sepolia key with a little ETH
```

Live-script settings (RPC overrides, keys) are listed in [`.env.example`](.env.example); the tests need none of them.

## 🧪 Testing & CI

```sh
forge test                             # contracts
FOUNDRY_PROFILE=kit forge test         # reactive-kit
pnpm typecheck && pnpm test:coverage   # TypeScript (vitest, coverage thresholds 100)
pnpm e2e                               # Playwright against the assembled Pages site
```

| Stage (`.github/workflows/ci.yml`) | What runs |
|---|---|
| 1 · Quality | `forge fmt --check`, `forge test` (both profiles), `forge coverage` gated by `scripts/coverage-gate.py`, `tsc`, vitest with coverage |
| 2 · Security | gitleaks over full history (`gitleaks.yml`), `pnpm audit --audit-level high`, Slither (advisory) |
| 3 · Build | `forge build --sizes`, shell scripts parse, Pages site assembled and every local link checked |
| 4 · E2E | Playwright: landing, deck, `/judge/` with no session, status card, no horizontal scroll at 375/768/1440 px |
| 5 · Performance | Lighthouse CI on landing, `/judge/` and deck (advisory) |
| 6 · Deploy Gate | main only; passes only when every stage did |

CodeQL (`codeql.yml`) scans the TypeScript and JavaScript; Dependabot sends grouped monthly minor/patch updates for npm and Actions (majors and `lib/` submodules are pinned on purpose); `release.yml` tags a semantic version from conventional commits. See [SECURITY.md](SECURITY.md) and [CONTRIBUTING.md](CONTRIBUTING.md).

## 📁 Project Structure

```
src/             HeirloomReactive, HeirloomVault, shared types; src/probe/ (Day-1 spike), src/testnet/ (test token)
test/            Foundry suites: reactive, vault, hardening, probe, coverage
packages/reactive-kit/   shared MIT helpers: Test Lib adapter, absence watch, ack/resend ledger, triple logger, latency observer
scripts/         triples, status and cost recompute, trigger-spoof, mainnet deploy (dry-run)
script/          deploy and scenario shell scripts
status/          static status page
e2e/             Playwright specs for the Pages site
evidence/        triples.csv and the raw measurements
docs/            landing (index.html), judge/, pitch/, DX-REPORT.md, architecture.png (source: architecture/)
JUDGE.md         the judge page in Markdown: claim, 30-second path, receipts, limits
```

## 🗺️ Roadmap

- [x] Spoof filter, allowlist, spam brake, canary freeze
- [x] Grace, cancel, expiry, two-step heir claim, teardown on live testnet
- [x] Shared `reactive-kit` and Test Lib adapter
- [ ] Mainnet instances (a 90-day one and a 48 h one)
- [ ] A REVIVE triple in the evidence
- [x] Hardening: CI scans, SECURITY.md

## 📽️ Demo Materials

- For judges, the 30-second path: [JUDGE.md](JUDGE.md) · [web version](https://edycutjong.github.io/heirloom/judge/)
- Every transaction, with a command to fire your own: [DEMO.md](DEMO.md)
- Measured platform facts: [docs/DX-REPORT.md](docs/DX-REPORT.md)

## 📄 License

MIT. See [LICENSE](LICENSE).
