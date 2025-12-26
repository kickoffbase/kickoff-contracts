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

    function setUp() public {
        // Deploy project token
        projectToken = new MockERC20("Project Token", "PROJECT", 18);

        // Deploy factory
        factory = new KickoffFactory(votingEscrow, voter, router, weth);

        // Mint tokens to admin
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
        vm.startPrank(admin);

        // Approve tokens
        projectToken.approve(address(factory), TOTAL_ALLOCATION);

        // Create pool (minVotingPower = 0)
        address pool = factory.createPool(address(projectToken), projectOwner, TOTAL_ALLOCATION, 0);

        vm.stopPrank();

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

        // Verify tokens were transferred
        assertEq(projectToken.balanceOf(pool), TOTAL_ALLOCATION);
        assertEq(projectToken.balanceOf(admin), 0);
    }

    function test_CreatePool_RevertZeroAddress() public {
        vm.startPrank(admin);
        projectToken.approve(address(factory), TOTAL_ALLOCATION);

        vm.expectRevert(KickoffFactory.ZeroAddress.selector);
        factory.createPool(address(0), projectOwner, TOTAL_ALLOCATION, 0);

        vm.expectRevert(KickoffFactory.ZeroAddress.selector);
        factory.createPool(address(projectToken), address(0), TOTAL_ALLOCATION, 0);

        vm.stopPrank();
    }

    function test_CreatePool_RevertZeroAmount() public {
        vm.startPrank(admin);
        projectToken.approve(address(factory), TOTAL_ALLOCATION);

        vm.expectRevert(KickoffFactory.ZeroAmount.selector);
        factory.createPool(address(projectToken), projectOwner, 0, 0);

        vm.stopPrank();
    }

    function test_CreatePool_RevertDuplicate() public {
        vm.startPrank(admin);
        projectToken.approve(address(factory), TOTAL_ALLOCATION);
        factory.createPool(address(projectToken), projectOwner, TOTAL_ALLOCATION / 2, 0);

        vm.expectRevert(KickoffFactory.PoolAlreadyExists.selector);
        factory.createPool(address(projectToken), projectOwner, TOTAL_ALLOCATION / 2, 0);

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
        address pool1 = factory.createPool(address(token1), projectOwner, TOTAL_ALLOCATION, 0);

        token2.approve(address(factory), TOTAL_ALLOCATION);
        address pool2 = factory.createPool(address(token2), projectOwner, TOTAL_ALLOCATION, 0);

        vm.stopPrank();

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

