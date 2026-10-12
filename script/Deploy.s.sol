// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Script} from "forge-std/Script.sol";
import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {DaemonToken} from "../src/DaemonToken.sol";
import {DaemonHook} from "../src/DaemonHook.sol";
import {NFTTreasury} from "../src/NFTTreasury.sol";
import {GameRewards} from "../src/GameRewards.sol";
import {DistributionReceiver} from "../src/DistributionReceiver.sol";
import {HookFlags} from "../src/HookFlags.sol";

/// @title Deploy
/// @notice Local / test-net rehearsal of the DAEMON launch wiring. NOT a mainnet launch: the production launch
/// is performed by the IMD launch factory from the manifest (see README, "Deployment plan"), which deploys the
/// token and the hook itself. This script reproduces the same shape on a local chain so the wiring can be
/// rehearsed and the post-launch owner steps checked.
contract Deploy is Script {
    struct Config {
        IPoolManager poolManager; // "$poolManager"
        address owner; // "$owner"
        address factory; // "$factory": the address that will initialize the pool
        address token; // "$token": zero to deploy a fresh DaemonToken from `factory`'s stand-in (this script)
        address create2Deployer; // address performing the CREATE2 of the hook (this script on a rehearsal)
    }

    struct Deployed {
        DaemonToken token;
        DaemonHook hook;
        NFTTreasury treasury;
        GameRewards gameRewards;
        DistributionReceiver receiver;
        bytes32 hookSalt;
    }

    uint160 public constant HOOK_FLAGS = HookFlags.BEFORE_INITIALIZE | HookFlags.BEFORE_SWAP | HookFlags.AFTER_SWAP
        | HookFlags.BEFORE_SWAP_RETURN_DELTA | HookFlags.AFTER_SWAP_RETURN_DELTA;

    error ZeroAddress();
    error NoSaltFound();
    error HookDeployFailed();
    error LocalRehearsalOnly();

    /// @notice Broadcast entry point. Reads nothing from the environment except what `vm.startBroadcast` needs;
    /// the configuration is passed explicitly so a test can call `deploy` directly.
    function run(Config memory cfg) external returns (Deployed memory d) {
        if (block.chainid != 31337) revert LocalRehearsalOnly();
        vm.startBroadcast();
        d = deploy(cfg);
        vm.stopBroadcast();
    }

    /// @notice Deploys the local test contracts. All owner configuration remains explicit after deployment.
    /// Recipients only the requester knows (development, founder, arbiter, IdentityMD NFT) are left unset.
    function deploy(Config memory cfg) public returns (Deployed memory d) {
        if (address(cfg.poolManager) == address(0) || cfg.owner == address(0) || cfg.factory == address(0)) {
            revert ZeroAddress();
        }
        d.token = cfg.token == address(0) ? new DaemonToken() : DaemonToken(cfg.token);

        bytes memory creation = abi.encodePacked(
            type(DaemonHook).creationCode, abi.encode(cfg.poolManager, cfg.owner, cfg.factory, address(d.token))
        );
        (address predicted, bytes32 salt) = mineSalt(cfg.create2Deployer, creation, HOOK_FLAGS);
        d.hookSalt = salt;
        address at;
        assembly ("memory-safe") {
            at := create2(0, add(creation, 0x20), mload(creation), salt)
        }
        if (at == address(0) || at != predicted) revert HookDeployFailed();
        d.hook = DaemonHook(at);

        d.treasury = new NFTTreasury(ERC20(address(d.token)), cfg.owner);
        d.gameRewards = new GameRewards(ERC20(address(d.token)), cfg.owner);
        d.receiver = new DistributionReceiver(ERC20(address(d.token)), cfg.owner);
    }

    /// @notice Finds a CREATE2 salt placing the hook on an address carrying exactly `flags`.
    function mineSalt(address deployer, bytes memory creationCode, uint160 flags)
        public
        pure
        returns (address predicted, bytes32 salt)
    {
        bytes32 initCodeHash = keccak256(creationCode);
        for (uint256 i = 0; i < 1_000_000; i++) {
            predicted = address(
                uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, bytes32(i), initCodeHash))))
            );
            if (HookFlags.matches(predicted, flags)) return (predicted, bytes32(i));
        }
        revert NoSaltFound();
    }
}
