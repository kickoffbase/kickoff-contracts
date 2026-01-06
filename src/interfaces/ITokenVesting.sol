// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ITokenVesting
/// @notice Interface for the TokenVesting contract
interface ITokenVesting {
    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Vesting schedule for a lock
    struct VestingSchedule {
        address token;           // ERC20 token address
        address beneficiary;     // Lock owner (who can claim)
        uint256 totalAmount;     // Total tokens under vesting (excludes TGE)
        uint256 cliffDuration;   // Cliff duration in seconds
        uint256 vestingDuration; // Linear vesting duration in seconds
        uint256 claimed;         // Amount already claimed
    }

    /// @notice Full lock info including computed values
    struct LockInfo {
        uint256 lockId;
        address token;
        address beneficiary;
        uint256 totalAmount;
        uint256 cliffDuration;
        uint256 vestingDuration;
        uint256 claimed;
        uint256 claimable;
        uint256 tgeStart;
        bool isStarted;
    }

    /// @notice Token vesting info
    struct TokenInfo {
        uint256 tgeStart;
        bool isStarted;
        uint256 totalLocked;
        uint256 totalClaimed;
    }

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Emitted when a new lock is created
    event LockCreated(
        uint256 indexed lockId,
        address indexed token,
        address indexed beneficiary,
        uint256 amount,
        uint256 cliffDuration,
        uint256 vestingDuration
    );

    /// @notice Emitted when vesting starts for a token
    event VestingStarted(address indexed token, uint256 tgeStart);

    /// @notice Emitted when tokens are claimed
    event Claimed(uint256 indexed lockId, address indexed beneficiary, uint256 amount);

    /// @notice Emitted when factory is set
    event FactorySet(address indexed factory);

    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error NotOwner();
    error NotFactory();
    error NotBeneficiary();
    error ZeroAddress();
    error ZeroAmount();
    error VestingNotStarted();
    error VestingAlreadyStarted();
    error NothingToClaim();
    error LockNotFound();
    error TransferFailed();
    error FactoryAlreadySet();
    error ReentrancyGuardReentrantCall();

    /*//////////////////////////////////////////////////////////////
                            FACTORY FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new vesting lock (only callable by factory)
    /// @param token The ERC20 token address
    /// @param beneficiary The lock owner who can claim
    /// @param amount Total amount under vesting
    /// @param cliffDuration Cliff duration in seconds
    /// @param vestingDuration Linear vesting duration in seconds
    /// @return lockId The ID of the created lock
    function createLock(
        address token,
        address beneficiary,
        uint256 amount,
        uint256 cliffDuration,
        uint256 vestingDuration
    ) external returns (uint256 lockId);

    /*//////////////////////////////////////////////////////////////
                            OWNER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Start vesting for a token (activates TGE timestamp)
    /// @param token The token address to start vesting for
    function startVesting(address token) external;

    /// @notice Set the factory address (only owner, once)
    /// @param _factory The factory contract address
    function setFactory(address _factory) external;

    /*//////////////////////////////////////////////////////////////
                            USER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim available tokens from a lock
    /// @param lockId The lock ID to claim from
    function claim(uint256 lockId) external;

    /// @notice Claim all available tokens from multiple locks
    /// @param lockIds Array of lock IDs to claim from
    function claimMultiple(uint256[] calldata lockIds) external;

    /*//////////////////////////////////////////////////////////////
                            VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get claimable amount for a lock
    /// @param lockId The lock ID
    /// @return The claimable amount
    function getClaimable(uint256 lockId) external view returns (uint256);

    /// @notice Get full info about a lock
    /// @param lockId The lock ID
    /// @return info The lock info struct
    function getLockInfo(uint256 lockId) external view returns (LockInfo memory info);

    /// @notice Get all lock IDs for a user
    /// @param user The user address
    /// @return Array of lock IDs
    function getUserLocks(address user) external view returns (uint256[] memory);

    /// @notice Get all lock IDs for a token
    /// @param token The token address
    /// @return Array of lock IDs
    function getTokenLocks(address token) external view returns (uint256[] memory);

    /// @notice Get vesting info for a token
    /// @param token The token address
    /// @return info The token vesting info
    function getTokenInfo(address token) external view returns (TokenInfo memory info);

    /// @notice Get the vesting schedule for a lock
    /// @param lockId The lock ID
    /// @return token The token address
    /// @return beneficiary The beneficiary address
    /// @return totalAmount The total amount under vesting
    /// @return cliffDuration The cliff duration in seconds
    /// @return vestingDuration The vesting duration in seconds
    /// @return claimed The amount already claimed
    function vestingSchedules(uint256 lockId) external view returns (
        address token,
        address beneficiary,
        uint256 totalAmount,
        uint256 cliffDuration,
        uint256 vestingDuration,
        uint256 claimed
    );

    /// @notice Get the factory address
    /// @return The factory address
    function factory() external view returns (address);

    /// @notice Get the owner address
    /// @return The owner address
    function owner() external view returns (address);

    /// @notice Get the total number of locks
    /// @return The lock count
    function lockCount() external view returns (uint256);
}

