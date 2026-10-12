// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";

/// @notice Exact public fee surface of the verified IMD PoolFees inherited by LaunchFactory.
/// Source and verification record: docs/factory-source.json, test/verified/PoolFees.sol.
interface ICreatorFeeFactory {
    function setRequester(uint64 launchNumber, address next) external;
    function claimFees(uint64 launchNumber) external returns (uint256 amount0, uint256 amount1);
    function positionOf(uint64 launchNumber)
        external
        view
        returns (PoolKey memory key, int24 lower, int24 upper, address requester);
    function owed(address account, Currency currency) external view returns (uint256);
    function withdraw(address account, Currency currency) external;
}
