// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IVoter} from "./interfaces/IVoter.sol";
import {IVotingReward} from "./interfaces/IVotingReward.sol";

/// @title IKickoffVoteSalePoolReader
/// @notice Interface for reading data from KickoffVoteSalePool
interface IKickoffVoteSalePoolReader {
    function gauge() external view returns (address);
    function voter() external view returns (IVoter);
    function lockedTokenIds(uint256 index) external view returns (uint256);
    function getLockedTokenIds() external view returns (uint256[] memory);
    function totalVotingPower() external view returns (uint256);
    function saleAllocation() external view returns (uint256);
    
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

/// @title KickoffPoolReader
/// @notice Read-only helper contract for KickoffVoteSalePool view functions
/// @dev Reduces VoteSalePool bytecode size by moving complex view logic here
/// @dev This contract has NO write permissions - purely reads public data
contract KickoffPoolReader {
    
    /*//////////////////////////////////////////////////////////////
                          REWARD FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get pending rewards for a specific NFT
    /// @param pool The KickoffVoteSalePool address
    /// @param tokenId The veAERO NFT token ID
    /// @param rewardTokens Array of reward token addresses to check
    /// @return feesEarned Array of earned amounts from fees (LP trading fees)
    /// @return bribesEarned Array of earned amounts from bribes (external)
    function getPendingRewards(
        address pool,
        uint256 tokenId, 
        address[] calldata rewardTokens
    ) external view returns (uint256[] memory feesEarned, uint256[] memory bribesEarned) {
        feesEarned = new uint256[](rewardTokens.length);
        bribesEarned = new uint256[](rewardTokens.length);
        
        IKickoffVoteSalePoolReader poolContract = IKickoffVoteSalePoolReader(pool);
        address gauge = poolContract.gauge();
        
        if (gauge == address(0)) return (feesEarned, bribesEarned);
        
        IVoter voter = poolContract.voter();
        
        address feesReward;
        address bribeReward;
        
        try voter.gaugeToFees(gauge) returns (address _fees) {
            feesReward = _fees;
        } catch {}
        
        try voter.gaugeToBribe(gauge) returns (address _bribe) {
            bribeReward = _bribe;
        } catch {}
        
        for (uint256 i = 0; i < rewardTokens.length; i++) {
            if (feesReward != address(0)) {
                try IVotingReward(feesReward).earned(rewardTokens[i], tokenId) returns (uint256 amount) {
                    feesEarned[i] = amount;
                } catch {}
            }
            if (bribeReward != address(0)) {
                try IVotingReward(bribeReward).earned(rewardTokens[i], tokenId) returns (uint256 amount) {
                    bribesEarned[i] = amount;
                } catch {}
            }
        }
    }

    /// @notice Get reward contract addresses for the pool's gauge
    /// @param pool The KickoffVoteSalePool address
    /// @return feesReward The fees reward contract (LP trading fees)
    /// @return bribeReward The bribe reward contract (external bribes)
    function getRewardContracts(address pool) external view returns (address feesReward, address bribeReward) {
        IKickoffVoteSalePoolReader poolContract = IKickoffVoteSalePoolReader(pool);
        address gauge = poolContract.gauge();
        
        if (gauge == address(0)) return (address(0), address(0));
        
        IVoter voter = poolContract.voter();
        
        try voter.gaugeToFees(gauge) returns (address _fees) {
            feesReward = _fees;
        } catch {}
        
        try voter.gaugeToBribe(gauge) returns (address _bribe) {
            bribeReward = _bribe;
        } catch {}
    }

    /// @notice Get all available reward tokens from fees and bribe contracts
    /// @param pool The KickoffVoteSalePool address
    /// @return feesTokens Array of token addresses from fees contract
    /// @return bribeTokens Array of token addresses from bribe contract
    function getAvailableRewardTokens(address pool) external view returns (
        address[] memory feesTokens,
        address[] memory bribeTokens
    ) {
        IKickoffVoteSalePoolReader poolContract = IKickoffVoteSalePoolReader(pool);
        address gauge = poolContract.gauge();
        
        if (gauge == address(0)) return (new address[](0), new address[](0));
        
        IVoter voter = poolContract.voter();
        
        address feesReward;
        address bribeReward;
        
        try voter.gaugeToFees(gauge) returns (address _fees) {
            feesReward = _fees;
        } catch {}
        
        try voter.gaugeToBribe(gauge) returns (address _bribe) {
            bribeReward = _bribe;
        } catch {}
        
        feesTokens = _getRewardTokens(feesReward);
        bribeTokens = _getRewardTokens(bribeReward);
    }

    /// @notice Get total claimable rewards for all locked NFTs in the pool
    /// @param pool The KickoffVoteSalePool address
    /// @param rewardTokens Array of token addresses to check
    /// @return amounts Array of total claimable amounts for each token
    function getTotalClaimableRewards(
        address pool,
        address[] calldata rewardTokens
    ) external view returns (uint256[] memory amounts) {
        amounts = new uint256[](rewardTokens.length);
        
        IKickoffVoteSalePoolReader poolContract = IKickoffVoteSalePoolReader(pool);
        address gauge = poolContract.gauge();
        
        uint256[] memory tokenIds = poolContract.getLockedTokenIds();
        
        if (gauge == address(0) || tokenIds.length == 0) return amounts;
        
        IVoter voter = poolContract.voter();
        
        address feesReward;
        address bribeReward;
        
        try voter.gaugeToFees(gauge) returns (address _fees) {
            feesReward = _fees;
        } catch {}
        
        try voter.gaugeToBribe(gauge) returns (address _bribe) {
            bribeReward = _bribe;
        } catch {}
        
        // Sum up rewards across all locked NFTs
        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            
            for (uint256 j = 0; j < rewardTokens.length; j++) {
                if (feesReward != address(0)) {
                    try IVotingReward(feesReward).earned(rewardTokens[j], tokenId) returns (uint256 earned) {
                        amounts[j] += earned;
                    } catch {}
                }
                
                if (bribeReward != address(0)) {
                    try IVotingReward(bribeReward).earned(rewardTokens[j], tokenId) returns (uint256 earned) {
                        amounts[j] += earned;
                    } catch {}
                }
            }
        }
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
    function getLockedNFTInfo(address pool, uint256 tokenId)
        external view returns (address owner, uint256 votingPower, bool unlocked)
    {
        return IKickoffVoteSalePoolReader(pool).lockedNFTs(tokenId);
    }

    /*//////////////////////////////////////////////////////////////
                        INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Get all reward tokens from a reward contract
    function _getRewardTokens(address rewardContract) internal view returns (address[] memory tokens) {
        if (rewardContract == address(0)) return new address[](0);
        
        uint256 length;
        try IVotingReward(rewardContract).rewardsListLength() returns (uint256 len) {
            length = len;
        } catch {
            return new address[](0);
        }
        
        tokens = new address[](length);
        for (uint256 i = 0; i < length; i++) {
            try IVotingReward(rewardContract).rewardsList(i) returns (address token) {
                tokens[i] = token;
            } catch {}
        }
    }
}

