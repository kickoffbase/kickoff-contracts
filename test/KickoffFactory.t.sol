// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {KickoffFactory} from "../src/KickoffFactory.sol";
import {KickoffVoteSalePool} from "../src/KickoffVoteSalePool.sol";
import {LPLocker} from "../src/LPLocker.sol";
import {MockERC20} from "./mocks/MockERC20.sol";

contract KickoffFactoryTest is Test {
    KickoffFactory public factory;
    MockERC20 public projectToken;

    address public admin = address(0x1);
    address public projectOwner = address(0x2);
    address public user = address(0x3);

    // Aerodrome addresses on Base (for reference, we'll use mocks in unit tests)
    address public votingEscrow = address(0x10);
    address public voter = address(0x11);
    address public router = address(0x12);
    address public weth = address(0x13);

    uint256 public constant TOTAL_ALLOCATION = 1_000_000 ether;
    uint256 public constant MIN_VOTING_POWER = 1 ether; // #1: Must be > 0

    function setUp() public {
        // Deploy project token
        projectToken = new MockERC20("Project Token", "PROJECT", 18);

        // Deploy factory (owner = address(this))
        factory = new KickoffFactory(votingEscrow, voter, router, weth);

        // Mint tokens to admin (pool admin)
        projectToken.mint(admin, TOTAL_ALLOCATION);
    }

    function test_Constructor() public view {
        assertEq(factory.owner(), address(this));
        assertEq(factory.votingEscrow(), votingEscrow);
        assertEq(factory.voter(), voter);
        assertEq(factory.router(), router);
        assertEq(factory.weth(), weth);
        assertTrue(address(factory.lpLocker()) != address(0));
    }

    function test_CreatePool() public {
        // Approve tokens from pool admin
        vm.prank(admin);
        projectToken.approve(address(factory), TOTAL_ALLOCATION);

        // Create pool (called by factory owner, admin is pool admin)
        address pool = factory.createPool(address(projectToken), projectOwner, TOTAL_ALLOCATION, MIN_VOTING_POWER, admin);

        // Verify pool was created
        assertTrue(pool != address(0));
        assertTrue(factory.isPool(pool));
        assertEq(factory.poolByToken(address(projectToken)), pool);
        assertEq(factory.poolCount(), 1);

        // Verify pool configuration
        KickoffVoteSalePool voteSalePool = KickoffVoteSalePool(pool);
        assertEq(voteSalePool.admin(), admin);
        assertEq(voteSalePool.projectOwner(), projectOwner);
        assertEq(voteSalePool.projectToken(), address(projectToken));
        assertEq(voteSalePool.totalAllocation(), TOTAL_ALLOCATION);
        assertEq(voteSalePool.saleAllocation(), TOTAL_ALLOCATION / 2);
        assertEq(voteSalePool.liquidityAllocation(), TOTAL_ALLOCATION - TOTAL_ALLOCATION / 2);
        assertEq(voteSalePool.minVotingPower(), MIN_VOTING_POWER);

        // Verify tokens were transferred
        assertEq(projectToken.balanceOf(pool), TOTAL_ALLOCATION);
        assertEq(projectToken.balanceOf(admin), 0);
    }

    function test_CreatePool_RevertZeroAddress() public {
        vm.prank(admin);
        projectToken.approve(address(factory), TOTAL_ALLOCATION);

        vm.expectRevert(KickoffFactory.ZeroAddress.selector);
        factory.createPool(address(0), projectOwner, TOTAL_ALLOCATION, MIN_VOTING_POWER, admin);

        vm.expectRevert(KickoffFactory.ZeroAddress.selector);
        factory.createPool(address(projectToken), address(0), TOTAL_ALLOCATION, MIN_VOTING_POWER, admin);

        vm.expectRevert(KickoffFactory.ZeroAddress.selector);
        factory.createPool(address(projectToken), projectOwner, TOTAL_ALLOCATION, MIN_VOTING_POWER, address(0));
    }

    function test_CreatePool_RevertZeroAmount() public {
        vm.prank(admin);
        projectToken.approve(address(factory), TOTAL_ALLOCATION);

        vm.expectRevert(KickoffFactory.ZeroAmount.selector);
        factory.createPool(address(projectToken), projectOwner, 0, MIN_VOTING_POWER, admin);
    }
    
    function test_CreatePool_RevertZeroVotingPower() public {
        vm.prank(admin);
        projectToken.approve(address(factory), TOTAL_ALLOCATION);

        // #1: minVotingPower = 0 should revert
        vm.expectRevert(KickoffFactory.ZeroVotingPower.selector);
        factory.createPool(address(projectToken), projectOwner, TOTAL_ALLOCATION, 0, admin);
    }

    function test_CreatePool_RevertDuplicate() public {
        vm.prank(admin);
        projectToken.approve(address(factory), TOTAL_ALLOCATION);
        
        factory.createPool(address(projectToken), projectOwner, TOTAL_ALLOCATION / 2, MIN_VOTING_POWER, admin);

        vm.expectRevert(KickoffFactory.PoolAlreadyExists.selector);
        factory.createPool(address(projectToken), projectOwner, TOTAL_ALLOCATION / 2, MIN_VOTING_POWER, admin);
    }
    
    function test_CreatePool_RevertNotOwner() public {
        // #5: Only factory owner can create pools
        vm.startPrank(user);
        projectToken.mint(user, TOTAL_ALLOCATION);
        projectToken.approve(address(factory), TOTAL_ALLOCATION);
        
        vm.expectRevert(KickoffFactory.NotOwner.selector);
        factory.createPool(address(projectToken), projectOwner, TOTAL_ALLOCATION, MIN_VOTING_POWER, user);
        
        vm.stopPrank();
    }

    function test_GetAllPools() public {
        // Create multiple pools with different tokens
        MockERC20 token1 = new MockERC20("Token 1", "T1", 18);
        MockERC20 token2 = new MockERC20("Token 2", "T2", 18);

        token1.mint(admin, TOTAL_ALLOCATION);
        token2.mint(admin, TOTAL_ALLOCATION);

        vm.startPrank(admin);
        token1.approve(address(factory), TOTAL_ALLOCATION);
        token2.approve(address(factory), TOTAL_ALLOCATION);
        vm.stopPrank();

        // Factory owner creates pools
        address pool1 = factory.createPool(address(token1), projectOwner, TOTAL_ALLOCATION, MIN_VOTING_POWER, admin);
        address pool2 = factory.createPool(address(token2), projectOwner, TOTAL_ALLOCATION, MIN_VOTING_POWER, admin);

        address[] memory pools = factory.getAllPools();
        assertEq(pools.length, 2);
        assertEq(pools[0], pool1);
        assertEq(pools[1], pool2);
    }

    function test_TransferOwnership() public {
        address newOwner = address(0x999);

        // Transfer ownership
        factory.transferOwnership(newOwner);
        assertEq(factory.pendingOwner(), newOwner);
        assertEq(factory.owner(), address(this));

        // Accept ownership
        vm.prank(newOwner);
        factory.acceptOwnership();

        assertEq(factory.owner(), newOwner);
        assertEq(factory.pendingOwner(), address(0));
    }

    function test_TransferOwnership_RevertNotOwner() public {
        vm.prank(user);
        vm.expectRevert(KickoffFactory.NotOwner.selector);
        factory.transferOwnership(user);
    }

    function test_AcceptOwnership_RevertNotPending() public {
        factory.transferOwnership(admin);

        vm.prank(user);
        vm.expectRevert(KickoffFactory.NotOwner.selector);
        factory.acceptOwnership();
    }
}
