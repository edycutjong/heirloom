# Heirloom

A dead-man's switch for a self-custody wallet, built on the Reactive Network (Omni). Work in progress.

- `src/probe/` — Day-1 spike contracts (Lasna reactive contract + Base Sepolia callback) used to measure the network's real behaviour.
- `packages/reactive-kit/` — shared, MIT-licensed helpers for Reactive Omni projects: Foundry test harness, CRON topics, absence/canary watch, Ack/resend ledger, tx-triple logger, wall-clock latency observer.
- `evidence/` — on-chain evidence: `triples.csv` (origin → reactive → callback tx hashes), latency samples, CRON probe.
- `docs/DX-REPORT.md` — measured platform facts and friction log.

## Build & test

```sh
git submodule update --init --recursive
forge test                      # contracts
FOUNDRY_PROFILE=kit forge test  # reactive-kit
pnpm install && pnpm typecheck && pnpm test:ts
```

License: MIT.
