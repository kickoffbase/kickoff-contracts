// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {IERC721Receiver} from "./interfaces/IERC721Receiver.sol";

/// @notice Interface for KickoffFactory
interface IKickoffFactory {
    function isPool(address pool) external view returns (bool);
}

/// @title LPLocker
/// @notice Permanent CL Position lock with trading fees distribution (30% Admin / 70% Project Owner)
/// @dev Stores Aerodrome Slipstream NFT positions permanently, only trading fees can be claimed
contract LPLocker is IERC721Receiver {
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
    error FactoryAlreadySet();
    error FactoryNotSet();
    error NotVoteSalePool();
    error NotDeployer();
    error InvalidPosition();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event PositionLocked(
        address indexed votePool,
        uint256 indexed positionId,
        address admin,
        address projectOwner,
        uint128 liquidity
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

    /// @notice Info about locked CL position for a vote pool
    struct LockedPosition {
        uint256 positionId;      // Slipstream NFT position ID
        address token0;          // First token of the pair
        address token1;          // Second token of the pair
        address admin;           // Receives 30% of trading fees
        address projectOwner;    // Receives 70% of trading fees
        uint128 liquidity;       // Position liquidity (for reference)
        bool exists;             // Whether this pool exists
    }
    
    /// @notice Accrued fees for pull-based withdrawal
    struct AccruedFees {
        uint256 adminBalance;
        uint256 projectBalance;
    }

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Aerodrome Slipstream NonfungiblePositionManager on Base mainnet
    INonfungiblePositionManager public constant positionManager = 
        INonfungiblePositionManager(0x827922686190790b37229fd06084350E74485b72);

    /// @notice Deployer address (for setFactory access control)
    address public immutable deployer;

    /// @notice KickoffFactory address (set once after deployment)
    address public kickoffFactory;

    /// @notice Fee split for admin (30%)
    uint256 public constant ADMIN_FEE_BPS = 3000;

    /// @notice Fee split for project owner (70%)
    uint256 public constant PROJECT_OWNER_FEE_BPS = 7000;

    /// @notice Basis points denominator
    uint256 public constant BPS_DENOMINATOR = 10000;

    /// @notice Mapping from vote pool address to locked position info
    mapping(address => LockedPosition) public lockedPools;

    /// @notice Array of all vote pools with locked positions
    address[] public allVotePools;
    
    /// @notice Accrued fees per votePool per token (pull-based)
    mapping(address => mapping(address => AccruedFees)) public accruedFees;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    constructor() {
        deployer = msg.sender;
    }

    /*//////////////////////////////////////////////////////////////
                           ERC721 RECEIVER
    //////////////////////////////////////////////////////////////*/

    /// @notice Handle receipt of NFT positions
    function onERC721Received(address, address, uint256, bytes calldata) external pure override returns (bytes4) {
        return this.onERC721Received.selector;
    }

    /*//////////////////////////////////////////////////////////////
                            FACTORY SETUP
    //////////////////////////////////////////////////////////////*/

    /// @notice Set the KickoffFactory address (can only be called once by deployer)
    function setFactory(address _factory) external {
        if (msg.sender != deployer) revert NotDeployer();
        if (_factory == address(0)) revert ZeroAddress();
        if (kickoffFactory != address(0)) revert FactoryAlreadySet();
        kickoffFactory = _factory;
    }

    /*//////////////////////////////////////////////////////////////
                            LOCK FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Lock a CL position NFT permanently
    /// @dev Only callable by KickoffVoteSalePool contracts created by KickoffFactory
    /// @param positionId The Slipstream NFT position ID to lock
    /// @param admin The admin address (receives 30% fees)
    /// @param projectOwner The project owner address (receives 70% fees)
    function lockPosition(
        uint256 positionId,
        address admin,
        address projectOwner
    ) external {
        // Ensure factory is set
        if (kickoffFactory == address(0)) revert FactoryNotSet();
        
        // Only allow calls from KickoffVoteSalePool contracts
        if (!IKickoffFactory(kickoffFactory).isPool(msg.sender)) revert NotVoteSalePool();
        
        if (admin == address(0) || projectOwner == address(0)) revert ZeroAddress();
        if (lockedPools[msg.sender].exists) revert AlreadyLocked();
        
        // Get position info to validate and store token addresses
        (
            ,  // nonce
            ,  // operator
            address token0,
            address token1,
            ,  // tickSpacing
            ,  // tickLower
            ,  // tickUpper
            uint128 liquidity,
            ,  // feeGrowthInside0LastX128
            ,  // feeGrowthInside1LastX128
            ,  // tokensOwed0
               // tokensOwed1
        ) = positionManager.positions(positionId);
        
        if (liquidity == 0) revert InvalidPosition();
        
        // Transfer NFT position to this contract
        positionManager.transferFrom(msg.sender, address(this), positionId);

        // Store locked position info
        lockedPools[msg.sender] = LockedPosition({
            positionId: positionId,
            token0: token0,
            token1: token1,
            admin: admin,
            projectOwner: projectOwner,
            liquidity: liquidity,
            exists: true
        });

        allVotePools.push(msg.sender);

        emit PositionLocked(msg.sender, positionId, admin, projectOwner, liquidity);
    }

    /*//////////////////////////////////////////////////////////////
                        CLAIM TRADING FEES
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim and accrue trading fees from CL position
    /// @param votePool The vote pool address
    function claimTradingFees(address votePool) external nonReentrant {
        LockedPosition storage pool = lockedPools[votePool];

        if (!pool.exists) revert PoolNotFound();

        // Collect all fees from position
        INonfungiblePositionManager.CollectParams memory params = INonfungiblePositionManager.CollectParams({
            tokenId: pool.positionId,
            recipient: address(this),
            amount0Max: type(uint128).max,
            amount1Max: type(uint128).max
        });

        (uint256 claimed0, uint256 claimed1) = positionManager.collect(params);

        // Calculate and accrue shares
        if (claimed0 > 0) {
            uint256 adminShare0 = (claimed0 * ADMIN_FEE_BPS) / BPS_DENOMINATOR;
            uint256 projectShare0 = claimed0 - adminShare0;
            accruedFees[votePool][pool.token0].adminBalance += adminShare0;
            accruedFees[votePool][pool.token0].projectBalance += projectShare0;
            emit FeesAccrued(votePool, pool.token0, adminShare0, projectShare0);
        }
        
        if (claimed1 > 0) {
            uint256 adminShare1 = (claimed1 * ADMIN_FEE_BPS) / BPS_DENOMINATOR;
            uint256 projectShare1 = claimed1 - adminShare1;
            accruedFees[votePool][pool.token1].adminBalance += adminShare1;
            accruedFees[votePool][pool.token1].projectBalance += projectShare1;
            emit FeesAccrued(votePool, pool.token1, adminShare1, projectShare1);
        }

        emit TradingFeesClaimed(votePool, msg.sender, pool.token0, claimed0, pool.token1, claimed1);
    }
    
    /// @notice Withdraw accrued fees for admin
    function withdrawAdminFees(address votePool, address token, address recipient) external nonReentrant {
        LockedPosition storage pool = lockedPools[votePool];
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
    function withdrawProjectFees(address votePool, address token, address recipient) external nonReentrant {
        LockedPosition storage pool = lockedPools[votePool];
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

    /// @notice Get pending trading fees for a vote pool (in position, not yet collected)
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
        LockedPosition storage pool = lockedPools[votePool];

        if (!pool.exists) {
            return (address(0), 0, address(0), 0);
        }

        token0 = pool.token0;
        token1 = pool.token1;

        // Get owed fees from position
        (
            ,,,,,,,
            ,  // liquidity
            ,  // feeGrowthInside0LastX128
            ,  // feeGrowthInside1LastX128
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = positionManager.positions(pool.positionId);
        
        amount0 = tokensOwed0;
        amount1 = tokensOwed1;
    }
    
    /// @notice Get accrued (already collected, awaiting withdrawal) fees for a vote pool
    function getAccruedFees(address votePool, address token) 
        external 
        view 
        returns (uint256 adminBalance, uint256 projectBalance) 
    {
        AccruedFees storage fees = accruedFees[votePool][token];
        return (fees.adminBalance, fees.projectBalance);
    }

    /// @notice Get fee shares for admin and project owner from pending fees
    function getPendingShares(address votePool)
        external
        view
        returns (uint256 adminShare0, uint256 adminShare1, uint256 projectShare0, uint256 projectShare1)
    {
        LockedPosition storage pool = lockedPools[votePool];

        if (!pool.exists) {
            return (0, 0, 0, 0);
        }

        (
            ,,,,,,,
            ,
            ,
            ,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        ) = positionManager.positions(pool.positionId);

        adminShare0 = (uint256(tokensOwed0) * ADMIN_FEE_BPS) / BPS_DENOMINATOR;
        adminShare1 = (uint256(tokensOwed1) * ADMIN_FEE_BPS) / BPS_DENOMINATOR;
        projectShare0 = uint256(tokensOwed0) - adminShare0;
        projectShare1 = uint256(tokensOwed1) - adminShare1;
    }

    /// @notice Get locked position info for a vote pool
    function getLockedPosition(address votePool) external view returns (LockedPosition memory info) {
        return lockedPools[votePool];
    }
    
    /// @notice Get locked LP info for a vote pool (legacy compatibility)
    /// @dev Returns a simplified view for backward compatibility
    function getLockedLP(address votePool) external view returns (
        address lpToken,
        address aerodromePool,
        address admin,
        address projectOwner,
        uint256 totalLP,
        bool exists
    ) {
        LockedPosition storage pool = lockedPools[votePool];
        return (
            address(positionManager),  // NFT contract as "LP token"
            address(0),                // No single pool address in CL
            pool.admin,
            pool.projectOwner,
            pool.positionId,           // Position ID as "amount"
            pool.exists
        );
    }

    /// @notice Get all vote pools with locked positions
    function getAllVotePools() external view returns (address[] memory) {
        return allVotePools;
    }

    /// @notice Get the count of vote pools with locked positions
    function getVotePoolCount() external view returns (uint256) {
        return allVotePools.length;
    }
}
