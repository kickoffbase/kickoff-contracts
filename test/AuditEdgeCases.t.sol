// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ProjectTokenFactory} from "../src/ProjectTokenFactory.sol";
import {TokenVesting} from "../src/TokenVesting.sol";
import {ProjectToken} from "../src/ProjectToken.sol";
import {ITokenVesting} from "../src/interfaces/ITokenVesting.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

/// @title AuditEdgeCases
/// @notice Tests for edge cases found during audit
contract AuditEdgeCasesTest is Test {
    ProjectTokenFactory public factory;
    TokenVesting public vesting;

    address public owner = makeAddr("owner");
    address public user = makeAddr("user");
    address public recipient = makeAddr("recipient");
    address public lockOwner = makeAddr("lockOwner");

    uint256 constant TOTAL_SUPPLY = 1_000_000_000e18;

    function setUp() public {
        vm.startPrank(owner);
        vesting = new TokenVesting();
        factory = new ProjectTokenFactory(address(vesting));
        vesting.setFactory(address(factory));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                    EDGE CASE: ZERO VESTING DURATION
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: vestingDuration = 0 with cliff - all available after cliff
    function test_EdgeCase_ZeroVestingWithCliff() public {
        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](1);
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: recipient,
            lockOwner: lockOwner,
            amount: TOTAL_SUPPLY,
            tgePercent: 0,
            cliffDuration: uint32(30 days),
            vestingDuration: 0  // All available immediately after cliff
        });

        vm.prank(owner);
        address token = factory.createToken("Test", "TST", TOTAL_SUPPLY, allocations);

        vm.prank(owner);
        vesting.startVesting(token);

        // Before cliff - nothing claimable
        assertEq(vesting.getClaimable(0), 0, "Should be 0 before cliff");

        // After cliff - ALL should be available (not linear)
        vm.warp(block.timestamp + 30 days);
        assertEq(vesting.getClaimable(0), TOTAL_SUPPLY, "All should be available after cliff");

        // Claim all
        vm.prank(lockOwner);
        vesting.claim(0);
        assertEq(IERC20(token).balanceOf(lockOwner), TOTAL_SUPPLY);
    }

    /// @notice Test: vestingDuration = 0 and cliffDuration = 0 - all available at TGE
    function test_EdgeCase_ZeroVestingZeroCliff() public {
        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](1);
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: recipient,
            lockOwner: lockOwner,
            amount: TOTAL_SUPPLY,
            tgePercent: 0,  // 0% TGE
            cliffDuration: 0,
            vestingDuration: 0  // All available immediately
        });

        vm.prank(owner);
        address token = factory.createToken("Test", "TST", TOTAL_SUPPLY, allocations);

        vm.prank(owner);
        vesting.startVesting(token);

        // All should be available immediately
        assertEq(vesting.getClaimable(0), TOTAL_SUPPLY, "All should be available immediately");
    }

    /*//////////////////////////////////////////////////////////////
                    EDGE CASE: ROUNDING IN TGE AMOUNT
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: Rounding in TGE calculation doesn't lose tokens
    function test_EdgeCase_TGERounding() public {
        // Use an amount that doesn't divide evenly
        uint256 amount = 1000000000000000001; // 1e18 + 1 wei
        uint16 tgePercent = 3333; // 33.33%
        
        // Expected: (1000000000000000001 * 3333) / 10000 = 333300000000000000.0333...
        // Solidity rounds down to 333300000000000000
        uint256 expectedTge = (amount * tgePercent) / 10000;
        uint256 expectedVesting = amount - expectedTge;

        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](1);
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: recipient,
            lockOwner: lockOwner,
            amount: amount,
            tgePercent: tgePercent,
            cliffDuration: 0,
            vestingDuration: uint32(30 days)
        });

        vm.prank(owner);
        address token = factory.createToken("Test", "TST", amount, allocations);

        // Verify no tokens are lost
        uint256 recipientBalance = IERC20(token).balanceOf(recipient);
        uint256 vestingBalance = IERC20(token).balanceOf(address(vesting));

        assertEq(recipientBalance, expectedTge, "TGE amount mismatch");
        assertEq(vestingBalance, expectedVesting, "Vesting amount mismatch");
        assertEq(recipientBalance + vestingBalance, amount, "Tokens lost in rounding!");
    }

    /// @notice Test: Edge case with 1 wei amount
    function test_EdgeCase_OneWeiAmount() public {
        uint256 amount = 1; // 1 wei
        
        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](1);
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: recipient,
            lockOwner: lockOwner,
            amount: amount,
            tgePercent: 5000, // 50%
            cliffDuration: 0,
            vestingDuration: uint32(30 days)
        });

        vm.prank(owner);
        address token = factory.createToken("Test", "TST", amount, allocations);

        // 50% of 1 wei = 0 wei (rounds down)
        assertEq(IERC20(token).balanceOf(recipient), 0, "TGE should be 0 for 1 wei at 50%");
        assertEq(IERC20(token).balanceOf(address(vesting)), 1, "All should go to vesting");
    }

    /*//////////////////////////////////////////////////////////////
                    EDGE CASE: VERY LONG VESTING PERIODS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: Very long vesting period (100 years)
    function test_EdgeCase_VeryLongVesting() public {
        uint32 oneHundredYears = uint32(100 * 365 days);
        
        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](1);
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: recipient,
            lockOwner: lockOwner,
            amount: TOTAL_SUPPLY,
            tgePercent: 0,
            cliffDuration: 0,
            vestingDuration: oneHundredYears
        });

        vm.prank(owner);
        address token = factory.createToken("Test", "TST", TOTAL_SUPPLY, allocations);

        vm.prank(owner);
        vesting.startVesting(token);

        // After 1 year - should be 1% vested
        vm.warp(block.timestamp + 365 days);
        uint256 claimable = vesting.getClaimable(0);
        assertApproxEqRel(claimable, TOTAL_SUPPLY / 100, 0.01e18, "Should be ~1% after 1 year");

        // After 100 years - should be fully vested
        vm.warp(block.timestamp + 99 * 365 days);
        assertEq(vesting.getClaimable(0), TOTAL_SUPPLY, "Should be fully vested after 100 years");
    }

    /*//////////////////////////////////////////////////////////////
                    EDGE CASE: MULTIPLE CLAIMS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: Multiple partial claims work correctly
    function test_EdgeCase_MultiplePartialClaims() public {
        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](1);
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: recipient,
            lockOwner: lockOwner,
            amount: TOTAL_SUPPLY,
            tgePercent: 0,
            cliffDuration: 0,
            vestingDuration: uint32(100 days)
        });

        vm.prank(owner);
        address token = factory.createToken("Test", "TST", TOTAL_SUPPLY, allocations);

        vm.prank(owner);
        vesting.startVesting(token);

        uint256 totalClaimed = 0;

        // Claim every 10 days
        for (uint256 i = 1; i <= 10; i++) {
            vm.warp(block.timestamp + 10 days);
            
            uint256 claimable = vesting.getClaimable(0);
            assertTrue(claimable > 0, "Should have claimable amount");
            
            vm.prank(lockOwner);
            vesting.claim(0);
            
            totalClaimed += claimable;
        }

        // Should have claimed everything
        assertEq(totalClaimed, TOTAL_SUPPLY, "Should have claimed total supply");
        assertEq(IERC20(token).balanceOf(lockOwner), TOTAL_SUPPLY, "Lock owner should have all tokens");
        assertEq(vesting.getClaimable(0), 0, "Nothing left to claim");
    }

    /// @notice Test: Claiming after full vesting multiple times
    function test_EdgeCase_ClaimAfterFullVesting() public {
        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](1);
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: recipient,
            lockOwner: lockOwner,
            amount: TOTAL_SUPPLY,
            tgePercent: 0,
            cliffDuration: 0,
            vestingDuration: uint32(30 days)
        });

        vm.prank(owner);
        address token = factory.createToken("Test", "TST", TOTAL_SUPPLY, allocations);

        vm.prank(owner);
        vesting.startVesting(token);

        // Wait for full vesting
        vm.warp(block.timestamp + 30 days);

        // First claim - should work
        vm.prank(lockOwner);
        vesting.claim(0);
        assertEq(IERC20(token).balanceOf(lockOwner), TOTAL_SUPPLY);

        // Second claim - should revert with NothingToClaim
        vm.prank(lockOwner);
        vm.expectRevert(ITokenVesting.NothingToClaim.selector);
        vesting.claim(0);

        // Wait more time - still nothing to claim
        vm.warp(block.timestamp + 365 days);
        assertEq(vesting.getClaimable(0), 0, "Should still be 0");
    }

    /*//////////////////////////////////////////////////////////////
                    EDGE CASE: TIMESTAMP OVERFLOW
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: Far future timestamp doesn't cause issues
    function test_EdgeCase_FarFutureTimestamp() public {
        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](1);
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: recipient,
            lockOwner: lockOwner,
            amount: TOTAL_SUPPLY,
            tgePercent: 0,
            cliffDuration: uint32(30 days),
            vestingDuration: uint32(365 days)
        });

        vm.prank(owner);
        address token = factory.createToken("Test", "TST", TOTAL_SUPPLY, allocations);

        vm.prank(owner);
        vesting.startVesting(token);

        // Warp to year 2100
        vm.warp(4102444800); // Jan 1, 2100

        // Should be fully vested (capped at totalAmount)
        assertEq(vesting.getClaimable(0), TOTAL_SUPPLY, "Should be fully vested in far future");
    }

    /*//////////////////////////////////////////////////////////////
                    EDGE CASE: CLAIM NON-EXISTENT LOCK
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: Claiming non-existent lock reverts
    function test_EdgeCase_ClaimNonExistentLock() public {
        vm.prank(user);
        vm.expectRevert(ITokenVesting.LockNotFound.selector);
        vesting.claim(999);
    }

    /// @notice Test: Getting claimable for non-existent lock returns 0
    function test_EdgeCase_GetClaimableNonExistentLock() public view {
        assertEq(vesting.getClaimable(999), 0, "Should return 0 for non-existent lock");
    }

    /*//////////////////////////////////////////////////////////////
                    EDGE CASE: CLAIM BEFORE TGE
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: Claiming before TGE started
    function test_EdgeCase_ClaimBeforeTGE() public {
        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](1);
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: recipient,
            lockOwner: lockOwner,
            amount: TOTAL_SUPPLY,
            tgePercent: 0,
            cliffDuration: 0,
            vestingDuration: uint32(30 days)
        });

        vm.prank(owner);
        factory.createToken("Test", "TST", TOTAL_SUPPLY, allocations);

        // Don't start vesting
        assertEq(vesting.getClaimable(0), 0, "Should be 0 before TGE");

        vm.prank(lockOwner);
        vm.expectRevert(ITokenVesting.NothingToClaim.selector);
        vesting.claim(0);
    }

    /*//////////////////////////////////////////////////////////////
                    EDGE CASE: MAX UINT256 AMOUNT
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: Very large amounts don't overflow
    function test_EdgeCase_VeryLargeAmount() public {
        // Use a large but reasonable amount
        uint256 largeAmount = type(uint128).max; // ~3.4e38

        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](1);
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: recipient,
            lockOwner: lockOwner,
            amount: largeAmount,
            tgePercent: 5000,
            cliffDuration: 0,
            vestingDuration: uint32(365 days)
        });

        vm.prank(owner);
        address token = factory.createToken("Test", "TST", largeAmount, allocations);

        vm.prank(owner);
        vesting.startVesting(token);

        // After half the vesting period
        vm.warp(block.timestamp + 182 days);

        uint256 claimable = vesting.getClaimable(0);
        uint256 expectedVesting = largeAmount / 2; // 50% went to TGE
        uint256 expectedClaimable = expectedVesting * 182 / 365;
        
        assertApproxEqRel(claimable, expectedClaimable, 0.01e18, "Large amount calculation should work");
    }

    /*//////////////////////////////////////////////////////////////
                    EDGE CASE: SAME RECIPIENT AND LOCK OWNER
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: recipient == lockOwner is valid
    function test_EdgeCase_SameRecipientAndLockOwner() public {
        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](1);
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: user,
            lockOwner: user,  // Same address
            amount: TOTAL_SUPPLY,
            tgePercent: 5000, // 50%
            cliffDuration: 0,
            vestingDuration: uint32(30 days)
        });

        vm.prank(owner);
        address token = factory.createToken("Test", "TST", TOTAL_SUPPLY, allocations);

        // User gets TGE immediately
        assertEq(IERC20(token).balanceOf(user), TOTAL_SUPPLY / 2, "User should have TGE tokens");

        // Start vesting and claim
        vm.prank(owner);
        vesting.startVesting(token);

        vm.warp(block.timestamp + 30 days);
        
        vm.prank(user);
        vesting.claim(0);

        // User should have everything
        assertEq(IERC20(token).balanceOf(user), TOTAL_SUPPLY, "User should have all tokens");
    }

    /*//////////////////////////////////////////////////////////////
                    EDGE CASE: MULTIPLE ALLOCATIONS TO SAME ADDRESS
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: Multiple allocations to same lock owner
    function test_EdgeCase_MultipleAllocationsToSameOwner() public {
        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](3);
        
        // 3 different allocations, same lock owner
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: recipient,
            lockOwner: lockOwner,
            amount: TOTAL_SUPPLY / 3,
            tgePercent: 0,
            cliffDuration: 0,
            vestingDuration: uint32(30 days)
        });
        allocations[1] = ProjectTokenFactory.TokenAllocation({
            recipient: recipient,
            lockOwner: lockOwner,
            amount: TOTAL_SUPPLY / 3,
            tgePercent: 0,
            cliffDuration: uint32(30 days),
            vestingDuration: uint32(60 days)
        });
        allocations[2] = ProjectTokenFactory.TokenAllocation({
            recipient: recipient,
            lockOwner: lockOwner,
            amount: TOTAL_SUPPLY / 3 + TOTAL_SUPPLY % 3, // Handle remainder
            tgePercent: 0,
            cliffDuration: uint32(60 days),
            vestingDuration: uint32(90 days)
        });

        vm.prank(owner);
        address token = factory.createToken("Test", "TST", TOTAL_SUPPLY, allocations);

        // Lock owner should have 3 locks
        uint256[] memory locks = vesting.getUserLocks(lockOwner);
        assertEq(locks.length, 3, "Should have 3 locks");

        vm.prank(owner);
        vesting.startVesting(token);

        // Claim multiple
        vm.warp(block.timestamp + 150 days); // All should be fully vested

        vm.prank(lockOwner);
        vesting.claimMultiple(locks);

        assertEq(IERC20(token).balanceOf(lockOwner), TOTAL_SUPPLY, "Should have all tokens");
    }

    /*//////////////////////////////////////////////////////////////
                    EDGE CASE: 100% TGE DOESN'T CREATE LOCK
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: 100% TGE allocation doesn't create a vesting lock
    function test_EdgeCase_FullTGENoLock() public {
        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](2);
        
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: recipient,
            lockOwner: address(0), // Not used
            amount: TOTAL_SUPPLY / 2,
            tgePercent: 10000, // 100%
            cliffDuration: 0,
            vestingDuration: 0
        });
        allocations[1] = ProjectTokenFactory.TokenAllocation({
            recipient: user,
            lockOwner: lockOwner,
            amount: TOTAL_SUPPLY / 2,
            tgePercent: 0,
            cliffDuration: 0,
            vestingDuration: uint32(30 days)
        });

        vm.prank(owner);
        address token = factory.createToken("Test", "TST", TOTAL_SUPPLY, allocations);

        // Only 1 lock should be created (for the second allocation)
        assertEq(vesting.lockCount(), 1, "Only 1 lock should be created");

        // Recipient should have their tokens immediately
        assertEq(IERC20(token).balanceOf(recipient), TOTAL_SUPPLY / 2, "Recipient should have TGE tokens");

        // LockOwner's tokens are in vesting
        assertEq(IERC20(token).balanceOf(address(vesting)), TOTAL_SUPPLY / 2, "Vesting should have locked tokens");
    }

    /*//////////////////////////////////////////////////////////////
                    EDGE CASE: PRECISION AT VESTING BOUNDARIES
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: Exact precision at vesting end boundary
    function test_EdgeCase_ExactVestingEndBoundary() public {
        uint256 amount = 1e18; // 1 token
        uint32 vestingDuration = uint32(100 days);

        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](1);
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: recipient,
            lockOwner: lockOwner,
            amount: amount,
            tgePercent: 0,
            cliffDuration: 0,
            vestingDuration: vestingDuration
        });

        vm.prank(owner);
        address token = factory.createToken("Test", "TST", amount, allocations);

        vm.prank(owner);
        vesting.startVesting(token);
        uint256 startTime = block.timestamp;

        // At exactly vesting end
        vm.warp(startTime + vestingDuration);
        assertEq(vesting.getClaimable(0), amount, "Should be exact amount at boundary");

        // 1 second before end
        vm.warp(startTime + vestingDuration - 1);
        uint256 claimableBefore = vesting.getClaimable(0);
        assertTrue(claimableBefore < amount, "Should be less than total 1 second before");

        // 1 second after end
        vm.warp(startTime + vestingDuration + 1);
        assertEq(vesting.getClaimable(0), amount, "Should be capped at total after end");
    }

    /*//////////////////////////////////////////////////////////////
                    EDGE CASE: EMPTY ALLOCATIONS ARRAY
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: Empty allocations array reverts
    function test_EdgeCase_EmptyAllocations() public {
        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](0);

        vm.prank(owner);
        vm.expectRevert(ProjectTokenFactory.InvalidAllocation.selector);
        factory.createToken("Test", "TST", TOTAL_SUPPLY, allocations);
    }

    /*//////////////////////////////////////////////////////////////
                    EDGE CASE: CLIFF EXACTLY EQUALS BLOCK.TIMESTAMP
    //////////////////////////////////////////////////////////////*/

    /// @notice Test: Behavior at exact cliff end timestamp
    function test_EdgeCase_ExactCliffEnd() public {
        uint32 cliffDuration = uint32(30 days);

        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](1);
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: recipient,
            lockOwner: lockOwner,
            amount: TOTAL_SUPPLY,
            tgePercent: 0,
            cliffDuration: cliffDuration,
            vestingDuration: uint32(60 days)
        });

        vm.prank(owner);
        address token = factory.createToken("Test", "TST", TOTAL_SUPPLY, allocations);

        vm.prank(owner);
        vesting.startVesting(token);
        uint256 startTime = block.timestamp;

        // 1 second before cliff ends - nothing claimable
        vm.warp(startTime + cliffDuration - 1);
        assertEq(vesting.getClaimable(0), 0, "Should be 0 before cliff");

        // Exactly at cliff end - linear vesting starts, 0 vested yet
        vm.warp(startTime + cliffDuration);
        assertEq(vesting.getClaimable(0), 0, "Should be 0 at exact cliff end");

        // 1 second after cliff - small amount vested
        vm.warp(startTime + cliffDuration + 1);
        assertTrue(vesting.getClaimable(0) > 0, "Should have vested after cliff");
    }
}

