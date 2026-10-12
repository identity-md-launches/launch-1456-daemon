// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

/// @title DistributionReceiver
/// @notice Receives the 7% remainder of the DAEMON supply from the launch factory and separates it into
/// game rewards (4%), development (1%) and founder (2%) in the fixed ratio 4 : 1 : 2.
/// @dev The receiver splits whatever DAEMON it holds when `distribute()` is called, so it works for the whole
/// remainder in one shot or for several partial transfers. The founder share is unlocked: no vesting, no
/// cliff. Nothing here mints or burns. The recipients that only the requester knows (development, founder)
/// are set by the owner after launch; `distribute()` reverts until all three are configured.
contract DistributionReceiver {
    using SafeTransferLib for ERC20;

    uint256 public constant GAME_SHARE = 4;
    uint256 public constant DEVELOPMENT_SHARE = 1;
    uint256 public constant FOUNDER_SHARE = 2;
    uint256 public constant TOTAL_SHARES = GAME_SHARE + DEVELOPMENT_SHARE + FOUNDER_SHARE;

    ERC20 public immutable daemon;
    address public owner;
    address public pendingOwner;
    address public gameRewards;
    address public development;
    address public founder;

    uint256 public distributedToGame;
    uint256 public distributedToDevelopment;
    uint256 public distributedToFounder;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event RecipientsSet(address indexed gameRewards, address indexed development, address indexed founder);
    event Distributed(uint256 game, uint256 development, uint256 founder);

    error NotOwner();
    error NotPendingOwner();
    error ZeroAddress();
    error RecipientsNotConfigured();
    error NothingToDistribute();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param daemon_ DAEMON token (launch manifest: "$token").
    /// @param owner_ Owner that sets the recipients (launch manifest: "$owner").
    constructor(ERC20 daemon_, address owner_) {
        if (address(daemon_) == address(0) || owner_ == address(0)) revert ZeroAddress();
        daemon = daemon_;
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

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

    /// @notice Sets the three recipients. All must be non-zero.
    function setRecipients(address gameRewards_, address development_, address founder_) external onlyOwner {
        if (gameRewards_ == address(0) || development_ == address(0) || founder_ == address(0)) revert ZeroAddress();
        gameRewards = gameRewards_;
        development = development_;
        founder = founder_;
        emit RecipientsSet(gameRewards_, development_, founder_);
    }

    function configured() public view returns (bool) {
        return gameRewards != address(0) && development != address(0) && founder != address(0);
    }

    /// @notice Splits the DAEMON balance 4 : 1 : 2. Anyone may call once the recipients are configured.
    /// @dev Rounding dust (at most 2 wei per call) goes to the founder so the balance is fully emptied.
    function distribute() external returns (uint256 game, uint256 dev, uint256 found) {
        if (!configured()) revert RecipientsNotConfigured();
        uint256 balance = daemon.balanceOf(address(this));
        if (balance == 0) revert NothingToDistribute();
        game = balance * GAME_SHARE / TOTAL_SHARES;
        dev = balance * DEVELOPMENT_SHARE / TOTAL_SHARES;
        found = balance - game - dev;
        distributedToGame += game;
        distributedToDevelopment += dev;
        distributedToFounder += found;
        daemon.safeTransfer(gameRewards, game);
        daemon.safeTransfer(development, dev);
        daemon.safeTransfer(founder, found);
        emit Distributed(game, dev, found);
    }
}
