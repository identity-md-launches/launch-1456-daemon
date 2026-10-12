// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {ERC721} from "solmate/src/tokens/ERC721.sol";

/// @notice Fixed-price ERC-721 marketplace paid in an ERC-20. Sellers list by approving the marketplace.
/// `rug` mode takes the payment without delivering the NFT, for failure tests.
contract MockMarketplace {
    struct Listing {
        address seller;
        address paymentToken;
        uint256 price;
    }

    mapping(address collection => mapping(uint256 tokenId => Listing)) public listings;
    bool public rug;
    /// @notice When set, the marketplace pulls this much more than the listed price (overcharge test).
    uint256 public overcharge;

    error NotListed();
    error PriceTooHigh(uint256 price, uint256 maxPrice);
    error WrongToken();

    function setRug(bool on) external {
        rug = on;
    }

    function setOvercharge(uint256 extra) external {
        overcharge = extra;
    }

    function list(address collection, uint256 tokenId, address paymentToken, uint256 price) external {
        require(ERC721(collection).ownerOf(tokenId) == msg.sender, "not owner");
        listings[collection][tokenId] = Listing(msg.sender, paymentToken, price);
    }

    function buy(address collection, uint256 tokenId, address paymentToken, uint256 maxPrice) external payable {
        Listing memory l = listings[collection][tokenId];
        if (l.seller == address(0)) revert NotListed();
        if (l.paymentToken != paymentToken) revert WrongToken();
        if (l.price > maxPrice) revert PriceTooHigh(l.price, maxPrice);
        uint256 charge = l.price + overcharge;
        if (paymentToken == address(0)) {
            require(msg.value >= charge, "payment failed");
            (bool ok,) = l.seller.call{value: charge}("");
            require(ok, "seller refused");
            if (msg.value > charge) {
                (ok,) = msg.sender.call{value: msg.value - charge}("");
                require(ok, "refund refused");
            }
        } else {
            require(msg.value == 0, "unexpected ETH");
            require(ERC20(paymentToken).transferFrom(msg.sender, l.seller, charge), "payment failed");
        }
        delete listings[collection][tokenId];
        if (!rug) ERC721(collection).transferFrom(l.seller, msg.sender, tokenId);
    }
}
