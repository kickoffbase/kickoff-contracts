// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IPool} from "./interfaces/IPool.sol";
import {IERC20} from "./interfaces/IERC20.sol";

/// @notice Interface for Aerodrome PoolFactory
interface IPoolFactory {
    function isPool(address pool) external view returns (bool);
}

/// @notice Interface for KickoffFactory
interface IKickoffFactory {
    function isPool(address pool) external view returns (bool);
}

/// @title LPLocker
/// @notice Permanent LP lock with trading fees distribution (30% Admin / 70% Project Owner)
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
    error InvalidPool();
    error FactoryAlreadySet();
    error FactoryNotSet();
    error NotVoteSalePool();
    error NotDeployer();

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
    
    event FeesAccrued(
        address indexed votePool,
        address token,
        uint256 adminAmount,
        uint256 projectAmount
    );
    
    event FeesWithdrawn(
        address indexed votePool,
        address indexed recipient,
        address token,
        uint256 amount
    );

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Info about locked LP for a vote pool
    struct LockedLP {
        address lpToken; // Aerodrome LP token address
        address aerodromePool; // Aerodrome Pool contract (for claimFees)
        address admin; // Receives 30% of trading fees
        address projectOwner; // Receives 70% of trading fees
        uint256 totalLP; // Total LP locked (forever)
        bool exists; // Whether this pool exists
    }
    
    /// @notice Accrued fees for pull-based withdrawal (#18)
    struct AccruedFees {
        uint256 adminBalance;
        uint256 projectBalance;
    }

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Aerodrome PoolFactory address on Base mainnet
    address public constant AERODROME_POOL_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

    /// @notice Deployer address (for setFactory access control)
    address public immutable deployer;

    /// @notice KickoffFactory address (set once after deployment)
    /// @dev Only pools created by KickoffFactory can call lockLP()
    address public kickoffFactory;

    /// @notice Fee split for admin (30%)
    uint256 public constant ADMIN_FEE_BPS = 3000;

    /// @notice Fee split for project owner (70%)
    uint256 public constant PROJECT_OWNER_FEE_BPS = 7000;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Mapping from vote pool address to locked LP info
    mapping(address => LockedLP) public lockedPools;

    /// @notice Array of all vote pools with locked LP
    address[] public allVotePools;
    
    /// @notice #18: Accrued fees per votePool per token (pull-based)
    /// @dev votePool => token => AccruedFees
    mapping(address => mapping(address => AccruedFees)) public accruedFees;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        deployer = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                            FACTORY SETUP
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the KickoffFactory address (can only be called once by deployer)
    /// @param _factory The KickoffFactory address
    function setFactory(address _factory) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (_factory == address(0)) revert ZeroAddress();
        if (kickoffFactory != address(0)) revert FactoryAlreadySet();
        kickoffFactory = _factory;
    }

    /*//////////////////////////////////////////////////////////////
                            LOCK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Lock LP tokens permanently
    /// @dev Only callable by KickoffVoteSalePool contracts created by KickoffFactory.
    /// @param lpToken The Aerodrome LP token address
    /// @param aerodromePool The Aerodrome Pool contract address
    /// @param admin The admin address (receives 30% fees)
    /// @param projectOwner The project owner address (receives 70% fees)
    /// @param amount The amount of LP tokens to lock
    function lockLP(
        address lpToken,
        address aerodromePool,
        address admin,
        address projectOwner,
        uint256 amount
    ) external {
        // Ensure factory is set
        if (kickoffFactory == address(0)) revert FactoryNotSet();
        
        // Only allow calls from KickoffVoteSalePool contracts
        if (!IKickoffFactory(kickoffFactory).isPool(msg.sender)) revert NotVoteSalePool();
        
        if (lpToken == address(0) || aerodromePool == address(0)) revert ZeroAddress();
        if (admin == address(0) || projectOwner == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (lockedPools[msg.sender].exists) revert AlreadyLocked();
        
        // SECURITY: Validate that aerodromePool is a legitimate Aerodrome pool
        if (!IPoolFactory(AERODROME_POOL_FACTORY).isPool(aerodromePool)) revert InvalidPool();
        
        // On Aerodrome, LP token address IS the pool contract address
        if (lpToken != aerodromePool) revert InvalidPool();

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

    /// @notice Claim and accrue trading fees from Aerodrome pool
    /// @dev #18: Pull-based - fees are accrued internally, then withdrawn separately
    /// @param votePool The vote pool address
    function claimTradingFees(address votePool) external nonReentrant {
        LockedLP storage pool = lockedPools[votePool];

        if (!pool.exists) revert PoolNotFound();

        // Get token addresses
        address token0 = IPool(pool.aerodromePool).token0();
        address token1 = IPool(pool.aerodromePool).token1();

        // Claim fees from Aerodrome pool
        (uint256 claimed0, uint256 claimed1) = IPool(pool.aerodromePool).claimFees();

        // Calculate and accrue shares
        if (claimed0 > 0) {
            uint256 adminShare0 = (claimed0 * ADMIN_FEE_BPS) / BPS_DENOMINATOR;
            uint256 projectShare0 = claimed0 - adminShare0;
            accruedFees[votePool][token0].adminBalance += adminShare0;
            accruedFees[votePool][token0].projectBalance += projectShare0;
            emit FeesAccrued(votePool, token0, adminShare0, projectShare0);
        }
        
        if (claimed1 > 0) {
            uint256 adminShare1 = (claimed1 * ADMIN_FEE_BPS) / BPS_DENOMINATOR;
            uint256 projectShare1 = claimed1 - adminShare1;
            accruedFees[votePool][token1].adminBalance += adminShare1;
            accruedFees[votePool][token1].projectBalance += projectShare1;
            emit FeesAccrued(votePool, token1, adminShare1, projectShare1);
        }

        emit TradingFeesClaimed(votePool, msg.sender, token0, claimed0, token1, claimed1);
    }
    
    /// @notice Withdraw accrued fees for admin
    /// @dev #18: Pull-based withdrawal to any recipient address
    /// @param votePool The vote pool address
    /// @param token The token to withdraw
    /// @param recipient The address to receive fees
    function withdrawAdminFees(address votePool, address token, address recipient) external nonReentrant {
        LockedLP storage pool = lockedPools[votePool];
        if (!pool.exists) revert PoolNotFound();
        if (msg.sender != pool.admin) revert NotAuthorized();
        if (recipient == address(0)) revert ZeroAddress();
        
        uint256 amount = accruedFees[votePool][token].adminBalance;
        if (amount == 0) revert ZeroAmount();
        
        accruedFees[votePool][token].adminBalance = 0;
        
        _safeTransfer(token, recipient, amount);
        emit FeesWithdrawn(votePool, recipient, token, amount);
    }
    
    /// @notice Withdraw accrued fees for project owner
    /// @dev #18: Pull-based withdrawal to any recipient address
    /// @param votePool The vote pool address
    /// @param token The token to withdraw
    /// @param recipient The address to receive fees
    function withdrawProjectFees(address votePool, address token, address recipient) external nonReentrant {
        LockedLP storage pool = lockedPools[votePool];
        if (!pool.exists) revert PoolNotFound();
        if (msg.sender != pool.projectOwner) revert NotAuthorized();
        if (recipient == address(0)) revert ZeroAddress();
        
        uint256 amount = accruedFees[votePool][token].projectBalance;
        if (amount == 0) revert ZeroAmount();
        
        accruedFees[votePool][token].projectBalance = 0;
        
        _safeTransfer(token, recipient, amount);
        emit FeesWithdrawn(votePool, recipient, token, amount);
    }
    
    /// @notice Safe transfer helper for non-standard tokens
    /// @dev #15: Handles tokens that don't return bool on transfer
    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            revert TransferFailed();
        }
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get pending trading fees for a vote pool (not yet claimed from Aerodrome)
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
    
    /// @notice Get accrued (already claimed, awaiting withdrawal) fees for a vote pool
    /// @dev #18: Shows fees that have been claimed from Aerodrome but not yet withdrawn
    /// @param votePool The vote pool address
    /// @param token The token address to check
    /// @return adminBalance Accrued balance for admin
    /// @return projectBalance Accrued balance for project owner
    function getAccruedFees(address votePool, address token) 
        external 
        view 
        returns (uint256 adminBalance, uint256 projectBalance) 
    {
        AccruedFees storage fees = accruedFees[votePool][token];
        return (fees.adminBalance, fees.projectBalance);
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

