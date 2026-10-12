// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IERC20} from "./openzeppelin/token/ERC20/IERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {LaunchFees} from "./LaunchFees.sol";

/// @title The LP fees of the positions a factory seeded, claimable by anyone
/// @notice A factory owns the liquidity it seeds, so the fees that liquidity earns accrue to the
/// factory. `claimFees` collects them for one launch and splits them: `REQUESTER_BPS` to the
/// launch's requester (the wallet that paid for it, or whoever it handed the share to) and the rest
/// to the network's recipient in `LaunchFees`, read at payout, so moving that recipient moves every
/// pool's share at once. Anyone may call it; nobody can send the fees anywhere else.
///
/// @dev Payouts are attempted, not assumed. A recipient that refuses a payment (a contract without
/// `receive`, a token that blocks it) leaves the amount owed to that same address, to be paid by
/// `withdraw` once it can take it, rather than reverting the claim and holding the other party's
/// share hostage. The principal is never touched: the only liquidity change is a zero one, which v4
/// treats as collecting.
abstract contract PoolFees {
    error NoPosition(uint64 launchNumber);
    error NotRequester(uint64 launchNumber);
    error ZeroRequester();
    error ClaimInProgress();
    error UnexpectedClaim();
    error HookTookFees(int128 amount0, int128 amount1);

    event PositionOpened(uint64 indexed launchNumber, address indexed requester, int24 tickLower, int24 tickUpper);
    event RequesterChanged(uint64 indexed launchNumber, address indexed previous, address indexed next);
    event FeesClaimed(uint64 indexed launchNumber, address indexed caller, uint256 amount0, uint256 amount1);
    event FeesOwed(address indexed account, Currency indexed currency, uint256 amount);
    event FeesPaid(address indexed account, Currency indexed currency, uint256 amount);

    /// @notice One launch's seeded position and who shares its fees.
    struct Position {
        PoolKey key;
        int24 tickLower;
        int24 tickUpper;
        /// @dev Zero for a launch nobody paid for: its fees all go to the network.
        address requester;
    }

    /// @notice The network's fee recipient, read at every payout.
    LaunchFees public immutable fees;

    mapping(uint64 launchNumber => Position) internal positions;
    /// @notice What a payout could not deliver yet, by the address it belongs to and the currency.
    mapping(address account => mapping(Currency currency => uint256)) public owed;
    /// @notice The network's share not yet paid out, by currency: it belongs to whoever `fees` names when it is paid.
    mapping(Currency currency => uint256) public networkOwed;

    /// @dev The launch a claim is collecting, for the unlock callback; `inClaim` because launch 0 is a number too.
    uint64 private claiming;
    bool private inClaim;

    constructor(LaunchFees fees_) {
        fees = fees_;
    }

    /// @dev The pool manager the factory seeds through; the only caller `unlockCallback` answers.
    function _manager() internal view virtual returns (IPoolManager);

    /// @notice A launch's pool, range and requester.
    function positionOf(uint64 launchNumber)
        external
        view
        returns (PoolKey memory key, int24 tickLower, int24 tickUpper, address requester)
    {
        Position storage p = positions[launchNumber];
        return (p.key, p.tickLower, p.tickUpper, p.requester);
    }

    /// @notice Hands the requester's share of a launch's future fees to another address. Only the
    /// current holder can; what was already paid or owed stays with the address it was owed to.
    function setRequester(uint64 launchNumber, address next) external {
        Position storage p = positions[launchNumber];
        if (p.requester == address(0) || msg.sender != p.requester) revert NotRequester(launchNumber);
        if (next == address(0)) revert ZeroRequester();
        emit RequesterChanged(launchNumber, p.requester, next);
        p.requester = next;
    }

    /// @notice Collects one launch's accrued LP fees and pays both shares. Anyone may call it.
    function claimFees(uint64 launchNumber) external returns (uint256 amount0, uint256 amount1) {
        Position storage p = positions[launchNumber];
        if (p.tickLower == p.tickUpper) revert NoPosition(launchNumber);
        if (inClaim) revert ClaimInProgress();
        (claiming, inClaim) = (launchNumber, true);
        (amount0, amount1) = abi.decode(_manager().unlock(abi.encode(launchNumber)), (uint256, uint256));
        (claiming, inClaim) = (0, false);
        emit FeesClaimed(launchNumber, msg.sender, amount0, amount1);

        Currency c0 = p.key.currency0;
        Currency c1 = p.key.currency1;
        address requester = p.requester;
        _split(requester, c0, amount0);
        _split(requester, c1, amount1);
        if (requester != address(0)) {
            _payAccount(requester, c0);
            _payAccount(requester, c1);
        }
        _payNetwork(c0);
        _payNetwork(c1);
    }

    /// @notice Pays an account what an earlier payout could not. Anyone may call it; it pays only `account`.
    function withdraw(address account, Currency currency) external {
        _payAccount(account, currency);
    }

    /// @notice Pays the network's owed share in `currency` to the current recipient. Anyone may call it.
    function withdrawNetwork(Currency currency) external {
        _payNetwork(currency);
    }

    /// @dev Whether an unlock callback is a claim's, which the factory answers with `_collect`.
    function _claiming() internal view returns (bool) {
        return inClaim;
    }

    /// @dev Inside the pool manager's unlock: a zero liquidity change on the seeded position, which
    /// v4 answers with the fees accrued, taken here. A hook may adjust that delta; one that would
    /// have the position pay is refused rather than paid.
    function _collect(bytes calldata data) internal returns (bytes memory) {
        uint64 launchNumber = abi.decode(data, (uint64));
        if (launchNumber != claiming) revert UnexpectedClaim();
        Position storage p = positions[launchNumber];
        IPoolManager manager = _manager();
        (BalanceDelta delta,) = manager.modifyLiquidity(
            p.key,
            ModifyLiquidityParams({
                tickLower: p.tickLower, tickUpper: p.tickUpper, liquidityDelta: 0, salt: bytes32(0)
            }),
            ""
        );
        int128 a0 = delta.amount0();
        int128 a1 = delta.amount1();
        if (a0 < 0 || a1 < 0) revert HookTookFees(a0, a1);
        if (a0 > 0) manager.take(p.key.currency0, address(this), uint128(a0));
        if (a1 > 0) manager.take(p.key.currency1, address(this), uint128(a1));
        return abi.encode(uint256(uint128(a0)), uint256(uint128(a1)));
    }

    /// @dev Records a launch's seeded position, called once as the factory seeds it.
    function _openPosition(uint64 launchNumber, PoolKey memory key, int24 tickLower, int24 tickUpper, address requester)
        internal
    {
        positions[launchNumber] = Position(key, tickLower, tickUpper, requester);
        emit PositionOpened(launchNumber, requester, tickLower, tickUpper);
    }

    function _split(address requester, Currency currency, uint256 amount) private {
        if (amount == 0) return;
        uint256 share = requester == address(0) ? 0 : (amount * fees.REQUESTER_BPS()) / 10_000;
        if (share > 0) owed[requester][currency] += share;
        networkOwed[currency] += amount - share;
    }

    function _payAccount(address account, Currency currency) private {
        uint256 amount = owed[account][currency];
        if (amount == 0) return;
        owed[account][currency] = 0;
        if (_send(currency, account, amount)) {
            emit FeesPaid(account, currency, amount);
        } else {
            owed[account][currency] = amount;
            emit FeesOwed(account, currency, amount);
        }
    }

    function _payNetwork(Currency currency) private {
        uint256 amount = networkOwed[currency];
        if (amount == 0) return;
        address recipient = fees.feeRecipient();
        networkOwed[currency] = 0;
        if (_send(currency, recipient, amount)) {
            emit FeesPaid(recipient, currency, amount);
        } else {
            networkOwed[currency] = amount;
            emit FeesOwed(recipient, currency, amount);
        }
    }

    /// @dev A payment that reports failure instead of reverting: native ETH by call, a token by
    /// `transfer`, accepting a token that returns nothing and refusing one that returns false. At
    /// most one word of what the callee returns is copied, so a recipient or token answering with a
    /// huge revert cannot spend the claimer's gas on the copy.
    function _send(Currency currency, address to, uint256 amount) private returns (bool ok) {
        if (currency.isAddressZero()) {
            assembly ("memory-safe") {
                ok := call(gas(), to, amount, 0, 0, 0, 0)
            }
            return ok;
        }
        address token = Currency.unwrap(currency);
        if (token.code.length == 0) return false;
        bytes memory data = abi.encodeCall(IERC20.transfer, (to, amount));
        uint256 size;
        uint256 word;
        assembly ("memory-safe") {
            ok := call(gas(), token, 0, add(data, 0x20), mload(data), 0, 0)
            size := returndatasize()
            if gt(size, 0x1f) {
                returndatacopy(0, 0, 0x20)
                word := mload(0)
            }
        }
        return ok && (size == 0 || (size >= 32 && word == 1));
    }
}
