// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";

/// @notice The marketplace surface the treasury buys from. Payment is pulled by the marketplace via
/// `transferFrom` up to the allowance the treasury grants for exactly one purchase.
interface IMarketplace {
    function buy(address collection, uint256 tokenId, address paymentToken, uint256 maxPrice) external;
}

interface IERC721Minimal {
    function ownerOf(uint256 tokenId) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

/// @title NFTTreasury
/// @notice Receives all DAEMON hook fees and buys NFTs with them, outside any swap callback.
/// @dev Guard rails:
/// - Only allowlisted marketplaces and allowlisted collections can be bought from.
/// - A per-purchase cap and a rolling per-window spending cap bound what an operator can spend.
/// - After a purchase the treasury checks it actually owns the NFT; otherwise the purchase reverts.
/// - The marketplace is granted an allowance for exactly the price of one purchase and the allowance is
///   zeroed afterwards, so a misbehaving marketplace cannot pull more than the approved price.
/// - The treasury never touches the pool: it has no PoolManager reference and no liquidity functions.
contract NFTTreasury is ReentrancyGuard {
    using SafeTransferLib for ERC20;

    ERC20 public immutable daemon;
    address public owner;
    address public pendingOwner;
    /// @notice Addresses allowed to execute purchases (the owner always may).
    mapping(address => bool) public operators;
    mapping(address => bool) public allowedMarketplaces;
    mapping(address => bool) public allowedCollections;

    /// @notice Maximum DAEMON spent on one NFT. Zero means purchases are disabled.
    uint256 public maxPricePerPurchase;
    /// @notice Maximum DAEMON spent per `windowLength` seconds. Zero means purchases are disabled.
    uint256 public windowCap;
    uint256 public windowLength;
    uint256 public windowStart;
    uint256 public spentInWindow;
    uint256 public totalSpent;
    uint256 public purchases;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OperatorSet(address indexed operator, bool allowed);
    event MarketplaceSet(address indexed marketplace, bool allowed);
    event CollectionSet(address indexed collection, bool allowed);
    event CapsSet(uint256 maxPricePerPurchase, uint256 windowCap, uint256 windowLength);
    event Purchased(address indexed marketplace, address indexed collection, uint256 indexed tokenId, uint256 price);
    event NFTWithdrawn(address indexed collection, uint256 indexed tokenId, address indexed to);
    event TokensWithdrawn(address indexed token, address indexed to, uint256 amount);

    error NotOwner();
    error NotPendingOwner();
    error NotOperator();
    error ZeroAddress();
    error MarketplaceNotAllowed(address marketplace);
    error CollectionNotAllowed(address collection);
    error PriceAboveCap(uint256 price, uint256 cap);
    error WindowCapExceeded(uint256 requested, uint256 remaining);
    error InvalidWindow();
    error PurchasesDisabled();
    error NotOwnedAfterPurchase(address collection, uint256 tokenId);
    error Overspent(uint256 charged, uint256 price);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyOperator() {
        if (msg.sender != owner && !operators[msg.sender]) revert NotOperator();
        _;
    }

    /// @param daemon_ DAEMON token (launch manifest: "$token").
    /// @param owner_ Treasury owner (launch manifest: "$owner").
    /// @dev No external calls: safe to construct on an empty chain. Caps start at zero: purchases are disabled
    /// until the owner sets them (see README, "After launch").
    constructor(ERC20 daemon_, address owner_) {
        if (address(daemon_) == address(0) || owner_ == address(0)) revert ZeroAddress();
        daemon = daemon_;
        owner = owner_;
        windowLength = 1 days;
        emit OwnershipTransferred(address(0), owner_);
    }

    // ------------------------------------------------------------------ admin

    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit OwnershipTransferStarted(owner, newOwner);
    }

    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotPendingOwner();
        emit OwnershipTransferred(owner, msg.sender);
        owner = msg.sender;
        pendingOwner = address(0);
    }

    function setOperator(address operator, bool allowed) external onlyOwner {
        if (operator == address(0)) revert ZeroAddress();
        operators[operator] = allowed;
        emit OperatorSet(operator, allowed);
    }

    function setMarketplace(address marketplace, bool allowed) external onlyOwner {
        if (marketplace == address(0)) revert ZeroAddress();
        allowedMarketplaces[marketplace] = allowed;
        emit MarketplaceSet(marketplace, allowed);
    }

    function setCollection(address collection, bool allowed) external onlyOwner {
        if (collection == address(0)) revert ZeroAddress();
        allowedCollections[collection] = allowed;
        emit CollectionSet(collection, allowed);
    }

    function setCaps(uint256 maxPricePerPurchase_, uint256 windowCap_, uint256 windowLength_) external onlyOwner {
        if (windowLength_ == 0) revert InvalidWindow();
        maxPricePerPurchase = maxPricePerPurchase_;
        windowCap = windowCap_;
        windowLength = windowLength_;
        emit CapsSet(maxPricePerPurchase_, windowCap_, windowLength_);
    }

    // ------------------------------------------------------------------ purchases

    /// @notice DAEMON still spendable in the current window.
    function remainingInWindow() public view returns (uint256) {
        if (block.timestamp >= windowStart + windowLength) return windowCap;
        return windowCap > spentInWindow ? windowCap - spentInWindow : 0;
    }

    /// @notice Buys `tokenId` of `collection` from `marketplace` for at most `price` DAEMON.
    /// @dev Never called from a swap callback: the hook only forwards tokens here, it never calls this.
    function buyNFT(address marketplace, address collection, uint256 tokenId, uint256 price)
        external
        onlyOperator
        nonReentrant
    {
        if (maxPricePerPurchase == 0 || windowCap == 0) revert PurchasesDisabled();
        if (!allowedMarketplaces[marketplace]) revert MarketplaceNotAllowed(marketplace);
        if (!allowedCollections[collection]) revert CollectionNotAllowed(collection);
        if (price > maxPricePerPurchase) revert PriceAboveCap(price, maxPricePerPurchase);

        if (block.timestamp >= windowStart + windowLength) {
            windowStart = block.timestamp;
            spentInWindow = 0;
        }
        uint256 remaining = windowCap - spentInWindow;
        if (price > remaining) revert WindowCapExceeded(price, remaining);
        spentInWindow += price;

        uint256 before = daemon.balanceOf(address(this));
        daemon.safeApprove(marketplace, price);
        IMarketplace(marketplace).buy(collection, tokenId, address(daemon), price);
        daemon.safeApprove(marketplace, 0);

        uint256 charged = before - daemon.balanceOf(address(this));
        if (charged > price) revert Overspent(charged, price);
        if (IERC721Minimal(collection).ownerOf(tokenId) != address(this)) {
            revert NotOwnedAfterPurchase(collection, tokenId);
        }
        totalSpent += charged;
        purchases += 1;
        emit Purchased(marketplace, collection, tokenId, charged);
    }

    // ------------------------------------------------------------------ custody

    /// @notice Moves an NFT the treasury holds (e.g. into a prize pool contract). Owner only.
    function withdrawNFT(address collection, uint256 tokenId, address to) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        IERC721Minimal(collection).safeTransferFrom(address(this), to, tokenId);
        emit NFTWithdrawn(collection, tokenId, to);
    }

    /// @notice Moves ERC-20 tokens the treasury holds. Owner only.
    function withdrawTokens(ERC20 token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        token.safeTransfer(to, amount);
        emit TokensWithdrawn(address(token), to, amount);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
