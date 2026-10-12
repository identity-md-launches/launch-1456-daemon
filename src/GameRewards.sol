// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {ERC20} from "solmate/src/tokens/ERC20.sol";
import {ReentrancyGuard} from "solmate/src/utils/ReentrancyGuard.sol";
import {NFTTreasury, IERC721Minimal} from "./NFTTreasury.sol";
import {ICreatorFeeFactory} from "./ICreatorFeeFactory.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SafeTransferLib} from "solmate/src/utils/SafeTransferLib.sol";

interface IERC721Owner {
    function ownerOf(uint256 tokenId) external view returns (address);
}

/// @notice TEST ONLY. Protected funding, existing arena ladder, and one four-week reward season.
/// The owner seals budgets/rules before play; a fixed independent authorizer publishes allocations
/// after the season. Claims pay the registered wallet, once, before the deadline. No sweeps, recipient
/// changes, arbitrary calls, purchases, or emergency withdrawals exist. See docs/SECURITY.md.
contract GameRewards is ReentrancyGuard {
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

    address public rewardAuthorizer;
    NFTTreasury public nftTreasury;
    uint256 public claimDeadline;
    uint256 public tokenBudget;
    uint256 public ethBudget;
    uint256 public nftBudget;
    bytes32 public rulesHash;
    bytes32 public allocationDocumentHash;
    bool public allocationsPublished;
    ICreatorFeeFactory public feeFactory;
    uint64 public feeLaunchNumber;
    bool public feeSourceConfigured;

    struct Allocation {
        uint256 nftId;
        uint256 tokenAmount;
        uint256 ethAmount;
        address collection;
        uint256 prizeTokenId;
        bool fromTreasury;
    }

    struct Award {
        address recipient;
        uint256 tokenAmount;
        uint256 ethAmount;
        address collection;
        uint256 prizeTokenId;
        bool fromTreasury;
    }
    mapping(uint256 => Award) public allocations;
    mapping(uint256 => bool) public claimed;
    mapping(bytes32 => bool) public allocatedNFTs;

    error ConfigurationLocked();
    error InvalidAuthority();
    error InvalidSeason();
    error InvalidAgent();
    error BudgetExceeded();
    error NotRewardAuthorizer();
    error OutsideClaimWindow();
    error AlreadyPublished();
    error InvalidAllocation();
    error IneligibleWinner();
    error DuplicateAllocation();
    error AlreadyClaimed();
    error PayerAuthorizationRequired();
    error WrongFeePool();

    event RewardAuthoritySet(address indexed authorizer, address indexed treasury);
    event SeasonConfigured(
        uint256 start, uint256 deadline, uint256 tokenBudget, uint256 ethBudget, uint256 nftBudget, bytes32 rulesHash
    );
    event AllocationPublished(
        uint256 indexed nftId,
        address indexed recipient,
        uint256 tokens,
        uint256 eth,
        address collection,
        uint256 prizeId,
        bool fromTreasury
    );
    event AllocationsFinalized(bytes32 indexed documentHash, uint256 tokens, uint256 eth, uint256 nfts);
    event RewardClaimed(uint256 indexed nftId, address indexed recipient, uint256 tokens, uint256 eth);
    event FeeSourceSet(address indexed factory, uint64 indexed launchNumber);

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
    event AgentRegistered(uint256 indexed nftId, address indexed wallet);
    event Seated(uint256 indexed championId, uint256 indexed challengerId);
    event ResultRecorded(uint256 indexed winner, uint256 indexed loser, bool draw, bool official);
    event EthReceived(address indexed from, uint256 amount);

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
        if (address(identityNft) != address(0)) revert ConfigurationLocked();
        if (nft.code.length == 0) revert NotConfigured();
        if (nft == address(0)) revert ZeroAddress();
        identityNft = IERC721Owner(nft);
        emit IdentityNftSet(nft);
    }

    function setArbiter(address arbiter_) external onlyOwner {
        if (arbiter != address(0)) revert ConfigurationLocked();
        if (arbiter_ == address(0)) revert ZeroAddress();
        arbiter = arbiter_;
        emit ArbiterSet(arbiter_);
    }

    /// @notice One-time role/custody setup. Authorizer cannot be the owner or match reporter.
    function setRewardAuthority(address authorizer, NFTTreasury treasury_) external onlyOwner {
        if (rewardAuthorizer != address(0)) revert ConfigurationLocked();
        if (authorizer == address(0) || address(treasury_).code.length == 0) revert NotConfigured();
        if (authorizer == owner || authorizer == arbiter) revert InvalidAuthority();
        rewardAuthorizer = authorizer;
        nftTreasury = treasury_;
        emit RewardAuthoritySet(authorizer, address(treasury_));
    }

    /// @notice Freeze the single season's rules, budget and deadline before it starts.
    function configureSeason(
        uint256 start,
        uint256 deadline,
        uint256 tokenBudget_,
        uint256 ethBudget_,
        uint256 nftBudget_,
        bytes32 rulesHash_
    ) external onlyOwner {
        if (seasonStart != 0) revert SeasonAlreadyStarted();
        if (start <= block.timestamp) revert SeasonInPast();
        if (address(identityNft) == address(0) || arbiter == address(0) || rewardAuthorizer == address(0)) {
            revert NotConfigured();
        }
        if (rewardAuthorizer == owner || rewardAuthorizer == arbiter) revert InvalidAuthority();
        if (deadline <= start + SEASON_LENGTH || deadline > start + SEASON_LENGTH + 90 days || rulesHash_ == bytes32(0))
        {
            revert InvalidSeason();
        }
        if (tokenBudget_ > daemon.balanceOf(address(this)) || ethBudget_ > address(this).balance || nftBudget_ > 128) {
            revert BudgetExceeded();
        }
        if (!nftTreasury.policySealed() || nftTreasury.gameRewards() != address(this)) revert NotConfigured();
        seasonStart = start;
        claimDeadline = deadline;
        tokenBudget = tokenBudget_;
        ethBudget = ethBudget_;
        nftBudget = nftBudget_;
        rulesHash = rulesHash_;
        prizesActive = true;
        emit SeasonConfigured(start, deadline, tokenBudget_, ethBudget_, nftBudget_, rulesHash_);
    }

    /// @notice Optional keeper entry point for the verified factory's native claimFees flow.
    /// The CURRENT payer must first call factory.setRequester(launchNumber, address(this)).
    function setFeeSource(ICreatorFeeFactory factory_, uint64 launchNumber_) external onlyOwner {
        if (feeSourceConfigured) revert ConfigurationLocked();
        if (address(factory_).code.length == 0) revert NotConfigured();
        feeFactory = factory_;
        feeLaunchNumber = launchNumber_;
        feeSourceConfigured = true;
        emit FeeSourceSet(address(factory_), launchNumber_);
    }

    function collectCreatorFees() external nonReentrant returns (uint256 amount0, uint256 amount1) {
        if (!feeSourceConfigured) revert NotConfigured();
        (PoolKey memory key,,, address requester) = feeFactory.positionOf(feeLaunchNumber);
        if (requester != address(this)) revert PayerAuthorizationRequired();
        if (!((key.currency0.isAddressZero() && Currency.unwrap(key.currency1) == address(daemon))
                    || (key.currency1.isAddressZero() && Currency.unwrap(key.currency0) == address(daemon)))) revert WrongFeePool();
        return feeFactory.claimFees(feeLaunchNumber);
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
        if (nftId == 0) revert InvalidAgent();
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

    /// @notice A published allocation is immutable, identifies the registered winner and is capped by
    /// the sealed season budget. A content hash links the public result/rules document to these events.
    function publishAllocations(Allocation[] calldata awards, bytes32 documentHash) external {
        if (msg.sender != rewardAuthorizer) revert NotRewardAuthorizer();
        if (!prizesActive) revert PrizesInactive();
        if (block.timestamp < seasonStart + SEASON_LENGTH || block.timestamp > claimDeadline) {
            revert OutsideClaimWindow();
        }
        if (allocationsPublished) revert AlreadyPublished();
        if (documentHash == bytes32(0) || awards.length == 0 || awards.length > 128) revert InvalidAllocation();
        allocationsPublished = true;
        allocationDocumentHash = documentHash;
        uint256 tokens;
        uint256 eth;
        uint256 nfts;
        for (uint256 i; i < awards.length; ++i) {
            Allocation calldata a = awards[i];
            if (a.nftId == EXCLUDED_NFT) revert ExcludedFromPrizes(a.nftId);
            Agent storage agent = agents[a.nftId];
            if (!agent.registered || agent.officialWins == 0) revert IneligibleWinner();
            if (allocations[a.nftId].recipient != address(0)) revert DuplicateAllocation();
            if (a.tokenAmount == 0 && a.ethAmount == 0 && a.collection == address(0)) revert InvalidAllocation();
            if (a.collection != address(0)) {
                if (a.prizeTokenId == EXCLUDED_NFT) revert ExcludedFromPrizes(a.prizeTokenId);
                bytes32 nftKey = keccak256(abi.encode(a.collection, a.prizeTokenId));
                if (allocatedNFTs[nftKey]) revert DuplicateAllocation();
                allocatedNFTs[nftKey] = true;
                address custodian = a.fromTreasury ? address(nftTreasury) : address(this);
                if (IERC721Minimal(a.collection).ownerOf(a.prizeTokenId) != custodian) revert InvalidAllocation();
                ++nfts;
            } else if (a.prizeTokenId != 0 || a.fromTreasury) {
                revert InvalidAllocation();
            }
            tokens += a.tokenAmount;
            eth += a.ethAmount;
            allocations[a.nftId] =
                Award(agent.wallet, a.tokenAmount, a.ethAmount, a.collection, a.prizeTokenId, a.fromTreasury);
            emit AllocationPublished(
                a.nftId, agent.wallet, a.tokenAmount, a.ethAmount, a.collection, a.prizeTokenId, a.fromTreasury
            );
        }
        if (tokens > tokenBudget || eth > ethBudget || nfts > nftBudget) revert BudgetExceeded();
        emit AllocationsFinalized(documentHash, tokens, eth, nfts);
    }

    /// @notice Anyone can relay a claim, but its recipient and amounts cannot be supplied or changed.
    function claimReward(uint256 nftId) external nonReentrant {
        if (!allocationsPublished) revert PrizesInactive();
        if (block.timestamp < seasonStart + SEASON_LENGTH || block.timestamp > claimDeadline) {
            revert OutsideClaimWindow();
        }
        if (claimed[nftId]) revert AlreadyClaimed();
        Award memory a = allocations[nftId];
        if (a.recipient == address(0)) revert InvalidAllocation();
        claimed[nftId] = true;
        totalPrizesPaid += a.tokenAmount;
        if (a.tokenAmount > 0) daemon.safeTransfer(a.recipient, a.tokenAmount);
        if (a.ethAmount > 0) SafeTransferLib.safeTransferETH(a.recipient, a.ethAmount);
        if (a.collection != address(0)) {
            if (a.fromTreasury) {
                nftTreasury.deliverPrize(a.collection, a.prizeTokenId, a.recipient);
            } else {
                IERC721Minimal(a.collection).safeTransferFrom(address(this), a.recipient, a.prizeTokenId);
                if (IERC721Minimal(a.collection).ownerOf(a.prizeTokenId) != a.recipient) revert InvalidAllocation();
            }
        }
        emit RewardClaimed(nftId, a.recipient, a.tokenAmount, a.ethAmount);
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
