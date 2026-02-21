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
///      arbitrageur transferFrom's only the input token, performs direct swap to target price,
///      and returns remaining tokens to caller
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

    /// @notice Full-range tick bounds (floor(887272/2000)*2000 = 886000)
    int24 public constant CL_MIN_TICK = -886000;
    int24 public constant CL_MAX_TICK = 886000;

    /*//////////////////////////////////////////////////////////////
                            MAIN FUNCTION
    //////////////////////////////////////////////////////////////*/

    /// @notice Fix a CL pool's price via direct swap (no dust liquidity mint)
    /// @dev Caller must approve `dustAmount` of both token0 and token1 to this contract before calling.
    ///      Only the input token (determined by swap direction) is actually transferred.
    ///      Admin specifies dustAmount in wei each time — use a small value (e.g. 1000) for normal cases,
    ///      or increase if the attacker added liquidity to the pool and the swap can't reach the target.
    /// @dev In empty pools, the swap traverses zero-liquidity ticks for free (0 tokens consumed).
    ///      If an attacker front-ran with liquidity, dustAmount serves as the budget to push through it.
    /// @dev H-01 fix: If pool tick is in the tail zone (outside ±886000 but within canonical ±887272),
    ///      performs a free swap through the guaranteed-empty tail zone first, then proceeds with price fix.
    ///      The tail zone has zero liquidity by definition (no tickSpacing=2000 position can cover it),
    ///      so the swap costs zero tokens.
    /// @dev H-02 fix: After the swap, verifies that the target price was actually reached.
    ///      Reverts with PriceNotReached() if the dust amount was insufficient.
    /// @param pool The existing CL pool address
    /// @param token0 The pool's token0 address (sorted)
    /// @param token1 The pool's token1 address (sorted)
    /// @param targetSqrtPrice The desired sqrtPriceX96 (fair price)
    /// @param dustAmount Amount of input token (in wei) to use for price arbitrage
    /// @return spent0 Actual amount of token0 spent (0 if swap direction is !zeroForOne)
    /// @return spent1 Actual amount of token1 spent (0 if swap direction is zeroForOne)
    function fixPoolPrice(
        address pool,
        address token0,
        address token1,
        uint160 targetSqrtPrice,
        int24, // tickSpacing (kept for interface compatibility)
        uint256 dustAmount
    ) external returns (uint256 spent0, uint256 spent1) {
        // Read current price
        (uint160 currentSqrtPrice, int24 currentTick,,,,) = ICLPool(pool).slot0();
        if (currentSqrtPrice == targetSqrtPrice) return (0, 0);

        uint160 originalSqrtPrice = currentSqrtPrice;

        // H-01: If current tick is in the tail zone (outside tickSpacing-aligned bounds),
        // perform a free swap to bring the price back into the supported range.
        // The tail zone [886001..887271] and [-887272..-886001] has ZERO active liquidity
        // because no tickSpacing=2000 position can cover those ticks. The swap traverses
        // the empty bitmap for free (0 tokens consumed).
        if (currentTick > CL_MAX_TICK || currentTick < CL_MIN_TICK) {
            int24 oldTick = currentTick;
            bool tailZeroForOne = currentTick > CL_MAX_TICK;

            // Compute the boundary of the empty tail zone.
            // The swap must stop AT the boundary (tick ±886000), not continue into the normal range
            // where attacker liquidity may exist. The arbitrageur has no tokens yet (transferFrom
            // happens later), so any callback demanding tokens would revert.
            uint160 tailBoundary = tailZeroForOne
                ? TickMathLib.getSqrtRatioAtTick(CL_MAX_TICK)   // stop AT tick +886000
                : TickMathLib.getSqrtRatioAtTick(CL_MIN_TICK);  // stop AT tick -886000

            _expectedPool = pool;
            ICLPool(pool).swap(
                address(this),
                tailZeroForOne,
                int256(1), // Minimal amountSpecified (pool requires != 0)
                tailBoundary,
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

        // Determine swap direction
        bool zeroForOne = currentSqrtPrice > targetSqrtPrice;

        // Snapshot arbitrageur balances before pulling dust (to isolate from external donations)
        uint256 arbBal0Before = IERC20(token0).balanceOf(address(this));
        uint256 arbBal1Before = IERC20(token1).balanceOf(address(this));

        // Transfer only the input token from caller (not both — output token is not needed).
        // For empty pools, the swap traverses zero-liquidity ticks for free (0 tokens consumed).
        // If attacker added liquidity, dustAmount serves as the budget to push through it.
        if (zeroForOne) {
            IERC20(token0).transferFrom(msg.sender, address(this), dustAmount);
        } else {
            IERC20(token1).transferFrom(msg.sender, address(this), dustAmount);
        }

        // Direct swap to move price to target (no dust liquidity mint needed)
        _expectedPool = pool;
        ICLPool(pool).swap(
            address(this),
            zeroForOne,
            int256(dustAmount),
            targetSqrtPrice,
            abi.encode(token0, token1)
        );
        _expectedPool = address(0);

        // H-02: Verify target price was actually reached after swap
        // If dust amount was insufficient to overcome attacker's liquidity, revert
        (uint160 postSwapPrice,,,,,) = ICLPool(pool).slot0();
        if (postSwapPrice != targetSqrtPrice) revert PriceNotReached();

        // Snapshot arbitrageur balances after swap
        uint256 arbBal0After = IERC20(token0).balanceOf(address(this));
        uint256 arbBal1After = IERC20(token1).balanceOf(address(this));

        // Return tokens to caller: remaining input + any swap output
        // Uses delta from pre-existing balance to avoid draining external donations
        uint256 return0 = arbBal0After > arbBal0Before ? arbBal0After - arbBal0Before : 0;
        uint256 return1 = arbBal1After > arbBal1Before ? arbBal1After - arbBal1Before : 0;
        if (return0 > 0) IERC20(token0).transfer(msg.sender, return0);
        if (return1 > 0) IERC20(token1).transfer(msg.sender, return1);

        // Compute actual tokens spent (only the input token can have positive spend)
        if (zeroForOne) {
            spent0 = dustAmount > return0 ? dustAmount - return0 : 0;
            spent1 = 0;
        } else {
            spent0 = 0;
            spent1 = dustAmount > return1 ? dustAmount - return1 : 0;
        }

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
