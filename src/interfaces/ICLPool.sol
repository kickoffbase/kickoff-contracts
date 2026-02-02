// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ICLPool
/// @notice Interface for Aerodrome Slipstream CL Pool
interface ICLPool {
    /// @notice The first of the two tokens of the pool, sorted by address
    function token0() external view returns (address);

    /// @notice The second of the two tokens of the pool, sorted by address
    function token1() external view returns (address);

    /// @notice The pool tick spacing
    function tickSpacing() external view returns (int24);

    /// @notice The pool's fee in hundredths of a bip (1 = 0.0001%)
    function fee() external view returns (uint24);

    /// @notice The 0th storage slot in the pool stores many values
    /// @return sqrtPriceX96 The current price of the pool as a sqrt(token1/token0) Q64.96 value
    /// @return tick The current tick of the pool
    /// @return observationIndex The index of the last oracle observation
    /// @return observationCardinality The current maximum number of observations stored
    /// @return observationCardinalityNext The next maximum number of observations
    /// @return unlocked Whether the pool is currently locked to reentrancy
    function slot0()
        external
        view
        returns (
            uint160 sqrtPriceX96,
            int24 tick,
            uint16 observationIndex,
            uint16 observationCardinality,
            uint16 observationCardinalityNext,
            bool unlocked
        );

    /// @notice The currently in range liquidity available to the pool
    function liquidity() external view returns (uint128);

    /// @notice Look up information about a specific tick
    function ticks(int24 tick)
        external
        view
        returns (
            uint128 liquidityGross,
            int128 liquidityNet,
            uint256 feeGrowthOutside0X128,
            uint256 feeGrowthOutside1X128,
            int56 tickCumulativeOutside,
            uint160 secondsPerLiquidityOutsideX128,
            uint32 secondsOutside,
            bool initialized
        );
}
