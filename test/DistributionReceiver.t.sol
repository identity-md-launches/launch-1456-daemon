// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {DaemonToken} from "../src/DaemonToken.sol";
import {DistributionReceiver} from "../src/DistributionReceiver.sol";
import {GameRewards} from "../src/GameRewards.sol";

contract DistributionReceiverTest is Test {
    DaemonToken daemon;
    DistributionReceiver receiver;
    GameRewards game;

    address factory = makeAddr("factory");
    address owner = makeAddr("owner");
    address development = makeAddr("development");
    address founder = makeAddr("founder");
    address stranger = makeAddr("stranger");

    uint256 constant REMAINDER = 70_000_000e18; // 7% of 1e9

    function setUp() public {
        vm.prank(factory);
        daemon = new DaemonToken();
        receiver = new DistributionReceiver(ERC20(address(daemon)), owner);
        game = new GameRewards(ERC20(address(daemon)), owner);
    }

    function _configure() internal {
        vm.prank(owner);
        receiver.setRecipients(address(game), development, founder);
    }

    function test_splitsTheSevenPercentRemainder() public {
        _configure();
        vm.prank(factory);
        daemon.transfer(address(receiver), REMAINDER);
        vm.prank(stranger); // anyone may trigger
        (uint256 g, uint256 d, uint256 f) = receiver.distribute();
        assertEq(g, 40_000_000e18, "4% game rewards");
        assertEq(d, 10_000_000e18, "1% development");
        assertEq(f, 20_000_000e18, "2% founder, unlocked");
        assertEq(daemon.balanceOf(address(game)), g);
        assertEq(daemon.balanceOf(development), d);
        assertEq(daemon.balanceOf(founder), f);
        assertEq(daemon.balanceOf(address(receiver)), 0);
        assertEq(daemon.totalSupply(), 1_000_000_000e18, "no mint, no burn");
    }

    function test_revertsUntilConfigured() public {
        vm.prank(factory);
        daemon.transfer(address(receiver), REMAINDER);
        assertFalse(receiver.configured());
        vm.expectRevert(DistributionReceiver.RecipientsNotConfigured.selector);
        receiver.distribute();
    }

    function test_revertsWithNothingToDistribute() public {
        _configure();
        vm.expectRevert(DistributionReceiver.NothingToDistribute.selector);
        receiver.distribute();
    }

    function test_onlyOwnerSetsRecipientsAndRejectsZero() public {
        vm.prank(stranger);
        vm.expectRevert(DistributionReceiver.NotOwner.selector);
        receiver.setRecipients(address(game), development, founder);
        vm.prank(owner);
        vm.expectRevert(DistributionReceiver.ZeroAddress.selector);
        receiver.setRecipients(address(game), address(0), founder);
    }

    function testFuzz_conservesEveryWei(uint256 amount) public {
        amount = bound(amount, 1, 70_000_000e18);
        _configure();
        vm.prank(factory);
        daemon.transfer(address(receiver), amount);
        (uint256 g, uint256 d, uint256 f) = receiver.distribute();
        assertEq(g + d + f, amount);
        assertEq(g, amount * 4 / 7);
        assertEq(d, amount * 1 / 7);
        assertLe(f - amount * 2 / 7, 2, "dust goes to the founder");
    }

    function test_partialTransfersDistributeSeparately() public {
        _configure();
        vm.startPrank(factory);
        daemon.transfer(address(receiver), 7e18);
        receiver.distribute();
        daemon.transfer(address(receiver), 14e18);
        receiver.distribute();
        vm.stopPrank();
        assertEq(receiver.distributedToGame(), 12e18);
        assertEq(receiver.distributedToDevelopment(), 3e18);
        assertEq(receiver.distributedToFounder(), 6e18);
    }
}
