// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams, SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {PoolModifyLiquidityTest} from "v4-core/src/test/PoolModifyLiquidityTest.sol";
import {DaemonHook} from "../../src/DaemonHook.sol";
import {DaemonToken} from "../../src/DaemonToken.sol";
import {NFTTreasury} from "../../src/NFTTreasury.sol";
import {HookFlags} from "../../src/HookFlags.sol";
import {HookDeployer} from "./HookDeployer.sol";
import {MockERC20} from "../mocks/MockERC20.sol";

/// @notice Shared fixture: a fresh PoolManager, the DAEMON token deployed by a stand-in factory, the hook mined
/// onto a flag-matching address, a pair currency on the requested side of DAEMON, and v4-core's test routers.
abstract contract Fixture is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;
    uint24 constant LP_FEE = 12_500; // the launch tier
    int24 constant TICK_SPACING = 100;
    uint160 constant FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;

    address factory = makeAddr("factory");
    address owner = makeAddr("owner");
    address trader = makeAddr("trader");
    address stranger = makeAddr("stranger");

    PoolManager manager;
    DaemonToken daemon;
    DaemonHook hook;
    NFTTreasury treasury;
    PoolSwapTest swapRouter;
    PoolModifyLiquidityTest lpRouter;

    function _deployCore() internal {
        manager = new PoolManager(address(this));
        vm.prank(factory);
        daemon = new DaemonToken();
        swapRouter = new PoolSwapTest(IPoolManager(address(manager)));
        lpRouter = new PoolModifyLiquidityTest(IPoolManager(address(manager)));
        hook = DaemonHook(
            HookDeployer.deploy(
                abi.encodePacked(
                    type(DaemonHook).creationCode, abi.encode(address(manager), owner, factory, address(daemon))
                ),
                FLAGS
            )
        );
        treasury = new NFTTreasury(daemon, owner);
    }

    /// @dev Places a mock ERC-20 immediately below or above DAEMON's address so the token order is chosen,
    /// not left to chance.
    function _pairToken(bool below) internal returns (MockERC20 pair) {
        address target = below ? address(uint160(address(daemon)) - 1) : address(uint160(address(daemon)) + 1);
        vm.etch(target, address(new MockERC20("PAIR", "PAIR", 0)).code);
        vm.label(target, below ? "pairBelow" : "pairAbove");
        pair = MockERC20(target);
    }

    function _key(address pair) internal view returns (PoolKey memory key) {
        (address c0, address c1) = pair < address(daemon) ? (pair, address(daemon)) : (address(daemon), pair);
        key = PoolKey({
            currency0: Currency.wrap(c0),
            currency1: Currency.wrap(c1),
            fee: LP_FEE,
            tickSpacing: TICK_SPACING,
            hooks: IHooks(address(hook))
        });
    }

    function _approveAll(address who, address token) internal {
        vm.startPrank(who);
        MockERC20(token).approve(address(swapRouter), type(uint256).max);
        MockERC20(token).approve(address(lpRouter), type(uint256).max);
        vm.stopPrank();
    }

    /// @dev Factory opens the pool and seeds full-range liquidity with DAEMON and the ERC-20 pair.
    function _openAndSeed(PoolKey memory key, MockERC20 pair, uint256 pairAmount) internal {
        vm.prank(factory);
        manager.initialize(key, SQRT_PRICE_1_1);
        pair.mint(factory, pairAmount);
        _approveAll(factory, address(daemon));
        _approveAll(factory, address(pair));
        int24 lower = TickMath.minUsableTick(TICK_SPACING);
        int24 upper = TickMath.maxUsableTick(TICK_SPACING);
        vm.prank(factory);
        lpRouter.modifyLiquidity(key, ModifyLiquidityParams(lower, upper, int256(pairAmount), bytes32(0)), "");
    }

    function _fund(address who, MockERC20 pair, uint256 amount) internal {
        pair.mint(who, amount);
        vm.prank(factory);
        daemon.transfer(who, amount);
        _approveAll(who, address(daemon));
        _approveAll(who, address(pair));
    }

    function _swap(PoolKey memory key, bool zeroForOne, int256 amountSpecified) internal returns (BalanceDelta) {
        return _swapAs(trader, key, zeroForOne, amountSpecified, 0);
    }

    function _swapAs(address who, PoolKey memory key, bool zeroForOne, int256 amountSpecified, uint256 value)
        internal
        returns (BalanceDelta delta)
    {
        uint160 limit = zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        vm.prank(who);
        delta = swapRouter.swap{value: value}(
            key, SwapParams(zeroForOne, amountSpecified, limit), PoolSwapTest.TestSettings(false, false), ""
        );
    }

    function _daemonIsZero(PoolKey memory key) internal view returns (bool) {
        return Currency.unwrap(key.currency0) == address(daemon);
    }
}
