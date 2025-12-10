// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC721Receiver} from "../../src/interfaces/IERC721Receiver.sol";

/// @title MockVotingEscrow
/// @notice Mock veAERO NFT for testing
contract MockVotingEscrow {
    struct NFT {
        address owner;
        uint256 votingPower;
        uint256 lockEnd;
    }

    mapping(uint256 => NFT) public nfts;
    mapping(uint256 => address) public getApproved;
    mapping(address => mapping(address => bool)) public isApprovedForAll;

    uint256 public nextTokenId = 1;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);
    event Approval(address indexed owner, address indexed approved, uint256 indexed tokenId);
    event ApprovalForAll(address indexed owner, address indexed operator, bool approved);

    function mint(address to, uint256 votingPower, uint256 lockEnd) external returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        nfts[tokenId] = NFT({owner: to, votingPower: votingPower, lockEnd: lockEnd});
        emit Transfer(address(0), to, tokenId);
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return nfts[tokenId].owner;
    }

    function balanceOfNFT(uint256 tokenId) external view returns (uint256) {
        return nfts[tokenId].votingPower;
    }

    function balanceOfNFTAt(uint256 tokenId, uint256) external view returns (uint256) {
        return nfts[tokenId].votingPower;
    }

    function isApprovedOrOwner(address spender, uint256 tokenId) external view returns (bool) {
        address tokenOwner = nfts[tokenId].owner;
        return spender == tokenOwner || getApproved[tokenId] == spender || isApprovedForAll[tokenOwner][spender];
    }

    function approve(address to, uint256 tokenId) external {
        require(nfts[tokenId].owner == msg.sender, "Not owner");
        getApproved[tokenId] = to;
        emit Approval(msg.sender, to, tokenId);
    }

    function setApprovalForAll(address operator, bool approved) external {
        isApprovedForAll[msg.sender][operator] = approved;
        emit ApprovalForAll(msg.sender, operator, approved);
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(_isApprovedOrOwner(msg.sender, tokenId), "Not approved");
        require(nfts[tokenId].owner == from, "Wrong from");

        getApproved[tokenId] = address(0);
        nfts[tokenId].owner = to;

        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(_isApprovedOrOwner(msg.sender, tokenId), "Not approved");
        require(nfts[tokenId].owner == from, "Wrong from");

        getApproved[tokenId] = address(0);
        nfts[tokenId].owner = to;

        emit Transfer(from, to, tokenId);

        if (to.code.length > 0) {
            require(
                IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, "") ==
                    IERC721Receiver.onERC721Received.selector,
                "ERC721: transfer to non ERC721Receiver"
            );
        }
    }

    function safeTransferFrom(address from, address to, uint256 tokenId, bytes calldata data) external {
        require(_isApprovedOrOwner(msg.sender, tokenId), "Not approved");
        require(nfts[tokenId].owner == from, "Wrong from");

        getApproved[tokenId] = address(0);
        nfts[tokenId].owner = to;

        emit Transfer(from, to, tokenId);

        if (to.code.length > 0) {
            require(
                IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, data) ==
                    IERC721Receiver.onERC721Received.selector,
                "ERC721: transfer to non ERC721Receiver"
            );
        }
    }

    function locked(uint256 tokenId) external view returns (int128 amount, uint256 end) {
        NFT storage nft = nfts[tokenId];
        return (int128(int256(nft.votingPower)), nft.lockEnd);
    }

    function totalSupply() external pure returns (uint256) {
        return 1000000 ether;
    }

    function tokenURI(uint256) external pure returns (string memory) {
        return "";
    }

    function setVotingPower(uint256 tokenId, uint256 newPower) external {
        nfts[tokenId].votingPower = newPower;
    }

    function _isApprovedOrOwner(address spender, uint256 tokenId) internal view returns (bool) {
        address tokenOwner = nfts[tokenId].owner;
        return spender == tokenOwner || getApproved[tokenId] == spender || isApprovedForAll[tokenOwner][spender];
    }
}

