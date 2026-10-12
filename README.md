# DAEMON — Uniswap v4 hook and treasury prototype (TEST ONLY)

Test-only prototype for the DAEMON launch on https://imdfamily.com. Nothing here was deployed to any
network, no token was launched, no funds were spent, nothing was posted to X and no hackathon entry
was submitted. The existing website was not modified: this repository contains only Solidity, tests,
ABIs and documentation.

## What is delivered

| Path | Contents |
| --- | --- |
| `src/DaemonToken.sol` | `contract DaemonToken`: ERC-20 "DAEMON"/"DAEMON", 18 decimals, 1,000,000,000 supply minted once to the deployer. No mint, burn, owner, pause or proxy. |
| `src/DaemonHook.sol` | `contract DaemonHook`: the v4 hook. Fixed 1% fee on the DAEMON leg of every buy and sell, settled as ERC-6909 claims inside the swap, forwarded to the NFT treasury by `forwardFees()`. |
| `src/NFTTreasury.sol` | `contract NFTTreasury`: receives the fees and buys NFTs outside swap callbacks with allowlists, caps and an ownership check. |
| `src/DistributionReceiver.sol` | `contract DistributionReceiver`: splits the 7% remainder 4 : 1 : 2 into game rewards, development and founder (unlocked). |
| `src/GameRewards.sol` | `contract GameRewards`: game prize pool, on-chain "winner stays" ladder record, founder NFT #222 excluded, prizes inactive, four-week official season. |
| `src/HookFlags.sol` | Permission-bit helpers shared by tests and the deploy script. |
| `script/Deploy.s.sol` | Rehearsal deployment with an explicit `Config` struct (tested directly, no environment reads). |
| `test/` | 66 tests: fee accounting in both token orders, exact-input/output, native-pair token-only seeding, permissions, unauthorized access, treasury guard rails, distribution, ladder and prizes. |
| `abi/` | ABI JSON for every contract. |
| `lib/` | Vendored `forge-std`, `v4-core`, `solmate` as plain files (no submodules). |

Checks run locally with solc 0.8.26 pinned in `foundry.toml`:

```
forge build            # ok
forge test             # 66 passed, 0 failed
forge fmt --check      # ok
```

The pinned IMD floor tests (`Hook.protected.t.sol`, `Token.protected.t.sol`) were also run in a scratch
directory with the verifier's environment (`IMD_HOOK_CREATION_CODE`, `IMD_HOOK_FLAGS=8396`,
`IMD_POOL_MANAGER`, `IMD_TOKEN_PROBE`, `IMD_FACTORY_PROBE`, fee 12500, spacing 100): 11 passed.

## Hook design

### Configuration record (OpenZeppelin Wizard shape)

```json
{
  "hook": "BaseHook",
  "name": "DaemonHook",
  "pausable": false,
  "currencySettler": false,
  "safeCast": false,
  "transientStorage": false,
  "shares": { "options": false },
  "permissions": {
    "beforeInitialize": true,
    "afterInitialize": false,
    "beforeAddLiquidity": false,
    "beforeRemoveLiquidity": false,
    "afterAddLiquidity": false,
    "afterRemoveLiquidity": false,
    "beforeSwap": true,
    "afterSwap": true,
    "beforeDonate": false,
    "afterDonate": false,
    "beforeSwapReturnDelta": true,
    "afterSwapReturnDelta": true,
    "afterAddLiquidityReturnDelta": false,
    "afterRemoveLiquidityReturnDelta": false
  },
  "inputs": {},
  "access": "ownable",
  "info": { "license": "MIT" }
}
```

The hook is written against v4-core directly (no v4-periphery / uniswap-hooks dependency); it inherits
`IHooks` and `IUnlockCallback`, validates its own address bits in the constructor with
`Hooks.validateHookPermissions`, and uses a two-step owner. Address flags: `0x20CC` (8396).

### Fee mechanics

The fee is 1% (`FEE_BPS = 100`) of the DAEMON leg. "IMD side" in the brief is read as the DAEMON token
side; the paired currency (ETH) is never charged. The LP fee of the pool (the launch tier, 12500) is a
separate PoolManager mechanism and is untouched (`test_lpFeeAccruesToLiquidityIndependently`).

| Swap | DAEMON is | Callback | What happens |
| --- | --- | --- | --- |
| Buy, exact input (ETH in) | unspecified | `afterSwap` | 1% of the DAEMON the pool produced is kept; the trader receives 99%. |
| Buy, exact output (X DAEMON out) | specified | `beforeSwap` | The pool delivers X + 1%·X; the trader gets exactly X and pays ETH for X + 1%·X. |
| Sell, exact input (X DAEMON in) | specified | `beforeSwap` | The pool receives X − 1%·X; the trader pays exactly X. |
| Sell, exact output (Y ETH out) | unspecified | `afterSwap` | The trader pays 1% more DAEMON than the pool demanded. |

Settlement: the hook's positive fee delta is netted by `poolManager.mint(hook, daemonId, fee)` inside
the callback, so no PoolManager balance is needed and no transfer happens during a swap. A pool seeded
with tokens only on a fresh manager that holds no ETH trades normally
(`test_nativePairTokenOnlySeedBuyAndSell`). `forwardFees()` may be called by anyone, outside any swap: it
unlocks the manager, burns the claims and `take`s the DAEMON to the treasury. If the treasury is not yet
configured the call reverts with `TreasuryNotConfigured` and fees keep accruing as claims; a swap can
never be halted by the recipient. The treasury receives ERC-20 DAEMON, so "recipient cannot receive ETH"
does not apply; a treasury that could not receive ERC-20 would only block `forwardFees()`, never a swap.

### NoOp justification for `beforeSwapReturnDelta`

The returned specified delta is always `+fee` with `fee = |amountSpecified| / 100`, never the whole
amount; the PoolManager's `HookDeltaExceedsSwapAmount` check and the tests `test_sellExactInput_*`,
`test_buyExactOutput_*` and the fuzz tests pin it to exactly 1%. The hook holds no user funds beyond the
claims it mints for its own fee, has no liquidity callbacks, no delegatecall, no selfdestruct, no proxy
and no way to change `FEE_BPS`.

### Launch gate

`beforeInitialize` accepts exactly one pool: the call must come from `factory` ("$factory"), the key must
contain `daemon` ("$token"), and any LP fee / tick spacing the manifest sets is accepted. A second
initialization reverts (`PoolAlreadyInitialized`).

### Security checklist (uniswap-v4-security)

| # | Item | Status |
| --- | --- | --- |
| 1 | Every callback checks `msg.sender == poolManager` | done, `test_callbacksRefuseNonManager` + floor test |
| 2 | Router allowlisting | not needed: the fee does not depend on who routes |
| 3 | Unbounded loops | none in the hook; the ladder queue is append-only with a head index |
| 4 | Reentrancy | hook makes no external call except to the PoolManager; treasury purchase is `nonReentrant` |
| 5 | Delta accounting sums to zero | mint(−fee) + hook delta(+fee) = 0; every swap test settles |
| 6 | Fee-on-transfer tokens | DAEMON is plain; the pair is ETH |
| 7 | No hardcoded addresses | all addresses are constructor arguments or owner-set |
| 8 | Slippage | untouched; the router's limits apply to the net amounts |
| 9 | Sensitive data | none |
| 10 | Upgrade mechanisms | none |
| 11 | `beforeSwapReturnDelta` justified | above |
| 12 | Fuzz tests | two fuzz tests on buy/sell fee, one on distribution conservation (64 runs) |
| 13 | Invariant tests | not written (time); listed as open |

Slither and Mythril were not available in this environment and did not run. Tests passing is not an
audit: an independent adversarial review is required before any funds are placed behind these contracts.

## Production allocation (1,000,000,000 DAEMON)

| Share | Amount | Where it goes |
| --- | --- | --- |
| 83% liquidity | 830,000,000 | pool, seeded by the launch factory |
| 10% IMD swarm | 100,000,000 | fixed swarm allocation handled by the factory |
| 7% remainder | 70,000,000 | `DistributionReceiver` (`remainderTo`), which splits it: |
| &nbsp;&nbsp;4% game rewards | 40,000,000 | `GameRewards` |
| &nbsp;&nbsp;1% development | 10,000,000 | owner-set development address |
| &nbsp;&nbsp;2% founder | 20,000,000 | owner-set founder address, unlocked, no vesting |

`DistributionReceiver.distribute()` splits whatever DAEMON it holds 4 : 1 : 2 and reverts until all three
recipients are set. No minting or burning exists anywhere (`test_noMintOrBurnPath`, floor tests).

**Assumption:** the factory sends the 83% to the pool and the 10% swarm share itself, and sends the 7% to
`remainderTo`. If instead the factory sends 17% to `remainderTo`, the swarm share must be split off first;
the receiver's fixed 4 : 1 : 2 ratio would then be wrong and needs a 10 : 4 : 1 : 2 variant. Confirm the
factory's split before the manifest is written.

## Creator share of pool fees → game rewards

The brief asks to route the entire creator share of pool fees to game rewards and warns not to assume
`remainderTo` controls fee revenue. **Verified from the inputs available here:** `remainderTo` is a token
distribution destination (the 7% remainder) and nothing in it concerns fee revenue. **Not verifiable
here:** the factory's `LaunchFees` contract, its 80% payer / 20% network split and the setter or
recipient field through which the payer's share is forwarded are not among the pinned inputs and
`.imd/reads/network.json` was not provided, so the forwarding mechanism could not be inspected.
`GameRewards` is built to be that recipient either way: it accepts ETH (`receive()`) and ERC-20, and the
owner can sweep ETH. **Operational step:** when the launch's fee-recipient mechanism is known, point the
payer share at the `GameRewards` address through the factory's supported setter. Until then this is an
open item, not an implemented route.

## NFT treasury guard rails

- Purchases run only through `buyNFT`, called by the owner or an operator; never from a hook callback.
- Marketplace and collection allowlists; per-purchase cap; rolling per-window cap (window length owner-set,
  default one day). Caps start at zero so purchases are disabled until the owner sets them.
- Allowance to the marketplace is exactly the price and is zeroed afterwards; an overcharging marketplace
  reverts (`test_marketplaceCannotPullMoreThanThePrice`).
- After the call the treasury checks `ownerOf(tokenId) == treasury`; a marketplace that takes payment without
  delivering reverts the whole purchase (`test_marketplaceThatKeepsPaymentWithoutDeliveringReverts`).
- The treasury and the game contracts have no reference to the PoolManager; the hook has no liquidity
  callbacks. Pool liquidity is never withdrawn for rewards or NFT purchases
  (`test_forwardSendsEveryFeeToTreasuryWithoutTouchingLiquidity`).
- Mocks: `test/mocks/MockERC721.sol`, `test/mocks/MockMarketplace.sol` (with rug and overcharge modes).

## Agent chess investigation

Observed on https://imdfamily.com on 2026-10-12 (pages `/game.html`, `/chess.html`, `/agents.html`,
scripts `/agent-panel.js`, `/agent-connect.js`, client `/agent-client.py`, endpoint
`/api/games/arena/public`).

**What exists today.** A local chess page ("Vs computer or a friend", local engine) and an agent arena.
The arena's public API answered `{"matches":[],"waiting":[],"rows":[],"official":false,"season":"Not
started"}`. Agent authentication is: `POST /api/games/challenge {wallet, tokenId}` → sign the returned
message with the wallet that owns that IdentityMD NFT (`personal_sign`) → `POST /api/games/login {id,
signature}` → a one-hour Bearer token. The published client (`agent-client.py`) then polls
`/api/games/arena`, needs an authenticated **Codex or Claude CLI** installed on the owner's machine
(`codex exec …` or `claude -p …`), uses that subscription's quota to choose each move, has "no
chess-engine fallback", plays exactly one practice match and stops. The site states: "Each participant
needs a different IdentityMD NFT, its owner wallet and an authenticated Codex or Claude CLI", "No winner
continues automatically after this one-match test", "automatic posting and automatic IMD swarm dispatch
are not connected", "Practice only", "Move limit: five minutes per turn", leaderboard by longest streak
then wins, draws return both to the queue.

**Winner-stays rule.** The arena already implements "winner stays, a new challenger takes the other
seat". `GameRewards` mirrors it on-chain (`register`, `reportResult`, draw handling, `waitingCount`) so
results reported by the arena's key can be recorded and prized later; it contains no engine and no
simulated agent.

**Blocker: swarm-to-game authentication is not supported.** Automatic participation by two IMD swarm
agents would require (a) each agent to hold, or be able to sign with, the private key of a wallet that
owns a distinct IdentityMD NFT, and (b) an authenticated Codex/Claude CLI session per agent. Neither is
available to a swarm worker: the arena's own page says swarm dispatch is not connected and the one-match
client stops after a single practice game. Running two agents here would mean fabricating wallets or NFT
ownership, or substituting an engine, which the brief forbids. **No agents were run.** What the requester
must decide to unblock it: either provision two operator-held wallets each owning an IdentityMD NFT (not
#222) plus two CLI sessions and run `agent-client.py` from those machines, or ask the arena maintainers
for a delegated agent-credential flow (for example an owner-signed delegation to an agent key) so a swarm
worker can authenticate without the NFT owner's private key.

**Prizes and seasons.** `prizesActive` is `false` and stays so for the trial; `awardPrize` reverts with
`PrizesInactive`. NFT #222 reverts with `ExcludedFromPrizes`. Results reported before `seasonStart` count
as test scores (`testWins`) and never enter `officialWins`/streaks. `setSeasonStart` can be set once, in
the future, at the real launch; the official window is `SEASON_LENGTH = 4 weeks`.

## Deployment plan

Nothing in this plan was executed. The production launch is done by the IMD launch factory from the
manifest written after acceptance; this repository does not contain a `launch.json`.

1. **Manifest values** (all placeholders, no literals):
   - `DaemonToken`: no constructor arguments. Name/symbol "DAEMON", 18 decimals, 1e27 supply to the factory.
   - `DaemonHook(poolManager, owner, factory, token)` = `"$poolManager"`, `"$owner"`, `"$factory"`, `"$token"`.
     Flags `8396` (`0x20CC`): beforeInitialize, beforeSwap, afterSwap, beforeSwapReturnDelta,
     afterSwapReturnDelta. The deployer mines a CREATE2 salt for those bits (`Deploy.mineSalt`).
   - `NFTTreasury(token, owner)`, `GameRewards(token, owner)`, `DistributionReceiver(token, owner)` =
     `"$token"`, `"$owner"`.
   - `pool.fee` = 12500 (launch tier), tick spacing per manifest; the hook accepts both. `remainderTo` =
     the `DistributionReceiver` address.
2. **Constructors** make no external calls and take at most 4 arguments each; every contract name is ≤ 32
   characters; all library functions are internal.
3. **After launch (owner steps, each emits an event):**
   | Contract | Setter | Value | Source |
   | --- | --- | --- | --- |
   | `DaemonHook` | `setTreasury(address)` | the `NFTTreasury` address | launch record |
   | `DistributionReceiver` | `setRecipients(game, development, founder)` | `GameRewards` address, the development wallet, the founder wallet | requester |
   | `DistributionReceiver` | `distribute()` | anyone, once the factory has sent the remainder | — |
   | `NFTTreasury` | `setMarketplace`, `setCollection`, `setCaps`, `setOperator` | allowlisted venue(s), collection(s), caps, buying operator | requester |
   | `GameRewards` | `setIdentityNft(address)` | the IdentityMD NFT contract on the launch chain | requester / explorer |
   | `GameRewards` | `setArbiter(address)` | the arena server's reporting key | arena maintainers |
   | `GameRewards` | `setSeasonStart(uint256)` | the real launch time | requester |
   | `GameRewards` | `setPrizesActive(true)` | only after the trial, by the owner | requester |
   | launch factory | its fee-recipient setter | `GameRewards` address | after the mechanism is verified |
4. **Operations:** anyone may call `forwardFees()` periodically (a keeper is fine); the treasury operator
   buys NFTs within caps; the owner is a trust assumption for treasury custody, prize awards and all
   setters, so it should be a multisig.
5. **Not done, by instruction:** no mainnet deployment, no production token, no spending, no publishing.

## Rehearsal script

`script/Deploy.s.sol` exposes `deploy(Config)`; `test/Deploy.t.sol` calls it directly with an explicit
config and then has the factory open the pool. `run(Config)` wraps it in a broadcast for a local anvil
rehearsal only. No test reads environment variables.

## Honest implementation status

| Item | Status |
| --- | --- |
| Hook: 1% DAEMON-side fee, both orders, exact in/out, claims settlement, forwarding | implemented, tested |
| Separation from LP fee | implemented, tested |
| Token: 1e9 supply, 18 decimals, no mint/burn | implemented, tested, floor tests pass |
| Distribution receiver 4 : 1 : 2 of the 7% | implemented, tested; factory split assumption above |
| NFT treasury with allowlists, caps, ownership check, mocks | implemented, tested |
| Game rewards, #222 exclusion, prizes inactive, 4-week season, test scores excluded | implemented, tested |
| Creator share of pool fees → game rewards | receiver ready; forwarding mechanism unverified (inputs missing) |
| Agent chess automatic participation by two swarm agents | **blocked**: arena requires NFT-owner wallet signatures and per-agent CLI sessions; swarm dispatch not connected; no agents run |
| Invariant tests, Slither, external audit, fork rehearsal | not done |
| Mainnet deployment, X post, hackathon entry | not done, by instruction |
