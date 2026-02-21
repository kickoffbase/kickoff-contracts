// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {CLPriceArbitrageur} from "../src/CLPriceArbitrageur.sol";
import {ICLPool} from "../src/interfaces/ICLPool.sol";
import {ICLFactory} from "../src/interfaces/ICLFactory.sol";
import {INonfungiblePositionManager} from "../src/interfaces/INonfungiblePositionManager.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

/// @title Mock CL Pool for testing arbitrage
/// @dev Simulates Aerodrome Slipstream CL Pool behavior
contract MockCLPool {
    uint160 public currentSqrtPriceX96;
    int24 public currentTick;
    address public token0Addr;
    address public token1Addr;

    constructor(address _token0, address _token1, uint160 _sqrtPriceX96) {
        token0Addr = _token0;
        token1Addr = _token1;
        currentSqrtPriceX96 = _sqrtPriceX96;
    }

    function slot0() external view returns (
        uint160 sqrtPriceX96,
        int24 tick,
        uint16 observationIndex,
        uint16 observationCardinality,
        uint16 observationCardinalityNext,
        bool unlocked
    ) {
        return (currentSqrtPriceX96, currentTick, 0, 1, 1, true);
    }

    function setSqrtPriceX96(uint160 _price) external {
        currentSqrtPriceX96 = _price;
    }

    /// @notice Simulates a swap - moves price to sqrtPriceLimitX96 and calls callback
    function swap(
        address recipient,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1) {
        // Move price to limit (simulates successful arbitrage)
        currentSqrtPriceX96 = sqrtPriceLimitX96;

        // Simulate minimal swap amounts (dust swap)
        if (zeroForOne) {
            amount0 = int256(1); // pool receives 1 wei of token0
            amount1 = -int256(1); // pool sends 1 wei of token1
        } else {
            amount0 = -int256(1);
            amount1 = int256(1);
        }

        // Call the swap callback to get tokens
        (address t0, address t1) = abi.decode(data, (address, address));
        CLPriceArbitrageur(msg.sender).uniswapV3SwapCallback(
            amount0,
            amount1,
            data
        );

        // Transfer output to recipient
        if (zeroForOne && amount1 < 0) {
            IERC20(token1Addr).transfer(recipient, uint256(-amount1));
        } else if (!zeroForOne && amount0 < 0) {
            IERC20(token0Addr).transfer(recipient, uint256(-amount0));
        }
    }

    function token0() external view returns (address) { return token0Addr; }
    function token1() external view returns (address) { return token1Addr; }
    function tickSpacing() external pure returns (int24) { return 2000; }
    function liquidity() external pure returns (uint128) { return 0; }
}

/// @title Mock CL Factory for testing
contract MockCLFactory {
    mapping(bytes32 => address) public pools;

    function setPool(address tokenA, address tokenB, int24 tickSpacing, address pool) external {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pools[keccak256(abi.encode(t0, t1, tickSpacing))] = pool;
    }

    function getPool(address tokenA, address tokenB, int24 tickSpacing) external view returns (address) {
        (address t0, address t1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        return pools[keccak256(abi.encode(t0, t1, tickSpacing))];
    }

    function isPool(address pool) external view returns (bool) {
        return pool != address(0); // simplified
    }
}

/// @title Mock Position Manager that handles dust liquidity
contract MockPositionManager {
    uint256 public nextTokenId = 1;
    mapping(uint256 => uint128) public positionLiquidity;

    function mint(INonfungiblePositionManager.MintParams calldata params)
        external
        returns (uint256 tokenId, uint128 liquidity, uint256 amount0, uint256 amount1)
    {
        tokenId = nextTokenId++;
        liquidity = 1; // minimal liquidity
        amount0 = params.amount0Desired > 0 ? 1 : 0;
        amount1 = params.amount1Desired > 0 ? 1 : 0;
        positionLiquidity[tokenId] = liquidity;

        // Actually take tokens from caller
        if (amount0 > 0) IERC20(params.token0).transferFrom(msg.sender, address(this), amount0);
        if (amount1 > 0) IERC20(params.token1).transferFrom(msg.sender, address(this), amount1);
    }

    function decreaseLiquidity(INonfungiblePositionManager.DecreaseLiquidityParams calldata params)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        positionLiquidity[params.tokenId] = 0;
        return (0, 0);
    }

    function collect(INonfungiblePositionManager.CollectParams calldata)
        external
        pure
        returns (uint256 amount0, uint256 amount1)
    {
        return (0, 0);
    }

    function burn(uint256 tokenId) external {
        delete positionLiquidity[tokenId];
    }

    function onERC721Received(address, address, uint256, bytes calldata) external pure returns (bytes4) {
        return this.onERC721Received.selector;
    }
}


contract CLPriceArbitrageurTest is Test {
    CLPriceArbitrageur public arbitrageur;
    MockERC20 public tokenA;
    MockERC20 public tokenB;
    address public token0;
    address public token1;

    MockCLFactory public mockFactory;
    MockPositionManager public mockPositionManager;

    // Hardcoded addresses from CLPriceArbitrageur
    address constant CL_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
    address constant CL_POSITION_MANAGER = 0x827922686190790b37229fd06084350E74485b72;

    // Common sqrt prices for testing
    // sqrtPriceX96 = sqrt(price) * 2^96
    // price = 1.0 → sqrtPriceX96 = 79228162514264337593543950336 (2^96)
    uint160 constant PRICE_1_TO_1 = 79228162514264337593543950336;
    // price = 4.0 → sqrtPriceX96 = 2 * 2^96 = 158456325028528675187087900672
    uint160 constant PRICE_4_TO_1 = 158456325028528675187087900672;
    // price = 0.25 → sqrtPriceX96 = 0.5 * 2^96 = 39614081257132168796771975168
    uint160 constant PRICE_025_TO_1 = 39614081257132168796771975168;
    // price = 100 → sqrtPriceX96 = 10 * 2^96 = 792281625142643375935439503360
    uint160 constant PRICE_100_TO_1 = 792281625142643375935439503360;
    // price = 0.01 → sqrtPriceX96 = 0.1 * 2^96 = 7922816251426433759354395034
    uint160 constant PRICE_001_TO_1 = 7922816251426433759354395034;
    // Very low price (near MIN_SQRT_RATIO)
    uint160 constant PRICE_VERY_LOW = 4295128740; // just above MIN_SQRT_RATIO
    // Very high price (near MAX_SQRT_RATIO)  
    uint160 constant PRICE_VERY_HIGH = 1461446703485210103287273052203988822378723970341; // just below MAX_SQRT_RATIO

    function setUp() public {
        // Deploy tokens
        tokenA = new MockERC20("TokenA", "TA", 18);
        tokenB = new MockERC20("TokenB", "TB", 18);

        // Sort tokens
        if (address(tokenA) < address(tokenB)) {
            token0 = address(tokenA);
            token1 = address(tokenB);
        } else {
            token0 = address(tokenB);
            token1 = address(tokenA);
        }

        // Deploy mocks
        mockFactory = new MockCLFactory();
        mockPositionManager = new MockPositionManager();

        // Place mock bytecode at hardcoded addresses using vm.etch
        vm.etch(CL_FACTORY, address(mockFactory).code);
        vm.etch(CL_POSITION_MANAGER, address(mockPositionManager).code);

        // Copy storage: we need to re-deploy mocks AT the target addresses
        // Instead, use vm.mockCall approach for factory, and etch for position manager
        // Actually, vm.etch copies code but not storage. For factory we need storage too.
        // Simplest: deploy factory at the hardcoded address by etching and using mockCall for state

        // Deploy the arbitrageur
        arbitrageur = new CLPriceArbitrageur();
    }

    /*//////////////////////////////////////////////////////////////
                         HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Create a mock pool and register it in the factory
    function _createMockPool(uint160 sqrtPriceX96) internal returns (MockCLPool pool) {
        pool = new MockCLPool(token0, token1, sqrtPriceX96);

        // Fund the pool with some tokens for swap outputs
        MockERC20(token0).mint(address(pool), 10_000);
        MockERC20(token1).mint(address(pool), 10_000);

        // Register pool in mock factory for all tick spacings (callback validation)
        // We need to mock the getPool call at the hardcoded CL_FACTORY address
        bytes memory getPoolCall = abi.encodeWithSelector(
            ICLFactory.getPool.selector, token0, token1, int24(200)
        );
        vm.mockCall(CL_FACTORY, getPoolCall, abi.encode(address(pool)));

        // Also mock for other tick spacings (callback validation checks all spacings)
        vm.mockCall(CL_FACTORY, abi.encodeWithSelector(
            ICLFactory.getPool.selector, token0, token1, int24(1)
        ), abi.encode(address(0)));
        vm.mockCall(CL_FACTORY, abi.encodeWithSelector(
            ICLFactory.getPool.selector, token0, token1, int24(50)
        ), abi.encode(address(0)));
        vm.mockCall(CL_FACTORY, abi.encodeWithSelector(
            ICLFactory.getPool.selector, token0, token1, int24(100)
        ), abi.encode(address(0)));
    }

    /// @notice Fund an address with dust amounts of both tokens
    function _fundWithDust(address target, uint256 amount) internal {
        MockERC20(token0).mint(target, amount);
        MockERC20(token1).mint(target, amount);
    }

    /*//////////////////////////////////////////////////////////////
                     TEST: POOL PRICE ALREADY CORRECT
    //////////////////////////////////////////////////////////////*/

    function test_fixPoolPrice_AlreadyCorrectPrice() public {
        uint160 targetPrice = PRICE_1_TO_1;
        MockCLPool pool = _createMockPool(targetPrice);

        // Fund caller with dust
        _fundWithDust(address(this), 1000);
        IERC20(token0).approve(address(arbitrageur), 1000);
        IERC20(token1).approve(address(arbitrageur), 1000);

        uint256 bal0Before = IERC20(token0).balanceOf(address(this));
        uint256 bal1Before = IERC20(token1).balanceOf(address(this));

        // Should return early without consuming any tokens
        arbitrageur.fixPoolPrice(address(pool), token0, token1, targetPrice, 200, 1000);

        uint256 bal0After = IERC20(token0).balanceOf(address(this));
        uint256 bal1After = IERC20(token1).balanceOf(address(this));

        // Balances should be unchanged - no tokens consumed
        assertEq(bal0After, bal0Before, "token0 balance should be unchanged");
        assertEq(bal1After, bal1Before, "token1 balance should be unchanged");
    }

    /*//////////////////////////////////////////////////////////////
              TEST: POOL PRICE TOO HIGH (need to push DOWN)
    //////////////////////////////////////////////////////////////*/

    function test_fixPoolPrice_PriceTooHigh() public {
        // Current price is 4:1, target is 1:1
        // zeroForOne = true (price too high, sell token0 to push down)
        MockCLPool pool = _createMockPool(PRICE_4_TO_1);

        _fundWithDust(address(this), 1000);
        IERC20(token0).approve(address(arbitrageur), 1000);
        IERC20(token1).approve(address(arbitrageur), 1000);

        // Mock the position manager mint to accept tokens
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.mint.selector
        ), abi.encode(uint256(1), uint128(1), uint256(1), uint256(1)));

        // Mock decreaseLiquidity, collect, burn
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.decreaseLiquidity.selector
        ), abi.encode(uint256(0), uint256(0)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.collect.selector
        ), abi.encode(uint256(0), uint256(0)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.burn.selector
        ), abi.encode());

        // Expect the event
        vm.expectEmit(true, false, false, true);
        emit CLPriceArbitrageur.PoolPriceArbitraged(address(pool), PRICE_4_TO_1, PRICE_1_TO_1);

        arbitrageur.fixPoolPrice(address(pool), token0, token1, PRICE_1_TO_1, 200, 1000);

        // Pool price should now be at target
        (uint160 newPrice,,,,,) = ICLPool(address(pool)).slot0();
        assertEq(newPrice, PRICE_1_TO_1, "Pool price should be corrected to target");
    }

    /*//////////////////////////////////////////////////////////////
              TEST: POOL PRICE TOO LOW (need to push UP)
    //////////////////////////////////////////////////////////////*/

    function test_fixPoolPrice_PriceTooLow() public {
        // Current price is 0.25:1, target is 1:1
        // zeroForOne = false (price too low, sell token1 to push up)
        MockCLPool pool = _createMockPool(PRICE_025_TO_1);

        _fundWithDust(address(this), 1000);
        IERC20(token0).approve(address(arbitrageur), 1000);
        IERC20(token1).approve(address(arbitrageur), 1000);

        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.mint.selector
        ), abi.encode(uint256(1), uint128(1), uint256(1), uint256(1)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.decreaseLiquidity.selector
        ), abi.encode(uint256(0), uint256(0)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.collect.selector
        ), abi.encode(uint256(0), uint256(0)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.burn.selector
        ), abi.encode());

        vm.expectEmit(true, false, false, true);
        emit CLPriceArbitrageur.PoolPriceArbitraged(address(pool), PRICE_025_TO_1, PRICE_1_TO_1);

        arbitrageur.fixPoolPrice(address(pool), token0, token1, PRICE_1_TO_1, 200, 1000);

        (uint160 newPrice,,,,,) = ICLPool(address(pool)).slot0();
        assertEq(newPrice, PRICE_1_TO_1, "Pool price should be corrected to target");
    }

    /*//////////////////////////////////////////////////////////////
              TEST: LARGE PRICE DEVIATION (100x higher)
    //////////////////////////////////////////////////////////////*/

    function test_fixPoolPrice_LargeDeviationHigher() public {
        // Current price is 100:1, target is 1:1
        MockCLPool pool = _createMockPool(PRICE_100_TO_1);

        _fundWithDust(address(this), 1000);
        IERC20(token0).approve(address(arbitrageur), 1000);
        IERC20(token1).approve(address(arbitrageur), 1000);

        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.mint.selector
        ), abi.encode(uint256(1), uint128(1), uint256(1), uint256(1)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.decreaseLiquidity.selector
        ), abi.encode(uint256(0), uint256(0)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.collect.selector
        ), abi.encode(uint256(0), uint256(0)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.burn.selector
        ), abi.encode());

        arbitrageur.fixPoolPrice(address(pool), token0, token1, PRICE_1_TO_1, 200, 1000);

        (uint160 newPrice,,,,,) = ICLPool(address(pool)).slot0();
        assertEq(newPrice, PRICE_1_TO_1, "Pool price should be corrected from 100x deviation");
    }

    /*//////////////////////////////////////////////////////////////
              TEST: LARGE PRICE DEVIATION (100x lower)
    //////////////////////////////////////////////////////////////*/

    function test_fixPoolPrice_LargeDeviationLower() public {
        // Current price is 0.01:1, target is 1:1
        MockCLPool pool = _createMockPool(PRICE_001_TO_1);

        _fundWithDust(address(this), 1000);
        IERC20(token0).approve(address(arbitrageur), 1000);
        IERC20(token1).approve(address(arbitrageur), 1000);

        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.mint.selector
        ), abi.encode(uint256(1), uint128(1), uint256(1), uint256(1)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.decreaseLiquidity.selector
        ), abi.encode(uint256(0), uint256(0)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.collect.selector
        ), abi.encode(uint256(0), uint256(0)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.burn.selector
        ), abi.encode());

        arbitrageur.fixPoolPrice(address(pool), token0, token1, PRICE_1_TO_1, 200, 1000);

        (uint160 newPrice,,,,,) = ICLPool(address(pool)).slot0();
        assertEq(newPrice, PRICE_1_TO_1, "Pool price should be corrected from 0.01x deviation");
    }

    /*//////////////////////////////////////////////////////////////
              TEST: TOKENS RETURNED AFTER ARBITRAGE
    //////////////////////////////////////////////////////////////*/

    function test_fixPoolPrice_ReturnsRemainingTokens() public {
        MockCLPool pool = _createMockPool(PRICE_4_TO_1);

        // Give caller exactly DUST_AMOUNT of each token
        _fundWithDust(address(this), 1000);
        IERC20(token0).approve(address(arbitrageur), 1000);
        IERC20(token1).approve(address(arbitrageur), 1000);

        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.mint.selector
        ), abi.encode(uint256(1), uint128(1), uint256(1), uint256(1)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.decreaseLiquidity.selector
        ), abi.encode(uint256(0), uint256(0)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.collect.selector
        ), abi.encode(uint256(0), uint256(0)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.burn.selector
        ), abi.encode());

        arbitrageur.fixPoolPrice(address(pool), token0, token1, PRICE_1_TO_1, 200, 1000);

        // Arbitrageur should have 0 balance after returning tokens
        assertEq(IERC20(token0).balanceOf(address(arbitrageur)), 0, "Arbitrageur should return all token0");
        assertEq(IERC20(token1).balanceOf(address(arbitrageur)), 0, "Arbitrageur should return all token1");
    }

    /*//////////////////////////////////////////////////////////////
              TEST: DIRECT SWAP WITHOUT MINT (replaces dust mint tests)
    //////////////////////////////////////////////////////////////*/

    function test_fixPoolPrice_WorksWithoutMint() public {
        // Previously tested DustArbitrageFailed on zero liquidity mint.
        // Now verifies fixPoolPrice works via direct swap without any mint.
        MockCLPool pool = _createMockPool(PRICE_4_TO_1);

        _fundWithDust(address(this), 1000);
        IERC20(token0).approve(address(arbitrageur), 1000);
        IERC20(token1).approve(address(arbitrageur), 1000);

        // No position manager mocks needed — direct swap approach
        arbitrageur.fixPoolPrice(address(pool), token0, token1, PRICE_1_TO_1, 200, 1000);

        (uint160 newPrice,,,,,) = ICLPool(address(pool)).slot0();
        assertEq(newPrice, PRICE_1_TO_1, "Pool price should be corrected without mint");
    }

    /*//////////////////////////////////////////////////////////////
              TEST: ONLY INPUT TOKEN IS TRANSFERRED FROM CALLER
    //////////////////////////////////////////////////////////////*/

    function test_fixPoolPrice_OnlyInputTokenTransferred() public {
        // For !zeroForOne (price too low → push up): only token1 should be pulled from caller
        MockCLPool pool = _createMockPool(PRICE_025_TO_1);

        _fundWithDust(address(this), 1000);
        IERC20(token0).approve(address(arbitrageur), 1000);
        IERC20(token1).approve(address(arbitrageur), 1000);

        uint256 bal0Before = IERC20(token0).balanceOf(address(this));

        arbitrageur.fixPoolPrice(address(pool), token0, token1, PRICE_1_TO_1, 200, 1000);

        uint256 bal0After = IERC20(token0).balanceOf(address(this));

        // token0 is NOT the input token for !zeroForOne, so caller's token0 should not decrease
        // (it may increase by 1 wei due to mock swap output)
        assertGe(bal0After, bal0Before, "token0 should not decrease when it's not the input token");
    }

    /*//////////////////////////////////////////////////////////////
              TEST: UNAUTHORIZED CALLBACK
    //////////////////////////////////////////////////////////////*/

    function test_uniswapV3SwapCallback_RevertUnauthorized() public {
        // Mock factory to return address(0) for all pools
        vm.mockCall(CL_FACTORY, abi.encodeWithSelector(
            ICLFactory.getPool.selector
        ), abi.encode(address(0)));

        bytes memory data = abi.encode(token0, token1);

        // Call from non-pool address should revert
        vm.expectRevert(CLPriceArbitrageur.UnauthorizedCallback.selector);
        arbitrageur.uniswapV3SwapCallback(1, 0, data);
    }

    /*//////////////////////////////////////////////////////////////
              TEST: AUTHORIZED CALLBACK WITH DIFFERENT TICK SPACINGS
    //////////////////////////////////////////////////////////////*/

    function test_uniswapV3SwapCallback_AuthorizedPool() public {
        address fakePool = address(0xBEEF);

        // Set _expectedPool (slot 0) to fakePool — simulates active fixPoolPrice execution
        vm.store(address(arbitrageur), bytes32(0), bytes32(uint256(uint160(fakePool))));

        // Fund arbitrageur with tokens (it needs tokens to transfer in callback)
        _fundWithDust(address(arbitrageur), 100);

        bytes memory data = abi.encode(token0, token1);

        // Call from the expected pool address should succeed
        vm.prank(fakePool);
        arbitrageur.uniswapV3SwapCallback(1, 0, data);

        // Token should have been transferred
        assertEq(IERC20(token0).balanceOf(fakePool), 1, "token0 should be transferred to pool");
    }

    /*//////////////////////////////////////////////////////////////
              TEST: CALLBACK WITH EXPECTED POOL (token1)
    //////////////////////////////////////////////////////////////*/

    function test_uniswapV3SwapCallback_ExpectedPool() public {
        address fakePool = address(0xCAFE);

        // Set _expectedPool (slot 0) to fakePool
        vm.store(address(arbitrageur), bytes32(0), bytes32(uint256(uint160(fakePool))));

        _fundWithDust(address(arbitrageur), 100);
        bytes memory data = abi.encode(token0, token1);

        vm.prank(fakePool);
        arbitrageur.uniswapV3SwapCallback(0, 1, data);

        assertEq(IERC20(token1).balanceOf(fakePool), 1, "token1 should be transferred to pool");
    }

    /*//////////////////////////////////////////////////////////////
              TEST: CALCULATE TICK RANGE - NORMAL
    //////////////////////////////////////////////////////////////*/

    function test_tickRange_NormalPositiveTicks() public {
        // Test via fixPoolPrice which uses _calculateTickRange internally
        // Price from tick 1000 to tick 2000 with spacing 200
        // Should produce tickLower = 800, tickUpper = 2200 (rounded outward)
        // We test this indirectly through a successful fixPoolPrice call
        MockCLPool pool = _createMockPool(PRICE_4_TO_1);

        _fundWithDust(address(this), 1000);
        IERC20(token0).approve(address(arbitrageur), 1000);
        IERC20(token1).approve(address(arbitrageur), 1000);

        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.mint.selector
        ), abi.encode(uint256(1), uint128(1), uint256(1), uint256(1)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.decreaseLiquidity.selector
        ), abi.encode(uint256(0), uint256(0)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.collect.selector
        ), abi.encode(uint256(0), uint256(0)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.burn.selector
        ), abi.encode());

        // Should not revert - tick range calculation succeeds
        arbitrageur.fixPoolPrice(address(pool), token0, token1, PRICE_1_TO_1, 200, 1000);
    }

    /*//////////////////////////////////////////////////////////////
              TEST: NEGATIVE TICK RANGE
    //////////////////////////////////////////////////////////////*/

    function test_tickRange_NegativeTicks() public {
        // Price scenario where both ticks are negative
        // 0.01 → 0.25 (both below 1:1, negative ticks)
        MockCLPool pool = _createMockPool(PRICE_001_TO_1);

        _fundWithDust(address(this), 1000);
        IERC20(token0).approve(address(arbitrageur), 1000);
        IERC20(token1).approve(address(arbitrageur), 1000);

        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.mint.selector
        ), abi.encode(uint256(1), uint128(1), uint256(1), uint256(1)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.decreaseLiquidity.selector
        ), abi.encode(uint256(0), uint256(0)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.collect.selector
        ), abi.encode(uint256(0), uint256(0)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.burn.selector
        ), abi.encode());

        // Should not revert with negative ticks
        arbitrageur.fixPoolPrice(address(pool), token0, token1, PRICE_025_TO_1, 200, 1000);

        (uint160 newPrice,,,,,) = ICLPool(address(pool)).slot0();
        assertEq(newPrice, PRICE_025_TO_1, "Price should be corrected to 0.25");
    }

    /*//////////////////////////////////////////////////////////////
              TEST: CROSS-ZERO TICK RANGE
    //////////////////////////////////////////////////////////////*/

    function test_tickRange_CrossZero() public {
        // Price from 0.25 (negative tick) to 4.0 (positive tick) - crosses tick 0
        MockCLPool pool = _createMockPool(PRICE_025_TO_1);

        _fundWithDust(address(this), 1000);
        IERC20(token0).approve(address(arbitrageur), 1000);
        IERC20(token1).approve(address(arbitrageur), 1000);

        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.mint.selector
        ), abi.encode(uint256(1), uint128(1), uint256(1), uint256(1)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.decreaseLiquidity.selector
        ), abi.encode(uint256(0), uint256(0)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.collect.selector
        ), abi.encode(uint256(0), uint256(0)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.burn.selector
        ), abi.encode());

        arbitrageur.fixPoolPrice(address(pool), token0, token1, PRICE_4_TO_1, 200, 1000);

        (uint160 newPrice,,,,,) = ICLPool(address(pool)).slot0();
        assertEq(newPrice, PRICE_4_TO_1, "Price should cross zero tick boundary");
    }

    /*//////////////////////////////////////////////////////////////
              TEST: MINIMAL PRICE DIFFERENCE (1 tick spacing)
    //////////////////////////////////////////////////////////////*/

    function test_fixPoolPrice_MinimalDifference() public {
        // Prices that differ by ~1 tick spacing
        uint160 priceA = PRICE_1_TO_1;
        uint160 priceB = PRICE_1_TO_1 + 1000000; // Very small difference

        MockCLPool pool = _createMockPool(priceA);

        _fundWithDust(address(this), 1000);
        IERC20(token0).approve(address(arbitrageur), 1000);
        IERC20(token1).approve(address(arbitrageur), 1000);

        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.mint.selector
        ), abi.encode(uint256(1), uint128(1), uint256(1), uint256(1)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.decreaseLiquidity.selector
        ), abi.encode(uint256(0), uint256(0)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.collect.selector
        ), abi.encode(uint256(0), uint256(0)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.burn.selector
        ), abi.encode());

        // Should handle minimal price difference without reverting
        arbitrageur.fixPoolPrice(address(pool), token0, token1, priceB, 200, 1000);
    }

    /*//////////////////////////////////////////////////////////////
              TEST: ERC721 RECEIVER
    //////////////////////////////////////////////////////////////*/

    function test_onERC721Received() public view {
        bytes4 selector = arbitrageur.onERC721Received(address(0), address(0), 0, "");
        assertEq(selector, bytes4(keccak256("onERC721Received(address,address,uint256,bytes)")));
    }

    /*//////////////////////////////////////////////////////////////
              TEST: SAME PRICE BOTH DIRECTIONS (no-op)
    //////////////////////////////////////////////////////////////*/

    function test_fixPoolPrice_ExactSamePrice() public {
        // Both current and target are exactly the same
        uint160 exactPrice = 123456789012345678901234567890;
        MockCLPool pool = _createMockPool(exactPrice);

        _fundWithDust(address(this), 1000);
        IERC20(token0).approve(address(arbitrageur), 1000);
        IERC20(token1).approve(address(arbitrageur), 1000);

        uint256 bal0Before = IERC20(token0).balanceOf(address(this));

        arbitrageur.fixPoolPrice(address(pool), token0, token1, exactPrice, 200, 1000);

        // Should be a no-op - no tokens consumed
        assertEq(IERC20(token0).balanceOf(address(this)), bal0Before, "No tokens should be consumed for same price");
    }

    /*//////////////////////////////////////////////////////////////
              TEST: PRICE DIFFERENCE OF 1 WEI
    //////////////////////////////////////////////////////////////*/

    function test_fixPoolPrice_OneWeiDifference() public {
        uint160 currentPrice = PRICE_1_TO_1;
        uint160 targetPrice = PRICE_1_TO_1 + 1;

        MockCLPool pool = _createMockPool(currentPrice);

        _fundWithDust(address(this), 1000);
        IERC20(token0).approve(address(arbitrageur), 1000);
        IERC20(token1).approve(address(arbitrageur), 1000);

        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.mint.selector
        ), abi.encode(uint256(1), uint128(1), uint256(1), uint256(1)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.decreaseLiquidity.selector
        ), abi.encode(uint256(0), uint256(0)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.collect.selector
        ), abi.encode(uint256(0), uint256(0)));
        vm.mockCall(CL_POSITION_MANAGER, abi.encodeWithSelector(
            INonfungiblePositionManager.burn.selector
        ), abi.encode());

        // Even 1 wei difference should trigger arbitrage
        arbitrageur.fixPoolPrice(address(pool), token0, token1, targetPrice, 200, 1000);

        (uint160 newPrice,,,,,) = ICLPool(address(pool)).slot0();
        assertEq(newPrice, targetPrice, "Should handle 1 wei price difference");
    }
}
