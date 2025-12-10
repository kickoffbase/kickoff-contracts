// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title MockVoter
/// @notice Mock Aerodrome Voter for testing
contract MockVoter {
    mapping(uint256 => uint256) public lastVoted;
    mapping(address => address) public gauges;
    mapping(address => address) public internal_bribes;
    mapping(address => address) public external_bribes;
    mapping(address => address) public poolForGauge;
    mapping(address => bool) public isAlive;
    mapping(address => bool) public isWhitelistedToken;
    mapping(uint256 => mapping(address => uint256)) public votes;

    address public ve;
    uint256 public totalWeight;
    mapping(address => uint256) public weights;

    constructor(address _ve) {
        ve = _ve;
    }

    function vote(uint256 tokenId, address[] calldata poolVote, uint256[] calldata _weights) external {
        lastVoted[tokenId] = block.timestamp;

        for (uint256 i = 0; i < poolVote.length; i++) {
            votes[tokenId][poolVote[i]] = _weights[i];
            weights[poolVote[i]] += _weights[i];
            totalWeight += _weights[i];
        }
    }

    function reset(uint256 tokenId) external {
        lastVoted[tokenId] = 0;
    }

    function claimBribes(address[] calldata, address[][] calldata, uint256) external {
        // Mock implementation - no actual token transfers
    }

    function claimFees(address[] calldata, address[][] calldata, uint256) external {
        // Mock implementation - no actual token transfers
    }

    function poke(uint256 tokenId) external {
        lastVoted[tokenId] = block.timestamp;
    }

    function distribute(address[] calldata) external {
        // Mock implementation
    }

    // Setup functions for testing
    function setGauge(address pool, address gauge) external {
        gauges[pool] = gauge;
        poolForGauge[gauge] = pool;
        isAlive[gauge] = true;
    }

    function setBribes(address gauge, address internal_, address external_) external {
        internal_bribes[gauge] = internal_;
        external_bribes[gauge] = external_;
    }

    function setLastVoted(uint256 tokenId, uint256 timestamp) external {
        lastVoted[tokenId] = timestamp;
    }

    function setWhitelistedToken(address token, bool whitelisted) external {
        isWhitelistedToken[token] = whitelisted;
    }
}

