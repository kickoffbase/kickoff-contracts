// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/// @title IRouter
/// @notice Interface for Aerodrome's Router contract
interface IRouter {
    struct Route {
        address from;
        address to;
        bool stable;
        address factory;
    }

    /// @notice Add liquidity to a pool
    /// @param tokenA First token address
    /// @param tokenB Second token address
    /// @param stable Whether the pool is stable or volatile
    /// @param amountADesired Desired amount of tokenA
    /// @param amountBDesired Desired amount of tokenB
    /// @param amountAMin Minimum amount of tokenA
    /// @param amountBMin Minimum amount of tokenB
    /// @param to Recipient of LP tokens
    /// @param deadline Transaction deadline
    /// @return amountA Actual amount of tokenA added
    /// @return amountB Actual amount of tokenB added
    /// @return liquidity Amount of LP tokens minted
    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256 amountAMin,
        uint256 amountBMin,
        address to,
        uint256 deadline
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity);

    /// @notice Add liquidity with ETH
    /// @param token Token address
    /// @param stable Whether the pool is stable or volatile
    /// @param amountTokenDesired Desired amount of token
    /// @param amountTokenMin Minimum amount of token
    /// @param amountETHMin Minimum amount of ETH
    /// @param to Recipient of LP tokens
    /// @param deadline Transaction deadline
    /// @return amountToken Actual amount of token added
    /// @return amountETH Actual amount of ETH added
    /// @return liquidity Amount of LP tokens minted
    function addLiquidityETH(
        address token,
        bool stable,
        uint256 amountTokenDesired,
        uint256 amountTokenMin,
        uint256 amountETHMin,
        address to,
        uint256 deadline
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity);

    /// @notice Swap exact tokens for tokens
    /// @param amountIn Amount of input tokens
    /// @param amountOutMin Minimum amount of output tokens
    /// @param routes Array of swap routes
    /// @param to Recipient of output tokens
    /// @param deadline Transaction deadline
    /// @return amounts Array of amounts for each swap
    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /// @notice Swap exact ETH for tokens
    /// @param amountOutMin Minimum amount of output tokens
    /// @param routes Array of swap routes
    /// @param to Recipient of output tokens
    /// @param deadline Transaction deadline
    /// @return amounts Array of amounts for each swap
    function swapExactETHForTokens(
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external payable returns (uint256[] memory amounts);

    /// @notice Swap exact tokens for ETH
    /// @param amountIn Amount of input tokens
    /// @param amountOutMin Minimum amount of ETH
    /// @param routes Array of swap routes
    /// @param to Recipient of ETH
    /// @param deadline Transaction deadline
    /// @return amounts Array of amounts for each swap
    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        Route[] calldata routes,
        address to,
        uint256 deadline
    ) external returns (uint256[] memory amounts);

    /// @notice Get amounts out for a swap
    /// @param amountIn Amount of input tokens
    /// @param routes Array of swap routes
    /// @return amounts Array of amounts for each step
    function getAmountsOut(uint256 amountIn, Route[] calldata routes) external view returns (uint256[] memory amounts);

    /// @notice Get the pool for a pair
    /// @param tokenA First token
    /// @param tokenB Second token
    /// @param stable Whether stable or volatile
    /// @return pool The pool address
    function poolFor(address tokenA, address tokenB, bool stable, address factory) external view returns (address pool);

    /// @notice Get the default factory
    /// @return The default factory address
    function defaultFactory() external view returns (address);

    /// @notice Get the WETH address
    /// @return The WETH address
    function weth() external view returns (address);

    /// @notice Sort tokens
    /// @param tokenA First token
    /// @param tokenB Second token
    /// @return token0 Sorted first token
    /// @return token1 Sorted second token
    function sortTokens(address tokenA, address tokenB) external pure returns (address token0, address token1);

    /// @notice Quote liquidity
    /// @param amountA Amount of tokenA
    /// @param reserveA Reserve of tokenA
    /// @param reserveB Reserve of tokenB
    /// @return amountB Amount of tokenB
    function quoteLiquidity(
        uint256 amountA,
        uint256 reserveA,
        uint256 reserveB
    ) external pure returns (uint256 amountB);

    /// @notice Get reserves for a pool
    /// @param tokenA First token
    /// @param tokenB Second token
    /// @param stable Whether stable or volatile
    /// @param factory Factory address
    /// @return reserveA Reserve of tokenA
    /// @return reserveB Reserve of tokenB
    function getReserves(
        address tokenA,
        address tokenB,
        bool stable,
        address factory
    ) external view returns (uint256 reserveA, uint256 reserveB);
}

