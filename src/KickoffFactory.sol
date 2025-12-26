// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {KickoffVoteSalePool} from "./KickoffVoteSalePool.sol";
import {LPLocker} from "./LPLocker.sol";
import {IERC20} from "./interfaces/IERC20.sol";

/// @title KickoffFactory
/// @notice Factory contract for creating Vote-Sale pools for project launches
/// @dev Creates KickoffVoteSalePool instances and manages global settings
contract KickoffFactory {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error ZeroAmount();
    error NotOwner();
    error PoolAlreadyExists();
    error TransferFailed();
    error InsufficientTokensReceived();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event PoolCreated(
        address indexed pool,
        address indexed projectToken,
        address indexed admin,
        address projectOwner,
        uint256 totalAllocation
    );

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PendingOwnerSet(address indexed pendingOwner);

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Owner of the factory (protocol admin)
    address public owner;

    /// @notice Pending owner for two-step transfer
    address public pendingOwner;

    /// @notice LP Locker contract for permanent LP locking
    LPLocker public immutable lpLocker;

    /// @notice Aerodrome VotingEscrow contract
    address public immutable votingEscrow;

    /// @notice Aerodrome Voter contract
    address public immutable voter;

    /// @notice Aerodrome Router contract
    address public immutable router;

    /// @notice WETH contract
    address public immutable weth;

    /// @notice Array of all created pools
    address[] public allPools;

    /// @notice Mapping from project token to pool address
    mapping(address projectToken => address pool) public poolByToken;

    /// @notice Mapping to check if an address is a pool
    mapping(address => bool) public isPool;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new KickoffFactory
    /// @param _votingEscrow Aerodrome VotingEscrow (veAERO) address
    /// @param _voter Aerodrome Voter address
    /// @param _router Aerodrome Router address
    /// @param _weth WETH address
    constructor(address _votingEscrow, address _voter, address _router, address _weth) {
        if (_votingEscrow == address(0) || _voter == address(0) || _router == address(0) || _weth == address(0)) {
            revert ZeroAddress();
        }

        owner = msg.sender;
        votingEscrow = _votingEscrow;
        voter = _voter;
        router = _router;
        weth = _weth;

        // Deploy LPLocker
        lpLocker = new LPLocker();

        emit OwnershipTransferred(address(0), msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                            POOL CREATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new Vote-Sale pool for a project
    /// @param projectToken The project's ERC20 token address
    /// @param projectOwner The project owner address (receives 70% of trading fees)
    /// @param totalAllocation Total amount of project tokens (split 50/50: sale + liquidity)
    /// @param minVotingPower Minimum voting power required to lock veAERO NFT (0 = no minimum)
    /// @return pool The address of the created pool
    function createPool(
        address projectToken,
        address projectOwner,
        uint256 totalAllocation,
        uint256 minVotingPower
    ) external returns (address pool) {
        if (projectToken == address(0) || projectOwner == address(0)) {
            revert ZeroAddress();
        }
        if (totalAllocation == 0) {
            revert ZeroAmount();
        }
        if (poolByToken[projectToken] != address(0)) {
            revert PoolAlreadyExists();
        }

        // Deploy new pool
        // msg.sender becomes the admin (receives 30% of trading fees)
        pool = address(
            new KickoffVoteSalePool(
                projectToken,
                msg.sender, // admin
                projectOwner,
                totalAllocation,
                minVotingPower,
                address(lpLocker),
                votingEscrow,
                voter,
                router,
                weth
            )
        );

        // Transfer project tokens from admin to pool
        // Check balance before and after to handle fee-on-transfer tokens
        uint256 balanceBefore = IERC20(projectToken).balanceOf(pool);
        bool success = IERC20(projectToken).transferFrom(msg.sender, pool, totalAllocation);
        if (!success) revert TransferFailed();
        uint256 balanceAfter = IERC20(projectToken).balanceOf(pool);
        if (balanceAfter - balanceBefore != totalAllocation) revert InsufficientTokensReceived();

        // Register pool
        allPools.push(pool);
        poolByToken[projectToken] = pool;
        isPool[pool] = true;

        emit PoolCreated(pool, projectToken, msg.sender, projectOwner, totalAllocation);
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get all created pools
    /// @return Array of pool addresses
    function getAllPools() external view returns (address[] memory) {
        return allPools;
    }

    /// @notice Get the number of pools created
    /// @return The count of pools
    function poolCount() external view returns (uint256) {
        return allPools.length;
    }

    /*//////////////////////////////////////////////////////////////
                            OWNER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Set pending owner for two-step transfer
    /// @param newOwner The new pending owner address
    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        if (newOwner == address(0)) revert ZeroAddress();

        pendingOwner = newOwner;
        emit PendingOwnerSet(newOwner);
    }

    /// @notice Accept ownership transfer
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();

        address oldOwner = owner;
        owner = msg.sender;
        pendingOwner = address(0);

        emit OwnershipTransferred(oldOwner, msg.sender);
    }
}

