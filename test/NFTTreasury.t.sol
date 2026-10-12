// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {NFTTreasury} from "../src/NFTTreasury.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockERC721} from "./mocks/MockERC721.sol";
import {MockMarketplace} from "./mocks/MockMarketplace.sol";

contract NFTTreasuryTest is Test {
    MockERC20 daemon;
    MockERC721 nft;
    MockMarketplace market;
    MockMarketplace otherMarket;
    NFTTreasury treasury;

    address owner = makeAddr("owner");
    address operator = makeAddr("operator");
    address seller = makeAddr("seller");
    address stranger = makeAddr("stranger");

    uint256 constant FUNDS = 1_000e18;

    function setUp() public {
        daemon = new MockERC20("DAEMON", "DAEMON", 0);
        nft = new MockERC721();
        market = new MockMarketplace();
        otherMarket = new MockMarketplace();
        treasury = new NFTTreasury(ERC20(address(daemon)), owner);
        daemon.mint(address(treasury), FUNDS);

        vm.startPrank(owner);
        treasury.setOperator(operator, true);
        treasury.setMarketplace(address(market), true);
        treasury.setCollection(address(nft), true);
        treasury.setCaps(100e18, 250e18, 1 days);
        vm.stopPrank();

        for (uint256 id = 1; id <= 5; id++) {
            nft.mint(seller, id);
        }
        vm.startPrank(seller);
        nft.setApprovalForAll(address(market), true);
        nft.setApprovalForAll(address(otherMarket), true);
        for (uint256 id = 1; id <= 5; id++) {
            market.list(address(nft), id, address(daemon), 100e18);
        }
        vm.stopPrank();
    }

    function test_purchaseHappyPath() public {
        vm.prank(operator);
        treasury.buyNFT(address(market), address(nft), 1, 100e18);
        assertEq(nft.ownerOf(1), address(treasury));
        assertEq(daemon.balanceOf(address(treasury)), FUNDS - 100e18);
        assertEq(daemon.balanceOf(seller), 100e18);
        assertEq(daemon.allowance(address(treasury), address(market)), 0, "allowance zeroed after purchase");
        assertEq(treasury.purchases(), 1);
        assertEq(treasury.totalSpent(), 100e18);
        assertEq(treasury.remainingInWindow(), 150e18);
    }

    function test_ownerMayAlsoBuy() public {
        vm.prank(owner);
        treasury.buyNFT(address(market), address(nft), 2, 100e18);
        assertEq(nft.ownerOf(2), address(treasury));
    }

    function test_strangerCannotBuy() public {
        vm.prank(stranger);
        vm.expectRevert(NFTTreasury.NotOperator.selector);
        treasury.buyNFT(address(market), address(nft), 1, 100e18);
    }

    function test_marketplaceMustBeAllowlisted() public {
        vm.prank(seller);
        otherMarket.list(address(nft), 1, address(daemon), 100e18);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NFTTreasury.MarketplaceNotAllowed.selector, address(otherMarket)));
        treasury.buyNFT(address(otherMarket), address(nft), 1, 100e18);
    }

    function test_collectionMustBeAllowlisted() public {
        MockERC721 other = new MockERC721();
        other.mint(seller, 1);
        vm.startPrank(seller);
        other.setApprovalForAll(address(market), true);
        market.list(address(other), 1, address(daemon), 1e18);
        vm.stopPrank();
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NFTTreasury.CollectionNotAllowed.selector, address(other)));
        treasury.buyNFT(address(market), address(other), 1, 1e18);
    }

    function test_perPurchaseCap() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NFTTreasury.PriceAboveCap.selector, 101e18, 100e18));
        treasury.buyNFT(address(market), address(nft), 1, 101e18);
    }

    function test_windowCapAndReset() public {
        vm.startPrank(operator);
        treasury.buyNFT(address(market), address(nft), 1, 100e18);
        treasury.buyNFT(address(market), address(nft), 2, 100e18);
        vm.expectRevert(abi.encodeWithSelector(NFTTreasury.WindowCapExceeded.selector, 100e18, 50e18));
        treasury.buyNFT(address(market), address(nft), 3, 100e18);
        vm.warp(block.timestamp + 1 days);
        treasury.buyNFT(address(market), address(nft), 3, 100e18);
        vm.stopPrank();
        assertEq(nft.ownerOf(3), address(treasury));
        assertEq(treasury.spentInWindow(), 100e18);
    }

    function test_purchasesDisabledUntilCapsSet() public {
        NFTTreasury fresh = new NFTTreasury(ERC20(address(daemon)), owner);
        vm.startPrank(owner);
        fresh.setMarketplace(address(market), true);
        fresh.setCollection(address(nft), true);
        vm.expectRevert(NFTTreasury.PurchasesDisabled.selector);
        fresh.buyNFT(address(market), address(nft), 1, 100e18);
        vm.stopPrank();
    }

    function test_marketplaceThatKeepsPaymentWithoutDeliveringReverts() public {
        market.setRug(true);
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(NFTTreasury.NotOwnedAfterPurchase.selector, address(nft), 1));
        treasury.buyNFT(address(market), address(nft), 1, 100e18);
        assertEq(daemon.balanceOf(address(treasury)), FUNDS, "nothing left the treasury");
    }

    function test_marketplaceCannotPullMoreThanThePrice() public {
        market.setOvercharge(1);
        vm.prank(operator);
        vm.expectRevert(); // allowance is exactly the price, so the extra transferFrom fails inside the market
        treasury.buyNFT(address(market), address(nft), 1, 100e18);
        assertEq(daemon.balanceOf(address(treasury)), FUNDS);
    }

    function test_maxPriceIsRespectedByMarketplace() public {
        vm.prank(operator);
        vm.expectRevert(abi.encodeWithSelector(MockMarketplace.PriceTooHigh.selector, 100e18, 90e18));
        treasury.buyNFT(address(market), address(nft), 1, 90e18);
    }

    function test_adminIsOwnerOnly() public {
        vm.startPrank(stranger);
        vm.expectRevert(NFTTreasury.NotOwner.selector);
        treasury.setOperator(stranger, true);
        vm.expectRevert(NFTTreasury.NotOwner.selector);
        treasury.setMarketplace(address(otherMarket), true);
        vm.expectRevert(NFTTreasury.NotOwner.selector);
        treasury.setCollection(address(nft), false);
        vm.expectRevert(NFTTreasury.NotOwner.selector);
        treasury.setCaps(1, 1, 1);
        vm.expectRevert(NFTTreasury.NotOwner.selector);
        treasury.withdrawTokens(ERC20(address(daemon)), stranger, 1);
        vm.expectRevert(NFTTreasury.NotOwner.selector);
        treasury.withdrawNFT(address(nft), 1, stranger);
        vm.stopPrank();
        vm.prank(owner);
        vm.expectRevert(NFTTreasury.InvalidWindow.selector);
        treasury.setCaps(1, 1, 0);
    }

    function test_ownerCustody() public {
        vm.prank(operator);
        treasury.buyNFT(address(market), address(nft), 1, 100e18);
        vm.startPrank(owner);
        treasury.withdrawNFT(address(nft), 1, owner);
        treasury.withdrawTokens(ERC20(address(daemon)), owner, 1e18);
        vm.stopPrank();
        assertEq(nft.ownerOf(1), owner);
        assertEq(daemon.balanceOf(owner), 1e18);
    }

    function test_twoStepOwnership() public {
        vm.prank(owner);
        treasury.transferOwnership(stranger);
        assertEq(treasury.owner(), owner);
        vm.prank(operator);
        vm.expectRevert(NFTTreasury.NotPendingOwner.selector);
        treasury.acceptOwnership();
        vm.prank(stranger);
        treasury.acceptOwnership();
        assertEq(treasury.owner(), stranger);
    }
}
