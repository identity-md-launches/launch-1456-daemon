// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {NFTTreasury} from "../src/NFTTreasury.sol";
import {GameRewards} from "../src/GameRewards.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC721} from "./mocks/MockERC721.sol";
import {MockMarketplace} from "./mocks/MockMarketplace.sol";

contract NFTTreasuryTest is Test {
    MockERC20 daemon;
    MockERC721 nft;
    MockMarketplace market;
    NFTTreasury treasury;
    GameRewards game;
    PoolManager manager;
    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address seller = makeAddr("seller");
    address stranger = makeAddr("stranger");

    function setUp() public {
        vm.warp(10 days);
        daemon = new MockERC20("DAEMON", "DAEMON", 0);
        nft = new MockERC721();
        market = new MockMarketplace();
        treasury = new NFTTreasury(daemon, owner);
        game = new GameRewards(daemon, owner);
        manager = new PoolManager(address(this));
        daemon.mint(address(treasury), 1000 ether);
        vm.deal(address(treasury), 1000 ether);
        vm.startPrank(owner);
        treasury.setOperator(operator, true);
        treasury.setMarketplace(address(market), true);
        treasury.setCollection(address(nft), true);
        treasury.setAssetPolicy(address(daemon), 100 ether, 250 ether, 500 ether);
        treasury.setAssetPolicy(address(0), 1 ether, 2 ether, 3 ether);
        treasury.sealPolicy(address(game), IPoolManager(address(manager)));
        vm.stopPrank();
        for (uint256 id = 1; id <= 8; id++) {
            nft.mint(seller, id);
        }
        vm.startPrank(seller);
        nft.setApprovalForAll(address(market), true);
        for (uint256 id = 1; id <= 8; id++) {
            market.list(address(nft), id, id <= 4 ? address(daemon) : address(0), id <= 4 ? 100 ether : 1 ether);
        }
        vm.stopPrank();
    }

    function _buy(uint256 id, address asset, uint256 price) internal {
        treasury.buyNFT(address(market), address(nft), id, asset, price, block.timestamp + 5 minutes);
    }

    function test_tokenPurchaseAndExactClearedApproval() public {
        vm.prank(operator);
        _buy(1, address(daemon), 100 ether);
        assertEq(nft.ownerOf(1), address(treasury));
        assertEq(daemon.balanceOf(seller), 100 ether);
        assertEq(daemon.allowance(address(treasury), address(market)), 0);
        assertEq(treasury.purchases(), 1);
    }

    function test_nativePurchase() public {
        vm.prank(operator);
        _buy(5, address(0), 1 ether);
        assertEq(nft.ownerOf(5), address(treasury));
        assertEq(seller.balance, 1 ether);
        assertEq(address(treasury).balance, 999 ether);
    }

    function test_nativeRefundCountsActualSpend() public {
        vm.prank(seller);
        market.list(address(nft), 5, address(0), 0.4 ether);
        vm.prank(operator);
        _buy(5, address(0), 1 ether);
        (,,,,, uint256 daily, uint256 total) = treasury.assets(address(0));
        assertEq(daily, 0.4 ether);
        assertEq(total, 0.4 ether);
        assertEq(address(treasury).balance, 999.6 ether);
    }

    function test_dailyAndLifetimeCapsAreIndependentByAsset() public {
        vm.startPrank(operator);
        _buy(5, address(0), 1 ether);
        _buy(6, address(0), 1 ether);
        vm.expectRevert(NFTTreasury.CapExceeded.selector);
        _buy(7, address(0), 1 ether);
        _buy(1, address(daemon), 100 ether);
        vm.warp(block.timestamp + 1 days);
        _buy(7, address(0), 1 ether);
        vm.warp(block.timestamp + 1 days);
        vm.expectRevert(NFTTreasury.CapExceeded.selector);
        _buy(8, address(0), 1 ether);
        vm.stopPrank();
    }

    function test_nonDeliveryRevertsETHAndTokenPayment() public {
        market.setRug(true);
        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(NFTTreasury.NotOwnedAfterPurchase.selector, address(nft), 1));
        _buy(1, address(daemon), 100 ether);
        vm.expectRevert(abi.encodeWithSelector(NFTTreasury.NotOwnedAfterPurchase.selector, address(nft), 5));
        _buy(5, address(0), 1 ether);
        vm.stopPrank();
        assertEq(daemon.balanceOf(address(treasury)), 1000 ether);
        assertEq(address(treasury).balance, 1000 ether);
        assertEq(treasury.purchases(), 0);
        assertEq(daemon.allowance(address(treasury), address(market)), 0);
    }

    function test_overchargeRevertsBothPaymentTypes() public {
        market.setOvercharge(1);
        vm.startPrank(operator);
        vm.expectRevert();
        _buy(1, address(daemon), 100 ether);
        vm.expectRevert();
        _buy(5, address(0), 1 ether);
        vm.stopPrank();
    }

    function test_strangerAndDeadlineAndPerPurchaseChecks() public {
        vm.prank(stranger);
        vm.expectRevert(NFTTreasury.NotOperator.selector);
        _buy(1, address(daemon), 100 ether);
        vm.startPrank(operator);
        vm.expectRevert(NFTTreasury.Expired.selector);
        treasury.buyNFT(address(market), address(nft), 1, address(daemon), 100 ether, block.timestamp - 1);
        vm.expectRevert(NFTTreasury.CapExceeded.selector);
        _buy(1, address(daemon), 101 ether);
        vm.expectRevert(NFTTreasury.ExcludedNFT.selector);
        _buy(222, address(0), 1 ether);
        vm.stopPrank();
    }

    function test_allThreeAllowlists() public {
        vm.startPrank(operator);
        vm.expectRevert(abi.encodeWithSelector(NFTTreasury.MarketplaceNotAllowed.selector, stranger));
        treasury.buyNFT(stranger, address(nft), 1, address(daemon), 1, block.timestamp);
        vm.expectRevert(abi.encodeWithSelector(NFTTreasury.CollectionNotAllowed.selector, stranger));
        treasury.buyNFT(address(market), stranger, 1, address(daemon), 1, block.timestamp);
        vm.expectRevert(NFTTreasury.PaymentNotAllowed.selector);
        _buy(1, stranger, 1);
        vm.stopPrank();
    }

    function test_noSpendingBeforeSealing() public {
        NFTTreasury fresh = new NFTTreasury(daemon, owner);
        vm.prank(owner);
        vm.expectRevert(NFTTreasury.NotConfigured.selector);
        fresh.buyNFT(address(market), address(nft), 1, address(daemon), 1, block.timestamp);
    }

    function test_ownerCannotExpandPolicyOrRedirectAfterTransfer() public {
        vm.startPrank(owner);
        vm.expectRevert(NFTTreasury.PolicySealed.selector);
        treasury.setAssetPolicy(address(daemon), 1000 ether, 1000 ether, 1000 ether);
        vm.expectRevert(NFTTreasury.PolicySealed.selector);
        treasury.setMarketplace(address(market), true);
        vm.expectRevert(NFTTreasury.PolicySealed.selector);
        treasury.setCollection(address(nft), true);
        vm.expectRevert(NFTTreasury.PolicySealed.selector);
        treasury.sealPolicy(address(market), IPoolManager(address(manager)));
        treasury.transferOwnership(stranger);
        vm.stopPrank();
        vm.startPrank(stranger);
        treasury.acceptOwnership();
        treasury.setOperator(stranger, true);
        vm.expectRevert(NFTTreasury.PolicySealed.selector);
        treasury.setAssetPolicy(address(0), 1000 ether, 1000 ether, 1000 ether);
        vm.expectRevert(NFTTreasury.NotGameRewards.selector);
        treasury.deliverPrize(address(nft), 1, stranger);
        vm.stopPrank();
    }

    function test_disableAndPauseOnlyRestrict() public {
        vm.prank(owner);
        treasury.disablePayment(address(0));
        vm.prank(operator);
        vm.expectRevert(NFTTreasury.PaymentNotAllowed.selector);
        _buy(5, address(0), 1 ether);
        vm.prank(owner);
        treasury.setPaused(true);
        vm.prank(operator);
        vm.expectRevert(NFTTreasury.PurchasesDisabled.selector);
        _buy(1, address(daemon), 100 ether);
    }

    function test_removedWithdrawalsFailForOwnerAndStranger() public {
        for (uint256 i; i < 2; i++) {
            address who = i == 0 ? owner : stranger;
            vm.startPrank(who);
            (bool a,) = address(treasury)
                .call(abi.encodeWithSignature("withdrawTokens(address,address,uint256)", address(daemon), who, 1 ether));
            (bool b,) = address(treasury).call(abi.encodeWithSignature("withdrawEth(address,uint256)", who, 1 ether));
            (bool c,) = address(treasury)
                .call(abi.encodeWithSignature("withdrawNFT(address,uint256,address)", address(nft), 1, who));
            vm.stopPrank();
            assertFalse(a || b || c);
        }
    }

    function test_cannotPayAgainForNFTAlreadyInCustody() public {
        vm.startPrank(operator);
        _buy(1, address(daemon), 100 ether);
        vm.expectRevert(NFTTreasury.AlreadyOwned.selector);
        _buy(1, address(daemon), 100 ether);
        vm.stopPrank();
        assertEq(treasury.purchases(), 1);
    }

    function test_reentrantMarketplaceCannotSpendTwice() public {
        NFTTreasury fresh = new NFTTreasury(daemon, owner);
        ReenteringMarketplace reentrant = new ReenteringMarketplace(fresh, nft);
        vm.deal(address(fresh), 2 ether);
        vm.startPrank(owner);
        fresh.setMarketplace(address(reentrant), true);
        fresh.setCollection(address(nft), true);
        fresh.setAssetPolicy(address(0), 1 ether, 2 ether, 2 ether);
        fresh.setOperator(address(reentrant), true);
        fresh.sealPolicy(address(game), IPoolManager(address(manager)));
        vm.stopPrank();
        vm.prank(seller);
        nft.approve(address(reentrant), 5);
        vm.prank(owner);
        fresh.buyNFT(address(reentrant), address(nft), 5, address(0), 1 ether, block.timestamp);
        assertFalse(reentrant.reentered());
        assertEq(fresh.purchases(), 1);
        assertEq(address(fresh).balance, 1 ether);
        assertEq(nft.ownerOf(5), address(fresh));
    }

    function test_buyBlockedWhilePoolManagerUnlocked() public {
        vm.prank(owner);
        treasury.setOperator(address(this), true);
        manager.unlock("");
        assertEq(treasury.purchases(), 0);
    }

    function unlockCallback(bytes calldata) external returns (bytes memory) {
        require(msg.sender == address(manager));
        vm.expectRevert(NFTTreasury.SwapInProgress.selector);
        _buy(5, address(0), 1 ether);
        return "";
    }
}

contract ReenteringMarketplace {
    NFTTreasury public treasury;
    MockERC721 public nft;
    bool public reentered;

    constructor(NFTTreasury treasury_, MockERC721 nft_) {
        treasury = treasury_;
        nft = nft_;
    }

    function buy(address collection, uint256 tokenId, address asset, uint256 price) external payable {
        require(msg.sender == address(treasury));
        (reentered,) = address(treasury)
            .call(abi.encodeCall(treasury.buyNFT, (address(this), collection, tokenId, asset, price, block.timestamp)));
        nft.transferFrom(nft.ownerOf(tokenId), msg.sender, tokenId);
    }
}
