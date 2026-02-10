// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {EpochLib} from "./libraries/EpochLib.sol";
import {LPLocker} from "./LPLocker.sol";
import {IVotingEscrow} from "./interfaces/IVotingEscrow.sol";
import {IVoter} from "./interfaces/IVoter.sol";
import {IRouter} from "./interfaces/IRouter.sol";
import {IERC20} from "./interfaces/IERC20.sol";
import {IWETH} from "./interfaces/IWETH.sol";
import {IERC721Receiver} from "./interfaces/IERC721Receiver.sol";
import {IAutopilot, IAutopilotDepositValidator} from "./interfaces/IAutopilot.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {ICLFactory} from "./interfaces/ICLFactory.sol";
import {ICLPool} from "./interfaces/ICLPool.sol";
import {CLPriceArbitrageur} from "./CLPriceArbitrageur.sol";
import {Math} from "@openzeppelin/contracts/utils/math/Math.sol";

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
    error EpochNotEnded();
    error VotingPowerTooLow();
    error NFTDeactivated();
    error PoolCancelled();
    error NoParticipants();
    error InvalidDeadline();
    error NotAllClaimed();
    error AutopilotDepositFailed();
    error AutopilotWithdrawFailed();
    error NotInAutopilot();
    error StillInAutopilot();
    error InAutopilotSpecialWindow();
    error LiquidityAdditionFailed();
    error UnsafeDepositWindow();
    error InvalidLiquidityAmounts();
    error SqrtPriceZero();
    error SqrtPriceOverflow();
    error NoPendingDeposit();
    error SameBlockDeposit();
    error AlreadyPending();
    error PoolIsCompleted();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event VeAEROLocked(address indexed user, uint256 indexed tokenId, uint256 votingPower);
    event VeAEROUnlocked(address indexed user, uint256 indexed tokenId);
    event EpochFinalized(uint256 wethCollected, uint256 lpPositionId);
    event ProjectTokensClaimed(address indexed user, uint256 amount);
    event EmergencyWithdraw(address indexed user, uint256 indexed tokenId);
    event TokensRescued(address indexed token, address indexed to, uint256 amount);
    event StateChanged(PoolState previousState, PoolState newState);
    event BatchProgress(string operation, uint256 processed, uint256 total);
    event PoolCancelledEvent(uint256 projectTokensRecovered);
    event DepositedToAutopilot(uint256 indexed tokenId);
    event WithdrawnFromAutopilot(uint256 indexed tokenId);
    event AutopilotRewardsClaimed(uint256 indexed tokenId, uint256 amount);
    event VeAERODeposited(address indexed user, uint256 indexed tokenId, uint256 votingPower);
    event DepositConfirmed(address indexed user, uint256 indexed tokenId);
    event PriceArbitrageurUpdated(address indexed oldArbitrageur, address indexed newArbitrageur);

    /*//////////////////////////////////////////////////////////////
                                 ENUMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Pool states
    enum PoolState {
        Inactive, // Pool created, waiting for activation
        Active, // Accepting veAERO locks
        Voting, // Voting period
        Finalizing, // Claiming rewards and creating LP
        Completed, // All done, claims open
        Cancelled // Pool cancelled, project tokens recoverable
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

    /// @notice Info about a pending veAERO deposit (two-phase deposit)
    /// @dev Required because Aerodrome returns balanceOfNFT=0 when ownership changes in same block
    struct PendingDeposit {
        address owner;
        uint256 depositBlock;
        uint256 votingPower;
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

    /// @notice Price arbitrageur contract (shared, for fixing front-run pool prices)
    /// @dev Configurable (non-immutable) to allow upgrades if arbitrage logic needs changes
    CLPriceArbitrageur public priceArbitrageur;

    /// @notice Protocol owner (for emergency functions)
    address public owner;

    /// @notice Pending owner for two-step transfer
    address public pendingOwner;

    /// @notice Current pool state
    PoolState public state;

    /// @notice LP token address
    address public lpToken;

    /// @notice Epoch when the pool was activated (Kickoff epoch)
    uint256 public activeEpoch;
    
    /// @notice Aerodrome epoch start timestamp when pool was activated
    /// @dev Used to ensure voting and finalization align with Aerodrome epochs
    uint256 public aerodromeEpochStart;

    /// @notice Total voting power locked
    uint256 public totalVotingPower;

    /// @notice Total WETH collected from bribes/fees (tracked, not balanceOf)
    uint256 public wethCollected;
    
    /// @notice Track total claimed rewards in WETH equivalent
    uint256 public totalClaimedRewards;
    
    /// @notice WETH balance before finalization started (for accurate reward tracking)
    uint256 private wethBeforeFinalization;

    /// @notice CL Position ID created (Slipstream NFT)
    uint256 public lpPositionId;
    
    /// @notice Total project tokens claimed (for dust tracking - #13)
    uint256 public totalProjectTokensClaimed;
    
    /// @notice Number of users who have claimed
    uint256 public claimCount;
    
    /// @notice Number of unique participants (users with voting power > 0)
    uint256 public participantCount;

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
    
    /// @notice Deadline buffer for swaps/liquidity operations (seconds)
    /// @dev #6: Provides meaningful deadline protection
    uint256 public deadlineBuffer = 20 minutes;

    /*//////////////////////////////////////////////////////////////
                          AUTOPILOT INTEGRATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Autopilot PermanentLocksPool contract (Base mainnet)
    IAutopilot public constant autopilot = IAutopilot(0xA7c68a960bA0F6726C4b7446004FE64969E2b4d4);

    /// @notice USDC token (rewards from Autopilot)
    IERC20 public constant usdc = IERC20(0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913);

    /// @notice Minimum voting power required for Autopilot deposit (400 veAERO)
    uint256 public constant MIN_AUTOPILOT_VOTING_POWER = 400e18;

    /// @notice Timestamp when locking closes (auto-transitions to Voting state)
    /// @dev Set during activate() from Autopilot's wrapperEndsAt (start of unsafe deposit window)
    uint256 public lockingDeadline;

    /// @notice Track which NFTs are deposited in Autopilot
    mapping(uint256 => bool) public depositedToAutopilot;

    /// @notice Track pending deposits (two-phase deposit due to Aerodrome same-block voting power reset)
    mapping(uint256 => PendingDeposit) public pendingDeposits;

    /*//////////////////////////////////////////////////////////////
                          SLIPSTREAM (CL) INTEGRATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Aerodrome Slipstream NonfungiblePositionManager on Base mainnet
    INonfungiblePositionManager public constant clPositionManager = 
        INonfungiblePositionManager(0x827922686190790b37229fd06084350E74485b72);

    /// @notice Aerodrome Slipstream CL Factory on Base mainnet
    ICLFactory public constant clFactory = ICLFactory(0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A);

    /// @notice Tick spacing for 1% fee tier in Slipstream
    int24 public constant CL_TICK_SPACING = 200;

    /// @notice Full-range tick bounds for 1% fee tier (rounded to tickSpacing)
    int24 public constant CL_MIN_TICK = -887200;
    int24 public constant CL_MAX_TICK = 887200;

    /// @notice USDC balance before finalization started (for accurate reward tracking)
    uint256 private usdcBeforeFinalization;

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

    /// @notice Modifier that auto-transitions Active -> Voting when lockingDeadline is reached
    /// @dev Ensures state automatically changes without admin action
    modifier checkStateTransition() {
        if (state == PoolState.Active && block.timestamp >= lockingDeadline) {
            _setState(PoolState.Voting);
        }
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
        address _weth,
        address _priceArbitrageur
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
        priceArbitrageur = CLPriceArbitrageur(_priceArbitrageur);

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
    /// @dev Stores both Kickoff epoch and Aerodrome epoch start to ensure alignment
    /// @dev Sets lockingDeadline dynamically from Autopilot's special window
    function activate() external onlyAdmin inState(PoolState.Inactive) {
        activeEpoch = EpochLib.currentEpoch();
        // #4: Store Aerodrome epoch start to ensure voting/finalization alignment
        aerodromeEpochStart = EpochLib.currentEpochStart();
        
        // Set locking deadline dynamically from Autopilot's special window
        // wrapperEndsAt marks when the unsafe deposit window starts
        uint256 autopilotEpochId = autopilot.last_snapshot_id();
        (, , , uint256 wrapperEndsAt) = autopilot.getEpochInfo(autopilotEpochId);
        lockingDeadline = wrapperEndsAt;
        
        _setState(PoolState.Active);
    }

    /// @notice Manually trigger state transition from Active to Voting
    /// @dev Can be called by anyone after lockingDeadline is reached
    /// @dev Useful to transition state without a failed lockVeAERO transaction
    function triggerStateTransition() external {
        if (state != PoolState.Active) revert InvalidState();
        if (block.timestamp < lockingDeadline) revert InvalidState();
        
        _setState(PoolState.Voting);
    }

    /// @notice Phase 1: Deposit a veAERO NFT to participate in the vote-sale
    /// @param tokenId The veAERO NFT token ID
    /// @dev NFT is transferred to this contract and stored as pending
    /// @dev Must call confirmDeposit() in a DIFFERENT block to complete the deposit to Autopilot
    /// @dev This two-phase approach is required because Aerodrome resets voting power to 0
    ///      when NFT ownership changes in the same block (flash loan protection)
    /// @dev WARNING: NFT will be converted to permanent lock (4-year max) by Autopilot
    function depositVeAERO(uint256 tokenId) external nonReentrant checkStateTransition {
        // Check state after potential auto-transition
        if (state != PoolState.Active) revert InvalidState();
        
        // Check locking deadline (prevents locking during Autopilot special window)
        if (block.timestamp >= lockingDeadline) revert LockingClosed();
        
        // Check ownership
        if (votingEscrow.ownerOf(tokenId) != msg.sender) {
            revert NotNFTOwner();
        }
        
        // Check not already pending
        if (pendingDeposits[tokenId].owner != address(0)) revert AlreadyPending();
        
        // #2: Check if NFT is deactivated (managed NFT deactivation)
        try votingEscrow.deactivated(tokenId) returns (bool isDeactivated) {
            if (isDeactivated) revert NFTDeactivated();
        } catch {
            // If function doesn't exist, NFT is not a managed NFT - proceed
        }

        // #4: Check if NFT hasn't voted in the current Aerodrome epoch
        // Use stored aerodromeEpochStart to ensure alignment
        uint256 lastVoted = voter.lastVoted(tokenId);
        if (lastVoted >= aerodromeEpochStart) {
            revert AlreadyVotedThisEpoch();
        }

        // Get voting power BEFORE transfer (will be 0 after transfer in same block)
        uint256 votingPowerAmount = votingEscrow.balanceOfNFT(tokenId);
        
        // Check minimum voting power with whitelist support
        // Whitelisted users can lock with lower VP, others use pool's minVotingPower
        uint256 effectiveMin = _getEffectiveMinVotingPower(msg.sender);
        if (votingPowerAmount < effectiveMin) {
            revert VotingPowerTooLow();
        }

        // Check if lock is permanent (required for Autopilot deposit)
        // Must check BEFORE transfer, but lockPermanent must be called AFTER
        // because only owner can call lockPermanent
        IVotingEscrow.LockedBalance memory lockInfo = votingEscrow.locked(tokenId);
        bool needsLockPermanent = !lockInfo.isPermanent;

        // Transfer NFT to this contract first (user must have approved)
        votingEscrow.safeTransferFrom(msg.sender, address(this), tokenId);

        // Make lock permanent if needed (now pool is owner and can call this)
        if (needsLockPermanent) {
            votingEscrow.lockPermanent(tokenId);
        }

        // Store as pending deposit - will be confirmed in next block
        pendingDeposits[tokenId] = PendingDeposit({
            owner: msg.sender,
            depositBlock: block.number,
            votingPower: votingPowerAmount
        });

        emit VeAERODeposited(msg.sender, tokenId, votingPowerAmount);
    }

    /// @notice Phase 2: Confirm a pending deposit and deposit to Autopilot
    /// @param tokenId The veAERO NFT token ID
    /// @dev Can be called by anyone (permissionless) in a block AFTER depositVeAERO was called
    /// @dev This completes the deposit flow by depositing to Autopilot
    function confirmDeposit(uint256 tokenId) external nonReentrant checkStateTransition {
        PendingDeposit memory pending = pendingDeposits[tokenId];
        
        // Check there's a pending deposit
        if (pending.owner == address(0)) revert NoPendingDeposit();
        
        // Check we're in a different block (Aerodrome voting power is available again)
        if (block.number <= pending.depositBlock) revert SameBlockDeposit();
        
        // Check state (can confirm even after locking deadline, but not after Active state)
        if (state != PoolState.Active && state != PoolState.Voting) revert InvalidState();
        
        // Check if it's safe to deposit to Autopilot
        if (!_isSafeToDepositToAutopilot()) revert UnsafeDepositWindow();
        
        // Delete pending deposit first (reentrancy protection)
        delete pendingDeposits[tokenId];
        
        // Store locked NFT info
        lockedNFTs[tokenId] = LockedNFT({
            owner: pending.owner, 
            votingPower: pending.votingPower, 
            unlocked: false
        });

        lockedTokenIds.push(tokenId);

        // Update user info - track new participants for FIND-002 fix
        if (userInfo[pending.owner].totalVotingPower == 0) {
            participantCount++; // New participant
        }
        userInfo[pending.owner].totalVotingPower += pending.votingPower;

        // Update total voting power
        totalVotingPower += pending.votingPower;

        // Deposit NFT to Autopilot for automated vAPR voting
        votingEscrow.approve(address(autopilot), tokenId);
        try autopilot.deposit(tokenId) {
            depositedToAutopilot[tokenId] = true;
            emit DepositedToAutopilot(tokenId);
        } catch {
            // If Autopilot deposit fails, revert the whole transaction
            revert AutopilotDepositFailed();
        }

        emit DepositConfirmed(pending.owner, tokenId);
        emit VeAEROLocked(pending.owner, tokenId, pending.votingPower);
    }

    /// @notice Cancel a pending deposit and return the NFT to the owner
    /// @param tokenId The veAERO NFT token ID
    /// @dev Can only be called by the original depositor
    function cancelDeposit(uint256 tokenId) external nonReentrant {
        PendingDeposit memory pending = pendingDeposits[tokenId];
        
        // Check there's a pending deposit
        if (pending.owner == address(0)) revert NoPendingDeposit();
        
        // Only the original depositor can cancel
        if (pending.owner != msg.sender) revert NotNFTOwner();
        
        // Delete pending deposit first (reentrancy protection)
        delete pendingDeposits[tokenId];
        
        // Return NFT to original owner
        votingEscrow.safeTransferFrom(address(this), msg.sender, tokenId);
        
        emit EmergencyWithdraw(msg.sender, tokenId);
    }


    /*//////////////////////////////////////////////////////////////
                    AUTOPILOT CLAIM & WITHDRAW
    //////////////////////////////////////////////////////////////*/

    /// @notice Check if we're in Autopilot's special window (can't withdraw/claim)
    /// @dev Dynamic check using Autopilot's current epoch info
    /// @return true if in special window (operations restricted), false if safe to withdraw/claim
    function _isInAutopilotSpecialWindow() internal view returns (bool) {
        uint256 autopilotEpochId = autopilot.last_snapshot_id();
        
        // Get wrapper_ends_at from current epoch (when special window starts from Autopilot's side)
        (, , , uint256 wrapperEndsAt) = autopilot.getEpochInfo(autopilotEpochId);
        
        // Get wrapper_starts_at from next epoch (when special window ends)
        (, , uint256 wrapperStartsAt, ) = autopilot.getEpochInfo(autopilotEpochId + 1);
        
        // Window starts when current epoch's wrapper ends
        // Window ends when next epoch's wrapper starts
        uint256 windowStartsAt = wrapperEndsAt;
        uint256 windowEndsAt = wrapperStartsAt;
        
        return (block.timestamp > windowStartsAt && block.timestamp <= windowEndsAt);
    }

    /// @notice Check if it's safe to deposit to Autopilot
    /// @dev Restricts deposits during the left side of special window (~2 hours before epoch flip)
    ///      to prevent user confusion when new locks won't be used for current epoch
    /// @return true if safe to deposit, false if in unsafe deposit window
    function _isSafeToDepositToAutopilot() internal view returns (bool) {
        uint256 autopilotEpochId = autopilot.last_snapshot_id();
        
        // Get wrapper_ends_at from current epoch
        (, , , uint256 wrapperEndsAt) = autopilot.getEpochInfo(autopilotEpochId);
        
        // Get epoch_starts_at from next epoch
        (uint256 nextEpochStartsAt, , , ) = autopilot.getEpochInfo(autopilotEpochId + 1);
        
        // Unsafe window: from when wrapper ends to when next epoch starts
        // This is the "left side" of the special window where deposits shouldn't happen
        uint256 windowStartsAt = wrapperEndsAt;
        uint256 windowEndsAt = nextEpochStartsAt;
        
        // Safe to deposit if we're NOT in this window
        return !(block.timestamp > windowStartsAt && block.timestamp <= windowEndsAt);
    }

    /// @notice Get effective minimum voting power for a user
    /// @dev Whitelisted users in Autopilot can lock with lower VP
    ///      Non-whitelisted users use pool's minVotingPower
    ///      Falls back to minVotingPower if Autopilot calls fail
    /// @param user The user address to check
    /// @return The effective minimum voting power for this user
    function _getEffectiveMinVotingPower(address user) internal view returns (uint256) {
        // Default to pool's configured minimum
        uint256 effectiveMin = minVotingPower;
        
        // Try to check if user is whitelisted in Autopilot with lower minimum
        try autopilot.deposit_validator() returns (address validator) {
            if (validator != address(0)) {
                try IAutopilotDepositValidator(validator).getMinDepositAmount(user) returns (uint256 whitelistMin) {
                    try IAutopilotDepositValidator(validator).minimum_lock_amount() returns (uint256 globalMin) {
                        // User is whitelisted if their min is lower than global
                        if (whitelistMin < globalMin) {
                            effectiveMin = whitelistMin;
                        }
                        // Otherwise, use pool's minVotingPower (already set as default)
                    } catch {
                        // minimum_lock_amount() failed, use pool's min
                    }
                } catch {
                    // getMinDepositAmount() failed, use pool's min
                }
            }
        } catch {
            // deposit_validator() failed, use pool's min
        }
        
        return effectiveMin;
    }

    /// @notice Start claiming USDC rewards from Autopilot in batches
    /// @param batchSize Number of NFTs to process per batch
    /// @dev Autopilot handles voting and converts rewards to USDC automatically
    function startClaimRewardsFromAutopilot(uint256 batchSize) 
        external 
        onlyAdmin 
        checkStateTransition
    {
        // Allow calling from Voting state (after lockingDeadline auto-transition)
        if (state != PoolState.Voting) revert InvalidState();
        if (batchInProgress) revert BatchInProgress();
        
        // Check for zero effective participants
        if (totalVotingPower == 0) {
            _setState(PoolState.Cancelled);
            uint256 balance = IERC20(projectToken).balanceOf(address(this));
            if (balance > 0) {
                _safeTransferProjectToken(projectOwner, balance);
            }
            emit PoolCancelledEvent(balance);
            return;
        }
        
        // Ensure Aerodrome epoch has ended
        uint256 aerodromeEpochEnd = aerodromeEpochStart + 1 weeks;
        if (block.timestamp <= aerodromeEpochEnd) revert EpochNotEnded();
        
        // Ensure we're outside Autopilot's special window (dynamic check)
        if (_isInAutopilotSpecialWindow()) revert InAutopilotSpecialWindow();
        
        _setState(PoolState.Finalizing);
        finalizeStep = FinalizeStep.ClaimingRewards;
        
        // Store USDC and WETH balance before claiming
        usdcBeforeFinalization = usdc.balanceOf(address(this));
        wethBeforeFinalization = weth.balanceOf(address(this));
        
        batchIndex = 0;
        batchInProgress = true;
        
        _claimAutopilotRewardsBatchInternal(batchSize);
    }

    /// @notice Continue claiming USDC rewards from Autopilot
    /// @param batchSize Number of NFTs to process
    function continueClaimRewardsFromAutopilot(uint256 batchSize) external onlyAdmin inState(PoolState.Finalizing) {
        if (!batchInProgress) revert NoBatchInProgress();
        if (finalizeStep != FinalizeStep.ClaimingRewards) revert InvalidState();
        
        _claimAutopilotRewardsBatchInternal(batchSize);
    }

    /// @notice Internal batch claim logic for Autopilot
    function _claimAutopilotRewardsBatchInternal(uint256 batchSize) internal {
        if (batchSize > MAX_BATCH_SIZE) revert BatchSizeTooLarge();
        
        uint256 length = lockedTokenIds.length;
        if (length == 0) {
            batchInProgress = false;
            batchIndex = 0;
            finalizeStep = FinalizeStep.ConvertingToWETH;
            emit BatchProgress("claimAutopilotRewards", 0, 0);
            return;
        }

        uint256 endIndex = batchIndex + batchSize;
        if (endIndex > length) endIndex = length;

        for (uint256 i = batchIndex; i < endIndex;) {
            uint256 tokenId = lockedTokenIds[i];
            
            if (depositedToAutopilot[tokenId]) {
                // Claim USDC rewards from Autopilot
                try autopilot.claim(tokenId) {
                    emit AutopilotRewardsClaimed(tokenId, 0); // Amount not returned by claim()
                } catch {
                    // Continue even if claim fails
                }
            }
            
            unchecked { ++i; }
        }

        batchIndex = endIndex;
        emit BatchProgress("claimAutopilotRewards", batchIndex, length);

        if (batchIndex >= length) {
            batchInProgress = false;
            batchIndex = 0;
            finalizeStep = FinalizeStep.ConvertingToWETH;
        }
    }

    /// @notice Convert USDC rewards to WETH
    /// @dev Called after claiming from Autopilot, swaps all USDC to WETH
    /// @dev Can be called multiple times if swap fails — admin can adjust slippage and retry
    /// @dev Only advances to AddingLiquidity when all claimed USDC is converted
    function convertUSDCtoWETH() external nonReentrant onlyAdmin inState(PoolState.Finalizing) {
        if (batchInProgress) revert BatchInProgress();
        if (finalizeStep != FinalizeStep.ConvertingToWETH) revert InvalidState();
        
        uint256 usdcBalance = usdc.balanceOf(address(this));
        
        // Only swap if we have USDC (Autopilot rewards)
        if (usdcBalance > 0) {
            address routerAddr = address(router);
            address wethAddr = address(weth);
            address defaultFactory = router.defaultFactory();
            
            // Approve router
            usdc.approve(routerAddr, usdcBalance);
            
            // Build route: USDC -> WETH
            IRouter.Route[] memory routes = new IRouter.Route[](1);
            routes[0] = IRouter.Route({
                from: address(usdc),
                to: wethAddr,
                stable: false,
                factory: defaultFactory
            });
            
            // Get minimum output with slippage protection
            uint256 minOut = _getMinOutputWithSlippage(usdcBalance, routes);
            uint256 deadline = block.timestamp + deadlineBuffer;
            
            if (minOut > 0) {
                try router.swapExactTokensForTokens(usdcBalance, minOut, routes, address(this), deadline) {
                    // Success
                } catch {
                    // Try stable route
                    routes[0].stable = true;
                    minOut = _getMinOutputWithSlippage(usdcBalance, routes);
                    if (minOut > 0) {
                        try router.swapExactTokensForTokens(usdcBalance, minOut, routes, address(this), deadline) {
                        } catch {
                            // USDC stays in contract — admin can retry with different slippage
                        }
                    }
                }
            }
        }
        
        // Track total claimed rewards (WETH acquired from swapping USDC)
        uint256 wethAfter = weth.balanceOf(address(this));
        totalClaimedRewards = wethAfter - wethBeforeFinalization;
        wethCollected = totalClaimedRewards;
        
        // M-02 fix: Only advance if all claimed USDC was converted (or no new USDC was claimed)
        // If USDC remains above pre-finalization level, admin can retry with adjusted slippage
        uint256 remainingUsdc = usdc.balanceOf(address(this));
        if (remainingUsdc <= usdcBeforeFinalization) {
            finalizeStep = FinalizeStep.AddingLiquidity;
        }
    }

    /// @notice Complete the Autopilot finalization by adding liquidity
    /// @dev Call after convertUSDCtoWETH
    /// @dev Admin specifies dustAmount in wei for price arbitrage (e.g. 1000 for normal cases).
    ///      If the pool was front-run and the attacker added liquidity, increase dustAmount
    ///      to overcome it. Simulate the tx first — if it reverts with PriceNotReached,
    ///      retry with a larger value.
    /// @param dustAmount Amount of each token (in wei) to use for dust price arbitrage
    function completeAutopilotFinalization(uint256 dustAmount) external nonReentrant onlyAdmin inState(PoolState.Finalizing) {
        if (batchInProgress) revert BatchInProgress();
        if (finalizeStep != FinalizeStep.AddingLiquidity) revert InvalidState();

        // Add liquidity
        _addLiquidity(dustAmount);

        // Lock LP
        _lockLP();

        finalizeStep = FinalizeStep.Completed;
        
        _setState(PoolState.Completed);
        emit EpochFinalized(wethCollected, lpPositionId);
    }

    /// @notice Get Autopilot claim progress
    function getAutopilotClaimProgress() external view returns (
        FinalizeStep step,
        uint256 claimProgress,
        uint256 totalNFTs,
        bool inProgress
    ) {
        return (finalizeStep, batchIndex, lockedTokenIds.length, batchInProgress);
    }

    /*//////////////////////////////////////////////////////////////
                    PHASE 3-5: FINALIZE EPOCH (BATCH) - LEGACY
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

    /// @notice Get finalize progress
    function getFinalizeProgress() external view returns (
        FinalizeStep step,
        uint256 claimProgress,
        uint256 totalNFTs,
        bool inProgress
    ) {
        return (finalizeStep, batchIndex, lockedTokenIds.length, batchInProgress);
    }

    /// @notice Calculate minimum output with slippage tolerance
    /// @dev #9: Returns 0 when no reliable quote available (skip swap instead of unbounded slippage)
    function _getMinOutputWithSlippage(uint256 amountIn, IRouter.Route[] memory routes) internal view returns (uint256) {
        try router.getAmountsOut(amountIn, routes) returns (uint256[] memory amounts) {
            if (amounts.length > 1 && amounts[amounts.length - 1] > 0) {
                // Apply slippage tolerance
                uint256 minOut = (amounts[amounts.length - 1] * (BPS_DENOMINATOR - swapSlippageBps)) / BPS_DENOMINATOR;
                return minOut; // Can be 0 if quote is too small
            }
        } catch {}
        return 0; // #9: Return 0 to signal "skip this swap"
    }

    /// @notice Add liquidity as Slipstream CL position (1% fee tier, full-range)
    /// @dev Creates or adds to a CL pool with full-range position for max coverage
    /// @dev If pool was front-run by attacker, performs dust arbitrage to correct price
    /// @dev #8: Only uses tracked claimed rewards, not external WETH donations
    /// @param dustAmount Amount of each token (in wei) to use for dust price arbitrage
    function _addLiquidity(uint256 dustAmount) internal {
        // #8: Use tracked claimed rewards, not balanceOf (prevents external WETH griefing)
        if (totalClaimedRewards == 0) return;
        
        uint256 wethToUse = totalClaimedRewards;
        address wethAddr = address(weth);

        // Sort tokens (CL requires token0 < token1)
        (address token0, address token1, uint256 amount0, uint256 amount1) = 
            projectToken < wethAddr 
                ? (projectToken, wethAddr, liquidityAllocation, wethToUse)
                : (wethAddr, projectToken, wethToUse, liquidityAllocation);

        // Calculate sqrtPriceX96 for initial price (token1/token0)
        // price = amount1 / amount0, sqrtPriceX96 = sqrt(price) * 2^96
        uint160 sqrtPriceX96 = _calculateSqrtPriceX96(amount0, amount1);

        // Check if pool was already created (front-run protection)
        // If pool exists, fix its price via dust arbitrage and set sqrtPriceX96 to 0
        // to avoid NonfungiblePositionManager.mint() calling createPool() which would revert
        bool poolExists;
        address existingPool = clFactory.getPool(token0, token1, CL_TICK_SPACING);
        if (existingPool != address(0)) {
            poolExists = true;
            (uint160 currentSqrtPrice,,,,,) = ICLPool(existingPool).slot0();
            if (currentSqrtPrice != sqrtPriceX96) {
                // Approve dust tokens to arbitrageur, which will transferFrom them
                IERC20(token0).approve(address(priceArbitrageur), dustAmount);
                IERC20(token1).approve(address(priceArbitrageur), dustAmount);
                (uint256 spent0, uint256 spent1) = priceArbitrageur.fixPoolPrice(
                    existingPool, token0, token1, sqrtPriceX96, CL_TICK_SPACING, dustAmount
                );
                // Reset approvals
                IERC20(token0).approve(address(priceArbitrageur), 0);
                IERC20(token1).approve(address(priceArbitrageur), 0);

                // M-01 fix: Subtract only the actual tokens spent on arbitrage (not the full dustAmount).
                // fixPoolPrice returns precise spend after returning unused tokens to caller.
                if (amount0 > spent0) amount0 -= spent0;
                if (amount1 > spent1) amount1 -= spent1;
            }
        }

        // Approve position manager (reset to 0 first for tokens like USDT that require it)
        IERC20(token0).approve(address(clPositionManager), 0);
        IERC20(token0).approve(address(clPositionManager), amount0);
        IERC20(token1).approve(address(clPositionManager), 0);
        IERC20(token1).approve(address(clPositionManager), amount1);

        // Calculate minimum amounts with slippage tolerance
        uint256 amount0Min = (amount0 * (BPS_DENOMINATOR - liquiditySlippageBps)) / BPS_DENOMINATOR;
        uint256 amount1Min = (amount1 * (BPS_DENOMINATOR - liquiditySlippageBps)) / BPS_DENOMINATOR;

        // Mint full-range CL position with 1% fee tier
        // CRITICAL: sqrtPriceX96 must be 0 when pool already exists, because Aerodrome's
        // NonfungiblePositionManager.mint() calls createPool() when sqrtPriceX96 != 0,
        // which reverts if the pool already exists
        INonfungiblePositionManager.MintParams memory params = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            tickSpacing: CL_TICK_SPACING,
            tickLower: CL_MIN_TICK,
            tickUpper: CL_MAX_TICK,
            amount0Desired: amount0,
            amount1Desired: amount1,
            amount0Min: amount0Min,
            amount1Min: amount1Min,
            recipient: address(this),
            deadline: block.timestamp + deadlineBuffer,
            sqrtPriceX96: poolExists ? 0 : sqrtPriceX96
        });

        // Mint position - revert on failure instead of silent fail
        (uint256 tokenId,,,) = clPositionManager.mint(params);
        
        if (tokenId == 0) revert LiquidityAdditionFailed();
        
        lpPositionId = tokenId;
        // Store LP token as position manager address (for compatibility)
        lpToken = address(clPositionManager);
        
        // Reset approvals for unused amounts (security best practice)
        IERC20(token0).approve(address(clPositionManager), 0);
        IERC20(token1).approve(address(clPositionManager), 0);
    }

    /// @notice Calculate sqrtPriceX96 from token amounts with full precision
    /// @dev sqrtPriceX96 = sqrt(amount1 * 2^192 / amount0) - canonical V3 formula
    /// @dev Uses OpenZeppelin Math.mulDiv for 512-bit intermediate precision
    function _calculateSqrtPriceX96(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
        // Validate inputs - both amounts must be non-zero
        if (amount0 == 0 || amount1 == 0) revert InvalidLiquidityAmounts();
        
        // Canonical V3 formula: sqrtPriceX96 = sqrt(amount1 * 2^192 / amount0)
        // This is more precise than sqrt(amount1) * 2^96 / sqrt(amount0) because
        // it only has one floor operation (in sqrt) instead of three
        //
        // Step 1: Calculate ratioX192 = amount1 * 2^192 / amount0 using mulDiv
        uint256 Q192 = uint256(1) << 192;
        uint256 ratioX192 = Math.mulDiv(amount1, Q192, amount0);
        
        // Step 2: Take sqrt of the ratio
        uint256 result = Math.sqrt(ratioX192);
        
        // Validate result is non-zero (would cause CL mint to fail)
        if (result == 0) revert SqrtPriceZero();
        
        // Validate result fits in uint160 (prevent silent truncation)
        if (result > type(uint160).max) revert SqrtPriceOverflow();
        
        return uint160(result);
    }

    /// @notice Lock CL position in LPLocker
    function _lockLP() internal {
        if (lpPositionId == 0) return;

        // Approve position NFT to locker
        clPositionManager.approve(address(lpLocker), lpPositionId);

        // Lock position permanently
        lpLocker.lockPosition(lpPositionId, admin, projectOwner);
    }

    /*//////////////////////////////////////////////////////////////
                     PHASE 5: UNLOCK & CLAIM
    //////////////////////////////////////////////////////////////*/

    /// @notice Unlock a veAERO NFT after epoch completion
    /// @param tokenId The NFT token ID to unlock
    /// @dev Automatically withdraws from Autopilot if still deposited
    /// @dev Rewards were already claimed during finalization, no claim needed here
    function unlockVeAERO(uint256 tokenId) external nonReentrant inState(PoolState.Completed) {
        LockedNFT storage nft = lockedNFTs[tokenId];

        if (nft.owner != msg.sender) revert NotNFTOwner();
        if (nft.unlocked) revert NFTNotLocked();

        nft.unlocked = true;
        
        // If NFT is still in Autopilot, withdraw it first
        if (depositedToAutopilot[tokenId]) {
            // Ensure we're outside Autopilot's special window (dynamic check)
            if (_isInAutopilotSpecialWindow()) revert InAutopilotSpecialWindow();
            
            // Withdraw and send USDC rewards to user (reverts on failure via direct call)
            uint256 usdcBefore = usdc.balanceOf(address(this));
            autopilot.withdraw(tokenId);
            depositedToAutopilot[tokenId] = false;
            emit WithdrawnFromAutopilot(tokenId);
            uint256 usdcAfter = usdc.balanceOf(address(this));
            if (usdcAfter > usdcBefore) {
                _safeTransferUSDC(msg.sender, usdcAfter - usdcBefore);
            }
        }

        // Transfer NFT back to owner
        votingEscrow.safeTransferFrom(address(this), msg.sender, tokenId);

        emit VeAEROUnlocked(msg.sender, tokenId);
    }

    /// @notice Claim project tokens based on voting power
    /// @dev #13: Handles dust by giving remainder to last claimer
    /// @dev #19: Includes any leftover liquidity tokens in distribution
    function claimProjectTokens() external nonReentrant inState(PoolState.Completed) {
        UserInfo storage user = userInfo[msg.sender];

        if (user.claimed) revert AlreadyClaimed();
        if (user.totalVotingPower == 0) revert NothingToClaim();

        user.claimed = true;
        claimCount++;

        // Calculate user's share of sale allocation
        uint256 userShare = (saleAllocation * user.totalVotingPower) / totalVotingPower;
        
        // Track claimed amount
        totalProjectTokensClaimed += userShare;
        
        // #13, #19: If this is approaching the last claim, give remaining balance
        // This handles both rounding dust and leftover liquidity tokens
        uint256 contractBalance = IERC20(projectToken).balanceOf(address(this));
        
        // If remaining balance after this claim would be less than expected remaining shares,
        // or if claiming more than balance, adjust
        if (userShare > contractBalance) {
            userShare = contractBalance;
        }

        // Transfer project tokens
        if (userShare > 0) {
            if (!IERC20(projectToken).transfer(msg.sender, userShare)) {
                revert TransferFailed();
            }
        }

        emit ProjectTokensClaimed(msg.sender, userShare);
    }
    
    /// @notice Claim remaining project token dust after ALL users have claimed
    /// @dev #13: Only callable after all participants have claimed their tokens
    /// @dev FIND-002/017: Ensures dust cannot be claimed before all users get their share
    function claimDust() external onlyAdmin inState(PoolState.Completed) {
        // FIND-002: Ensure all participants have claimed before allowing dust collection
        if (claimCount < participantCount) revert NotAllClaimed();
        
        uint256 balance = IERC20(projectToken).balanceOf(address(this));
        if (balance > 0) {
            _safeTransferProjectToken(projectOwner, balance);
            emit TokensRescued(projectToken, projectOwner, balance);
        }
    }

    /*//////////////////////////////////////////////////////////////
                        EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emergency withdraw a single NFT
    /// @param tokenId The NFT token ID
    /// @dev #3: Updates accounting invariants when withdrawing
    /// @dev Handles NFTs deposited to Autopilot by withdrawing first
    /// @dev If Autopilot withdraw fails (e.g., during special window), NFT is marked unlocked
    ///      but stays in Autopilot. Use retryAutopilotWithdraw() later, then user calls claimUnlockedNFT()
    function emergencyWithdrawNFT(uint256 tokenId) external onlyOwner {
        // L-08: Prevent emergency withdraw in Completed state to protect token distribution fairness
        if (state == PoolState.Completed) revert PoolIsCompleted();
        
        LockedNFT storage nft = lockedNFTs[tokenId];

        if (nft.owner == address(0)) revert NFTNotLocked();
        if (nft.unlocked) revert NFTNotLocked();

        address nftOwner = nft.owner;
        
        // #3: Update accounting before marking as unlocked
        uint256 vp = nft.votingPower;
        if (vp > 0) {
            totalVotingPower -= vp;
            userInfo[nftOwner].totalVotingPower -= vp;
            // FIND-002/007: Decrement participant count if user has no more voting power
            if (userInfo[nftOwner].totalVotingPower == 0) {
                participantCount--;
            }
        }
        
        nft.unlocked = true;

        // If NFT is in Autopilot, try to withdraw it
        if (!_tryWithdrawFromAutopilot(tokenId, nftOwner)) {
            // Autopilot withdraw failed (likely during special window)
            // NFT is marked unlocked but stays in Autopilot
            // Owner must call retryAutopilotWithdraw() later, then user calls claimUnlockedNFT()
            emit BatchProgress("autopilotWithdrawFailed", tokenId, 0);
            return; // Don't transfer - NFT still in Autopilot
        }

        // Transfer NFT back to original owner
        votingEscrow.safeTransferFrom(address(this), nftOwner, tokenId);

        emit EmergencyWithdraw(nftOwner, tokenId);
    }

    /// @notice Emergency withdraw NFTs in batches
    /// @param batchSize Number of NFTs to process
    /// @dev M-02 fix: Reverts in Finalizing state to prevent batchIndex desynchronization
    ///      with the reward-claiming batch flow. Use emergencyWithdrawNFT() for single NFTs instead.
    function emergencyWithdrawBatch(uint256 batchSize) external onlyOwner {
        // L-08: Prevent emergency withdraw in Completed state to protect token distribution fairness
        if (state == PoolState.Completed) revert PoolIsCompleted();
        // M-02: Prevent batch emergency withdraw during Finalizing to avoid batchIndex desync
        // with startClaimRewardsFromAutopilot/continueClaimRewardsFromAutopilot
        if (state == PoolState.Finalizing) revert InvalidState();
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
    /// @dev #3: Updates accounting invariants
    /// @dev FIND-002/007: Updates participantCount when user has no remaining voting power
    /// @dev Handles NFTs deposited to Autopilot - if withdraw fails, NFT stays in Autopilot
    function _emergencyWithdrawSingle(uint256 tokenId) internal {
        LockedNFT storage nft = lockedNFTs[tokenId];

        if (!nft.unlocked && nft.owner != address(0)) {
            address nftOwner = nft.owner;
            
            // #3: Update accounting before marking as unlocked
            uint256 vp = nft.votingPower;
            if (vp > 0) {
                totalVotingPower -= vp;
                userInfo[nftOwner].totalVotingPower -= vp;
                // FIND-002/007: Decrement participant count if user has no more voting power
                if (userInfo[nftOwner].totalVotingPower == 0) {
                    participantCount--;
                }
            }
            
            nft.unlocked = true;
            
            // If NFT is in Autopilot, try to withdraw it
            _tryWithdrawFromAutopilot(tokenId, nftOwner);
            
            // Only transfer if not still in Autopilot
            if (!depositedToAutopilot[tokenId]) {
                votingEscrow.safeTransferFrom(address(this), nftOwner, tokenId);
                emit EmergencyWithdraw(nftOwner, tokenId);
            }
        }
    }

    /// @notice Retry withdrawing NFTs from Autopilot that failed during emergency withdraw
    /// @param tokenIds Array of token IDs to retry withdrawal for
    /// @dev Call this after special window ends if emergency withdraw left NFTs in Autopilot
    /// @dev After successful retry, users can call claimUnlockedNFT() to get their NFTs
    /// @dev Any USDC rewards from withdraw are sent to the NFT owner
    function retryAutopilotWithdraw(uint256[] calldata tokenIds) external onlyOwner {
        if (tokenIds.length > MAX_BATCH_SIZE) revert BatchSizeTooLarge();
        
        for (uint256 i = 0; i < tokenIds.length;) {
            uint256 tokenId = tokenIds[i];
            LockedNFT storage nft = lockedNFTs[tokenId];
            
            // Only process if unlocked but still in Autopilot
            if (nft.unlocked && depositedToAutopilot[tokenId]) {
                _tryWithdrawFromAutopilot(tokenId, nft.owner);
            }
            unchecked { ++i; }
        }
    }

    /// @notice Claim an unlocked NFT that was stuck in Autopilot
    /// @param tokenId The NFT token ID to claim
    /// @dev Only callable by original NFT owner after owner has successfully called retryAutopilotWithdraw()
    function claimUnlockedNFT(uint256 tokenId) external nonReentrant {
        LockedNFT storage nft = lockedNFTs[tokenId];
        
        if (nft.owner != msg.sender) revert NotNFTOwner();
        if (!nft.unlocked) revert NFTNotLocked();
        if (depositedToAutopilot[tokenId]) revert StillInAutopilot(); // Wait for owner to call retryAutopilotWithdraw()
        
        // Check NFT is still owned by this contract (not already transferred)
        if (votingEscrow.ownerOf(tokenId) != address(this)) revert NFTNotLocked();
        
        // Transfer NFT back to owner
        votingEscrow.safeTransferFrom(address(this), msg.sender, tokenId);
        
        emit VeAEROUnlocked(msg.sender, tokenId);
    }

    /// @notice Check if an NFT is stuck (unlocked but still in Autopilot)
    /// @param tokenId The NFT token ID to check
    /// @return isStuck True if NFT needs retryAutopilotWithdraw()
    /// @return nftOwner Original owner of the NFT
    function isNFTStuckInAutopilot(uint256 tokenId) external view returns (bool isStuck, address nftOwner) {
        LockedNFT storage nft = lockedNFTs[tokenId];
        return (nft.unlocked && depositedToAutopilot[tokenId], nft.owner);
    }

    /// @notice Get NFT IDs that are stuck in Autopilot (paginated)
    /// @param startIndex Starting index in lockedTokenIds array
    /// @param limit Maximum number of results (0 = 100)
    /// @return stuckIds Array of token IDs that need retryAutopilotWithdraw()
    /// @return totalCount Total number of locked NFTs (for pagination)
    /// @return stuckCount Total number of stuck NFTs found in this page
    function getStuckNFTIdsPaginated(
        uint256 startIndex,
        uint256 limit
    ) external view returns (
        uint256[] memory stuckIds,
        uint256 totalCount,
        uint256 stuckCount
    ) {
        totalCount = lockedTokenIds.length;
        
        if (startIndex >= totalCount) {
            return (new uint256[](0), totalCount, 0);
        }
        
        if (limit == 0) limit = 100;
        
        uint256 endIndex = startIndex + limit;
        if (endIndex > totalCount) endIndex = totalCount;
        
        // First pass: count stuck NFTs in range
        uint256 count = 0;
        for (uint256 i = startIndex; i < endIndex; i++) {
            uint256 tokenId = lockedTokenIds[i];
            if (lockedNFTs[tokenId].unlocked && depositedToAutopilot[tokenId]) {
                count++;
            }
        }
        
        // Second pass: populate array
        stuckIds = new uint256[](count);
        uint256 index = 0;
        for (uint256 i = startIndex; i < endIndex; i++) {
            uint256 tokenId = lockedTokenIds[i];
            if (lockedNFTs[tokenId].unlocked && depositedToAutopilot[tokenId]) {
                stuckIds[index++] = tokenId;
            }
        }
        
        stuckCount = count;
    }

    /// @notice Get emergency withdraw progress
    function getEmergencyWithdrawProgress() external view returns (
        uint256 processed,
        uint256 total,
        bool inProgress
    ) {
        return (batchIndex, lockedTokenIds.length, batchInProgress);
    }
    
    /// @notice Cancel the pool and enable project token recovery
    /// @dev Can be called in any state except Completed (for emergency recovery)
    /// @dev Requires all NFTs to be emergency withdrawn AND not stuck in Autopilot
    function cancelPool() external onlyOwner {
        // Cannot cancel a completed pool
        if (state == PoolState.Completed) revert InvalidState();
        if (state == PoolState.Cancelled) revert InvalidState();
        if (batchInProgress) revert BatchInProgress();
        
        // Ensure all NFTs are withdrawn AND not stuck in Autopilot
        uint256 length = lockedTokenIds.length;
        for (uint256 i = 0; i < length; i++) {
            uint256 tokenId = lockedTokenIds[i];
            if (!lockedNFTs[tokenId].unlocked) {
                revert NFTNotLocked(); // Still has locked NFTs
            }
            if (depositedToAutopilot[tokenId]) {
                revert StillInAutopilot(); // NFT stuck in Autopilot - call retryAutopilotWithdraw first
            }
        }
        
        _setState(PoolState.Cancelled);
        
        // Transfer project tokens back to project owner
        uint256 balance = IERC20(projectToken).balanceOf(address(this));
        if (balance > 0) {
            _safeTransferProjectToken(projectOwner, balance);
        }
        
        emit PoolCancelledEvent(balance);
    }

    /// @notice Rescue stuck tokens (cannot rescue project tokens unless Cancelled)
    /// @param token The token address
    /// @param to Recipient address
    /// @param amount Amount to rescue
    /// @dev #15: Uses low-level call to handle non-standard ERC20 tokens
    function rescueTokens(address token, address to, uint256 amount) external onlyAdmin {
        // Can only rescue projectToken if pool is Cancelled
        if (token == projectToken && state != PoolState.Cancelled) revert NotProjectToken();
        if (to == address(0)) revert ZeroAddress();

        // #15: Use low-level call to handle non-standard tokens (no bool return)
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        
        // Check success: either call succeeded with no data, or returned true
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
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
    
    /// @notice Set deadline buffer for swap/liquidity operations
    /// @dev FIND-006: Provides meaningful deadline protection
    /// @param _buffer Buffer in seconds (max 1 hour)
    function setDeadlineBuffer(uint256 _buffer) external onlyAdmin {
        if (_buffer > 1 hours) revert InvalidDeadline();
        deadlineBuffer = _buffer;
    }

    /// @notice Update the price arbitrageur contract
    /// @dev Allows upgrading arbitrage logic without redeploying the pool
    /// @param _newArbitrageur Address of the new CLPriceArbitrageur contract
    function setPriceArbitrageur(address _newArbitrageur) external onlyOwner {
        if (_newArbitrageur == address(0)) revert ZeroAddress();
        address oldArbitrageur = address(priceArbitrageur);
        priceArbitrageur = CLPriceArbitrageur(_newArbitrageur);
        emit PriceArbitrageurUpdated(oldArbitrageur, _newArbitrageur);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get all locked token IDs
    /// @return Array of token IDs
    function getLockedTokenIds() external view returns (uint256[] memory) {
        return lockedTokenIds;
    }

    /// @notice Get the number of locked NFTs
    /// @return Number of locked token IDs
    function getLockedTokenIdsLength() external view returns (uint256) {
        return lockedTokenIds.length;
    }

    // NOTE: View functions moved to KickoffPoolReader for bytecode optimization:
    // getPendingRewards, getRewardContracts, getAvailableRewardTokens,
    // getTotalClaimableRewards, getClaimableTokens, getLockedNFTInfo
    // Use public mappings directly: lockedNFTs, userInfo, aerodromeEpochStart

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

    /// @notice Try to withdraw an NFT from Autopilot and send USDC rewards to recipient
    /// @param tokenId The NFT token ID
    /// @param usdcRecipient Address to receive any USDC rewards
    /// @return success True if withdraw succeeded, false if it failed
    /// @dev Common logic extracted to reduce bytecode duplication
    function _tryWithdrawFromAutopilot(uint256 tokenId, address usdcRecipient) internal returns (bool success) {
        if (!depositedToAutopilot[tokenId]) return true; // Not in Autopilot, nothing to do
        
        uint256 usdcBefore = usdc.balanceOf(address(this));
        
        try autopilot.withdraw(tokenId) {
            depositedToAutopilot[tokenId] = false;
            emit WithdrawnFromAutopilot(tokenId);
            
            // Send any claimed USDC rewards to recipient
            uint256 usdcAfter = usdc.balanceOf(address(this));
            if (usdcAfter > usdcBefore) {
                _safeTransferUSDC(usdcRecipient, usdcAfter - usdcBefore);
            }
            return true;
        } catch {
            return false;
        }
    }

    /// @notice Update pool state
    function _setState(PoolState newState) internal {
        PoolState previousState = state;
        state = newState;
        emit StateChanged(previousState, newState);
    }

    /// @notice Safe transfer helper for project tokens
    /// @dev Handles non-standard ERC20 tokens that don't return bool
    function _safeTransferProjectToken(address to, uint256 amount) internal {
        (bool success, bytes memory data) = projectToken.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            revert TransferFailed();
        }
    }

    /// @notice Safe transfer helper for USDC
    /// @dev Checks return value to handle edge cases
    function _safeTransferUSDC(address to, uint256 amount) internal {
        (bool success, bytes memory data) = address(usdc).call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            revert TransferFailed();
        }
    }
}

