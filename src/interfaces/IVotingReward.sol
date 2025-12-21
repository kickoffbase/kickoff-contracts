// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IVotingReward
/// @notice Interface for Aerodrome's VotingReward contracts (FeesVotingReward, BribeVotingReward)
/// @dev Used to check and claim rewards earned by veAERO voters
interface IVotingReward {
    /// @notice Get the amount of rewards earned by a tokenId for a specific token
    /// @param token The reward token address
    /// @param tokenId The veAERO NFT token ID
    /// @return The amount of rewards earned
    function earned(address token, uint256 tokenId) external view returns (uint256);

    /// @notice Get all reward tokens for this reward contract
    /// @return Array of reward token addresses
    function rewards() external view returns (address[] memory);

    /// @notice Get the number of reward tokens
    /// @return The count of reward tokens
    function rewardsListLength() external view returns (uint256);

    /// @notice Get reward token at index
    /// @param index The index in the rewards list
    /// @return The reward token address
    function rewardsList(uint256 index) external view returns (address);

    /// @notice Claim rewards for a tokenId
    /// @param tokenId The veAERO NFT token ID
    /// @param tokens Array of token addresses to claim
    function getReward(uint256 tokenId, address[] calldata tokens) external;

    /// @notice Get the voter contract address
    /// @return The Voter contract address
    function voter() external view returns (address);

    /// @notice Get the voting escrow contract address
    /// @return The VotingEscrow contract address
    function ve() external view returns (address);

    /// @notice Check if address is a reward token
    /// @param token The token address to check
    /// @return True if token is a reward
    function isReward(address token) external view returns (bool);

    /// @notice Get balance of tokenId in this reward contract
    /// @param tokenId The veAERO NFT token ID
    /// @return The balance
    function balanceOf(uint256 tokenId) external view returns (uint256);

    /// @notice Get total supply of this reward contract
    /// @return The total supply
    function totalSupply() external view returns (uint256);
}

