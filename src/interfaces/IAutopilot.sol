// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IAutopilot
/// @notice Interface for Autopilot PermanentLocksPoolV1 contract
/// @dev Used for depositing veAERO NFTs, claiming USDC rewards, and withdrawing
interface IAutopilot {
    /// @notice Individual Lock Deposit Information Structure
    struct LockInfo {
        /// @notice Original NFT ID that was deposited
        uint256 lock_id;
        /// @notice First snapshot ID that this lock is eligible for
        uint256 start_snapshot_id;
        /// @notice Last epoch ID for which rewards were calculated
        uint256 rewards_snapshot_id;
        /// @notice Current voting power of this lock
        uint256 voting_power;
        /// @notice Accumulated rewards waiting to be claimed
        uint256 postponed_rewards;
    }

    /// @notice Deposits a veNFT lock into the vault
    /// @dev Lock must not have voted in current epoch and caller must own the NFT
    /// @param _lock_id Token ID of the permanent veNFT to deposit
    function deposit(uint256 _lock_id) external;

    /// @notice Withdraws a specific lock by lock ID
    /// @dev Must not be in special window and caller must own the lock
    /// @param _lock_id Lock ID of the NFT to withdraw
    function withdraw(uint256 _lock_id) external;

    /// @notice Claims accumulated rewards for a specific lock
    /// @dev Caller must have lock deposited
    /// @param _lock_id Lock ID to claim rewards from
    function claim(uint256 _lock_id) external;

    /// @notice Returns the rewards token used in the locks pool (USDC)
    function rewards_token() external view returns (address);

    /// @notice Calculates pending rewards for a specific lock
    /// @param _owner Address of the lock owner
    /// @param _lock_id Lock ID to calculate pending rewards for
    /// @return pending_rewards Amount of pending rewards for this lock
    function getPendingRewards(address _owner, uint256 _lock_id) external view returns (uint256);

    /// @notice Retrieves specific lock information by lock ID and owner
    /// @param _owner Address of the lock owner
    /// @param _lock_id Lock ID to retrieve information for
    /// @return LockInfo struct containing the specific lock details
    function getUserLock(address _owner, uint256 _lock_id) external view returns (LockInfo memory);

    /// @notice ID of the last reward snapshot (corresponds to epoch ID)
    function last_snapshot_id() external view returns (uint256);

    /// @notice Gets total tracked weight information for current epoch
    /// @return total_tracked_weight_ Total tracked weight from users
    function getTvl() external view returns (uint256 total_tracked_weight_);

    /// @notice Gets the current epoch ID
    /// @return Current epoch ID based on block timestamp
    function getCurrentEpochId() external view returns (uint256);

    /// @notice Provides comprehensive epoch information
    /// @param _epoch_id The epoch ID to get information for
    /// @return epoch_start Timestamp when epoch starts
    /// @return epoch_end Timestamp when epoch ends
    /// @return wrapped_start Timestamp when special window starts
    /// @return wrapped_end Timestamp when special window ends
    function getEpochInfo(uint256 _epoch_id) external view returns (
        uint256 epoch_start,
        uint256 epoch_end,
        uint256 wrapped_start,
        uint256 wrapped_end
    );

    /// @notice Whether deposits are paused
    function deposits_paused() external view returns (bool);

    /// @notice Pre-epoch window duration (time before epoch end when special window starts)
    function window_preepoch_duration() external view returns (uint256);

    /// @notice Post-epoch window duration (time after epoch start when special window ends)
    function window_postepoch_duration() external view returns (uint256);

    /// @notice Returns the deposit validator contract address
    /// @dev Used to get the minimum lock amount requirement
    function deposit_validator() external view returns (address);
}

/// @title IAutopilotDepositValidator
/// @notice Interface for Autopilot's deposit validator contract
interface IAutopilotDepositValidator {
    /// @notice Returns the minimum lock amount required for deposits
    /// @return The minimum veAERO voting power required
    function minimum_lock_amount() external view returns (uint256);
    
    /// @notice Returns the minimum deposit amount for a specific address
    /// @dev Returns whitelist minimum if set, otherwise global minimum
    /// @param _depositor Address to check
    /// @return Minimum deposit amount for this address
    function getMinDepositAmount(address _depositor) external view returns (uint256);
}
