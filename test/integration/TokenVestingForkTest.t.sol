// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ProjectTokenFactory} from "../../src/ProjectTokenFactory.sol";
import {TokenVesting} from "../../src/TokenVesting.sol";
import {ProjectToken} from "../../src/ProjectToken.sol";
import {ITokenVesting} from "../../src/interfaces/ITokenVesting.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";

/// @title TokenVestingForkTest
/// @notice Integration test with real tokenomics on Base mainnet fork
contract TokenVestingForkTest is Test {
    ProjectTokenFactory public factory;
    TokenVesting public vesting;

    // Protocol addresses
    address public owner = makeAddr("owner");
    
    // Real tokenomics recipients (simulating real wallets)
    address public kickoffIncubationRecipient = makeAddr("kickoffIncubation");
    address public kickoffIncubationLock = makeAddr("kickoffIncubationLock");
    address public kickoffAirdropRecipient = makeAddr("kickoffAirdrop");
    address public airdrop2Recipient = makeAddr("airdrop2");
    address public airdrop2Lock = makeAddr("airdrop2Lock");
    address public communityIncentivesRecipient = makeAddr("communityIncentives");
    address public communityIncentivesLock = makeAddr("communityIncentivesLock");
    address public builderEcosystemRecipient = makeAddr("builderEcosystem");
    address public builderEcosystemLock = makeAddr("builderEcosystemLock");
    address public investorsRecipient = makeAddr("investors");
    address public investorsLock = makeAddr("investorsLock");
    address public teamAdvisorsRecipient = makeAddr("teamAdvisors");
    address public teamAdvisorsLock = makeAddr("teamAdvisorsLock");
    address public presaleLiquidityRecipient = makeAddr("presaleLiquidity");
    address public foundationOpsRecipient = makeAddr("foundationOps");
    address public foundationOpsLock = makeAddr("foundationOpsLock");

    // Token
    address public lemonToken;

    // Constants from LEMON tokenomics
    uint256 constant TOTAL_SUPPLY = 1_000_000_000e18; // 1 billion LEMON
    
    // Allocations
    uint256 constant KICKOFF_INCUBATION = 10_000_000e18;      // 1% - 0.5% TGE + 0.5% over 6 months
    uint256 constant KICKOFF_AIRDROP = 20_000_000e18;         // 2% - 100% via point system
    uint256 constant AIRDROP_2 = 105_000_000e18;              // 10.5% - 1 month cliff + 10-12 months linear
    uint256 constant COMMUNITY_INCENTIVES = 270_000_000e18;   // 27% - 3 month cliff + 36 months
    uint256 constant BUILDER_ECOSYSTEM = 90_000_000e18;       // 9% - 1 month cliff + 6 months
    uint256 constant INVESTORS = 270_000_000e18;              // 21% - 2 month cliff + 24 months (note: 270M = 27%)
    uint256 constant TEAM_ADVISORS = 140_000_000e18;          // 14% - 2 month cliff + 18 months
    uint256 constant PRESALE_LIQUIDITY = 60_000_000e18;       // 6% - 100% TGE (note: 60M = 6%)
    uint256 constant FOUNDATION_OPS = 35_000_000e18;          // 3.5% - 2 month cliff + 18 months

    // Time constants (uint256 for warp, cast to uint32 for struct)
    uint256 constant ONE_MONTH = 30 days;
    uint256 constant ONE_YEAR = 365 days;

    // Lock IDs
    uint256 public kickoffIncubationLockId;
    uint256 public airdrop2LockId;
    uint256 public communityIncentivesLockId;
    uint256 public builderEcosystemLockId;
    uint256 public investorsLockId;
    uint256 public teamAdvisorsLockId;
    uint256 public foundationOpsLockId;

    uint256 public tgeTimestamp;

    function setUp() public {
        // Fork Base mainnet
        vm.createSelectFork("https://mainnet.base.org", 20000000);

        // Deploy contracts
        vm.startPrank(owner);
        vesting = new TokenVesting();
        factory = new ProjectTokenFactory(address(vesting));
        vesting.setFactory(address(factory));
        vm.stopPrank();

        // Create LEMON token with real tokenomics
        _createLemonToken();
    }

    function _createLemonToken() internal {
        // Build allocations array - adjust amounts to match exactly 1B
        // Current sum: 10 + 20 + 105 + 270 + 90 + 270 + 140 + 60 + 35 = 1000M ✓
        
        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](9);

        // 1. Kickoff Incubation: 1% - 50% TGE + 50% over 6 months (no cliff)
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: kickoffIncubationRecipient,
            lockOwner: kickoffIncubationLock,
            amount: KICKOFF_INCUBATION,
            tgePercent: 5000, // 50% TGE
            cliffDuration: 0,
            vestingDuration: uint32(6 * ONE_MONTH)
        });

        // 2. Kickoff Airdrop: 2% - 100% via point system (immediate)
        allocations[1] = ProjectTokenFactory.TokenAllocation({
            recipient: kickoffAirdropRecipient,
            lockOwner: address(0),
            amount: KICKOFF_AIRDROP,
            tgePercent: 10000, // 100% TGE
            cliffDuration: 0,
            vestingDuration: 0
        });

        // 3. Airdrop #2: 10.5% - 1 month cliff + 10 months linear
        allocations[2] = ProjectTokenFactory.TokenAllocation({
            recipient: airdrop2Recipient,
            lockOwner: airdrop2Lock,
            amount: AIRDROP_2,
            tgePercent: 0,
            cliffDuration: uint32(ONE_MONTH),
            vestingDuration: uint32(10 * ONE_MONTH)
        });

        // 4. Community Onchain Incentives: 27% - 3 month cliff + 36 months
        allocations[3] = ProjectTokenFactory.TokenAllocation({
            recipient: communityIncentivesRecipient,
            lockOwner: communityIncentivesLock,
            amount: COMMUNITY_INCENTIVES,
            tgePercent: 0,
            cliffDuration: uint32(3 * ONE_MONTH),
            vestingDuration: uint32(36 * ONE_MONTH)
        });

        // 5. Builder & Ecosystem: 9% - 1 month cliff + 6 months
        allocations[4] = ProjectTokenFactory.TokenAllocation({
            recipient: builderEcosystemRecipient,
            lockOwner: builderEcosystemLock,
            amount: BUILDER_ECOSYSTEM,
            tgePercent: 0,
            cliffDuration: uint32(ONE_MONTH),
            vestingDuration: uint32(6 * ONE_MONTH)
        });

        // 6. Investors: 27% - 2 month cliff + 24 months
        allocations[5] = ProjectTokenFactory.TokenAllocation({
            recipient: investorsRecipient,
            lockOwner: investorsLock,
            amount: INVESTORS,
            tgePercent: 0,
            cliffDuration: uint32(2 * ONE_MONTH),
            vestingDuration: uint32(24 * ONE_MONTH)
        });

        // 7. Team & Advisors: 14% - 2 month cliff + 18 months
        allocations[6] = ProjectTokenFactory.TokenAllocation({
            recipient: teamAdvisorsRecipient,
            lockOwner: teamAdvisorsLock,
            amount: TEAM_ADVISORS,
            tgePercent: 0,
            cliffDuration: uint32(2 * ONE_MONTH),
            vestingDuration: uint32(18 * ONE_MONTH)
        });

        // 8. Presale/Liquidity: 6% - 100% TGE
        allocations[7] = ProjectTokenFactory.TokenAllocation({
            recipient: presaleLiquidityRecipient,
            lockOwner: address(0),
            amount: PRESALE_LIQUIDITY,
            tgePercent: 10000, // 100% TGE
            cliffDuration: 0,
            vestingDuration: 0
        });

        // 9. Foundation/Ops/Hires: 3.5% - 2 month cliff + 18 months
        allocations[8] = ProjectTokenFactory.TokenAllocation({
            recipient: foundationOpsRecipient,
            lockOwner: foundationOpsLock,
            amount: FOUNDATION_OPS,
            tgePercent: 0,
            cliffDuration: uint32(2 * ONE_MONTH),
            vestingDuration: uint32(18 * ONE_MONTH)
        });

        vm.prank(owner);
        lemonToken = factory.createToken("Lemon Token", "LEMON", TOTAL_SUPPLY, allocations);

        // Store lock IDs (created in order: 0, 1, 2, 3, 4, 5, 6)
        // Only allocations with vesting create locks
        kickoffIncubationLockId = 0;  // 50% vesting
        airdrop2LockId = 1;           // 100% vesting
        communityIncentivesLockId = 2; // 100% vesting
        builderEcosystemLockId = 3;   // 100% vesting
        investorsLockId = 4;          // 100% vesting
        teamAdvisorsLockId = 5;       // 100% vesting
        foundationOpsLockId = 6;      // 100% vesting
    }

    /*//////////////////////////////////////////////////////////////
                          INITIAL STATE TESTS
    //////////////////////////////////////////////////////////////*/

    function test_InitialDistribution() public view {
        // Check immediate TGE distributions
        
        // Kickoff Incubation: 50% TGE = 5M
        assertEq(
            IERC20(lemonToken).balanceOf(kickoffIncubationRecipient),
            KICKOFF_INCUBATION / 2,
            "Kickoff Incubation TGE incorrect"
        );

        // Kickoff Airdrop: 100% TGE = 20M
        assertEq(
            IERC20(lemonToken).balanceOf(kickoffAirdropRecipient),
            KICKOFF_AIRDROP,
            "Kickoff Airdrop TGE incorrect"
        );

        // Presale/Liquidity: 100% TGE = 60M
        assertEq(
            IERC20(lemonToken).balanceOf(presaleLiquidityRecipient),
            PRESALE_LIQUIDITY,
            "Presale/Liquidity TGE incorrect"
        );

        // Other allocations should have 0 balance (all in vesting)
        assertEq(IERC20(lemonToken).balanceOf(airdrop2Recipient), 0, "Airdrop2 should have 0 TGE");
        assertEq(IERC20(lemonToken).balanceOf(communityIncentivesRecipient), 0, "Community should have 0 TGE");
        assertEq(IERC20(lemonToken).balanceOf(builderEcosystemRecipient), 0, "Builder should have 0 TGE");
        assertEq(IERC20(lemonToken).balanceOf(investorsRecipient), 0, "Investors should have 0 TGE");
        assertEq(IERC20(lemonToken).balanceOf(teamAdvisorsRecipient), 0, "Team should have 0 TGE");
        assertEq(IERC20(lemonToken).balanceOf(foundationOpsRecipient), 0, "Foundation should have 0 TGE");

        // Verify vesting contract holds remaining tokens
        uint256 expectedInVesting = KICKOFF_INCUBATION / 2  // 5M from incubation
            + AIRDROP_2                                      // 105M
            + COMMUNITY_INCENTIVES                           // 270M
            + BUILDER_ECOSYSTEM                              // 90M
            + INVESTORS                                      // 270M
            + TEAM_ADVISORS                                  // 140M
            + FOUNDATION_OPS;                                // 35M
        
        assertEq(
            IERC20(lemonToken).balanceOf(address(vesting)),
            expectedInVesting,
            "Vesting contract balance incorrect"
        );

        console.log("=== Initial Distribution ===");
        console.log("TGE distributed:", (KICKOFF_INCUBATION / 2 + KICKOFF_AIRDROP + PRESALE_LIQUIDITY) / 1e18, "LEMON");
        console.log("In vesting:", expectedInVesting / 1e18, "LEMON");
        console.log("Total:", TOTAL_SUPPLY / 1e18, "LEMON");
    }

    function test_VestingNotStarted_NoClaimable() public view {
        // Before TGE starts, nothing should be claimable
        assertEq(vesting.getClaimable(kickoffIncubationLockId), 0, "Should be 0 before TGE");
        assertEq(vesting.getClaimable(airdrop2LockId), 0, "Should be 0 before TGE");
        assertEq(vesting.getClaimable(investorsLockId), 0, "Should be 0 before TGE");
    }

    /*//////////////////////////////////////////////////////////////
                          TGE + TIME PROGRESSION
    //////////////////////////////////////////////////////////////*/

    function test_FullVestingTimeline() public {
        console.log("\n=== Full Vesting Timeline Test ===\n");

        // Start vesting (TGE)
        vm.prank(owner);
        vesting.startVesting(lemonToken);
        tgeTimestamp = block.timestamp;

        console.log("TGE started at timestamp:", tgeTimestamp);
        console.log("");

        // ============ DAY 0 (TGE) ============
        console.log("--- DAY 0 (TGE) ---");
        _logClaimableAmounts();
        
        // Only Kickoff Incubation has no cliff, so vesting starts immediately
        // But at t=0, vested amount is 0 (linear starts)
        assertEq(vesting.getClaimable(kickoffIncubationLockId), 0, "Incubation: 0 at TGE start");
        assertEq(vesting.getClaimable(airdrop2LockId), 0, "Airdrop2: 0 (in 1 month cliff)");
        assertEq(vesting.getClaimable(communityIncentivesLockId), 0, "Community: 0 (in 3 month cliff)");

        // ============ MONTH 1 ============
        vm.warp(tgeTimestamp + ONE_MONTH);
        console.log("\n--- MONTH 1 ---");
        _logClaimableAmounts();

        // Kickoff Incubation: 1/6 of vesting (5M / 6 = 833,333 LEMON)
        uint256 expectedIncubation1M = (KICKOFF_INCUBATION / 2) / 6;
        assertApproxEqRel(
            vesting.getClaimable(kickoffIncubationLockId),
            expectedIncubation1M,
            0.01e18, // 1% tolerance
            "Incubation: ~833k at 1 month"
        );

        // Airdrop2: Cliff just ended, 0 vested yet
        assertEq(vesting.getClaimable(airdrop2LockId), 0, "Airdrop2: 0 (cliff just ended)");

        // Builder/Ecosystem: Cliff just ended, 0 vested yet
        assertEq(vesting.getClaimable(builderEcosystemLockId), 0, "Builder: 0 (cliff just ended)");

        // ============ MONTH 2 ============
        vm.warp(tgeTimestamp + 2 * ONE_MONTH);
        console.log("\n--- MONTH 2 ---");
        _logClaimableAmounts();

        // Kickoff Incubation: 2/6 of vesting
        uint256 expectedIncubation2M = (KICKOFF_INCUBATION / 2) * 2 / 6;
        assertApproxEqRel(
            vesting.getClaimable(kickoffIncubationLockId),
            expectedIncubation2M,
            0.01e18,
            "Incubation: ~1.66M at 2 months"
        );

        // Airdrop2: 1 month of vesting (1/10 of 105M = 10.5M)
        uint256 expectedAirdrop2M = AIRDROP_2 / 10;
        assertApproxEqRel(
            vesting.getClaimable(airdrop2LockId),
            expectedAirdrop2M,
            0.01e18,
            "Airdrop2: ~10.5M at 2 months"
        );

        // Builder/Ecosystem: 1 month of vesting (1/6 of 90M = 15M)
        uint256 expectedBuilder2M = BUILDER_ECOSYSTEM / 6;
        assertApproxEqRel(
            vesting.getClaimable(builderEcosystemLockId),
            expectedBuilder2M,
            0.01e18,
            "Builder: ~15M at 2 months"
        );

        // Investors/Team/Foundation: Cliff just ended (2 months)
        assertEq(vesting.getClaimable(investorsLockId), 0, "Investors: 0 (cliff just ended)");
        assertEq(vesting.getClaimable(teamAdvisorsLockId), 0, "Team: 0 (cliff just ended)");
        assertEq(vesting.getClaimable(foundationOpsLockId), 0, "Foundation: 0 (cliff just ended)");

        // ============ MONTH 3 ============
        vm.warp(tgeTimestamp + 3 * ONE_MONTH);
        console.log("\n--- MONTH 3 ---");
        _logClaimableAmounts();

        // Community Incentives: Cliff just ended (3 months), 0 vested yet
        assertEq(vesting.getClaimable(communityIncentivesLockId), 0, "Community: 0 (cliff just ended)");

        // Investors: 1 month of vesting (1/24 of 270M = 11.25M)
        uint256 expectedInvestors3M = INVESTORS / 24;
        assertApproxEqRel(
            vesting.getClaimable(investorsLockId),
            expectedInvestors3M,
            0.01e18,
            "Investors: ~11.25M at 3 months"
        );

        // ============ MONTH 6 ============
        vm.warp(tgeTimestamp + 6 * ONE_MONTH);
        console.log("\n--- MONTH 6 ---");
        _logClaimableAmounts();

        // Kickoff Incubation: FULLY VESTED (6 months)
        assertEq(
            vesting.getClaimable(kickoffIncubationLockId),
            KICKOFF_INCUBATION / 2,
            "Incubation: Fully vested at 6 months"
        );

        // Builder/Ecosystem: 5/6 of vesting (cliff at 1 month, so 5 months of vesting)
        // Wait, vesting starts after cliff, so at month 6 we have 5 months of vesting out of 6
        // (6 - 1 cliff) / 6 = 5/6
        uint256 expectedBuilder6M = BUILDER_ECOSYSTEM * 5 / 6;
        assertApproxEqRel(
            vesting.getClaimable(builderEcosystemLockId),
            expectedBuilder6M,
            0.01e18,
            "Builder: ~75M at 6 months"
        );

        // ============ MONTH 7 ============
        vm.warp(tgeTimestamp + 7 * ONE_MONTH);
        console.log("\n--- MONTH 7 ---");
        _logClaimableAmounts();

        // Builder/Ecosystem: FULLY VESTED (1 cliff + 6 vesting = 7 months)
        assertEq(
            vesting.getClaimable(builderEcosystemLockId),
            BUILDER_ECOSYSTEM,
            "Builder: Fully vested at 7 months"
        );

        // ============ MONTH 11 ============
        vm.warp(tgeTimestamp + 11 * ONE_MONTH);
        console.log("\n--- MONTH 11 ---");
        _logClaimableAmounts();

        // Airdrop2: FULLY VESTED (1 cliff + 10 vesting = 11 months)
        assertEq(
            vesting.getClaimable(airdrop2LockId),
            AIRDROP_2,
            "Airdrop2: Fully vested at 11 months"
        );

        // ============ MONTH 20 ============
        vm.warp(tgeTimestamp + 20 * ONE_MONTH);
        console.log("\n--- MONTH 20 ---");
        _logClaimableAmounts();

        // Team & Advisors: FULLY VESTED (2 cliff + 18 vesting = 20 months)
        assertEq(
            vesting.getClaimable(teamAdvisorsLockId),
            TEAM_ADVISORS,
            "Team: Fully vested at 20 months"
        );

        // Foundation: FULLY VESTED (2 cliff + 18 vesting = 20 months)
        assertEq(
            vesting.getClaimable(foundationOpsLockId),
            FOUNDATION_OPS,
            "Foundation: Fully vested at 20 months"
        );

        // ============ MONTH 26 ============
        vm.warp(tgeTimestamp + 26 * ONE_MONTH);
        console.log("\n--- MONTH 26 ---");
        _logClaimableAmounts();

        // Investors: FULLY VESTED (2 cliff + 24 vesting = 26 months)
        assertEq(
            vesting.getClaimable(investorsLockId),
            INVESTORS,
            "Investors: Fully vested at 26 months"
        );

        // ============ MONTH 39 ============
        vm.warp(tgeTimestamp + 39 * ONE_MONTH);
        console.log("\n--- MONTH 39 ---");
        _logClaimableAmounts();

        // Community Incentives: FULLY VESTED (3 cliff + 36 vesting = 39 months)
        assertEq(
            vesting.getClaimable(communityIncentivesLockId),
            COMMUNITY_INCENTIVES,
            "Community: Fully vested at 39 months"
        );

        console.log("\n=== All Vesting Complete ===");
    }

    function test_ClaimAndVerifyBalances() public {
        // Start vesting
        vm.prank(owner);
        vesting.startVesting(lemonToken);
        tgeTimestamp = block.timestamp;

        // Fast forward to month 3
        vm.warp(tgeTimestamp + 3 * ONE_MONTH);

        // Get claimable amounts
        uint256 incubationClaimable = vesting.getClaimable(kickoffIncubationLockId);
        uint256 airdrop2Claimable = vesting.getClaimable(airdrop2LockId);
        uint256 builderClaimable = vesting.getClaimable(builderEcosystemLockId);
        uint256 investorsClaimable = vesting.getClaimable(investorsLockId);

        console.log("\n=== Claim Test at Month 3 ===");
        console.log("Incubation claimable:", incubationClaimable / 1e18);
        console.log("Airdrop2 claimable:", airdrop2Claimable / 1e18);
        console.log("Builder claimable:", builderClaimable / 1e18);
        console.log("Investors claimable:", investorsClaimable / 1e18);

        // Claim Kickoff Incubation
        uint256 incubationLockBalanceBefore = IERC20(lemonToken).balanceOf(kickoffIncubationLock);
        vm.prank(kickoffIncubationLock);
        vesting.claim(kickoffIncubationLockId);
        uint256 incubationLockBalanceAfter = IERC20(lemonToken).balanceOf(kickoffIncubationLock);
        
        assertEq(
            incubationLockBalanceAfter - incubationLockBalanceBefore,
            incubationClaimable,
            "Incubation claim amount mismatch"
        );

        // Claim Investors
        vm.prank(investorsLock);
        vesting.claim(investorsLockId);
        assertEq(
            IERC20(lemonToken).balanceOf(investorsLock),
            investorsClaimable,
            "Investors claim amount mismatch"
        );

        // Verify nothing more to claim immediately
        assertEq(vesting.getClaimable(kickoffIncubationLockId), 0, "Should be 0 after claim");
        assertEq(vesting.getClaimable(investorsLockId), 0, "Should be 0 after claim");

        // Fast forward 1 more month
        vm.warp(tgeTimestamp + 4 * ONE_MONTH);

        // Should have new claimable amounts
        uint256 newIncubationClaimable = vesting.getClaimable(kickoffIncubationLockId);
        uint256 newInvestorsClaimable = vesting.getClaimable(investorsLockId);

        console.log("\n--- After 1 more month ---");
        console.log("New Incubation claimable:", newIncubationClaimable / 1e18);
        console.log("New Investors claimable:", newInvestorsClaimable / 1e18);

        assertTrue(newIncubationClaimable > 0, "Should have new claimable");
        assertTrue(newInvestorsClaimable > 0, "Should have new claimable");
    }

    function test_ClaimMultiple() public {
        // Start vesting
        vm.prank(owner);
        vesting.startVesting(lemonToken);
        tgeTimestamp = block.timestamp;

        // Fast forward to after all cliffs
        vm.warp(tgeTimestamp + 6 * ONE_MONTH);

        // Create a user with multiple locks
        // First, let's check getUserLocks for lock owners with single locks
        uint256[] memory investorLocks = vesting.getUserLocks(investorsLock);
        assertEq(investorLocks.length, 1, "Investor should have 1 lock");

        // Claim
        uint256 balanceBefore = IERC20(lemonToken).balanceOf(investorsLock);
        
        vm.prank(investorsLock);
        vesting.claimMultiple(investorLocks);
        
        uint256 balanceAfter = IERC20(lemonToken).balanceOf(investorsLock);
        assertTrue(balanceAfter > balanceBefore, "Should have received tokens");
    }

    function test_GetLockInfo() public {
        // Start vesting
        vm.prank(owner);
        vesting.startVesting(lemonToken);
        tgeTimestamp = block.timestamp;

        // Get lock info for investors
        ITokenVesting.LockInfo memory info = vesting.getLockInfo(investorsLockId);

        console.log("\n=== Investors Lock Info ===");
        console.log("Lock ID:", info.lockId);
        console.log("Token:", info.token);
        console.log("Beneficiary:", info.beneficiary);
        console.log("Total Amount:", info.totalAmount / 1e18);
        console.log("Cliff Duration:", info.cliffDuration / 1 days, "days");
        console.log("Vesting Duration:", info.vestingDuration / 1 days, "days");
        console.log("Claimed:", info.claimed / 1e18);
        console.log("Claimable:", info.claimable / 1e18);
        console.log("TGE Start:", info.tgeStart);
        console.log("Is Started:", info.isStarted);

        assertEq(info.token, lemonToken, "Token mismatch");
        assertEq(info.beneficiary, investorsLock, "Beneficiary mismatch");
        assertEq(info.totalAmount, INVESTORS, "Amount mismatch");
        assertEq(info.cliffDuration, 2 * ONE_MONTH, "Cliff mismatch");
        assertEq(info.vestingDuration, 24 * ONE_MONTH, "Vesting duration mismatch");
        assertTrue(info.isStarted, "Should be started");
    }

    function test_GetTokenInfo() public {
        // Before TGE
        ITokenVesting.TokenInfo memory infoBefore = vesting.getTokenInfo(lemonToken);
        assertFalse(infoBefore.isStarted, "Should not be started");

        // Start vesting
        vm.prank(owner);
        vesting.startVesting(lemonToken);

        // After TGE
        ITokenVesting.TokenInfo memory infoAfter = vesting.getTokenInfo(lemonToken);
        
        console.log("\n=== Token Vesting Info ===");
        console.log("TGE Start:", infoAfter.tgeStart);
        console.log("Is Started:", infoAfter.isStarted);
        console.log("Total Locked:", infoAfter.totalLocked / 1e18);
        console.log("Total Claimed:", infoAfter.totalClaimed / 1e18);

        assertTrue(infoAfter.isStarted, "Should be started");
        assertEq(infoAfter.tgeStart, block.timestamp, "TGE timestamp mismatch");
    }

    function test_MathPrecision() public {
        // Start vesting
        vm.prank(owner);
        vesting.startVesting(lemonToken);
        tgeTimestamp = block.timestamp;

        console.log("\n=== Math Precision Test ===");

        // Test at various time points
        uint256[] memory timePoints = new uint256[](10);
        timePoints[0] = 1 days;
        timePoints[1] = 7 days;
        timePoints[2] = 15 days;
        timePoints[3] = ONE_MONTH;
        timePoints[4] = 45 days;
        timePoints[5] = 2 * ONE_MONTH;
        timePoints[6] = 3 * ONE_MONTH;
        timePoints[7] = 6 * ONE_MONTH;
        timePoints[8] = ONE_YEAR;
        timePoints[9] = 2 * ONE_YEAR;

        for (uint256 i = 0; i < timePoints.length; i++) {
            vm.warp(tgeTimestamp + timePoints[i]);
            
            // Kickoff Incubation: no cliff, 6 month linear
            // Expected: min(elapsed / 6 months, 1) * 5M
            uint256 incubationClaimable = vesting.getClaimable(kickoffIncubationLockId);
            uint256 expectedIncubation;
            if (timePoints[i] >= 6 * ONE_MONTH) {
                expectedIncubation = KICKOFF_INCUBATION / 2;
            } else {
                expectedIncubation = (KICKOFF_INCUBATION / 2) * timePoints[i] / (6 * ONE_MONTH);
            }
            
            assertApproxEqRel(
                incubationClaimable,
                expectedIncubation,
                0.001e18, // 0.1% tolerance
                string.concat("Incubation math at ", vm.toString(timePoints[i] / 1 days), " days")
            );
        }
    }

    /*//////////////////////////////////////////////////////////////
                              HELPERS
    //////////////////////////////////////////////////////////////*/

    function _logClaimableAmounts() internal view {
        console.log("Kickoff Incubation:", vesting.getClaimable(kickoffIncubationLockId) / 1e18, "LEMON");
        console.log("Airdrop2:", vesting.getClaimable(airdrop2LockId) / 1e18, "LEMON");
        console.log("Community Incentives:", vesting.getClaimable(communityIncentivesLockId) / 1e18, "LEMON");
        console.log("Builder/Ecosystem:", vesting.getClaimable(builderEcosystemLockId) / 1e18, "LEMON");
        console.log("Investors:", vesting.getClaimable(investorsLockId) / 1e18, "LEMON");
        console.log("Team & Advisors:", vesting.getClaimable(teamAdvisorsLockId) / 1e18, "LEMON");
        console.log("Foundation/Ops:", vesting.getClaimable(foundationOpsLockId) / 1e18, "LEMON");
    }
}

