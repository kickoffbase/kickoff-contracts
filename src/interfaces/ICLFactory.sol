// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title ICLFactory
/// @notice Interface for Aerodrome Slipstream's CL Pool Factory
interface ICLFactory {
    /// @notice Returns the pool address for a given pair of tokens and tick spacing
    /// @param tokenA First token address
    /// @param tokenB Second token address
    /// @param tickSpacing The tick spacing of the pool
    /// @return pool The pool address (address(0) if doesn't exist)
    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address pool);

    /// @notice Creates a pool for the given two tokens and tick spacing
    /// @param tokenA First token address
    /// @param tokenB Second token address
    /// @param tickSpacing The tick spacing for the pool
    /// @param sqrtPriceX96 The initial sqrt price of the pool as a Q64.96
    /// @return pool The address of the newly created pool
    function createPool(address tokenA, address tokenB, int24 tickSpacing, uint160 sqrtPriceX96)
        external
        returns (address pool);

    /// @notice Returns the tick spacing for a given fee amount
    /// @param tickSpacing The tick spacing to check
    /// @return fee The fee amount in hundredths of a bip (1 = 0.0001%)
    function tickSpacingToFee(int24 tickSpacing) external view returns (uint24 fee);

    /// @notice Check if a pool exists
    /// @param pool The pool address to check
    /// @return True if the pool exists
    function isPool(address pool) external view returns (bool);
}
