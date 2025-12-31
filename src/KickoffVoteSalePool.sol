// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EpochLib} from "./libraries/EpochLib.sol";
import {LPLocker} from "./LPLocker.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {IVoter} from "./interfaces/IVoter.sol";
import {IRouter} from "./interfaces/IRouter.sol";
import {IPool} from "./interfaces/IPool.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IERC721Receiver} from "./interfaces/IERC721Receiver.sol";
import {IVotingReward} from "./interfaces/IVotingReward.sol";

/// @title KickoffVoteSalePool
/// @notice Vote-Sale pool for veAERO holders to participate in project launches
/// @dev Handles locking veAERO NFTs, voting, claiming rewards, and distributing project tokens
contract KickoffVoteSalePool is IERC721Receiver {
    using EpochLib for uint256;

    /*//////////////////////////////////////////////////////////////
                            REENTRANCY GUARD
    //////////////////////////////////////////////////////////////*/

    uint256 private constant NOT_ENTERED = 1;
    uint256 private constant ENTERED = 2;
    uint256 private _reentrancyStatus = NOT_ENTERED;

    modifier nonReentrant() {
        if (_reentrancyStatus == ENTERED) revert ReentrancyGuardReentrantCall();
        _reentrancyStatus = ENTERED;
        _;
        _reentrancyStatus = NOT_ENTERED;
    }

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotAdmin();
    error NotOwner();
    error ZeroAddress();
    error InvalidState();
    error NotNFTOwner();
    error AlreadyVotedThisEpoch();
    error NFTNotLocked();
    error AlreadyClaimed();
    error NothingToClaim();
    error TransferFailed();
    error LockingClosed();
    error NotProjectToken();
    error SwapFailed();
    error BatchInProgress();
    error NoBatchInProgress();
    error BatchSizeTooLarge();
    error ReentrancyGuardReentrantCall();
    error SlippageExceeded();
    error InvalidGauge();
    error GaugeNotActive();
    error EpochNotEnded();
    error VotingPowerTooLow();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event VeAEROLocked(address indexed user, uint256 indexed tokenId, uint256 votingPower);
    event VeAEROUnlocked(address indexed user, uint256 indexed tokenId);
    event VotesCast(address indexed gauge, uint256 totalVotingPower);
    event EpochFinalized(uint256 wethCollected, uint256 lpCreated);
    event ProjectTokensClaimed(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed tokenId);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);
    event StateChanged(PoolState previousState, PoolState newState);
    event BatchProgress(string operation, uint256 processed, uint256 total);

    /*//////////////////////////////////////////////////////////////
                                 ENUMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pool states
    enum PoolState {
        Inactive, // Pool created, waiting for activation
        Active, // Accepting veAERO locks
        Voting, // Voting period
        Finalizing, // Claiming rewards and creating LP
        Completed // All done, claims open
    }

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Info about a locked veAERO NFT
    struct LockedNFT {
        address owner;
        uint256 votingPower;
        bool unlocked;
    }

    /// @notice User participation info
    struct UserInfo {
        uint256 totalVotingPower;
        bool claimed;
    }

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Admin address (pool creator, receives 30% trading fees)
    address public immutable admin;

    /// @notice Project owner address (receives 70% trading fees)
    address public immutable projectOwner;

    /// @notice Project token address
    address public immutable projectToken;

    /// @notice Total allocation of project tokens (50% sale, 50% liquidity)
    uint256 public immutable totalAllocation;

    /// @notice Sale allocation (50% of total, for participants)
    uint256 public immutable saleAllocation;

    /// @notice Liquidity allocation (50% of total, for LP creation)
    uint256 public immutable liquidityAllocation;

    /// @notice Minimum voting power required to lock veAERO NFT
    uint256 public immutable minVotingPower;

    /// @notice LP Locker contract
    LPLocker public immutable lpLocker;

    /// @notice Aerodrome VotingEscrow contract
    IVotingEscrow public immutable votingEscrow;

    /// @notice Aerodrome Voter contract
    IVoter public immutable voter;

    /// @notice Aerodrome Router contract
    IRouter public immutable router;

    /// @notice WETH contract
    IWETH public immutable weth;

    /// @notice Protocol owner (for emergency functions)
    address public owner;

    /// @notice Pending owner for two-step transfer
    address public pendingOwner;

    /// @notice Current pool state
    PoolState public state;

    /// @notice Gauge address (set during castVotes)
    address public gauge;

    /// @notice Aerodrome pool for the LP
    address public aerodromePool;

    /// @notice LP token address
    address public lpToken;

    /// @notice Epoch when the pool was activated
    uint256 public activeEpoch;

    /// @notice Total voting power locked
    uint256 public totalVotingPower;

    /// @notice Total WETH collected from bribes/fees
    uint256 public wethCollected;

    /// @notice Total LP created
    uint256 public lpCreated;

    /// @notice Mapping of tokenId to locked NFT info
    mapping(uint256 => LockedNFT) public lockedNFTs;

    /// @notice Array of all locked token IDs
    uint256[] public lockedTokenIds;

    /// @notice Mapping of user address to their info
    mapping(address => UserInfo) public userInfo;

    /*//////////////////////////////////////////////////////////////
                           BATCH PROCESSING
    //////////////////////////////////////////////////////////////*/

    /// @notice Maximum NFTs to process per batch (gas optimization)
    uint256 public constant MAX_BATCH_SIZE = 50;

    /// @notice Index of last processed NFT in current batch operation
    uint256 public batchIndex;

    /// @notice Whether a batch operation is in progress
    bool public batchInProgress;

    /// @notice Bribe tokens for batch claim (stored between batches)
    /// @dev Cached reward tokens for batch operations (auto-discovered)
    address[] private _cachedRewardTokens;

    /*//////////////////////////////////////////////////////////////
                          SLIPPAGE PROTECTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Default slippage tolerance in basis points (5% = 500)
    uint256 public constant DEFAULT_SLIPPAGE_BPS = 500;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Slippage tolerance for swaps (in basis points)
    uint256 public swapSlippageBps = DEFAULT_SLIPPAGE_BPS;

    /// @notice Slippage tolerance for adding liquidity (in basis points)
    uint256 public liquiditySlippageBps = DEFAULT_SLIPPAGE_BPS;

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyAdmin() {
        if (msg.sender != admin) revert NotAdmin();
        _;
    }

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier inState(PoolState _state) {
        if (state != _state) revert InvalidState();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new Vote-Sale pool
    constructor(
        address _projectToken,
        address _admin,
        address _projectOwner,
        uint256 _totalAllocation,
        uint256 _minVotingPower,
        address _lpLocker,
        address _votingEscrow,
        address _voter,
        address _router,
        address _weth
    ) {
        projectToken = _projectToken;
        admin = _admin;
        projectOwner = _projectOwner;
        totalAllocation = _totalAllocation;
        saleAllocation = _totalAllocation / 2;
        liquidityAllocation = _totalAllocation - saleAllocation;
        minVotingPower = _minVotingPower;

        lpLocker = LPLocker(_lpLocker);
        votingEscrow = IVotingEscrow(_votingEscrow);
        voter = IVoter(_voter);
        router = IRouter(_router);
        weth = IWETH(_weth);

        owner = _admin;
        state = PoolState.Inactive;
    }

    /*//////////////////////////////////////////////////////////////
                           ERC721 RECEIVER
    //////////////////////////////////////////////////////////////*/

    /// @notice Handle receipt of veAERO NFT
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return IERC721Receiver.onERC721Received.selector;
    }

    /*//////////////////////////////////////////////////////////////
                        PHASE 1: LOCK veAERO
    //////////////////////////////////////////////////////////////*/

    /// @notice Activate the pool for the current epoch
    function activate() external onlyAdmin inState(PoolState.Inactive) {
        activeEpoch = EpochLib.currentEpoch();
        _setState(PoolState.Active);
    }

    /// @notice Lock a veAERO NFT to participate in the vote-sale
    /// @param tokenId The veAERO NFT token ID
    function lockVeAERO(uint256 tokenId) external nonReentrant inState(PoolState.Active) {
        // Check ownership
        if (votingEscrow.ownerOf(tokenId) != msg.sender) {
            revert NotNFTOwner();
        }

        // Check if NFT hasn't voted this epoch
        uint256 lastVoted = voter.lastVoted(tokenId);
        if (EpochLib.hasVotedThisEpoch(lastVoted)) {
            revert AlreadyVotedThisEpoch();
        }

        // Get voting power
        uint256 votingPowerAmount = votingEscrow.balanceOfNFT(tokenId);
        
        // Check minimum voting power requirement
        if (votingPowerAmount < minVotingPower) {
            revert VotingPowerTooLow();
        }

        // Transfer NFT to this contract
        votingEscrow.safeTransferFrom(msg.sender, address(this), tokenId);

        // Store locked NFT info
        lockedNFTs[tokenId] = LockedNFT({owner: msg.sender, votingPower: votingPowerAmount, unlocked: false});

        lockedTokenIds.push(tokenId);

        // Update user info
        userInfo[msg.sender].totalVotingPower += votingPowerAmount;

        // Update total voting power
        totalVotingPower += votingPowerAmount;

        emit VeAEROLocked(msg.sender, tokenId, votingPowerAmount);
    }

    /*//////////////////////////////////////////////////////////////
                        PHASE 2: CAST VOTES (BATCH)
    //////////////////////////////////////////////////////////////*/

    /// @notice Start or continue casting votes in batches
    /// @param _gauge The Aerodrome gauge to vote for (only used on first call)
    /// @param batchSize Number of NFTs to process in this batch (max MAX_BATCH_SIZE)
    /// @dev Call multiple times until getVotingProgress().inProgress returns false
    /// @dev State changes to Voting on first batch, blocking further NFT locks
    function castVotesBatch(address _gauge, uint256 batchSize) external onlyAdmin {
        // First batch requires Active state, subsequent batches require Voting state with batch in progress
        if (!batchInProgress) {
            if (state != PoolState.Active) revert InvalidState();
        } else {
            if (state != PoolState.Voting) revert InvalidState();
        }
        
        if (batchSize > MAX_BATCH_SIZE) revert BatchSizeTooLarge();
        
        uint256 length = lockedTokenIds.length;
        if (length == 0) {
            _setState(PoolState.Voting);
            emit VotesCast(_gauge, 0);
            return;
        }

        // First batch - initialize and change state immediately
        if (!batchInProgress) {
            if (_gauge == address(0)) revert ZeroAddress();
            
            // Validate gauge
            address pool = voter.poolForGauge(_gauge);
            if (pool == address(0)) revert InvalidGauge();
            if (!voter.isAlive(_gauge)) revert GaugeNotActive();
            
            gauge = _gauge;
            aerodromePool = pool;
            
            // Note: bribe addresses are fetched dynamically during claim via gaugeToFees/gaugeToBribe
            
            batchIndex = 0;
            batchInProgress = true;
            
            // Change state to Voting immediately - this blocks further NFT locks
            _setState(PoolState.Voting);
        }

        // Calculate end index
        uint256 endIndex = batchIndex + batchSize;
        if (endIndex > length) endIndex = length;

        // Prepare vote arrays
        address[] memory pools = new address[](1);
        uint256[] memory weights = new uint256[](1);
        pools[0] = aerodromePool;
        weights[0] = 1;

        // Vote with NFTs in this batch
        for (uint256 i = batchIndex; i < endIndex;) {
            voter.vote(lockedTokenIds[i], pools, weights);
            unchecked { ++i; }
        }

        batchIndex = endIndex;
        emit BatchProgress("castVotes", batchIndex, length);

        // Check if complete
        if (batchIndex >= length) {
            batchInProgress = false;
            batchIndex = 0;
            // State is already Voting
            emit VotesCast(gauge, totalVotingPower);
        }
    }

    /// @notice Cast all votes in one transaction (for small number of NFTs)
    /// @param _gauge The Aerodrome gauge to vote for
    /// @dev Use castVotesBatch for large numbers of NFTs
    function castVotes(address _gauge) external onlyAdmin inState(PoolState.Active) {
        if (batchInProgress) revert BatchInProgress();
        if (_gauge == address(0)) revert ZeroAddress();

        // Validate gauge
        address pool = voter.poolForGauge(_gauge);
        if (pool == address(0)) revert InvalidGauge();
        if (!voter.isAlive(_gauge)) revert GaugeNotActive();

        gauge = _gauge;
        aerodromePool = pool;
        
        // Note: bribe addresses are fetched dynamically during claim via gaugeToFees/gaugeToBribe

        address[] memory pools = new address[](1);
        uint256[] memory weights = new uint256[](1);
        pools[0] = aerodromePool;
        weights[0] = 1;

        uint256 length = lockedTokenIds.length;
        for (uint256 i = 0; i < length;) {
            voter.vote(lockedTokenIds[i], pools, weights);
            unchecked { ++i; }
        }

        _setState(PoolState.Voting);
        emit VotesCast(_gauge, totalVotingPower);
    }

    /// @notice Check voting batch progress
    /// @return processed Number of NFTs processed
    /// @return total Total number of NFTs
    /// @return inProgress Whether batch is in progress
    function getVotingProgress() external view returns (uint256 processed, uint256 total, bool inProgress) {
        return (batchIndex, lockedTokenIds.length, batchInProgress);
    }

    /*//////////////////////////////////////////////////////////////
                    PHASE 3-5: FINALIZE EPOCH (BATCH)
    //////////////////////////////////////////////////////////////*/

    /// @notice Finalize step enum for batch processing
    enum FinalizeStep {
        NotStarted,
        ClaimingRewards,
        ConvertingToWETH,
        AddingLiquidity,
        Completed
    }

    /// @notice Current finalize step
    FinalizeStep public finalizeStep;

    /// @notice Start claiming rewards in batches with auto-discovery of reward tokens
    /// @param batchSize Number of NFTs to process per batch
    function startClaimRewardsBatch(uint256 batchSize) 
        external 
        onlyAdmin 
        inState(PoolState.Voting) 
    {
        if (batchInProgress) revert BatchInProgress();
        
        // Ensure voting epoch has ended (rewards are only claimable after epoch end)
        if (block.timestamp < EpochLib.epochEnd(activeEpoch)) revert EpochNotEnded();
        
        _setState(PoolState.Finalizing);
        finalizeStep = FinalizeStep.ClaimingRewards;
        
        // Auto-discover and cache reward tokens
        delete _cachedRewardTokens;
        address[] memory discovered = _discoverRewardTokens();
        for (uint256 i = 0; i < discovered.length; i++) {
            _cachedRewardTokens.push(discovered[i]);
        }
        
        batchIndex = 0;
        batchInProgress = true;
        
        _claimRewardsBatchInternal(batchSize);
    }

    /// @notice Continue claiming rewards batch
    /// @param batchSize Number of NFTs to process
    function continueClaimRewardsBatch(uint256 batchSize) external onlyAdmin inState(PoolState.Finalizing) {
        if (!batchInProgress) revert NoBatchInProgress();
        if (finalizeStep != FinalizeStep.ClaimingRewards) revert InvalidState();
        
        _claimRewardsBatchInternal(batchSize);
    }

    /// @notice Internal batch claim logic
    /// @dev Gets bribe addresses dynamically via gaugeToFees/gaugeToBribe (Aerodrome V2)
    function _claimRewardsBatchInternal(uint256 batchSize) internal {
        if (batchSize > MAX_BATCH_SIZE) revert BatchSizeTooLarge();
        
        uint256 length = lockedTokenIds.length;
        if (length == 0) {
            batchInProgress = false;
            batchIndex = 0;
            finalizeStep = FinalizeStep.ConvertingToWETH;
            emit BatchProgress("claimRewards", 0, 0);
            return;
        }

        uint256 endIndex = batchIndex + batchSize;
        if (endIndex > length) endIndex = length;

        // Get bribe addresses dynamically (works in any epoch)
        address feesReward;
        address bribeReward;
        
        try voter.gaugeToFees(gauge) returns (address _fees) {
            feesReward = _fees;
        } catch {}
        
        try voter.gaugeToBribe(gauge) returns (address _bribe) {
            bribeReward = _bribe;
        } catch {}

        // If no reward contracts found, skip to next step
        if (feesReward == address(0) && bribeReward == address(0)) {
            batchInProgress = false;
            batchIndex = 0;
            finalizeStep = FinalizeStep.ConvertingToWETH;
            emit BatchProgress("claimRewards", length, length);
            return;
        }

        // Build arrays only with valid (non-zero) addresses
        uint256 rewardContractCount = (feesReward != address(0) ? 1 : 0) + (bribeReward != address(0) ? 1 : 0);
        address[] memory rewardContracts = new address[](rewardContractCount);
        address[][] memory tokenArrays = new address[][](rewardContractCount);
        
        uint256 idx = 0;
        if (feesReward != address(0)) {
            rewardContracts[idx] = feesReward;
            tokenArrays[idx] = _cachedRewardTokens;
            idx++;
        }
        if (bribeReward != address(0)) {
            rewardContracts[idx] = bribeReward;
            tokenArrays[idx] = _cachedRewardTokens;
        }

        for (uint256 i = batchIndex; i < endIndex;) {
            uint256 tokenId = lockedTokenIds[i];
            // Single call claims from all reward contracts (fees + bribes)
            try voter.claimBribes(rewardContracts, tokenArrays, tokenId) {} catch {}
            unchecked { ++i; }
        }

        batchIndex = endIndex;
        emit BatchProgress("claimRewards", batchIndex, length);

        if (batchIndex >= length) {
            batchInProgress = false;
            batchIndex = 0;
            finalizeStep = FinalizeStep.ConvertingToWETH;
        }
    }

    /// @notice Convert rewards to WETH and complete finalization
    /// @dev Call after claimRewards batch is complete
    function completeFinalization() external nonReentrant onlyAdmin inState(PoolState.Finalizing) {
        if (batchInProgress) revert BatchInProgress();
        if (finalizeStep != FinalizeStep.ConvertingToWETH) revert InvalidState();

        // Convert all cached tokens to WETH
        _convertToWETHInternal(_cachedRewardTokens);

        // Add liquidity
        _addLiquidity();

        // Lock LP
        _lockLP();

        // Cleanup
        delete _cachedRewardTokens;
        finalizeStep = FinalizeStep.Completed;
        
        _setState(PoolState.Completed);
        emit EpochFinalized(wethCollected, lpCreated);
    }

    /// @notice Finalize the epoch in one transaction (for small number of NFTs)
    /// @dev Automatically discovers reward tokens from VotingReward contracts
    /// @dev Use batch functions for large numbers of NFTs
    function finalizeEpoch() external nonReentrant onlyAdmin inState(PoolState.Voting) {
        if (batchInProgress) revert BatchInProgress();
        
        // Ensure voting epoch has ended (rewards are only claimable after epoch end)
        if (block.timestamp < EpochLib.epochEnd(activeEpoch)) revert EpochNotEnded();
        
        _setState(PoolState.Finalizing);

        // Auto-discover reward tokens
        address[] memory rewardTokens = _discoverRewardTokens();

        // Claim all rewards
        _claimRewardsAll(rewardTokens);

        // Convert to WETH
        _convertToWETHInternal(rewardTokens);

        // Add liquidity
        _addLiquidity();

        // Lock LP
        _lockLP();

        _setState(PoolState.Completed);
        emit EpochFinalized(wethCollected, lpCreated);
    }

    /// @notice Discover reward tokens that have earned rewards for our locked NFTs
    /// @dev Checks both fees and bribe contracts, returns only tokens with actual rewards
    /// @return tokens Array of token addresses that have rewards to claim
    function _discoverRewardTokens() internal view returns (address[] memory tokens) {
        address feesReward;
        address bribeReward;
        
        try voter.gaugeToFees(gauge) returns (address _f) { feesReward = _f; } catch {}
        try voter.gaugeToBribe(gauge) returns (address _b) { bribeReward = _b; } catch {}
        
        // Get tokens with actual rewards from both contracts
        address[] memory feesTokens = _getTokensWithRewards(feesReward);
        address[] memory bribeTokens = _getTokensWithRewards(bribeReward);
        
        // Combine arrays (deduplicate)
        return _mergeTokenArrays(feesTokens, bribeTokens);
    }

    /// @notice Get tokens that have actual earned rewards in a VotingReward contract
    /// @dev Uses low-level calls for rewardsListLength + rewardsList + earned
    function _getTokensWithRewards(address rewardContract) internal view returns (address[] memory tokens) {
        if (rewardContract == address(0)) return new address[](0);
        
        // Get rewards list length
        uint256 length = _getRewardsListLength(rewardContract);
        if (length == 0) return new address[](0);
        if (length > 30) length = 30;
        
        // Collect tokens that have rewards
        address[] memory tempTokens = new address[](length);
        uint256 validCount = 0;
        
        for (uint256 i = 0; i < length; i++) {
            address token = _getRewardTokenAt(rewardContract, i);
            if (token == address(0)) continue;
            
            if (_hasEarnedRewards(rewardContract, token)) {
                tempTokens[validCount++] = token;
            }
        }
        
        // Copy to correctly sized array
        tokens = new address[](validCount);
        for (uint256 i = 0; i < validCount; i++) {
            tokens[i] = tempTokens[i];
        }
    }

    /// @notice Get rewardsListLength from a VotingReward contract
    function _getRewardsListLength(address rewardContract) internal view returns (uint256) {
        (bool success, bytes memory data) = rewardContract.staticcall(
            abi.encodeWithSignature("rewardsListLength()")
        );
        if (!success || data.length < 32) return 0;
        return abi.decode(data, (uint256));
    }

    /// @notice Get reward token at index from a VotingReward contract
    /// @dev Aerodrome uses `rewards` array, so getter is rewards(uint256)
    function _getRewardTokenAt(address rewardContract, uint256 index) internal view returns (address) {
        // Aerodrome VotingReward stores tokens in `rewards` array
        (bool success, bytes memory data) = rewardContract.staticcall(
            abi.encodeWithSignature("rewards(uint256)", index)
        );
        if (success && data.length >= 32) {
            return abi.decode(data, (address));
        }
        return address(0);
    }

    /// @notice Check if any locked NFT has earned rewards for a token
    /// @dev Checks all NFTs - if any has rewards, returns true immediately
    function _hasEarnedRewards(address rewardContract, address token) internal view returns (bool) {
        uint256 nftCount = lockedTokenIds.length;
        
        for (uint256 i = 0; i < nftCount; i++) {
            (bool success, bytes memory data) = rewardContract.staticcall(
                abi.encodeWithSignature("earned(address,uint256)", token, lockedTokenIds[i])
            );
            if (success && data.length >= 32) {
                uint256 earned = abi.decode(data, (uint256));
                if (earned > 0) return true;
            }
        }
        return false;
    }

    /// @notice Merge two token arrays and remove duplicates
    function _mergeTokenArrays(address[] memory a, address[] memory b) internal pure returns (address[] memory) {
        if (a.length == 0) return b;
        if (b.length == 0) return a;
        
        // Combine with deduplication
        address[] memory temp = new address[](a.length + b.length);
        uint256 count = 0;
        
        // Add all from a
        for (uint256 i = 0; i < a.length; i++) {
            temp[count++] = a[i];
        }
        
        // Add from b if not duplicate
        for (uint256 i = 0; i < b.length; i++) {
            bool isDuplicate = false;
            for (uint256 j = 0; j < a.length; j++) {
                if (b[i] == a[j]) {
                    isDuplicate = true;
                    break;
                }
            }
            if (!isDuplicate) {
                temp[count++] = b[i];
            }
        }
        
        // Copy to correctly sized array
        address[] memory result = new address[](count);
        for (uint256 i = 0; i < count; i++) {
            result[i] = temp[i];
        }
        return result;
    }

    /// @notice Claim all rewards in one transaction
    /// @dev Gets bribe addresses dynamically via gaugeToFees/gaugeToBribe (Aerodrome V2)
    function _claimRewardsAll(address[] memory rewardTokens) internal {
        // Get bribe addresses dynamically (works in any epoch)
        address feesReward;
        address bribeReward;
        
        try voter.gaugeToFees(gauge) returns (address _fees) {
            feesReward = _fees;
        } catch {}
        
        try voter.gaugeToBribe(gauge) returns (address _bribe) {
            bribeReward = _bribe;
        } catch {}

        // If no reward contracts found, skip claiming
        if (feesReward == address(0) && bribeReward == address(0)) {
            return;
        }

        // Build arrays only with valid (non-zero) addresses
        uint256 rewardContractCount = (feesReward != address(0) ? 1 : 0) + (bribeReward != address(0) ? 1 : 0);
        address[] memory rewardContracts = new address[](rewardContractCount);
        address[][] memory tokenArrays = new address[][](rewardContractCount);
        
        uint256 idx = 0;
        if (feesReward != address(0)) {
            rewardContracts[idx] = feesReward;
            tokenArrays[idx] = rewardTokens;
            idx++;
        }
        if (bribeReward != address(0)) {
            rewardContracts[idx] = bribeReward;
            tokenArrays[idx] = rewardTokens;
        }

        uint256 length = lockedTokenIds.length;
        for (uint256 i = 0; i < length;) {
            uint256 tokenId = lockedTokenIds[i];
            // Single call claims from all reward contracts (fees + bribes)
            try voter.claimBribes(rewardContracts, tokenArrays, tokenId) {} catch {}
            unchecked { ++i; }
        }
    }

    /// @notice Get finalize progress
    function getFinalizeProgress() external view returns (
        FinalizeStep step,
        uint256 claimProgress,
        uint256 totalNFTs,
        bool inProgress
    ) {
        return (finalizeStep, batchIndex, lockedTokenIds.length, batchInProgress);
    }

    /// @notice Convert reward tokens to WETH with slippage protection
    function _convertToWETHInternal(address[] memory rewardTokens) internal {
        address routerAddr = address(router);
        address wethAddr = address(weth);
        address defaultFactory = router.defaultFactory();

        uint256 length = rewardTokens.length;
        for (uint256 i = 0; i < length;) {
            address token = rewardTokens[i];

            // Skip WETH
            if (token == wethAddr) {
                unchecked { ++i; }
                continue;
            }

            uint256 balance = IERC20(token).balanceOf(address(this));
            if (balance > 0) {
                // Approve router
                IERC20(token).approve(routerAddr, balance);

                // Try to swap to WETH with slippage protection
                IRouter.Route[] memory routes = new IRouter.Route[](1);
                routes[0] = IRouter.Route({
                    from: token,
                    to: wethAddr,
                    stable: false,
                    factory: defaultFactory
                });

                // Get expected output amount for slippage calculation
                uint256 minOut = _getMinOutputWithSlippage(balance, routes);

                try router.swapExactTokensForTokens(balance, minOut, routes, address(this), block.timestamp) {}
                catch {
                    // Try stable route with slippage
                    routes[0].stable = true;
                    minOut = _getMinOutputWithSlippage(balance, routes);
                    try router.swapExactTokensForTokens(balance, minOut, routes, address(this), block.timestamp) {}
                    catch {
                        // Token stays on contract for manual rescue
                    }
                }
            }

            unchecked { ++i; }
        }

        wethCollected = weth.balanceOf(address(this));
    }

    /// @notice Calculate minimum output with slippage tolerance
    /// @dev Returns minimum 1 wei to protect against sandwich attacks when quote fails
    function _getMinOutputWithSlippage(uint256 amountIn, IRouter.Route[] memory routes) internal view returns (uint256) {
        try router.getAmountsOut(amountIn, routes) returns (uint256[] memory amounts) {
            if (amounts.length > 1 && amounts[amounts.length - 1] > 0) {
                // Apply slippage tolerance
                uint256 minOut = (amounts[amounts.length - 1] * (BPS_DENOMINATOR - swapSlippageBps)) / BPS_DENOMINATOR;
                return minOut > 0 ? minOut : 1; // Ensure at least 1 wei
            }
        } catch {}
        return 1; // Minimum 1 wei to protect against dust/sandwich attacks
    }

    /// @notice Add liquidity with WETH and project tokens (with slippage protection)
    function _addLiquidity() internal {
        if (wethCollected == 0) return;

        address routerAddr = address(router);
        address wethAddr = address(weth);

        // Approve tokens
        IERC20(projectToken).approve(routerAddr, liquidityAllocation);
        weth.approve(routerAddr, wethCollected);

        // Calculate minimum amounts with slippage tolerance
        uint256 minProjectToken = (liquidityAllocation * (BPS_DENOMINATOR - liquiditySlippageBps)) / BPS_DENOMINATOR;
        uint256 minWeth = (wethCollected * (BPS_DENOMINATOR - liquiditySlippageBps)) / BPS_DENOMINATOR;

        // Add liquidity (volatile pool) with slippage protection
        (,, uint256 liquidity) = router.addLiquidity(
            projectToken,
            wethAddr,
            false, // volatile
            liquidityAllocation,
            wethCollected,
            minProjectToken,
            minWeth,
            address(this),
            block.timestamp
        );

        lpCreated = liquidity;

        // Get LP token address
        lpToken = router.poolFor(projectToken, wethAddr, false, router.defaultFactory());
    }

    /// @notice Lock LP tokens in LPLocker
    function _lockLP() internal {
        if (lpCreated == 0) return;

        // Approve LP to locker
        IERC20(lpToken).approve(address(lpLocker), lpCreated);

        // Lock LP permanently
        // Note: In Aerodrome, lpToken address IS the pool address (they're the same contract)
        lpLocker.lockLP(lpToken, lpToken, admin, projectOwner, lpCreated);
    }

    /*//////////////////////////////////////////////////////////////
                     PHASE 5: UNLOCK & CLAIM
    //////////////////////////////////////////////////////////////*/

    /// @notice Unlock a veAERO NFT after epoch completion
    /// @param tokenId The NFT token ID to unlock
    function unlockVeAERO(uint256 tokenId) external nonReentrant inState(PoolState.Completed) {
        LockedNFT storage nft = lockedNFTs[tokenId];

        if (nft.owner != msg.sender) revert NotNFTOwner();
        if (nft.unlocked) revert NFTNotLocked();

        nft.unlocked = true;

        // Transfer NFT back to owner
        votingEscrow.safeTransferFrom(address(this), msg.sender, tokenId);

        emit VeAEROUnlocked(msg.sender, tokenId);
    }

    /// @notice Claim project tokens based on voting power
    function claimProjectTokens() external nonReentrant inState(PoolState.Completed) {
        UserInfo storage user = userInfo[msg.sender];

        if (user.claimed) revert AlreadyClaimed();
        if (user.totalVotingPower == 0) revert NothingToClaim();

        user.claimed = true;

        // Calculate user's share of sale allocation
        uint256 userShare = (saleAllocation * user.totalVotingPower) / totalVotingPower;

        // Transfer project tokens
        if (!IERC20(projectToken).transfer(msg.sender, userShare)) {
            revert TransferFailed();
        }

        emit ProjectTokensClaimed(msg.sender, userShare);
    }

    /// @notice Get the amount of project tokens claimable by a user
    /// @param user The user address
    /// @return The claimable amount
    function getClaimableTokens(address user) external view returns (uint256) {
        UserInfo storage info = userInfo[user];

        if (info.claimed || info.totalVotingPower == 0 || totalVotingPower == 0) {
            return 0;
        }

        return (saleAllocation * info.totalVotingPower) / totalVotingPower;
    }

    /*//////////////////////////////////////////////////////////////
                        EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emergency withdraw a single NFT
    /// @param tokenId The NFT token ID
    function emergencyWithdrawNFT(uint256 tokenId) external onlyOwner {
        LockedNFT storage nft = lockedNFTs[tokenId];

        if (nft.owner == address(0)) revert NFTNotLocked();
        if (nft.unlocked) revert NFTNotLocked();

        address nftOwner = nft.owner;
        nft.unlocked = true;

        // Transfer NFT back to original owner
        votingEscrow.safeTransferFrom(address(this), nftOwner, tokenId);

        emit EmergencyWithdraw(nftOwner, tokenId);
    }

    /// @notice Emergency withdraw all NFTs in one transaction (for small numbers)
    function emergencyWithdrawAllNFTs() external onlyOwner {
        if (batchInProgress) revert BatchInProgress();
        
        uint256 length = lockedTokenIds.length;
        for (uint256 i = 0; i < length;) {
            _emergencyWithdrawSingle(lockedTokenIds[i]);
            unchecked { ++i; }
        }
    }

    /// @notice Emergency withdraw NFTs in batches
    /// @param batchSize Number of NFTs to process
    function emergencyWithdrawBatch(uint256 batchSize) external onlyOwner {
        if (batchSize > MAX_BATCH_SIZE) revert BatchSizeTooLarge();
        
        uint256 length = lockedTokenIds.length;
        if (length == 0) return;

        // Initialize batch if not started
        if (!batchInProgress) {
            batchIndex = 0;
            batchInProgress = true;
        }

        uint256 endIndex = batchIndex + batchSize;
        if (endIndex > length) endIndex = length;

        for (uint256 i = batchIndex; i < endIndex;) {
            _emergencyWithdrawSingle(lockedTokenIds[i]);
            unchecked { ++i; }
        }

        batchIndex = endIndex;
        emit BatchProgress("emergencyWithdraw", batchIndex, length);

        if (batchIndex >= length) {
            batchInProgress = false;
            batchIndex = 0;
        }
    }

    /// @notice Internal single NFT emergency withdraw
    function _emergencyWithdrawSingle(uint256 tokenId) internal {
        LockedNFT storage nft = lockedNFTs[tokenId];

        if (!nft.unlocked && nft.owner != address(0)) {
            address nftOwner = nft.owner;
            nft.unlocked = true;
            votingEscrow.safeTransferFrom(address(this), nftOwner, tokenId);
            emit EmergencyWithdraw(nftOwner, tokenId);
        }
    }

    /// @notice Get emergency withdraw progress
    function getEmergencyWithdrawProgress() external view returns (
        uint256 processed,
        uint256 total,
        bool inProgress
    ) {
        return (batchIndex, lockedTokenIds.length, batchInProgress);
    }

    /// @notice Rescue stuck tokens (cannot rescue project tokens)
    /// @param token The token address
    /// @param to Recipient address
    /// @param amount Amount to rescue
    function rescueTokens(address token, address to, uint256 amount) external onlyAdmin {
        if (token == projectToken) revert NotProjectToken();
        if (to == address(0)) revert ZeroAddress();

        if (!IERC20(token).transfer(to, amount)) {
            revert TransferFailed();
        }

        emit TokensRescued(token, to, amount);
    }

    /*//////////////////////////////////////////////////////////////
                        SLIPPAGE CONFIGURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Set swap slippage tolerance
    /// @param _slippageBps Slippage in basis points (e.g., 500 = 5%)
    function setSwapSlippage(uint256 _slippageBps) external onlyAdmin {
        if (_slippageBps > 5000) revert SlippageExceeded(); // Max 50%
        swapSlippageBps = _slippageBps;
    }

    /// @notice Set liquidity slippage tolerance
    /// @param _slippageBps Slippage in basis points (e.g., 500 = 5%)
    function setLiquiditySlippage(uint256 _slippageBps) external onlyAdmin {
        if (_slippageBps > 5000) revert SlippageExceeded(); // Max 50%
        liquiditySlippageBps = _slippageBps;
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get the count of locked NFTs
    /// @return The count
    function getLockedNFTCount() external view returns (uint256) {
        return lockedTokenIds.length;
    }

    /// @notice Get all locked token IDs
    /// @return Array of token IDs
    function getLockedTokenIds() external view returns (uint256[] memory) {
        return lockedTokenIds;
    }

    /// @notice Get info about a locked NFT
    /// @param tokenId The NFT token ID
    /// @return owner_ The original owner
    /// @return votingPower_ The voting power
    /// @return unlocked_ Whether it's been unlocked
    function getLockedNFTInfo(uint256 tokenId)
        external
        view
        returns (address owner_, uint256 votingPower_, bool unlocked_)
    {
        LockedNFT storage nft = lockedNFTs[tokenId];
        return (nft.owner, nft.votingPower, nft.unlocked);
    }

    /// @notice Get pending rewards for a specific NFT
    /// @param tokenId The veAERO NFT token ID
    /// @param rewardTokens Array of reward token addresses to check
    /// @return feesEarned Array of earned amounts from fees (LP trading fees)
    /// @return bribesEarned Array of earned amounts from bribes (external)
    function getPendingRewards(uint256 tokenId, address[] calldata rewardTokens) 
        external 
        view 
        returns (uint256[] memory feesEarned, uint256[] memory bribesEarned) 
    {
        feesEarned = new uint256[](rewardTokens.length);
        bribesEarned = new uint256[](rewardTokens.length);
        
        if (gauge == address(0)) return (feesEarned, bribesEarned);
        
        address feesReward;
        address bribeReward;
        
        try voter.gaugeToFees(gauge) returns (address _fees) {
            feesReward = _fees;
        } catch {}
        
        try voter.gaugeToBribe(gauge) returns (address _bribe) {
            bribeReward = _bribe;
        } catch {}
        
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            if (feesReward != address(0)) {
                try IVotingReward(feesReward).earned(rewardTokens[i], tokenId) returns (uint256 amount) {
                    feesEarned[i] = amount;
                } catch {}
            }
            if (bribeReward != address(0)) {
                try IVotingReward(bribeReward).earned(rewardTokens[i], tokenId) returns (uint256 amount) {
                    bribesEarned[i] = amount;
                } catch {}
            }
        }
    }

    /// @notice Get reward contract addresses for the current gauge
    /// @return feesReward The fees reward contract (LP trading fees)
    /// @return bribeReward The bribe reward contract (external bribes)
    function getRewardContracts() external view returns (address feesReward, address bribeReward) {
        if (gauge == address(0)) return (address(0), address(0));
        
        try voter.gaugeToFees(gauge) returns (address _fees) {
            feesReward = _fees;
        } catch {}
        
        try voter.gaugeToBribe(gauge) returns (address _bribe) {
            bribeReward = _bribe;
        } catch {}
    }

    /// @notice Get all available reward tokens that have actual rewards to claim
    /// @return feesTokens Array of token addresses with rewards from fees contract
    /// @return bribeTokens Array of token addresses with rewards from bribe contract
    function getAvailableRewardTokens() external view returns (
        address[] memory feesTokens,
        address[] memory bribeTokens
    ) {
        if (gauge == address(0)) return (new address[](0), new address[](0));
        
        address feesReward;
        address bribeReward;
        
        try voter.gaugeToFees(gauge) returns (address _fees) {
            feesReward = _fees;
        } catch {}
        
        try voter.gaugeToBribe(gauge) returns (address _bribe) {
            bribeReward = _bribe;
        } catch {}
        
        feesTokens = _getTokensWithRewards(feesReward);
        bribeTokens = _getTokensWithRewards(bribeReward);
    }

    /// @notice Get total claimable rewards for all locked NFTs
    /// @param rewardTokens Array of token addresses to check
    /// @return amounts Array of total claimable amounts for each token
    function getTotalClaimableRewards(address[] calldata rewardTokens) 
        external 
        view 
        returns (uint256[] memory amounts) 
    {
        amounts = new uint256[](rewardTokens.length);
        
        if (gauge == address(0) || lockedTokenIds.length == 0) return amounts;
        
        address feesReward;
        address bribeReward;
        
        try voter.gaugeToFees(gauge) returns (address _fees) {
            feesReward = _fees;
        } catch {}
        
        try voter.gaugeToBribe(gauge) returns (address _bribe) {
            bribeReward = _bribe;
        } catch {}
        
        // Sum up rewards across all locked NFTs
        for (uint256 i = 0; i < lockedTokenIds.length; i++) {
            uint256 tokenId = lockedTokenIds[i];
            
            for (uint256 j = 0; j < rewardTokens.length; j++) {
                // Check fees rewards
                if (feesReward != address(0)) {
                    try IVotingReward(feesReward).earned(rewardTokens[j], tokenId) returns (uint256 earned) {
                        amounts[j] += earned;
                    } catch {}
                }
                
                // Check bribe rewards
                if (bribeReward != address(0)) {
                    try IVotingReward(bribeReward).earned(rewardTokens[j], tokenId) returns (uint256 earned) {
                        amounts[j] += earned;
                    } catch {}
                }
            }
        }
    }

    /*//////////////////////////////////////////////////////////////
                         OWNER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Transfer ownership (two-step)
    /// @param newOwner The new pending owner
    function transferOwnership(address newOwner) external onlyOwner {
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
    }

    /// @notice Accept ownership
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        owner = msg.sender;
        pendingOwner = address(0);
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Update pool state
    function _setState(PoolState newState) internal {
        PoolState previousState = state;
        state = newState;
        emit StateChanged(previousState, newState);
    }
}

