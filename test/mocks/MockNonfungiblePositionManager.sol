// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {INonfungiblePositionManager} from "../../src/interfaces/INonfungiblePositionManager.sol";
import {IERC721Receiver} from "../../src/interfaces/IERC721Receiver.sol";

/// @title MockNonfungiblePositionManager
/// @notice Mock Slipstream position manager for testing
contract MockNonfungiblePositionManager {
    struct Position {
        address owner;
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint128 liquidity;
        uint128 tokensOwed0;
        uint128 tokensOwed1;
    }

    mapping(uint256 => Position) public _positions;
    mapping(uint256 => address) public getApproved;
    
    uint256 public nextTokenId = 1;
    address public factory;

    event Transfer(address indexed from, address indexed to, uint256 indexed tokenId);

    constructor(address _factory) {
        factory = _factory;
    }

    /// @notice Mint a new position
    function mint(INonfungiblePositionManager.MintParams calldata params)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        tokenId = nextTokenId++;
        liquidity = uint128(params.amount0Desired + params.amount1Desired); // Simplified
        amount0 = params.amount0Desired;
        amount1 = params.amount1Desired;

        _positions[tokenId] = Position({
            owner: params.recipient,
            token0: params.token0,
            token1: params.token1,
            tickSpacing: params.tickSpacing,
            tickLower: params.tickLower,
            tickUpper: params.tickUpper,
            liquidity: liquidity,
            tokensOwed0: 0,
            tokensOwed1: 0
        });

        emit Transfer(address(0), params.recipient, tokenId);
    }

    /// @notice Create a position for testing (without actual token transfers)
    function createPosition(
        address owner,
        address token0,
        address token1,
        int24 tickSpacing,
        uint128 liquidity
    ) external returns (uint256 tokenId) {
        tokenId = nextTokenId++;
        _positions[tokenId] = Position({
            owner: owner,
            token0: token0,
            token1: token1,
            tickSpacing: tickSpacing,
            tickLower: -887200,
            tickUpper: 887200,
            liquidity: liquidity,
            tokensOwed0: 0,
            tokensOwed1: 0
        });
        emit Transfer(address(0), owner, tokenId);
    }

    /// @notice Set owed tokens for testing fee collection
    function setTokensOwed(uint256 tokenId, uint128 owed0, uint128 owed1) external {
        _positions[tokenId].tokensOwed0 = owed0;
        _positions[tokenId].tokensOwed1 = owed1;
    }

    /// @notice Collect fees
    function collect(INonfungiblePositionManager.CollectParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        Position storage pos = _positions[params.tokenId];
        
        amount0 = pos.tokensOwed0 > params.amount0Max ? params.amount0Max : pos.tokensOwed0;
        amount1 = pos.tokensOwed1 > params.amount1Max ? params.amount1Max : pos.tokensOwed1;
        
        pos.tokensOwed0 -= uint128(amount0);
        pos.tokensOwed1 -= uint128(amount1);

        // In real implementation, tokens would be transferred to recipient
        // For testing, we'll handle this in the test setup
    }

    /// @notice Get position info
    function positions(uint256 tokenId)
        external
        view
        returns (
            uint96 nonce,
            address operator,
            address token0,
            address token1,
            int24 tickSpacing,
            int24 tickLower,
            int24 tickUpper,
            uint128 liquidity,
            uint256 feeGrowthInside0LastX128,
            uint256 feeGrowthInside1LastX128,
            uint128 tokensOwed0,
            uint128 tokensOwed1
        )
    {
        Position storage pos = _positions[tokenId];
        return (
            0,
            address(0),
            pos.token0,
            pos.token1,
            pos.tickSpacing,
            pos.tickLower,
            pos.tickUpper,
            pos.liquidity,
            0,
            0,
            pos.tokensOwed0,
            pos.tokensOwed1
        );
    }

    function ownerOf(uint256 tokenId) external view returns (address) {
        return _positions[tokenId].owner;
    }

    function approve(address to, uint256 tokenId) external {
        require(_positions[tokenId].owner == msg.sender, "Not owner");
        getApproved[tokenId] = to;
    }

    function transferFrom(address from, address to, uint256 tokenId) external {
        require(
            _positions[tokenId].owner == from,
            "Wrong from"
        );
        require(
            msg.sender == from || msg.sender == getApproved[tokenId],
            "Not approved"
        );
        
        getApproved[tokenId] = address(0);
        _positions[tokenId].owner = to;
        
        emit Transfer(from, to, tokenId);
    }

    function safeTransferFrom(address from, address to, uint256 tokenId) external {
        require(
            _positions[tokenId].owner == from,
            "Wrong from"
        );
        require(
            msg.sender == from || msg.sender == getApproved[tokenId],
            "Not approved"
        );
        
        getApproved[tokenId] = address(0);
        _positions[tokenId].owner = to;
        
        emit Transfer(from, to, tokenId);

        if (to.code.length > 0) {
            require(
                IERC721Receiver(to).onERC721Received(msg.sender, from, tokenId, "") ==
                    IERC721Receiver.onERC721Received.selector,
                "ERC721: transfer to non ERC721Receiver"
            );
        }
    }
}
