// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {TokenVesting} from "../src/TokenVesting.sol";
import {ITokenVesting} from "../src/interfaces/ITokenVesting.sol";
import {ProjectToken} from "../src/ProjectToken.sol";

contract TokenVestingTest is Test {
    TokenVesting public vesting;
    ProjectToken public token;

    address public owner = makeAddr("owner");
    address public factory = makeAddr("factory");
    address public beneficiary = makeAddr("beneficiary");
    address public beneficiary2 = makeAddr("beneficiary2");

    uint256 constant TOTAL_SUPPLY = 1_000_000_000e18;
    uint256 constant LOCK_AMOUNT = 100_000e18;

    function setUp() public {
        vm.startPrank(owner);
        vesting = new TokenVesting();
        vesting.setFactory(factory);
        vm.stopPrank();

        // Create token and fund vesting contract
        token = new ProjectToken("Test", "TEST", TOTAL_SUPPLY, address(this));
        token.transfer(address(vesting), LOCK_AMOUNT * 10);
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor() public view {
        assertEq(vesting.owner(), owner);
        assertEq(vesting.factory(), factory);
        assertEq(vesting.lockCount(), 0);
    }

    /*//////////////////////////////////////////////////////////////
                          SET FACTORY TESTS
    //////////////////////////////////////////////////////////////*/

    function test_SetFactory_RevertNotOwner() public {
        TokenVesting newVesting = new TokenVesting();
        
        vm.prank(beneficiary);
        vm.expectRevert(ITokenVesting.NotOwner.selector);
        newVesting.setFactory(factory);
    }

    function test_SetFactory_RevertZeroAddress() public {
        TokenVesting newVesting = new TokenVesting();
        
        vm.expectRevert(ITokenVesting.ZeroAddress.selector);
        newVesting.setFactory(address(0));
    }

    function test_SetFactory_RevertAlreadySet() public {
        vm.prank(owner);
        vm.expectRevert(ITokenVesting.FactoryAlreadySet.selector);
        vesting.setFactory(makeAddr("newFactory"));
    }

    /*//////////////////////////////////////////////////////////////
                          CREATE LOCK TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreateLock() public {
        vm.prank(factory);
        uint256 lockId = vesting.createLock(
            address(token),
            beneficiary,
            LOCK_AMOUNT,
            30 days,
            365 days
        );

        assertEq(lockId, 0);
        assertEq(vesting.lockCount(), 1);
        
        (
            address lockToken,
            address lockBeneficiary,
            uint256 totalAmount,
            uint256 cliffDuration,
            uint256 vestingDuration,
            uint256 claimed
        ) = vesting.vestingSchedules(lockId);

        assertEq(lockToken, address(token));
        assertEq(lockBeneficiary, beneficiary);
        assertEq(totalAmount, LOCK_AMOUNT);
        assertEq(cliffDuration, 30 days);
        assertEq(vestingDuration, 365 days);
        assertEq(claimed, 0);
    }

    function test_CreateLock_RevertNotFactory() public {
        vm.expectRevert(ITokenVesting.NotFactory.selector);
        vesting.createLock(address(token), beneficiary, LOCK_AMOUNT, 30 days, 365 days);
    }

    function test_CreateLock_RevertZeroToken() public {
        vm.prank(factory);
        vm.expectRevert(ITokenVesting.ZeroAddress.selector);
        vesting.createLock(address(0), beneficiary, LOCK_AMOUNT, 30 days, 365 days);
    }

    function test_CreateLock_RevertZeroBeneficiary() public {
        vm.prank(factory);
        vm.expectRevert(ITokenVesting.ZeroAddress.selector);
        vesting.createLock(address(token), address(0), LOCK_AMOUNT, 30 days, 365 days);
    }

    function test_CreateLock_RevertZeroAmount() public {
        vm.prank(factory);
        vm.expectRevert(ITokenVesting.ZeroAmount.selector);
        vesting.createLock(address(token), beneficiary, 0, 30 days, 365 days);
    }

    function test_CreateLock_EmitsEvent() public {
        vm.prank(factory);
        vm.expectEmit(true, true, true, true);
        emit ITokenVesting.LockCreated(0, address(token), beneficiary, LOCK_AMOUNT, 30 days, 365 days);
        vesting.createLock(address(token), beneficiary, LOCK_AMOUNT, 30 days, 365 days);
    }

    /*//////////////////////////////////////////////////////////////
                        START VESTING TESTS
    //////////////////////////////////////////////////////////////*/

    function test_StartVesting() public {
        vm.prank(owner);
        vesting.startVesting(address(token));

        assertEq(vesting.tgeStart(address(token)), block.timestamp);
    }

    function test_StartVesting_RevertNotOwner() public {
        vm.expectRevert(ITokenVesting.NotOwner.selector);
        vesting.startVesting(address(token));
    }

    function test_StartVesting_RevertZeroAddress() public {
        vm.prank(owner);
        vm.expectRevert(ITokenVesting.ZeroAddress.selector);
        vesting.startVesting(address(0));
    }

    function test_StartVesting_RevertAlreadyStarted() public {
        vm.startPrank(owner);
        vesting.startVesting(address(token));
        
        vm.expectRevert(ITokenVesting.VestingAlreadyStarted.selector);
        vesting.startVesting(address(token));
        vm.stopPrank();
    }

    function test_StartVesting_EmitsEvent() public {
        vm.prank(owner);
        vm.expectEmit(true, false, false, true);
        emit ITokenVesting.VestingStarted(address(token), block.timestamp);
        vesting.startVesting(address(token));
    }

    /*//////////////////////////////////////////////////////////////
                            CLAIM TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Claim_NoCliffNoVesting() public {
        // 100% available immediately after TGE start
        vm.prank(factory);
        uint256 lockId = vesting.createLock(address(token), beneficiary, LOCK_AMOUNT, 0, 0);

        vm.prank(owner);
        vesting.startVesting(address(token));

        uint256 claimable = vesting.getClaimable(lockId);
        assertEq(claimable, LOCK_AMOUNT);

        vm.prank(beneficiary);
        vesting.claim(lockId);

        assertEq(token.balanceOf(beneficiary), LOCK_AMOUNT);
        assertEq(vesting.getClaimable(lockId), 0);
    }

    function test_Claim_WithCliff() public {
        vm.prank(factory);
        uint256 lockId = vesting.createLock(address(token), beneficiary, LOCK_AMOUNT, 30 days, 0);

        vm.prank(owner);
        vesting.startVesting(address(token));

        // Before cliff - nothing claimable
        assertEq(vesting.getClaimable(lockId), 0);

        // After cliff - all available (no vesting duration)
        vm.warp(block.timestamp + 30 days);
        assertEq(vesting.getClaimable(lockId), LOCK_AMOUNT);

        vm.prank(beneficiary);
        vesting.claim(lockId);
        assertEq(token.balanceOf(beneficiary), LOCK_AMOUNT);
    }

    function test_Claim_LinearVesting() public {
        vm.prank(factory);
        uint256 lockId = vesting.createLock(address(token), beneficiary, LOCK_AMOUNT, 0, 100 days);

        vm.prank(owner);
        vesting.startVesting(address(token));

        // 25% after 25 days
        vm.warp(block.timestamp + 25 days);
        assertEq(vesting.getClaimable(lockId), LOCK_AMOUNT * 25 / 100);

        // 50% after 50 days
        vm.warp(block.timestamp + 25 days);
        assertEq(vesting.getClaimable(lockId), LOCK_AMOUNT * 50 / 100);

        // 100% after 100 days
        vm.warp(block.timestamp + 50 days);
        assertEq(vesting.getClaimable(lockId), LOCK_AMOUNT);

        vm.prank(beneficiary);
        vesting.claim(lockId);
        assertEq(token.balanceOf(beneficiary), LOCK_AMOUNT);
    }

    function test_Claim_CliffPlusLinearVesting() public {
        vm.prank(factory);
        uint256 lockId = vesting.createLock(address(token), beneficiary, LOCK_AMOUNT, 30 days, 100 days);

        vm.prank(owner);
        vesting.startVesting(address(token));

        // During cliff - nothing
        vm.warp(block.timestamp + 15 days);
        assertEq(vesting.getClaimable(lockId), 0);

        // Cliff ends, vesting starts
        vm.warp(block.timestamp + 15 days); // now at 30 days
        assertEq(vesting.getClaimable(lockId), 0);

        // 50% of vesting after 50 more days
        vm.warp(block.timestamp + 50 days); // now at 80 days
        assertEq(vesting.getClaimable(lockId), LOCK_AMOUNT * 50 / 100);

        // Full amount after cliff + vesting
        vm.warp(block.timestamp + 50 days); // now at 130 days
        assertEq(vesting.getClaimable(lockId), LOCK_AMOUNT);
    }

    function test_Claim_PartialClaims() public {
        vm.prank(factory);
        uint256 lockId = vesting.createLock(address(token), beneficiary, LOCK_AMOUNT, 0, 100 days);

        vm.prank(owner);
        vesting.startVesting(address(token));

        // Claim 25%
        vm.warp(block.timestamp + 25 days);
        vm.prank(beneficiary);
        vesting.claim(lockId);
        assertEq(token.balanceOf(beneficiary), LOCK_AMOUNT * 25 / 100);

        // Claim another 25%
        vm.warp(block.timestamp + 25 days);
        vm.prank(beneficiary);
        vesting.claim(lockId);
        assertEq(token.balanceOf(beneficiary), LOCK_AMOUNT * 50 / 100);

        // Claim remaining
        vm.warp(block.timestamp + 50 days);
        vm.prank(beneficiary);
        vesting.claim(lockId);
        assertEq(token.balanceOf(beneficiary), LOCK_AMOUNT);
    }

    function test_Claim_RevertNotBeneficiary() public {
        vm.prank(factory);
        uint256 lockId = vesting.createLock(address(token), beneficiary, LOCK_AMOUNT, 0, 0);

        vm.prank(owner);
        vesting.startVesting(address(token));

        vm.expectRevert(ITokenVesting.NotBeneficiary.selector);
        vesting.claim(lockId);
    }

    function test_Claim_RevertVestingNotStarted() public {
        vm.prank(factory);
        uint256 lockId = vesting.createLock(address(token), beneficiary, LOCK_AMOUNT, 0, 0);

        vm.prank(beneficiary);
        vm.expectRevert(ITokenVesting.NothingToClaim.selector);
        vesting.claim(lockId);
    }

    function test_Claim_RevertNothingToClaim() public {
        vm.prank(factory);
        uint256 lockId = vesting.createLock(address(token), beneficiary, LOCK_AMOUNT, 30 days, 100 days);

        vm.prank(owner);
        vesting.startVesting(address(token));

        // During cliff
        vm.prank(beneficiary);
        vm.expectRevert(ITokenVesting.NothingToClaim.selector);
        vesting.claim(lockId);
    }

    function test_ClaimMultiple() public {
        vm.startPrank(factory);
        uint256 lockId1 = vesting.createLock(address(token), beneficiary, LOCK_AMOUNT, 0, 0);
        uint256 lockId2 = vesting.createLock(address(token), beneficiary, LOCK_AMOUNT, 0, 0);
        vm.stopPrank();

        vm.prank(owner);
        vesting.startVesting(address(token));

        uint256[] memory lockIds = new uint256[](2);
        lockIds[0] = lockId1;
        lockIds[1] = lockId2;

        vm.prank(beneficiary);
        vesting.claimMultiple(lockIds);

        assertEq(token.balanceOf(beneficiary), LOCK_AMOUNT * 2);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_GetLockInfo() public {
        vm.prank(factory);
        uint256 lockId = vesting.createLock(address(token), beneficiary, LOCK_AMOUNT, 30 days, 100 days);

        vm.prank(owner);
        vesting.startVesting(address(token));

        ITokenVesting.LockInfo memory info = vesting.getLockInfo(lockId);

        assertEq(info.lockId, lockId);
        assertEq(info.token, address(token));
        assertEq(info.beneficiary, beneficiary);
        assertEq(info.totalAmount, LOCK_AMOUNT);
        assertEq(info.cliffDuration, 30 days);
        assertEq(info.vestingDuration, 100 days);
        assertEq(info.claimed, 0);
        assertEq(info.claimable, 0); // Still in cliff
        assertEq(info.tgeStart, block.timestamp);
        assertTrue(info.isStarted);
    }

    function test_GetUserLocks() public {
        vm.startPrank(factory);
        vesting.createLock(address(token), beneficiary, LOCK_AMOUNT, 0, 0);
        vesting.createLock(address(token), beneficiary, LOCK_AMOUNT, 0, 0);
        vesting.createLock(address(token), beneficiary2, LOCK_AMOUNT, 0, 0);
        vm.stopPrank();

        uint256[] memory locks = vesting.getUserLocks(beneficiary);
        assertEq(locks.length, 2);
        assertEq(locks[0], 0);
        assertEq(locks[1], 1);

        uint256[] memory locks2 = vesting.getUserLocks(beneficiary2);
        assertEq(locks2.length, 1);
        assertEq(locks2[0], 2);
    }

    function test_GetTokenLocks() public {
        ProjectToken token2 = new ProjectToken("Test2", "TEST2", TOTAL_SUPPLY, address(this));
        token2.transfer(address(vesting), LOCK_AMOUNT * 10);

        vm.startPrank(factory);
        vesting.createLock(address(token), beneficiary, LOCK_AMOUNT, 0, 0);
        vesting.createLock(address(token), beneficiary, LOCK_AMOUNT, 0, 0);
        vesting.createLock(address(token2), beneficiary, LOCK_AMOUNT, 0, 0);
        vm.stopPrank();

        uint256[] memory locks = vesting.getTokenLocks(address(token));
        assertEq(locks.length, 2);

        uint256[] memory locks2 = vesting.getTokenLocks(address(token2));
        assertEq(locks2.length, 1);
    }

    function test_GetTokenInfo() public {
        vm.prank(factory);
        vesting.createLock(address(token), beneficiary, LOCK_AMOUNT, 0, 0);

        ITokenVesting.TokenInfo memory info = vesting.getTokenInfo(address(token));
        assertEq(info.tgeStart, 0);
        assertFalse(info.isStarted);
        assertEq(info.totalLocked, LOCK_AMOUNT);
        assertEq(info.totalClaimed, 0);

        vm.prank(owner);
        vesting.startVesting(address(token));

        info = vesting.getTokenInfo(address(token));
        assertEq(info.tgeStart, block.timestamp);
        assertTrue(info.isStarted);
    }

    function test_GetUserLocksInfo() public {
        vm.startPrank(factory);
        vesting.createLock(address(token), beneficiary, LOCK_AMOUNT, 0, 0);
        vesting.createLock(address(token), beneficiary, LOCK_AMOUNT * 2, 30 days, 100 days);
        vm.stopPrank();

        ITokenVesting.LockInfo[] memory infos = vesting.getUserLocksInfo(beneficiary);
        assertEq(infos.length, 2);
        assertEq(infos[0].totalAmount, LOCK_AMOUNT);
        assertEq(infos[1].totalAmount, LOCK_AMOUNT * 2);
    }

    /*//////////////////////////////////////////////////////////////
                        OWNERSHIP TRANSFER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_TransferOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        vesting.transferOwnership(newOwner);
        assertEq(vesting.pendingOwner(), newOwner);

        vm.prank(newOwner);
        vesting.acceptOwnership();
        assertEq(vesting.owner(), newOwner);
        assertEq(vesting.pendingOwner(), address(0));
    }

    function test_TransferOwnership_RevertNotOwner() public {
        vm.expectRevert(ITokenVesting.NotOwner.selector);
        vesting.transferOwnership(makeAddr("newOwner"));
    }

    function test_AcceptOwnership_RevertNotPendingOwner() public {
        vm.prank(owner);
        vesting.transferOwnership(makeAddr("newOwner"));

        vm.expectRevert(ITokenVesting.NotOwner.selector);
        vesting.acceptOwnership();
    }
}

