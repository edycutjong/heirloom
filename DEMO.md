# Heirloom: demo and proof

Every row below is a real transaction on Reactive Lasna (5318007), Base Sepolia (84532) or Ethereum Sepolia (11155111), copied from [`evidence/triples.csv`](evidence/triples.csv), [`evidence/demo-actions.csv`](evidence/demo-actions.csv) and [`evidence/fresh-loop-runs.csv`](evidence/fresh-loop-runs.csv). Nothing here is simulated. Mainnet rows do not exist yet: the mainnet deploy is a separate step (`scripts/deploy-mainnet.sh`, dry-run only so far), so every claim on this page is a testnet claim.

**Which build.** The `demo` and `long-t` instances were deployed on 2026-11-08, before the re-entry lock, `coverDebt()` and the claim-grace fix. The `demo-head` instance ran the same lifecycle on 2026-11-22 from `201eb1e`, the current contract source (see [the same lifecycle at HEAD](#the-same-lifecycle-at-head-2026-11-22)); the `demo-revive` instance added a live REVIVE the same day (see [a live REVIVE](#a-live-revive-2026-11-22)). The rows prove the loop; the current contracts are what `forge test` runs and what mainnet deploys.

## The loop in one line

A watched wallet's token activity on an origin chain → a Reactive Network contract (`react()`) decides whether it counts as life → on silence it requests a callback → `HeirloomVault` on Base moves to GRACE, then CLAIMABLE, then pays the heir after a two-step claim. A **triple** is one origin or trigger tx, the reactive tx it caused on Lasna, and the callback tx it produced on Base.

## Instances

| Instance | Reactive contract (Lasna) | Vault (Base Sepolia) | T | Notes |
|---|---|---|---|---|
| demo | [`0xa3d92EAe…B8b`](https://lasna.reactscan.net/address/0xa3d92EAefb2fc4C972d6Ee524c24F38A93739B8b) | [`0x51365bb9…DBA`](https://sepolia.basescan.org/address/0x51365bb9560dDfA4236fd62d4eF2CB61f78edDBA) | 5 min | full scenario, torn down after the claim |
| demo-head (`201eb1e`, 2026-11-22) | [`0xe8812588…381F`](https://lasna.reactscan.net/address/0xe8812588c7bEa5E5c29004aebB04AC02abA2381F) | [`0x3d526a7D…0BEa`](https://sepolia.basescan.org/address/0x3d526a7DeB8d963F2e5A0AdaEde747A1Ce3a0BEa) | 5 min | full lifecycle at `HEAD`, released and torn down; see below |
| demo-revive (`2ef45d0`, 2026-11-22) | [`0x2dB4Ff1E…1768`](https://lasna.reactscan.net/address/0x2dB4Ff1E444D6f023A8bfe542517E1A598091768) | [`0x5320Aa92…cfe8`](https://sepolia.basescan.org/address/0x5320Aa92ad7635A828bF2A4FD3a111D2fAdfcfe8) | 5 min | expiry, then the owner came back: live REVIVE; then released and torn down; see below |
| long-t | [`0x80b56204…DC6`](https://lasna.reactscan.net/address/0x80b56204D8860a6B46c08deCd9F01DD1881F9DC6) | [`0x8C37E794…7Be`](https://sepolia.basescan.org/address/0x8C37E79420Cd16e46E4D9FFd4541a87FfFa4e7Be) | 90 days | armed since 2026-11-08 (UTC). It stalled in reactive-contract debt after its last logged event (2026-11-08 23:35 UTC): this build predates `coverDebt()`, and the 2026-11-15 top-ups were transfers, which do not clear debt. Revived on 2026-11-22 with the system contract's `depositTo` ([`0xe1c6ea97…c94a`](https://lasna.reactscan.net/tx/0xe1c6ea97590511041e9795f729bb1efc6f6a9b5bd07dd8ece81e5f023931c94a)): 9.0067 lREACT balance plus 0.9866 lREACT reserves at the revival, last heartbeat 2026-11-22 02:20 UTC (`evidence/status.json`). The one to fire a loop against |

Owner (every instance): `0x12bF8bbD1Eec23B5ab5A44B8d551bbC1d038651C`. Heir: `0x440E03bb3AAdBE65D5Bf2Ad7f84A64c509ff438b`.

## Triples

Callback stages (GRACE, CANCEL, EXPIRE, ATTEST, REVIVE) have all three legs. VISIT and REFUSED are reactive-only: the origin tx and the reactive tx that handled it. A CRON-triggered stage has the Lasna CRON tx in the "trigger" column.

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
| VISIT (2026-11-22, after the revival) | origin_log @ 84532 | [`0xd29c6509…0cc0`](https://sepolia.basescan.org/tx/0xd29c6509ddf88430200f8ddfc1dbdf5ad12e52fb7e477294e9195ebe8da20cc0) | [`0xddd26576…9a70`](https://lasna.reactscan.net/tx/0xddd265766c478bfe572902e5038b7a2e941b86956891646439b24beadeef9a70) |

**Live again on 2026-11-22:** after the revival, the long-T contract's next CRON tick sent its overdue weekly ATTEST: CRON [`0xb5efe19b…d124`](https://lasna.reactscan.net/tx/0xb5efe19b1f732eb58d82ca56bdfe395feb870d394996913dd63066f06987d124) → react [`0xf776b049…3500`](https://lasna.reactscan.net/tx/0xf776b049b86c6f59ee2ac63bbc578d43496cc944ee2b2e811f4e957ceea13500) → callback [`0x0d654fcd…855b`](https://sepolia.basescan.org/tx/0x0d654fcd69b0deda5039f67662502ab774c635ca5a6b7265ff332eec5d6a855b) (acknowledged; the vault paid about 0.0000012 ETH for it).

## The same lifecycle at `HEAD` (2026-11-22)

The `demo-head` instance was deployed on 2026-11-22 from commit `201eb1e`, the current contract source (re-entry lock, `coverDebt()`, the claim-grace fix and the claim solvency gate), with the same settings as the 11-08 demo (T = 5 min, grace 220 s, claim delay 450 s). `script/heirloom-scenario.sh` now fails the run unless the first heartbeat is `Seen` on Lasna; it was, about one second after the Ethereum Sepolia transfer. Reactive contract [`0xe8812588…381F`](https://lasna.reactscan.net/address/0xe8812588c7bEa5E5c29004aebB04AC02abA2381F), vault [`0x3d526a7D…0BEa`](https://sepolia.basescan.org/address/0x3d526a7DeB8d963F2e5A0AdaEde747A1Ce3a0BEa).

| Stage | Trigger | Trigger tx | Reactive tx (Lasna) | Callback tx (Base Sepolia) |
|---|---|---|---|---|
| VISIT | origin_log @ 84532 | [`0x4aca1bc2…78d5`](https://sepolia.basescan.org/tx/0x4aca1bc2d978674bab74c9de048dc3e21fe84a710c1c6cef68dc0b6ec9b978d5) | [`0xeecc9786…c6b6`](https://lasna.reactscan.net/tx/0xeecc97860f0b5f0e6ea43fdacd70c2a7e7cc17e0573ead13ab6023769d38c6b6) | — |
| VISIT | origin_log @ 84532 | [`0x4aca1bc2…78d5`](https://sepolia.basescan.org/tx/0x4aca1bc2d978674bab74c9de048dc3e21fe84a710c1c6cef68dc0b6ec9b978d5) | [`0xa4a40a0a…5edb`](https://lasna.reactscan.net/tx/0xa4a40a0a48b9608c047161d9bdbcb536de7242c5913461a8147cc2c326f45edb) | — |
| VISIT | origin_log @ 11155111 | [`0xb8b8d322…f870`](https://sepolia.etherscan.io/tx/0xb8b8d322e0ed0e74b744945007e8bb53b782a4ff55b35bc91f5e693fe3a1f870) | [`0xaa601523…1a4e`](https://lasna.reactscan.net/tx/0xaa601523763141756f97c76fef389d33aa370f5c022ffddb4e1086bcf4741a4e) | — |
| REFUSED | origin_log @ 84532 | [`0xe9b9693e…4bd9`](https://sepolia.basescan.org/tx/0xe9b9693ed731a9689c6bab2ec65ee863ca590ffaaa5f7241a5c069f7c30e4bd9) | [`0xd5420c22…cabc`](https://lasna.reactscan.net/tx/0xd5420c2258d9267e4c674349fe5e4b0ef1cd46fcb9086b4581ad728a1097cabc) | — |
| ATTEST | cron @ 5318007 | [`0x5b448b3f…6af9`](https://lasna.reactscan.net/tx/0x5b448b3ff0535f63548995213dfb251021932854d71989e4e0ac3237f3f66af9) | [`0x9a963bb7…097c`](https://lasna.reactscan.net/tx/0x9a963bb7b36fef36cac9fe34b071c3597afbbf866446903503cd5d6dc84a097c) | [`0xf47ed40b…2960`](https://sepolia.basescan.org/tx/0xf47ed40b82e1c058739e863bc44025d248e11e6f8bae2d7a9b035cb500402960) |
| GRACE | cron @ 5318007 | [`0xa6bac6a7…e4ac`](https://lasna.reactscan.net/tx/0xa6bac6a7a8d9b0b1ba0670f3f7087ecef593a970d5b9d4aac23466aa3126e4ac) | [`0x05117b9f…b381`](https://lasna.reactscan.net/tx/0x05117b9fc4047636a97b166716bec00efb4b19f3056e34484da1e6ff73e1b381) | [`0x884975d6…7861`](https://sepolia.basescan.org/tx/0x884975d6e9151e016e57d40eb901330628984a0b3692f827a805c769be787861) |
| CANCEL | origin_log @ 84532 | [`0xc5767890…970f`](https://sepolia.basescan.org/tx/0xc5767890327b0cae7bf6356b17de5f49494d26c5e685eca33311ab12627b970f) | [`0x680c0cc5…5ec9`](https://lasna.reactscan.net/tx/0x680c0cc555b8c560318db5d66eef551be65dfae04199d29310c67865aae65ec9) | [`0x40536ed4…2e50`](https://sepolia.basescan.org/tx/0x40536ed404473d29bb513b8889ddabb8c659602a5efb4143fb37112461372e50) |
| ATTEST | cron @ 5318007 | [`0x4e797a28…46ca`](https://lasna.reactscan.net/tx/0x4e797a2800511029c8974b3e9f7c620c4943bf050c4c904d4b7f2520950246ca) | [`0x2226832b…519b`](https://lasna.reactscan.net/tx/0x2226832bddd66e30d48791ac189809e936413e7ba12d3def25ceb0a86da2519b) | [`0xb46a06be…466a`](https://sepolia.basescan.org/tx/0xb46a06bea51196629f3f611b33d23540471dd096b04b5a82b30b3970a589466a) |
| GRACE | cron @ 5318007 | [`0xed38fcd5…e499`](https://lasna.reactscan.net/tx/0xed38fcd51b812cd3fbfed95037109965a24e73ad2c0b516e880ef79d2b8fe499) | [`0xfe78af6f…3911`](https://lasna.reactscan.net/tx/0xfe78af6f5e615fb51ac864f88eb3c6d357f1380e883973d9bb4167dac0e03911) | [`0x4d53977b…be02`](https://sepolia.basescan.org/tx/0x4d53977b810c4747d6f70c9824a1b99131dd58410c208f31491d2e2aee48be02) |
| ATTEST | cron @ 5318007 | [`0x6f4617f1…2fee`](https://lasna.reactscan.net/tx/0x6f4617f1fa9447bfae9b113351ed6407e9ac868ee90a40c5dcfb0f35d9502fee) | [`0xe4fcf10f…a239`](https://lasna.reactscan.net/tx/0xe4fcf10f8fc1041831dbe28e4c1e9e48019630033795138981421dad68baa239) | [`0xd8b44558…36ec`](https://sepolia.basescan.org/tx/0xd8b44558648c68aca06dc10ca4471e1070eb405cee12ae27e6f83f31bb0436ec) |
| EXPIRE | cron @ 5318007 | [`0x7b936e40…b24d`](https://lasna.reactscan.net/tx/0x7b936e40fddf48e552097db71263b9e24d65d1cb40ab6f5dadeecdffd6f7b24d) | [`0x0b64541a…a901`](https://lasna.reactscan.net/tx/0x0b64541a84c958bdc7b12d3344057407abb06ab2877303726e32eba6030fa901) | [`0xf0c5235b…a61d`](https://sepolia.basescan.org/tx/0xf0c5235bd87ce749bf0d49e1a20e238d96c709871dd418e25ec6f9bf5b47a61d) |
| ATTEST | cron @ 5318007 | [`0x5d363a8b…7b1a`](https://lasna.reactscan.net/tx/0x5d363a8b60276e100d0dcc1746864b6ff79455e2619290291994d37e040b7b1a) | [`0xf26781f2…62bf`](https://lasna.reactscan.net/tx/0xf26781f2860243f189364e762bae51085d32f725a866667331638be67c8262bf) | [`0xbd288794…28d9`](https://sepolia.basescan.org/tx/0xbd288794cef75abd98592c142daa79d8788b90ce6bb9370ec643dcf25faa28d9) |
| TEARDOWN | origin_log @ 84532 | [`0xdc714896…fb49`](https://sepolia.basescan.org/tx/0xdc714896e85fcae9b40f8ea4c29f197f320bcd77462331ff975fddaee5f9fb49) | [`0x95df1304…130d`](https://lasna.reactscan.net/tx/0x95df1304bea8b5fce1c81dadef30e2ab81c6326ca09f3924aa1c9ef6efc3130d) | — |

Claim: a third wallet that is neither owner nor heir (`0xc8cd…5395`) pressed `initiateClaim` [`0xa96dd12d…f79d`](https://sepolia.basescan.org/tx/0xa96dd12dcc21ccd1fbbd7ac1a31366dbb6b6221aa23e2db09cff4a0d0d88f79d), the heir's wallet pressed `finalizeClaim` [`0xdc714896…fb49`](https://sepolia.basescan.org/tx/0xdc714896e85fcae9b40f8ea4c29f197f320bcd77462331ff975fddaee5f9fb49), and the vault paid the heir. 8 of 8 callbacks acknowledged on the first try, 0 resends; the reactive contract then removed its own subscriptions (TEARDOWN row).

### Claim on the demo instance (Base Sepolia)

Anyone may press either step; on this 11-08 run both were pressed from the owner key, and the vault paid the heir (`0x440E…438b`). On the `demo-head` run above, a third wallet initiated and the heir's wallet finalized.

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

**REVIVE is in the evidence** since 2026-11-22: [`0x61f81227…ff26`](https://sepolia.etherscan.io/tx/0x61f8122782204b2731deeae60e6d45a107436e9bc66d9ed5fd295f357b37ff26) (Ethereum Sepolia) → [`0x51d7f47d…5118`](https://lasna.reactscan.net/tx/0x51d7f47d84404d2746332a0771aa14b90c11f615f80921f559f6b1fae73d5118) (Lasna) → [`0x5b295eca…6ad3`](https://sepolia.basescan.org/tx/0x5b295eca4f2db1f2c0696d8df9d5b58e95a64ef779eb293ec8596eaf7b666ad3) (Base Sepolia); see [a live REVIVE](#a-live-revive-2026-11-22). The CANCEL rows show the reactive path (an owner token transfer seen by `react()`); a vault owner action cancels synchronously on Base (`test_cancel_by_ping_in_grace`, `test_owner_withdraw_any_state`) and has no live triple.

## A live REVIVE (2026-11-22)

REVIVE is the fifth callback kind (`src/HeirloomTypes.sol`): the grace ran out and the vault is CLAIMABLE, but the owner moves a watched token before anyone completes a claim, so the reactive contract goes back to ARMED and tells the vault to re-arm. The `demo-revive` instance was deployed on 2026-11-22 from `2ef45d0` (same contract source as `201eb1e`) with the `demo-head` settings (T = 5 min, grace 220 s, claim delay 450 s) and run with `script/heirloom-scenario.sh` `STEP=setup`, `STEP=revive`, `STEP=expire`. Reactive contract [`0x2dB4Ff1E…1768`](https://lasna.reactscan.net/address/0x2dB4Ff1E444D6f023A8bfe542517E1A598091768), vault [`0x5320Aa92…cfe8`](https://sepolia.basescan.org/address/0x5320Aa92ad7635A828bF2A4FD3a111D2fAdfcfe8). Actions: [`evidence/demo-revive-actions.csv`](evidence/demo-revive-actions.csv).

The REVIVE triple: the owner's token transfer on Ethereum Sepolia [`0x61f81227…ff26`](https://sepolia.etherscan.io/tx/0x61f8122782204b2731deeae60e6d45a107436e9bc66d9ed5fd295f357b37ff26) → `react()` on Lasna [`0x51d7f47d…5118`](https://lasna.reactscan.net/tx/0x51d7f47d84404d2746332a0771aa14b90c11f615f80921f559f6b1fae73d5118) → `sync` on Base Sepolia [`0x5b295eca…6ad3`](https://sepolia.basescan.org/tx/0x5b295eca4f2db1f2c0696d8df9d5b58e95a64ef779eb293ec8596eaf7b666ad3) (vault CLAIMABLE → ARMED). The EXPIRE before it ([`0x30e9db26…719b`](https://sepolia.basescan.org/tx/0x30e9db26e263d24c7e22e9895fdfa424e081f3f2c85328cc9be0955d1d31719b)) had made the vault CLAIMABLE; nobody pressed `initiateClaim`. Block times: reactive tx 0 s after the origin block, callback 1 s after the reactive tx (04:56:48 → 04:56:49 UTC).

| Stage | Trigger | Trigger tx | Reactive tx (Lasna) | Callback tx (Base Sepolia) |
|---|---|---|---|---|
| VISIT | origin_log @ 84532 | [`0x4930a282…a633`](https://sepolia.basescan.org/tx/0x4930a28254a3fb088653c9d1e0aa27916e3b9606275a348c930dd2fb60e0a633) | [`0x3e6bc0a5…8b18`](https://lasna.reactscan.net/tx/0x3e6bc0a533f11fee883d65b6a5bed2c8b0af37dd85c25c56f3fd01e945888b18) | — |
| VISIT | origin_log @ 84532 | [`0x4930a282…a633`](https://sepolia.basescan.org/tx/0x4930a28254a3fb088653c9d1e0aa27916e3b9606275a348c930dd2fb60e0a633) | [`0x80e72a44…9a35`](https://lasna.reactscan.net/tx/0x80e72a44883f39f5f74e8da062e93033495c5c772d994fcbf4310e4308a29a35) | — |
| VISIT | origin_log @ 11155111 | [`0x16998950…b6eb`](https://sepolia.etherscan.io/tx/0x1699895013b81917d247afa76801d4d1507ac0f111590bd109c9143b1f46b6eb) | [`0xc16ec2bc…541c`](https://lasna.reactscan.net/tx/0xc16ec2bcdc2d9278a9350c9fcf83173d65d600c911bf7445454191f53bcd541c) | — |
| REFUSED | origin_log @ 84532 | [`0x8e0ddbb4…9b81`](https://sepolia.basescan.org/tx/0x8e0ddbb4fdb4356d483bbeb2bb36a49f05cff5303d85a0b7ed18da7ebe649b81) | [`0x84ab122b…51de`](https://lasna.reactscan.net/tx/0x84ab122bb4e4dbe8b5710bc74528d8d9cce237da368d0c9c86897f28b73151de) | — |
| GRACE | cron @ 5318007 | [`0x381c8bb9…29dd`](https://lasna.reactscan.net/tx/0x381c8bb95695da7d473f64b737c65b42feccc862a8a4c4c40674c372687529dd) | [`0x4f0ce0bd…131c`](https://lasna.reactscan.net/tx/0x4f0ce0bda83c1ea940ad98c6adb60b7a0500c6a6b858d6260111a037e475131c) | [`0x70e75d23…2b7d`](https://sepolia.basescan.org/tx/0x70e75d231829171a74043a4710cef7a29f2f7c2eaf5257ae9f22262f5f612b7d) |
| EXPIRE | cron @ 5318007 | [`0x3c4b5aac…c49f`](https://lasna.reactscan.net/tx/0x3c4b5aaca213782df7cb399bbbe8ccb505b9c5c9432ddd3920aa9fd3ea96c49f) | [`0x52702338…38ee`](https://lasna.reactscan.net/tx/0x52702338430978b31ebe323b11896c98c868b7e5c0aa1250fba8f869fa9438ee) | [`0x30e9db26…719b`](https://sepolia.basescan.org/tx/0x30e9db26e263d24c7e22e9895fdfa424e081f3f2c85328cc9be0955d1d31719b) |
| **REVIVE** | origin_log @ 11155111 | [`0x61f81227…ff26`](https://sepolia.etherscan.io/tx/0x61f8122782204b2731deeae60e6d45a107436e9bc66d9ed5fd295f357b37ff26) | [`0x51d7f47d…5118`](https://lasna.reactscan.net/tx/0x51d7f47d84404d2746332a0771aa14b90c11f615f80921f559f6b1fae73d5118) | [`0x5b295eca…6ad3`](https://sepolia.basescan.org/tx/0x5b295eca4f2db1f2c0696d8df9d5b58e95a64ef779eb293ec8596eaf7b666ad3) |
| GRACE | cron @ 5318007 | [`0xdfd4d24f…6028`](https://lasna.reactscan.net/tx/0xdfd4d24f31e100d0771578c06545afcb635689c005696d40148e037843046028) | [`0x8218ca22…ef87`](https://lasna.reactscan.net/tx/0x8218ca221010ae716c245d702313c1d53e1c23bc8427b2c1ceccaab697deef87) | [`0x8d2b2ddc…1e9c`](https://sepolia.basescan.org/tx/0x8d2b2ddcd237a8d0443b0ce4e01a81b26c8547d516dac9206d14dda435a51e9c) |
| EXPIRE | cron @ 5318007 | [`0x2a427bc9…bd53`](https://lasna.reactscan.net/tx/0x2a427bc996013822611c0195d81ce7826167e67ba25a3cf2fd9a1710dab4bd53) | [`0x70541848…8bcc`](https://lasna.reactscan.net/tx/0x70541848378ca7a25775d6c96f96d8838d7b2fa9f579845744c0e14fe42b8bcc) | [`0xdd2ea68a…6b31`](https://sepolia.basescan.org/tx/0xdd2ea68abb05da6060bc1e16c62003f8cc1db8c77f615a8818a9bf96c3246b31) |
| ATTEST | cron @ 5318007 | [`0x170675a1…7da1`](https://lasna.reactscan.net/tx/0x170675a120b634ef3cada4730796818b93d4c655cecacaff63b1b9dbc30e7da1) | [`0x56356920…bce7`](https://lasna.reactscan.net/tx/0x56356920738b96871e00d55defc5a9308c0cf73fb41a3cbf19fb82000f75bce7) | [`0xad5dec51…9aef`](https://sepolia.basescan.org/tx/0xad5dec513a529ef427c667ed625f2ef55e7c3869a705d24589954892ecd29aef) |
| TEARDOWN | origin_log @ 84532 | [`0xea174823…1494`](https://sepolia.basescan.org/tx/0xea1748232659e868f0125fd49b2c326306d12156c62317d8527258ebad301494) | [`0xa7394105…a591`](https://lasna.reactscan.net/tx/0xa73941055e87e653029130c61b9462a4f9180b7bc7020bdea8c7a72ffb75a591) | — |

Then the instance went silent again and ended the way `demo-head` did: a third wallet (`0xc8cd…5395`) pressed `initiateClaim` [`0x6dfeae07…10eb`](https://sepolia.basescan.org/tx/0x6dfeae07d565b5d1da46ddd1a0acf5657fcf1a569d049758e9c62ed024ba10eb), the heir's wallet pressed `finalizeClaim` [`0xea174823…1494`](https://sepolia.basescan.org/tx/0xea1748232659e868f0125fd49b2c326306d12156c62317d8527258ebad301494), the vault paid the heir, and the reactive contract removed its own subscriptions (TEARDOWN row). 6 of 6 callbacks acknowledged on the first try, 0 resends (`evidence/demo-revive-summary.json`).

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
forge test                       # Ran 10 test suites: 169 tests passed, 0 failed, 0 skipped
FOUNDRY_PROFILE=kit forge test   # Ran 5 test suites: 27 tests passed, 0 failed, 0 skipped
pnpm test:ts                     # Test Files 2 passed, Tests 27 passed
```

Those are the counts at the latest test update (2026-11-22 UTC); the first version of this page (2026-11-08) ran 104, 23 and 6.

## Cost and latency

No cost-per-month or dollar figure is published yet. The measured REACT burn is still short of a window long enough to extrapolate, and a dollar figure needs a second REACT price source (`evidence/cost.json`: `usd: null`). `scripts/refresh-evidence.sh` recomputes it. Latency from the wall-clock observer is three samples (`docs/DX-REPORT.md` §8), too few to quote as a figure.
