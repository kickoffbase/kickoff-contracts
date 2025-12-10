// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IERC721Receiver
/// @notice Interface for contracts that can receive ERC721 tokens
interface IERC721Receiver {
    /// @notice Handle the receipt of an NFT
    /// @param operator The address which called safeTransferFrom
    /// @param from The address which previously owned the token
    /// @param tokenId The NFT token ID being transferred
    /// @param data Additional data with no specified format
    /// @return The selector of this function (must return this value)
    function onERC721Received(
        address operator,
        address from,
        uint256 tokenId,
        bytes calldata data
    ) external returns (bytes4);
}

