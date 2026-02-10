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
/// @dev Flow: caller approves dustAmount of each token → calls fixPoolPrice() →
///      arbitrageur transferFrom's dust tokens, adds dust liquidity, swaps to target price,
///      cleans up dust position, and returns remaining tokens to caller
contract CLPriceArbitrageur {
    /*//////////////////////////////////////////////////////////////
                                 ERRORS
    //////////////////////////////////////////////////////////////*/

    error DustArbitrageFailed();
    error UnauthorizedCallback();
    error InvalidTickRange();
    error PriceNotReached();

    /*//////////////////////////////////////////////////////////////
                                 EVENTS
    //////////////////////////////////////////////////////////////*/

    event PoolPriceArbitraged(address indexed pool, uint160 oldSqrtPriceX96, uint160 newSqrtPriceX96);
    event TailTickCorrected(address indexed pool, int24 oldTick, int24 newTick);

    /*//////////////////////////////////////////////////////////////
                               STATE
    //////////////////////////////////////////////////////////////*/

    /// @notice The pool address expected for the current swap callback
    /// @dev Set before each swap() call and checked in uniswapV3SwapCallback()
    ///      to ensure only the exact pool being arbitraged can trigger the callback
    address private _expectedPool;

    /*//////////////////////////////////////////////////////////////
                               CONSTANTS
    //////////////////////////////////////////////////////////////*/

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
    /// @dev Caller must approve `dustAmount` of both token0 and token1 to this contract before calling.
    ///      Admin specifies dustAmount in wei each time — use a small value (e.g. 1000) for normal cases,
    ///      or increase if the attacker added liquidity to the pool and the swap can't reach the target.
    /// @dev H-01 fix: If pool tick is in the tail zone (outside ±887200 but within canonical ±887272),
    ///      performs a free swap through the guaranteed-empty tail zone first, then proceeds with dust arbitrage.
    ///      The tail zone has zero liquidity by definition (no tickSpacing=200 position can cover it),
    ///      so the swap costs zero tokens.
    /// @dev H-02 fix: After the dust swap, verifies that the target price was actually reached.
    ///      Reverts with PriceNotReached() if the dust amount was insufficient.
    /// @param pool The existing CL pool address
    /// @param token0 The pool's token0 address (sorted)
    /// @param token1 The pool's token1 address (sorted)
    /// @param targetSqrtPrice The desired sqrtPriceX96 (fair price)
    /// @param tickSpacing The pool's tick spacing
    /// @param dustAmount Amount of each token (in wei) to use for dust arbitrage
    /// @return spent0 Actual amount of token0 spent (dustAmount minus returned remainder)
    /// @return spent1 Actual amount of token1 spent (dustAmount minus returned remainder)
    function fixPoolPrice(
        address pool,
        address token0,
        address token1,
        uint160 targetSqrtPrice,
        int24 tickSpacing,
        uint256 dustAmount
    ) external returns (uint256 spent0, uint256 spent1) {
        // Read current price
        (uint160 currentSqrtPrice, int24 currentTick,,,,) = ICLPool(pool).slot0();
        if (currentSqrtPrice == targetSqrtPrice) return (0, 0);

        uint160 originalSqrtPrice = currentSqrtPrice;

        // H-01: If current tick is in the tail zone (outside tickSpacing-aligned bounds),
        // perform a free swap to bring the price back into the supported range.
        // The tail zone [887201..887271] and [-887272..-887201] has ZERO active liquidity
        // because no tickSpacing=200 position can cover those ticks. The swap traverses
        // the empty bitmap for free (0 tokens consumed).
        if (currentTick > CL_MAX_TICK || currentTick < CL_MIN_TICK) {
            int24 oldTick = currentTick;
            bool tailZeroForOne = currentTick > CL_MAX_TICK;

            _expectedPool = pool;
            ICLPool(pool).swap(
                address(this),
                tailZeroForOne,
                int256(1), // Minimal amountSpecified (pool requires != 0)
                targetSqrtPrice,
                abi.encode(token0, token1)
            );
            _expectedPool = address(0);

            // Re-read price after tail correction
            (currentSqrtPrice, currentTick,,,,) = ICLPool(pool).slot0();
            emit TailTickCorrected(pool, oldTick, currentTick);

            // If target already reached (empty pool case), we're done
            if (currentSqrtPrice == targetSqrtPrice) {
                emit PoolPriceArbitraged(pool, originalSqrtPrice, targetSqrtPrice);
                return (0, 0);
            }
        }

        // Record caller balances before transferFrom to compute precise spend
        uint256 callerBal0Before = IERC20(token0).balanceOf(msg.sender);
        uint256 callerBal1Before = IERC20(token1).balanceOf(msg.sender);

        // Transfer dust tokens from caller
        IERC20(token0).transferFrom(msg.sender, address(this), dustAmount);
        IERC20(token1).transferFrom(msg.sender, address(this), dustAmount);

        // Determine swap direction
        bool zeroForOne = currentSqrtPrice > targetSqrtPrice;

        // Step 1: Calculate tick range covering the price path
        int24 tickA = TickMathLib.getTickAtSqrtRatio(currentSqrtPrice);
        int24 tickB = TickMathLib.getTickAtSqrtRatio(targetSqrtPrice);
        
        (int24 tickLower, int24 tickUpper) = _calculateTickRange(tickA, tickB, tickSpacing);

        // Step 2: Add dust concentrated liquidity to enable the swap
        IERC20(token0).approve(address(clPositionManager), dustAmount);
        IERC20(token1).approve(address(clPositionManager), dustAmount);

        INonfungiblePositionManager.MintParams memory dustParams = INonfungiblePositionManager.MintParams({
            token0: token0,
            token1: token1,
            tickSpacing: tickSpacing,
            tickLower: tickLower,
            tickUpper: tickUpper,
            amount0Desired: dustAmount,
            amount1Desired: dustAmount,
            amount0Min: 0,
            amount1Min: 0,
            recipient: address(this),
            deadline: block.timestamp,
            sqrtPriceX96: 0 // Pool already exists
        });

        (uint256 dustTokenId, uint128 dustLiquidity,,) = clPositionManager.mint(dustParams);
        if (dustTokenId == 0 || dustLiquidity == 0) revert DustArbitrageFailed();

        // Step 3: Swap to move price to target
        _expectedPool = pool;
        ICLPool(pool).swap(
            address(this),
            zeroForOne,
            int256(dustAmount),
            targetSqrtPrice,
            abi.encode(token0, token1)
        );
        _expectedPool = address(0);

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

        // H-02: Verify target price was actually reached after dust swap
        // If dust amount was insufficient to overcome attacker's liquidity, revert
        (uint160 postSwapPrice,,,,,) = ICLPool(pool).slot0();
        if (postSwapPrice != targetSqrtPrice) revert PriceNotReached();

        // Compute actual tokens spent by comparing caller balances
        // If caller ended up with more tokens (net gain from swap output), spent is 0
        uint256 callerBal0After = IERC20(token0).balanceOf(msg.sender);
        uint256 callerBal1After = IERC20(token1).balanceOf(msg.sender);
        spent0 = callerBal0After < callerBal0Before ? callerBal0Before - callerBal0After : 0;
        spent1 = callerBal1After < callerBal1Before ? callerBal1Before - callerBal1After : 0;

        emit PoolPriceArbitraged(pool, originalSqrtPrice, targetSqrtPrice);
    }

    /*//////////////////////////////////////////////////////////////
                           SWAP CALLBACK
    //////////////////////////////////////////////////////////////*/

    /// @notice Callback for CL pool swaps (Uniswap V3 compatible)
    /// @dev Called by the CL pool during swap() to collect input tokens
    /// @dev Security: validates msg.sender is the exact pool set by fixPoolPrice() before swap()
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        // Security: only the exact pool being arbitraged can trigger the callback
        if (msg.sender != _expectedPool) revert UnauthorizedCallback();

        (address token0, address token1) = abi.decode(data, (address, address));

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
