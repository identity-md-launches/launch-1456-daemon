// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {GameRewards} from "../src/GameRewards.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

contract GameRewardsTest is Test {
    MockERC20 daemon;
    MockERC721 identity;
    GameRewards game;

    address owner = makeAddr("owner");
    address arbiter = makeAddr("arbiter");
    address alice = makeAddr("alice"); // NFT 1
    address bob = makeAddr("bob"); // NFT 2
    address carol = makeAddr("carol"); // NFT 3
    address founder = makeAddr("founder"); // NFT 222
    address stranger = makeAddr("stranger");

    function setUp() public {
        daemon = new MockERC20("DAEMON", "DAEMON", 0);
        identity = new MockERC721();
        game = new GameRewards(ERC20(address(daemon)), owner);
        daemon.mint(address(game), 40_000_000e18);
        identity.mint(alice, 1);
        identity.mint(bob, 2);
        identity.mint(carol, 3);
        identity.mint(founder, 222);
        vm.startPrank(owner);
        game.setIdentityNft(address(identity));
        game.setArbiter(arbiter);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ registration / authentication

    function test_registerRequiresNftOwnership() public {
        vm.prank(stranger);
        vm.expectRevert(abi.encodeWithSelector(GameRewards.NotNftOwner.selector, 1, stranger));
        game.register(1);
    }

    function test_registerRequiresConfiguredNft() public {
        GameRewards fresh = new GameRewards(ERC20(address(daemon)), owner);
        vm.prank(alice);
        vm.expectRevert(GameRewards.NotConfigured.selector);
        fresh.register(1);
    }

    function test_oneWalletOneNft() public {
        identity.mint(alice, 9);
        vm.startPrank(alice);
        game.register(1);
        vm.expectRevert(abi.encodeWithSelector(GameRewards.WalletAlreadyRegistered.selector, alice, 1));
        game.register(9);
        vm.expectRevert(abi.encodeWithSelector(GameRewards.AlreadyRegistered.selector, 1));
        game.register(1);
        vm.stopPrank();
    }

    // ------------------------------------------------------------------ winner stays ladder

    function _seatTwo() internal {
        vm.prank(alice);
        game.register(1);
        assertEq(game.champion(), 1, "first agent takes the empty seat");
        assertEq(game.challenger(), 0);
        vm.prank(bob);
        game.register(2);
        assertEq(game.challenger(), 2, "second agent becomes the challenger");
    }

    function test_winnerStaysLoserLeavesNextIsSeated() public {
        _seatTwo();
        vm.prank(carol);
        game.register(3);
        assertEq(game.waitingCount(), 1);

        vm.prank(arbiter);
        game.reportResult(2, 1, false);
        assertEq(game.champion(), 2, "winner stays");
        assertEq(game.challenger(), 3, "next in queue is seated");
        (, bool reg, bool seated,,,,) = game.agents(1);
        assertTrue(reg);
        assertFalse(seated, "loser leaves");

        vm.prank(arbiter);
        game.reportResult(2, 3, false);
        assertEq(game.champion(), 2);
        assertEq(game.challenger(), 0, "nobody left to face the champion");
        (,,,,,, uint256 testWins) = game.agents(2);
        assertEq(testWins, 2, "before the season these are test scores");
    }

    function test_drawReturnsBothToQueueAndEndsStreaks() public {
        _seatTwo();
        vm.prank(arbiter);
        game.reportResult(1, 2, true);
        assertEq(game.champion(), 1, "re-queued in order and re-seated");
        assertEq(game.challenger(), 2);
    }

    function test_onlyArbiterReportsAndOnlySeatedAgents() public {
        _seatTwo();
        vm.prank(stranger);
        vm.expectRevert(GameRewards.NotArbiter.selector);
        game.reportResult(1, 2, false);
        vm.prank(carol);
        game.register(3);
        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(GameRewards.NotInMatch.selector, 3));
        game.reportResult(3, 1, false);
        vm.prank(arbiter);
        vm.expectRevert(abi.encodeWithSelector(GameRewards.NotInMatch.selector, 1));
        game.reportResult(1, 1, false);
    }

    function test_noMatchInProgress() public {
        vm.prank(alice);
        game.register(1);
        vm.prank(arbiter);
        vm.expectRevert(GameRewards.NoMatchInProgress.selector);
        game.reportResult(1, 2, false);
    }

    // ------------------------------------------------------------------ official season vs test scores

    function test_officialSeasonIsFourWeeksAndTestScoresAreExcluded() public {
        _seatTwo();
        vm.prank(arbiter);
        game.reportResult(1, 2, false); // test score
        (,,, uint256 wins, uint256 streak,,) = game.agents(1);
        assertEq(wins, 0);
        assertEq(streak, 0);

        uint256 start = block.timestamp + 1 days;
        vm.prank(owner);
        game.setSeasonStart(start);
        vm.prank(owner);
        vm.expectRevert(GameRewards.SeasonAlreadyStarted.selector);
        game.setSeasonStart(start + 1);

        vm.warp(start);
        assertTrue(game.isOfficial());
        vm.prank(bob);
        vm.expectRevert(abi.encodeWithSelector(GameRewards.AlreadyRegistered.selector, 2));
        game.register(2);
        vm.prank(carol);
        game.register(3);
        vm.prank(arbiter);
        game.reportResult(1, 3, false);
        (,,, wins, streak,,) = game.agents(1);
        assertEq(wins, 1);
        assertEq(streak, 1);

        vm.warp(start + 4 weeks);
        assertFalse(game.isOfficial(), "season over after four weeks");
    }

    function test_seasonStartMustBeInTheFuture() public {
        vm.prank(owner);
        vm.expectRevert(GameRewards.SeasonInPast.selector);
        game.setSeasonStart(block.timestamp);
    }

    // ------------------------------------------------------------------ prizes

    function test_prizesInactiveDuringTrial() public {
        assertFalse(game.prizesActive());
        vm.prank(owner);
        vm.expectRevert(GameRewards.PrizesInactive.selector);
        game.awardPrize(1, 1e18);
    }

    function test_prizePaidToCurrentNftOwnerOnceActive() public {
        vm.startPrank(owner);
        game.setPrizesActive(true);
        game.awardPrize(1, 5e18);
        vm.stopPrank();
        assertEq(daemon.balanceOf(alice), 5e18);
        assertEq(game.totalPrizesPaid(), 5e18);
    }

    function test_founderNft222NeverReceivesAPrize() public {
        vm.startPrank(owner);
        game.setPrizesActive(true);
        vm.expectRevert(abi.encodeWithSelector(GameRewards.ExcludedFromPrizes.selector, 222));
        game.awardPrize(222, 1e18);
        vm.stopPrank();
        assertEq(daemon.balanceOf(founder), 0);
    }

    function test_onlyOwnerAwardsAndConfigures() public {
        vm.startPrank(stranger);
        vm.expectRevert(GameRewards.NotOwner.selector);
        game.awardPrize(1, 1);
        vm.expectRevert(GameRewards.NotOwner.selector);
        game.setPrizesActive(true);
        vm.expectRevert(GameRewards.NotOwner.selector);
        game.setArbiter(stranger);
        vm.expectRevert(GameRewards.NotOwner.selector);
        game.setIdentityNft(stranger);
        vm.expectRevert(GameRewards.NotOwner.selector);
        game.setSeasonStart(block.timestamp + 1);
        vm.expectRevert(GameRewards.NotOwner.selector);
        game.withdrawEth(stranger, 0);
        vm.stopPrank();
    }

    function test_receivesCreatorFeeShareInEth() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(game).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(game).balance, 1 ether);
        vm.prank(owner);
        game.withdrawEth(owner, 0.4 ether);
        assertEq(owner.balance, 0.4 ether);
    }
}
