// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {IRouter} from "../../src/interfaces/IRouter.sol";
import {MockERC20} from "./MockERC20.sol";

/// @title MockRouter
/// @notice Mock Aerodrome Router for testing
contract MockRouter {
    address public defaultFactory;
    address public weth;

    mapping(bytes32 => address) public pools;

    constructor(address _weth) {
        weth = _weth;
        defaultFactory = address(this); // Use self as factory for simplicity
    }

    function addLiquidity(
        address tokenA,
        address tokenB,
        bool stable,
        uint256 amountADesired,
        uint256 amountBDesired,
        uint256,
        uint256,
        address to,
        uint256
    ) external returns (uint256 amountA, uint256 amountB, uint256 liquidity) {
        // Transfer tokens from sender
        MockERC20(tokenA).transferFrom(msg.sender, address(this), amountADesired);
        MockERC20(tokenB).transferFrom(msg.sender, address(this), amountBDesired);

        // Get or create pool
        address pool = poolFor(tokenA, tokenB, stable, defaultFactory);
        if (pool == address(0)) {
            pool = _createPool(tokenA, tokenB, stable);
        }

        // Mint LP tokens (simplified: 1:1 with smaller token amount)
        liquidity = amountADesired < amountBDesired ? amountADesired : amountBDesired;
        MockERC20(pool).mint(to, liquidity);

        return (amountADesired, amountBDesired, liquidity);
    }

    function addLiquidityETH(
        address token,
        bool stable,
        uint256 amountTokenDesired,
        uint256,
        uint256,
        address to,
        uint256
    ) external payable returns (uint256 amountToken, uint256 amountETH, uint256 liquidity) {
        MockERC20(token).transferFrom(msg.sender, address(this), amountTokenDesired);

        address pool = poolFor(token, weth, stable, defaultFactory);
        if (pool == address(0)) {
            pool = _createPool(token, weth, stable);
        }

        liquidity = amountTokenDesired < msg.value ? amountTokenDesired : msg.value;
        MockERC20(pool).mint(to, liquidity);

        return (amountTokenDesired, msg.value, liquidity);
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256,
        IRouter.Route[] calldata routes,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        require(routes.length > 0, "No routes");

        // Transfer input token
        MockERC20(routes[0].from).transferFrom(msg.sender, address(this), amountIn);

        // Mock swap: 1:1 ratio for simplicity
        amounts = new uint256[](routes.length + 1);
        amounts[0] = amountIn;

        for (uint256 i = 0; i < routes.length; i++) {
            amounts[i + 1] = amounts[i]; // 1:1 swap ratio
        }

        // Mint output tokens
        address outToken = routes[routes.length - 1].to;
        MockERC20(outToken).mint(to, amounts[routes.length]);

        return amounts;
    }

    function swapExactETHForTokens(
        uint256,
        IRouter.Route[] calldata routes,
        address to,
        uint256
    ) external payable returns (uint256[] memory amounts) {
        amounts = new uint256[](routes.length + 1);
        amounts[0] = msg.value;

        for (uint256 i = 0; i < routes.length; i++) {
            amounts[i + 1] = amounts[i];
        }

        address outToken = routes[routes.length - 1].to;
        MockERC20(outToken).mint(to, amounts[routes.length]);

        return amounts;
    }

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256,
        IRouter.Route[] calldata routes,
        address to,
        uint256
    ) external returns (uint256[] memory amounts) {
        MockERC20(routes[0].from).transferFrom(msg.sender, address(this), amountIn);

        amounts = new uint256[](routes.length + 1);
        amounts[0] = amountIn;

        for (uint256 i = 0; i < routes.length; i++) {
            amounts[i + 1] = amounts[i];
        }

        payable(to).transfer(amounts[routes.length]);

        return amounts;
    }

    function getAmountsOut(uint256 amountIn, IRouter.Route[] calldata routes)
        external
        pure
        returns (uint256[] memory amounts)
    {
        amounts = new uint256[](routes.length + 1);
        amounts[0] = amountIn;

        for (uint256 i = 0; i < routes.length; i++) {
            amounts[i + 1] = amounts[i]; // 1:1 ratio
        }

        return amounts;
    }

    function poolFor(address tokenA, address tokenB, bool stable, address) public view returns (address pool) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        bytes32 key = keccak256(abi.encodePacked(token0, token1, stable));
        return pools[key];
    }

    function sortTokens(address tokenA, address tokenB) public pure returns (address token0, address token1) {
        (token0, token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
    }

    function quoteLiquidity(uint256 amountA, uint256 reserveA, uint256 reserveB)
        external
        pure
        returns (uint256 amountB)
    {
        return (amountA * reserveB) / reserveA;
    }

    function getReserves(address tokenA, address tokenB, bool stable, address)
        external
        view
        returns (uint256 reserveA, uint256 reserveB)
    {
        address pool = poolFor(tokenA, tokenB, stable, defaultFactory);
        if (pool == address(0)) return (0, 0);

        // Mock reserves
        return (1000 ether, 1000 ether);
    }

    function _createPool(address tokenA, address tokenB, bool stable) internal returns (address pool) {
        (address token0, address token1) = sortTokens(tokenA, tokenB);
        bytes32 key = keccak256(abi.encodePacked(token0, token1, stable));

        // Deploy mock LP token
        string memory symbol = stable ? "sAMM" : "vAMM";
        pool = address(new MockERC20(string.concat(symbol, "-LP"), symbol, 18));

        pools[key] = pool;
        return pool;
    }

    // Allow receiving ETH
    receive() external payable {}
}

