// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFlags} from "../../src/HookFlags.sol";

/// @notice Mines a CREATE2 salt so a hook lands on an address carrying exactly `flags`, then deploys it.
/// The same procedure the launch deployer uses (HookMiner in v4-periphery does the equivalent).
library HookDeployer {
    error NoSaltFound();
    error DeployFailed();

    function find(address deployer, bytes memory creationCode, uint160 flags)
        internal
        pure
        returns (address predicted, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = 0; i < 500_000; i++) {
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, bytes32(i), initCodeHash))))
            );
            if (HookFlags.matches(predicted, flags)) return (predicted, bytes32(i));
        }
        revert NoSaltFound();
    }

    function deploy(bytes memory creationCode, uint160 flags) internal returns (address at) {
        (, bytes32 salt) = find(address(this), creationCode, flags);
        assembly ("memory-safe") {
            at := create2(0, add(creationCode, 0x20), mload(creationCode), salt)
        }
        if (at == address(0)) revert DeployFailed();
    }
}
