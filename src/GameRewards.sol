// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

interface IERC721Owner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @title GameRewards
/// @notice Prize pool for the agent chess arena plus an on-chain "winner stays" ladder record.
/// @dev Funding: the 4% game-rewards allocation (from DistributionReceiver) and the creator share of pool fees
/// (whatever the launch factory forwards; ETH is accepted through `receive()`). Nothing here reads or touches
/// the pool.
///
/// Participation: an agent registers with an IdentityMD NFT id from the wallet that owns it. Two agents must
/// use different NFTs and different wallets. Results are reported by the owner-set `arbiter` (the arena
/// server's key): the winner keeps the seat, the loser leaves, the next waiting agent is seated. The contract
/// does not play chess and contains no engine; it only records what the arena reports.
///
/// Prizes: `prizesActive` starts false and stays false for the trial. Founder NFT #222 can never receive a
/// prize. Results reported before `seasonStart` or after `seasonStart + SEASON_LENGTH` are test scores and do
/// not count toward official wins and streaks.
contract GameRewards {
    using SafeTransferLib for ERC20;

    uint256 public constant EXCLUDED_NFT = 222;
    uint256 public constant SEASON_LENGTH = 4 weeks;

    ERC20 public immutable daemon;
    address public owner;
    address public pendingOwner;
    /// @notice IdentityMD NFT collection used to authenticate agents (owner-set after launch).
    IERC721Owner public identityNft;
    /// @notice Key that reports arena results (owner-set after launch).
    address public arbiter;
    bool public prizesActive;
    /// @notice Start of the official four-week season; zero until the owner sets it at the real launch.
    uint256 public seasonStart;

    // ---- ladder state
    struct Agent {
        address wallet;
        bool registered;
        bool seated;
        uint256 officialWins;
        uint256 officialStreak;
        uint256 bestOfficialStreak;
        uint256 testWins;
    }

    mapping(uint256 nftId => Agent) public agents;
    mapping(address wallet => uint256 nftId) public nftOfWallet;
    /// @notice Current champion NFT id (0 = empty seat) and the challenger facing it (0 = none).
    uint256 public champion;
    uint256 public challenger;
    uint256[] private queue;
    uint256 private queueHead;
    uint256 public totalPrizesPaid;

    event OwnershipTransferStarted(address indexed previousOwner, address indexed newOwner);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event IdentityNftSet(address indexed nft);
    event ArbiterSet(address indexed arbiter);
    event PrizesActiveSet(bool active);
    event SeasonStartSet(uint256 start);
    event AgentRegistered(uint256 indexed nftId, address indexed wallet);
    event Seated(uint256 indexed championId, uint256 indexed challengerId);
    event ResultRecorded(uint256 indexed winner, uint256 indexed loser, bool draw, bool official);
    event PrizePaid(uint256 indexed nftId, address indexed to, uint256 amount);
    event EthReceived(address indexed from, uint256 amount);
    event EthWithdrawn(address indexed to, uint256 amount);

    error NotOwner();
    error NotPendingOwner();
    error NotArbiter();
    error ZeroAddress();
    error NotConfigured();
    error NotNftOwner(uint256 nftId, address wallet);
    error AlreadyRegistered(uint256 nftId);
    error WalletAlreadyRegistered(address wallet, uint256 nftId);
    error NotInMatch(uint256 nftId);
    error NoMatchInProgress();
    error PrizesInactive();
    error ExcludedFromPrizes(uint256 nftId);
    error SeasonAlreadyStarted();
    error SeasonInPast();
    error EthTransferFailed();

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /// @param daemon_ DAEMON token (launch manifest: "$token").
    /// @param owner_ Owner (launch manifest: "$owner").
    constructor(ERC20 daemon_, address owner_) {
        if (address(daemon_) == address(0) || owner_ == address(0)) revert ZeroAddress();
        daemon = daemon_;
        owner = owner_;
        emit OwnershipTransferred(address(0), owner_);
    }

    receive() external payable {
        emit EthReceived(msg.sender, msg.value);
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

    function setIdentityNft(address nft) external onlyOwner {
        if (nft == address(0)) revert ZeroAddress();
        identityNft = IERC721Owner(nft);
        emit IdentityNftSet(nft);
    }

    function setArbiter(address arbiter_) external onlyOwner {
        if (arbiter_ == address(0)) revert ZeroAddress();
        arbiter = arbiter_;
        emit ArbiterSet(arbiter_);
    }

    function setPrizesActive(bool active) external onlyOwner {
        prizesActive = active;
        emit PrizesActiveSet(active);
    }

    /// @notice Sets the official season start (the real launch). Can only be set once, and only in the future.
    function setSeasonStart(uint256 start) external onlyOwner {
        if (seasonStart != 0) revert SeasonAlreadyStarted();
        if (start <= block.timestamp) revert SeasonInPast();
        seasonStart = start;
        emit SeasonStartSet(start);
    }

    function withdrawEth(address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        (bool ok,) = to.call{value: amount}("");
        if (!ok) revert EthTransferFailed();
        emit EthWithdrawn(to, amount);
    }

    // ------------------------------------------------------------------ views

    function isOfficial() public view returns (bool) {
        return seasonStart != 0 && block.timestamp >= seasonStart && block.timestamp < seasonStart + SEASON_LENGTH;
    }

    function waitingCount() external view returns (uint256) {
        return queue.length - queueHead;
    }

    // ------------------------------------------------------------------ ladder

    /// @notice Registers the caller's NFT as an agent and queues it. One NFT per wallet, one wallet per NFT.
    function register(uint256 nftId) external {
        if (address(identityNft) == address(0)) revert NotConfigured();
        if (identityNft.ownerOf(nftId) != msg.sender) revert NotNftOwner(nftId, msg.sender);
        if (agents[nftId].registered) revert AlreadyRegistered(nftId);
        if (nftOfWallet[msg.sender] != 0) revert WalletAlreadyRegistered(msg.sender, nftOfWallet[msg.sender]);
        agents[nftId] = Agent({
            wallet: msg.sender,
            registered: true,
            seated: false,
            officialWins: 0,
            officialStreak: 0,
            bestOfficialStreak: 0,
            testWins: 0
        });
        nftOfWallet[msg.sender] = nftId;
        emit AgentRegistered(nftId, msg.sender);
        queue.push(nftId);
        _seat();
    }

    /// @notice Records a result for the match in progress. Winner stays, loser leaves; on a draw both leave
    /// and re-queue. Only the arbiter may call.
    function reportResult(uint256 winner, uint256 loser, bool draw) external {
        if (msg.sender != arbiter) revert NotArbiter();
        if (champion == 0 || challenger == 0) revert NoMatchInProgress();
        bool winnerSeated = winner == champion || winner == challenger;
        bool loserSeated = loser == champion || loser == challenger;
        if (!winnerSeated || !loserSeated || winner == loser) revert NotInMatch(winner);

        bool official = isOfficial();
        if (draw) {
            agents[champion].officialStreak = 0;
            agents[challenger].officialStreak = 0;
            agents[champion].seated = false;
            agents[challenger].seated = false;
            queue.push(champion);
            queue.push(challenger);
            champion = 0;
            challenger = 0;
        } else {
            Agent storage w = agents[winner];
            if (official) {
                w.officialWins += 1;
                w.officialStreak += 1;
                if (w.officialStreak > w.bestOfficialStreak) w.bestOfficialStreak = w.officialStreak;
            } else {
                w.testWins += 1;
            }
            agents[loser].officialStreak = 0;
            agents[loser].seated = false;
            champion = winner;
            challenger = 0;
        }
        emit ResultRecorded(winner, loser, draw, official);
        _seat();
    }

    /// @dev Fills the champion seat and then the challenger seat from the queue.
    function _seat() internal {
        if (champion == 0 && queueHead < queue.length) {
            champion = queue[queueHead++];
            agents[champion].seated = true;
        }
        if (champion != 0 && challenger == 0 && queueHead < queue.length) {
            challenger = queue[queueHead++];
            agents[challenger].seated = true;
            emit Seated(champion, challenger);
        }
    }

    // ------------------------------------------------------------------ prizes

    /// @notice Pays a DAEMON prize to the current owner of `nftId`. Owner only; disabled until `prizesActive`.
    function awardPrize(uint256 nftId, uint256 amount) external onlyOwner {
        if (!prizesActive) revert PrizesInactive();
        if (nftId == EXCLUDED_NFT) revert ExcludedFromPrizes(nftId);
        if (address(identityNft) == address(0)) revert NotConfigured();
        address to = identityNft.ownerOf(nftId);
        totalPrizesPaid += amount;
        daemon.safeTransfer(to, amount);
        emit PrizePaid(nftId, to, amount);
    }
}
