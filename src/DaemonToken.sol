// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";

/// @title DaemonToken (DAEMON)
/// @notice Fixed-supply launch token: 1,000,000,000 DAEMON with 18 decimals, minted once to the deployer.
/// @dev The deployer is the launch factory, which splits the supply (83% liquidity, 10% IMD swarm, 7% to the
/// distribution receiver). There is no mint, burn, pause, owner, proxy or hook of any kind: the supply
/// at construction is the supply forever.
contract DaemonToken is ERC20 {
    /// @notice Total and only supply: one billion whole tokens.
    uint256 public constant TOTAL_SUPPLY = 1_000_000_000e18;

    constructor() ERC20("DAEMON", "DAEMON", 18) {
        _mint(msg.sender, TOTAL_SUPPLY);
    }
}
