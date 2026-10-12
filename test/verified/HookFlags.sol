// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @title The 14 bits a v4 hook address has to carry
/// @notice Uniswap v4 encodes a hook's permissions in the low 14 bits of its address, and
/// `PoolManager` rejects a hook whose address does not match what `getHookPermissions` reports. That
/// makes this bit layout load-bearing in three places at once: the deployer mines a CREATE2 salt
/// against it, the factory checks it on chain, and the admission gate compares it to what the
/// attested bytecode declares.
///
/// @dev Written down once, here, because three implementations of one bit layout is three chances
/// for one of them to differ — and a wrong bit produces an address the pool manager refuses, after
/// the gas is spent. `HookFlags.t.sol` asserts every constant below equals the one v4 itself
/// declares, so a version bump that renumbered them would fail our build rather than a mainnet
/// transaction.
library HookFlags {
    uint160 internal constant ALL = uint160((1 << 14) - 1);

    uint160 internal constant BEFORE_INITIALIZE = 1 << 13;
    uint160 internal constant AFTER_INITIALIZE = 1 << 12;
    uint160 internal constant BEFORE_ADD_LIQUIDITY = 1 << 11;
    uint160 internal constant AFTER_ADD_LIQUIDITY = 1 << 10;
    uint160 internal constant BEFORE_REMOVE_LIQUIDITY = 1 << 9;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY = 1 << 8;
    uint160 internal constant BEFORE_SWAP = 1 << 7;
    uint160 internal constant AFTER_SWAP = 1 << 6;
    uint160 internal constant BEFORE_DONATE = 1 << 5;
    uint160 internal constant AFTER_DONATE = 1 << 4;
    uint160 internal constant BEFORE_SWAP_RETURN_DELTA = 1 << 3;
    uint160 internal constant AFTER_SWAP_RETURN_DELTA = 1 << 2;
    uint160 internal constant AFTER_ADD_LIQUIDITY_RETURN_DELTA = 1 << 1;
    uint160 internal constant AFTER_REMOVE_LIQUIDITY_RETURN_DELTA = 1 << 0;

    /// @notice The permission bits an address actually carries.
    function flagsOf(address hook) internal pure returns (uint160) {
        return uint160(hook) & ALL;
    }

    /// @notice Whether an address declares exactly these permissions and no others.
    /// @dev Equality rather than a mask test. A hook whose address carries a bit its implementation
    /// does not handle is called for a callback it will revert on, which takes the pool with it.
    function matches(address hook, uint160 flags) internal pure returns (bool) {
        return flagsOf(hook) == (flags & ALL);
    }
}
