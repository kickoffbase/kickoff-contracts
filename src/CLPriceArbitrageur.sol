// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IERC20} from "./interfaces/IERC20.sol";
import {INonfungiblePositionManager} from "./interfaces/INonfungiblePositionManager.sol";
import {ICLFactory} from "./interfaces/ICLFactory.sol";
import {ICLPool} from "./interfaces/ICLPool.sol";
import {TickMathLib} from "./libraries/TickMathLib.sol";

/// @title CLPriceArbitrageur
/// @notice Shared contract for fixing CL pool prices via dust arbitrage
/// @dev Used by KickoffVoteSalePool to correct pool price when someone front-runs pool creation
/// @dev Stateless - can be shared across all vote-sale pools
/// @dev Flow: caller approves DUST_AMOUNT of each token → calls fixPoolPrice() →
///      arbitrageur transferFrom's dust tokens, adds dust liquidity, swaps to target price,
///      cleans up dust position, and returns remaining tokens to caller
contract CLPriceArbitrageur {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error DustArbitrageFailed();
    error UnauthorizedCallback();
    error InvalidTickRange();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event PoolPriceArbitraged(address indexed pool, uint160 oldSqrtPriceX96, uint160 newSqrtPriceX96);

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Dust amount used per token for price arbitrage (wei)
    uint256 public constant DUST_AMOUNT = 1000;

    /// @notice Aerodrome Slipstream NonfungiblePositionManager on Base mainnet
    INonfungiblePositionManager public constant clPositionManager = 
        INonfungiblePositionManager(0x827922686190790b37229fd06084350E74485b72);

    /// @notice Aerodrome Slipstream CL Factory on Base mainnet
    ICLFactory public constant clFactory = ICLFactory(0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A);

    /// @notice Full-range tick bounds (for clamping)
    int24 public constant CL_MIN_TICK = -887200;
    int24 public constant CL_MAX_TICK = 887200;

    /*//////////////////////////////////////////////////////////////
                            MAIN FUNCTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Fix a CL pool's price via dust arbitrage
    /// @dev Caller must approve DUST_AMOUNT of both token0 and token1 to this contract before calling
    /// @dev Adds dust concentrated liquidity, swaps to target price, cleans up, returns remaining tokens
    /// @param pool The existing CL pool address
    /// @param token0 The pool's token0 address (sorted)
    /// @param token1 The pool's token1 address (sorted)
    /// @param targetSqrtPrice The desired sqrtPriceX96 (fair price)
    /// @param tickSpacing The pool's tick spacing
    function fixPoolPrice(
        address pool,
        address token0,
        address token1,
        uint160 targetSqrtPrice,
        int24 tickSpacing
    ) external {
        // Read current price
        (uint160 currentSqrtPrice,,,,,) = ICLPool(pool).slot0();
        if (currentSqrtPrice == targetSqrtPrice) return;

        // Transfer dust tokens from caller
        IERC20(token0).transferFrom(msg.sender, address(this), DUST_AMOUNT);
        IERC20(token1).transferFrom(msg.sender, address(this), DUST_AMOUNT);

        // Determine swap direction
        bool zeroForOne = currentSqrtPrice > targetSqrtPrice;

        // Step 1: Calculate tick range covering the price path
        int24 tickA = TickMathLib.getTickAtSqrtRatio(currentSqrtPrice);
        int24 tickB = TickMathLib.getTickAtSqrtRatio(targetSqrtPrice);
        
        (int24 tickLower, int24 tickUpper) = _calculateTickRange(tickA, tickB, tickSpacing);

        // Step 2: Add dust concentrated liquidity to enable the swap
        IERC20(token0).approve(address(clPositionManager), DUST_AMOUNT);
        IERC20(token1).approve(address(clPositionManager), DUST_AMOUNT);

        INonfungiblePositionManager.MintParams memory dustParams = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            tickSpacing: tickSpacing,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: DUST_AMOUNT,
            amount1Desired: DUST_AMOUNT,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp,
            sqrtPriceX96: 0 // Pool already exists
        });

        (uint256 dustTokenId, uint128 dustLiquidity,,) = clPositionManager.mint(dustParams);
        if (dustTokenId == 0 || dustLiquidity == 0) revert DustArbitrageFailed();

        // Step 3: Swap to move price to target
        ICLPool(pool).swap(
            address(this),
            zeroForOne,
            int256(DUST_AMOUNT),
            targetSqrtPrice,
            abi.encode(token0, token1)
        );

        // Step 4: Remove dust position
        clPositionManager.decreaseLiquidity(
            INonfungiblePositionManager.DecreaseLiquidityParams({
                tokenId: dustTokenId,
                liquidity: dustLiquidity,
                amount0Min: 0,
                amount1Min: 0,
                deadline: block.timestamp
            })
        );

        clPositionManager.collect(
            INonfungiblePositionManager.CollectParams({
                tokenId: dustTokenId,
                recipient: address(this),
                amount0Max: type(uint128).max,
                amount1Max: type(uint128).max
            })
        );

        clPositionManager.burn(dustTokenId);

        // Step 5: Return remaining tokens to caller
        uint256 bal0 = IERC20(token0).balanceOf(address(this));
        uint256 bal1 = IERC20(token1).balanceOf(address(this));
        if (bal0 > 0) IERC20(token0).transfer(msg.sender, bal0);
        if (bal1 > 0) IERC20(token1).transfer(msg.sender, bal1);

        emit PoolPriceArbitraged(pool, currentSqrtPrice, targetSqrtPrice);
    }

    /*//////////////////////////////////////////////////////////////
                           SWAP CALLBACK
    //////////////////////////////////////////////////////////////*/

    /// @notice Callback for CL pool swaps (Uniswap V3 compatible)
    /// @dev Called by the CL pool during swap() to collect input tokens
    /// @dev Security: validates caller is a legitimate Aerodrome CL pool via factory
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        (address token0, address token1) = abi.decode(data, (address, address));

        // Security: verify caller is a legitimate CL pool
        // Check all possible tick spacings that could match this pool
        bool isLegitimate;
        int24[4] memory spacings = [int24(1), int24(50), int24(100), int24(200)];
        for (uint256 i = 0; i < spacings.length; i++) {
            if (clFactory.getPool(token0, token1, spacings[i]) == msg.sender) {
                isLegitimate = true;
                break;
            }
        }
        if (!isLegitimate) revert UnauthorizedCallback();

        if (amount0Delta > 0) {
            IERC20(token0).transfer(msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            IERC20(token1).transfer(msg.sender, uint256(amount1Delta));
        }
    }

    /*//////////////////////////////////////////////////////////////
                         INTERNAL FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Calculate tick range covering the path, rounded to tick spacing boundaries
    function _calculateTickRange(
        int24 tickA,
        int24 tickB,
        int24 tickSpacing
    ) internal pure returns (int24 tickLower, int24 tickUpper) {
        int24 lower = tickA < tickB ? tickA : tickB;
        int24 upper = tickA < tickB ? tickB : tickA;

        // Round lower DOWN to tick spacing boundary
        tickLower = (lower / tickSpacing) * tickSpacing;
        if (lower < 0 && lower % tickSpacing != 0) tickLower -= tickSpacing;

        // Round upper UP to tick spacing boundary
        tickUpper = (upper / tickSpacing) * tickSpacing;
        if (tickUpper <= upper) tickUpper += tickSpacing;

        // Clamp to valid range
        if (tickLower < CL_MIN_TICK) tickLower = CL_MIN_TICK;
        if (tickUpper > CL_MAX_TICK) tickUpper = CL_MAX_TICK;

        if (tickLower >= tickUpper) revert InvalidTickRange();
    }

    /// @notice ERC721 receiver for dust position NFT
    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}
