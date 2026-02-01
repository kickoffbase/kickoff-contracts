// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IKickoffVoteSalePoolReader
/// @notice Interface for reading data from KickoffVoteSalePool
interface IKickoffVoteSalePoolReader {
    function lockedTokenIds(uint256 index) external view returns (uint256);
    function getLockedTokenIds() external view returns (uint256[] memory);
    function getLockedTokenIdsLength() external view returns (uint256);
    function totalVotingPower() external view returns (uint256);
    function saleAllocation() external view returns (uint256);
    function participantCount() external view returns (uint256);
    function depositedToAutopilot(uint256 tokenId) external view returns (bool);
    
    struct UserInfo {
        uint256 totalVotingPower;
        bool hasClaimed;
    }
    function userInfo(address user) external view returns (uint256 totalVotingPower, bool hasClaimed);
    
    struct LockedNFT {
        address owner;
        uint256 votingPower;
        bool unlocked;
    }
    function lockedNFTs(uint256 tokenId) external view returns (address owner, uint256 votingPower, bool unlocked);
}

/// @title IAutopilotReader
/// @notice Interface for reading Autopilot data
interface IAutopilotReader {
    function getPendingRewards(address owner, uint256 lockId) external view returns (uint256);
    function rewards_token() external view returns (address);
}

/// @title KickoffPoolReader
/// @notice Read-only helper contract for KickoffVoteSalePool view functions
/// @dev Reduces VoteSalePool bytecode size by moving complex view logic here
/// @dev This contract has NO write permissions - purely reads public data
contract KickoffPoolReader {
    
    /// @notice Autopilot contract address on Base mainnet
    address public constant AUTOPILOT = 0x35cbd6982334e377e05F16DB14DcC1d191644D5c;

    /// @notice Default page size for paginated queries
    uint256 public constant DEFAULT_PAGE_SIZE = 100;

    /*//////////////////////////////////////////////////////////////
                         AUTOPILOT FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get pending USDC rewards from Autopilot for a specific NFT
    /// @param pool The KickoffVoteSalePool address
    /// @param tokenId The veAERO NFT token ID
    /// @return pendingRewards Amount of pending USDC rewards
    function getAutopilotPendingRewards(
        address pool,
        uint256 tokenId
    ) external view returns (uint256 pendingRewards) {
        IKickoffVoteSalePoolReader poolContract = IKickoffVoteSalePoolReader(pool);
        
        // Check if NFT is deposited to Autopilot
        if (!poolContract.depositedToAutopilot(tokenId)) {
            return 0;
        }
        
        try IAutopilotReader(AUTOPILOT).getPendingRewards(pool, tokenId) returns (uint256 amount) {
            pendingRewards = amount;
        } catch {}
    }

    /// @notice Get total pending USDC rewards from Autopilot (PAGINATED)
    /// @param pool The KickoffVoteSalePool address
    /// @param startIndex Starting index in lockedTokenIds array
    /// @param limit Maximum number of NFTs to check (0 = DEFAULT_PAGE_SIZE)
    /// @return totalPending Total pending USDC rewards for this page
    /// @return processedCount Number of NFTs processed in this page
    /// @return totalCount Total number of locked NFTs
    function getTotalAutopilotPendingRewardsPaginated(
        address pool,
        uint256 startIndex,
        uint256 limit
    ) external view returns (uint256 totalPending, uint256 processedCount, uint256 totalCount) {
        IKickoffVoteSalePoolReader poolContract = IKickoffVoteSalePoolReader(pool);
        totalCount = poolContract.getLockedTokenIdsLength();
        
        if (startIndex >= totalCount) {
            return (0, 0, totalCount);
        }
        
        if (limit == 0) limit = DEFAULT_PAGE_SIZE;
        
        uint256 endIndex = startIndex + limit;
        if (endIndex > totalCount) endIndex = totalCount;
        
        for (uint256 i = startIndex; i < endIndex; i++) {
            uint256 tokenId = poolContract.lockedTokenIds(i);
            
            if (poolContract.depositedToAutopilot(tokenId)) {
                try IAutopilotReader(AUTOPILOT).getPendingRewards(pool, tokenId) returns (uint256 amount) {
                    totalPending += amount;
                } catch {}
            }
        }
        
        processedCount = endIndex - startIndex;
    }

    /// @notice Get Autopilot rewards token address (USDC)
    /// @return rewardsToken The USDC token address
    function getAutopilotRewardsToken() external view returns (address rewardsToken) {
        try IAutopilotReader(AUTOPILOT).rewards_token() returns (address token) {
            rewardsToken = token;
        } catch {}
    }

    /*//////////////////////////////////////////////////////////////
                         HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get claimable project tokens for a user
    /// @param pool The KickoffVoteSalePool address
    /// @param user The user address
    /// @return amount The claimable amount
    function getClaimableTokens(address pool, address user) external view returns (uint256 amount) {
        IKickoffVoteSalePoolReader poolContract = IKickoffVoteSalePoolReader(pool);
        
        (uint256 userVotingPower, bool hasClaimed) = poolContract.userInfo(user);
        
        if (hasClaimed || userVotingPower == 0) return 0;
        
        uint256 totalVP = poolContract.totalVotingPower();
        if (totalVP == 0) return 0;
        
        uint256 saleAlloc = poolContract.saleAllocation();
        return (saleAlloc * userVotingPower) / totalVP;
    }

    /// @notice Get info about a locked NFT
    /// @param pool The KickoffVoteSalePool address
    /// @param tokenId The NFT token ID
    /// @return owner The original owner
    /// @return votingPower The voting power
    /// @return unlocked Whether it's been unlocked
    /// @return inAutopilot Whether it's deposited in Autopilot
    function getLockedNFTInfo(address pool, uint256 tokenId)
        external view returns (address owner, uint256 votingPower, bool unlocked, bool inAutopilot)
    {
        IKickoffVoteSalePoolReader poolContract = IKickoffVoteSalePoolReader(pool);
        (owner, votingPower, unlocked) = poolContract.lockedNFTs(tokenId);
        inAutopilot = poolContract.depositedToAutopilot(tokenId);
    }

    /// @notice Get pool statistics
    /// @param pool The KickoffVoteSalePool address
    /// @return totalVotingPower Total voting power locked
    /// @return participantCount Number of unique participants
    /// @return nftCount Number of locked NFTs
    /// @return saleAllocation Total tokens for sale
    function getPoolStats(address pool) external view returns (
        uint256 totalVotingPower,
        uint256 participantCount,
        uint256 nftCount,
        uint256 saleAllocation
    ) {
        IKickoffVoteSalePoolReader poolContract = IKickoffVoteSalePoolReader(pool);
        totalVotingPower = poolContract.totalVotingPower();
        participantCount = poolContract.participantCount();
        nftCount = poolContract.getLockedTokenIdsLength();
        saleAllocation = poolContract.saleAllocation();
    }

    /// @notice Get locked NFT IDs with Autopilot status (PAGINATED)
    /// @param pool The KickoffVoteSalePool address
    /// @param startIndex Starting index in lockedTokenIds array
    /// @param limit Maximum number of NFTs to return (0 = DEFAULT_PAGE_SIZE)
    /// @return tokenIds Array of locked token IDs for this page
    /// @return inAutopilot Array of booleans indicating Autopilot deposit status
    /// @return totalCount Total number of locked NFTs
    function getLockedNFTsWithStatusPaginated(
        address pool,
        uint256 startIndex,
        uint256 limit
    ) external view returns (
        uint256[] memory tokenIds,
        bool[] memory inAutopilot,
        uint256 totalCount
    ) {
        IKickoffVoteSalePoolReader poolContract = IKickoffVoteSalePoolReader(pool);
        totalCount = poolContract.getLockedTokenIdsLength();
        
        if (startIndex >= totalCount) {
            return (new uint256[](0), new bool[](0), totalCount);
        }
        
        if (limit == 0) limit = DEFAULT_PAGE_SIZE;
        
        uint256 endIndex = startIndex + limit;
        if (endIndex > totalCount) endIndex = totalCount;
        
        uint256 resultLength = endIndex - startIndex;
        tokenIds = new uint256[](resultLength);
        inAutopilot = new bool[](resultLength);
        
        for (uint256 i = 0; i < resultLength; i++) {
            uint256 tokenId = poolContract.lockedTokenIds(startIndex + i);
            tokenIds[i] = tokenId;
            inAutopilot[i] = poolContract.depositedToAutopilot(tokenId);
        }
    }

    /// @notice Get multiple NFT infos in a single call (for specific token IDs)
    /// @param pool The KickoffVoteSalePool address
    /// @param tokenIds Array of token IDs to query
    /// @return owners Array of owners
    /// @return votingPowers Array of voting powers
    /// @return unlockeds Array of unlocked flags
    /// @return inAutopilots Array of Autopilot deposit flags
    function getMultipleNFTInfos(
        address pool,
        uint256[] calldata tokenIds
    ) external view returns (
        address[] memory owners,
        uint256[] memory votingPowers,
        bool[] memory unlockeds,
        bool[] memory inAutopilots
    ) {
        IKickoffVoteSalePoolReader poolContract = IKickoffVoteSalePoolReader(pool);
        uint256 length = tokenIds.length;
        
        owners = new address[](length);
        votingPowers = new uint256[](length);
        unlockeds = new bool[](length);
        inAutopilots = new bool[](length);
        
        for (uint256 i = 0; i < length; i++) {
            uint256 tokenId = tokenIds[i];
            (owners[i], votingPowers[i], unlockeds[i]) = poolContract.lockedNFTs(tokenId);
            inAutopilots[i] = poolContract.depositedToAutopilot(tokenId);
        }
    }
}
