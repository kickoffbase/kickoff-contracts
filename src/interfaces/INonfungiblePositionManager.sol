// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title INonfungiblePositionManager
/// @notice Interface for Aerodrome Slipstream's NFT Position Manager
interface INonfungiblePositionManager {
    /// @notice Parameters for minting a new position
    struct MintParams {
        address token0;
        address token1;
        int24 tickSpacing;
        int24 tickLower;
        int24 tickUpper;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min;
        uint256 amount1Min;
        address recipient;
        uint256 deadline;
        uint160 sqrtPriceX96;
    }

    /// @notice Creates a new position wrapped in an NFT
    /// @param params The params necessary to mint a position
    /// @return tokenId The ID of the token that represents the minted position
    /// @return liquidity The amount of liquidity for this position
    /// @return amount0 The amount of token0 deposited
    /// @return amount1 The amount of token1 deposited
    function mint(MintParams calldata params)
        external
        payable
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1);

    /// @notice Parameters for collecting fees from a position
    struct CollectParams {
        uint256 tokenId;
        address recipient;
        uint128 amount0Max;
        uint128 amount1Max;
    }

    /// @notice Collects up to a maximum amount of fees owed to a specific position
    /// @param params The params necessary to collect fees
    /// @return amount0 The amount of fees collected in token0
    /// @return amount1 The amount of fees collected in token1
    function collect(CollectParams calldata params) external payable returns (uint256 amount0, uint256 amount1);

    /// @notice Returns the position information associated with a given token ID
    /// @param tokenId The ID of the token that represents the position
    /// @return nonce The nonce for permits
    /// @return operator The address approved for spending
    /// @return token0 The address of the token0 for this pool
    /// @return token1 The address of the token1 for this pool
    /// @return tickSpacing The tick spacing of the pool
    /// @return tickLower The lower tick of the position
    /// @return tickUpper The upper tick of the position
    /// @return liquidity The liquidity of the position
    /// @return feeGrowthInside0LastX128 Fee growth of token0 inside the tick range
    /// @return feeGrowthInside1LastX128 Fee growth of token1 inside the tick range
    /// @return tokensOwed0 Uncollected token0 fees
    /// @return tokensOwed1 Uncollected token1 fees
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
        );

    /// @notice Parameters for decreasing liquidity
    struct DecreaseLiquidityParams {
        uint256 tokenId;
        uint128 liquidity;
        uint256 amount0Min;
        uint256 amount1Min;
        uint256 deadline;
    }

    /// @notice Decreases the amount of liquidity in a position and accounts it to the position
    /// @param params The params necessary to decrease liquidity
    /// @return amount0 The amount of token0 accounted to the position's tokens owed
    /// @return amount1 The amount of token1 accounted to the position's tokens owed
    function decreaseLiquidity(DecreaseLiquidityParams calldata params)
        external
        payable
        returns (uint256 amount0, uint256 amount1);

    /// @notice Burns a token ID, which deletes it from the NFT contract
    /// @dev The token must have 0 liquidity and all tokens must be collected first
    /// @param tokenId The ID of the token that is being burned
    function burn(uint256 tokenId) external payable;

    /// @notice Returns the owner of the NFT
    function ownerOf(uint256 tokenId) external view returns (address);

    /// @notice Approve an address to manage a token
    function approve(address to, uint256 tokenId) external;

    /// @notice Transfer NFT from one address to another
    function transferFrom(address from, address to, uint256 tokenId) external;

    /// @notice Safe transfer NFT
    function safeTransferFrom(address from, address to, uint256 tokenId) external;

    /// @notice Returns the address of the pool factory
    function factory() external view returns (address);
}
