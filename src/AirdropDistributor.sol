// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {MerkleProof} from "@openzeppelin/contracts/utils/cryptography/MerkleProof.sol";

/// @notice Minimal interface to read VoteSalePool state
interface IVoteSalePool {
    enum PoolState { Inactive, Active, Voting, Finalizing, Completed, Cancelled }
    function state() external view returns (PoolState);
}

/// @notice Minimal interface to validate pool existence
interface IKickoffFactory {
    function poolByToken(address token) external view returns (address);
}

/// @notice Minimal interface to validate token creator
interface IProjectTokenFactory {
    function tokenInfo(address token) external view returns (
        address token_,
        string memory name,
        string memory symbol,
        uint256 totalSupply,
        address creator,
        uint256 createdAt
    );
}

/// @title AirdropDistributor
/// @notice Merkle-tree-based airdrop distribution gated by VoteSalePool completion
/// @dev One airdrop per project token. Claims unlock when the linked VoteSalePool reaches Completed state.
contract AirdropDistributor {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error ZeroAddress();
    error ZeroAmount();
    error NotOwner();
    error NotProjectOwner();
    error AirdropAlreadyExists();
    error AirdropNotFound();
    error AirdropNotActive();
    error AlreadyClaimed();
    error InvalidProof();
    error PoolNotCompleted();
    error PoolNotLinked();
    error ClaimsAlreadyStarted();
    error InsufficientBalance();
    error WithdrawNotRequested();
    error WithdrawNotApproved();
    error WithdrawAlreadyPending();
    error TransferFailed();
    error NotTokenCreator();
    error Reentrancy();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event AirdropCreated(address indexed token, address indexed projectOwner, address indexed voteSalePool, bytes32 merkleRoot, string ipfsHash);
    event MerkleRootUpdated(address indexed token, bytes32 oldRoot, bytes32 newRoot, string ipfsHash);
    event Claimed(address indexed token, address indexed recipient, uint256 amount);
    event WithdrawRequested(address indexed token, address indexed to, uint256 amount);
    event WithdrawApproved(address indexed token);
    event WithdrawExecuted(address indexed token, address indexed to, uint256 amount);
    event WithdrawCancelled(address indexed token);
    event AirdropDeactivated(address indexed token);
    event OwnershipTransferred(address indexed previousOwner, address indexed newOwner);
    event PendingOwnerSet(address indexed pendingOwner);

    /*//////////////////////////////////////////////////////////////
                                 STRUCTS
    //////////////////////////////////////////////////////////////*/

    struct AirdropConfig {
        address projectOwner;
        address voteSalePool;
        bytes32 merkleRoot;
        string ipfsHash;
        uint256 totalAllocation;
        uint256 totalClaimed;
        bool active;
    }

    struct WithdrawRequest {
        address to;
        uint256 amount;
        bool approved;
        bool pending;
    }

    /*//////////////////////////////////////////////////////////////
                                 STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice Protocol admin (can approve withdrawals)
    address public owner;

    /// @notice Pending owner for two-step transfer
    address public pendingOwner;

    /// @notice KickoffFactory for pool validation
    IKickoffFactory public immutable kickoffFactory;

    /// @notice ProjectTokenFactory for creator validation
    IProjectTokenFactory public immutable projectTokenFactory;

    /// @notice Reentrancy lock (1 = unlocked, 2 = locked)
    uint256 private _locked = 1;

    /// @notice Per-token airdrop configuration
    mapping(address => AirdropConfig) public airdrops;

    /// @notice Per-token per-user claimed status
    mapping(address => mapping(address => bool)) public claimed;

    /// @notice Per-token withdrawal requests
    mapping(address => WithdrawRequest) public withdrawRequests;

    /*//////////////////////////////////////////////////////////////
                              CONSTRUCTOR
    //////////////////////////////////////////////////////////////*/

    /// @param _kickoffFactory KickoffFactory address for pool validation
    /// @param _projectTokenFactory ProjectTokenFactory address for creator validation
    constructor(address _kickoffFactory, address _projectTokenFactory) {
        if (_kickoffFactory == address(0) || _projectTokenFactory == address(0)) revert ZeroAddress();
        owner = msg.sender;
        kickoffFactory = IKickoffFactory(_kickoffFactory);
        projectTokenFactory = IProjectTokenFactory(_projectTokenFactory);
        emit OwnershipTransferred(address(0), msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                              MODIFIERS
    //////////////////////////////////////////////////////////////*/

    modifier nonReentrant() {
        if (_locked == 2) revert Reentrancy();
        _locked = 2;
        _;
        _locked = 1;
    }

    /*//////////////////////////////////////////////////////////////
                          AIRDROP MANAGEMENT
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a new airdrop for a project token
    /// @param token The project token address (tokens must already be on this contract)
    /// @param voteSalePool The linked VoteSalePool address (claims gated by Completed state)
    /// @param merkleRoot The Merkle root of all (recipient, amount) pairs
    /// @param totalAllocation Total tokens allocated for this airdrop
    /// @param ipfsHash IPFS CID of the full allocation list
    function createAirdrop(
        address token,
        address voteSalePool,
        bytes32 merkleRoot,
        uint256 totalAllocation,
        string calldata ipfsHash
    ) external {
        if (token == address(0) || voteSalePool == address(0)) revert ZeroAddress();
        if (totalAllocation == 0) revert ZeroAmount();
        if (merkleRoot == bytes32(0)) revert ZeroAmount();
        if (airdrops[token].active) revert AirdropAlreadyExists();

        // Validate caller is the token creator from ProjectTokenFactory
        (,,,,address creator,) = projectTokenFactory.tokenInfo(token);
        if (creator == address(0) || creator != msg.sender) revert NotTokenCreator();

        // Validate pool exists in KickoffFactory for this token
        address registeredPool = kickoffFactory.poolByToken(token);
        if (registeredPool != voteSalePool) revert PoolNotLinked();

        // Validate this contract holds enough tokens
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (balance < totalAllocation) revert InsufficientBalance();

        airdrops[token] = AirdropConfig({
            projectOwner: msg.sender,
            voteSalePool: voteSalePool,
            merkleRoot: merkleRoot,
            ipfsHash: ipfsHash,
            totalAllocation: totalAllocation,
            totalClaimed: 0,
            active: true
        });

        emit AirdropCreated(token, msg.sender, voteSalePool, merkleRoot, ipfsHash);
    }

    /// @notice Update Merkle root before claims start (fix mistakes)
    /// @param token The project token address
    /// @param newRoot The new Merkle root
    /// @param newIpfsHash Updated IPFS CID
    function updateMerkleRoot(address token, bytes32 newRoot, string calldata newIpfsHash) external {
        AirdropConfig storage config = airdrops[token];
        if (!config.active) revert AirdropNotFound();
        if (msg.sender != config.projectOwner) revert NotProjectOwner();
        if (newRoot == bytes32(0)) revert ZeroAmount();

        // Only allow updates before any claims (pool not yet Completed)
        if (config.totalClaimed > 0) revert ClaimsAlreadyStarted();
        IVoteSalePool.PoolState poolState = IVoteSalePool(config.voteSalePool).state();
        if (poolState == IVoteSalePool.PoolState.Completed) revert ClaimsAlreadyStarted();

        bytes32 oldRoot = config.merkleRoot;
        config.merkleRoot = newRoot;
        config.ipfsHash = newIpfsHash;

        emit MerkleRootUpdated(token, oldRoot, newRoot, newIpfsHash);
    }

    /*//////////////////////////////////////////////////////////////
                              CLAIM
    //////////////////////////////////////////////////////////////*/

    /// @notice Claim airdrop tokens using a Merkle proof
    /// @param token The project token address
    /// @param amount The allocated amount for the caller
    /// @param merkleProof The Merkle proof for (msg.sender, amount)
    function claim(address token, uint256 amount, bytes32[] calldata merkleProof) external nonReentrant {
        AirdropConfig storage config = airdrops[token];
        if (!config.active) revert AirdropNotActive();
        if (claimed[token][msg.sender]) revert AlreadyClaimed();

        // Gate: pool must be Completed
        IVoteSalePool.PoolState poolState = IVoteSalePool(config.voteSalePool).state();
        if (poolState != IVoteSalePool.PoolState.Completed) revert PoolNotCompleted();

        // Verify Merkle proof (double-hash leaf for OZ StandardMerkleTree compatibility)
        bytes32 leaf = keccak256(bytes.concat(keccak256(abi.encode(msg.sender, amount))));
        if (!MerkleProof.verify(merkleProof, config.merkleRoot, leaf)) revert InvalidProof();

        claimed[token][msg.sender] = true;
        config.totalClaimed += amount;

        _safeTransfer(token, msg.sender, amount);

        emit Claimed(token, msg.sender, amount);
    }

    /*//////////////////////////////////////////////////////////////
                      2-STEP WITHDRAWAL
    //////////////////////////////////////////////////////////////*/

    /// @notice Request withdrawal of project tokens (step 1 — by project owner)
    /// @param token The project token address
    /// @param to Recipient address
    /// @param amount Amount to withdraw
    function requestWithdraw(address token, address to, uint256 amount) external {
        AirdropConfig storage config = airdrops[token];
        if (!config.active) revert AirdropNotFound();
        if (msg.sender != config.projectOwner) revert NotProjectOwner();
        if (to == address(0)) revert ZeroAddress();
        if (amount == 0) revert ZeroAmount();
        if (withdrawRequests[token].pending) revert WithdrawAlreadyPending();

        uint256 balance = IERC20(token).balanceOf(address(this));
        if (amount > balance) revert InsufficientBalance();

        withdrawRequests[token] = WithdrawRequest({
            to: to,
            amount: amount,
            approved: false,
            pending: true
        });

        emit WithdrawRequested(token, to, amount);
    }

    /// @notice Approve a pending withdrawal (step 2 — by protocol admin)
    /// @param token The project token address
    function approveWithdraw(address token) external {
        if (msg.sender != owner) revert NotOwner();
        WithdrawRequest storage req = withdrawRequests[token];
        if (!req.pending) revert WithdrawNotRequested();

        req.approved = true;

        emit WithdrawApproved(token);
    }

    /// @notice Execute an approved withdrawal (step 3 — by project owner)
    /// @param token The project token address
    function executeWithdraw(address token) external nonReentrant {
        AirdropConfig storage config = airdrops[token];
        if (msg.sender != config.projectOwner) revert NotProjectOwner();

        WithdrawRequest storage req = withdrawRequests[token];
        if (!req.pending) revert WithdrawNotRequested();
        if (!req.approved) revert WithdrawNotApproved();

        address to = req.to;
        uint256 amount = req.amount;

        // Verify balance is still sufficient (may have decreased since request due to claims)
        uint256 balance = IERC20(token).balanceOf(address(this));
        if (amount > balance) revert InsufficientBalance();

        // Clear request before transfer (CEI)
        delete withdrawRequests[token];

        _safeTransfer(token, to, amount);

        emit WithdrawExecuted(token, to, amount);
    }

    /// @notice Cancel a pending withdrawal request (by project owner)
    /// @param token The project token address
    function cancelWithdraw(address token) external {
        AirdropConfig storage config = airdrops[token];
        if (msg.sender != config.projectOwner) revert NotProjectOwner();

        WithdrawRequest storage req = withdrawRequests[token];
        if (!req.pending) revert WithdrawNotRequested();

        delete withdrawRequests[token];

        emit WithdrawCancelled(token);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Check if an address has claimed for a specific token
    function hasClaimed(address token, address user) external view returns (bool) {
        return claimed[token][user];
    }

    /// @notice Get full airdrop config for a token
    function getAirdrop(address token) external view returns (AirdropConfig memory) {
        return airdrops[token];
    }

    /// @notice Get withdrawal request for a token
    function getWithdrawRequest(address token) external view returns (WithdrawRequest memory) {
        return withdrawRequests[token];
    }

    /// @notice Check if claims are open for a token (airdrop active + pool completed)
    function claimsOpen(address token) external view returns (bool) {
        AirdropConfig storage config = airdrops[token];
        if (!config.active) return false;
        IVoteSalePool.PoolState poolState = IVoteSalePool(config.voteSalePool).state();
        return poolState == IVoteSalePool.PoolState.Completed;
    }

    /*//////////////////////////////////////////////////////////////
                          OWNER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Transfer ownership (two-step)
    function transferOwnership(address newOwner) external {
        if (msg.sender != owner) revert NotOwner();
        if (newOwner == address(0)) revert ZeroAddress();
        pendingOwner = newOwner;
        emit PendingOwnerSet(newOwner);
    }

    /// @notice Accept ownership
    function acceptOwnership() external {
        if (msg.sender != pendingOwner) revert NotOwner();
        address oldOwner = owner;
        owner = msg.sender;
        pendingOwner = address(0);
        emit OwnershipTransferred(oldOwner, msg.sender);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _safeTransfer(address token, address to, uint256 amount) internal {
        (bool success, bytes memory data) = token.call(
            abi.encodeWithSelector(IERC20.transfer.selector, to, amount)
        );
        if (!success || (data.length > 0 && !abi.decode(data, (bool)))) {
            revert TransferFailed();
        }
    }
}
