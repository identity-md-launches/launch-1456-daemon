// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {Deploy} from "../script/Deploy.s.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @notice Calls the deploy function directly with an explicit config (no environment, no broadcast).
contract DeployTest is Test {
    uint160 constant SQRT_PRICE_1_1 = 79228162514264337593543950336;

    function test_deployWiresEverythingAndFactoryCanOpenThePool() public {
        PoolManager manager = new PoolManager(address(this));
        address owner = makeAddr("owner");
        address factory = makeAddr("factory");
        Deploy script = new Deploy();

        Deploy.Deployed memory d = script.deploy(
            Deploy.Config({
                poolManager: IPoolManager(address(manager)),
                owner: owner,
                factory: factory,
                token: address(0),
                create2Deployer: address(script)
            })
        );

        assertEq(d.token.balanceOf(address(script)), 1_000_000_000e18, "token minted to its deployer");
        assertEq(HookFlags.flagsOf(address(d.hook)), script.HOOK_FLAGS());
        assertEq(d.hook.owner(), owner);
        assertEq(d.hook.factory(), factory);
        assertEq(d.hook.daemon(), address(d.token));
        assertEq(d.treasury.owner(), owner);
        assertEq(d.gameRewards.owner(), owner);
        assertEq(d.receiver.owner(), owner);
        assertEq(d.hook.treasury(), address(0), "owner wires the treasury after launch");

        // The factory can open the launch pool (native pair, launch tier fee).
        PoolKey memory key =
            PoolKey(Currency.wrap(address(0)), Currency.wrap(address(d.token)), 12_500, 100, IHooks(address(d.hook)));
        vm.prank(factory);
        manager.initialize(key, SQRT_PRICE_1_1);
        assertTrue(d.hook.poolInitialized());

        // Post-launch owner steps.
        vm.startPrank(owner);
        d.hook.setTreasury(address(d.treasury));
        d.receiver.setRecipients(address(d.gameRewards), makeAddr("dev"), makeAddr("founder"));
        vm.stopPrank();
        assertTrue(d.receiver.configured());
    }

    function test_deployRejectsZeroConfig() public {
        Deploy script = new Deploy();
        vm.expectRevert(Deploy.ZeroAddress.selector);
        script.deploy(
            Deploy.Config({
                poolManager: IPoolManager(address(0)),
                owner: address(1),
                factory: address(1),
                token: address(0),
                create2Deployer: address(script)
            })
        );
    }
}
