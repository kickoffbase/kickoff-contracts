// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {LPLocker} from "../src/LPLocker.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockPool} from "./mocks/MockPool.sol";

contract LPLockerTest is Test {
    LPLocker public lpLocker;
    MockERC20 public lpToken;
    MockPool public aerodromePool;
    MockERC20 public token0;
    MockERC20 public token1;

    address public votePool = address(0x1);
    address public admin = address(0x2);
    address public projectOwner = address(0x3);
    address public randomUser = address(0x4);

    uint256 public constant LP_AMOUNT = 1000 ether;
    uint256 public constant FEES_AMOUNT = 100 ether;

    function setUp() public {
        // Deploy contracts
        lpLocker = new LPLocker();
        lpToken = new MockERC20("LP Token", "LP", 18);
        token0 = new MockERC20("Token0", "T0", 18);
        token1 = new MockERC20("Token1", "T1", 18);
        aerodromePool = new MockPool(address(token0), address(token1), address(lpToken));

        // Mint LP tokens to vote pool
        lpToken.mint(votePool, LP_AMOUNT);
    }

    /*//////////////////////////////////////////////////////////////
                           LOCK LP TESTS
    //////////////////////////////////////////////////////////////*/

    function test_LockLP() public {
        vm.startPrank(votePool);
        lpToken.approve(address(lpLocker), LP_AMOUNT);
        lpLocker.lockLP(address(lpToken), address(aerodromePool), admin, projectOwner, LP_AMOUNT);
        vm.stopPrank();

        // Verify lock
        LPLocker.LockedLP memory locked = lpLocker.getLockedLP(votePool);
        assertEq(locked.lpToken, address(lpToken));
        assertEq(locked.aerodromePool, address(aerodromePool));
        assertEq(locked.admin, admin);
        assertEq(locked.projectOwner, projectOwner);
        assertEq(locked.totalLP, LP_AMOUNT);
        assertTrue(locked.exists);

        // Verify LP transferred
        assertEq(lpToken.balanceOf(address(lpLocker)), LP_AMOUNT);
        assertEq(lpToken.balanceOf(votePool), 0);

        // Verify tracking
        assertEq(lpLocker.getVotePoolCount(), 1);
        assertEq(lpLocker.getAllVotePools()[0], votePool);
    }

    function test_LockLP_RevertZeroAddress() public {
        vm.startPrank(votePool);
        lpToken.approve(address(lpLocker), LP_AMOUNT);

        vm.expectRevert(LPLocker.ZeroAddress.selector);
        lpLocker.lockLP(address(0), address(aerodromePool), admin, projectOwner, LP_AMOUNT);

        vm.expectRevert(LPLocker.ZeroAddress.selector);
        lpLocker.lockLP(address(lpToken), address(0), admin, projectOwner, LP_AMOUNT);

        vm.expectRevert(LPLocker.ZeroAddress.selector);
        lpLocker.lockLP(address(lpToken), address(aerodromePool), address(0), projectOwner, LP_AMOUNT);

        vm.expectRevert(LPLocker.ZeroAddress.selector);
        lpLocker.lockLP(address(lpToken), address(aerodromePool), admin, address(0), LP_AMOUNT);

        vm.stopPrank();
    }

    function test_LockLP_RevertZeroAmount() public {
        vm.startPrank(votePool);

        vm.expectRevert(LPLocker.ZeroAmount.selector);
        lpLocker.lockLP(address(lpToken), address(aerodromePool), admin, projectOwner, 0);

        vm.stopPrank();
    }

    function test_LockLP_RevertAlreadyLocked() public {
        vm.startPrank(votePool);
        lpToken.approve(address(lpLocker), LP_AMOUNT);
        lpLocker.lockLP(address(lpToken), address(aerodromePool), admin, projectOwner, LP_AMOUNT / 2);

        vm.expectRevert(LPLocker.AlreadyLocked.selector);
        lpLocker.lockLP(address(lpToken), address(aerodromePool), admin, projectOwner, LP_AMOUNT / 2);

        vm.stopPrank();
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

        // Claim as admin
        vm.prank(admin);
        lpLocker.claimTradingFees(votePool);

        // Verify split: 20% admin, 80% project owner
        uint256 expectedAdminShare = (FEES_AMOUNT * 2000) / 10000; // 20%
        uint256 expectedProjectShare = FEES_AMOUNT - expectedAdminShare; // 80%

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

        // Claim as project owner
        vm.prank(projectOwner);
        lpLocker.claimTradingFees(votePool);

        // Verify split
        uint256 expectedAdminShare = (FEES_AMOUNT * 2000) / 10000;
        uint256 expectedProjectShare = FEES_AMOUNT - expectedAdminShare;

        assertEq(token0.balanceOf(admin), expectedAdminShare);
        assertEq(token0.balanceOf(projectOwner), expectedProjectShare);
    }

    function test_ClaimTradingFees_RevertNotAuthorized() public {
        _lockLP();

        vm.prank(randomUser);
        vm.expectRevert(LPLocker.NotAuthorized.selector);
        lpLocker.claimTradingFees(votePool);
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

        // 20% admin, 80% project
        assertEq(adminShare0, 20 ether);
        assertEq(adminShare1, 20 ether);
        assertEq(projectShare0, 80 ether);
        assertEq(projectShare1, 80 ether);
    }

    function test_Constants() public view {
        assertEq(lpLocker.ADMIN_FEE_BPS(), 2000);
        assertEq(lpLocker.PROJECT_OWNER_FEE_BPS(), 8000);
        assertEq(lpLocker.BPS_DENOMINATOR(), 10000);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function _lockLP() internal {
        vm.startPrank(votePool);
        lpToken.approve(address(lpLocker), LP_AMOUNT);
        lpLocker.lockLP(address(lpToken), address(aerodromePool), admin, projectOwner, LP_AMOUNT);
        vm.stopPrank();
    }
}

