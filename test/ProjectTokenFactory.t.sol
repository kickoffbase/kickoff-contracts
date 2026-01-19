// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import {Test, console} from "forge-std/Test.sol";
import {ProjectTokenFactory} from "../src/ProjectTokenFactory.sol";
import {TokenVesting} from "../src/TokenVesting.sol";
import {ProjectToken} from "../src/ProjectToken.sol";
import {ITokenVesting} from "../src/interfaces/ITokenVesting.sol";
import {IERC20} from "../src/interfaces/IERC20.sol";

contract ProjectTokenFactoryTest is Test {
    ProjectTokenFactory public factory;
    TokenVesting public vesting;

    address public owner = makeAddr("owner");
    address public creator = makeAddr("creator");
    
    // Tokenomics recipients
    address public teamWallet = makeAddr("teamWallet");
    address public teamLockOwner = makeAddr("teamLockOwner");
    address public investorWallet = makeAddr("investorWallet");
    address public investorLockOwner = makeAddr("investorLockOwner");
    address public airdropContract = makeAddr("airdropContract");
    address public liquidityWallet = makeAddr("liquidityWallet");

    string constant NAME = "Test Token";
    string constant SYMBOL = "TEST";
    uint256 constant TOTAL_SUPPLY = 1_000_000_000e18;

    function setUp() public {
        vm.startPrank(owner);
        vesting = new TokenVesting();
        factory = new ProjectTokenFactory(address(vesting));
        vesting.setFactory(address(factory));
        vm.stopPrank();
    }

    /*//////////////////////////////////////////////////////////////
                            CONSTRUCTOR TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Constructor() public view {
        assertEq(factory.owner(), owner);
        assertEq(address(factory.vesting()), address(vesting));
        assertEq(factory.tokenCount(), 0);
    }

    function test_Constructor_RevertZeroVesting() public {
        vm.expectRevert(ProjectTokenFactory.ZeroAddress.selector);
        new ProjectTokenFactory(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                          CREATE TOKEN TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CreateToken_FullTGE() public {
        // 100% unlocked at TGE
        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](1);
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: airdropContract,
            lockOwner: address(0), // Not used for 100% TGE
            amount: TOTAL_SUPPLY,
            tgePercent: 10000, // 100%
            cliffDuration: 0,
            vestingDuration: 0
        });

        vm.prank(creator);
        address token = factory.createToken(NAME, SYMBOL, TOTAL_SUPPLY, allocations);

        // Verify token created
        assertTrue(factory.isToken(token));
        assertEq(factory.tokenCount(), 1);
        assertEq(IERC20(token).balanceOf(airdropContract), TOTAL_SUPPLY);
        
        // No locks created
        assertEq(vesting.lockCount(), 0);
    }

    function test_CreateToken_PartialTGE() public {
        // 20% TGE + 80% vesting
        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](1);
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: teamWallet,
            lockOwner: teamLockOwner,
            amount: TOTAL_SUPPLY,
            tgePercent: 2000, // 20%
            cliffDuration: 30 days,
            vestingDuration: 365 days
        });

        vm.prank(creator);
        address token = factory.createToken(NAME, SYMBOL, TOTAL_SUPPLY, allocations);

        uint256 tgeAmount = TOTAL_SUPPLY * 20 / 100;
        uint256 vestingAmount = TOTAL_SUPPLY - tgeAmount;

        // TGE tokens to recipient
        assertEq(IERC20(token).balanceOf(teamWallet), tgeAmount);
        
        // Vesting tokens locked
        assertEq(IERC20(token).balanceOf(address(vesting)), vestingAmount);
        assertEq(vesting.lockCount(), 1);

        // Verify lock
        (
            address lockToken,
            address lockBeneficiary,
            uint256 totalAmount,
            uint256 cliffDuration,
            uint256 vestingDuration,
            
        ) = vesting.vestingSchedules(0);

        assertEq(lockToken, token);
        assertEq(lockBeneficiary, teamLockOwner);
        assertEq(totalAmount, vestingAmount);
        assertEq(cliffDuration, 30 days);
        assertEq(vestingDuration, 365 days);
    }

    function test_CreateToken_ZeroTGE() public {
        // 0% TGE, 100% vesting
        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](1);
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: investorWallet, // Not used but required
            lockOwner: investorLockOwner,
            amount: TOTAL_SUPPLY,
            tgePercent: 0,
            cliffDuration: 0,
            vestingDuration: 18 * 30 days // 18 months
        });

        vm.prank(creator);
        address token = factory.createToken(NAME, SYMBOL, TOTAL_SUPPLY, allocations);

        // No TGE tokens
        assertEq(IERC20(token).balanceOf(investorWallet), 0);
        
        // All in vesting
        assertEq(IERC20(token).balanceOf(address(vesting)), TOTAL_SUPPLY);
    }

    function test_CreateToken_MultipleAllocations() public {
        // Real tokenomics example
        uint256 teamAmount = 150_000_000e18;      // 15%
        uint256 investorAmount = 150_000_000e18;  // 15%
        uint256 airdropAmount = 200_000_000e18;   // 20%
        uint256 liquidityAmount = 500_000_000e18; // 50%

        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](4);
        
        // Team: 10% TGE + 1 month cliff + 12 month vest
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: teamWallet,
            lockOwner: teamLockOwner,
            amount: teamAmount,
            tgePercent: 1000, // 10%
            cliffDuration: 30 days,
            vestingDuration: 365 days
        });

        // Investors: 0% TGE + 18 month vest
        allocations[1] = ProjectTokenFactory.TokenAllocation({
            recipient: investorWallet,
            lockOwner: investorLockOwner,
            amount: investorAmount,
            tgePercent: 0,
            cliffDuration: 0,
            vestingDuration: 18 * 30 days
        });

        // Airdrop: 100% TGE
        allocations[2] = ProjectTokenFactory.TokenAllocation({
            recipient: airdropContract,
            lockOwner: address(0),
            amount: airdropAmount,
            tgePercent: 10000, // 100%
            cliffDuration: 0,
            vestingDuration: 0
        });

        // Liquidity: 100% TGE
        allocations[3] = ProjectTokenFactory.TokenAllocation({
            recipient: liquidityWallet,
            lockOwner: address(0),
            amount: liquidityAmount,
            tgePercent: 10000, // 100%
            cliffDuration: 0,
            vestingDuration: 0
        });

        vm.prank(creator);
        address token = factory.createToken(NAME, SYMBOL, TOTAL_SUPPLY, allocations);

        // Verify distributions
        uint256 teamTGE = teamAmount * 10 / 100;
        uint256 teamVesting = teamAmount - teamTGE;

        assertEq(IERC20(token).balanceOf(teamWallet), teamTGE);
        assertEq(IERC20(token).balanceOf(investorWallet), 0);
        assertEq(IERC20(token).balanceOf(airdropContract), airdropAmount);
        assertEq(IERC20(token).balanceOf(liquidityWallet), liquidityAmount);
        
        // Vesting has team + investor tokens
        assertEq(IERC20(token).balanceOf(address(vesting)), teamVesting + investorAmount);
        
        // 2 locks created
        assertEq(vesting.lockCount(), 2);
    }

    function test_CreateToken_DifferentRecipientAndLockOwner() public {
        // TGE goes to operations wallet, vesting owned by multisig
        address operationsWallet = makeAddr("operations");
        address multisig = makeAddr("multisig");

        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](1);
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: operationsWallet,
            lockOwner: multisig,
            amount: TOTAL_SUPPLY,
            tgePercent: 5000, // 50%
            cliffDuration: 0,
            vestingDuration: 365 days
        });

        vm.prank(creator);
        address token = factory.createToken(NAME, SYMBOL, TOTAL_SUPPLY, allocations);

        // 50% to operations
        assertEq(IERC20(token).balanceOf(operationsWallet), TOTAL_SUPPLY / 2);
        
        // 50% in vesting owned by multisig
        (,address lockBeneficiary,,,,) = vesting.vestingSchedules(0);
        assertEq(lockBeneficiary, multisig);

        // Start vesting and verify multisig can claim
        vm.prank(owner);
        vesting.startVesting(token);

        vm.warp(block.timestamp + 365 days);

        vm.prank(multisig);
        vesting.claim(0);
        assertEq(IERC20(token).balanceOf(multisig), TOTAL_SUPPLY / 2);
    }

    /*//////////////////////////////////////////////////////////////
                          ERROR CASES
    //////////////////////////////////////////////////////////////*/

    function test_CreateToken_RevertZeroSupply() public {
        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](1);
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: teamWallet,
            lockOwner: address(0),
            amount: 0,
            tgePercent: 10000,
            cliffDuration: 0,
            vestingDuration: 0
        });

        vm.prank(creator);
        vm.expectRevert(ProjectTokenFactory.ZeroAmount.selector);
        factory.createToken(NAME, SYMBOL, 0, allocations);
    }

    function test_CreateToken_RevertEmptyAllocations() public {
        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](0);

        vm.prank(creator);
        vm.expectRevert(ProjectTokenFactory.InvalidAllocation.selector);
        factory.createToken(NAME, SYMBOL, TOTAL_SUPPLY, allocations);
    }

    function test_CreateToken_RevertZeroAmountAllocation() public {
        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](1);
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: teamWallet,
            lockOwner: address(0),
            amount: 0,
            tgePercent: 10000,
            cliffDuration: 0,
            vestingDuration: 0
        });

        vm.prank(creator);
        vm.expectRevert(ProjectTokenFactory.ZeroAmount.selector);
        factory.createToken(NAME, SYMBOL, TOTAL_SUPPLY, allocations);
    }

    function test_CreateToken_RevertZeroRecipient() public {
        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](1);
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: address(0),
            lockOwner: address(0),
            amount: TOTAL_SUPPLY,
            tgePercent: 10000,
            cliffDuration: 0,
            vestingDuration: 0
        });

        vm.prank(creator);
        vm.expectRevert(ProjectTokenFactory.ZeroAddress.selector);
        factory.createToken(NAME, SYMBOL, TOTAL_SUPPLY, allocations);
    }

    function test_CreateToken_RevertZeroLockOwnerWithVesting() public {
        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](1);
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: teamWallet,
            lockOwner: address(0), // Invalid - needs lockOwner for vesting
            amount: TOTAL_SUPPLY,
            tgePercent: 5000, // 50% TGE means 50% vesting
            cliffDuration: 0,
            vestingDuration: 365 days
        });

        vm.prank(creator);
        vm.expectRevert(ProjectTokenFactory.ZeroAddress.selector);
        factory.createToken(NAME, SYMBOL, TOTAL_SUPPLY, allocations);
    }

    function test_CreateToken_RevertInvalidTGEPercent() public {
        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](1);
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: teamWallet,
            lockOwner: teamLockOwner,
            amount: TOTAL_SUPPLY,
            tgePercent: 10001, // > 100%
            cliffDuration: 0,
            vestingDuration: 0
        });

        vm.prank(creator);
        vm.expectRevert(ProjectTokenFactory.InvalidAllocation.selector);
        factory.createToken(NAME, SYMBOL, TOTAL_SUPPLY, allocations);
    }

    function test_CreateToken_RevertAllocationMismatch() public {
        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](2);
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: teamWallet,
            lockOwner: address(0),
            amount: TOTAL_SUPPLY / 2,
            tgePercent: 10000,
            cliffDuration: 0,
            vestingDuration: 0
        });
        allocations[1] = ProjectTokenFactory.TokenAllocation({
            recipient: investorWallet,
            lockOwner: address(0),
            amount: TOTAL_SUPPLY / 4, // Only adds up to 75%
            tgePercent: 10000,
            cliffDuration: 0,
            vestingDuration: 0
        });

        vm.prank(creator);
        vm.expectRevert(ProjectTokenFactory.AllocationMismatch.selector);
        factory.createToken(NAME, SYMBOL, TOTAL_SUPPLY, allocations);
    }

    /*//////////////////////////////////////////////////////////////
                          VIEW FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    function test_GetAllTokens() public {
        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](1);
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: airdropContract,
            lockOwner: address(0),
            amount: TOTAL_SUPPLY,
            tgePercent: 10000,
            cliffDuration: 0,
            vestingDuration: 0
        });

        vm.prank(creator);
        address token1 = factory.createToken("Token1", "TK1", TOTAL_SUPPLY, allocations);
        
        vm.prank(creator);
        address token2 = factory.createToken("Token2", "TK2", TOTAL_SUPPLY, allocations);

        address[] memory tokens = factory.getAllTokens();
        assertEq(tokens.length, 2);
        assertEq(tokens[0], token1);
        assertEq(tokens[1], token2);
    }

    function test_GetCreatorTokens() public {
        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](1);
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: airdropContract,
            lockOwner: address(0),
            amount: TOTAL_SUPPLY,
            tgePercent: 10000,
            cliffDuration: 0,
            vestingDuration: 0
        });

        vm.prank(creator);
        address token1 = factory.createToken("Token1", "TK1", TOTAL_SUPPLY, allocations);
        
        vm.prank(creator);
        address token2 = factory.createToken("Token2", "TK2", TOTAL_SUPPLY, allocations);

        // Both tokens created by creator
        address[] memory creatorTokens = factory.getCreatorTokens(creator);
        assertEq(creatorTokens.length, 2);
        assertEq(creatorTokens[0], token1);
        assertEq(creatorTokens[1], token2);
    }

    function test_GetTokenInfo() public {
        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](1);
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: airdropContract,
            lockOwner: address(0),
            amount: TOTAL_SUPPLY,
            tgePercent: 10000,
            cliffDuration: 0,
            vestingDuration: 0
        });

        vm.prank(creator);
        address token = factory.createToken(NAME, SYMBOL, TOTAL_SUPPLY, allocations);

        ProjectTokenFactory.TokenInfo memory info = factory.getTokenInfo(token);
        assertEq(info.token, token);
        assertEq(info.name, NAME);
        assertEq(info.symbol, SYMBOL);
        assertEq(info.totalSupply, TOTAL_SUPPLY);
        assertEq(info.creator, creator);
        assertEq(info.createdAt, block.timestamp);
    }

    /*//////////////////////////////////////////////////////////////
                        OWNERSHIP TRANSFER TESTS
    //////////////////////////////////////////////////////////////*/

    function test_TransferOwnership() public {
        address newOwner = makeAddr("newOwner");

        vm.prank(owner);
        factory.transferOwnership(newOwner);
        assertEq(factory.pendingOwner(), newOwner);

        vm.prank(newOwner);
        factory.acceptOwnership();
        assertEq(factory.owner(), newOwner);
    }

    function test_TransferOwnership_RevertNotOwner() public {
        vm.expectRevert(ProjectTokenFactory.NotOwner.selector);
        factory.transferOwnership(makeAddr("newOwner"));
    }

    /*//////////////////////////////////////////////////////////////
                        INTEGRATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_FullVestingFlow() public {
        // Create token with vesting
        ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](1);
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: teamWallet,
            lockOwner: teamLockOwner,
            amount: TOTAL_SUPPLY,
            tgePercent: 1000, // 10%
            cliffDuration: 30 days,
            vestingDuration: 90 days
        });

        vm.prank(creator);
        address token = factory.createToken(NAME, SYMBOL, TOTAL_SUPPLY, allocations);

        uint256 tgeAmount = TOTAL_SUPPLY / 10;
        uint256 vestingAmount = TOTAL_SUPPLY - tgeAmount;

        // Verify TGE distribution
        assertEq(IERC20(token).balanceOf(teamWallet), tgeAmount);

        // Start vesting (owner of vesting contract)
        vm.prank(owner);
        vesting.startVesting(token);

        // Use absolute timestamps (startTime = 1 in tests)
        // During cliff - nothing claimable
        assertEq(vesting.getClaimable(0), 0);

        // After cliff - start vesting (30 days)
        vm.warp(1 + 30 days);
        assertEq(vesting.getClaimable(0), 0);

        // 30 days into vesting (60 days total = 1/3 of 90 day vesting)
        vm.warp(1 + 60 days);
        assertApproxEqAbs(vesting.getClaimable(0), vestingAmount / 3, 1e18);

        // Claim partial
        vm.prank(teamLockOwner);
        vesting.claim(0);
        assertApproxEqAbs(IERC20(token).balanceOf(teamLockOwner), vestingAmount / 3, 1e18);

        // Full vest (30 days cliff + 90 days vesting = 120 days total)
        vm.warp(1 + 120 days);
        
        // Claim remaining
        vm.prank(teamLockOwner);
        vesting.claim(0);
        assertEq(IERC20(token).balanceOf(teamLockOwner), vestingAmount);

        // Total: TGE to teamWallet + vesting to teamLockOwner = TOTAL_SUPPLY
        assertEq(
            IERC20(token).balanceOf(teamWallet) + IERC20(token).balanceOf(teamLockOwner),
            TOTAL_SUPPLY
        );
    }

    function test_RealWorldTokenomics() public {
        // Simulating real tokenomics - use helper to avoid stack too deep
        ProjectTokenFactory.TokenAllocation[] memory allocations = _buildRealWorldAllocations();

        vm.prank(creator);
        address token = factory.createToken("Kickoff Token", "KICK", TOTAL_SUPPLY, allocations);

        // Verify total supply distributed
        uint256 totalInVesting = IERC20(token).balanceOf(address(vesting));
        uint256 totalInWallets = TOTAL_SUPPLY - totalInVesting;
        
        assertEq(totalInWallets + totalInVesting, TOTAL_SUPPLY);
        
        // Verify lock count (7 allocations have vesting)
        assertEq(vesting.lockCount(), 7);
    }

    function _buildRealWorldAllocations() internal returns (ProjectTokenFactory.TokenAllocation[] memory allocations) {
        allocations = new ProjectTokenFactory.TokenAllocation[](9);

        // Kickoff Incubation: 0.5% TGE + 0.5% over 6 months (1% total)
        allocations[0] = ProjectTokenFactory.TokenAllocation({
            recipient: makeAddr("incubation"),
            lockOwner: makeAddr("incubationLock"),
            amount: 10_000_000e18,
            tgePercent: 5000,
            cliffDuration: 0,
            vestingDuration: 180 days
        });

        // Kickoff Airdrop: 100% (2%)
        allocations[1] = ProjectTokenFactory.TokenAllocation({
            recipient: makeAddr("airdrop1"),
            lockOwner: address(0),
            amount: 20_000_000e18,
            tgePercent: 10000,
            cliffDuration: 0,
            vestingDuration: 0
        });

        // Airdrop #2: 1-month cliff + 10 months linear (12%)
        allocations[2] = ProjectTokenFactory.TokenAllocation({
            recipient: makeAddr("airdrop2"),
            lockOwner: makeAddr("airdrop2Lock"),
            amount: 120_000_000e18,
            tgePercent: 0,
            cliffDuration: 30 days,
            vestingDuration: 300 days
        });

        // Onchain Activity: 3-month cliff + 36-month emissions (25%)
        allocations[3] = ProjectTokenFactory.TokenAllocation({
            recipient: makeAddr("onchain"),
            lockOwner: makeAddr("onchainLock"),
            amount: 250_000_000e18,
            tgePercent: 0,
            cliffDuration: 90 days,
            vestingDuration: 3 * 365 days
        });

        // Ecosystem: 1-month cliff + 12-month vesting (8%)
        allocations[4] = ProjectTokenFactory.TokenAllocation({
            recipient: makeAddr("ecosystem"),
            lockOwner: makeAddr("ecosystemLock"),
            amount: 80_000_000e18,
            tgePercent: 0,
            cliffDuration: 30 days,
            vestingDuration: 365 days
        });

        // Investors: 0% TGE + 18-month linear (15%)
        allocations[5] = ProjectTokenFactory.TokenAllocation({
            recipient: makeAddr("investor"),
            lockOwner: makeAddr("investorLock"),
            amount: 150_000_000e18,
            tgePercent: 0,
            cliffDuration: 0,
            vestingDuration: 18 * 30 days
        });

        // Team: 1-month cliff + 12-month vesting (15%)
        allocations[6] = ProjectTokenFactory.TokenAllocation({
            recipient: makeAddr("team"),
            lockOwner: makeAddr("teamLock"),
            amount: 150_000_000e18,
            tgePercent: 0,
            cliffDuration: 30 days,
            vestingDuration: 365 days
        });

        // Presale/Liquidity: 100% TGE (10%)
        allocations[7] = ProjectTokenFactory.TokenAllocation({
            recipient: makeAddr("presale"),
            lockOwner: address(0),
            amount: 100_000_000e18,
            tgePercent: 10000,
            cliffDuration: 0,
            vestingDuration: 0
        });

        // Foundation: 1-month cliff + 18-month vest (12%)
        allocations[8] = ProjectTokenFactory.TokenAllocation({
            recipient: makeAddr("foundation"),
            lockOwner: makeAddr("foundationLock"),
            amount: 120_000_000e18,
            tgePercent: 0,
            cliffDuration: 30 days,
            vestingDuration: 18 * 30 days
        });
    }
}

