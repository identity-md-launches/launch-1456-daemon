// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {NFTTreasury} from "../src/NFTTreasury.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {GameRewards} from "../src/GameRewards.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC721} from "./mocks/MockERC721.sol";

contract GameRewardsTest is Test {
    MockERC20 daemon;
    MockERC721 identity;
    GameRewards game;
    NFTTreasury treasury;
    address authorizer = makeAddr("authorizer");

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
        vm.deal(address(game), 10 ether);
        treasury = new NFTTreasury(daemon, owner);
        PoolManager manager = new PoolManager(address(this));
        vm.prank(owner);
        treasury.sealPolicy(address(game), IPoolManager(address(manager)));
        identity.mint(alice, 1);
        identity.mint(bob, 2);
        identity.mint(carol, 3);
        identity.mint(founder, 222);
        vm.startPrank(owner);
        game.setIdentityNft(address(identity));
        game.setArbiter(arbiter);
        game.setRewardAuthority(authorizer, treasury);
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
        game.configureSeason(start, start + 5 weeks, 100 ether, 2 ether, 2, keccak256("published season rules"));
        vm.prank(owner);
        vm.expectRevert(GameRewards.SeasonAlreadyStarted.selector);
        game.configureSeason(start + 1, start + 5 weeks, 100 ether, 2 ether, 2, keccak256("changed"));

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
        game.configureSeason(block.timestamp, block.timestamp + 5 weeks, 100 ether, 2 ether, 2, keccak256("rules"));
    }

    // ------------------------------------------------------------------ prizes

    function _finishSeason(uint256 winner, uint256 loser) internal {
        vm.prank(identity.ownerOf(winner));
        game.register(winner);
        vm.prank(identity.ownerOf(loser));
        game.register(loser);
        uint256 start = block.timestamp + 1 days;
        vm.prank(owner);
        game.configureSeason(start, start + 5 weeks, 100 ether, 2 ether, 2, keccak256("published season rules"));
        vm.warp(start);
        vm.prank(arbiter);
        game.reportResult(winner, loser, false);
        vm.warp(start + 4 weeks);
    }

    function _allocation(uint256 id) internal pure returns (GameRewards.Allocation[] memory awards) {
        awards = new GameRewards.Allocation[](1);
        awards[0] = GameRewards.Allocation(id, 5 ether, 1 ether, address(0), 0, false);
    }

    function _publish(GameRewards.Allocation[] memory awards) internal {
        vm.prank(authorizer);
        game.publishAllocations(awards, keccak256("public results and allocation document"));
    }

    function test_prizesInactiveDuringTrial() public {
        assertFalse(game.prizesActive());
        vm.expectRevert(GameRewards.PrizesInactive.selector);
        game.claimReward(1);
    }

    function test_seasonTokenAndETHClaimAndDuplicateProtection() public {
        _finishSeason(1, 2);
        _publish(_allocation(1));
        vm.prank(stranger);
        game.claimReward(1);
        assertEq(daemon.balanceOf(alice), 5 ether);
        assertEq(alice.balance, 1 ether);
        assertEq(game.totalPrizesPaid(), 5 ether);
        vm.expectRevert(GameRewards.AlreadyClaimed.selector);
        game.claimReward(1);
    }

    function test_identityTransferCannotRedirectSnapshotRecipient() public {
        _finishSeason(1, 2);
        _publish(_allocation(1));
        vm.prank(alice);
        identity.transferFrom(alice, stranger, 1);
        game.claimReward(1);
        assertEq(daemon.balanceOf(alice), 5 ether);
        assertEq(daemon.balanceOf(stranger), 0);
    }

    function test_founderNFT222ExcludedEvenWithOfficialWin() public {
        _finishSeason(222, 1);
        vm.expectRevert(abi.encodeWithSelector(GameRewards.ExcludedFromPrizes.selector, 222));
        _publish(_allocation(222));
        assertEq(daemon.balanceOf(founder), 0);
    }

    function test_prizeNFT222ExcludedAndNoArbitraryTransfer() public {
        _finishSeason(1, 2);
        MockERC721 prizes = new MockERC721();
        prizes.mint(address(game), 222);
        GameRewards.Allocation[] memory a = _allocation(1);
        a[0].collection = address(prizes);
        a[0].prizeTokenId = 222;
        vm.expectRevert(abi.encodeWithSelector(GameRewards.ExcludedFromPrizes.selector, 222));
        _publish(a);
        assertEq(prizes.ownerOf(222), address(game));
    }

    function test_NFTPrizeFromTreasuryAuthorizedOnlyByPublishedClaim() public {
        _finishSeason(1, 2);
        MockERC721 prizes = new MockERC721();
        prizes.mint(address(treasury), 50);
        GameRewards.Allocation[] memory a = _allocation(1);
        a[0].collection = address(prizes);
        a[0].prizeTokenId = 50;
        a[0].fromTreasury = true;
        _publish(a);
        vm.prank(owner);
        vm.expectRevert(NFTTreasury.NotGameRewards.selector);
        treasury.deliverPrize(address(prizes), 50, owner);
        game.claimReward(1);
        assertEq(prizes.ownerOf(50), alice);
        vm.expectRevert(GameRewards.AlreadyClaimed.selector);
        game.claimReward(1);
    }

    function test_NFTPrizeHeldByGame() public {
        _finishSeason(1, 2);
        MockERC721 prizes = new MockERC721();
        prizes.mint(address(game), 51);
        GameRewards.Allocation[] memory a = _allocation(1);
        a[0].collection = address(prizes);
        a[0].prizeTokenId = 51;
        _publish(a);
        game.claimReward(1);
        assertEq(prizes.ownerOf(51), alice);
    }

    function test_duplicateAllocationsAndOverBudgetRevertAtomically() public {
        _finishSeason(1, 2);
        GameRewards.Allocation[] memory a = new GameRewards.Allocation[](2);
        a[0] = _allocation(1)[0];
        a[1] = a[0];
        vm.expectRevert(GameRewards.DuplicateAllocation.selector);
        _publish(a);
        assertFalse(game.allocationsPublished());
        a = _allocation(1);
        a[0].tokenAmount = 101 ether;
        vm.expectRevert(GameRewards.BudgetExceeded.selector);
        _publish(a);
        a[0].tokenAmount = 1 ether;
        a[0].ethAmount = 3 ether;
        vm.expectRevert(GameRewards.BudgetExceeded.selector);
        _publish(a);
    }

    function test_onlyOfficialWinnersCanReceiveAllocations() public {
        _finishSeason(1, 2);
        vm.expectRevert(GameRewards.IneligibleWinner.selector);
        _publish(_allocation(2));
        vm.expectRevert(GameRewards.IneligibleWinner.selector);
        _publish(_allocation(999));
    }

    function test_ownerCannotPublishOrChangeRolesAndBudgets() public {
        _finishSeason(1, 2);
        vm.startPrank(owner);
        vm.expectRevert(GameRewards.NotRewardAuthorizer.selector);
        game.publishAllocations(_allocation(1), keccak256("fake"));
        vm.expectRevert(GameRewards.ConfigurationLocked.selector);
        game.setIdentityNft(address(identity));
        vm.expectRevert(GameRewards.ConfigurationLocked.selector);
        game.setArbiter(owner);
        vm.expectRevert(GameRewards.ConfigurationLocked.selector);
        game.setRewardAuthority(owner, treasury);
        vm.expectRevert(GameRewards.SeasonAlreadyStarted.selector);
        game.configureSeason(
            block.timestamp + 1 days, block.timestamp + 5 weeks, 1000 ether, 2 ether, 2, keccak256("changed")
        );
        vm.stopPrank();
        _publish(_allocation(1));
        vm.expectRevert(GameRewards.AlreadyPublished.selector);
        _publish(_allocation(1));
    }

    function test_claimWindowAndPublicationTiming() public {
        _finishSeason(1, 2);
        uint256 end = block.timestamp;
        vm.warp(end - 1);
        vm.expectRevert(GameRewards.OutsideClaimWindow.selector);
        _publish(_allocation(1));
        vm.warp(end);
        _publish(_allocation(1));
        vm.warp(game.claimDeadline() + 1);
        vm.expectRevert(GameRewards.OutsideClaimWindow.selector);
        game.claimReward(1);
    }

    function test_removedWithdrawalsAndArbitraryAwardFailEvenForOwner() public {
        vm.startPrank(owner);
        (bool a,) = address(game).call(abi.encodeWithSignature("withdrawEth(address,uint256)", owner, 1 ether));
        (bool b,) = address(game)
            .call(abi.encodeWithSignature("withdrawTokens(address,address,uint256)", address(daemon), owner, 1 ether));
        (bool c,) = address(game)
            .call(abi.encodeWithSignature("withdrawNFT(address,uint256,address)", address(identity), 1, owner));
        (bool d,) = address(game).call(abi.encodeWithSignature("awardPrize(uint256,uint256)", 1, 1 ether));
        vm.stopPrank();
        assertFalse(a || b || c || d);
    }

    function test_zeroAgentCannotCorruptSeatSentinel() public {
        identity.mint(alice, 0);
        vm.prank(alice);
        vm.expectRevert(GameRewards.InvalidAgent.selector);
        game.register(0);
    }

    function test_ownershipChangeCannotRewriteSeasonRolesOrRecipients() public {
        _finishSeason(1, 2);
        _publish(_allocation(1));
        vm.prank(owner);
        game.transferOwnership(stranger);
        vm.startPrank(stranger);
        game.acceptOwnership();
        vm.expectRevert(GameRewards.ConfigurationLocked.selector);
        game.setRewardAuthority(stranger, treasury);
        vm.expectRevert(GameRewards.ConfigurationLocked.selector);
        game.setArbiter(stranger);
        vm.expectRevert(GameRewards.ConfigurationLocked.selector);
        game.setIdentityNft(address(identity));
        vm.expectRevert(GameRewards.SeasonAlreadyStarted.selector);
        game.configureSeason(
            block.timestamp + 1, block.timestamp + 5 weeks, 1000 ether, 10 ether, 128, keccak256("changed")
        );
        game.claimReward(1);
        vm.stopPrank();
        assertEq(daemon.balanceOf(alice), 5 ether);
        assertEq(daemon.balanceOf(stranger), 0);
    }

    function test_sameNFTCannotBeAllocatedToTwoWinners() public {
        _seatTwo();
        vm.prank(carol);
        game.register(3);
        uint256 start = block.timestamp + 1 days;
        vm.prank(owner);
        game.configureSeason(start, start + 5 weeks, 100 ether, 2 ether, 2, keccak256("rules"));
        vm.warp(start);
        vm.startPrank(arbiter);
        game.reportResult(1, 2, false);
        game.reportResult(3, 1, false);
        vm.stopPrank();
        vm.warp(start + 4 weeks);
        MockERC721 prize = new MockERC721();
        prize.mint(address(game), 70);
        GameRewards.Allocation[] memory a = new GameRewards.Allocation[](2);
        a[0] = GameRewards.Allocation(1, 1 ether, 0, address(prize), 70, false);
        a[1] = GameRewards.Allocation(3, 1 ether, 0, address(prize), 70, false);
        vm.expectRevert(GameRewards.DuplicateAllocation.selector);
        _publish(a);
        assertFalse(game.allocationsPublished());
    }

    function test_failedReceiverRollsBackEveryAssetAndCanRetryWithoutDuplicate() public {
        RewardReceiver receiver = new RewardReceiver();
        identity.mint(address(receiver), 4);
        _finishSeason(4, 2);
        MockERC721 prizes = new MockERC721();
        prizes.mint(address(treasury), 60);
        GameRewards.Allocation[] memory a = _allocation(4);
        a[0].collection = address(prizes);
        a[0].prizeTokenId = 60;
        a[0].fromTreasury = true;
        _publish(a);
        receiver.configure(game, 4, true, false);
        vm.expectRevert();
        game.claimReward(4);
        assertFalse(game.claimed(4));
        assertEq(daemon.balanceOf(address(receiver)), 0);
        assertEq(address(receiver).balance, 0);
        receiver.configure(game, 4, false, true);
        vm.expectRevert();
        game.claimReward(4);
        assertFalse(game.claimed(4));
        assertEq(daemon.balanceOf(address(receiver)), 0);
        assertEq(address(receiver).balance, 0);
        assertEq(prizes.ownerOf(60), address(treasury));
        receiver.configure(game, 4, false, false);
        game.claimReward(4);
        assertTrue(game.claimed(4));
        assertFalse(receiver.reentered());
        assertEq(daemon.balanceOf(address(receiver)), 5 ether);
        assertEq(address(receiver).balance, 1 ether);
        assertEq(prizes.ownerOf(60), address(receiver));
    }

    function test_unsetFeeSourceAndUnauthorizedAdmin() public {
        vm.expectRevert(GameRewards.NotConfigured.selector);
        game.collectCreatorFees();
        vm.startPrank(stranger);
        vm.expectRevert(GameRewards.NotOwner.selector);
        game.setIdentityNft(address(identity));
        vm.expectRevert(GameRewards.NotOwner.selector);
        game.setArbiter(stranger);
        vm.expectRevert(GameRewards.NotOwner.selector);
        game.configureSeason(block.timestamp + 1, block.timestamp + 5 weeks, 1, 1, 1, keccak256("rules"));
        vm.stopPrank();
    }

    function test_receivesCreatorETHWithoutWithdrawalPath() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(game).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(game).balance, 11 ether);
    }
}

contract RewardReceiver {
    GameRewards public game;
    uint256 public id;
    bool public rejectETH;
    bool public rejectNFT;
    bool public reentered;

    function configure(GameRewards game_, uint256 id_, bool eth_, bool nft_) external {
        game = game_;
        id = id_;
        rejectETH = eth_;
        rejectNFT = nft_;
    }

    receive() external payable {
        require(!rejectETH, "reject ETH");
        (reentered,) = address(game).call(abi.encodeCall(game.claimReward, (id)));
    }

    function onERC721Received(address, address, uint256, bytes calldata) external returns (bytes4) {
        require(!rejectNFT, "reject NFT");
        (reentered,) = address(game).call(abi.encodeCall(game.claimReward, (id)));
        return this.onERC721Received.selector;
    }
}
