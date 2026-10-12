// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Ownable, Ownable2Step} from "./openzeppelin/access/Ownable2Step.sol";

/// @title What launch pools charge, where the network's share of it goes, and the network's treasury
/// @notice One per chain. The factories read the recipient at the moment fees are paid out, so
/// changing it here moves the network's share of every pool they ever opened, past and future,
/// without touching a single pool. They read `poolFee` as they open a pool: a pool's fee is fixed
/// when it is created, so a new fee applies to the pools opened after it.
/// @dev The split itself is not here and cannot be changed: a requester was promised
/// `REQUESTER_BPS` of their pool's fees when they paid, and an owner able to lower it would make
/// that promise worth nothing. Only the recipient of the rest moves.
contract LaunchFees is Ownable2Step {
    error ZeroRecipient();
    error ZeroTreasury();
    error InvalidPoolFee(uint24 fee);

    event FeeRecipientChanged(address indexed previous, address indexed next);
    event PoolFeeChanged(uint24 previous, uint24 next);
    event TreasuryChanged(address indexed previous, address indexed next);

    /// @notice The requester's share of a pool's LP fees: 80%, which is 1% of volume at a 1.25% fee.
    uint16 public constant REQUESTER_BPS = 8000;

    /// @notice The highest pool fee the owner may set, in v4's hundredths of a basis point: 10%.
    uint24 public constant MAX_POOL_FEE = 100_000;

    /// @notice The LP fee a project factory opens its pools at, in hundredths of a basis point
    /// (12_500 is 1.25%). Hook launches keep the fee their hook's launch sets.
    uint24 public poolFee;

    /// @notice Receives the network's share: what the requester's share leaves, and all of a pool
    /// opened with no requester.
    address public feeRecipient;
    /// @notice Where unclaimed contributor rewards go once a round's year is up, and the requester's
    /// share of a launch nobody paid for. Read when it is used, like `feeRecipient`, so moving it
    /// here moves it for every distributor and launch the factories ever made.
    address public treasury;

    constructor(address owner_, address feeRecipient_, address treasury_, uint24 poolFee_) Ownable(owner_) {
        if (feeRecipient_ == address(0)) revert ZeroRecipient();
        if (treasury_ == address(0)) revert ZeroTreasury();
        if (poolFee_ == 0 || poolFee_ > MAX_POOL_FEE) revert InvalidPoolFee(poolFee_);
        feeRecipient = feeRecipient_;
        treasury = treasury_;
        poolFee = poolFee_;
        emit FeeRecipientChanged(address(0), feeRecipient_);
        emit TreasuryChanged(address(0), treasury_);
        emit PoolFeeChanged(0, poolFee_);
    }

    /// @notice Moves the network's share, for every pool at once, from the next payout on.
    function setFeeRecipient(address next) external onlyOwner {
        if (next == address(0)) revert ZeroRecipient();
        emit FeeRecipientChanged(feeRecipient, next);
        feeRecipient = next;
    }

    /// @notice Sets the fee the next project pools open at. Pools already open keep theirs.
    function setPoolFee(uint24 next) external onlyOwner {
        if (next == 0 || next > MAX_POOL_FEE) revert InvalidPoolFee(next);
        emit PoolFeeChanged(poolFee, next);
        poolFee = next;
    }

    /// @notice Moves the treasury, for every distributor and launch at once, from its next use on.
    function setTreasury(address next) external onlyOwner {
        if (next == address(0)) revert ZeroTreasury();
        emit TreasuryChanged(treasury, next);
        treasury = next;
    }
}
