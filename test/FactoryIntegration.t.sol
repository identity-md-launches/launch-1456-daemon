// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {LaunchFactory} from "./verified/LaunchFactory.sol";
import {LaunchFees} from "./verified/LaunchFees.sol";
import {PoolFees} from "./verified/PoolFees.sol";
import {DaemonToken} from "../src/DaemonToken.sol";
import {DaemonHook} from "../src/DaemonHook.sol";
import {GameRewards} from "../src/GameRewards.sol";
import {NFTTreasury} from "../src/NFTTreasury.sol";
import {DistributionReceiver} from "../src/DistributionReceiver.sol";
import {ICreatorFeeFactory} from "../src/ICreatorFeeFactory.sol";
import {HookDeployer} from "./utils/HookDeployer.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {PoolSwapTest} from "v4-core/src/test/PoolSwapTest.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {FullMath} from "v4-core/src/libraries/FullMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @notice Executes the actual Sourcify-verified factory + PoolFees source locally, not a mock split.
contract FactoryIntegrationTest is Test {
    using StateLibrary for IPoolManager;
    uint64 constant LAUNCH = 1456;
    uint160 constant Q96 = 79228162514264337593543950336;
    uint160 constant FLAGS = 8396;
    uint256 constant SUPPLY = 1_000_000_000 ether;
    PoolManager manager;
    LaunchFactory factory;
    LaunchFees feePolicy;
    DaemonToken daemon;
    DaemonHook hook;
    GameRewards game;
    NFTTreasury treasury;
    DistributionReceiver receiver;
    PoolSwapTest router;
    PoolKey key;
    address distributor;
    address owner = makeAddr("owner");
    address payer = makeAddr("payer");
    address network = makeAddr("network");
    address founder = makeAddr("founder");
    address dev = makeAddr("development");
    address trader = makeAddr("trader");

    function setUp() public {
        manager = new PoolManager(address(this));
        feePolicy = new LaunchFees(owner, network, network, 12500);
        factory = new LaunchFactory(IPoolManager(address(manager)), address(this), feePolicy);
        router = new PoolSwapTest(IPoolManager(address(manager)));
        address predicted = factory.predictToken(LAUNCH, type(DaemonToken).creationCode);
        daemon = DaemonToken(predicted);
        game = new GameRewards(daemon, owner);
        treasury = new NFTTreasury(daemon, owner);
        receiver = new DistributionReceiver(daemon, owner);
        LaunchFactory.LaunchParams memory p;
        p.launchNumber = LAUNCH;
        p.kind = "hook";
        p.tokenCreationCode = type(DaemonToken).creationCode;
        p.hookCreationCode = abi.encodePacked(
            type(DaemonHook).creationCode, abi.encode(address(manager), owner, address(factory), predicted)
        );
        (, p.hookSalt) = HookDeployer.find(address(factory), p.hookCreationCode, FLAGS);
        p.hookFlags = FLAGS;
        p.totalSupply = SUPPLY;
        p.poolBps = 8300;
        p.remainderTo = address(receiver);
        p.merkleRoot = keccak256("local-only swarm distribution root");
        p.sweepDelaySeconds = 365 days;
        p.pairedCurrency = Currency.wrap(address(0));
        p.fee = 12500;
        p.tickSpacing = 100;
        p.sqrtPriceX96 = Q96;
        p.tickLower = -10000;
        p.tickUpper = 0;
        // token1 seeding takes ceil(L * (sqrtUpper - sqrtLower) / Q96).
        // Difference < Q96, so this L consumes exactly the target, verified below.
        p.liquidity = uint128(FullMath.mulDiv(830_000_000 ether, Q96, Q96 - TickMath.getSqrtPriceAtTick(-10000)));
        p.requester = payer;
        (address token, address h, address swarm) = factory.launch(p);
        assertEq(token, predicted);
        hook = DaemonHook(h);
        distributor = swarm;
        (key,,,) = factory.positionOf(LAUNCH);
        vm.startPrank(owner);
        hook.setTreasury(address(treasury));
        receiver.setRecipients(address(game), dev, founder);
        game.setFeeSource(ICreatorFeeFactory(address(factory)), LAUNCH);
        vm.stopPrank();
        vm.deal(trader, 1000 ether);
    }

    function _trade() internal {
        vm.startPrank(trader);
        router.swap{value: 100 ether}(
            key, SwapParams(true, -100 ether, TickMath.MIN_SQRT_PRICE + 1), PoolSwapTest.TestSettings(false, false), ""
        );
        daemon.approve(address(router), type(uint256).max);
        router.swap(
            key,
            SwapParams(false, -int256(daemon.balanceOf(trader) / 2), TickMath.MAX_SQRT_PRICE - 1),
            PoolSwapTest.TestSettings(false, false),
            ""
        );
        vm.stopPrank();
    }

    function test_actualFactoryAllocatesExactly83_10_7AndReceiver4_1_2() public {
        assertEq(daemon.totalSupply(), SUPPLY);
        assertEq(daemon.balanceOf(address(manager)), 830_000_000 ether);
        assertEq(daemon.balanceOf(distributor), 100_000_000 ether);
        assertEq(daemon.balanceOf(address(receiver)), 70_000_000 ether);
        assertEq(daemon.balanceOf(address(factory)), 0);
        receiver.distribute();
        assertEq(daemon.balanceOf(address(game)), 40_000_000 ether);
        assertEq(daemon.balanceOf(dev), 10_000_000 ether);
        assertEq(daemon.balanceOf(founder), 20_000_000 ether);
        assertEq(
            daemon.balanceOf(address(manager)) + daemon.balanceOf(distributor) + daemon.balanceOf(address(game))
                + daemon.balanceOf(dev) + daemon.balanceOf(founder),
            SUPPLY
        );
        vm.prank(founder);
        daemon.transfer(trader, 20_000_000 ether);
        assertEq(daemon.balanceOf(trader), 20_000_000 ether, "founder has no vesting or treasury restriction");
    }

    function test_entireCreatorShareToGameAndHookETHToNFTTreasury() public {
        vm.prank(payer);
        factory.setRequester(LAUNCH, address(game));
        _trade();
        uint128 liquidity = IPoolManager(address(manager)).getLiquidity(key.toId());
        uint256 hookFees = hook.pendingFees();
        (uint256 feeETH, uint256 feeToken) = game.collectCreatorFees();
        assertGt(feeETH, 0);
        assertGt(feeToken, 0);
        assertEq(address(game).balance, feeETH * 8000 / 10000);
        assertEq(daemon.balanceOf(address(game)), feeToken * 8000 / 10000);
        assertEq(network.balance, feeETH - feeETH * 8000 / 10000);
        assertEq(daemon.balanceOf(network), feeToken - feeToken * 8000 / 10000);
        assertEq(address(treasury).balance, 0);
        assertEq(hook.pendingFees(), hookFees, "LP collection cannot consume hook fees");
        hook.forwardFees();
        assertEq(address(treasury).balance, hookFees);
        assertEq(IPoolManager(address(manager)).getLiquidity(key.toId()), liquidity, "principal retained");
        (uint256 againETH, uint256 againToken) = factory.claimFees(LAUNCH);
        assertEq(againETH + againToken, 0, "no duplicate fee payment");
    }

    function test_requiresActualPayerAuthorizationNotRemainderReceiverOrAdmin() public {
        vm.expectRevert(GameRewards.PayerAuthorizationRequired.selector);
        game.collectCreatorFees();
        vm.prank(owner);
        vm.expectRevert(abi.encodeWithSelector(PoolFees.NotRequester.selector, LAUNCH));
        factory.setRequester(LAUNCH, address(game));
        vm.prank(address(receiver));
        vm.expectRevert(abi.encodeWithSelector(PoolFees.NotRequester.selector, LAUNCH));
        factory.setRequester(LAUNCH, address(game));
        (,,, address requester) = factory.positionOf(LAUNCH);
        assertEq(requester, payer);
        _trade();
        (uint256 eth, uint256 tokens) = factory.claimFees(LAUNCH);
        assertEq(payer.balance, eth * 8000 / 10000);
        assertEq(daemon.balanceOf(payer), tokens * 8000 / 10000);
        assertEq(address(game).balance, 0);
    }

    function test_assignmentIrreversibleFromGameAndOwnerCannotReplaceSource() public {
        vm.prank(payer);
        factory.setRequester(LAUNCH, address(game));
        vm.prank(payer);
        vm.expectRevert(abi.encodeWithSelector(PoolFees.NotRequester.selector, LAUNCH));
        factory.setRequester(LAUNCH, payer);
        vm.startPrank(owner);
        vm.expectRevert(GameRewards.ConfigurationLocked.selector);
        game.setFeeSource(ICreatorFeeFactory(address(factory)), LAUNCH + 1);
        (bool ok,) = address(game).call(abi.encodeWithSignature("setRequester(uint64,address)", LAUNCH, owner));
        assertFalse(ok);
        vm.stopPrank();
    }

    function test_oldPaidShareMustBeForwardedByPayerManually() public {
        _trade();
        factory.claimFees(LAUNCH);
        uint256 oldETH = payer.balance;
        uint256 oldTokens = daemon.balanceOf(payer);
        vm.startPrank(payer);
        factory.setRequester(LAUNCH, address(game));
        (bool ok,) = address(game).call{value: oldETH}("");
        require(ok);
        daemon.transfer(address(game), oldTokens);
        vm.stopPrank();
        assertEq(address(game).balance, oldETH);
        assertEq(daemon.balanceOf(address(game)), oldTokens);
    }

    function test_failedPayerPaymentStaysOwedToOldPayerAfterAssignment() public {
        FeePayer contractPayer = new FeePayer();
        vm.prank(payer);
        factory.setRequester(LAUNCH, address(contractPayer));
        _trade();
        (uint256 eth,) = factory.claimFees(LAUNCH);
        uint256 oldShare = eth * 8000 / 10000;
        assertGt(oldShare, 0);
        assertEq(factory.owed(address(contractPayer), Currency.wrap(address(0))), oldShare);
        assertEq(network.balance, eth - oldShare, "refusing payer does not block network share");
        vm.prank(address(contractPayer));
        factory.setRequester(LAUNCH, address(game));
        assertEq(factory.owed(address(game), Currency.wrap(address(0))), 0);
        factory.withdraw(address(contractPayer), Currency.wrap(address(0)));
        assertEq(factory.owed(address(contractPayer), Currency.wrap(address(0))), oldShare);
        contractPayer.allowETH();
        factory.withdraw(address(contractPayer), Currency.wrap(address(0)));
        assertEq(address(contractPayer).balance, oldShare);
        assertEq(factory.owed(address(contractPayer), Currency.wrap(address(0))), 0);
        factory.withdraw(address(contractPayer), Currency.wrap(address(0)));
        assertEq(address(contractPayer).balance, oldShare);
    }

    function test_distributionRecipientsCannotBeChanged() public {
        vm.prank(owner);
        vm.expectRevert(DistributionReceiver.RecipientsAlreadyConfigured.selector);
        receiver.setRecipients(owner, owner, owner);
    }
}

contract FeePayer {
    bool public acceptsETH;

    function allowETH() external {
        acceptsETH = true;
    }

    receive() external payable {
        require(acceptsETH, "no ETH yet");
    }
}
