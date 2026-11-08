# Contributing

Thanks for looking at Heirloom. This is a hackathon project; small, focused PRs are welcome.

## Setup

```sh
git submodule update --init --recursive
pnpm install --frozen-lockfile
```

## Checks before a PR

```sh
forge build && forge test                    # contracts
FOUNDRY_PROFILE=kit forge test               # reactive-kit
pnpm typecheck && pnpm test:ts               # TypeScript scripts
gitleaks detect --source . --log-opts="--all" --gitleaks-ignore-path .gitleaksignore
```

## Guidelines

- Never commit keys or `.env` files; credentials live outside the repo.
- Contract changes need a test. Numbers quoted in docs must trace to `evidence/`.
- Keep commits small with real messages.
