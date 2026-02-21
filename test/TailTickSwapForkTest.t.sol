// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {TickMathLib} from "../src/libraries/TickMathLib.sol";
import {ICLFactory} from "../src/interfaces/ICLFactory.sol";
import {ICLPool} from "../src/interfaces/ICLPool.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

/// @title TailTickSwapForkTest
/// @notice Tests whether a swap through a zero-liquidity tail-tick zone works on Slipstream
/// @dev H-01 fix validation: proves that a hostile pool initialized at tick 887201
///      can be corrected via a free swap through the guaranteed-empty tail zone
/// @dev Run: forge test --match-contract TailTickSwapForkTest --fork-url $BASE_RPC_URL -vvvv
contract TailTickSwapForkTest is Test {
    // ============ AERODROME SLIPSTREAM CONTRACTS (Base mainnet) ============
    address constant CL_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    // ============ TICK CONSTANTS ============
    int24 constant CL_TICK_SPACING = 200;
    int24 constant CL_MIN_TICK = -886000; // Max aligned to tickSpacing=2000
    int24 constant CL_MAX_TICK = 886000;
    // Canonical TickMath bounds: [-887272, 887272]
    // Tail zones: (886000, 887272] and [-887272, -886000)

    // ============ STATE ============
    ICLFactory clFactory = ICLFactory(CL_FACTORY);
    MockToken tokenA;
    SwapCaller swapCaller;

    function setUp() public {
        if (block.chainid != 8453) return;

        // Deploy a mock ERC20 token to pair with WETH
        tokenA = new MockToken("TestToken", "TEST");
        tokenA.mint(address(this), 1_000_000 ether);

        // Deploy a helper contract that can receive swap callbacks
        swapCaller = new SwapCaller();
    }

    // ============ HELPERS ============

    /// @notice Sort tokens as required by CL pools
    function _sortTokens() internal view returns (address token0, address token1) {
        (token0, token1) = address(tokenA) < WETH
            ? (address(tokenA), WETH)
            : (WETH, address(tokenA));
    }

    /// @notice Create a hostile pool at a specific tail tick
    function _createHostilePool(int24 tailTick) internal returns (address pool) {
        (address token0, address token1) = _sortTokens();
        uint160 hostileSqrtPrice = TickMathLib.getSqrtRatioAtTick(tailTick);

        pool = clFactory.createPool(token0, token1, CL_TICK_SPACING, hostileSqrtPrice);
        assertTrue(pool != address(0), "Pool should be created");

        console.log("Created hostile pool at:", pool);
        console.log("  Tail tick:", uint256(uint24(tailTick)));
        console.log("  sqrtPriceX96:", uint256(hostileSqrtPrice));
    }

    /// @notice Read and log pool state
    function _logPoolState(address pool, string memory label) internal view {
        (uint160 sqrtPrice, int24 tick,,,,) = ICLPool(pool).slot0();
        uint128 liq = ICLPool(pool).liquidity();
        console.log(label);
        console.log("  sqrtPriceX96:", uint256(sqrtPrice));
        console.log("  tick:", tick >= 0 ? uint256(uint24(tick)) : uint256(uint24(-tick)));
        console.log("  tick is negative:", tick < 0);
        console.log("  liquidity:", uint256(liq));
    }

    // ============ TEST 1: Swap through UPPER tail zone (tick > 886000) ============

    /// @notice Hostile pool at tick 887201 — swap should bring price back into range for free
    function test_swapThroughUpperTailZone() public {
        if (block.chainid != 8453) { vm.skip(true); return; }

        console.log("");
        console.log("================================================================");
        console.log("  TEST: Swap through UPPER tail zone (tick 887201)");
        console.log("================================================================");
        console.log("");

        // Step 1: Create hostile pool at tick 887201
        address pool = _createHostilePool(887201);
        _logPoolState(pool, "BEFORE swap:");

        // Verify tick is in the tail zone
        (, int24 tickBefore,,,,) = ICLPool(pool).slot0();
        assertTrue(tickBefore > CL_MAX_TICK, "Tick should be above CL_MAX_TICK (886000)");

        // Step 2: Determine swap direction and target
        // Tick 887201 is above range → need to push price DOWN → zeroForOne = true
        // Target: bring price to tick 0 (neutral) for simplicity
        uint160 targetSqrtPrice = TickMathLib.getSqrtRatioAtTick(0);
        (address token0, address token1) = _sortTokens();

        // Fund the swap caller with some tokens for the callback
        // (shouldn't need any since zone is empty, but provide some just in case)
        deal(token0, address(swapCaller), 10_000);
        deal(token1, address(swapCaller), 10_000);

        uint256 bal0Before = IERC20(token0).balanceOf(address(swapCaller));
        uint256 bal1Before = IERC20(token1).balanceOf(address(swapCaller));

        // Step 3: Execute swap — should move price through empty tail zone
        console.log("");
        console.log("Executing swap (zeroForOne=true, amountSpecified=1)...");

        bool success = swapCaller.trySwap(
            pool,
            true, // zeroForOne (push price down)
            int256(1), // minimal input
            targetSqrtPrice,
            token0,
            token1
        );

        assertTrue(success, "Swap should succeed through zero-liquidity tail zone");

        // Step 4: Verify price moved
        _logPoolState(pool, "AFTER swap:");

        (uint160 sqrtPriceAfter, int24 tickAfter,,,,) = ICLPool(pool).slot0();

        console.log("");
        console.log("RESULTS:");
        console.log("  Price reached target:", sqrtPriceAfter == targetSqrtPrice);
        console.log("  Tick now in range:", tickAfter >= CL_MIN_TICK && tickAfter <= CL_MAX_TICK);

        // Check token balances — should be unchanged (free swap)
        uint256 bal0After = IERC20(token0).balanceOf(address(swapCaller));
        uint256 bal1After = IERC20(token1).balanceOf(address(swapCaller));
        console.log("  Token0 spent:", bal0Before - bal0After);
        console.log("  Token1 spent:", bal1Before - bal1After);

        // Assert: price should have moved to target (or very close)
        assertEq(sqrtPriceAfter, targetSqrtPrice, "Price should reach target exactly");
        assertTrue(tickAfter >= CL_MIN_TICK && tickAfter <= CL_MAX_TICK, "Tick should be in supported range");
    }

    // ============ TEST 2: Swap through LOWER tail zone (tick < -886000) ============

    /// @notice Hostile pool at tick -887201 — swap should bring price back into range for free
    function test_swapThroughLowerTailZone() public {
        if (block.chainid != 8453) { vm.skip(true); return; }

        console.log("");
        console.log("================================================================");
        console.log("  TEST: Swap through LOWER tail zone (tick -887201)");
        console.log("================================================================");
        console.log("");

        // Step 1: Create hostile pool at tick -887201
        address pool = _createHostilePool(-887201);
        _logPoolState(pool, "BEFORE swap:");

        // Verify tick is in the tail zone
        (, int24 tickBefore,,,,) = ICLPool(pool).slot0();
        assertTrue(tickBefore < CL_MIN_TICK, "Tick should be below CL_MIN_TICK (-886000)");

        // Step 2: Swap direction — need to push price UP → zeroForOne = false
        uint160 targetSqrtPrice = TickMathLib.getSqrtRatioAtTick(0);
        (address token0, address token1) = _sortTokens();

        deal(token0, address(swapCaller), 10_000);
        deal(token1, address(swapCaller), 10_000);

        uint256 bal0Before = IERC20(token0).balanceOf(address(swapCaller));
        uint256 bal1Before = IERC20(token1).balanceOf(address(swapCaller));

        // Step 3: Execute swap
        console.log("");
        console.log("Executing swap (zeroForOne=false, amountSpecified=1)...");

        bool success = swapCaller.trySwap(
            pool,
            false, // !zeroForOne (push price up)
            int256(1),
            targetSqrtPrice,
            token0,
            token1
        );

        assertTrue(success, "Swap should succeed through zero-liquidity lower tail zone");

        // Step 4: Verify
        _logPoolState(pool, "AFTER swap:");

        (uint160 sqrtPriceAfter, int24 tickAfter,,,,) = ICLPool(pool).slot0();

        console.log("");
        console.log("RESULTS:");
        console.log("  Price reached target:", sqrtPriceAfter == targetSqrtPrice);
        console.log("  Tick now in range:", tickAfter >= CL_MIN_TICK && tickAfter <= CL_MAX_TICK);

        uint256 bal0After = IERC20(token0).balanceOf(address(swapCaller));
        uint256 bal1After = IERC20(token1).balanceOf(address(swapCaller));
        console.log("  Token0 spent:", bal0Before - bal0After);
        console.log("  Token1 spent:", bal1Before - bal1After);

        assertEq(sqrtPriceAfter, targetSqrtPrice, "Price should reach target exactly");
        assertTrue(tickAfter >= CL_MIN_TICK && tickAfter <= CL_MAX_TICK, "Tick should be in supported range");
    }

    // ============ TEST 3: Swap at MAX usable tail tick (887271) ============

    /// @notice Extreme case: pool at the highest usable tail tick
    /// @dev 887272 is rejected by pool.initialize() because getSqrtRatioAtTick(887272) == MAX_SQRT_RATIO
    ///      and initialize requires sqrtPriceX96 < MAX_SQRT_RATIO (strictly less)
    ///      So the actual worst case for the attacker is tick 887271
    function test_swapFromMaxUsableTailTick() public {
        if (block.chainid != 8453) { vm.skip(true); return; }

        console.log("");
        console.log("================================================================");
        console.log("  TEST: Swap from MAX usable tail tick (887271)");
        console.log("================================================================");
        console.log("");

        // 887271 is the highest tick an attacker can actually use
        // (887272 reverts on createPool because sqrtPrice == MAX_SQRT_RATIO)
        address pool = _createHostilePool(887271);
        _logPoolState(pool, "BEFORE swap:");

        uint160 targetSqrtPrice = TickMathLib.getSqrtRatioAtTick(0);
        (address token0, address token1) = _sortTokens();

        deal(token0, address(swapCaller), 10_000);
        deal(token1, address(swapCaller), 10_000);

        bool success = swapCaller.trySwap(pool, true, int256(1), targetSqrtPrice, token0, token1);

        assertTrue(success, "Swap should succeed from max usable tail tick");

        (uint160 sqrtPriceAfter, int24 tickAfter,,,,) = ICLPool(pool).slot0();
        _logPoolState(pool, "AFTER swap:");

        assertEq(sqrtPriceAfter, targetSqrtPrice, "Price should reach target");
    }

    // ============ TEST 4: Swap at MIN tail tick (-887272) ============

    /// @notice Extreme case: pool at the absolute minimum canonical tick
    function test_swapFromMinCanonicalTick() public {
        if (block.chainid != 8453) { vm.skip(true); return; }

        console.log("");
        console.log("================================================================");
        console.log("  TEST: Swap from MIN canonical tick (-887272)");
        console.log("================================================================");
        console.log("");

        address pool = _createHostilePool(-887272);
        _logPoolState(pool, "BEFORE swap:");

        uint160 targetSqrtPrice = TickMathLib.getSqrtRatioAtTick(0);
        (address token0, address token1) = _sortTokens();

        deal(token0, address(swapCaller), 10_000);
        deal(token1, address(swapCaller), 10_000);

        bool success = swapCaller.trySwap(pool, false, int256(1), targetSqrtPrice, token0, token1);

        assertTrue(success, "Swap should succeed from min canonical tick");

        (uint160 sqrtPriceAfter,,,,,) = ICLPool(pool).slot0();
        assertEq(sqrtPriceAfter, targetSqrtPrice, "Price should reach target");
    }

    // ============ TEST 5: Verify zero tokens spent (free swap) ============

    /// @notice Confirm the swap costs zero tokens when traversing empty pool
    function test_swapCostsZeroTokens() public {
        if (block.chainid != 8453) { vm.skip(true); return; }

        console.log("");
        console.log("================================================================");
        console.log("  TEST: Verify swap costs ZERO tokens");
        console.log("================================================================");
        console.log("");

        address pool = _createHostilePool(887201);
        uint160 targetSqrtPrice = TickMathLib.getSqrtRatioAtTick(100); // Arbitrary target in range
        (address token0, address token1) = _sortTokens();

        // Give exactly 100 of each token — track precisely
        deal(token0, address(swapCaller), 100);
        deal(token1, address(swapCaller), 100);

        uint256 bal0Before = IERC20(token0).balanceOf(address(swapCaller));
        uint256 bal1Before = IERC20(token1).balanceOf(address(swapCaller));

        swapCaller.trySwap(pool, true, int256(1), targetSqrtPrice, token0, token1);

        uint256 bal0After = IERC20(token0).balanceOf(address(swapCaller));
        uint256 bal1After = IERC20(token1).balanceOf(address(swapCaller));

        uint256 token0Spent = bal0Before - bal0After;
        uint256 token1Spent = bal1Before - bal1After;

        console.log("Token0 spent:", token0Spent);
        console.log("Token1 spent:", token1Spent);

        // Both should be 0 — the swap traverses zero-liquidity zones for free
        assertEq(token0Spent, 0, "Token0 should not be spent (zero liquidity path)");
        assertEq(token1Spent, 0, "Token1 should not be spent (zero liquidity path)");
    }

    // ============ TEST 6: Verify it works with realistic target price ============

    /// @notice Use a realistic target price (not tick 0) that mimics real pool deployment
    function test_swapToRealisticTargetPrice() public {
        if (block.chainid != 8453) { vm.skip(true); return; }

        console.log("");
        console.log("================================================================");
        console.log("  TEST: Swap to a realistic target price");
        console.log("================================================================");
        console.log("");

        address pool = _createHostilePool(887201);

        // Simulate a realistic price: 1 WETH = 500,000 project tokens
        // This represents a small-cap token launch
        // tick for this ratio depends on token ordering
        int24 realisticTick = -50000; // Some realistic tick
        uint160 targetSqrtPrice = TickMathLib.getSqrtRatioAtTick(realisticTick);

        (address token0, address token1) = _sortTokens();
        deal(token0, address(swapCaller), 10_000);
        deal(token1, address(swapCaller), 10_000);

        bool success = swapCaller.trySwap(pool, true, int256(1), targetSqrtPrice, token0, token1);
        assertTrue(success, "Swap to realistic target should succeed");

        (uint160 sqrtPriceAfter, int24 tickAfter,,,,) = ICLPool(pool).slot0();
        assertEq(sqrtPriceAfter, targetSqrtPrice, "Should reach realistic target price");
        console.log("Final tick:", tickAfter >= 0 ? uint256(uint24(tickAfter)) : uint256(uint24(-tickAfter)));
        console.log("Tick is negative:", tickAfter < 0);
    }

    // ============ TEST 7: Gas measurement for tail-zone traversal ============

    /// @notice Measure gas cost of swapping through the entire empty tick bitmap
    function test_gasForTailZoneSwap() public {
        if (block.chainid != 8453) { vm.skip(true); return; }

        console.log("");
        console.log("================================================================");
        console.log("  TEST: Gas measurement for tail-zone swap");
        console.log("================================================================");
        console.log("");

        address pool = _createHostilePool(887271); // Worst usable case
        uint160 targetSqrtPrice = TickMathLib.getSqrtRatioAtTick(0);
        (address token0, address token1) = _sortTokens();

        deal(token0, address(swapCaller), 10_000);
        deal(token1, address(swapCaller), 10_000);

        uint256 gasBefore = gasleft();
        swapCaller.trySwap(pool, true, int256(1), targetSqrtPrice, token0, token1);
        uint256 gasUsed = gasBefore - gasleft();

        console.log("Gas used for full tail-zone traversal (tick 887271 -> 0):", gasUsed);
        console.log("This traverses ~4436 tick positions / ~17 bitmap words");

        // Sanity check: should be less than 5M gas (well within block limits)
        assertTrue(gasUsed < 5_000_000, "Gas should be reasonable for block limits");
    }
}

/// @title SwapCaller
/// @notice Helper contract that can call pool.swap() and handle the callback
/// @dev Needed because pool.swap() calls uniswapV3SwapCallback on msg.sender
contract SwapCaller {

    /// @notice Try to execute a swap, returning success/failure
    function trySwap(
        address pool,
        bool zeroForOne,
        int256 amountSpecified,
        uint160 sqrtPriceLimitX96,
        address token0,
        address token1
    ) external returns (bool success) {
        try ICLPool(pool).swap(
            address(this),
            zeroForOne,
            amountSpecified,
            sqrtPriceLimitX96,
            abi.encode(token0, token1)
        ) returns (int256, int256) {
            return true;
        } catch {
            return false;
        }
    }

    /// @notice Callback from Slipstream pool during swap
    /// @dev Pays the pool whatever it asks for (should be 0 for zero-liquidity zones)
    function uniswapV3SwapCallback(
        int256 amount0Delta,
        int256 amount1Delta,
        bytes calldata data
    ) external {
        (address token0, address token1) = abi.decode(data, (address, address));

        if (amount0Delta > 0) {
            IERC20(token0).transfer(msg.sender, uint256(amount0Delta));
        }
        if (amount1Delta > 0) {
            IERC20(token1).transfer(msg.sender, uint256(amount1Delta));
        }
    }
}

/// @title MockToken
/// @notice Simple ERC20 for testing (deployed on fork)
contract MockToken {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient");
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amount, "Allowance");
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
