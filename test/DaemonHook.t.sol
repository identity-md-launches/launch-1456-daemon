// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {DaemonHook} from "../src/DaemonHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @notice Fee accounting, both token orders, exact-input/output, permissions and unauthorized access.
contract DaemonHookTest is Fixture {
    using StateLibrary for IPoolManager;

    uint256 constant SEED = 10_000_000e18;
    uint256 constant TRADER_FUNDS = 1_000_000e18;

    MockERC20 pairBelow; // pair is currency0, DAEMON is currency1
    MockERC20 pairAbove; // DAEMON is currency0, pair is currency1
    PoolKey keyDaemon1;
    PoolKey keyDaemon0;

    function setUp() public {
        _deployCore();
        pairBelow = _pairToken(true);
        keyDaemon1 = _key(address(pairBelow));
        _openAndSeed(keyDaemon1, pairBelow, SEED);
        _fund(trader, pairBelow, TRADER_FUNDS);
    }

    /// @dev Second hook instance for the other token order (one hook serves exactly one pool).
    function _setUpDaemon0() internal {
        _deployCore();
        pairAbove = _pairToken(false);
        keyDaemon0 = _key(address(pairAbove));
        _openAndSeed(keyDaemon0, pairAbove, SEED);
        _fund(trader, pairAbove, TRADER_FUNDS);
    }

    // ------------------------------------------------------------------ permissions & address

    function test_permissionsMatchAddressAndHaveNoLiquidityCallbacks() public view {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(p.beforeInitialize);
        assertTrue(p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta);
        assertFalse(p.afterInitialize || p.beforeAddLiquidity || p.afterAddLiquidity);
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate);
        assertFalse(p.afterAddLiquidityReturnDelta || p.afterRemoveLiquidityReturnDelta);
        assertEq(HookFlags.flagsOf(address(hook)), FLAGS);
        assertEq(hook.FEE_BPS(), 100);
    }

    function test_constructorRejectsWrongAddressBits() public {
        vm.expectRevert();
        new DaemonHook(IPoolManager(address(manager)), owner, factory, address(daemon));
    }

    function test_constructorRejectsZeroAddresses() public {
        bytes memory code = abi.encodePacked(
            type(DaemonHook).creationCode, abi.encode(address(manager), address(0), factory, address(daemon))
        );
        address at;
        assembly {
            at := create2(0, add(code, 0x20), mload(code), 0)
        }
        assertEq(at, address(0), "zero owner must revert");
    }

    // ------------------------------------------------------------------ initialization gate

    function test_initializeRefusesNonFactory() public {
        _deployCore();
        PoolKey memory key = _key(address(_pairToken(true)));
        vm.prank(stranger);
        vm.expectRevert();
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    function test_initializeRefusesPoolWithoutDaemon() public {
        _deployCore();
        MockERC20 a = new MockERC20("A", "A", 0);
        MockERC20 b = new MockERC20("B", "B", 0);
        (address c0, address c1) = address(a) < address(b) ? (address(a), address(b)) : (address(b), address(a));
        PoolKey memory key = PoolKey(Currency.wrap(c0), Currency.wrap(c1), LP_FEE, TICK_SPACING, IHooks(address(hook)));
        vm.prank(factory);
        vm.expectRevert();
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    function test_initializeAcceptsOnlyOnePool() public {
        assertTrue(hook.poolInitialized());
        assertEq(PoolId.unwrap(hook.poolId()), PoolId.unwrap(keyDaemon1.toId()));
        PoolKey memory second = _key(address(_pairToken(false)));
        vm.prank(factory);
        vm.expectRevert();
        manager.initialize(second, SQRT_PRICE_1_1);
    }

    function test_initializeAcceptsLaunchTierFeeAndNativePair() public {
        _deployCore();
        PoolKey memory key = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(daemon)), LP_FEE, TICK_SPACING, IHooks(address(hook))
        );
        vm.prank(factory);
        manager.initialize(key, SQRT_PRICE_1_1);
        (,,, uint24 lpFee) = IPoolManager(address(manager)).getSlot0(key.toId());
        assertEq(lpFee, LP_FEE, "LP fee is the pool's, untouched by the hook");
    }

    // ------------------------------------------------------------------ unauthorized access

    function test_callbacksRefuseNonManager() public {
        SwapParams memory sp = SwapParams(true, -1e18, SQRT_PRICE_1_1 / 2);
        ModifyLiquidityParams memory lp = ModifyLiquidityParams(-100, 100, 1e18, bytes32(0));
        vm.startPrank(stranger);
        vm.expectRevert(DaemonHook.NotPoolManager.selector);
        hook.beforeInitialize(factory, keyDaemon1, SQRT_PRICE_1_1);
        vm.expectRevert(DaemonHook.NotPoolManager.selector);
        hook.afterInitialize(factory, keyDaemon1, SQRT_PRICE_1_1, 0);
        vm.expectRevert(DaemonHook.NotPoolManager.selector);
        hook.beforeSwap(stranger, keyDaemon1, sp, "");
        vm.expectRevert(DaemonHook.NotPoolManager.selector);
        hook.afterSwap(stranger, keyDaemon1, sp, BalanceDelta.wrap(0), "");
        vm.expectRevert(DaemonHook.NotPoolManager.selector);
        hook.beforeAddLiquidity(stranger, keyDaemon1, lp, "");
        vm.expectRevert(DaemonHook.NotPoolManager.selector);
        hook.beforeRemoveLiquidity(stranger, keyDaemon1, lp, "");
        vm.expectRevert(DaemonHook.NotPoolManager.selector);
        hook.beforeDonate(stranger, keyDaemon1, 1, 1, "");
        vm.expectRevert(DaemonHook.NotPoolManager.selector);
        hook.afterDonate(stranger, keyDaemon1, 1, 1, "");
        vm.expectRevert(DaemonHook.NotPoolManager.selector);
        hook.unlockCallback(abi.encode(uint256(1)));
        vm.stopPrank();
    }

    function test_adminIsOwnerOnly() public {
        vm.prank(stranger);
        vm.expectRevert(DaemonHook.NotOwner.selector);
        hook.setTreasury(address(treasury));
        vm.prank(stranger);
        vm.expectRevert(DaemonHook.NotOwner.selector);
        hook.transferOwnership(stranger);
        vm.prank(owner);
        vm.expectRevert(DaemonHook.ZeroAddress.selector);
        hook.setTreasury(address(0));

        vm.prank(owner);
        hook.transferOwnership(stranger);
        assertEq(hook.owner(), owner, "two-step: still the old owner");
        vm.prank(trader);
        vm.expectRevert(DaemonHook.NotPendingOwner.selector);
        hook.acceptOwnership();
        vm.prank(stranger);
        hook.acceptOwnership();
        assertEq(hook.owner(), stranger);
    }

    // ------------------------------------------------------------------ fee accounting, DAEMON = currency1

    /// Exact-input buy: pair in, DAEMON out. DAEMON is unspecified; afterSwap takes 1% of the output.
    function test_buyExactInput_daemon1() public {
        uint256 before = daemon.balanceOf(trader);
        _swap(keyDaemon1, true, -1_000e18);
        uint256 received = daemon.balanceOf(trader) - before;
        uint256 fee = hook.pendingFees();
        assertGt(fee, 0);
        assertEq(fee, (received + fee) * 100 / 10_000, "fee is 1% of the DAEMON the pool produced");
        assertEq(hook.totalFeesCharged(), fee);
    }

    /// Exact-output buy: pair in, exactly X DAEMON out. DAEMON is specified; beforeSwap adds 1% on top.
    function test_buyExactOutput_daemon1() public {
        uint256 before = daemon.balanceOf(trader);
        uint256 want = 1_000e18;
        _swap(keyDaemon1, true, int256(want));
        assertEq(daemon.balanceOf(trader) - before, want, "trader receives exactly what was asked");
        assertEq(hook.pendingFees(), want / 100, "fee is 1% of the specified DAEMON");
    }

    /// Exact-input sell: exactly X DAEMON in, pair out. DAEMON is specified; beforeSwap keeps 1% of the input.
    function test_sellExactInput_daemon1() public {
        uint256 before = daemon.balanceOf(trader);
        uint256 pairBefore = pairBelow.balanceOf(trader);
        uint256 amount = 1_000e18;
        _swap(keyDaemon1, false, -int256(amount));
        assertEq(before - daemon.balanceOf(trader), amount, "trader pays exactly what was specified");
        assertEq(hook.pendingFees(), amount / 100);
        assertGt(pairBelow.balanceOf(trader), pairBefore);
    }

    /// Exact-output sell: DAEMON in, exactly Y pair out. DAEMON is unspecified; afterSwap adds 1% to the input.
    function test_sellExactOutput_daemon1() public {
        uint256 before = daemon.balanceOf(trader);
        uint256 pairBefore = pairBelow.balanceOf(trader);
        uint256 want = 1_000e18;
        _swap(keyDaemon1, false, int256(want));
        assertEq(pairBelow.balanceOf(trader) - pairBefore, want, "trader receives exactly the pair amount");
        uint256 paid = before - daemon.balanceOf(trader);
        uint256 fee = hook.pendingFees();
        assertEq(fee, (paid - fee) * 100 / 10_000, "fee is 1% of the DAEMON the pool demanded");
    }

    // ------------------------------------------------------------------ fee accounting, DAEMON = currency0

    function test_buyExactInput_daemon0() public {
        _setUpDaemon0();
        uint256 before = daemon.balanceOf(trader);
        _swap(keyDaemon0, false, -1_000e18);
        uint256 received = daemon.balanceOf(trader) - before;
        uint256 fee = hook.pendingFees();
        assertGt(fee, 0);
        assertEq(fee, (received + fee) * 100 / 10_000);
    }

    function test_buyExactOutput_daemon0() public {
        _setUpDaemon0();
        uint256 before = daemon.balanceOf(trader);
        _swap(keyDaemon0, false, 1_000e18);
        assertEq(daemon.balanceOf(trader) - before, 1_000e18);
        assertEq(hook.pendingFees(), 10e18);
    }

    function test_sellExactInput_daemon0() public {
        _setUpDaemon0();
        uint256 before = daemon.balanceOf(trader);
        _swap(keyDaemon0, true, -1_000e18);
        assertEq(before - daemon.balanceOf(trader), 1_000e18);
        assertEq(hook.pendingFees(), 10e18);
    }

    function test_sellExactOutput_daemon0() public {
        _setUpDaemon0();
        uint256 before = daemon.balanceOf(trader);
        uint256 pairBefore = pairAbove.balanceOf(trader);
        _swap(keyDaemon0, true, 1_000e18);
        assertEq(pairAbove.balanceOf(trader) - pairBefore, 1_000e18);
        uint256 paid = before - daemon.balanceOf(trader);
        uint256 fee = hook.pendingFees();
        assertEq(fee, (paid - fee) * 100 / 10_000);
    }

    function testFuzz_buyFeeIsOnePercentOfPoolOutput(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e12, 100_000e18);
        uint256 before = daemon.balanceOf(trader);
        _swap(keyDaemon1, true, -int256(amountIn));
        uint256 received = daemon.balanceOf(trader) - before;
        uint256 fee = hook.pendingFees();
        assertEq(fee, (received + fee) * 100 / 10_000);
    }

    function testFuzz_sellFeeIsOnePercentOfInput(uint256 amountIn) public {
        amountIn = bound(amountIn, 1e12, 100_000e18);
        uint256 before = daemon.balanceOf(trader);
        _swap(keyDaemon1, false, -int256(amountIn));
        assertEq(before - daemon.balanceOf(trader), amountIn);
        assertEq(hook.pendingFees(), amountIn / 100);
    }

    /// The hook never charges the pair currency: a pair-side amount is exactly what the pool produced.
    function test_pairSideIsNeverCharged() public {
        uint256 pairBefore = pairBelow.balanceOf(trader);
        BalanceDelta d = _swap(keyDaemon1, false, -1_000e18);
        assertEq(pairBelow.balanceOf(trader) - pairBefore, uint256(uint128(d.amount0())));
        assertEq(manager.balanceOf(address(hook), Currency.wrap(address(pairBelow)).toId()), 0);
    }

    // ------------------------------------------------------------------ separation from LP fees

    function test_lpFeeAccruesToLiquidityIndependently() public {
        (,,, uint24 lpFee) = IPoolManager(address(manager)).getSlot0(keyDaemon1.toId());
        assertEq(lpFee, LP_FEE);
        (uint256 g0Before, uint256 g1Before) = IPoolManager(address(manager)).getFeeGrowthGlobals(keyDaemon1.toId());
        _swap(keyDaemon1, true, -1_000e18);
        (uint256 g0After, uint256 g1After) = IPoolManager(address(manager)).getFeeGrowthGlobals(keyDaemon1.toId());
        assertGt(g0After, g0Before, "LP fee grew on the input side");
        assertEq(g1After, g1Before, "hook fee did not leak into LP fee growth");
        assertEq(hook.pendingFees(), (daemon.balanceOf(trader) - (TRADER_FUNDS) + hook.pendingFees()) / 100);
    }

    // ------------------------------------------------------------------ forwarding to the treasury

    function test_forwardRevertsUntilTreasuryConfigured() public {
        _swap(keyDaemon1, true, -1_000e18);
        assertGt(hook.pendingFees(), 0, "fees still accrue while unconfigured");
        vm.expectRevert(DaemonHook.TreasuryNotConfigured.selector);
        hook.forwardFees();
    }

    function test_forwardRevertsWithNothingPending() public {
        vm.prank(owner);
        hook.setTreasury(address(treasury));
        vm.expectRevert(DaemonHook.NothingToForward.selector);
        hook.forwardFees();
    }

    function test_forwardSendsEveryFeeToTreasuryWithoutTouchingLiquidity() public {
        vm.prank(owner);
        hook.setTreasury(address(treasury));
        _swap(keyDaemon1, true, -5_000e18);
        _swap(keyDaemon1, false, -2_000e18);
        _swap(keyDaemon1, true, 300e18);
        uint256 pending = hook.pendingFees();
        assertEq(pending, hook.totalFeesCharged());
        uint128 liquidityBefore = IPoolManager(address(manager)).getLiquidity(keyDaemon1.toId());
        uint256 managerDaemonBefore = daemon.balanceOf(address(manager));

        vm.prank(stranger); // anyone may forward
        uint256 forwarded = hook.forwardFees();

        assertEq(forwarded, pending);
        assertEq(daemon.balanceOf(address(treasury)), pending);
        assertEq(hook.pendingFees(), 0);
        assertEq(hook.totalFeesForwarded(), pending);
        assertEq(IPoolManager(address(manager)).getLiquidity(keyDaemon1.toId()), liquidityBefore, "liquidity untouched");
        assertEq(managerDaemonBefore - daemon.balanceOf(address(manager)), pending, "only the fee claims left");
    }

    // ------------------------------------------------------------------ native ETH pair, token-only seeding

    /// A fresh manager holding no ETH, a pool seeded with DAEMON only: a buy with ETH must still work and the
    /// fee must still be charged, because the fee is settled as a claim, never as a transfer.
    function test_nativePairTokenOnlySeedBuyAndSell() public {
        _deployCore();
        PoolKey memory key = PoolKey(
            Currency.wrap(address(0)), Currency.wrap(address(daemon)), LP_FEE, TICK_SPACING, IHooks(address(hook))
        );
        vm.prank(factory);
        manager.initialize(key, SQRT_PRICE_1_1);
        _approveAll(factory, address(daemon));
        // One-sided DAEMON (currency1) position at or below the current price: no ETH enters the manager.
        vm.prank(factory);
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(-10_000, 0, int256(SEED), bytes32(0)), "");
        assertEq(address(manager).balance, 0, "manager holds no ETH before the first buy");

        vm.deal(trader, 100 ether);
        uint256 before = daemon.balanceOf(trader);
        _swapAs(trader, key, true, -1 ether, 1 ether);
        uint256 received = daemon.balanceOf(trader) - before;
        uint256 fee = hook.pendingFees();
        assertGt(received, 0);
        assertEq(fee, (received + fee) * 100 / 10_000);

        // Sell some DAEMON back for ETH: exact input, fee on the DAEMON input.
        _approveAll(trader, address(daemon));
        uint256 ethBefore = trader.balance;
        _swapAs(trader, key, false, -int256(received / 2), 0);
        assertGt(trader.balance, ethBefore);
        assertEq(hook.pendingFees(), fee + (received / 2) / 100);
    }
}
