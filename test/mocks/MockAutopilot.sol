// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockAutopilot
/// @notice Mock contract for Autopilot PermanentLocksPoolV1
contract MockAutopilot {
    mapping(uint256 => bool) public deposited;
    mapping(uint256 => uint256) public pendingRewards;
    address public rewards_token;
    
    constructor(address _rewardsToken) {
        rewards_token = _rewardsToken;
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
    
    function getEpochInfo(uint256) external view returns (uint256, uint256, uint256, uint256) {
        return (block.timestamp - 1 weeks, block.timestamp, 0, 0);
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
}
