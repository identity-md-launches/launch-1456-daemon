// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./openzeppelin/token/ERC20/IERC20.sol";
import {SafeERC20} from "./openzeppelin/token/ERC20/utils/SafeERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {HookFlags} from "./HookFlags.sol";
import {LaunchRegistry} from "./LaunchRegistry.sol";
import {MerkleDistributor} from "./MerkleDistributor.sol";
import {LaunchFees} from "./LaunchFees.sol";
import {PoolFees} from "./PoolFees.sol";

/// @title The whole launch, in one transaction
/// @notice Deploys the token and the hook at deterministic addresses, splits the supply per policy,
/// initialises the pool, seeds it, funds the contributor distributor, and writes the public record —
/// all or nothing.
///
/// @dev Atomicity buys three separate things, and the third is the one that is easy to give away
/// later for convenience:
///
/// 1. Crash safety. There is no half-launch to reason about, so a deployer killed mid-flight has
///    either done nothing or done everything.
/// 2. MEV safety. Nobody can trade between `initialize` and the first liquidity, because there is no
///    between. Splitting these into two transactions hands the first trade to whoever is watching
///    the mempool.
/// 3. Idempotency. Every address is deterministic, so "did I already do this" is a code-size check
///    rather than a database question.
///
/// This contract is immutable and permanent per chain: its address is an input to every CREATE2
/// address it produces, so redeploying it renames every launch the network has ever predicted.
///
/// It keeps the liquidity it seeds, and with it the pool's LP fees, at whatever fee the hook sets:
/// anyone can claim a launch's fees, which split between its requester and the network (`PoolFees`).
contract LaunchFactory is IUnlockCallback, PoolFees {
    using SafeERC20 for IERC20;

    error NotDeployer();
    error AlreadyLaunched(uint64 launchNumber);
    error HookAddressMismatch(address predicted, uint160 wanted, uint160 got);
    error DeploymentFailed();
    error SupplyMismatch(uint256 expected, uint256 held);
    error InvalidPoolShare(uint16 poolBps);
    error RemainderRecipientMissing();
    error PoolShareExceeded(uint256 allowed, uint256 taken);
    error NotPoolManager();
    error CurrencyNotSorted();
    error NoLiquiditySeeded();
    error InitializationCallbackRequired();
    error PairedCurrencySpent(uint256 before, uint256 afterSeed);

    event Launched(
        uint64 indexed launchNumber,
        address indexed token,
        address indexed hook,
        address distributor,
        uint128 liquiditySeeded
    );

    /// @notice Everything one launch needs, assembled off chain from an attestation and a policy.
    /// @dev The technical half comes from the manifest and the attestation; the economic half comes
    /// from a policy row no model ever writes. Nothing here is derived on chain from the other, which
    /// is deliberate: the contract's job is to refuse a combination that does not add up, not to
    /// pick one.
    struct LaunchParams {
        uint64 launchNumber;
        bytes32 kind;
        /// @dev Creation code with constructor arguments already appended. The verifier attested the
        /// code without arguments; the deployer appends them and this recomputes what it deploys.
        bytes tokenCreationCode;
        bytes hookCreationCode;
        /// @dev Mined off chain until the resulting address carries exactly `hookFlags`.
        bytes32 hookSalt;
        uint160 hookFlags;
        /// @dev The whole supply, which the token must mint to this factory in its constructor.
        uint256 totalSupply;
        /// @dev Share of the whole supply the pool may take, the requester's choice within its 90%.
        /// The seed is rolled back if it takes more.
        uint16 poolBps;
        /// @dev Receives what the swarm and the pool leave: the requester's wallet, or zero for the
        /// chain's treasury (`LaunchFees.treasury()`), as for a launch nobody paid for.
        address remainderTo;
        bytes32 merkleRoot;
        uint64 contributorLockSeconds;
        uint64 sweepDelaySeconds;
        /// @dev The other side of the pair. Must sort below or above the launched token; the factory
        /// orders the key itself rather than trusting the caller to.
        Currency pairedCurrency;
        uint24 fee;
        int24 tickSpacing;
        uint160 sqrtPriceX96;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        LaunchRegistry.Launch record;
        uint256[] agentIds;
        /// @dev Who shares the pool's LP fees with the network: the wallet that paid for the launch, or zero.
        address requester;
    }

    /// @notice The swarm's share of every launch's supply: a constant, not a parameter. The other 90%
    /// is the requester's: `poolBps` of the supply seeds the pool, the rest goes to `remainderTo`.
    uint16 public constant SWARM_BPS = 1000;

    IPoolManager public immutable poolManager;
    LaunchRegistry public immutable registry;
    /// @notice The one address allowed to launch. It holds the key that spends; this holds nothing.
    address public immutable deployer;

    /// @dev Set for the duration of one `unlock`, so the callback knows what it is settling.
    struct Seeding {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        address token;
    }

    constructor(IPoolManager poolManager_, address deployer_, LaunchFees fees_) PoolFees(fees_) {
        poolManager = poolManager_;
        deployer = deployer_;
        // Created here rather than passed in, so that pairing the two is not a step anyone has to
        // remember to get right. The registry takes writes from this factory and from nothing else,
        // and it has no owner: there is no privileged action on a record that cannot be revised.
        registry = new LaunchRegistry(address(this));
    }

    /// @notice Runs one launch, or reverts having done nothing.
    function launch(LaunchParams calldata params) external returns (address token, address hook, address distributor) {
        if (msg.sender != deployer) revert NotDeployer();
        if (registry.isRecorded(params.launchNumber)) revert AlreadyLaunched(params.launchNumber);
        // Before this transaction the hook has no code, so an initialize callback cannot succeed.
        // Its deployment and pool initialization share this transaction; outsiders cannot interleave.
        if ((params.hookFlags & (HookFlags.BEFORE_INITIALIZE | HookFlags.AFTER_INITIALIZE)) == 0) {
            revert InitializationCallbackRequired();
        }

        uint16 requesterBps = 10_000 - SWARM_BPS;
        if (params.poolBps == 0 || params.poolBps > requesterBps) revert InvalidPoolShare(params.poolBps);
        if (params.remainderTo == address(this)) revert RemainderRecipientMissing();

        token = _deploy(params.tokenCreationCode, _launchSalt(params.launchNumber));
        hook = _deploy(params.hookCreationCode, params.hookSalt);

        // The pool manager checks this too and reverts on `initialize`. Checking it here costs one
        // comparison and turns an opaque revert deep inside v4 into a named error naming both sides.
        if (!HookFlags.matches(hook, params.hookFlags)) {
            revert HookAddressMismatch(hook, params.hookFlags & HookFlags.ALL, HookFlags.flagsOf(hook));
        }

        // The token must mint its whole supply to whoever deployed it, which is this contract. A
        // token that minted somewhere else would leave the splits below silently short, so the
        // supply is checked as well as the balance: holding `totalSupply` proves nothing about a
        // second mint to another wallet.
        uint256 held = IERC20(token).balanceOf(address(this));
        if (held != params.totalSupply || IERC20(token).totalSupply() != params.totalSupply) {
            revert SupplyMismatch(params.totalSupply, held);
        }

        distributor = address(
            new MerkleDistributor{salt: _launchSalt(params.launchNumber)}(
                IERC20(token), address(this), fees, params.sweepDelaySeconds
            )
        );

        // The swarm's tenth, whole, to the contributors' distributor.
        uint256 contributorPool = (params.totalSupply * SWARM_BPS) / 10_000;
        IERC20(token).safeTransfer(distributor, contributorPool);
        // The factory opens this one round and can open no other; the distributor answers to the
        // chain's treasury from here on, and nobody can sweep it before its delay is up.
        MerkleDistributor(distributor).openRound(params.merkleRoot, contributorPool, params.contributorLockSeconds);

        PoolKey memory key = _seedRequesterPool(params, token, hook);
        _openPosition(params.launchNumber, key, params.tickLower, params.tickUpper, params.requester);
        _record(params, token, hook, distributor);

        emit Launched(params.launchNumber, token, hook, distributor, params.liquidity);
    }

    /// @dev Creates and seeds the pool with at most the requester's pool share, and sends what the
    /// swarm and the pool leave to the requester. The balance is read around the seed on purpose:
    /// what the pool took is the honest measure of its share. The seed's external calls cannot
    /// re-enter a launch (only the deployer launches, and `unlockCallback` answers only the pool
    /// manager), so the reading is not attackable.
    // slither-disable-start reentrancy-balance
    function _seedRequesterPool(LaunchParams calldata params, address token, address hook)
        private
        returns (PoolKey memory key)
    {
        key = _poolKey(token, hook, params);
        // The seed is the launched token only. Anything this factory holds in the paired currency
        // is fees owed to other requesters and the network (`PoolFees`), so the seed must not spend
        // it — whether a hook returns a delta, moves the empty pool's price from its initialize
        // callback, or the range simply straddles the price. Read before `initialize`, because the
        // hook's initialize callback is the first code that could move it.
        uint256 pairedBefore = params.pairedCurrency.balanceOfSelf();
        poolManager.initialize(key, params.sqrtPriceX96);
        if (params.liquidity == 0) revert NoLiquiditySeeded();
        uint256 before = IERC20(token).balanceOf(address(this));
        poolManager.unlock(
            abi.encode(
                Seeding({
                    key: key,
                    tickLower: params.tickLower,
                    tickUpper: params.tickUpper,
                    liquidity: params.liquidity,
                    token: token
                })
            )
        );
        uint256 taken = before - IERC20(token).balanceOf(address(this));
        uint256 allowed = (params.totalSupply * params.poolBps) / 10_000;
        if (taken > allowed) revert PoolShareExceeded(allowed, taken);
        uint256 pairedAfter = params.pairedCurrency.balanceOfSelf();
        if (pairedAfter < pairedBefore) revert PairedCurrencySpent(pairedBefore, pairedAfter);
        uint256 remainder = IERC20(token).balanceOf(address(this));
        if (remainder > 0) {
            IERC20(token)
                .safeTransfer(params.remainderTo == address(0) ? fees.treasury() : params.remainderTo, remainder);
        }
    }

    // slither-disable-end reentrancy-balance

    /// @notice Settles the liquidity this factory just added.
    /// @dev v4 hands back a signed delta per currency: negative is owed to the pool, positive is owed
    /// to us. Both directions are handled rather than only the expected one — a hook that returns a
    /// delta can turn "we owe the pool" into "the pool owes us", and an implementation that only
    /// knew how to pay would strand tokens inside the manager.
    function unlockCallback(bytes calldata data) external override returns (bytes memory) {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        if (_claiming()) return _collect(data);

        Seeding memory seeding = abi.decode(data, (Seeding));

        (BalanceDelta delta,) = poolManager.modifyLiquidity(
            seeding.key,
            ModifyLiquidityParams({
                tickLower: seeding.tickLower,
                tickUpper: seeding.tickUpper,
                liquidityDelta: int256(uint256(seeding.liquidity)),
                salt: bytes32(0)
            }),
            ""
        );

        _settle(seeding.key.currency0, delta.amount0());
        _settle(seeding.key.currency1, delta.amount1());

        return "";
    }

    function _manager() internal view override returns (IPoolManager) {
        return poolManager;
    }

    /// @dev Pays what is owed, or takes what is owed to us. Zero is neither.
    function _settle(Currency currency, int128 amount) private {
        if (amount < 0) {
            uint256 due = uint256(uint128(-amount));
            poolManager.sync(currency);
            if (currency.isAddressZero()) {
                poolManager.settle{value: due}();
            } else {
                IERC20(Currency.unwrap(currency)).safeTransfer(address(poolManager), due);
                poolManager.settle();
            }
        } else if (amount > 0) {
            poolManager.take(currency, address(this), uint256(uint128(amount)));
        }
    }

    /// @dev v4 requires the pair sorted by address, and the caller does not get to decide the order.
    /// The hook is the one this transaction just deployed — not an address the caller supplies, which
    /// would let a launch attest one hook and pool against another.
    function _poolKey(address token, address hook, LaunchParams calldata params) private pure returns (PoolKey memory) {
        Currency launched = Currency.wrap(token);
        Currency paired = params.pairedCurrency;

        (Currency currency0, Currency currency1) =
            Currency.unwrap(launched) < Currency.unwrap(paired) ? (launched, paired) : (paired, launched);

        if (Currency.unwrap(currency0) >= Currency.unwrap(currency1)) revert CurrencyNotSorted();

        return PoolKey({
            currency0: currency0,
            currency1: currency1,
            fee: params.fee,
            tickSpacing: params.tickSpacing,
            hooks: IHooks(hook)
        });
    }

    function _record(LaunchParams calldata params, address token, address hook, address distributor) private {
        LaunchRegistry.Artifact[] memory artifacts = new LaunchRegistry.Artifact[](3);
        artifacts[0] = LaunchRegistry.Artifact("token", "token", token);
        artifacts[1] = LaunchRegistry.Artifact("hook", "hook", hook);
        artifacts[2] = LaunchRegistry.Artifact("distributor", "distributor", distributor);

        LaunchRegistry.Launch memory entry = params.record;
        entry.launchNumber = params.launchNumber;
        entry.kind = params.kind;

        registry.record(entry, artifacts, params.agentIds);
    }

    /// @dev CREATE2 so every address is knowable before anything is sent, which is what makes a
    /// crashed deployer recoverable rather than expensive.
    function _deploy(bytes memory creationCode, bytes32 salt) private returns (address deployed) {
        assembly ("memory-safe") {
            deployed := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
        if (deployed == address(0)) revert DeploymentFailed();
    }

    /// @dev The salt for everything a launch deploys that nobody has to mine: the token and the
    /// distributor. The hook's salt is mined off chain for its flags and taken exactly as given.
    function _launchSalt(uint64 launchNumber) private pure returns (bytes32) {
        return bytes32(uint256(launchNumber));
    }

    /// @notice The distributor's creation-code hash, so the deployer can report the distributor as an
    /// artifact the way the project factory's launches report theirs.
    function distributorCreationCodeHash() external pure returns (bytes32) {
        return keccak256(type(MerkleDistributor).creationCode);
    }

    /// @notice Where a launch's token will land, before it exists.
    /// @dev The whole idempotency story: the deployer predicts, checks for code, and skips a launch
    /// that already happened rather than paying for it twice.
    function predictToken(uint64 launchNumber, bytes calldata tokenCreationCode) external view returns (address) {
        return _predict(_launchSalt(launchNumber), tokenCreationCode);
    }

    /// @notice Where a launch's hook will land, for the salt the deployer mined.
    /// @dev The salt is taken exactly as `launch` takes it. One `predict` for both used to read a
    /// zero salt as "none given, use the launch number" — a fine default for a token and a wrong
    /// answer for a hook: the miner counts up from zero, so zero is a salt a launch can really carry,
    /// and it was the one value for which the prediction and the deployment disagreed.
    function predictHook(bytes calldata hookCreationCode, bytes32 hookSalt) external view returns (address) {
        return _predict(hookSalt, hookCreationCode);
    }

    /// @dev CREATE2 as the EVM computes it, with this factory as the deployer.
    function _predict(bytes32 salt, bytes calldata creationCode) private view returns (address) {
        return address(
            uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), address(this), salt, keccak256(creationCode)))))
        );
    }

    receive() external payable {}
}
