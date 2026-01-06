// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {ProjectToken} from "./ProjectToken.sol";
import {ITokenVesting} from "./interfaces/ITokenVesting.sol";
import {IERC20} from "./interfaces/IERC20.sol";

/// @title ProjectTokenFactory
/// @notice Factory for creating project tokens with customizable tokenomics
/// @dev Creates ProjectToken instances and registers vesting schedules
contract ProjectTokenFactory {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error ZeroAmount();
    error NotOwner();
    error InvalidAllocation();
    error AllocationMismatch();
    error TransferFailed();
    error TokenAlreadyExists();
    error TooManyAllocations();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event TokenCreated(
        address indexed token,
        string name,
        string symbol,
        uint256 totalSupply,
        address indexed creator
    );

    event AllocationDistributed(
        address indexed token,
        address indexed recipient,
        address indexed lockOwner,
        uint256 tgeAmount,
        uint256 vestingAmount,
        uint256 lockId
    );

    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PendingOwnerSet(address indexed pendingOwner);

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Token allocation configuration
    /// @param recipient Address to receive TGE tokens immediately
    /// @param lockOwner Address that owns the vesting lock (can claim vested tokens)
    /// @param amount Total token amount for this allocation
    /// @param tgePercent Percentage unlocked at TGE (basis points, 10000 = 100%)
    /// @param cliffDuration Cliff duration in seconds before vesting starts
    /// @param vestingDuration Linear vesting duration in seconds
    struct TokenAllocation {
        address recipient;
        address lockOwner;
        uint256 amount;
        uint16 tgePercent;
        uint32 cliffDuration;
        uint32 vestingDuration;
    }

    /// @notice Created token info
    struct TokenInfo {
        address token;
        string name;
        string symbol;
        uint256 totalSupply;
        address creator;
        uint256 createdAt;
    }

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Owner of the factory
    address public owner;

    /// @notice Pending owner for two-step transfer
    address public pendingOwner;

    /// @notice TokenVesting contract
    ITokenVesting public immutable vesting;

    /// @notice Array of all created tokens
    address[] public allTokens;

    /// @notice Mapping of token address to info
    mapping(address => TokenInfo) public tokenInfo;

    /// @notice Mapping to check if an address is a created token
    mapping(address => bool) public isToken;

    /// @notice Mapping of creator to their tokens
    mapping(address => address[]) public creatorTokens;

    /// @notice Basis points denominator
    uint16 public constant BPS_DENOMINATOR = 10000;

    /// @notice Maximum allocations per token (gas limit protection)
    uint256 public constant MAX_ALLOCATIONS = 50;

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier onlyOwner() {
        if (msg.sender != owner) revert NotOwner();
        _;
    }

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new ProjectTokenFactory
    /// @param _vesting TokenVesting contract address
    constructor(address _vesting) {
        if (_vesting == address(0)) revert ZeroAddress();

        owner = msg.sender;
        vesting = ITokenVesting(_vesting);

        emit OwnershipTransferred(address(0), msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                            TOKEN CREATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new project token with tokenomics
    /// @param name Token name
    /// @param symbol Token symbol
    /// @param totalSupply Total supply to mint
    /// @param allocations Array of token allocations
    /// @return token The address of the created token
    function createToken(
        string calldata name,
        string calldata symbol,
        uint256 totalSupply,
        TokenAllocation[] calldata allocations
    ) external returns (address token) {
        if (totalSupply == 0) revert ZeroAmount();
        if (allocations.length == 0) revert InvalidAllocation();
        if (allocations.length > MAX_ALLOCATIONS) revert TooManyAllocations();

        // Validate allocations sum to totalSupply
        uint256 allocationSum = 0;
        for (uint256 i = 0; i < allocations.length;) {
            TokenAllocation calldata alloc = allocations[i];
            
            if (alloc.amount == 0) revert ZeroAmount();
            if (alloc.recipient == address(0)) revert ZeroAddress();
            if (alloc.tgePercent > BPS_DENOMINATOR) revert InvalidAllocation();
            
            // If there's vesting (not 100% TGE), lockOwner must be set
            if (alloc.tgePercent < BPS_DENOMINATOR && alloc.lockOwner == address(0)) {
                revert ZeroAddress();
            }
            
            allocationSum += alloc.amount;
            unchecked { ++i; }
        }

        if (allocationSum != totalSupply) revert AllocationMismatch();

        // Deploy new token - mint all to this factory first
        token = address(new ProjectToken(name, symbol, totalSupply, address(this)));

        // Register token
        allTokens.push(token);
        isToken[token] = true;
        creatorTokens[msg.sender].push(token);
        
        tokenInfo[token] = TokenInfo({
            token: token,
            name: name,
            symbol: symbol,
            totalSupply: totalSupply,
            creator: msg.sender,
            createdAt: block.timestamp
        });

        emit TokenCreated(token, name, symbol, totalSupply, msg.sender);

        // Distribute allocations
        for (uint256 i = 0; i < allocations.length;) {
            _distributeAllocation(token, allocations[i]);
            unchecked { ++i; }
        }
    }

    /// @notice Internal function to distribute a single allocation
    function _distributeAllocation(address token, TokenAllocation calldata alloc) internal {
        uint256 tgeAmount = (alloc.amount * alloc.tgePercent) / BPS_DENOMINATOR;
        uint256 vestingAmount = alloc.amount - tgeAmount;
        uint256 lockId = 0;

        // Transfer TGE amount to recipient
        if (tgeAmount > 0) {
            bool success = IERC20(token).transfer(alloc.recipient, tgeAmount);
            if (!success) revert TransferFailed();
        }

        // Create vesting lock for remaining amount
        if (vestingAmount > 0) {
            // Transfer tokens to vesting contract
            bool success = IERC20(token).transfer(address(vesting), vestingAmount);
            if (!success) revert TransferFailed();

            // Create lock
            lockId = vesting.createLock(
                token,
                alloc.lockOwner,
                vestingAmount,
                alloc.cliffDuration,
                alloc.vestingDuration
            );
        }

        emit AllocationDistributed(
            token,
            alloc.recipient,
            alloc.lockOwner,
            tgeAmount,
            vestingAmount,
            lockId
        );
    }

    /*//////////////////////////////////////////////////////////////
                              VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get all created tokens
    /// @return Array of token addresses
    function getAllTokens() external view returns (address[] memory) {
        return allTokens;
    }

    /// @notice Get the number of tokens created
    /// @return The count of tokens
    function tokenCount() external view returns (uint256) {
        return allTokens.length;
    }

    /// @notice Get all tokens created by an address
    /// @param creator The creator address
    /// @return Array of token addresses
    function getCreatorTokens(address creator) external view returns (address[] memory) {
        return creatorTokens[creator];
    }

    /// @notice Get full token info
    /// @param token The token address
    /// @return info The token info struct
    function getTokenInfo(address token) external view returns (TokenInfo memory info) {
        return tokenInfo[token];
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

