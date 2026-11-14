# Contributing

Thanks for looking at Heirloom. This is a hackathon project; small, focused PRs are welcome.

## Setup

```sh
git submodule update --init --recursive
pnpm install --frozen-lockfile
cp .env.example .env   # only for the live scripts; tests need no keys
```

## Checks before a PR

```sh
forge fmt --check && FOUNDRY_PROFILE=kit forge fmt --check   # src/ and the kit sources are frozen (foundry.toml)
forge build && forge test                                     # contracts
FOUNDRY_PROFILE=kit forge test                                # reactive-kit
pnpm typecheck && pnpm test:coverage                          # TypeScript, coverage thresholds 100
pnpm e2e                                                      # Playwright against the assembled Pages site
gitleaks detect --source . --log-opts="--all" --gitleaks-ignore-path .gitleaksignore
```

Coverage gates (the same commands CI Stage 1 runs):

```sh
forge coverage --report lcov --no-match-coverage '(script|test|lib)/' \
  && python3 scripts/coverage-gate.py lcov.info --include '^src/' --allow-branch src/HeirloomReactive.sol:509
FOUNDRY_PROFILE=kit forge coverage --report lcov --no-match-coverage '(test|lib)/' \
  && python3 scripts/coverage-gate.py lcov.info --include '^packages/reactive-kit/src/' --exclude '/test/'
```

## Commits and releases

Use conventional commits: `feat:` (minor release), `fix:` / `perf:` (patch), `feat!:` or a `BREAKING CHANGE:` footer
(major); `docs:`, `test:`, `ci:`, `chore:`, `refactor:` do not release. `release.yml` tags and publishes from these.

## Guidelines

- Never commit keys or `.env` files; credentials live outside the repo.
- Contract changes need a test. Name a regression test after the defect it pins.
- Numbers quoted in docs must trace to `evidence/` or a test.
