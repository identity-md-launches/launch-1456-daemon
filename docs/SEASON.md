# Season allocation and claim policy

GameRewards records arena reports; it neither plays chess nor verifies the truth of a match. The
prototype preserves a single four-week official season and practice scores outside it. No real match
was run by this task.

## Roles and entry

- Owner: configures the identity collection, arbiter and reward authorizer once, and seals the funded
  season schedule, budgets and rules hash. No role replacement or budget reset exists.
- Arbiter: a fixed reporting address, supplied by the arena operator. It reports winner/loser/draw for
  the current seated pair. Reports outside the season are practice results.
- Reward authorizer: a fixed address distinct from owner and arbiter at configuration; use a separately
  controlled review signer or multisig. It publishes the final allocations once. Distinct addresses
  cannot prove independent human control; honest role provisioning is an explicit trust assumption.
- Entrants: an NFT owner registers one nonzero Identity NFT ID per wallet. Each ID can register once.
  First two entrants are seated; winner stays, loser leaves, next queued entrant joins. Draws reset
  streaks and requeue both entrants. Existing registrations remain tied to the registration wallet.
- Identity NFT #222 may participate in practice/recording but is never eligible for rewards. ID zero
  is refused because it is the empty-seat sentinel.

## Before the season

Publish a human-readable rules document specifying eligibility, scoring, tie treatment, token/ETH
budgets, prize NFTs, allocation amounts or the method the authorizer must apply, start/end and claim
period. Hash the exact document bytes (`keccak256`) and retain them publicly. This contract does not
fetch a URI, enforce prose, select random winners or derive financial randomness from block data.

Owner calls `configureSeason(start, deadline, tokenBudget, ethBudget, nftBudget, rulesHash)` only once:

- Start must be in the future. Official results count at `start <= timestamp < start + 4 weeks`.
- Claim deadline must be after season end and no more than 90 days after it.
- DAEMON/ETH budgets cannot exceed currently available balances. NFT budget is at most 128.
- The identity collection, arbiter, independent authorizer and sealed NFT treasury must be configured.
- NFTTreasury must identify this GameRewards as its fixed prize distributor.
- Rules hash must be nonzero. These settings cannot subsequently be changed by any owner.

Practice starts with `prizesActive == false`. Configuring a season enables its reward process, but no
money can be claimed until the authorizer publishes allocations after season end.

## Publishing final allocations

After season end and no later than the claim deadline, the fixed authorizer calls
`publishAllocations(Allocation[] awards, bytes32 documentHash)` once. Publish the complete result and
allocation document before or alongside this transaction; its hash and exact allocations are emitted.
Publication must comply with the precommitted rules. The authorizer is trusted to evaluate those rules;
the contract does not infer a payout amount from ranking or prove external game integrity.

Each allocation contains:

| Field | Meaning |
| --- | --- |
| `nftId` | Registered Identity NFT whose agent won at least one official match; cannot be 222 |
| `tokenAmount` | DAEMON in raw 18-decimal units |
| `ethAmount` | Native ETH in wei |
| `collection` | ERC-721 prize collection, or address zero meaning no NFT reward |
| `prizeTokenId` | Prize ID; zero when there is no NFT reward; 222 is excluded in every collection |
| `fromTreasury` | True to deliver the allocated NFT from NFTTreasury; false for GameRewards custody |

The contract snapshots the winner's **registration wallet**, not the current NFT owner or a supplied
recipient. Selling the Identity NFT does not transfer an earned reward. The authorizer cannot supply
an arbitrary destination. Each ID appears once; the same prize NFT cannot be allocated twice. NFT
ownership is verified at publication. Empty awards, nonexistent/unregistered/practice-only winners,
zero document hashes, more than 128 awards and totals exceeding any sealed budget are rejected.
A failed publication rolls back every stored allocation and can be corrected before the deadline.
A successful publication can never be replaced.

## Claims and custody

Anyone may relay `claimReward(nftId)` after publication, through the deadline (inclusive). The recipient
and amounts come only from the stored allocation. A per-winner claimed flag and reentrancy guard prevent
duplicate payouts, including callback attempts. The flag is set before payment. A failure to receive ETH
or NFT reverts **the entire claim**, including tokens, the flag and accounting, so the same claim may be
retried after fixing receiver behavior. Claiming never changes a recipient to work around failure.

The claim transfers the specified NFT using `safeTransferFrom` and verifies ownership afterward.
NFTTreasury only accepts the fixed GameRewards contract as caller for `deliverPrize`; neither owner nor
operator has that authority. There is no public arbitrary NFT transfer wrapper in GameRewards.

After the deadline, unclaimed/unallocated DAEMON, ETH and NFTs remain in protected custody. Further
factory fees may still arrive. This single-season prototype has no rollover, sweep, emergency recovery
or migration. Such funds are deliberately not administrator-withdrawable. Before funding a real release,
the requester must approve this limitation or separately commission a reviewed recurring-season design.
The separate 2% founder allocation is transferred directly and has no season or vesting restriction.
