# Security assumptions and delivery checklist

This is test-only code, not an audited or deployed system. No independent contributor security review,
Slither, Mythril, live fork or public-network rehearsal was performed in this assignment. Local tests
include adversarial callers and callbacks; they are not an independent audit.

## Asset boundaries

- DAEMON remains the original plain 18-decimal ERC-20 with a single 1 billion constructor mint. No
  additional mint, burn, pause, upgrade or transfer-tax mechanism was added. Local test deployments do
  not replace a live token.
- Pool liquidity belongs to the actual factory. Application contracts have no liquidity-removal path.
  Verified factory fee collection uses a zero liquidity change. Hook claim mint/burn concerns native
  ETH ERC-6909 accounting, not DAEMON supply or LP principal.
- Hook fees belong exclusively to the once-configured NFTTreasury. No owner fee amount/recipient changes
  after initial setup. Anyone can forward; a rejecting treasury retains claims and does not block swaps.
- NFTTreasury has only bounded purchases and fixed-distributor NFT prize deliveries as spending paths.
  GameRewards has only published season claims as spending paths. Neither has token/ETH/NFT sweeps,
  general external calls, delegatecalls, owner-selected claim recipients or emergency withdrawal powers.
- DistributionReceiver's one-time recipients are separate from treasury restrictions. Founder funds
  transfer immediately and can be spent normally, with no vesting or cliff.

## Trusted setup and external contracts

Initial setup remains trusted. The requester must review all one-time address bindings and seal the
purchase policy before funding. A contract cannot decide which treasury, venue, collection, signer or
wallet the requester intended. Code presence checks are not an audit of that code. In particular, an
initially chosen malicious game contract or lying NFT collection defeats any custody policy that trusts
it. This is a setup risk, not an ongoing administrator recipient-change feature.

Only immutable, reviewed marketplace adapters and genuine collections/payment tokens should be
allowlisted. A proxy administrator of an external venue or collection could change behavior behind a
frozen allowlist; the application cannot protect against such external upgrades. A vetted venue must
implement the documented `buy(collection, tokenId, paymentToken, maxPrice)` interface, deliver to its
caller, honor native refunds and not rely on standing approvals. A generic Seaport address will not
work without an independently reviewed adapter. No such real venue is assumed configured by this task.

Payment tokens must have honest `balanceOf`/allowance behavior and stable balances. Fee-on-transfer,
rebasing, callback-heavy or upgradeable tokens are outside the approved payment model. Native ETH and
plain DAEMON are the tested core assets. ERC-20 exact temporary approvals use the existing Solmate
SafeTransferLib, with zero reset before approval and clearing afterward. The per-purchase maximum also
bounds native call value; net actual spend consumes independent per-asset rolling 24-hour and lifetime
caps. These are fixed-length windows, not a continuously sliding trailing-day sum; two budgets can be
spent across a window boundary. Limits are denominated in each asset's raw units, not USD.

The owner may replace buying operators, pause/unpause purchases, and disable venues, collections or
payments. It cannot add/re-enable entries, raise caps, reset spend, change the manager/distributor, or
remove assets after sealing. Ownership transfer does not relax these checks. The owner can censor
purchases; loss of operator keys can be repaired without granting withdrawal powers. Permanent disable
and lifetime-cap exhaustion have no administrative reset.

The configured PoolManager must be the actual manager used by the hook. Its lock state prevents
purchases during any of its unlock callbacks. Swaps themselves only create fee claims and never call
the purchase path. A keeper forwards fees afterward. Hook forwarding requires the manager to be locked.

## Rewards and operational liveness

The arbiter and independent allocation authorizer are trusted for truthful results and compliance with
the publicly committed rules. The contract enforces winner eligibility, one-time allocation, fixed
recipient, fixed aggregate budget and fixed time bounds. It does not prove chess results, human
independence of signers or prose-based rankings. Role addresses are one-time; an owner cannot replace
them or modify a sealed season. Losing either role key may strand that season's rewards. There is no
emergency backdoor to recover them. Registration-wallet snapshots survive identity NFT transfers.

This release intentionally has one season, at most 128 final allocations, and one NFT per allocation.
Claim deadlines, non-receiving winner contracts, changed NFT transfer rules and permanent policy locks
can strand assets. Rejected claims roll back atomically and can retry only within the original deadline.
Unclaimed funds, unsolicited assets and NFT #222 have no emergency recovery. A subsequent recurring
season or migration would need a separate reviewed design; existing GameRewards cannot hand its
assigned factory fee share elsewhere. These limitations must be approved before any funded release.

The only normal future creator-fee route is the actual payer's `setRequester` authorization. Manual
forwarding of historical funds requires that payer. Read-only source verification and local factory
execution do not constitute that authorization. Application owner setters never substitute for it.

## Fee and numeric assumptions

ETH fee = floor(base/100). Specified ETH uses the requested amount; unspecified ETH uses the actual
pool delta. Exact ETH output uses the requested net-output base. Sub-100-wei amounts round to zero and
splitting trades can reduce rounding fees. Specified-ETH partial fills revert; routers must account for
this. The bound on specified amounts ensures `requested + fee` fits int128. The most negative int256
is explicitly rejected before negation. Unspecified int128 magnitudes are promoted before negation.
Pool key and manager authentication are checked in each implemented swap callback.

The factory's `poolBps` is only a maximum; exact seeding is a release invariant to check independently.
Receiver rounding conserves tokens and sends up to two wei per partial distribution to the founder.
Actual factory fees use an independently fixed 80/20 split; neither treasury nor hook alters it.

## Completed / open / excluded checklist

| Item | Status and evidence |
| --- | --- |
| Fixed 1% ETH hook fee on buys/sells | Complete; four real swap modes, rounding and fuzz tests |
| Both currency orderings | Complete for callback math; reverse native key explicitly rejected by real v4 |
| Settlement and ETH forwarding | Complete; empty-manager token-only seed, insufficient settlement, rejecting recipient, all-fees transfer |
| Partial-fill accounting | Complete; specified ETH reverts, unspecified ETH uses actual fill |
| 1 billion and 100% allocation | Complete; actual factory source launch and 83/10/7 then 4/1/2 balances |
| Founder unlocked | Complete; immediate full founder transfer regression |
| Verified creator fee mechanism | Complete in source/local integration; actual payer authorization required for use |
| Separate factory/hook fees, principal retained | Complete; both currencies split 80/20, hook claims untouched, liquidity unchanged |
| Protected purchases | Complete; sealed allowlists, asset-specific caps, deadlines, exact approvals, verified new delivery, manager lock |
| Protected treasury withdrawals | Complete; removed selectors fail for owner and stranger; fixed recipient/role bindings |
| Season allocations and duplicate claims | Complete; budgets, publication deadline, one-time allocations, snapshot wallets, duplicate rejection |
| NFT prize transfer authority and #222 | Complete; GameRewards claim path only, winner and prize exclusions |
| Reentrancy and failed payout rollback | Complete; marketplace and reward callback attacks, ETH/NFT rejection and retry |
| Updated ABIs and reproducible results | Complete; `scripts/export_abis.py --check`, validation logs |
| Offline factory source provenance | Complete; saved Sourcify matches and `scripts/verify_sources.py` |
| Specific live owner/roles/venues/caps/chain | Unset by design; owner-settable configuration and release checklist in README |
| Payer assignment, historical manual forwarding, keeper operation | Not executed; external operational responsibilities |
| Independent security review, real venue integration, live/fork rehearsal | Open before funded use; not claimed complete |
| Recurring seasons, emergency recovery/migration | Unsupported; explicit protected-custody limitation |
| Real agent match, final share cards, website integration | Outside this contract task; not performed |
| Deployment/token launch/real spending/site changes | Outside authorized scope; not performed |

No requester-only input prevents this code deliverable: all unspecified settings have explicit,
event-emitting owner configuration and fail closed while unset. There is no blocked task file and no
claim that configuration is ready for production. No values were filled with stand-in recipients.
