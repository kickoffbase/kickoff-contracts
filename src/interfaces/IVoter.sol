// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IVoter
/// @notice Interface for Aerodrome's Voter contract
interface IVoter {
    /// @notice Vote for pools with voting power from an NFT
    /// @param tokenId The veAERO NFT token ID
    /// @param poolVote Array of pool addresses to vote for
    /// @param weights Array of weights for each pool
    function vote(uint256 tokenId, address[] calldata poolVote, uint256[] calldata weights) external;

    /// @notice Reset votes for an NFT
    /// @param tokenId The veAERO NFT token ID
    function reset(uint256 tokenId) external;

    /// @notice Get the timestamp of last vote for an NFT
    /// @param tokenId The veAERO NFT token ID
    /// @return The timestamp of last vote
    function lastVoted(uint256 tokenId) external view returns (uint256);

    /// @notice Claim bribes for an NFT
    /// @param bribes Array of bribe contract addresses
    /// @param tokens Array of token arrays to claim for each bribe
    /// @param tokenId The veAERO NFT token ID
    function claimBribes(address[] calldata bribes, address[][] calldata tokens, uint256 tokenId) external;

    /// @notice Claim fees for an NFT
    /// @param fees Array of fee contract addresses
    /// @param tokens Array of token arrays to claim for each fee
    /// @param tokenId The veAERO NFT token ID
    function claimFees(address[] calldata fees, address[][] calldata tokens, uint256 tokenId) external;

    /// @notice Get the gauge for a pool
    /// @param pool The pool address
    /// @return The gauge address
    function gauges(address pool) external view returns (address);

    /// @notice Get the internal bribe contract for a gauge (legacy name)
    /// @param gauge The gauge address
    /// @return The internal bribe address
    function internal_bribes(address gauge) external view returns (address);

    /// @notice Get the external bribe contract for a gauge (legacy name)
    /// @param gauge The gauge address
    /// @return The external bribe address
    function external_bribes(address gauge) external view returns (address);

    /// @notice Get the fees reward contract for a gauge (Aerodrome V2)
    /// @param gauge The gauge address
    /// @return The fees reward contract address
    function gaugeToFees(address gauge) external view returns (address);

    /// @notice Get the bribe reward contract for a gauge (Aerodrome V2)
    /// @param gauge The gauge address
    /// @return The bribe reward contract address
    function gaugeToBribe(address gauge) external view returns (address);

    /// @notice Get the pool for a gauge
    /// @param gauge The gauge address
    /// @return The pool address
    function poolForGauge(address gauge) external view returns (address);

    /// @notice Check if a gauge is alive
    /// @param gauge The gauge address
    /// @return True if gauge is alive
    function isAlive(address gauge) external view returns (bool);

    /// @notice Check if a token is whitelisted
    /// @param token The token address
    /// @return True if token is whitelisted
    function isWhitelistedToken(address token) external view returns (bool);

    /// @notice Get the voting escrow contract address
    /// @return The VotingEscrow address
    function ve() external view returns (address);

    /// @notice Get votes for a pool from an NFT
    /// @param tokenId The veAERO NFT token ID
    /// @param pool The pool address
    /// @return The vote weight
    function votes(uint256 tokenId, address pool) external view returns (uint256);

    /// @notice Get total weight of votes
    /// @return The total weight
    function totalWeight() external view returns (uint256);

    /// @notice Get weight of votes for a pool
    /// @param pool The pool address
    /// @return The pool weight
    function weights(address pool) external view returns (uint256);

    /// @notice Distribute emissions to gauges
    /// @param gauges Array of gauge addresses
    function distribute(address[] calldata gauges) external;

    /// @notice Poke votes for an NFT (update weights without changing vote)
    /// @param tokenId The veAERO NFT token ID
    function poke(uint256 tokenId) external;
}

