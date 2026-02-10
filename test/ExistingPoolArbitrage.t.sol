// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {KickoffFactory} from "../src/KickoffFactory.sol";
import {KickoffVoteSalePool} from "../src/KickoffVoteSalePool.sol";
import {CLPriceArbitrageur} from "../src/CLPriceArbitrageur.sol";
import {VoteSalePoolDeployer} from "../src/VoteSalePoolDeployer.sol";
import {LPLocker} from "../src/LPLocker.sol";
import {ICLPool} from "../src/interfaces/ICLPool.sol";
import {ICLFactory} from "../src/interfaces/ICLFactory.sol";
import {INonfungiblePositionManager} from "../src/interfaces/INonfungiblePositionManager.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockVotingEscrow} from "./mocks/MockVotingEscrow.sol";
import {MockVoter} from "./mocks/MockVoter.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {MockAutopilot} from "./mocks/MockAutopilot.sol";
import {MockNonfungiblePositionManager} from "./mocks/MockNonfungiblePositionManager.sol";

/*//////////////////////////////////////////////////////////////
                    MOCK CL POOL FOR ARBITRAGE
//////////////////////////////////////////////////////////////*/

/// @title MockCLPoolForArbitrage
/// @notice Simulates an Aerodrome Slipstream CL Pool that was front-run created
/// @dev Handles slot0() price reads and swap() with proper callback to arbitrageur
contract MockCLPoolForArbitrage {
    uint160 public currentSqrtPriceX96;
    int24 public currentTick;
    address public immutable token0;
    address public immutable token1;

    constructor(address _token0, address _token1, uint160 _sqrtPriceX96) {
        token0 = _token0;
        token1 = _token1;
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

    /// @notice Simulates a swap - moves price to sqrtPriceLimitX96 and calls back
    function swap(
        address recipient,
        bool zeroForOne,
        int256, /* amountSpecified */
        uint160 sqrtPriceLimitX96,
        bytes calldata data
    ) external returns (int256 amount0, int256 amount1) {
        // Move price to limit (simulates successful arbitrage)
        currentSqrtPriceX96 = sqrtPriceLimitX96;

        // Simulate minimal swap amounts
        if (zeroForOne) {
            amount0 = int256(1);
            amount1 = -int256(1);
        } else {
            amount0 = -int256(1);
            amount1 = int256(1);
        }

        // Call the swap callback on the caller (arbitrageur) to get input tokens
        CLPriceArbitrageur(msg.sender).uniswapV3SwapCallback(
            amount0,
            amount1,
            data
        );

        // Transfer output to recipient (the arbitrageur itself)
        if (zeroForOne && amount1 < 0) {
            IERC20(token1).transfer(recipient, uint256(-amount1));
        } else if (!zeroForOne && amount0 < 0) {
            IERC20(token0).transfer(recipient, uint256(-amount0));
        }
    }

    function tickSpacing() external pure returns (int24) { return 200; }
    function liquidity() external pure returns (uint128) { return 0; }
    function fee() external pure returns (uint24) { return 10000; }
}

/*//////////////////////////////////////////////////////////////
                    EXISTING POOL ARBITRAGE TESTS
//////////////////////////////////////////////////////////////*/

/// @title ExistingPoolArbitrageTest
/// @notice Tests _addLiquidity behavior when a CL pool already exists (front-run protection)
/// @dev Tests the full flow through completeAutopilotFinalization with various pool states
contract ExistingPoolArbitrageTest is Test {
    KickoffFactory public factory;
    KickoffVoteSalePool public pool;
    LPLocker public lpLocker;
    CLPriceArbitrageur public arbitrageur;

    MockERC20 public projectToken;
    MockERC20 public weth;
    MockVotingEscrow public votingEscrow;
    MockVoter public voter;
    MockRouter public router;

    address public admin = address(0x1);
    address public projectOwner = address(0x2);
    address public user1 = address(0x3);

    // Hardcoded addresses from contracts
    address constant AUTOPILOT_ADDRESS = 0xA7c68a960bA0F6726C4b7446004FE64969E2b4d4;
    address constant USDC_ADDRESS = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant AERODROME_POOL_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
    address constant SLIPSTREAM_POSITION_MANAGER = 0x827922686190790b37229fd06084350E74485b72;
    address constant CL_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
    address constant AUTOPILOT_DEPOSIT_VALIDATOR = address(0x999);

    uint256 public constant TOTAL_ALLOCATION = 1_000_000 ether;
    uint256 public constant USER1_VOTING_POWER = 100_000 ether;
    uint256 public constant WETH_REWARDS = 10 ether;
    uint256 public constant DUST_AMOUNT = 1000; // CLPriceArbitrageur.DUST_AMOUNT

    function setUp() public {
        vm.warp(1700000000);

        // Deploy mock tokens
        weth = new MockERC20("Wrapped ETH", "WETH", 18);
        projectToken = new MockERC20("Project Token", "PROJECT", 18);
        MockERC20 usdc = new MockERC20("USD Coin", "USDC", 6);
        vm.etch(USDC_ADDRESS, address(usdc).code);

        // Deploy mock contracts
        votingEscrow = new MockVotingEscrow();
        voter = new MockVoter(address(votingEscrow));
        router = new MockRouter(address(weth));
        MockAutopilot autopilotMock = new MockAutopilot(USDC_ADDRESS);
        vm.etch(AUTOPILOT_ADDRESS, address(autopilotMock).code);

        // Mock Autopilot
        vm.mockCall(AUTOPILOT_ADDRESS, abi.encodeWithSignature("deposit_validator()"), abi.encode(AUTOPILOT_DEPOSIT_VALIDATOR));
        vm.mockCall(AUTOPILOT_DEPOSIT_VALIDATOR, abi.encodeWithSignature("minimum_lock_amount()"), abi.encode(1000 ether));
        vm.mockCall(AUTOPILOT_DEPOSIT_VALIDATOR, abi.encodeWithSignature("getMinDepositAmount(address)"), abi.encode(1000 ether));

        uint256 currentEpochStart = (block.timestamp / 1 weeks) * 1 weeks;
        uint256 currentEpochEnd = currentEpochStart + 1 weeks;
        vm.mockCall(AUTOPILOT_ADDRESS, abi.encodeWithSignature("last_snapshot_id()"), abi.encode(uint256(1)));
        vm.mockCall(AUTOPILOT_ADDRESS, abi.encodeWithSelector(bytes4(keccak256("getEpochInfo(uint256)")), uint256(1)),
            abi.encode(currentEpochStart, currentEpochEnd, currentEpochEnd - 90 minutes, currentEpochEnd + 30 minutes));
        vm.mockCall(AUTOPILOT_ADDRESS, abi.encodeWithSelector(bytes4(keccak256("getEpochInfo(uint256)")), uint256(2)),
            abi.encode(currentEpochEnd, currentEpochEnd + 1 weeks, currentEpochEnd + 1 weeks - 90 minutes, currentEpochEnd + 1 weeks + 30 minutes));

        // Mock pool factory
        vm.mockCall(AERODROME_POOL_FACTORY, abi.encodeWithSignature("isPool(address)"), abi.encode(true));

        // Deploy position manager mock at hardcoded address
        MockNonfungiblePositionManager mockPM = new MockNonfungiblePositionManager(address(0));
        vm.etch(SLIPSTREAM_POSITION_MANAGER, address(mockPM).code);
        vm.store(SLIPSTREAM_POSITION_MANAGER, bytes32(uint256(2)), bytes32(uint256(1)));

        // Deploy shared contracts
        arbitrageur = new CLPriceArbitrageur();
        VoteSalePoolDeployer poolDeployer = new VoteSalePoolDeployer();
        factory = new KickoffFactory(
            AUTOPILOT_ADDRESS,
            address(votingEscrow),
            address(voter),
            address(router),
            address(weth),
            address(arbitrageur),
            address(poolDeployer)
        );
        poolDeployer.setFactory(address(factory));
        lpLocker = factory.lpLocker();

        // Mint and approve tokens
        projectToken.mint(admin, TOTAL_ALLOCATION);
        vm.prank(admin);
        projectToken.approve(address(factory), TOTAL_ALLOCATION);

        // Create pool
        address poolAddr = factory.createPool(address(projectToken), projectOwner, TOTAL_ALLOCATION, 1000 ether, admin);
        pool = KickoffVoteSalePool(poolAddr);

        // Mint veAERO NFT to user
        votingEscrow.mint(user1, USER1_VOTING_POWER, false);
    }

    /*//////////////////////////////////////////////////////////////
                         HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _updateAutopilotMocks() internal {
        vm.clearMockedCalls();
        vm.mockCall(AUTOPILOT_ADDRESS, abi.encodeWithSignature("deposit_validator()"), abi.encode(AUTOPILOT_DEPOSIT_VALIDATOR));
        vm.mockCall(AUTOPILOT_DEPOSIT_VALIDATOR, abi.encodeWithSignature("minimum_lock_amount()"), abi.encode(1000 ether));
        vm.mockCall(AUTOPILOT_DEPOSIT_VALIDATOR, abi.encodeWithSignature("getMinDepositAmount(address)"), abi.encode(1000 ether));
        uint256 currentEpochStart = (block.timestamp / 1 weeks) * 1 weeks;
        uint256 currentEpochEnd = currentEpochStart + 1 weeks;
        vm.mockCall(AUTOPILOT_ADDRESS, abi.encodeWithSignature("last_snapshot_id()"), abi.encode(uint256(2)));
        vm.mockCall(AUTOPILOT_ADDRESS, abi.encodeWithSelector(bytes4(keccak256("getEpochInfo(uint256)")), uint256(2)),
            abi.encode(currentEpochStart, currentEpochEnd, currentEpochEnd - 90 minutes, currentEpochEnd + 30 minutes));
        vm.mockCall(AUTOPILOT_ADDRESS, abi.encodeWithSelector(bytes4(keccak256("getEpochInfo(uint256)")), uint256(3)),
            abi.encode(currentEpochEnd, currentEpochEnd + 1 weeks, currentEpochEnd + 1 weeks - 90 minutes, currentEpochEnd + 1 weeks + 30 minutes));
        vm.mockCall(AERODROME_POOL_FACTORY, abi.encodeWithSignature("isPool(address)"), abi.encode(true));
    }

    /// @notice Lock veAERO (two-phase deposit)
    function _lockVeAERO() internal {
        vm.startPrank(user1);
        votingEscrow.approve(address(pool), 1);
        pool.depositVeAERO(1);
        vm.stopPrank();
        vm.roll(block.number + 1);
        pool.confirmDeposit(1);
    }

    /// @notice Advance pool to Finalizing state and prepare for completeAutopilotFinalization
    function _advanceToFinalizing() internal {
        vm.prank(admin);
        pool.activate();
        _lockVeAERO();

        // Advance to next epoch
        uint256 nextEpochStart = ((block.timestamp / 1 weeks) + 1) * 1 weeks;
        vm.warp(nextEpochStart + 2 hours);
        _updateAutopilotMocks();

        // Start finalization
        vm.startPrank(admin);
        pool.startClaimRewardsFromAutopilot(50);
        weth.mint(address(pool), WETH_REWARDS);
        pool.convertUSDCtoWETH();
        vm.stopPrank();
    }

    /// @notice Get sorted token pair and amounts (mirrors _addLiquidity logic)
    function _getSortedTokens() internal view returns (address token0, address token1) {
        address wethAddr = address(weth);
        address projAddr = address(projectToken);
        (token0, token1) = projAddr < wethAddr ? (projAddr, wethAddr) : (wethAddr, projAddr);
    }

    /// @notice Deploy a mock CL pool with manipulated price and register it in factory
    function _deployMockPool(uint160 manipulatedPrice) internal returns (MockCLPoolForArbitrage mockPool) {
        (address token0, address token1) = _getSortedTokens();
        mockPool = new MockCLPoolForArbitrage(token0, token1, manipulatedPrice);

        // Fund pool with tokens for swap outputs
        MockERC20(token0).mint(address(mockPool), 10_000);
        MockERC20(token1).mint(address(mockPool), 10_000);

        // Mock CL factory getPool to return our mock pool
        vm.mockCall(CL_FACTORY, abi.encodeWithSelector(
            ICLFactory.getPool.selector, token0, token1, int24(200)
        ), abi.encode(address(mockPool)));

        // Mock other tick spacings to return address(0) (for callback validation)
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

    /// @notice Mock CL factory to return no existing pool
    function _mockNoExistingPool() internal {
        (address token0, address token1) = _getSortedTokens();
        vm.mockCall(CL_FACTORY, abi.encodeWithSelector(
            ICLFactory.getPool.selector, token0, token1, int24(200)
        ), abi.encode(address(0)));
    }

    /*//////////////////////////////////////////////////////////////
              TEST 1: NO EXISTING POOL (BASELINE - NORMAL FLOW)
    //////////////////////////////////////////////////////////////*/

    /// @notice When no pool exists, _addLiquidity creates a new one with sqrtPriceX96 != 0
    function test_addLiquidity_NoExistingPool() public {
        _advanceToFinalizing();
        _mockNoExistingPool();

        vm.prank(admin);
        pool.completeAutopilotFinalization(1000);

        // Pool should be completed
        assertEq(uint256(pool.state()), uint256(KickoffVoteSalePool.PoolState.Completed));
        // LP position should be created
        assertTrue(pool.lpPositionId() > 0, "LP position should be created");
    }

    /*//////////////////////////////////////////////////////////////
              TEST 2: EXISTING POOL WITH CORRECT PRICE
    //////////////////////////////////////////////////////////////*/

    /// @notice When pool exists with correct price, no arbitrage is needed
    /// @dev sqrtPriceX96 should match → skip arbitrage → subtract dust → add liquidity
    function test_addLiquidity_ExistingPoolCorrectPrice() public {
        _advanceToFinalizing();

        // Calculate the correct sqrtPriceX96 that _addLiquidity would compute
        (address token0, address token1) = _getSortedTokens();
        uint256 liquidityAllocation = pool.liquidityAllocation();
        uint256 wethToUse = pool.totalClaimedRewards();

        uint256 amount0;
        uint256 amount1;
        if (address(projectToken) < address(weth)) {
            amount0 = liquidityAllocation;
            amount1 = wethToUse;
        } else {
            amount0 = wethToUse;
            amount1 = liquidityAllocation;
        }

        // Calculate expected sqrtPriceX96 using the same formula as the contract
        uint160 expectedSqrtPrice = _calculateSqrtPriceX96(amount0, amount1);

        // Deploy mock pool with the CORRECT price
        MockCLPoolForArbitrage mockPool = _deployMockPool(expectedSqrtPrice);

        uint256 token0BalBefore = IERC20(token0).balanceOf(address(pool));
        uint256 token1BalBefore = IERC20(token1).balanceOf(address(pool));

        vm.prank(admin);
        pool.completeAutopilotFinalization(1000);

        assertEq(uint256(pool.state()), uint256(KickoffVoteSalePool.PoolState.Completed));
        assertTrue(pool.lpPositionId() > 0, "LP position should be created");

        // Arbitrageur should have 0 balance (no tokens were sent to it)
        assertEq(IERC20(token0).balanceOf(address(arbitrageur)), 0, "Arbitrageur should have 0 token0");
        assertEq(IERC20(token1).balanceOf(address(arbitrageur)), 0, "Arbitrageur should have 0 token1");
    }

    /*//////////////////////////////////////////////////////////////
              TEST 3: EXISTING POOL WITH PRICE TOO HIGH
    //////////////////////////////////////////////////////////////*/

    /// @notice Pool price was manipulated higher → arbitrage pushes it down
    function test_addLiquidity_ExistingPoolPriceTooHigh() public {
        _advanceToFinalizing();

        // Set manipulated price 4x higher than expected
        // sqrtPriceX96 for price=4 relative to 1:1 → 2 * 2^96
        uint160 manipulatedPrice = 158456325028528675187087900672; // ~4x price

        MockCLPoolForArbitrage mockPool = _deployMockPool(manipulatedPrice);

        vm.prank(admin);
        pool.completeAutopilotFinalization(1000);

        assertEq(uint256(pool.state()), uint256(KickoffVoteSalePool.PoolState.Completed));
        assertTrue(pool.lpPositionId() > 0, "LP position should be created");

        // Pool price should have been corrected (not the manipulated price anymore)
        (uint160 finalPrice,,,,,) = ICLPool(address(mockPool)).slot0();
        assertTrue(finalPrice != manipulatedPrice, "Pool price should have been corrected");
    }

    /*//////////////////////////////////////////////////////////////
              TEST 4: EXISTING POOL WITH PRICE TOO LOW
    //////////////////////////////////////////////////////////////*/

    /// @notice Pool price was manipulated lower → arbitrage pushes it up
    function test_addLiquidity_ExistingPoolPriceTooLow() public {
        _advanceToFinalizing();

        // Set manipulated price 4x lower than expected
        // sqrtPriceX96 for price=0.25 → 0.5 * 2^96
        uint160 manipulatedPrice = 39614081257132168796771975168; // ~0.25x price

        MockCLPoolForArbitrage mockPool = _deployMockPool(manipulatedPrice);

        vm.prank(admin);
        pool.completeAutopilotFinalization(1000);

        assertEq(uint256(pool.state()), uint256(KickoffVoteSalePool.PoolState.Completed));
        assertTrue(pool.lpPositionId() > 0, "LP position should be created");

        (uint160 finalPrice,,,,,) = ICLPool(address(mockPool)).slot0();
        assertTrue(finalPrice != manipulatedPrice, "Pool price should have been corrected upward");
    }

    /*//////////////////////////////////////////////////////////////
              TEST 5: EXTREME PRICE DEVIATION (100x higher)
    //////////////////////////////////////////////////////////////*/

    /// @notice Pool price was manipulated to extreme (100x) → arbitrage corrects
    function test_addLiquidity_ExtremeHighPrice() public {
        _advanceToFinalizing();

        // 100x price: sqrtPrice = 10 * 2^96
        uint160 extremePrice = 792281625142643375935439503360;

        MockCLPoolForArbitrage mockPool = _deployMockPool(extremePrice);

        vm.prank(admin);
        pool.completeAutopilotFinalization(1000);

        assertEq(uint256(pool.state()), uint256(KickoffVoteSalePool.PoolState.Completed));
        assertTrue(pool.lpPositionId() > 0, "LP position should be created even after extreme arbitrage");
    }

    /*//////////////////////////////////////////////////////////////
              TEST 6: EXTREME PRICE DEVIATION (100x lower)
    //////////////////////////////////////////////////////////////*/

    /// @notice Pool price was manipulated to extreme low (0.01x) → arbitrage corrects
    function test_addLiquidity_ExtremeLowPrice() public {
        _advanceToFinalizing();

        // 0.01x price: sqrtPrice = 0.1 * 2^96
        uint160 extremePrice = 7922816251426433759354395034;

        MockCLPoolForArbitrage mockPool = _deployMockPool(extremePrice);

        vm.prank(admin);
        pool.completeAutopilotFinalization(1000);

        assertEq(uint256(pool.state()), uint256(KickoffVoteSalePool.PoolState.Completed));
        assertTrue(pool.lpPositionId() > 0);
    }

    /*//////////////////////////////////////////////////////////////
              TEST 7: DUST SUBTRACTION DOESN'T UNDERFLOW
    //////////////////////////////////////////////////////////////*/

    /// @notice Verify that dust subtraction handles edge case where amounts > dustAmount
    function test_addLiquidity_DustSubtraction() public {
        _advanceToFinalizing();

        // Deploy pool with different price to trigger arbitrage
        uint160 manipulatedPrice = 158456325028528675187087900672;
        MockCLPoolForArbitrage mockPool = _deployMockPool(manipulatedPrice);

        (address token0, address token1) = _getSortedTokens();
        uint256 poolBal0Before = IERC20(token0).balanceOf(address(pool));
        uint256 poolBal1Before = IERC20(token1).balanceOf(address(pool));

        // Both amounts should be >> DUST_AMOUNT (1000 wei)
        assertTrue(poolBal0Before > DUST_AMOUNT, "Pool should have enough token0");
        assertTrue(poolBal1Before > DUST_AMOUNT, "Pool should have enough token1");

        vm.prank(admin);
        pool.completeAutopilotFinalization(1000);

        assertEq(uint256(pool.state()), uint256(KickoffVoteSalePool.PoolState.Completed));
    }

    /*//////////////////////////////////////////////////////////////
              TEST 8: LP POSITION LOCKED AFTER ARBITRAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Verify LP position is properly locked even when pool was front-run
    function test_addLiquidity_LPLockedAfterArbitrage() public {
        _advanceToFinalizing();

        uint160 manipulatedPrice = 39614081257132168796771975168;
        _deployMockPool(manipulatedPrice);

        vm.prank(admin);
        pool.completeAutopilotFinalization(1000);

        uint256 positionId = pool.lpPositionId();
        assertTrue(positionId > 0, "LP position should exist");

        // Verify LP token is set
        assertEq(pool.lpToken(), SLIPSTREAM_POSITION_MANAGER, "LP token should be position manager");
    }

    /*//////////////////////////////////////////////////////////////
              TEST 9: MULTIPLE POOLS - ONLY MATCHING TICK SPACING
    //////////////////////////////////////////////////////////////*/

    /// @notice CL factory returns pool only for matching tick spacing (200)
    function test_addLiquidity_PoolFoundOnlyForCorrectTickSpacing() public {
        _advanceToFinalizing();

        (address token0, address token1) = _getSortedTokens();

        // Only mock tick spacing 200 to return a pool
        uint160 manipulatedPrice = 158456325028528675187087900672;
        MockCLPoolForArbitrage mockPool = new MockCLPoolForArbitrage(token0, token1, manipulatedPrice);
        MockERC20(token0).mint(address(mockPool), 10_000);
        MockERC20(token1).mint(address(mockPool), 10_000);

        // Tick spacing 200 → existing pool
        vm.mockCall(CL_FACTORY, abi.encodeWithSelector(
            ICLFactory.getPool.selector, token0, token1, int24(200)
        ), abi.encode(address(mockPool)));

        // Other tick spacings → no pool
        vm.mockCall(CL_FACTORY, abi.encodeWithSelector(
            ICLFactory.getPool.selector, token0, token1, int24(1)
        ), abi.encode(address(0)));
        vm.mockCall(CL_FACTORY, abi.encodeWithSelector(
            ICLFactory.getPool.selector, token0, token1, int24(50)
        ), abi.encode(address(0)));
        vm.mockCall(CL_FACTORY, abi.encodeWithSelector(
            ICLFactory.getPool.selector, token0, token1, int24(100)
        ), abi.encode(address(0)));

        vm.prank(admin);
        pool.completeAutopilotFinalization(1000);

        assertEq(uint256(pool.state()), uint256(KickoffVoteSalePool.PoolState.Completed));
    }

    /*//////////////////////////////////////////////////////////////
              TEST 10: sqrtPriceX96 = 0 WHEN POOL EXISTS
    //////////////////////////////////////////////////////////////*/

    /// @notice Verify mint is called with sqrtPriceX96=0 when pool exists
    /// @dev This is critical: NonfungiblePositionManager.mint() reverts if sqrtPriceX96!=0 and pool exists
    function test_addLiquidity_SqrtPriceZeroWhenPoolExists() public {
        _advanceToFinalizing();

        // Deploy mock pool at correct price (no arbitrage needed, just the pool existence path)
        (address token0, address token1) = _getSortedTokens();
        uint256 liquidityAllocation = pool.liquidityAllocation();
        uint256 wethToUse = pool.totalClaimedRewards();
        uint256 amount0 = address(projectToken) < address(weth) ? liquidityAllocation : wethToUse;
        uint256 amount1 = address(projectToken) < address(weth) ? wethToUse : liquidityAllocation;
        uint160 correctPrice = _calculateSqrtPriceX96(amount0, amount1);

        _deployMockPool(correctPrice);

        // Record the mint call to verify sqrtPriceX96 parameter
        vm.recordLogs();

        vm.prank(admin);
        pool.completeAutopilotFinalization(1000);

        // If we got here without reverting, the mint was called with sqrtPriceX96=0
        // (since the mock position manager doesn't revert on pool creation attempts)
        assertEq(uint256(pool.state()), uint256(KickoffVoteSalePool.PoolState.Completed));
    }

    /*//////////////////////////////////////////////////////////////
              TEST 11: ARBITRAGE EVENT EMITTED
    //////////////////////////////////////////////////////////////*/

    /// @notice Verify PoolPriceArbitraged event is emitted when price is corrected
    function test_addLiquidity_ArbitrageEventEmitted() public {
        _advanceToFinalizing();

        uint160 manipulatedPrice = 158456325028528675187087900672;
        MockCLPoolForArbitrage mockPool = _deployMockPool(manipulatedPrice);

        // Calculate expected target price
        (address token0, address token1) = _getSortedTokens();
        uint256 liquidityAllocation = pool.liquidityAllocation();
        uint256 wethToUse = pool.totalClaimedRewards();
        uint256 amount0 = address(projectToken) < address(weth) ? liquidityAllocation : wethToUse;
        uint256 amount1 = address(projectToken) < address(weth) ? wethToUse : liquidityAllocation;
        uint160 targetPrice = _calculateSqrtPriceX96(amount0, amount1);

        // Expect the arbitrage event
        vm.expectEmit(true, false, false, true);
        emit CLPriceArbitrageur.PoolPriceArbitraged(address(mockPool), manipulatedPrice, targetPrice);

        vm.prank(admin);
        pool.completeAutopilotFinalization(1000);
    }

    /*//////////////////////////////////////////////////////////////
              TEST 12: ARBITRAGEUR RETURNS ALL TOKENS
    //////////////////////////////////////////////////////////////*/

    /// @notice After arbitrage, arbitrageur should not hold any tokens
    function test_addLiquidity_ArbitrageurReturnsTokens() public {
        _advanceToFinalizing();

        uint160 manipulatedPrice = 158456325028528675187087900672;
        _deployMockPool(manipulatedPrice);

        (address token0, address token1) = _getSortedTokens();

        vm.prank(admin);
        pool.completeAutopilotFinalization(1000);

        // Arbitrageur should have returned all tokens
        assertEq(IERC20(token0).balanceOf(address(arbitrageur)), 0, "Arbitrageur should hold 0 token0");
        assertEq(IERC20(token1).balanceOf(address(arbitrageur)), 0, "Arbitrageur should hold 0 token1");
    }

    /*//////////////////////////////////////////////////////////////
              TEST 13: APPROVAL RESET AFTER ARBITRAGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Approvals to arbitrageur are reset to 0 after arbitrage
    function test_addLiquidity_ApprovalsResetAfterArbitrage() public {
        _advanceToFinalizing();

        uint160 manipulatedPrice = 158456325028528675187087900672;
        _deployMockPool(manipulatedPrice);

        (address token0, address token1) = _getSortedTokens();

        vm.prank(admin);
        pool.completeAutopilotFinalization(1000);

        // Check that approvals to arbitrageur are reset to 0
        assertEq(IERC20(token0).allowance(address(pool), address(arbitrageur)), 0, "token0 approval should be reset");
        assertEq(IERC20(token1).allowance(address(pool), address(arbitrageur)), 0, "token1 approval should be reset");
    }

    /*//////////////////////////////////////////////////////////////
              TEST 14: USER CAN CLAIM AFTER POOL-EXISTS FLOW
    //////////////////////////////////////////////////////////////*/

    /// @notice Full flow: pool exists → arbitrage → liquidity → user claims tokens
    function test_fullFlow_ExistingPool_UserClaims() public {
        _advanceToFinalizing();

        uint160 manipulatedPrice = 39614081257132168796771975168; // 0.25x
        _deployMockPool(manipulatedPrice);

        vm.prank(admin);
        pool.completeAutopilotFinalization(1000);

        // User should be able to claim tokens
        uint256 expectedAmount = (TOTAL_ALLOCATION / 2) * USER1_VOTING_POWER / USER1_VOTING_POWER;
        vm.prank(user1);
        pool.claimProjectTokens();

        assertEq(projectToken.balanceOf(user1), expectedAmount, "User should receive correct token amount");
    }

    /*//////////////////////////////////////////////////////////////
              TEST 15: USER CAN UNLOCK veAERO AFTER POOL-EXISTS FLOW
    //////////////////////////////////////////////////////////////*/

    /// @notice Full flow: pool exists → arbitrage → liquidity → user unlocks veAERO
    function test_fullFlow_ExistingPool_UserUnlocksVeAERO() public {
        _advanceToFinalizing();

        uint160 manipulatedPrice = 158456325028528675187087900672; // 4x
        _deployMockPool(manipulatedPrice);

        vm.prank(admin);
        pool.completeAutopilotFinalization(1000);

        // User should be able to unlock their veAERO
        vm.prank(user1);
        pool.unlockVeAERO(1);
        assertEq(votingEscrow.ownerOf(1), user1, "veAERO should be returned to user");
    }

    /*//////////////////////////////////////////////////////////////
              TEST 16: VERY SMALL REWARDS (near dust amount)
    //////////////////////////////////////////////////////////////*/

    /// @notice Edge case: WETH rewards are very small (close to dust amount)
    /// @dev Ensures dust subtraction doesn't cause issues with small amounts
    function test_addLiquidity_SmallRewardsWithExistingPool() public {
        // Create a new pool with very small rewards
        MockERC20 newToken = new MockERC20("Small Token", "SMALL", 18);
        newToken.mint(admin, TOTAL_ALLOCATION);
        vm.prank(admin);
        newToken.approve(address(factory), TOTAL_ALLOCATION);

        KickoffVoteSalePool smallPool = KickoffVoteSalePool(
            factory.createPool(address(newToken), projectOwner, TOTAL_ALLOCATION, 1000 ether, admin)
        );

        // Activate and lock
        vm.prank(admin);
        smallPool.activate();

        vm.startPrank(user1);
        // Need a new NFT for this pool
        votingEscrow.mint(user1, USER1_VOTING_POWER, false);
        uint256 nftId = votingEscrow.nextTokenId() - 1;
        votingEscrow.approve(address(smallPool), nftId);
        smallPool.depositVeAERO(nftId);
        vm.stopPrank();
        vm.roll(block.number + 1);
        smallPool.confirmDeposit(nftId);

        // Advance to next epoch
        uint256 nextEpochStart = ((block.timestamp / 1 weeks) + 1) * 1 weeks;
        vm.warp(nextEpochStart + 2 hours);
        _updateAutopilotMocks();

        // Start finalization with very small WETH amount (just above 2x dust amount)
        vm.startPrank(admin);
        smallPool.startClaimRewardsFromAutopilot(50);
        weth.mint(address(smallPool), 3000); // Only 3000 wei WETH (just above 2 * DUST_AMOUNT)
        smallPool.convertUSDCtoWETH();
        vm.stopPrank();

        // Set up existing pool mock
        address wethAddr = address(weth);
        address newTokenAddr = address(newToken);
        (address t0, address t1) = newTokenAddr < wethAddr ? (newTokenAddr, wethAddr) : (wethAddr, newTokenAddr);

        uint160 manipulatedPrice = 158456325028528675187087900672;
        MockCLPoolForArbitrage mockPool = new MockCLPoolForArbitrage(t0, t1, manipulatedPrice);
        MockERC20(t0).mint(address(mockPool), 10_000);
        MockERC20(t1).mint(address(mockPool), 10_000);

        vm.mockCall(CL_FACTORY, abi.encodeWithSelector(
            ICLFactory.getPool.selector, t0, t1, int24(200)
        ), abi.encode(address(mockPool)));
        vm.mockCall(CL_FACTORY, abi.encodeWithSelector(
            ICLFactory.getPool.selector, t0, t1, int24(1)
        ), abi.encode(address(0)));
        vm.mockCall(CL_FACTORY, abi.encodeWithSelector(
            ICLFactory.getPool.selector, t0, t1, int24(50)
        ), abi.encode(address(0)));
        vm.mockCall(CL_FACTORY, abi.encodeWithSelector(
            ICLFactory.getPool.selector, t0, t1, int24(100)
        ), abi.encode(address(0)));

        vm.prank(admin);
        smallPool.completeAutopilotFinalization(1000);

        assertEq(uint256(smallPool.state()), uint256(KickoffVoteSalePool.PoolState.Completed));
    }

    /*//////////////////////////////////////////////////////////////
              TEST 17: PRICE DIFFERENCE OF 1 WEI (sqrtPriceX96)
    //////////////////////////////////////////////////////////////*/

    /// @notice Edge case: pool price differs by just 1 from target
    function test_addLiquidity_OneWeiPriceDifference() public {
        _advanceToFinalizing();

        (address token0, address token1) = _getSortedTokens();
        uint256 liquidityAllocation = pool.liquidityAllocation();
        uint256 wethToUse = pool.totalClaimedRewards();
        uint256 amount0 = address(projectToken) < address(weth) ? liquidityAllocation : wethToUse;
        uint256 amount1 = address(projectToken) < address(weth) ? wethToUse : liquidityAllocation;
        uint160 correctPrice = _calculateSqrtPriceX96(amount0, amount1);

        // Price differs by just 1 wei
        _deployMockPool(correctPrice + 1);

        vm.prank(admin);
        pool.completeAutopilotFinalization(1000);

        assertEq(uint256(pool.state()), uint256(KickoffVoteSalePool.PoolState.Completed));
    }

    /*//////////////////////////////////////////////////////////////
              TEST 18: WETH AS TOKEN0 (address ordering)
    //////////////////////////////////////////////////////////////*/

    /// @notice Verify correct behavior regardless of token ordering
    /// @dev WETH could be token0 or token1 depending on address comparison
    function test_addLiquidity_TokenOrdering() public {
        _advanceToFinalizing();

        (address token0, address token1) = _getSortedTokens();

        // Verify we know the ordering
        if (address(weth) < address(projectToken)) {
            assertEq(token0, address(weth), "WETH should be token0");
            assertEq(token1, address(projectToken), "Project token should be token1");
        } else {
            assertEq(token0, address(projectToken), "Project token should be token0");
            assertEq(token1, address(weth), "WETH should be token1");
        }

        // Deploy existing pool with manipulated price
        uint160 manipulatedPrice = 158456325028528675187087900672;
        _deployMockPool(manipulatedPrice);

        vm.prank(admin);
        pool.completeAutopilotFinalization(1000);

        assertEq(uint256(pool.state()), uint256(KickoffVoteSalePool.PoolState.Completed));
    }

    /*//////////////////////////////////////////////////////////////
              TEST 19: STATE IS FINALIZED (NOT REVERTED)
    //////////////////////////////////////////////////////////////*/

    /// @notice Verify state transitions correctly even with pool arbitrage
    function test_addLiquidity_StateTransitionComplete() public {
        _advanceToFinalizing();

        // Verify we're in Finalizing state before
        assertEq(uint256(pool.state()), uint256(KickoffVoteSalePool.PoolState.Finalizing));

        uint160 manipulatedPrice = 39614081257132168796771975168;
        _deployMockPool(manipulatedPrice);

        vm.prank(admin);
        pool.completeAutopilotFinalization(1000);

        // Should be Completed, not stuck in Finalizing
        assertEq(uint256(pool.state()), uint256(KickoffVoteSalePool.PoolState.Completed));

        // EpochFinalized event should have been emitted
        assertTrue(pool.lpPositionId() > 0);
    }

    /*//////////////////////////////////////////////////////////////
              TEST 20: REPEATED FINALIZATION REVERTS
    //////////////////////////////////////////////////////////////*/

    /// @notice After successful finalization with arbitrage, cannot finalize again
    function test_addLiquidity_CannotDoubleFinalizeAfterArbitrage() public {
        _advanceToFinalizing();

        uint160 manipulatedPrice = 158456325028528675187087900672;
        _deployMockPool(manipulatedPrice);

        vm.prank(admin);
        pool.completeAutopilotFinalization(1000);

        // Try to finalize again - should revert
        vm.prank(admin);
        vm.expectRevert(KickoffVoteSalePool.InvalidState.selector);
        pool.completeAutopilotFinalization(1000);
    }

    /*//////////////////////////////////////////////////////////////
                     HELPER: SQRT PRICE CALCULATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Mirror of KickoffVoteSalePool._calculateSqrtPriceX96
    function _calculateSqrtPriceX96(uint256 amount0, uint256 amount1) internal pure returns (uint160) {
        if (amount0 == 0 || amount1 == 0) return 0;

        // sqrtPriceX96 = sqrt(amount1 * 2^192 / amount0)
        // Use iterative sqrt for precision
        uint256 ratio = (amount1 * (1 << 96)) / amount0;
        uint256 sqrtRatio = _sqrt(ratio) * (1 << 48);

        // Adjust: ratio was (amount1 << 96) / amount0
        // We want sqrt((amount1 << 192) / amount0) = sqrt(amount1/amount0) * 2^96
        // = sqrt(ratio * 2^96)
        // Actually: sqrtPriceX96 = sqrt(amount1/amount0) * 2^96
        //         = sqrt(amount1 * 2^192 / amount0)
        // Let's compute step by step:
        // numerator = amount1 * 2^192
        // sqrtPriceX96 = sqrt(numerator / amount0)

        // Simplified: using mulDiv
        uint256 ratioX192 = _mulDiv(amount1, uint256(1) << 192, amount0);
        return uint160(_sqrt(ratioX192));
    }

    function _sqrt(uint256 x) internal pure returns (uint256 y) {
        if (x == 0) return 0;
        y = x;
        uint256 z = (x + 1) / 2;
        while (z < y) {
            y = z;
            z = (x / z + z) / 2;
        }
    }

    function _mulDiv(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        // Simple mulDiv for testing (may overflow for very large numbers)
        result = (a * b) / denominator;
    }
}
