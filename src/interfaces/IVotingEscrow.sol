// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IVotingEscrow
/// @notice Interface for Aerodrome's veAERO NFT contract
interface IVotingEscrow {
    /// @notice Get the owner of an NFT
    /// @param tokenId The NFT token ID
    /// @return The owner address
    function ownerOf(uint256 tokenId) external view returns (address);

    /// @notice Get the voting power of an NFT at current timestamp
    /// @param tokenId The NFT token ID
    /// @return The voting power
    function balanceOfNFT(uint256 tokenId) external view returns (uint256);

    /// @notice Get the voting power of an NFT at a specific timestamp
    /// @param tokenId The NFT token ID
    /// @param _t The timestamp
    /// @return The voting power at that timestamp
    function balanceOfNFTAt(uint256 tokenId, uint256 _t) external view returns (uint256);

    /// @notice Check if an address is approved or owner of an NFT
    /// @param _spender The address to check
    /// @param tokenId The NFT token ID
    /// @return True if approved or owner
    function isApprovedOrOwner(address _spender, uint256 tokenId) external view returns (bool);

    /// @notice Get approved address for an NFT
    /// @param tokenId The NFT token ID
    /// @return The approved address
    function getApproved(uint256 tokenId) external view returns (address);

    /// @notice Check if operator is approved for all NFTs of owner
    /// @param owner The owner address
    /// @param operator The operator address
    /// @return True if approved for all
    function isApprovedForAll(address owner, address operator) external view returns (bool);

    /// @notice Transfer NFT from one address to another
    /// @param from The sender address
    /// @param to The recipient address
    /// @param tokenId The NFT token ID
    function transferFrom(address from, address to, uint256 tokenId) external;

    /// @notice Safe transfer NFT from one address to another
    /// @param from The sender address
    /// @param to The recipient address
    /// @param tokenId The NFT token ID
    function safeTransferFrom(address from, address to, uint256 tokenId) external;

    /// @notice Safe transfer NFT with data
    /// @param from The sender address
    /// @param to The recipient address
    /// @param tokenId The NFT token ID
    /// @param data Additional data
    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external;

    /// @notice Approve an address to manage an NFT
    /// @param to The address to approve
    /// @param tokenId The NFT token ID
    function approve(address to, uint256 tokenId) external;

    /// @notice Set approval for all NFTs
    /// @param operator The operator address
    /// @param approved Whether to approve or revoke
    function setApprovalForAll(address operator, bool approved) external;

    /// @notice Get the locked amount and end time for an NFT
    /// @param tokenId The NFT token ID
    /// @return amount The locked AERO amount
    /// @return end The lock end timestamp
    function locked(uint256 tokenId) external view returns (int128 amount, uint256 end);

    /// @notice Get the total voting power
    /// @return The total supply of voting power
    function totalSupply() external view returns (uint256);

    /// @notice Get the token URI
    /// @param tokenId The NFT token ID
    /// @return The token URI
    function tokenURI(uint256 tokenId) external view returns (string memory);
}

