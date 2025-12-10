// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPool} from "./interfaces/IPool.sol";
import {IERC20} from "./interfaces/IERC20.sol";

/// @title LPLocker
/// @notice Permanent LP lock with trading fees distribution (20% Admin / 80% Project Owner)
/// @dev LP tokens are locked forever, only trading fees can be claimed
contract LPLocker {
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

    error ZeroAddress();
    error ZeroAmount();
    error NotAuthorized();
    error PoolNotFound();
    error AlreadyLocked();
    error TransferFailed();
    error ReentrancyGuardReentrantCall();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event LPLocked(
        address indexed votePool,
        address indexed lpToken,
        address admin,
        address projectOwner,
        uint256 amount
    );

    event TradingFeesClaimed(
        address indexed votePool,
        address indexed claimer,
        address token0,
        uint256 amount0,
        address token1,
        uint256 amount1
    );

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Info about locked LP for a vote pool
    struct LockedLP {
        address lpToken; // Aerodrome LP token address
        address aerodromePool; // Aerodrome Pool contract (for claimFees)
        address admin; // Receives 20% of trading fees
        address projectOwner; // Receives 80% of trading fees
        uint256 totalLP; // Total LP locked (forever)
        bool exists; // Whether this pool exists
    }

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Fee split for admin (20%)
    uint256 public constant ADMIN_FEE_BPS = 2000;

    /// @notice Fee split for project owner (80%)
    uint256 public constant PROJECT_OWNER_FEE_BPS = 8000;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Mapping from vote pool address to locked LP info
    mapping(address => LockedLP) public lockedPools;

    /// @notice Array of all vote pools with locked LP
    address[] public allVotePools;

    /*//////////////////////////////////////////////////////////////
                            LOCK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Lock LP tokens permanently
    /// @param lpToken The Aerodrome LP token address
    /// @param aerodromePool The Aerodrome Pool contract address
    /// @param admin The admin address (receives 20% fees)
    /// @param projectOwner The project owner address (receives 80% fees)
    /// @param amount The amount of LP tokens to lock
    function lockLP(
        address lpToken,
        address aerodromePool,
        address admin,
        address projectOwner,
        uint256 amount
    ) external {
        if (lpToken == address(0) || aerodromePool == address(0)) revert ZeroAddress();
        if (admin == address(0) || projectOwner == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (lockedPools[msg.sender].exists) revert AlreadyLocked();

        // Transfer LP tokens to this contract
        if (!IERC20(lpToken).transferFrom(msg.sender, address(this), amount)) revert TransferFailed();

        // Store locked LP info
        lockedPools[msg.sender] = LockedLP({
            lpToken: lpToken,
            aerodromePool: aerodromePool,
            admin: admin,
            projectOwner: projectOwner,
            totalLP: amount,
            exists: true
        });

        allVotePools.push(msg.sender);

        emit LPLocked(msg.sender, lpToken, admin, projectOwner, amount);
    }

    /*//////////////////////////////////////////////////////////////
                        CLAIM TRADING FEES
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim trading fees for a vote pool
    /// @dev Can be called by either admin (gets 20%) or project owner (gets 80%)
    /// @param votePool The vote pool address
    function claimTradingFees(address votePool) external nonReentrant {
        LockedLP storage pool = lockedPools[votePool];

        if (!pool.exists) revert PoolNotFound();
        if (msg.sender != pool.admin && msg.sender != pool.projectOwner) {
            revert NotAuthorized();
        }

        // Get token addresses
        address token0 = IPool(pool.aerodromePool).token0();
        address token1 = IPool(pool.aerodromePool).token1();

        // Claim fees from Aerodrome pool
        // Note: In Aerodrome, LP holders earn fees proportionally
        // We need to call claimFees on the pool contract
        (uint256 claimed0, uint256 claimed1) = IPool(pool.aerodromePool).claimFees();

        // Calculate shares
        uint256 adminShare0 = (claimed0 * ADMIN_FEE_BPS) / BPS_DENOMINATOR;
        uint256 adminShare1 = (claimed1 * ADMIN_FEE_BPS) / BPS_DENOMINATOR;
        uint256 projectShare0 = claimed0 - adminShare0;
        uint256 projectShare1 = claimed1 - adminShare1;

        // Transfer to admin
        if (adminShare0 > 0) {
            if (!IERC20(token0).transfer(pool.admin, adminShare0)) revert TransferFailed();
        }
        if (adminShare1 > 0) {
            if (!IERC20(token1).transfer(pool.admin, adminShare1)) revert TransferFailed();
        }

        // Transfer to project owner
        if (projectShare0 > 0) {
            if (!IERC20(token0).transfer(pool.projectOwner, projectShare0)) revert TransferFailed();
        }
        if (projectShare1 > 0) {
            if (!IERC20(token1).transfer(pool.projectOwner, projectShare1)) revert TransferFailed();
        }

        emit TradingFeesClaimed(votePool, msg.sender, token0, claimed0, token1, claimed1);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get pending trading fees for a vote pool
    /// @param votePool The vote pool address
    /// @return token0 The first token address
    /// @return amount0 Pending amount of token0
    /// @return token1 The second token address
    /// @return amount1 Pending amount of token1
    function pendingFees(address votePool)
        external
        view
        returns (address token0, uint256 amount0, address token1, uint256 amount1)
    {
        LockedLP storage pool = lockedPools[votePool];

        if (!pool.exists) {
            return (address(0), 0, address(0), 0);
        }

        token0 = IPool(pool.aerodromePool).token0();
        token1 = IPool(pool.aerodromePool).token1();

        // Get claimable fees (this is a view approximation)
        // Note: Actual claimable amounts may differ slightly
        amount0 = IPool(pool.aerodromePool).claimable0(address(this));
        amount1 = IPool(pool.aerodromePool).claimable1(address(this));
    }

    /// @notice Get fee shares for admin and project owner
    /// @param votePool The vote pool address
    /// @return adminShare0 Admin's share of token0
    /// @return adminShare1 Admin's share of token1
    /// @return projectShare0 Project owner's share of token0
    /// @return projectShare1 Project owner's share of token1
    function getPendingShares(address votePool)
        external
        view
        returns (uint256 adminShare0, uint256 adminShare1, uint256 projectShare0, uint256 projectShare1)
    {
        LockedLP storage pool = lockedPools[votePool];

        if (!pool.exists) {
            return (0, 0, 0, 0);
        }

        uint256 amount0 = IPool(pool.aerodromePool).claimable0(address(this));
        uint256 amount1 = IPool(pool.aerodromePool).claimable1(address(this));

        adminShare0 = (amount0 * ADMIN_FEE_BPS) / BPS_DENOMINATOR;
        adminShare1 = (amount1 * ADMIN_FEE_BPS) / BPS_DENOMINATOR;
        projectShare0 = amount0 - adminShare0;
        projectShare1 = amount1 - adminShare1;
    }

    /// @notice Get locked LP info for a vote pool
    /// @param votePool The vote pool address
    /// @return info The LockedLP struct
    function getLockedLP(address votePool) external view returns (LockedLP memory info) {
        return lockedPools[votePool];
    }

    /// @notice Get all vote pools with locked LP
    /// @return Array of vote pool addresses
    function getAllVotePools() external view returns (address[] memory) {
        return allVotePools;
    }

    /// @notice Get the count of vote pools with locked LP
    /// @return The count
    function getVotePoolCount() external view returns (uint256) {
        return allVotePools.length;
    }
}

