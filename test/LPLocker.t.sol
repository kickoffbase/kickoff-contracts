// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {LPLocker} from "../src/LPLocker.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockNonfungiblePositionManager} from "./mocks/MockNonfungiblePositionManager.sol";
import {MockKickoffFactory} from "./mocks/MockKickoffFactory.sol";

contract LPLockerTest is Test {
    LPLocker public lpLocker;
    MockKickoffFactory public mockFactory;
    MockNonfungiblePositionManager public mockPositionManager;
    MockERC20 public token0;
    MockERC20 public token1;

    address public votePool = address(0x1);
    address public admin = address(0x2);
    address public projectOwner = address(0x3);
    address public randomUser = address(0x4);

    uint128 public constant LIQUIDITY = 1000 ether;
    uint128 public constant FEES_AMOUNT = 100 ether;
    
    // Position ID created for testing
    uint256 public testPositionId;

    // Slipstream position manager address on Base
    address constant SLIPSTREAM_POSITION_MANAGER = 0x827922686190790b37229fd06084350E74485b72;

    function setUp() public {
        // Deploy contracts
        lpLocker = new LPLocker();
        mockFactory = new MockKickoffFactory();
        token0 = new MockERC20("Token0", "T0", 18);
        token1 = new MockERC20("Token1", "T1", 18);
        
        // Deploy mock position manager
        mockPositionManager = new MockNonfungiblePositionManager(address(0));
        
        // Mock the position manager at the hardcoded address
        vm.etch(SLIPSTREAM_POSITION_MANAGER, address(mockPositionManager).code);

        // Setup factory relationship
        lpLocker.setFactory(address(mockFactory));
        mockFactory.setPool(votePool, true);
        
        // Create a test position owned by votePool
        vm.prank(votePool);
        testPositionId = MockNonfungiblePositionManager(SLIPSTREAM_POSITION_MANAGER).createPosition(
            votePool,
            address(token0),
            address(token1),
            200, // 1% fee tier
            LIQUIDITY
        );
    }

    /*//////////////////////////////////////////////////////////////
                           LOCK POSITION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_LockPosition() public {
        vm.startPrank(votePool);
        MockNonfungiblePositionManager(SLIPSTREAM_POSITION_MANAGER).approve(address(lpLocker), testPositionId);
        lpLocker.lockPosition(testPositionId, admin, projectOwner);
        vm.stopPrank();

        // Verify lock
        LPLocker.LockedPosition memory locked = lpLocker.getLockedPosition(votePool);
        assertEq(locked.positionId, testPositionId);
        assertEq(locked.token0, address(token0));
        assertEq(locked.token1, address(token1));
        assertEq(locked.admin, admin);
        assertEq(locked.projectOwner, projectOwner);
        assertEq(locked.liquidity, LIQUIDITY);
        assertTrue(locked.exists);

        // Verify position transferred
        assertEq(MockNonfungiblePositionManager(SLIPSTREAM_POSITION_MANAGER).ownerOf(testPositionId), address(lpLocker));

        // Verify tracking
        assertEq(lpLocker.getVotePoolCount(), 1);
        assertEq(lpLocker.getAllVotePools()[0], votePool);
    }

    function test_LockPosition_RevertZeroAddress() public {
        vm.startPrank(votePool);
        MockNonfungiblePositionManager(SLIPSTREAM_POSITION_MANAGER).approve(address(lpLocker), testPositionId);

        vm.expectRevert(LPLocker.ZeroAddress.selector);
        lpLocker.lockPosition(testPositionId, address(0), projectOwner);

        vm.expectRevert(LPLocker.ZeroAddress.selector);
        lpLocker.lockPosition(testPositionId, admin, address(0));

        vm.stopPrank();
    }

    function test_LockPosition_RevertAlreadyLocked() public {
        vm.startPrank(votePool);
        MockNonfungiblePositionManager(SLIPSTREAM_POSITION_MANAGER).approve(address(lpLocker), testPositionId);
        lpLocker.lockPosition(testPositionId, admin, projectOwner);
        
        // Create another position
        uint256 anotherPosition = MockNonfungiblePositionManager(SLIPSTREAM_POSITION_MANAGER).createPosition(
            votePool,
            address(token0),
            address(token1),
            200,
            LIQUIDITY
        );
        MockNonfungiblePositionManager(SLIPSTREAM_POSITION_MANAGER).approve(address(lpLocker), anotherPosition);

        vm.expectRevert(LPLocker.AlreadyLocked.selector);
        lpLocker.lockPosition(anotherPosition, admin, projectOwner);

        vm.stopPrank();
    }

    function test_LockPosition_RevertNotVoteSalePool() public {
        address attacker = address(0x999);
        
        // Create position for attacker
        vm.prank(attacker);
        uint256 attackerPosition = MockNonfungiblePositionManager(SLIPSTREAM_POSITION_MANAGER).createPosition(
            attacker,
            address(token0),
            address(token1),
            200,
            LIQUIDITY
        );

        vm.startPrank(attacker);
        MockNonfungiblePositionManager(SLIPSTREAM_POSITION_MANAGER).approve(address(lpLocker), attackerPosition);

        vm.expectRevert(LPLocker.NotVoteSalePool.selector);
        lpLocker.lockPosition(attackerPosition, attacker, attacker);

        vm.stopPrank();
    }

    function test_LockPosition_RevertFactoryNotSet() public {
        LPLocker freshLocker = new LPLocker();
        
        vm.startPrank(votePool);
        MockNonfungiblePositionManager(SLIPSTREAM_POSITION_MANAGER).approve(address(freshLocker), testPositionId);

        vm.expectRevert(LPLocker.FactoryNotSet.selector);
        freshLocker.lockPosition(testPositionId, admin, projectOwner);

        vm.stopPrank();
    }

    function test_SetFactory_RevertAlreadySet() public {
        vm.expectRevert(LPLocker.FactoryAlreadySet.selector);
        lpLocker.setFactory(address(0x123));
    }

    function test_SetFactory_RevertZeroAddress() public {
        LPLocker freshLocker = new LPLocker();
        
        vm.expectRevert(LPLocker.ZeroAddress.selector);
        freshLocker.setFactory(address(0));
    }

    function test_SetFactory_RevertNotDeployer() public {
        LPLocker freshLocker = new LPLocker();
        
        vm.prank(address(0x999));
        vm.expectRevert(LPLocker.NotDeployer.selector);
        freshLocker.setFactory(address(mockFactory));
    }

    /*//////////////////////////////////////////////////////////////
                       CLAIM TRADING FEES TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ClaimTradingFees_ByAdmin() public {
        _lockPosition();

        // Set owed fees on position
        MockNonfungiblePositionManager(SLIPSTREAM_POSITION_MANAGER).setTokensOwed(
            testPositionId, 
            FEES_AMOUNT, 
            FEES_AMOUNT
        );
        
        // Mint tokens to locker (simulates fee collection)
        token0.mint(address(lpLocker), FEES_AMOUNT);
        token1.mint(address(lpLocker), FEES_AMOUNT);

        // Claim fees
        lpLocker.claimTradingFees(votePool);

        // Verify fees are accrued
        uint256 expectedAdminShare = (uint256(FEES_AMOUNT) * 3000) / 10000; // 30%
        uint256 expectedProjectShare = uint256(FEES_AMOUNT) - expectedAdminShare; // 70%
        
        (uint256 adminBal0, uint256 projectBal0) = lpLocker.getAccruedFees(votePool, address(token0));
        (uint256 adminBal1, uint256 projectBal1) = lpLocker.getAccruedFees(votePool, address(token1));
        
        assertEq(adminBal0, expectedAdminShare);
        assertEq(adminBal1, expectedAdminShare);
        assertEq(projectBal0, expectedProjectShare);
        assertEq(projectBal1, expectedProjectShare);
        
        // Admin withdraws their fees
        vm.startPrank(admin);
        lpLocker.withdrawAdminFees(votePool, address(token0), admin);
        lpLocker.withdrawAdminFees(votePool, address(token1), admin);
        vm.stopPrank();
        
        // Project owner withdraws their fees
        vm.startPrank(projectOwner);
        lpLocker.withdrawProjectFees(votePool, address(token0), projectOwner);
        lpLocker.withdrawProjectFees(votePool, address(token1), projectOwner);
        vm.stopPrank();

        assertEq(token0.balanceOf(admin), expectedAdminShare);
        assertEq(token1.balanceOf(admin), expectedAdminShare);
        assertEq(token0.balanceOf(projectOwner), expectedProjectShare);
        assertEq(token1.balanceOf(projectOwner), expectedProjectShare);
    }

    function test_ClaimTradingFees_ByProjectOwner() public {
        _lockPosition();

        MockNonfungiblePositionManager(SLIPSTREAM_POSITION_MANAGER).setTokensOwed(
            testPositionId, 
            FEES_AMOUNT, 
            FEES_AMOUNT
        );
        token0.mint(address(lpLocker), FEES_AMOUNT);
        token1.mint(address(lpLocker), FEES_AMOUNT);

        // Anyone can claim (accrue), but only authorized can withdraw
        lpLocker.claimTradingFees(votePool);

        uint256 expectedProjectShare = uint256(FEES_AMOUNT) - (uint256(FEES_AMOUNT) * 3000) / 10000;
        
        vm.startPrank(projectOwner);
        lpLocker.withdrawProjectFees(votePool, address(token0), projectOwner);
        vm.stopPrank();

        assertEq(token0.balanceOf(projectOwner), expectedProjectShare);
    }

    function test_ClaimTradingFees_RevertNotAuthorized() public {
        _lockPosition();

        MockNonfungiblePositionManager(SLIPSTREAM_POSITION_MANAGER).setTokensOwed(
            testPositionId, 
            FEES_AMOUNT, 
            FEES_AMOUNT
        );
        token0.mint(address(lpLocker), FEES_AMOUNT);
        
        lpLocker.claimTradingFees(votePool);

        vm.prank(randomUser);
        vm.expectRevert(LPLocker.NotAuthorized.selector);
        lpLocker.withdrawAdminFees(votePool, address(token0), randomUser);
    }

    function test_ClaimTradingFees_RevertPoolNotFound() public {
        vm.prank(admin);
        vm.expectRevert(LPLocker.PoolNotFound.selector);
        lpLocker.claimTradingFees(address(0x999));
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_PendingFees() public {
        _lockPosition();

        MockNonfungiblePositionManager(SLIPSTREAM_POSITION_MANAGER).setTokensOwed(
            testPositionId, 
            FEES_AMOUNT, 
            FEES_AMOUNT * 2
        );

        (address t0, uint256 a0, address t1, uint256 a1) = lpLocker.pendingFees(votePool);

        assertEq(t0, address(token0));
        assertEq(a0, FEES_AMOUNT);
        assertEq(t1, address(token1));
        assertEq(a1, FEES_AMOUNT * 2);
    }

    function test_GetPendingShares() public {
        _lockPosition();

        MockNonfungiblePositionManager(SLIPSTREAM_POSITION_MANAGER).setTokensOwed(
            testPositionId, 
            100 ether, 
            100 ether
        );

        (uint256 adminShare0, uint256 adminShare1, uint256 projectShare0, uint256 projectShare1) =
            lpLocker.getPendingShares(votePool);

        // 30% admin, 70% project
        assertEq(adminShare0, 30 ether);
        assertEq(adminShare1, 30 ether);
        assertEq(projectShare0, 70 ether);
        assertEq(projectShare1, 70 ether);
    }

    function test_Constants() public view {
        assertEq(lpLocker.ADMIN_FEE_BPS(), 3000);
        assertEq(lpLocker.PROJECT_OWNER_FEE_BPS(), 7000);
        assertEq(lpLocker.BPS_DENOMINATOR(), 10000);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _lockPosition() internal {
        vm.startPrank(votePool);
        MockNonfungiblePositionManager(SLIPSTREAM_POSITION_MANAGER).approve(address(lpLocker), testPositionId);
        lpLocker.lockPosition(testPositionId, admin, projectOwner);
        vm.stopPrank();
    }
}
