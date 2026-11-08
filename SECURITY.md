# Security Policy

Heirloom is a hackathon-stage project (Reactive Omni Buildathon 2026). It has **not** been externally audited.
Contracts hold only small, capped amounts by design (the mainnet demo instance is a ~$5 vault).

## Reporting a vulnerability

Please open a private security advisory on this repository (Security → Report a vulnerability) rather than a public issue.
Include the contract, the transaction sequence, and the expected vs. observed state. We aim to acknowledge within 72 hours.

## Scope

- `src/HeirloomReactive.sol`, `src/HeirloomVault.sol`, `src/HeirloomTypes.sol`
- `packages/reactive-kit/`

Out of scope: `src/probe/`, `src/testnet/` (spike and test-token helpers), third-party code in `lib/`.

## Automated checks

Every push runs `forge test`, gitleaks over full history, and Slither (see `.github/workflows/`). Known design limits are listed under
"Known limits" in the README.
