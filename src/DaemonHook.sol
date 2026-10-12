// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary, toBeforeSwapDelta} from "v4-core/src/types/BeforeSwapDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice TEST ONLY. Fixed 1% native ETH fee, separate from the factory's LP fee.
/// @dev ETH specified: floor(abs(amountSpecified)/100), collected beforeSwap. ETH unspecified:
/// floor(abs(actual pool ETH delta)/100), collected afterSwap. Specified-ETH partial fills revert
/// so an unfilled request cannot be charged. Fees settle as native ERC-6909 claims; permissionless
/// forwarding redeems them outside swaps to the permanently configured NFT treasury.
contract DaemonHook is IHooks, IUnlockCallback {
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    // ------------------------------------------------------------------ constants

    /// @notice Hook fee in basis points on the ETH leg of a swap. Fixed for the life of the hook.
    uint256 public constant FEE_BPS = 100;
    uint256 public constant BPS = 10_000;

    // ------------------------------------------------------------------ immutables

    IPoolManager public immutable poolManager;
    /// @notice The launch factory: the only address allowed to initialize the pool.
    address public immutable factory;
    /// @notice The DAEMON token paired with native ETH.
    address public immutable daemon;

    // ------------------------------------------------------------------ storage

    address public owner;
    address public pendingOwner;
    /// @notice NFT treasury that receives all forwarded fees. Unset until the owner configures it.
    address public treasury;
    /// @notice The single pool this hook serves; zero until the factory initializes it.
    PoolId public poolId;
    bool public poolInitialized;
    /// @notice Lifetime ETH fees charged (claims minted) and forwarded to the treasury.
    uint256 public totalFeesCharged;
    uint256 public totalFeesForwarded;

    // ------------------------------------------------------------------ events

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event TreasurySet(address indexed previousTreasury, address indexed newTreasury);
    event PoolAccepted(PoolId indexed poolId, address currency0, address currency1, uint24 fee);
    event FeeCharged(PoolId indexed poolId, bool zeroForOne, bool exactInput, uint256 amount);
    event FeesForwarded(address indexed treasury, uint256 amount);

    // ------------------------------------------------------------------ errors

    error NotPoolManager();
    error NotOwner();
    error NotPendingOwner();
    error NotFactory();
    error ZeroAddress();
    error PoolMissingDaemon();
    error PoolAlreadyInitialized();
    error TreasuryNotConfigured();
    error NothingToForward();
    error HookNotImplemented();
    error NativePairRequired();
    error TreasuryAlreadyConfigured();
    error InvalidTreasury();
    error WrongPool();
    error AmountTooLarge();
    error PartialFillUnsupported();

    // ------------------------------------------------------------------ modifiers

    modifier onlyPoolManager() {
        if (msg.sender != address(poolManager)) revert NotPoolManager();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    // ------------------------------------------------------------------ constructor

    /// @param manager_ The chain's PoolManager (launch manifest: "$poolManager").
    /// @param owner_ The owner who configures the treasury (launch manifest: "$owner"). Never msg.sender.
    /// @param factory_ The launch factory allowed to initialize the pool (launch manifest: "$factory").
    /// @param daemon_ The DAEMON token paired with ETH (launch manifest: "$token").
    /// @dev Makes no external call: the launch checks run the constructor on an empty chain.
    constructor(IPoolManager manager_, address owner_, address factory_, address daemon_) {
        if (address(manager_) == address(0) || owner_ == address(0) || factory_ == address(0) || daemon_ == address(0))
        {
            revert ZeroAddress();
        }
        poolManager = manager_;
        owner = owner_;
        factory = factory_;
        daemon = daemon_;
        Hooks.validateHookPermissions(this, getHookPermissions());
        emit OwnershipTransferred(address(0), owner_);
    }

    // ------------------------------------------------------------------ permissions

    function getHookPermissions() public pure returns (Hooks.Permissions memory) {
        return Hooks.Permissions({
            beforeInitialize: true,
            afterInitialize: false,
            beforeAddLiquidity: false,
            afterAddLiquidity: false,
            beforeRemoveLiquidity: false,
            afterRemoveLiquidity: false,
            beforeSwap: true,
            afterSwap: true,
            beforeDonate: false,
            afterDonate: false,
            beforeSwapReturnDelta: true,
            afterSwapReturnDelta: true,
            afterAddLiquidityReturnDelta: false,
            afterRemoveLiquidityReturnDelta: false
        });
    }

    // ------------------------------------------------------------------ admin

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /// @notice Sets the NFT treasury that receives forwarded fees. Fees accrue as claims until it is set.
    function setTreasury(address newTreasury) external onlyOwner {
        if (newTreasury == address(0)) revert ZeroAddress();
        if (treasury != address(0)) revert TreasuryAlreadyConfigured();
        if (newTreasury.code.length == 0) revert InvalidTreasury();
        emit TreasurySet(treasury, newTreasury);
        treasury = newTreasury;
    }

    // ------------------------------------------------------------------ fee forwarding

    /// @notice ETH fees held by the hook as ERC-6909 claims, not yet forwarded.
    function pendingFees() public view returns (uint256) {
        return poolManager.balanceOf(address(this), Currency.wrap(address(0)).toId());
    }

    /// @notice Forwards every pending ETH fee claim to the treasury. Anyone may call; runs outside swaps.
    function forwardFees() external returns (uint256 amount) {
        if (treasury == address(0)) revert TreasuryNotConfigured();
        amount = pendingFees();
        if (amount == 0) revert NothingToForward();
        poolManager.unlock(abi.encode(amount));
    }

    /// @inheritdoc IUnlockCallback
    function unlockCallback(bytes calldata data) external onlyPoolManager returns (bytes memory) {
        uint256 amount = abi.decode(data, (uint256));
        Currency currency = Currency.wrap(address(0));
        poolManager.burn(address(this), currency.toId(), amount);
        poolManager.take(currency, treasury, amount);
        totalFeesForwarded += amount;
        emit FeesForwarded(treasury, amount);
        return "";
    }

    // ------------------------------------------------------------------ hook callbacks

    /// @inheritdoc IHooks
    function beforeInitialize(address sender, PoolKey calldata key, uint160) external onlyPoolManager returns (bytes4) {
        if (sender != factory) revert NotFactory();
        if (poolInitialized) revert PoolAlreadyInitialized();
        if (Currency.unwrap(key.currency0) != daemon && Currency.unwrap(key.currency1) != daemon) {
            revert PoolMissingDaemon();
        }
        if (!key.currency0.isAddressZero() && !key.currency1.isAddressZero()) revert NativePairRequired();
        PoolId id = key.toId();
        poolId = id;
        poolInitialized = true;
        emit PoolAccepted(id, Currency.unwrap(key.currency0), Currency.unwrap(key.currency1), key.fee);
        return IHooks.beforeInitialize.selector;
    }

    /// @inheritdoc IHooks
    function beforeSwap(address, PoolKey calldata key, SwapParams calldata params, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, BeforeSwapDelta, uint24)
    {
        _checkPool(key);
        // Specified currency: input on exact-input, output on exact-output.
        bool exactInput = params.amountSpecified < 0;
        Currency specified = (params.zeroForOne == exactInput) ? key.currency0 : key.currency1;
        if (!specified.isAddressZero()) {
            return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        }
        if (params.amountSpecified == type(int256).min) revert AmountTooLarge();
        uint256 magnitude = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
        if (magnitude > uint256(uint128(type(int128).max)) / 101 * 100) revert AmountTooLarge();
        uint256 fee = magnitude * FEE_BPS / BPS;
        if (fee == 0) return (IHooks.beforeSwap.selector, BeforeSwapDeltaLibrary.ZERO_DELTA, 0);
        _chargeFee(key, params.zeroForOne, exactInput, fee);
        // Positive specified delta: the hook is owed `fee` of the specified currency. On exact input the pool
        // receives amountSpecified - fee; on exact output the pool delivers amountSpecified + fee.
        return (IHooks.beforeSwap.selector, toBeforeSwapDelta(int128(uint128(fee)), 0), 0);
    }

    /// @inheritdoc IHooks
    function afterSwap(address, PoolKey calldata key, SwapParams calldata params, BalanceDelta delta, bytes calldata)
        external
        onlyPoolManager
        returns (bytes4, int128)
    {
        bool exactInput = params.amountSpecified < 0;
        _checkPool(key);
        // ETH specified must fill completely. Core supplies the pre-hook pool delta here.
        bool specifiedIsZero = params.zeroForOne == exactInput;
        Currency specified = specifiedIsZero ? key.currency0 : key.currency1;
        if (specified.isAddressZero()) {
            uint256 requested = exactInput ? uint256(-params.amountSpecified) : uint256(params.amountSpecified);
            uint256 feeBefore = requested / 100;
            int256 actual = specifiedIsZero ? int256(delta.amount0()) : int256(delta.amount1());
            int256 expected = exactInput ? -int256(requested - feeBefore) : int256(requested + feeBefore);
            if (actual != expected) revert PartialFillUnsupported();
            return (IHooks.afterSwap.selector, 0);
        }
        // Unspecified currency is the other side.
        Currency unspecified = (params.zeroForOne == exactInput) ? key.currency1 : key.currency0;
        if (!unspecified.isAddressZero()) return (IHooks.afterSwap.selector, 0);
        int128 unspecifiedAmount = (params.zeroForOne == exactInput) ? delta.amount1() : delta.amount0();
        uint256 magnitude =
            unspecifiedAmount < 0 ? uint256(-int256(unspecifiedAmount)) : uint256(uint128(unspecifiedAmount));
        uint256 fee = magnitude * FEE_BPS / BPS;
        if (fee == 0) return (IHooks.afterSwap.selector, 0);
        _chargeFee(key, params.zeroForOne, exactInput, fee);
        // Positive unspecified delta: the swapper receives `fee` less (exact input) or pays `fee` more (exact output).
        return (IHooks.afterSwap.selector, int128(uint128(fee)));
    }

    /// @dev Settles the hook's positive fee delta by minting itself an ERC-6909 claim for native ETH. The claim mint
    /// accounts -fee to the hook, the returned hook delta accounts +fee, so the hook's delta nets to zero.
    function _chargeFee(PoolKey calldata key, bool zeroForOne, bool exactInput, uint256 fee) internal {
        poolManager.mint(address(this), Currency.wrap(address(0)).toId(), fee);
        totalFeesCharged += fee;
        emit FeeCharged(key.toId(), zeroForOne, exactInput, fee);
    }

    function _checkPool(PoolKey calldata key) internal view {
        if (!poolInitialized || PoolId.unwrap(key.toId()) != PoolId.unwrap(poolId)) revert WrongPool();
    }

    // ------------------------------------------------------------------ unused callbacks (never called: bits unset)

    function afterInitialize(address, PoolKey calldata, uint160, int24) external view onlyPoolManager returns (bytes4) {
        revert HookNotImplemented();
    }

    function beforeAddLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterAddLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeRemoveLiquidity(address, PoolKey calldata, ModifyLiquidityParams calldata, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterRemoveLiquidity(
        address,
        PoolKey calldata,
        ModifyLiquidityParams calldata,
        BalanceDelta,
        BalanceDelta,
        bytes calldata
    ) external view onlyPoolManager returns (bytes4, BalanceDelta) {
        revert HookNotImplemented();
    }

    function beforeDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }

    function afterDonate(address, PoolKey calldata, uint256, uint256, bytes calldata)
        external
        view
        onlyPoolManager
        returns (bytes4)
    {
        revert HookNotImplemented();
    }
}
