// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title EpochLib
/// @notice Library for working with Aerodrome epochs
/// @dev Aerodrome epochs are weekly, starting Thursday 00:00 UTC
///      Unix epoch (timestamp 0) was Thursday Jan 1, 1970, so week boundaries
///      naturally align with Thursday 00:00 UTC. This matches Aerodrome's
///      epoch calculation: epochStart = timestamp - (timestamp % WEEK)
library EpochLib {
    /// @notice Duration of one epoch (1 week = 604800 seconds)
    /// @dev Matches Aerodrome's WEEK constant
    uint256 internal constant EPOCH_DURATION = 1 weeks;

    /// @notice Get the current epoch number
    /// @return The current epoch (weeks since Unix epoch, Thursday-aligned)
    function currentEpoch() internal view returns (uint256) {
        return block.timestamp / EPOCH_DURATION;
    }

    /// @notice Get the epoch for a given timestamp
    /// @param timestamp The timestamp to convert
    /// @return The epoch number
    function epochAt(uint256 timestamp) internal pure returns (uint256) {
        return timestamp / EPOCH_DURATION;
    }

    /// @notice Get the start timestamp of the current epoch (Thursday 00:00 UTC)
    /// @dev Matches Aerodrome's _epochStart(): timestamp - (timestamp % WEEK)
    /// @return The start timestamp
    function currentEpochStart() internal view returns (uint256) {
        unchecked {
            return block.timestamp - (block.timestamp % EPOCH_DURATION);
        }
    }

    /// @notice Get the start timestamp for any given timestamp's epoch
    /// @param timestamp The timestamp to get epoch start for
    /// @return The epoch start timestamp
    function epochStartAt(uint256 timestamp) internal pure returns (uint256) {
        unchecked {
            return timestamp - (timestamp % EPOCH_DURATION);
        }
    }

    /// @notice Get the end timestamp of the current epoch
    /// @return The end timestamp
    function currentEpochEnd() internal view returns (uint256) {
        return currentEpochStart() + EPOCH_DURATION;
    }

    /// @notice Get the start timestamp of a given epoch
    /// @param epoch The epoch number
    /// @return The start timestamp
    function epochStart(uint256 epoch) internal pure returns (uint256) {
        return epoch * EPOCH_DURATION;
    }

    /// @notice Get the end timestamp of a given epoch
    /// @param epoch The epoch number
    /// @return The end timestamp
    function epochEnd(uint256 epoch) internal pure returns (uint256) {
        return (epoch + 1) * EPOCH_DURATION;
    }

    /// @notice Check if an NFT has already voted in the current epoch
    /// @dev Matches Aerodrome Voter's check: lastVoted[tokenId] > _bribeStart()
    ///      where _bribeStart() = epochStart(block.timestamp)
    /// @param lastVotedTimestamp The timestamp of the last vote
    /// @return True if already voted this epoch
    function hasVotedThisEpoch(uint256 lastVotedTimestamp) internal view returns (bool) {
        // Using > (not >=) to match Aerodrome's exact logic
        // NFT can vote again if lastVoted == epochStart (edge case)
        return lastVotedTimestamp > currentEpochStart();
    }

    /// @notice Get time remaining in current epoch
    /// @return Seconds remaining
    function timeUntilEpochEnd() internal view returns (uint256) {
        return currentEpochEnd() - block.timestamp;
    }

    /// @notice Check if we're in the voting window (e.g., last 6 hours before epoch end)
    /// @param windowDuration Duration of voting window before epoch end
    /// @return True if in voting window
    function isInVotingWindow(uint256 windowDuration) internal view returns (bool) {
        return timeUntilEpochEnd() <= windowDuration;
    }

    /// @notice Get the next epoch number
    /// @return The next epoch
    function nextEpoch() internal view returns (uint256) {
        return currentEpoch() + 1;
    }

    /// @notice Check if a timestamp is in a past epoch
    /// @param timestamp The timestamp to check
    /// @return True if in a past epoch
    function isInPastEpoch(uint256 timestamp) internal view returns (bool) {
        return epochAt(timestamp) < currentEpoch();
    }
}

