// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ProjectToken} from "../src/ProjectToken.sol";

contract ProjectTokenTest is Test {
    ProjectToken public token;

    address public alice = makeAddr("alice");
    address public bob = makeAddr("bob");

    string constant NAME = "Test Token";
    string constant SYMBOL = "TEST";
    uint256 constant TOTAL_SUPPLY = 1_000_000_000e18;

    function setUp() public {
        token = new ProjectToken(NAME, SYMBOL, TOTAL_SUPPLY, alice);
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor() public view {
        assertEq(token.name(), NAME);
        assertEq(token.symbol(), SYMBOL);
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), TOTAL_SUPPLY);
        assertEq(token.balanceOf(alice), TOTAL_SUPPLY);
    }

    function test_Constructor_RevertZeroAddress() public {
        vm.expectRevert(ProjectToken.ZeroAddress.selector);
        new ProjectToken(NAME, SYMBOL, TOTAL_SUPPLY, address(0));
    }

    function test_Constructor_ZeroSupplyAllowed() public {
        ProjectToken zeroToken = new ProjectToken(NAME, SYMBOL, 0, alice);
        assertEq(zeroToken.totalSupply(), 0);
        assertEq(zeroToken.balanceOf(alice), 0);
    }

    /*//////////////////////////////////////////////////////////////
                            TRANSFER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Transfer() public {
        uint256 amount = 100e18;
        
        vm.prank(alice);
        bool success = token.transfer(bob, amount);
        
        assertTrue(success);
        assertEq(token.balanceOf(alice), TOTAL_SUPPLY - amount);
        assertEq(token.balanceOf(bob), amount);
    }

    function test_Transfer_RevertZeroAddress() public {
        vm.prank(alice);
        vm.expectRevert(ProjectToken.ZeroAddress.selector);
        token.transfer(address(0), 100e18);
    }

    function test_Transfer_RevertInsufficientBalance() public {
        vm.prank(bob);
        vm.expectRevert(ProjectToken.InsufficientBalance.selector);
        token.transfer(alice, 1);
    }

    function test_Transfer_EmitsEvent() public {
        uint256 amount = 100e18;
        
        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit ProjectToken.Transfer(alice, bob, amount);
        token.transfer(bob, amount);
    }

    /*//////////////////////////////////////////////////////////////
                            APPROVE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Approve() public {
        uint256 amount = 100e18;
        
        vm.prank(alice);
        bool success = token.approve(bob, amount);
        
        assertTrue(success);
        assertEq(token.allowance(alice, bob), amount);
    }

    function test_Approve_EmitsEvent() public {
        uint256 amount = 100e18;
        
        vm.prank(alice);
        vm.expectEmit(true, true, false, true);
        emit ProjectToken.Approval(alice, bob, amount);
        token.approve(bob, amount);
    }

    function test_Approve_CanOverwrite() public {
        vm.startPrank(alice);
        token.approve(bob, 100e18);
        token.approve(bob, 200e18);
        vm.stopPrank();
        
        assertEq(token.allowance(alice, bob), 200e18);
    }

    /*//////////////////////////////////////////////////////////////
                          TRANSFER FROM TESTS
    //////////////////////////////////////////////////////////////*/

    function test_TransferFrom() public {
        uint256 amount = 100e18;
        
        vm.prank(alice);
        token.approve(bob, amount);
        
        vm.prank(bob);
        bool success = token.transferFrom(alice, bob, amount);
        
        assertTrue(success);
        assertEq(token.balanceOf(alice), TOTAL_SUPPLY - amount);
        assertEq(token.balanceOf(bob), amount);
        assertEq(token.allowance(alice, bob), 0);
    }

    function test_TransferFrom_MaxAllowance() public {
        uint256 amount = 100e18;
        
        vm.prank(alice);
        token.approve(bob, type(uint256).max);
        
        vm.prank(bob);
        token.transferFrom(alice, bob, amount);
        
        // Max allowance should not decrease
        assertEq(token.allowance(alice, bob), type(uint256).max);
    }

    function test_TransferFrom_RevertZeroAddress() public {
        vm.prank(alice);
        token.approve(bob, 100e18);
        
        vm.prank(bob);
        vm.expectRevert(ProjectToken.ZeroAddress.selector);
        token.transferFrom(alice, address(0), 100e18);
    }

    function test_TransferFrom_RevertInsufficientBalance() public {
        vm.prank(bob);
        token.approve(alice, TOTAL_SUPPLY + 1);
        
        vm.prank(alice);
        vm.expectRevert(ProjectToken.InsufficientBalance.selector);
        token.transferFrom(bob, alice, 1);
    }

    function test_TransferFrom_RevertInsufficientAllowance() public {
        vm.prank(alice);
        token.approve(bob, 50e18);
        
        vm.prank(bob);
        vm.expectRevert(ProjectToken.InsufficientAllowance.selector);
        token.transferFrom(alice, bob, 100e18);
    }

    /*//////////////////////////////////////////////////////////////
                            FUZZ TESTS
    //////////////////////////////////////////////////////////////*/

    function testFuzz_Transfer(uint256 amount) public {
        amount = bound(amount, 0, TOTAL_SUPPLY);
        
        vm.prank(alice);
        token.transfer(bob, amount);
        
        assertEq(token.balanceOf(alice), TOTAL_SUPPLY - amount);
        assertEq(token.balanceOf(bob), amount);
    }

    function testFuzz_TransferFrom(uint256 amount) public {
        amount = bound(amount, 0, TOTAL_SUPPLY);
        
        vm.prank(alice);
        token.approve(bob, amount);
        
        vm.prank(bob);
        token.transferFrom(alice, bob, amount);
        
        assertEq(token.balanceOf(bob), amount);
    }
}

