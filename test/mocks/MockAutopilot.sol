// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockDepositValidator
/// @notice Mock deposit validator for whitelist testing
contract MockDepositValidator {
    uint256 public minimum_lock_amount = 1000e18;
    mapping(address => uint256) public whitelist_min_amount;
    
    function setMinimumLockAmount(uint256 _amount) external {
        minimum_lock_amount = _amount;
    }
    
    function setWhitelistMin(address _depositor, uint256 _amount) external {
        whitelist_min_amount[_depositor] = _amount;
    }
    
    function getMinDepositAmount(address _depositor) external view returns (uint256) {
        uint256 wl_min = whitelist_min_amount[_depositor];
        return wl_min > 0 ? wl_min : minimum_lock_amount;
    }
}

/// @title MockAutopilot
/// @notice Mock contract for Autopilot PermanentLocksPoolV1
contract MockAutopilot {
    mapping(uint256 => bool) public deposited;
    mapping(uint256 => uint256) public pendingRewards;
    address public rewards_token;
    MockDepositValidator public depositValidator;
    
    // Fixed epoch times for testing (set during construction)
    uint256 public currentEpochStart;
    uint256 public currentEpochEnd;
    
    constructor(address _rewardsToken) {
        rewards_token = _rewardsToken;
        depositValidator = new MockDepositValidator();
        // Set epoch times based on Thursday-based epochs
        // Find current epoch start (Thursday 00:00 UTC)
        currentEpochStart = (block.timestamp / 1 weeks) * 1 weeks;
        currentEpochEnd = currentEpochStart + 1 weeks;
    }
    
    function deposit(uint256 _lock_id) external {
        deposited[_lock_id] = true;
    }
    
    function withdraw(uint256 _lock_id) external {
        deposited[_lock_id] = false;
    }
    
    function claim(uint256 _lock_id) external returns (uint256) {
        uint256 amount = pendingRewards[_lock_id];
        pendingRewards[_lock_id] = 0;
        return amount;
    }
    
    function getPendingRewards(address, uint256 lock_id) external view returns (uint256) {
        return pendingRewards[lock_id];
    }
    
    function setPendingRewards(uint256 lock_id, uint256 amount) external {
        pendingRewards[lock_id] = amount;
    }
    
    function deposits_paused() external pure returns (bool) {
        return false;
    }
    
    function last_snapshot_id() external pure returns (uint256) {
        return 1;
    }
    
    function getTvl() external pure returns (uint256) {
        return 1000000e18;
    }
    
    function getCurrentEpochId() external pure returns (uint256) {
        return 1;
    }
    
    function getEpochInfo(uint256 epochId) external view returns (uint256, uint256, uint256, uint256) {
        // Use fixed epoch times based on Thursday-based epochs
        // epoch_start, epoch_end, wrapped_start, wrapped_end
        if (epochId == 1) {
            // Current epoch
            uint256 wrappedStart = currentEpochEnd - 90 minutes;  // Special window starts 90 min before end
            uint256 wrappedEnd = currentEpochEnd + 30 minutes;    // Special window ends 30 min after
            return (currentEpochStart, currentEpochEnd, wrappedStart, wrappedEnd);
        }
        // For next epoch (epochId == 2):
        if (epochId == 2) {
            uint256 nextEpochStart = currentEpochEnd;
            uint256 nextEpochEnd = currentEpochEnd + 1 weeks;
            uint256 wrappedStart = nextEpochEnd - 90 minutes;
            uint256 wrappedEnd = nextEpochEnd + 30 minutes;
            return (nextEpochStart, nextEpochEnd, wrappedStart, wrappedEnd);
        }
        // Default - return current epoch info
        return (currentEpochStart, currentEpochEnd, currentEpochEnd - 90 minutes, currentEpochEnd + 30 minutes);
    }
    
    function window_preepoch_duration() external pure returns (uint256) {
        return 90 minutes;
    }
    
    function window_postepoch_duration() external pure returns (uint256) {
        return 30 minutes;
    }
    
    struct LockInfo {
        uint256 lock_id;
        uint256 start_snapshot_id;
        uint256 rewards_snapshot_id;
        uint256 voting_power;
        uint256 postponed_rewards;
    }
    
    function getUserLock(address, uint256 lock_id) external pure returns (LockInfo memory) {
        return LockInfo({
            lock_id: lock_id,
            start_snapshot_id: 1,
            rewards_snapshot_id: 1,
            voting_power: 100000e18,
            postponed_rewards: 0
        });
    }
    
    function deposit_validator() external view returns (address) {
        return address(depositValidator);
    }
    
    /// @notice Set whitelist minimum for an address (for testing)
    function setWhitelistMin(address _depositor, uint256 _amount) external {
        depositValidator.setWhitelistMin(_depositor, _amount);
    }
    
    /// @notice Set global minimum lock amount (for testing)
    function setMinimumLockAmount(uint256 _amount) external {
        depositValidator.setMinimumLockAmount(_amount);
    }
}
