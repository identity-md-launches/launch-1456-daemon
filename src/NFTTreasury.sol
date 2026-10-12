// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {TransientStateLibrary} from "v4-core/src/libraries/TransientStateLibrary.sol";

/// @notice A reviewed marketplace adapter must implement this exact, bounded purchase interface.
/// Native ETH is paymentToken == address(0). No arbitrary calldata or recipient is accepted.
interface IMarketplace {
    function buy(address collection, uint256 tokenId, address paymentToken, uint256 maxPrice) external payable;
}

interface IERC721Minimal {
    function ownerOf(uint256 tokenId) external view returns (address);
    function safeTransferFrom(address from, address to, uint256 tokenId) external;
}

/// @notice Protected custody for hook ETH. No token/ETH withdrawal or general NFT withdrawal exists.
/// Purchases require a sealed policy; only the fixed GameRewards contract can deliver NFT prizes.
/// No emergency recovery: unsolicited assets and unallocated NFTs remain in custody.
contract NFTTreasury is ReentrancyGuard {
    using SafeTransferLib for ERC20;
    using TransientStateLibrary for IPoolManager;

    ERC20 public immutable daemon;
    address public owner;
    address public pendingOwner;
    address public gameRewards;
    IPoolManager public poolManager;
    bool public policySealed;
    bool public paused;
    mapping(address => bool) public operators;
    mapping(address => bool) public allowedMarketplaces;
    mapping(address => bool) public allowedCollections;

    struct AssetPolicy {
        bool allowed;
        uint256 perPurchase;
        uint256 perDay;
        uint256 lifetimeCap;
        uint256 dayStart;
        uint256 spentToday;
        uint256 totalSpent;
    }
    mapping(address => AssetPolicy) public assets;
    uint256 public purchases;

    error NotOwner();
    error NotPendingOwner();
    error NotOperator();
    error ZeroAddress();
    error PolicySealed();
    error NotConfigured();
    error PurchasesDisabled();
    error MarketplaceNotAllowed(address marketplace);
    error CollectionNotAllowed(address collection);
    error PaymentNotAllowed();
    error InvalidCaps();
    error CapExceeded();
    error Expired();
    error AlreadyOwned();
    error NotOwnedAfterPurchase(address collection, uint256 tokenId);
    error Overspent();
    error SwapInProgress();
    error NotGameRewards();
    error ExcludedNFT();

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event OperatorSet(address indexed operator, bool allowed);
    event MarketplaceSet(address indexed marketplace, bool allowed);
    event CollectionSet(address indexed collection, bool allowed);
    event AssetPolicySet(address indexed asset, uint256 perPurchase, uint256 perDay, uint256 lifetimeCap);
    event PaymentDisabled(address indexed asset);
    event PolicyFinalized(address indexed gameRewards, address indexed poolManager);
    event Paused(bool paused);
    event Purchased(
        address indexed marketplace, address indexed collection, uint256 indexed tokenId, address asset, uint256 charged
    );
    event PrizeDelivered(address indexed collection, uint256 indexed tokenId, address indexed recipient);

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }
    modifier unsealed() {
        if (policySealed) revert PolicySealed();
        _;
    }

    constructor(ERC20 daemon_, address owner_) {
        if (address(daemon_) == address(0) || owner_ == address(0)) revert ZeroAddress();
        daemon = daemon_;
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    receive() external payable {}

    function transferOwnership(address next) external onlyOwner {
        if (next == address(0)) revert ZeroAddress();
        pendingOwner = next;
        emit OwnershipTransferStarted(owner, next);
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
        if (policySealed && allowed) revert PolicySealed();
        if (marketplace.code.length == 0 || marketplace == address(this)) revert NotConfigured();
        allowedMarketplaces[marketplace] = allowed;
        emit MarketplaceSet(marketplace, allowed);
    }

    function setCollection(address collection, bool allowed) external onlyOwner {
        if (policySealed && allowed) revert PolicySealed();
        if (collection.code.length == 0) revert NotConfigured();
        allowedCollections[collection] = allowed;
        emit CollectionSet(collection, allowed);
    }

    /// @notice Native ETH uses address(0), a currency identifier, not a recipient placeholder.
    function setAssetPolicy(address asset, uint256 perPurchase, uint256 perDay, uint256 lifetimeCap)
        external
        onlyOwner
        unsealed
    {
        if (asset != address(0) && asset.code.length == 0) revert NotConfigured();
        if (perPurchase == 0 || perDay < perPurchase || lifetimeCap < perDay) revert InvalidCaps();
        assets[asset] = AssetPolicy(true, perPurchase, perDay, lifetimeCap, 0, 0, 0);
        emit AssetPolicySet(asset, perPurchase, perDay, lifetimeCap);
    }

    function disablePayment(address asset) external onlyOwner {
        assets[asset].allowed = false;
        emit PaymentDisabled(asset);
    }

    /// @notice Finalizes custody and restrictions before the first purchase. No recipient setter exists afterward.
    function sealPolicy(address game, IPoolManager manager) external onlyOwner unsealed {
        if (game.code.length == 0 || address(manager).code.length == 0 || game == address(this)) {
            revert NotConfigured();
        }
        gameRewards = game;
        poolManager = manager;
        policySealed = true;
        emit PolicyFinalized(game, address(manager));
    }

    function setPaused(bool value) external onlyOwner {
        paused = value;
        emit Paused(value);
    }

    function buyNFT(
        address marketplace,
        address collection,
        uint256 tokenId,
        address asset,
        uint256 price,
        uint256 deadline
    ) external nonReentrant {
        if (msg.sender != owner && !operators[msg.sender]) revert NotOperator();
        if (!policySealed) revert NotConfigured();
        if (poolManager.isUnlocked()) revert SwapInProgress();
        if (paused) revert PurchasesDisabled();
        if (block.timestamp > deadline || deadline > block.timestamp + 1 days) revert Expired();
        if (!allowedMarketplaces[marketplace]) revert MarketplaceNotAllowed(marketplace);
        if (!allowedCollections[collection]) revert CollectionNotAllowed(collection);
        if (tokenId == 222) revert ExcludedNFT();
        AssetPolicy storage p = assets[asset];
        if (!p.allowed) revert PaymentNotAllowed();
        if (price == 0 || price > p.perPurchase) revert CapExceeded();
        if (block.timestamp >= p.dayStart + 1 days) {
            p.dayStart = block.timestamp;
            p.spentToday = 0;
        }
        if (price > p.perDay - p.spentToday || price > p.lifetimeCap - p.totalSpent) revert CapExceeded();
        if (IERC721Minimal(collection).ownerOf(tokenId) == address(this)) revert AlreadyOwned();
        p.spentToday += price;
        p.totalSpent += price;
        uint256 beforeBalance = _balance(asset);
        if (asset != address(0)) {
            ERC20(asset).safeApprove(marketplace, 0);
            ERC20(asset).safeApprove(marketplace, price);
        }
        IMarketplace(marketplace).buy{value: asset == address(0) ? price : 0}(collection, tokenId, asset, price);
        if (asset != address(0)) ERC20(asset).safeApprove(marketplace, 0);
        uint256 afterBalance = _balance(asset);
        uint256 charged = beforeBalance > afterBalance ? beforeBalance - afterBalance : 0;
        if (charged > price) revert Overspent();
        if (IERC721Minimal(collection).ownerOf(tokenId) != address(this)) {
            revert NotOwnedAfterPurchase(collection, tokenId);
        }
        p.spentToday -= price - charged;
        p.totalSpent -= price - charged;
        purchases++;
        emit Purchased(marketplace, collection, tokenId, asset, charged);
    }

    /// @notice Called only during a fixed GameRewards allocation claim; admins cannot invoke or redirect it.
    function deliverPrize(address collection, uint256 tokenId, address recipient) external nonReentrant {
        if (!policySealed || msg.sender != gameRewards) revert NotGameRewards();
        if (tokenId == 222) revert ExcludedNFT();
        if (recipient == address(0) || recipient == address(this)) revert ZeroAddress();
        IERC721Minimal(collection).safeTransferFrom(address(this), recipient, tokenId);
        if (IERC721Minimal(collection).ownerOf(tokenId) != recipient) {
            revert NotOwnedAfterPurchase(collection, tokenId);
        }
        emit PrizeDelivered(collection, tokenId, recipient);
    }

    function _balance(address asset) private view returns (uint256) {
        return asset == address(0) ? address(this).balance : ERC20(asset).balanceOf(address(this));
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
