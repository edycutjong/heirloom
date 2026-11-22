# Heirloom: demo and proof

Every row below is a real transaction on Reactive Lasna (5318007), Base Sepolia (84532) or Ethereum Sepolia (11155111), copied from [`evidence/triples.csv`](evidence/triples.csv), [`evidence/demo-actions.csv`](evidence/demo-actions.csv) and [`evidence/fresh-loop-runs.csv`](evidence/fresh-loop-runs.csv). Nothing here is simulated. Mainnet rows do not exist yet: the mainnet deploy is a separate step (`scripts/deploy-mainnet.sh`, dry-run only so far), so every claim on this page is a testnet claim.

**Which build.** The testnet instances were deployed from an earlier commit than `HEAD` (before the re-entry lock, `coverDebt()` and the claim-grace fix). The rows prove the loop; the current contracts are what `forge test` runs and what mainnet deploys.

## The loop in one line

A watched wallet's token activity on an origin chain → a Reactive Network contract (`react()`) decides whether it counts as life → on silence it requests a callback → `HeirloomVault` on Base moves to GRACE, then CLAIMABLE, then pays the heir after a two-step claim. A **triple** is one origin or trigger tx, the reactive tx it caused on Lasna, and the callback tx it produced on Base.

## Instances

| Instance | Reactive contract (Lasna) | Vault (Base Sepolia) | T | Notes |
|---|---|---|---|---|
| demo | [`0xa3d92EAe…B8b`](https://lasna.reactscan.net/address/0xa3d92EAefb2fc4C972d6Ee524c24F38A93739B8b) | [`0x51365bb9…DBA`](https://sepolia.basescan.org/address/0x51365bb9560dDfA4236fd62d4eF2CB61f78edDBA) | 5 min | full scenario, torn down after the claim |
| long-t | [`0x80b56204…DC6`](https://lasna.reactscan.net/address/0x80b56204D8860a6B46c08deCd9F01DD1881F9DC6) | [`0x8C37E794…7Be`](https://sepolia.basescan.org/address/0x8C37E79420Cd16e46E4D9FFd4541a87FfFa4e7Be) | 90 days | armed as of 2026-11-08 (UTC); funded for days, not its 90-day horizon (`evidence/status.json`); the one to fire a loop against |

Owner (both): `0x12bF8bbD1Eec23B5ab5A44B8d551bbC1d038651C`. Heir: `0x440E03bb3AAdBE65D5Bf2Ad7f84A64c509ff438b`.

## Triples

Callback stages (GRACE, CANCEL, EXPIRE, ATTEST) have all three legs. VISIT and REFUSED are reactive-only: the origin tx and the reactive tx that handled it. A CRON-triggered stage has the Lasna CRON tx in the "trigger" column.

### Demo instance (T = 5 min): grace, cancel, grace, expiry, attest

| Stage | Trigger | Origin / trigger tx | Reactive tx (Lasna) | Callback tx (Base Sepolia) |
|---|---|---|---|---|
| GRACE | cron @ 5318007 | [`0x9535fa9d…10a0`](https://lasna.reactscan.net/tx/0x9535fa9d6409fb168cba654e2b53c499770c409fb6cafe61fa6d648549cd10a0) | [`0xe4d5fb4d…4e5d`](https://lasna.reactscan.net/tx/0xe4d5fb4d7d811d13c35781eabf43cfcdc6fe03f972291299ca01b3df77d74e5d) | [`0xde28408b…9488`](https://sepolia.basescan.org/tx/0xde28408b0cb45115d6bde3464bf03255e356a5411d666c0c7f617bee3d209488) |
| CANCEL | origin_log @ 84532 | [`0x2082f0bc…ef00`](https://sepolia.basescan.org/tx/0x2082f0bc5c04108e8393bb2b58451b5a58c90a057aa0ccc6a2e2d8aee05def00) | [`0x99bb1f22…99fe`](https://lasna.reactscan.net/tx/0x99bb1f2241f3b067a91e4130343e0d8a6bfe8245aa658b4e639329c4ed2899fe) | [`0x217b43e3…90ce`](https://sepolia.basescan.org/tx/0x217b43e3027b9ead0bf1f1af33137ab12b8a9a4f69c4202fec9d82bf62f390ce) |
| GRACE | cron @ 5318007 | [`0x17ab70ce…6e5a`](https://lasna.reactscan.net/tx/0x17ab70ce258d30f3ef517202ce30e0e5a2374aaa47b2b2536fa23d671ee36e5a) | [`0x4eb1a473…cc18`](https://lasna.reactscan.net/tx/0x4eb1a473547c2ce10ce5f415d83a8363fbff3b001ce09a6d5e79e8833843cc18) | [`0x484b96d0…fe2f`](https://sepolia.basescan.org/tx/0x484b96d0154bf62b99f08ce40a24d5b12c32b740fbc727259146a3426e9efe2f) |
| EXPIRE | cron @ 5318007 | [`0x569b06af…9704`](https://lasna.reactscan.net/tx/0x569b06af98ae83a68faa81b9d723a02ba3d2818093d4138cee1006e0163a9704) | [`0x87e9a71f…e0f4`](https://lasna.reactscan.net/tx/0x87e9a71f93602d20f133e29c090a2adb5022b7aadee7194e5f1c8b6bb7eee0f4) | [`0xabb5147f…0401`](https://sepolia.basescan.org/tx/0xabb5147f4da4bb94174c142612cdde6dfbcac89f7c206f757d24426d8a6e0401) |
| ATTEST | cron @ 5318007 | [`0xc860df62…629e`](https://lasna.reactscan.net/tx/0xc860df62abf8792452cb03d25e08f4fd081798b49fbe419509204b34c4ad629e) | [`0x794783a5…a790`](https://lasna.reactscan.net/tx/0x794783a5552e425efba1d4c651eeffd682d3977b52b7142c5a194a9c307ea790) | [`0x54d9e18e…3614`](https://sepolia.basescan.org/tx/0x54d9e18e6df914d6fe6cacd43028848d6f8ee10894e8b01a4b3292d3106e3614) |

### Short-T end-to-end instance (`p1b-e2e`): attest ×4, grace ×2, cancel, expiry

| Stage | Trigger | Origin / trigger tx | Reactive tx (Lasna) | Callback tx (Base Sepolia) |
|---|---|---|---|---|
| ATTEST | cron @ 5318007 | [`0x53f7da45…6546`](https://lasna.reactscan.net/tx/0x53f7da451fb8aa6816a9852d4d5feeac96836c32f224dd4ed2d2d5f21fb46546) | [`0xcb0c2b41…564d`](https://lasna.reactscan.net/tx/0xcb0c2b416bebffd685dc61e961a5d28bb2b2225caa31b5aa7b1872d435aa564d) | [`0x13145551…d76c`](https://sepolia.basescan.org/tx/0x131455514a71496400e3e1183c40d42cfd938715749b7fefcebfd6288352d76c) |
| GRACE | cron @ 5318007 | [`0x258c5bef…873e`](https://lasna.reactscan.net/tx/0x258c5beff1b754b24f97f050c5264325a44db4944dcffb7f8b0f810c4f34873e) | [`0x0564f7bd…471e`](https://lasna.reactscan.net/tx/0x0564f7bde5c3d303ca185c334da818d626c930bdcf76b9f3796561e3035b471e) | [`0x77107fb2…23a9`](https://sepolia.basescan.org/tx/0x77107fb261b4f25df6f371c821a377fe2e7e3b641a7701487088819400da23a9) |
| CANCEL | origin_log @ 84532 | [`0x2e5530b2…4552`](https://sepolia.basescan.org/tx/0x2e5530b236fbafdf79474b8d673d29b36a1168b2306f781f185c0fcd83554552) | [`0x8cf34ab5…9b11`](https://lasna.reactscan.net/tx/0x8cf34ab520934e769ca7d7d98c9403a102407eb355180779b571437355d09b11) | [`0x35069a5a…274d`](https://sepolia.basescan.org/tx/0x35069a5a3e6db3f9199db94967a8ce18ee3a27432b9393f3e5f2a416da90274d) |
| ATTEST | cron @ 5318007 | [`0xe6149190…4bef`](https://lasna.reactscan.net/tx/0xe6149190082c7d03911435ae36da4e5fc5d144a1cd804e27168fc55e4d844bef) | [`0x07768548…8d88`](https://lasna.reactscan.net/tx/0x07768548ff625d9f9fabdd1065c744ca8197f69b9205a0b4231380e19a0c8d88) | [`0x2bda636b…1400`](https://sepolia.basescan.org/tx/0x2bda636bccb709f5eee63553eeda57e16fcb2083d93b20dd5616271588511400) |
| GRACE | cron @ 5318007 | [`0x2d0816a2…f341`](https://lasna.reactscan.net/tx/0x2d0816a2321de8addee7a7228d183da6af71a99eb97ca08cc652b6f5ea9df341) | [`0xc258b21c…f4b7`](https://lasna.reactscan.net/tx/0xc258b21ca14e3cb951bea687b763900d393fef3b5afb1b42778f969928def4b7) | [`0x8bb7b1bc…48a2`](https://sepolia.basescan.org/tx/0x8bb7b1bc8870028ffa24153969b345a3b008c1c7f13d29ec5b13c2d64fe148a2) |
| ATTEST | cron @ 5318007 | [`0x33a303d2…db35`](https://lasna.reactscan.net/tx/0x33a303d2c97b82c2a25a67847d02f9092fbcdd5a5bdc1e3d8e38b2be840adb35) | [`0x4dcc84ec…6dd4`](https://lasna.reactscan.net/tx/0x4dcc84ecf4f5ec135755939ce57633b9968b2fbe131fa94d6ba8327524356dd4) | [`0x514111f2…f8ac`](https://sepolia.basescan.org/tx/0x514111f23f38fe5cb67c072bab33920851227010f265352539719d091b09f8ac) |
| EXPIRE | cron @ 5318007 | [`0xa173a433…bc25`](https://lasna.reactscan.net/tx/0xa173a433e08568e6c7fcd3dd36807214af6e72cbcc67305e4de87189c2a4bc25) | [`0x124e82ed…47ca`](https://lasna.reactscan.net/tx/0x124e82ed0ea35129be2370cdd3a13cf731108f7abb70ff54e14cada82e4b47ca) | [`0x9c0992d2…ebf9`](https://sepolia.basescan.org/tx/0x9c0992d21658f778414ab4b9bb4a02db2e19ca93f124c9c2ca11c3d9e5b3ebf9) |
| ATTEST | cron @ 5318007 | [`0x596980e2…9f3c`](https://lasna.reactscan.net/tx/0x596980e24acba49b7f4de78b344c6b4cabaa3fea8b367d5d31219a4089ac9f3c) | [`0x0d39ce7c…52cf`](https://lasna.reactscan.net/tx/0x0d39ce7c3a36d31d8b6449535982595191aeaa358438d2fcca5dbd4d785952cf) | [`0x0ac06b7a…f1d8`](https://sepolia.basescan.org/tx/0x0ac06b7a110e758dae0b3a02b91d7286f5a916f96864990482c8b8b58f45f1d8) |

### Reactive-only rows (no callback): heartbeats and refused spoofs, long-T instance

The instances share one owner, so one owner transfer can appear more than once: `0xe698b8e6…68b6` is listed twice because that one tx emitted two watched logs, a token `Transfer` and the vault's `OwnerActive`, and each got its own reactive tx (not a double-processed log), and `0x2082f0bc…ef00` is the demo instance's CANCEL origin, which the long-T contract also counted as a visit (each contract was billed for it).

| Stage | Trigger | Origin tx | Reactive tx (Lasna) |
|---|---|---|---|
| VISIT | origin_log @ 84532 | [`0xe698b8e6…68b6`](https://sepolia.basescan.org/tx/0xe698b8e61267c4845ffd5a1e625106a32538eb914e34f91340593e5ba70068b6) | [`0xee192b3d…1101`](https://lasna.reactscan.net/tx/0xee192b3d2c4b3cd18d283fd7982a24b0ba92d38e26957525263c347cca301101) |
| VISIT | origin_log @ 84532 | [`0xe698b8e6…68b6`](https://sepolia.basescan.org/tx/0xe698b8e61267c4845ffd5a1e625106a32538eb914e34f91340593e5ba70068b6) | [`0x3205641e…fdf4`](https://lasna.reactscan.net/tx/0x3205641ec5e665a8288e51d825d894ebbd8393df07f925493358a4086fc8fdf4) |
| VISIT | origin_log @ 11155111 | [`0x5a227c35…8fd1`](https://sepolia.etherscan.io/tx/0x5a227c353f039392ca9df1d379ac7111f7006c505097a40d6f28488893598fd1) | [`0x2a6d7ba6…1051`](https://lasna.reactscan.net/tx/0x2a6d7ba6b8db4f2a8408af9337602445e4e95b4dcea7daed4a028920e2171051) |
| REFUSED | origin_log @ 84532 | [`0x5584cff3…8156`](https://sepolia.basescan.org/tx/0x5584cff365b6a51d651be89ac490837a58a547d7175544b755c0f4d41f888156) | [`0x7376cb13…d2c2`](https://lasna.reactscan.net/tx/0x7376cb131e93184115b03cdbd3386a68acaea10d99ed3f48b8a130ca6e32d2c2) |
| VISIT | origin_log @ 84532 | [`0x17d60349…f478`](https://sepolia.basescan.org/tx/0x17d60349ae30cf05796d73184a9698713209fe3d42e13a850e6f92035d16f478) | [`0xdb1e080d…aa78`](https://lasna.reactscan.net/tx/0xdb1e080dc9cab34b5c33e2fae9d3aca1b7f6b021adf1f433d44f0ed880f4aa78) |
| VISIT | origin_log @ 11155111 | [`0xbc2c6b8b…ac55`](https://sepolia.etherscan.io/tx/0xbc2c6b8b69649105fc56b15fac5f792b9117da76f9f01c5d6ef71442140bac55) | [`0x54e99883…e3a2`](https://lasna.reactscan.net/tx/0x54e99883591dbe92ee5c85816c6375938b6aa951d7cf486f3dcd3b2f8d3ae3a2) |
| REFUSED | origin_log @ 84532 | [`0xaac45c5d…52e9`](https://sepolia.basescan.org/tx/0xaac45c5d961a6daf07676707c49b2422f72f24c0d90c06025f9033ade90b52e9) | [`0x76661c01…6a77`](https://lasna.reactscan.net/tx/0x76661c01fd3877e9329ae37566d58d960e79a6026be9667e0df7ec7479ef6a77) |
| VISIT | origin_log @ 84532 | [`0x2082f0bc…ef00`](https://sepolia.basescan.org/tx/0x2082f0bc5c04108e8393bb2b58451b5a58c90a057aa0ccc6a2e2d8aee05def00) | [`0x479f3bf4…6c2b`](https://lasna.reactscan.net/tx/0x479f3bf4127e69e4189588dc07a6d51c0906204b880679ef90688d32db846c2b) |

### Claim on the demo instance (Base Sepolia)

Anyone may press either step; here both were pressed from the owner key, and the vault paid the heir (`0x440E…438b`).

| Step | Tx |
|---|---|
| `initiateClaim` | [`0xf86669ab…de8d`](https://sepolia.basescan.org/tx/0xf86669ab514601ee00a1fc8c0f97e6f0e6e2edb405cc9d496e761f25d91ede8d) |
| `finalizeClaim` | [`0x13d8677c…80d3`](https://sepolia.basescan.org/tx/0x13d8677c445bbfb41a63e33b3405c218bec83b6af7c50018ca34d739caf580d3) |

The scenario's own summary (`evidence/demo-summary.json`): 5 callback rows, 0 stuck, 0 resends, 0 `FreezeUsed`, 3 canary beats. Acknowledged callbacks: `evidence/status.json`, demo instance, `callbacksSent` 5 and `acked` 5.

Teardown check (the finished demo instance holds no filters on Lasna; the live long-t instance holds 10):

```sh
curl -s -X POST https://lasna-rpc.rnk.dev/ -H 'content-type: application/json' -d '{"jsonrpc":"2.0","id":1,"method":"rnk_getFilters","params":[]}' \
  | jq --arg rc 0xa3d92EAefb2fc4C972d6Ee524c24F38A93739B8b '[.. | objects | select(has("Contract")) | select((.Contract|type)=="string" and (.Contract|ascii_downcase)==($rc|ascii_downcase))] | length'
```

**Not yet in the evidence:** a REVIVE callback (the cross-chain revive after an expired grace) has no triple. REVIVE is the fifth callback kind (`src/HeirloomTypes.sol`). The CANCEL rows show the reactive path (an owner token transfer seen by `react()`); a vault owner action cancels synchronously on Base (`test_cancel_by_ping_in_grace`, `test_owner_withdraw_any_state`) and has no live triple.

## Fire a fresh loop yourself

Any wallet that is not the owner can send a zero-value `transferFrom(owner, you, 0)` on the instance's Base Sepolia USDC. It is not the owner's activity, so the reactive contract must refuse it. You see your origin tx, then a `SpoofRefused` event from the long-t reactive contract on Lasna shortly after (no timing figure is claimed). (Only the owner's key, or a spender the owner has approved on that token, can produce a real heartbeat; see Known limit 2 in the README.)

The long-T contract brakes a token after 20 refused spoofs within 24 hours (`maxRefusedPerWindow` = 20, `brakeWindow` = 86,400 s, both read from the deployed contract): after that you see a `SpamBrake` event and no `SpoofRefused` for that token for 24 hours. A brake can delay a release; it never causes one.

```sh
pnpm install
pnpm exec tsx scripts/trigger-spoof.ts --dry-run                 # simulates, sends nothing, needs no key
PRIVATE_KEY=0x… pnpm exec tsx scripts/trigger-spoof.ts           # any Base Sepolia key with a little ETH; default instance long-t
```

The script prints the origin tx link and the long-t reactive contract's Reactscan page. A run on 2026-11-08 at 20:22 UTC (the script as committed):

| Origin tx (Base Sepolia) | Reactive tx (Lasna) | Refusal reason |
|---|---|---|
| [`0x777b953e…4d79`](https://sepolia.basescan.org/tx/0x777b953e33748cc005ae19e57c2f480ec54a2244203291ca7162690ab4174d79) | [`0xb622bc82…f226`](https://lasna.reactscan.net/tx/0xb622bc82cdbd66bad8d5c14e085d4c080ec253c99b10ad1413675f67e849f226) | `ZERO_VALUE` (3) |

To read it from the chain without trusting this page:

```sh
cast logs --rpc-url https://lasna-rpc.rnk.dev/ --address 0x80b56204D8860a6B46c08deCd9F01DD1881F9DC6 --from-block 7865700 --to-block 7865900 'SpoofRefused(uint256,address,uint256,uint8)'
```

That window holds the run above; for your own run use `--from-block $((B-300))` right after sending (B = the head from `cast block-number`). The log's data begins with your origin tx hash; the last word is the refusal reason. `scripts/evidence-status.ts` recomputes the refused-spoof count for every instance.

## Test Lib output

The contracts are tested with the Reactive Network's own Test Lib, driven through an adapter in `packages/reactive-kit` because the library cannot drive an Omni contract as shipped (see [docs/DX-REPORT.md](docs/DX-REPORT.md) finding 1).

```sh
forge test                       # Ran 10 test suites: 168 tests passed, 0 failed, 0 skipped
FOUNDRY_PROFILE=kit forge test   # Ran 5 test suites: 27 tests passed, 0 failed, 0 skipped
pnpm test:ts                     # Test Files 2 passed, Tests 25 passed
```

Those are the counts at the latest test update (2026-11-14 UTC); the first version of this page (2026-11-08) ran 104, 23 and 6.

## Cost and latency

No cost-per-month or dollar figure is published yet. The measured REACT burn is still short of a window long enough to extrapolate, and a dollar figure needs a second REACT price source (`evidence/cost.json`: `usd: null`). `scripts/refresh-evidence.sh` recomputes it. Latency from the wall-clock observer is three samples (`docs/DX-REPORT.md` §8), too few to quote as a figure.
