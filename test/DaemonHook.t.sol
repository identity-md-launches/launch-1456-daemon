// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Fixture} from "./utils/Fixture.sol";
import {HookDeployer} from "./utils/HookDeployer.sol";
import {DaemonHook} from "../src/DaemonHook.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {PoolId} from "v4-core/src/types/PoolId.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta, toBalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {BeforeSwapDelta, BeforeSwapDeltaLibrary} from "v4-core/src/types/BeforeSwapDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";

contract RefusingETH {
    receive() external payable {
        revert("reject ETH");
    }
}

contract DaemonHookTest is Fixture {
    using StateLibrary for IPoolManager;
    PoolKey key;

    function setUp() public {
        _deployCore();
        key = _key(address(0));
        vm.prank(factory);
        manager.initialize(key, SQRT_PRICE_1_1);
        _approveAll(factory, address(daemon));
        vm.deal(factory, 100_000 ether);
        vm.prank(factory);
        lpRouter.modifyLiquidity{value: 10_001 ether}(key, ModifyLiquidityParams(-10000, 10000, 25_000 ether, 0), "");
        vm.prank(factory);
        daemon.transfer(trader, 10_000 ether);
        _approveAll(trader, address(daemon));
        vm.deal(trader, 10_000 ether);
    }

    function test_buyExactInputETH() public {
        uint256 before = trader.balance;
        BalanceDelta d = _swapAs(trader, key, true, -1 ether, 1 ether);
        assertEq(before - trader.balance, 1 ether);
        assertEq(hook.pendingFees(), 0.01 ether);
        assertEq(d.amount0(), -1 ether);
        assertEq(manager.balanceOf(address(hook), uint256(uint160(address(daemon)))), 0);
    }

    function test_buyExactOutputDaemon() public {
        uint256 before = trader.balance;
        uint256 tokens = daemon.balanceOf(trader);
        _swapAs(trader, key, true, 1 ether, 2 ether);
        uint256 paid = before - trader.balance;
        uint256 fee = hook.pendingFees();
        assertEq(daemon.balanceOf(trader) - tokens, 1 ether);
        assertEq(fee, (paid - fee) / 100);
    }

    function test_sellExactInputDaemon() public {
        uint256 before = trader.balance;
        uint256 tokens = daemon.balanceOf(trader);
        _swapAs(trader, key, false, -1 ether, 0);
        uint256 received = trader.balance - before;
        uint256 fee = hook.pendingFees();
        assertEq(tokens - daemon.balanceOf(trader), 1 ether);
        assertEq(fee, (received + fee) / 100);
    }

    function test_sellExactOutputETH() public {
        uint256 before = trader.balance;
        _swapAs(trader, key, false, 1 ether, 0);
        assertEq(trader.balance - before, 1 ether);
        assertEq(hook.pendingFees(), 0.01 ether);
    }

    function testFuzz_buyRounding(uint96 value) public {
        uint256 amount = bound(value, 100, 100 ether);
        uint256 before = trader.balance;
        _swapAs(trader, key, true, -int256(amount), amount);
        assertEq(before - trader.balance, amount);
        assertEq(hook.pendingFees(), amount / 100);
    }

    function testFuzz_sellRounding(uint96 value) public {
        uint256 amount = bound(value, 100, 100 ether);
        uint256 before = trader.balance;
        _swapAs(trader, key, false, -int256(amount), 0);
        uint256 fee = hook.pendingFees();
        assertEq(fee, (trader.balance - before + fee) / 100);
    }

    function test_dust99WeiChargesZeroAnd100ChargesOne() public {
        _swapAs(trader, key, true, -99, 99);
        assertEq(hook.pendingFees(), 0);
        _swapAs(trader, key, true, -100, 100);
        assertEq(hook.pendingFees(), 1);
    }

    function test_forwardAllETHAndPreserveLiquidityAndTokens() public {
        vm.prank(owner);
        hook.setTreasury(address(treasury));
        _swapAs(trader, key, true, -5 ether, 5 ether);
        _swapAs(trader, key, false, -2 ether, 0);
        uint256 fee = hook.pendingFees();
        uint256 tokens = daemon.balanceOf(address(manager));
        uint256 eth = address(manager).balance;
        uint128 liquidity = IPoolManager(address(manager)).getLiquidity(key.toId());
        vm.prank(stranger);
        assertEq(hook.forwardFees(), fee);
        assertEq(address(treasury).balance, fee);
        assertEq(address(manager).balance, eth - fee);
        assertEq(daemon.balanceOf(address(manager)), tokens);
        assertEq(hook.pendingFees(), 0);
        assertEq(hook.totalFeesForwarded(), hook.totalFeesCharged());
        assertEq(IPoolManager(address(manager)).getLiquidity(key.toId()), liquidity);
    }

    function test_failedForwardPreservesClaimsAndSwapsRemainLive() public {
        RefusingETH recipient = new RefusingETH();
        vm.prank(owner);
        hook.setTreasury(address(recipient));
        _swapAs(trader, key, true, -1 ether, 1 ether);
        vm.expectRevert();
        hook.forwardFees();
        assertEq(hook.pendingFees(), 0.01 ether);
        assertEq(hook.totalFeesForwarded(), 0);
        _swapAs(trader, key, true, -1 ether, 1 ether);
        assertEq(hook.pendingFees(), 0.02 ether);
    }

    function test_unconfiguredForwardAndEmptyClaims() public {
        vm.expectRevert(DaemonHook.TreasuryNotConfigured.selector);
        hook.forwardFees();
        vm.prank(owner);
        hook.setTreasury(address(treasury));
        vm.expectRevert(DaemonHook.NothingToForward.selector);
        hook.forwardFees();
    }

    function test_ownerCannotRedirectFeesAfterSetup() public {
        vm.prank(owner);
        hook.setTreasury(address(treasury));
        vm.startPrank(owner);
        vm.expectRevert(DaemonHook.TreasuryAlreadyConfigured.selector);
        hook.setTreasury(address(manager));
        hook.transferOwnership(stranger);
        vm.stopPrank();
        vm.startPrank(stranger);
        hook.acceptOwnership();
        vm.expectRevert(DaemonHook.TreasuryAlreadyConfigured.selector);
        hook.setTreasury(address(manager));
        vm.stopPrank();
    }

    function test_lpFeesRemainIndependent() public {
        (,,, uint24 lpFee) = IPoolManager(address(manager)).getSlot0(key.toId());
        (uint256 g0, uint256 g1) = IPoolManager(address(manager)).getFeeGrowthGlobals(key.toId());
        _swapAs(trader, key, true, -1 ether, 1 ether);
        (uint256 a0, uint256 a1) = IPoolManager(address(manager)).getFeeGrowthGlobals(key.toId());
        assertEq(lpFee, LP_FEE);
        assertGt(a0, g0);
        assertEq(a1, g1);
        assertEq(hook.pendingFees(), 0.01 ether);
    }

    function test_nativeTokenOnlySeedOnEmptyManager() public {
        _deployCore();
        key = _key(address(0));
        vm.prank(factory);
        manager.initialize(key, SQRT_PRICE_1_1);
        _approveAll(factory, address(daemon));
        vm.prank(factory);
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(-10000, 0, 1_000_000 ether, 0), "");
        assertEq(address(manager).balance, 0);
        _swapAs(trader, key, true, -1 ether, 1 ether);
        assertEq(hook.pendingFees(), 0.01 ether);
        _approveAll(trader, address(daemon));
        _swapAs(trader, key, false, -int256(daemon.balanceOf(trader) / 2), 0);
        assertGt(hook.pendingFees(), 0.01 ether);
    }

    function test_specifiedETHPartialFillRevertsWithoutCharging() public {
        vm.prank(trader);
        vm.expectRevert();
        swapRouter.swap{value: 100 ether}(
            key,
            SwapParams(true, -100 ether, TickMath.getSqrtPriceAtTick(-1)),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertEq(hook.pendingFees(), 0);
    }

    function test_insufficientETHSettlementRollsBackFeeClaims() public {
        uint256 tokens = daemon.balanceOf(trader);
        vm.expectRevert();
        _swapAs(trader, key, true, -1 ether, 0);
        assertEq(hook.pendingFees(), 0);
        assertEq(hook.totalFeesCharged(), 0);
        assertEq(daemon.balanceOf(trader), tokens);
    }

    function test_unspecifiedETHPartialFillChargesOnlyActualOutput() public {
        uint256 beforeETH = trader.balance;
        uint256 beforeToken = daemon.balanceOf(trader);
        vm.prank(trader);
        swapRouter.swap(
            key,
            SwapParams(false, -100 ether, TickMath.getSqrtPriceAtTick(1)),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        assertLt(beforeToken - daemon.balanceOf(trader), 100 ether);
        uint256 fee = hook.pendingFees();
        assertEq(fee, (trader.balance - beforeETH + fee) / 100);
    }

    function test_reverseNativeOrderRejectedByRealPoolManager() public {
        _deployCore();
        PoolKey memory reverse = PoolKey(
            Currency.wrap(address(daemon)), Currency.wrap(address(0)), LP_FEE, TICK_SPACING, IHooks(address(hook))
        );
        vm.prank(factory);
        vm.expectRevert();
        manager.initialize(reverse, SQRT_PRICE_1_1);
    }

    function test_nonNativePoolRejected() public {
        _deployCore();
        PoolKey memory other = _key(address(_pairToken(true)));
        vm.prank(factory);
        vm.expectRevert();
        manager.initialize(other, SQRT_PRICE_1_1);
    }

    function test_onlyFactoryOnePoolAndCallbackAuthentication() public {
        vm.prank(stranger);
        vm.expectRevert(DaemonHook.NotPoolManager.selector);
        hook.beforeSwap(trader, key, SwapParams(true, -1 ether, 1), "");
        vm.prank(stranger);
        vm.expectRevert(DaemonHook.NotOwner.selector);
        hook.setTreasury(address(treasury));
        vm.prank(address(manager));
        vm.expectRevert(DaemonHook.PoolAlreadyInitialized.selector);
        hook.beforeInitialize(factory, key, SQRT_PRICE_1_1);
        _deployCore();
        key = _key(address(0));
        vm.prank(stranger);
        vm.expectRevert();
        manager.initialize(key, SQRT_PRICE_1_1);
    }

    function test_permissionsAndBounds() public {
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.beforeInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta && p.afterSwapReturnDelta
        );
        assertFalse(p.beforeRemoveLiquidity || p.afterRemoveLiquidity || p.beforeAddLiquidity || p.afterAddLiquidity);
        vm.startPrank(address(manager));
        vm.expectRevert(DaemonHook.AmountTooLarge.selector);
        hook.beforeSwap(trader, key, SwapParams(true, type(int256).min, 1), "");
        vm.expectRevert(DaemonHook.AmountTooLarge.selector);
        hook.beforeSwap(trader, key, SwapParams(false, type(int256).max, 1), "");
        vm.stopPrank();
    }
}

/// @dev Deliberately synthetic manager, to test callback math in both currency orderings. Native ETH
/// sorts first in a real v4 pool; the real-manager rejection above prevents misrepresenting that case.
contract ClaimAccountingMock {
    uint256 public minted;
    uint256 public currencyId;

    function mint(address, uint256 id, uint256 amount) external {
        minted += amount;
        currencyId = id;
    }
}

contract HookOrderMatrixTest is Fixture {
    using BeforeSwapDeltaLibrary for BeforeSwapDelta;

    function testFuzz_bothOrdersDirectionsAndExactModes(bool ethZero, bool buy, bool exactInput, uint64 raw) public {
        ClaimAccountingMock mock = new ClaimAccountingMock();
        DaemonHook h = DaemonHook(
            HookDeployer.deploy(
                abi.encodePacked(
                    type(DaemonHook).creationCode, abi.encode(address(mock), owner, factory, address(0x1234))
                ),
                FLAGS
            )
        );
        PoolKey memory k = PoolKey(
            Currency.wrap(ethZero ? address(0) : address(0x1234)),
            Currency.wrap(ethZero ? address(0x1234) : address(0)),
            LP_FEE,
            TICK_SPACING,
            IHooks(address(h))
        );
        uint256 amount = bound(raw, 1, 1e18);
        SwapParams memory sp = SwapParams(buy == ethZero, exactInput ? -int256(amount) : int256(amount), 1);
        vm.startPrank(address(mock));
        h.beforeInitialize(factory, k, SQRT_PRICE_1_1);
        {
            (, BeforeSwapDelta bd, uint24 overrideFee) = h.beforeSwap(trader, k, sp, "");
            assertEq(bd.getSpecifiedDelta(), buy == exactInput ? int128(int256(amount / 100)) : int128(0));
            assertEq(overrideFee, 0);
        }
        (, int128 ad) = h.afterSwap(trader, k, sp, _delta(ethZero, buy, exactInput, amount), "");
        vm.stopPrank();
        assertEq(ad, buy == exactInput ? int128(0) : int128(int256(amount / 100)));
        assertEq(mock.minted(), amount / 100);
        assertEq(mock.currencyId(), 0);
    }

    function test_matrixETH0BuyExactInput() public {
        testFuzz_bothOrdersDirectionsAndExactModes(true, true, true, 12345);
    }

    function test_matrixETH0BuyExactOutput() public {
        testFuzz_bothOrdersDirectionsAndExactModes(true, true, false, 12345);
    }

    function test_matrixETH0SellExactInput() public {
        testFuzz_bothOrdersDirectionsAndExactModes(true, false, true, 12345);
    }

    function test_matrixETH0SellExactOutput() public {
        testFuzz_bothOrdersDirectionsAndExactModes(true, false, false, 12345);
    }

    function test_matrixETH1BuyExactInput() public {
        testFuzz_bothOrdersDirectionsAndExactModes(false, true, true, 12345);
    }

    function test_matrixETH1BuyExactOutput() public {
        testFuzz_bothOrdersDirectionsAndExactModes(false, true, false, 12345);
    }

    function test_matrixETH1SellExactInput() public {
        testFuzz_bothOrdersDirectionsAndExactModes(false, false, true, 12345);
    }

    function test_matrixETH1SellExactOutput() public {
        testFuzz_bothOrdersDirectionsAndExactModes(false, false, false, 12345);
    }

    function _delta(bool ethZero, bool buy, bool exactInput, uint256 amount) private pure returns (BalanceDelta) {
        bool ethSpecified = buy == exactInput;
        uint256 fee = amount / 100;
        int128 poolETH = buy
            ? -int128(int256(ethSpecified ? amount - fee : amount))
            : int128(int256(ethSpecified ? amount + fee : amount));
        int128 poolToken = buy ? int128(1000) : -int128(1000);
        return ethZero ? toBalanceDelta(poolETH, poolToken) : toBalanceDelta(poolToken, poolETH);
    }
}
