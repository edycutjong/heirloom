# Heirloom for judges

> When your wallet goes quiet, silence pays your heir. A Reactive dead-man's switch: no keeper, no check-in button, spoofs refused.

Web version (no wallet, no sign-in): **https://edycutjong.github.io/heirloom/judge/**. Track: **Set It and Forget It**. Everything below is testnet (Reactive Lasna 5318007 + Base Sepolia 84532); the mainnet deploy is scripted and dry-run, not yet run.

## The 30-second path

Every link is a real transaction on a public explorer. The demo instance ran with T = 5 min on 2026-11-08 (UTC). These instances were deployed from a commit before `HEAD` (before the re-entry lock, `coverDebt()` and the claim-grace fix): the rows prove the loop, the tests cover `HEAD`.

0. **Live again on 2026-11-22:** after the revival, the long-T contract's next CRON tick sent its overdue weekly ATTEST: CRON [`0xb5efe19b…d124`](https://lasna.reactscan.net/tx/0xb5efe19b1f732eb58d82ca56bdfe395feb870d394996913dd63066f06987d124) → react [`0xf776b049…3500`](https://lasna.reactscan.net/tx/0xf776b049b86c6f59ee2ac63bbc578d43496cc944ee2b2e811f4e957ceea13500) → callback [`0x0d654fcd…855b`](https://sepolia.basescan.org/tx/0x0d654fcd69b0deda5039f67662502ab774c635ca5a6b7265ff332eec5d6a855b) (acknowledged; the vault paid about 0.0000012 ETH for it).
1. **Open the live status card:** https://edycutjong.github.io/heirloom/status/. It reads both testnet instances from the chain: the 90-day one is armed, the demo one is released.
2. **Silence opens a grace window.** A Reactive CRON tick saw no owner activity for T, so the reactive contract asked the Base vault to enter GRACE.
   CRON [`0x9535fa9d…10a0`](https://lasna.reactscan.net/tx/0x9535fa9d6409fb168cba654e2b53c499770c409fb6cafe61fa6d648549cd10a0) → react [`0xe4d5fb4d…4e5d`](https://lasna.reactscan.net/tx/0xe4d5fb4d7d811d13c35781eabf43cfcdc6fe03f972291299ca01b3df77d74e5d) → callback [`0xde28408b…9488`](https://sepolia.basescan.org/tx/0xde28408b0cb45115d6bde3464bf03255e356a5411d666c0c7f617bee3d209488)
3. **An ordinary owner transfer cancels it.** No button: a token transfer on Base Sepolia was the proof of life.
   origin [`0x2082f0bc…ef00`](https://sepolia.basescan.org/tx/0x2082f0bc5c04108e8393bb2b58451b5a58c90a057aa0ccc6a2e2d8aee05def00) → react [`0x99bb1f22…99fe`](https://lasna.reactscan.net/tx/0x99bb1f2241f3b067a91e4130343e0d8a6bfe8245aa658b4e639329c4ed2899fe) → callback [`0x217b43e3…90ce`](https://sepolia.basescan.org/tx/0x217b43e3027b9ead0bf1f1af33137ab12b8a9a4f69c4202fec9d82bf62f390ce)
4. **A stranger's $0 transfer is refused.** `transferFrom(owner, you, 0)` from another wallet; the long-T reactive contract logged `SpoofRefused` with reason `ZERO_VALUE`.
   origin [`0x777b953e…4d79`](https://sepolia.basescan.org/tx/0x777b953e33748cc005ae19e57c2f480ec54a2244203291ca7162690ab4174d79) → react [`0xb622bc82…f226`](https://lasna.reactscan.net/tx/0xb622bc82cdbd66bad8d5c14e085d4c080ec253c99b10ad1413675f67e849f226)
5. **Silence again, grace runs out, the heir is paid.** EXPIRE makes the vault claimable; the two-step claim pays only the heir (`0x440E…438b`).
   EXPIRE callback [`0xabb5147f…0401`](https://sepolia.basescan.org/tx/0xabb5147f4da4bb94174c142612cdde6dfbcac89f7c206f757d24426d8a6e0401) · initiateClaim [`0xf86669ab…de8d`](https://sepolia.basescan.org/tx/0xf86669ab514601ee00a1fc8c0f97e6f0e6e2edb405cc9d496e761f25d91ede8d) · finalizeClaim [`0x13d8677c…80d3`](https://sepolia.basescan.org/tx/0x13d8677c445bbfb41a63e33b3405c218bec83b6af7c50018ca34d739caf580d3)
6. **The contract cleans up after itself.** After the payout, `react()` removed its own subscriptions: the finished demo instance holds 0 filters on Lasna.
   teardown [`0x1eb6d631…a988`](https://lasna.reactscan.net/tx/0x1eb6d631129b1db49bac2a230b10632214460809939c29e517d614021c25a988) · check command in [DEMO.md](DEMO.md)

## Receipts

| Measure | Value | Source |
|---|---|---|
| Rows in the triple log (origin or CRON → reactive → callback) | 45 (23 with a callback leg: 14 from Heirloom instances (12 CRON-triggered, 2 owner-transfer CANCELs) and 9 from day-1 probes, 2 of them deliberately failed) | [`evidence/triples.csv`](evidence/triples.csv) |
| Demo instance callbacks acknowledged | 5 of 5, 0 resends | [`evidence/status.json`](evidence/status.json), [`evidence/demo-summary.json`](evidence/demo-summary.json) |
| Demo scenario | 2 graces, 1 cancel, 1 expiry, claim, teardown | [`evidence/demo-summary.json`](evidence/demo-summary.json) |
| Contract tests (`forge test`) | 168 passed | [`test/`](test/) |
| Shared kit tests (`FOUNDRY_PROFILE=kit forge test`) | 27 passed | [`packages/reactive-kit/test/`](packages/reactive-kit/test/) |
| TypeScript tests (`pnpm test:coverage`) | 27 passed | [`packages/reactive-kit/ts/`](packages/reactive-kit/ts/) |
| Line coverage: `src/` contracts · kit contracts · TypeScript kit | 611/611 · 64/64 · 126/126 | CI Stage 1 gate; branches 202/203 in `src/` (the one left is an unreachable guard, `HeirloomReactive.sol:509`, allowed by name) |

## Reproduce it yourself

The real path: fire a spoof from any Base Sepolia wallet against the live long-T instance and watch the reactive contract refuse it on Lasna.

```sh
git clone --recurse-submodules https://github.com/edycutjong/heirloom && cd heirloom
pnpm install
PRIVATE_KEY=0x… pnpm exec tsx scripts/trigger-spoof.ts   # any Base Sepolia key with a little ETH; sends a real tx
```

CI / deterministic replay (not the product, no network): `forge test && FOUNDRY_PROFILE=kit forge test && pnpm test:coverage`. No key? `pnpm exec tsx scripts/trigger-spoof.ts --dry-run` simulates the same call with `eth_call` and sends nothing.

## Honest limits

- **No mainnet evidence yet.** The mainnet deploy is scripted and dry-run, not run. Every transaction on this page is testnet.
- **The testnet instances predate `HEAD`.** They were deployed before the re-entry lock, `coverDebt()` and the claim-grace fix; the rows prove the loop, the current contracts are what the tests run.
- **Native ETH and silent grace.** Native ETH transfers emit no ERC-20 `Transfer` log, so they are not proof of life, and nobody is notified when a grace window opens. Until notifications ship, a living owner can watch the vault itself: every vault state change emits `StateChanged`, so an explorer address alert on the vault warns of a grace window.

## Links

- Repository: https://github.com/edycutjong/heirloom
- Every transaction, with a command to fire your own: [DEMO.md](DEMO.md)
- Live status card: https://edycutjong.github.io/heirloom/status/
- Landing page: https://edycutjong.github.io/heirloom/
- Pitch deck: https://edycutjong.github.io/heirloom/pitch/
- Latest release: https://github.com/edycutjong/heirloom/releases/latest
