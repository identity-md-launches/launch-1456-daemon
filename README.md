# DAEMON prototype — TEST ONLY

This correction implements a fixed **1% native ETH hook fee**, protected NFT custody and season rewards,
and the verified IMD payer-fee assignment path. This is source and local test work only. No contracts were
deployed, no token was launched/replaced/re-minted, no real funds were spent, and https://imdfamily.com was
not modified. No real agent match, final share cards, website integration or live fee assignment is claimed.

## Deliverables and checks

| Path | Purpose |
| --- | --- |
| `src/DaemonHook.sol` | Native ETH fee accounting, ERC-6909 settlement and permissionless forwarding |
| `src/NFTTreasury.sol` | ETH/ERC-20 NFT purchases under a sealed policy; no general withdrawals |
| `src/GameRewards.sol` | Existing arena ladder, fixed season budgets, published allocations and one-time claims |
| `src/DistributionReceiver.sol` | Immutable-after-setup 4:1:2 split of the 7% remainder |
| `src/DaemonToken.sol` | Unchanged fixed 1 billion supply, 18 decimals; no additional mint/burn interface |
| `src/ICreatorFeeFactory.sol` | Verified factory fee interface, including `setRequester` |
| `test/FactoryIntegration.t.sol` | Actual verified factory logic exercised with a local v4 PoolManager |
| `test/verified/` | Offline factory and required OpenZeppelin source fixtures, as ordinary files |
| `abi/` | Regenerated contract ABIs; removed withdrawal/award methods are absent |
| `docs/FACTORY.md` | Source provenance, exact allocation evidence and payer responsibilities |
| `docs/SECURITY.md` | Threat model, operational limits and completed/open checklist |
| `docs/SEASON.md` | Eligibility, rules commitment, authorizer responsibilities and claim lifecycle |
| `docs/validation/` | Reproducible command results from this delivery |

Use the repository's unchanged configuration: **solc 0.8.26**, Cancun, optimizer 200, no via-IR, no FFI,
no filesystem cheatcodes. Dependencies needed by the tests are all present as ordinary files. The
existing protected configuration, remappings and `lib/` were not edited.

```sh
forge build
forge test
forge fmt --check
python3 scripts/verify_sources.py
python3 scripts/export_abis.py --check
```

The tests use explicit local fixtures, without environment reads, RPC access, mainnet forks, private keys
or external services. See `docs/validation/RESULTS.md` for exact counts and additional checks.

## Hook ETH fee

Only the factory may initialize the single DAEMON/native-ETH pool. Other pairs are rejected. The hook's
address must carry flags **8396 / 0x20cc**: beforeInitialize, beforeSwap, afterSwap, beforeSwapReturnDelta,
afterSwapReturnDelta. It has no liquidity callbacks, upgrades, adjustable fee or trader exemption.

The integer fee is `floor(ETH base / 100)` wei. The base is the user-specified ETH amount when ETH is
specified; otherwise it is the actual ETH pool delta before the hook charge. It is assessed once:

| Trade | ETH base | Fee behavior |
| --- | --- | --- |
| Buy, exact ETH input `X` | `X` | Trader pays exactly `X`; the pool receives `X - floor(X/100)` |
| Buy, exact DAEMON output | Actual ETH input required by pool | Trader pays pool input plus `floor(input/100)` |
| Sell, exact DAEMON input | Actual ETH output produced by pool | Trader receives pool output minus `floor(output/100)` |
| Sell, exact ETH output `Y` | `Y` | Pool produces `Y + floor(Y/100)`; trader receives exactly `Y` |

For exact ETH output the 1% is based on the requested net amount, not a gross-up calculation. All rounding
is down; ETH bases below 100 wei have zero fee. DAEMON is never charged by this hook. The factory LP fee
is independent and may also be charged by the pool on its input currency.

Specified-ETH trades must fill completely or revert, including their fee claims. This avoids charging
1% of an unfilled request at a price limit. Unspecified-ETH partial fills charge only the actual ETH delta.
Routers must account for the net hook amounts, slippage and this full-fill restriction.

The hook mints **ETH-denominated ERC-6909 claims**, not DAEMON, within the PoolManager callback. The
positive fee delta offsets the claim mint, so swaps settle even when a token-only seed initially holds
no ETH. `forwardFees()` is permissionless: outside swaps it unlocks the manager, burns the claims and
sends every collected wei to NFTTreasury. Treasury setup is one-time; fees can accrue before setup. A
failed ETH transfer reverts the forwarding transaction and retains the claims without stopping swaps.
No pool position is reduced. Swaps never buy NFTs.

Native ETH is currency address zero and always sorts first in real Uniswap v4 pools. Tests cover all four
real swap modes, settlement and both directions, explicitly reject reversed native keys in the real
manager, and cover all eight order/direction/mode combinations in a labeled synthetic callback harness.
There is no claim that an ETH-as-currency1 pool can be initialized in real v4. WETH is not silently treated
as native ETH.

## Allocation and LP creator fees

| Allocation | DAEMON | Percent |
| --- | ---: | ---: |
| Factory-owned pool liquidity | 830,000,000 | 83% |
| Fixed IMD swarm distributor | 100,000,000 | 10% |
| GameRewards | 40,000,000 | 4% |
| Development | 10,000,000 | 1% |
| Founder, immediately unlocked | 20,000,000 | 2% |
| Total | 1,000,000,000 | 100% |

The actual factory sends `supply - swarm - actual seed consumption` to `remainderTo`; setting `poolBps`
alone is not proof of exact seeding. The local integration executes its real `launch()` with an exact
830M token seed, proves a 70M remainder reaches DistributionReceiver, and verifies the 4:1:2 split. A
future launch must independently verify its own seed parameters and balance changes. The factory always
reserves 10% for the swarm. No application here can withdraw its pool principal.

**Supported creator-fee route:** the current payer/share holder calls
`factory.setRequester(launchNumber, gameRewards)`. Anyone then calls `factory.claimFees(launchNumber)`
or, after configuration, `gameRewards.collectCreatorFees()`. The verified source sends the entire
creator share (80% of actual LP fees in each currency) directly to GameRewards; the other 20% goes to
the network. GameRewards cannot reassign that share. `remainderTo` has no effect on fee recipients.
Already-paid or already-owed payer fees require the original payer's manual forwarding; assignment
cannot seize them. See `docs/FACTORY.md` for exact evidence and recovery behavior.

## Protected treasury and reward operations

NFTTreasury accepts native ETH and tokens. Before purchases, its owner configures vetted marketplace
adapters, NFT collections, payment assets and per-asset per-purchase, 24-hour-window and lifetime caps,
then calls `sealPolicy(gameRewards, poolManager)`. The sealed policy cannot be broadened or its recipient
changed, even after ownership transfer. Operators can be changed, but every operator and the owner
obey identical purchase checks. Administrators can pause purchases or permanently disable allowlist
entries. The initial configuration must be reviewed **before funding**.

Purchases have an explicit deadline (at most one day ahead), use a fixed marketplace interface, fix NFT
delivery to the treasury, reject already-owned NFTs, check actual delivery, and bound spending. ERC-20
allowances are reset to zero, set to exactly the purchase ceiling and cleared after use. ETH purchases
send only the ceiling; refunds count against actual spend. The configured manager must be locked during
purchases. No arbitrary calldata, approvals, recipient argument, sweep, general transfer or emergency
recovery function exists. NFT #222 cannot be purchased or paid as a prize.

GameRewards accepts fees and the 4% allocation. It makes no purchases. Only documented, capped rewards
from its one configured four-week season can leave: DAEMON, ETH and individually allocated ERC-721 prizes.
Its fixed authorizer publishes allocations after the season, and claims pay each winner's registered
wallet once. NFT prizes can be held by GameRewards or drawn from the fixed NFTTreasury. The treasury
accepts prize-transfer instructions only from GameRewards' claim path. Identity NFT #222 is excluded
as a winner too. The separate founder token allocation is unaffected.

This prototype retains **one season per GameRewards instance**. Budgets and recipients cannot be reset
for a second season. Expired/unallocated funds and future fees stay protected in custody. Recurring
seasons, emergency migration and release of such funds would require a separately specified and reviewed
contract change; this task does not install an administrative escape path.

## Deployment parameters and after-launch responsibilities

No `launch.json` is written and no broadcast was run. `script/Deploy.s.sol` is a local rehearsal helper;
its broadcast entry point refuses chains other than local chain ID 31337. The tests call `deploy(Config)`
directly. It is not the production factory launch implementation; factory integration is tested separately.

All application constructors avoid external calls and accept at most four arguments:

| Contract | Constructor values |
| --- | --- |
| `DaemonToken` | None; original one-time supply goes to its deployer/factory |
| `DaemonHook` | Target-chain PoolManager, requester owner, actual launch factory, DAEMON token |
| `NFTTreasury`, `GameRewards`, `DistributionReceiver` | DAEMON token, requester owner |

No launch chain or owner/recipient/marketplace values were invented. The launch operator must use the
admitted chain's records, the requester's confirmed addresses and reviewed marketplace interfaces.
Unset application settings fail closed and remain configurable through the following explicit steps:

1. Owner: `hook.setTreasury(nftTreasury)` once; verify the protected contract and chain first.
2. Owner: `receiver.setRecipients(gameRewards, development, founder)` once, using the requester's wallets.
   Anyone calls `distribute()` after the actual 7% remainder arrives. Verify balances and total supply.
3. Owner: configure treasury allowlists and asset caps from the approved purchasing policy, optionally
   `setOperator`, then `sealPolicy(gameRewards, poolManager)`. Review the marketplace adapter's immutable
   code and the collection; the generic `buy` interface is not a Seaport integration.
4. Owner: `game.setIdentityNft` from verified collection records; `setArbiter` from the arena operator;
   `setRewardAuthority(independentAuthorizer, nftTreasury)` from the requester. Each is one-time.
5. Payer/share holder: verify `factory.positionOf(launchNumber)`, then call the actual factory's
   `setRequester(launchNumber, gameRewards)`. No administrator or keeper can substitute for the payer.
   Owner: `game.setFeeSource(factory, launchNumber)` once. Keepers may collect and forward fees periodically;
   this code does not run a keeper or automate a wallet signature.
6. Owner: after funding and public rule approval, `configureSeason(start, claimDeadline, tokenBudget,
   ethBudget, nftBudget, rulesHash)`. Start must be in the future. See `docs/SEASON.md` for all bounds.
7. Fixed arbiter reports results. Fixed reward authorizer publishes the final documented allocation once
   after the season. Anyone relays `claimReward(nftId)` before the deadline; no caller selects a recipient.

The caller owner is explicit, never implicitly the factory or `tx.origin`. Production deployment,
wallet authorization, review of policies/venues, keeper operation and a real arena connection remain
outside this code-only assignment.
