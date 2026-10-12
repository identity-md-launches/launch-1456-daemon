# Verified IMD factory behavior

Inspection date: 2026-10-12. These are evidence addresses, not deployment configuration for DAEMON.
No public-network transaction or fork was executed.

## Provenance

The [official IMD contract table](https://imd.fun/docs) identifies Ethereum LaunchFactory
`0x12c63b581d07093f6126bc02263c58f7eadaa96f` and LaunchFees
`0x12c9e1007262afac205567457f5826a9416a3863`. Their verified source was downloaded directly from
Sourcify's v2 API, independently of the earlier prototype's assumptions:

- [LaunchFactory full record](https://sourcify.dev/server/v2/contract/1/0x12c63b581d07093f6126bc02263c58f7eadaa96f?fields=all):
  creation and runtime match; verified 2026-10-08T17:44:20Z; deployment block 26128678;
  transaction `0x1441cd85a00735eb68f4e4964bc07fa4b21b038e9e1d7dcab2b5efbd7f9178f3`.
- [LaunchFees full record](https://sourcify.dev/server/v2/contract/1/0x12c9e1007262afac205567457f5826a9416a3863?fields=all):
  creation and runtime match; verified 2026-10-12T08:49:26Z; deployment block 26128673;
  transaction `0xc7d5fff41fd980a45c0dfee497c22bfac31b6af223b895073f36159a59dda9b1`.
- Compiler: 0.8.26+commit.8a97fa7a, optimizer 200, Cancun, no via-IR, metadata bytecode hash none.
- The independently verified LaunchFees source is identical to the LaunchFactory compilation's
  LaunchFees dependency. Factory sources include its inherited `PoolFees`, which implements fee collection.

`factory-source.json` records original SHA-256 hashes, compiler and deployment records. `launch-fees-source.json`
records the independent LaunchFees match. `verified-sources.json` stores the original source contents so
checks need no network. `test/verified/` holds executable fixtures. The only adaptations are the
OpenZeppelin import prefix (`@openzeppelin/contracts/` → `./openzeppelin/`) and `forge fmt` formatting.
The 16 v4 interface/type/library files in that compilation match this repository's existing `lib/v4-core`
files byte-for-byte. `python3 scripts/verify_sources.py` verifies these claims offline.

The small required OpenZeppelin subset lives under `test/verified/openzeppelin/`, not the protected `lib/`
directory, and retains its MIT SPDX and license. None of these test fixtures is a replacement deployed
factory. Reverify the admitted chain's factory code, fee policy and launch position before any future use.
No network address is hardcoded into application constructors or tests.

## Allocation: what the factory actually does

Read `test/verified/LaunchFactory.sol`, `launch()` and `_seedRequesterPool()`:

1. Deploy token/hook atomically and require the factory holds the entire stated supply, with equal
   ERC-20 `totalSupply()`.
2. Send `totalSupply * SWARM_BPS / 10_000` to its MerkleDistributor. `SWARM_BPS` is fixed at **1000**.
3. Initialize and seed its own position. Measure actual token consumption around the seed.
4. Reject consumption above `totalSupply * poolBps / 10_000`. Reject paired-currency spending.
5. Transfer **all** residual tokens to `remainderTo` (or chain treasury when that parameter is zero).
6. Record a position with `requester` independently of `remainderTo`.

Thus `poolBps = 8300` sets an upper bound, not a forced exact 83% transfer. Underseeding sends MORE than
7% to the remainder receiver. The local acceptance test chooses tick range `[-10000, 0]`, initial
`sqrtPriceX96 = 2^96`, native ETH as currency0 and DAEMON as currency1. Let
`D = 2^96 - TickMath.getSqrtPriceAtTick(-10000)` and `T = 830_000_000e18`.
It uses `L = floor(T * 2^96 / D)`. Since `D < 2^96`, the pool's rounded-up token1 debit is exactly `T`.
The real factory consequently sends exactly 100M to the swarm and 70M to DistributionReceiver.

This price/range is a **local accounting fixture**, not a proposed launch valuation. Future launch
parameters must produce the intended exact seed or disclose and resolve rounding before launch.
Do not compensate with a burn, extra mint or principal withdrawal. The receiver does not control
factory seeding. Its split is immutable after setup: game=floor(balance*4/7), development=floor(balance/7),
founder=the remainder. At 70M tokens the allocations are exactly 40M/10M/20M. Arbitrary donations/partial
transfers conserve funds; at most two token-wei rounding dust per call goes to the founder.

## Fee route: supported ABI and required authorization

`PoolFees.Position.requester` is the fee share holder. The following verified functions exist:

```solidity
setRequester(uint64 launchNumber, address next)
claimFees(uint64 launchNumber) returns (uint256 amount0, uint256 amount1)
positionOf(uint64 launchNumber) returns (PoolKey key, int24 lower, int24 upper, address requester)
withdraw(address account, Currency currency)
owed(address account, Currency currency) returns (uint256)
```

The current nonzero `requester` alone may call `setRequester`. An owner of this application, factory
administrator, distribution receiver or keeper cannot do it for the payer. The next address must be
nonzero. This is a transfer of the whole share, not a percentage setting. There is no invented creator
recipient setter; LaunchFees' real `setFeeRecipient` changes only the network's recipient.

After the payer sets `requester = GameRewards`, permissionless `claimFees` sends every creator-share wei
of native ETH and token fees directly to GameRewards. Its keeper wrapper verifies that the configured
position is the DAEMON/native pair and GameRewards is already its requester. GameRewards offers no
external call or `setRequester` wrapper, so an administrator cannot later redirect the share.

`LaunchFees.REQUESTER_BPS()` is the constant 8000: creator receives `floor(collected * 8000 / 10000)` for
each currency; the network receives the residual. At a 12500 pool fee (1.25%), this nominally represents
1% and 0.25% of fee-bearing volume, respectively, subject to v4 integer rounding and trading mechanics.
The hook's separate ETH fee is not part of this split. `PoolFees._collect` uses `liquidityDelta: 0`,
collecting accrued fees without reducing principal. It refuses negative collection deltas.

## Existing fees, failed payments and automation limits

- Already-paid fees belong to the original payer. That wallet must manually transfer all such intended
  ETH and DAEMON fees to GameRewards. The application cannot seize its funds or prove completeness of
  historical offchain payments.
- Already-owed failed payouts remain keyed to the old account. After making that recipient able to
  accept payment, anyone may call `withdraw(oldAccount, currency)`; the recipient is fixed, so the
  caller cannot redirect the withdrawal. The old account must then forward it manually.
- A failed creator payout does not withhold the network share. Source tests cover failure, owed balances,
  reassignment, retry and duplicate-withdrawal prevention.
- A plain EOA payer cannot be made to auto-forward historical fees without its own authorization. No
  private key, signature, allowance or wallet automation is assumed or installed.
- A keeper can call public `claimFees` and hook `forwardFees` after configuration. Transactions still
  require an operator and gas; this code task starts no keeper and spends nothing.
- If a target factory lacks these verified interfaces or behavior, the automatic future-share route
  is unsupported until that chain's source is verified. Do not assume another factory version matches.

`FactoryIntegration.t.sol` executes the saved actual factory source against a real local PoolManager.
It proves fee assignment, both currencies' 80/20 split, separate hook ETH, exact allocation, unchanged
liquidity and old-payer behavior. This is stronger than a mock interface test but is **not** a live
fork, an onchain payer authorization or an executed production integration.
