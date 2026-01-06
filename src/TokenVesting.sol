// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ITokenVesting} from "./interfaces/ITokenVesting.sol";
import {IERC20} from "./interfaces/IERC20.sol";

/// @title TokenVesting
/// @notice Universal vesting contract for all project tokens created via Kickoff
/// @dev Supports multiple vesting scenarios: full TGE, partial TGE + linear, cliff + linear, pure linear
contract TokenVesting is ITokenVesting {
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
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Contract owner (can start vesting, set factory)
    address public owner;

    /// @notice Pending owner for two-step transfer
    address public pendingOwner;

    /// @notice Factory contract address (can create locks)
    address public factory;

    /// @notice Total number of locks created
    uint256 public lockCount;

    /// @notice Mapping of lockId to vesting schedule
    mapping(uint256 => VestingSchedule) internal _vestingSchedules;

    /// @notice Mapping of token address to TGE start timestamp (0 = not started)
    mapping(address => uint256) public tgeStart;

    /// @notice Mapping of token address to total locked amount
    mapping(address => uint256) public totalLocked;

    /// @notice Mapping of token address to total claimed amount
    mapping(address => uint256) public totalClaimed;

    /// @notice Mapping of user address to their lock IDs
    mapping(address => uint256[]) internal _userLocks;

    /// @notice Mapping of token address to its lock IDs
    mapping(address => uint256[]) internal _tokenLocks;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new TokenVesting contract
    constructor() {
        owner = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    modifier onlyFactory() {
        if (msg.sender != factory) revert NotFactory();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                            FACTORY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ITokenVesting
    function createLock(
        address token,
        address beneficiary,
        uint256 amount,
        uint256 cliffDuration,
        uint256 vestingDuration
    ) external onlyFactory returns (uint256 lockId) {
        if (token == address(0)) revert ZeroAddress();
        if (beneficiary == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();

        lockId = lockCount++;

        _vestingSchedules[lockId] = VestingSchedule({
            token: token,
            beneficiary: beneficiary,
            totalAmount: amount,
            cliffDuration: cliffDuration,
            vestingDuration: vestingDuration,
            claimed: 0
        });

        _userLocks[beneficiary].push(lockId);
        _tokenLocks[token].push(lockId);
        totalLocked[token] += amount;

        emit LockCreated(lockId, token, beneficiary, amount, cliffDuration, vestingDuration);
    }

    /*//////////////////////////////////////////////////////////////
                            OWNER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ITokenVesting
    function setFactory(address _factory) external onlyOwner {
        if (_factory == address(0)) revert ZeroAddress();
        if (factory != address(0)) revert FactoryAlreadySet();

        factory = _factory;
        emit FactorySet(_factory);
    }

    /// @inheritdoc ITokenVesting
    function startVesting(address token) external onlyOwner {
        if (token == address(0)) revert ZeroAddress();
        if (tgeStart[token] != 0) revert VestingAlreadyStarted();

        tgeStart[token] = block.timestamp;
        emit VestingStarted(token, block.timestamp);
    }

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
                            USER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ITokenVesting
    function claim(uint256 lockId) external nonReentrant {
        _claim(lockId);
    }

    /// @inheritdoc ITokenVesting
    function claimMultiple(uint256[] calldata lockIds) external nonReentrant {
        uint256 length = lockIds.length;
        for (uint256 i = 0; i < length;) {
            _claim(lockIds[i]);
            unchecked { ++i; }
        }
    }

    /// @notice Internal claim logic
    function _claim(uint256 lockId) internal {
        VestingSchedule storage schedule = _vestingSchedules[lockId];
        
        if (schedule.beneficiary == address(0)) revert LockNotFound();
        if (schedule.beneficiary != msg.sender) revert NotBeneficiary();

        uint256 claimable = _getClaimable(schedule);
        if (claimable == 0) revert NothingToClaim();

        schedule.claimed += claimable;
        totalClaimed[schedule.token] += claimable;

        bool success = IERC20(schedule.token).transfer(msg.sender, claimable);
        if (!success) revert TransferFailed();

        emit Claimed(lockId, msg.sender, claimable);
    }

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @inheritdoc ITokenVesting
    function getClaimable(uint256 lockId) external view returns (uint256) {
        VestingSchedule storage schedule = _vestingSchedules[lockId];
        if (schedule.beneficiary == address(0)) return 0;
        return _getClaimable(schedule);
    }

    /// @notice Internal claimable calculation
    function _getClaimable(VestingSchedule storage schedule) internal view returns (uint256) {
        uint256 start = tgeStart[schedule.token];
        
        // Vesting not started
        if (start == 0) return 0;
        
        // Still in cliff period
        if (block.timestamp < start + schedule.cliffDuration) return 0;

        uint256 vested;
        
        if (schedule.vestingDuration == 0) {
            // No vesting period - all available after cliff
            vested = schedule.totalAmount;
        } else {
            // Linear vesting after cliff
            uint256 elapsed = block.timestamp - start - schedule.cliffDuration;
            vested = (elapsed * schedule.totalAmount) / schedule.vestingDuration;
            
            // Cap at total amount
            if (vested > schedule.totalAmount) {
                vested = schedule.totalAmount;
            }
        }

        return vested - schedule.claimed;
    }

    /// @inheritdoc ITokenVesting
    function getLockInfo(uint256 lockId) external view returns (LockInfo memory info) {
        VestingSchedule storage schedule = _vestingSchedules[lockId];
        
        info = LockInfo({
            lockId: lockId,
            token: schedule.token,
            beneficiary: schedule.beneficiary,
            totalAmount: schedule.totalAmount,
            cliffDuration: schedule.cliffDuration,
            vestingDuration: schedule.vestingDuration,
            claimed: schedule.claimed,
            claimable: schedule.beneficiary != address(0) ? _getClaimable(schedule) : 0,
            tgeStart: tgeStart[schedule.token],
            isStarted: tgeStart[schedule.token] != 0
        });
    }

    /// @inheritdoc ITokenVesting
    function getUserLocks(address user) external view returns (uint256[] memory) {
        return _userLocks[user];
    }

    /// @inheritdoc ITokenVesting
    function getTokenLocks(address token) external view returns (uint256[] memory) {
        return _tokenLocks[token];
    }

    /// @inheritdoc ITokenVesting
    function getTokenInfo(address token) external view returns (TokenInfo memory info) {
        info = TokenInfo({
            tgeStart: tgeStart[token],
            isStarted: tgeStart[token] != 0,
            totalLocked: totalLocked[token],
            totalClaimed: totalClaimed[token]
        });
    }

    /// @inheritdoc ITokenVesting
    function vestingSchedules(uint256 lockId) external view returns (
        address token,
        address beneficiary,
        uint256 totalAmount,
        uint256 cliffDuration,
        uint256 vestingDuration,
        uint256 claimed
    ) {
        VestingSchedule storage schedule = _vestingSchedules[lockId];
        return (
            schedule.token,
            schedule.beneficiary,
            schedule.totalAmount,
            schedule.cliffDuration,
            schedule.vestingDuration,
            schedule.claimed
        );
    }

    /// @notice Get multiple locks info at once
    /// @param lockIds Array of lock IDs
    /// @return infos Array of lock info structs
    function getMultipleLockInfo(uint256[] calldata lockIds) external view returns (LockInfo[] memory infos) {
        uint256 length = lockIds.length;
        infos = new LockInfo[](length);
        
        for (uint256 i = 0; i < length;) {
            VestingSchedule storage schedule = _vestingSchedules[lockIds[i]];
            
            infos[i] = LockInfo({
                lockId: lockIds[i],
                token: schedule.token,
                beneficiary: schedule.beneficiary,
                totalAmount: schedule.totalAmount,
                cliffDuration: schedule.cliffDuration,
                vestingDuration: schedule.vestingDuration,
                claimed: schedule.claimed,
                claimable: schedule.beneficiary != address(0) ? _getClaimable(schedule) : 0,
                tgeStart: tgeStart[schedule.token],
                isStarted: tgeStart[schedule.token] != 0
            });
            
            unchecked { ++i; }
        }
    }

    /// @notice Get all locks for a user with full info
    /// @param user The user address
    /// @return infos Array of lock info structs
    function getUserLocksInfo(address user) external view returns (LockInfo[] memory infos) {
        uint256[] storage lockIds = _userLocks[user];
        uint256 length = lockIds.length;
        infos = new LockInfo[](length);
        
        for (uint256 i = 0; i < length;) {
            VestingSchedule storage schedule = _vestingSchedules[lockIds[i]];
            
            infos[i] = LockInfo({
                lockId: lockIds[i],
                token: schedule.token,
                beneficiary: schedule.beneficiary,
                totalAmount: schedule.totalAmount,
                cliffDuration: schedule.cliffDuration,
                vestingDuration: schedule.vestingDuration,
                claimed: schedule.claimed,
                claimable: _getClaimable(schedule),
                tgeStart: tgeStart[schedule.token],
                isStarted: tgeStart[schedule.token] != 0
            });
            
            unchecked { ++i; }
        }
    }

    /*//////////////////////////////////////////////////////////////
                        EMERGENCY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emergency rescue stuck tokens (only owner, only non-vested tokens)
    /// @dev Can only rescue tokens that are not part of any vesting schedule
    /// @param token The token to rescue
    /// @param to The recipient address
    /// @param amount The amount to rescue
    function emergencyRescue(address token, address to, uint256 amount) external onlyOwner {
        if (to == address(0)) revert ZeroAddress();
        
        // Calculate how much is actually locked for this token
        uint256 actuallyLocked = totalLocked[token] - totalClaimed[token];
        uint256 balance = IERC20(token).balanceOf(address(this));
        
        // Can only rescue excess tokens (tokens sent by mistake)
        uint256 rescuable = balance > actuallyLocked ? balance - actuallyLocked : 0;
        if (amount > rescuable) revert ZeroAmount(); // Using ZeroAmount as "insufficient rescuable"
        
        bool success = IERC20(token).transfer(to, amount);
        if (!success) revert TransferFailed();
    }
}

