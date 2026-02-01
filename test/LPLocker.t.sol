// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {LPLocker} from "../src/LPLocker.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";
import {MockKickoffFactory} from "./mocks/MockKickoffFactory.sol";

contract LPLockerTest is Test {
    LPLocker public lpLocker;
    MockKickoffFactory public mockFactory;
    MockPool public aerodromePool;
    MockERC20 public token0;
    MockERC20 public token1;

    address public votePool = address(0x1);
    address public admin = address(0x2);
    address public projectOwner = address(0x3);
    address public randomUser = address(0x4);

    uint256 public constant LP_AMOUNT = 1000 ether;
    uint256 public constant FEES_AMOUNT = 100 ether;

    // Aerodrome PoolFactory address on Base
    address constant AERODROME_POOL_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;

    function setUp() public {
        // Deploy contracts
        lpLocker = new LPLocker();
        mockFactory = new MockKickoffFactory();
        token0 = new MockERC20("Token0", "T0", 18);
        token1 = new MockERC20("Token1", "T1", 18);
        
        // On Aerodrome, LP token IS the pool contract
        // Deploy MockPool which acts as both LP token and pool
        aerodromePool = new MockPool(address(token0), address(token1), address(0));

        // Setup factory relationship
        lpLocker.setFactory(address(mockFactory));
        mockFactory.setPool(votePool, true);
        
        // Mock Aerodrome PoolFactory to return true for our mock pool
        vm.mockCall(
            AERODROME_POOL_FACTORY,
            abi.encodeWithSignature("isPool(address)", address(aerodromePool)),
            abi.encode(true)
        );

        // Mint LP tokens to vote pool (pool IS the LP token on Aerodrome)
        aerodromePool.mintLP(votePool, LP_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                           LOCK LP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_LockLP() public {
        vm.startPrank(votePool);
        // On Aerodrome, LP token IS the pool contract
        aerodromePool.approve(address(lpLocker), LP_AMOUNT);
        lpLocker.lockLP(address(aerodromePool), address(aerodromePool), admin, projectOwner, LP_AMOUNT);
        vm.stopPrank();

        // Verify lock
        LPLocker.LockedLP memory locked = lpLocker.getLockedLP(votePool);
        assertEq(locked.lpToken, address(aerodromePool));
        assertEq(locked.aerodromePool, address(aerodromePool));
        assertEq(locked.admin, admin);
        assertEq(locked.projectOwner, projectOwner);
        assertEq(locked.totalLP, LP_AMOUNT);
        assertTrue(locked.exists);

        // Verify LP transferred
        assertEq(aerodromePool.balanceOf(address(lpLocker)), LP_AMOUNT);
        assertEq(aerodromePool.balanceOf(votePool), 0);

        // Verify tracking
        assertEq(lpLocker.getVotePoolCount(), 1);
        assertEq(lpLocker.getAllVotePools()[0], votePool);
    }

    function test_LockLP_RevertZeroAddress() public {
        vm.startPrank(votePool);
        aerodromePool.approve(address(lpLocker), LP_AMOUNT);

        vm.expectRevert(LPLocker.ZeroAddress.selector);
        lpLocker.lockLP(address(0), address(aerodromePool), admin, projectOwner, LP_AMOUNT);

        vm.expectRevert(LPLocker.ZeroAddress.selector);
        lpLocker.lockLP(address(aerodromePool), address(0), admin, projectOwner, LP_AMOUNT);

        vm.expectRevert(LPLocker.ZeroAddress.selector);
        lpLocker.lockLP(address(aerodromePool), address(aerodromePool), address(0), projectOwner, LP_AMOUNT);

        vm.expectRevert(LPLocker.ZeroAddress.selector);
        lpLocker.lockLP(address(aerodromePool), address(aerodromePool), admin, address(0), LP_AMOUNT);

        vm.stopPrank();
    }

    function test_LockLP_RevertZeroAmount() public {
        vm.startPrank(votePool);

        vm.expectRevert(LPLocker.ZeroAmount.selector);
        lpLocker.lockLP(address(aerodromePool), address(aerodromePool), admin, projectOwner, 0);

        vm.stopPrank();
    }

    function test_LockLP_RevertAlreadyLocked() public {
        vm.startPrank(votePool);
        aerodromePool.approve(address(lpLocker), LP_AMOUNT);
        lpLocker.lockLP(address(aerodromePool), address(aerodromePool), admin, projectOwner, LP_AMOUNT / 2);

        vm.expectRevert(LPLocker.AlreadyLocked.selector);
        lpLocker.lockLP(address(aerodromePool), address(aerodromePool), admin, projectOwner, LP_AMOUNT / 2);

        vm.stopPrank();
    }

    function test_LockLP_RevertNotVoteSalePool() public {
        // Try to lock from an address not registered as a pool
        address attacker = address(0x999);
        aerodromePool.mintLP(attacker, LP_AMOUNT);

        vm.startPrank(attacker);
        aerodromePool.approve(address(lpLocker), LP_AMOUNT);

        vm.expectRevert(LPLocker.NotVoteSalePool.selector);
        lpLocker.lockLP(address(aerodromePool), address(aerodromePool), attacker, attacker, LP_AMOUNT);

        vm.stopPrank();
    }

    function test_LockLP_RevertFactoryNotSet() public {
        // Deploy a fresh LPLocker without setting factory
        LPLocker freshLocker = new LPLocker();
        
        vm.startPrank(votePool);
        aerodromePool.approve(address(freshLocker), LP_AMOUNT);

        vm.expectRevert(LPLocker.FactoryNotSet.selector);
        freshLocker.lockLP(address(aerodromePool), address(aerodromePool), admin, projectOwner, LP_AMOUNT);

        vm.stopPrank();
    }

    function test_SetFactory_RevertAlreadySet() public {
        // Factory is already set in setUp
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
        
        // Try to set factory from a different address (not deployer)
        vm.prank(address(0x999));
        vm.expectRevert(LPLocker.NotDeployer.selector);
        freshLocker.setFactory(address(mockFactory));
    }

    /*//////////////////////////////////////////////////////////////
                       CLAIM TRADING FEES TESTS
    //////////////////////////////////////////////////////////////*/

    function test_ClaimTradingFees_ByAdmin() public {
        // Setup lock
        _lockLP();

        // Add claimable fees
        aerodromePool.setClaimableFees(FEES_AMOUNT, FEES_AMOUNT);
        token0.mint(address(aerodromePool), FEES_AMOUNT);
        token1.mint(address(aerodromePool), FEES_AMOUNT);

        // #18: Claim first (accrues fees)
        lpLocker.claimTradingFees(votePool);

        // Verify fees are accrued
        uint256 expectedAdminShare = (FEES_AMOUNT * 3000) / 10000; // 30%
        uint256 expectedProjectShare = FEES_AMOUNT - expectedAdminShare; // 70%
        
        (uint256 adminBal0, uint256 projectBal0) = lpLocker.getAccruedFees(votePool, address(token0));
        (uint256 adminBal1, uint256 projectBal1) = lpLocker.getAccruedFees(votePool, address(token1));
        
        assertEq(adminBal0, expectedAdminShare);
        assertEq(adminBal1, expectedAdminShare);
        assertEq(projectBal0, expectedProjectShare);
        assertEq(projectBal1, expectedProjectShare);
        
        // #18: Admin withdraws their fees
        vm.startPrank(admin);
        lpLocker.withdrawAdminFees(votePool, address(token0), admin);
        lpLocker.withdrawAdminFees(votePool, address(token1), admin);
        vm.stopPrank();
        
        // #18: Project owner withdraws their fees
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
        _lockLP();

        aerodromePool.setClaimableFees(FEES_AMOUNT, FEES_AMOUNT);
        token0.mint(address(aerodromePool), FEES_AMOUNT);
        token1.mint(address(aerodromePool), FEES_AMOUNT);

        // #18: Anyone can claim (accrue), but only authorized can withdraw
        lpLocker.claimTradingFees(votePool);

        // Verify fees are accrued
        uint256 expectedAdminShare = (FEES_AMOUNT * 3000) / 10000;
        uint256 expectedProjectShare = FEES_AMOUNT - expectedAdminShare;
        
        // Project owner withdraws
        vm.startPrank(projectOwner);
        lpLocker.withdrawProjectFees(votePool, address(token0), projectOwner);
        vm.stopPrank();

        assertEq(token0.balanceOf(projectOwner), expectedProjectShare);
    }

    function test_ClaimTradingFees_RevertNotAuthorized() public {
        _lockLP();

        aerodromePool.setClaimableFees(FEES_AMOUNT, FEES_AMOUNT);
        token0.mint(address(aerodromePool), FEES_AMOUNT);
        token1.mint(address(aerodromePool), FEES_AMOUNT);
        
        // Claim and accrue fees
        lpLocker.claimTradingFees(votePool);

        // Random user cannot withdraw
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
        _lockLP();

        aerodromePool.setClaimableFees(FEES_AMOUNT, FEES_AMOUNT * 2);

        (address t0, uint256 a0, address t1, uint256 a1) = lpLocker.pendingFees(votePool);

        assertEq(t0, address(token0));
        assertEq(a0, FEES_AMOUNT);
        assertEq(t1, address(token1));
        assertEq(a1, FEES_AMOUNT * 2);
    }

    function test_GetPendingShares() public {
        _lockLP();

        aerodromePool.setClaimableFees(100 ether, 100 ether);

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

    function _lockLP() internal {
        vm.startPrank(votePool);
        aerodromePool.approve(address(lpLocker), LP_AMOUNT);
        lpLocker.lockLP(address(aerodromePool), address(aerodromePool), admin, projectOwner, LP_AMOUNT);
        vm.stopPrank();
    }
}

