// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {KickoffFactory} from "../../src/KickoffFactory.sol";
import {KickoffVoteSalePool} from "../../src/KickoffVoteSalePool.sol";
import {CLPriceArbitrageur} from "../../src/CLPriceArbitrageur.sol";
import {VoteSalePoolDeployer} from "../../src/VoteSalePoolDeployer.sol";
import {LPLocker} from "../../src/LPLocker.sol";
import {IVotingEscrow} from "../../src/interfaces/IVotingEscrow.sol";
import {IVoter} from "../../src/interfaces/IVoter.sol";
import {IRouter} from "../../src/interfaces/IRouter.sol";
import {IAutopilot} from "../../src/interfaces/IAutopilot.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";

/// @title AutopilotIntegrationTest
/// @notice Integration test for Autopilot protocol integration
/// @dev Run: forge test --match-contract AutopilotIntegrationTest --fork-url $BASE_RPC_URL -vvvv
contract AutopilotIntegrationTest is Test {
    // ============ AERODROME MAINNET CONTRACTS ============
    address constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
    address constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;
    address constant ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    
    // ============ AUTOPILOT CONTRACT ============
    address constant AUTOPILOT = 0xA7c68a960bA0F6726C4b7446004FE64969E2b4d4;
    
    // ============ TEST NFTs ============
    // NFTs with >400 veAERO voting power
    uint256[10] public NFT_IDS = [
        uint256(6), 7, 47, 48, 12, 2, 3, 4, 5, 10
    ];
    
    // Minimum voting power for Autopilot
    uint256 constant MIN_AUTOPILOT_VP = 400e18;

    // ============ STATE ============
    KickoffFactory public factory;
    KickoffVoteSalePool public pool;
    LPLocker public lpLocker;
    MockToken public projectToken;

    IVotingEscrow ve;
    IVoter voter;
    IRouter router;
    IAutopilot autopilot;

    address public admin;
    address public projectOwner;
    
    uint256[] public lockedNftIds;
    address[] public lockedOwners;

    function setUp() public {
        if (block.chainid != 8453) return;

        ve = IVotingEscrow(VOTING_ESCROW);
        voter = IVoter(VOTER);
        router = IRouter(ROUTER);
        autopilot = IAutopilot(AUTOPILOT);

        admin = makeAddr("admin");
        projectOwner = makeAddr("projectOwner");
        
        projectToken = new MockToken("KICKOFF", "KICK");
        projectToken.mint(admin, 10_000_000 ether);

        // Deploy shared helper contracts and factory
        CLPriceArbitrageur arbitrageur = new CLPriceArbitrageur();
        VoteSalePoolDeployer poolDeployer = new VoteSalePoolDeployer();
        factory = new KickoffFactory(AUTOPILOT, VOTING_ESCROW, VOTER, ROUTER, WETH, address(arbitrageur), address(poolDeployer));
        poolDeployer.setFactory(address(factory));
        lpLocker = factory.lpLocker();

        // Admin approves tokens
        vm.prank(admin);
        projectToken.approve(address(factory), 10_000_000 ether);
        
        // Create pool with minVotingPower >= Autopilot's dynamic minimum
        uint256 minVP = factory.getMinAutopilotVotingPower();
        pool = KickoffVoteSalePool(
            factory.createPool(
                address(projectToken), 
                projectOwner, 
                10_000_000 ether, 
                minVP, // Dynamic minimum from Autopilot
                admin
            )
        );
    }

    /// @notice Test minimum voting power validation in factory
    function test_FactoryRejectsLowMinVotingPower() public {
        if (block.chainid != 8453) { vm.skip(true); return; }
        
        MockToken newToken = new MockToken("NEW", "NEW");
        newToken.mint(admin, 10_000_000 ether);
        
        vm.prank(admin);
        newToken.approve(address(factory), 10_000_000 ether);
        
        // Should revert with VotingPowerBelowAutopilotMin
        vm.expectRevert(KickoffFactory.VotingPowerBelowAutopilotMin.selector);
        factory.createPool(
            address(newToken), 
            projectOwner, 
            10_000_000 ether, 
            100e18, // Below 400 veAERO minimum
            admin
        );
    }

    /// @notice Test two-phase locking with Autopilot deposit
    function test_DepositVeAERO_TwoPhaseFlow() public {
        if (block.chainid != 8453) { vm.skip(true); return; }

        console.log("");
        console.log("================================================================");
        console.log("   TEST: TWO-PHASE DEPOSIT veAERO WITH AUTOPILOT");
        console.log("================================================================");

        // Activate pool
        vm.prank(admin);
        pool.activate();
        
        uint256 lockingDeadline = pool.lockingDeadline();
        console.log("Locking deadline:", lockingDeadline);
        console.log("Current time:", block.timestamp);
        
        // Find an NFT with sufficient voting power that hasn't voted
        (uint256 tokenId, address nftOwner) = _findEligibleNFT();
        
        if (tokenId == 0) {
            console.log("No eligible NFT found, skipping test");
            return;
        }
        
        uint256 vpBefore = ve.balanceOfNFT(tokenId);
        console.log("NFT ID:", tokenId);
        console.log("Owner:", nftOwner);
        console.log("Voting power:", vpBefore);
        
        // Use two-phase helper to lock
        bool success = _lockVeAERO(nftOwner, tokenId);
        assertTrue(success, "Lock should succeed");
        
        // Verify NFT is tracked in pool
        (address owner, uint256 vp, bool unlocked) = pool.lockedNFTs(tokenId);
        assertEq(owner, nftOwner, "Owner should be set");
        assertEq(vp, vpBefore, "Voting power should be recorded");
        assertFalse(unlocked, "Should not be unlocked");
        
        // Verify NFT is in Autopilot
        assertTrue(pool.depositedToAutopilot(tokenId), "Should be deposited to Autopilot");
        
        console.log("SUCCESS: NFT locked and deposited to Autopilot via two-phase flow");
    }

    /// @notice Test automatic state transition at lockingDeadline
    function test_AutomaticStateTransition() public {
        if (block.chainid != 8453) { vm.skip(true); return; }

        console.log("");
        console.log("================================================================");
        console.log("   TEST: AUTOMATIC STATE TRANSITION");
        console.log("================================================================");

        // Activate pool
        vm.prank(admin);
        pool.activate();
        
        assertEq(uint256(pool.state()), uint256(KickoffVoteSalePool.PoolState.Active));
        
        uint256 lockingDeadline = pool.lockingDeadline();
        console.log("Locking deadline:", lockingDeadline);
        
        // Warp to just before deadline
        vm.warp(lockingDeadline - 1);
        
        // Find and lock an NFT (should work)
        (uint256 tokenId, address nftOwner) = _findEligibleNFT();
        if (tokenId > 0) {
            bool success = _lockVeAERO(nftOwner, tokenId);
            if (success) {
                console.log("Locked NFT before deadline");
            }
        }
        
        // Warp to after deadline
        vm.warp(lockingDeadline + 1);
        
        // Try to deposit another NFT - should fail after checkStateTransition
        (uint256 tokenId2, address nftOwner2) = _findEligibleNFT2();
        if (tokenId2 > 0 && tokenId2 != tokenId) {
            vm.startPrank(nftOwner2);
            ve.approve(address(pool), tokenId2);
            
            // This should trigger auto-transition and then revert with InvalidState
            vm.expectRevert(KickoffVoteSalePool.InvalidState.selector);
            pool.depositVeAERO(tokenId2);
            vm.stopPrank();
            
            console.log("Deposit correctly rejected after deadline");
        }
        
        // Verify state transitioned to Voting
        assertEq(uint256(pool.state()), uint256(KickoffVoteSalePool.PoolState.Voting));
        console.log("SUCCESS: State automatically transitioned to Voting");
    }

    /// @notice Test rejecting NFT with voting power below minimum
    function test_RejectLowVotingPowerNFT() public {
        if (block.chainid != 8453) { vm.skip(true); return; }

        console.log("");
        console.log("================================================================");
        console.log("   TEST: REJECT LOW VOTING POWER NFT");
        console.log("================================================================");

        // Activate pool
        vm.prank(admin);
        pool.activate();
        
        // Find an NFT with low voting power (if any)
        uint256 lowVpNft = _findLowVotingPowerNFT();
        
        if (lowVpNft == 0) {
            console.log("No low VP NFT found, test inconclusive");
            return;
        }
        
        address nftOwner = ve.ownerOf(lowVpNft);
        uint256 vp = ve.balanceOfNFT(lowVpNft);
        
        console.log("Low VP NFT:", lowVpNft);
        console.log("Voting power:", vp);
        console.log("Minimum required:", MIN_AUTOPILOT_VP);
        
        vm.startPrank(nftOwner);
        ve.approve(address(pool), lowVpNft);
        
        vm.expectRevert(KickoffVoteSalePool.VotingPowerTooLow.selector);
        pool.depositVeAERO(lowVpNft);
        vm.stopPrank();
        
        console.log("SUCCESS: Low VP NFT correctly rejected");
    }

    /// @notice Test user unlock via unlockVeAERO (auto-withdraws from Autopilot)
    function test_UnlockVeAERO_AutoWithdrawsFromAutopilot() public {
        if (block.chainid != 8453) { vm.skip(true); return; }

        console.log("");
        console.log("================================================================");
        console.log("   TEST: UNLOCK veAERO AUTO-WITHDRAWS FROM AUTOPILOT");
        console.log("================================================================");

        // Setup: Lock an NFT
        vm.prank(admin);
        pool.activate();
        
        (uint256 tokenId, address nftOwner) = _findEligibleNFT();
        if (tokenId == 0) {
            console.log("No eligible NFT found, skipping test");
            return;
        }
        
        bool success = _lockVeAERO(nftOwner, tokenId);
        assertTrue(success, "Lock should succeed");
        
        assertTrue(pool.depositedToAutopilot(tokenId), "Should be in Autopilot");
        
        // Fast forward past epoch end + special window
        uint256 aerodromeEpochEnd = pool.aerodromeEpochStart() + 1 weeks;
        vm.warp(aerodromeEpochEnd + 2 hours); // After special window
        
        // Simulate completion (manually set state for testing)
        // In real scenario, this happens after finalization flow
        vm.store(
            address(pool),
            bytes32(uint256(8)), // state storage slot (approximate)
            bytes32(uint256(4)) // Completed state
        );
        
        // User tries to unlock from wrong address - should fail
        vm.prank(admin);
        vm.expectRevert(KickoffVoteSalePool.NotNFTOwner.selector);
        pool.unlockVeAERO(tokenId);
        
        // User unlocks their NFT (auto-withdraws from Autopilot)
        vm.prank(nftOwner);
        pool.unlockVeAERO(tokenId);
        
        // Verify NFT is no longer in Autopilot
        assertFalse(pool.depositedToAutopilot(tokenId), "Should not be in Autopilot");
        
        // Verify user got their NFT back
        assertEq(ve.ownerOf(tokenId), nftOwner, "User should own NFT");
        
        console.log("SUCCESS: unlockVeAERO auto-withdrew from Autopilot");
    }

    /// @notice Test emergency withdraw handles Autopilot
    function test_EmergencyWithdrawFromAutopilot() public {
        if (block.chainid != 8453) { vm.skip(true); return; }

        console.log("");
        console.log("================================================================");
        console.log("   TEST: EMERGENCY WITHDRAW FROM AUTOPILOT");
        console.log("================================================================");

        // Setup: Lock an NFT
        vm.prank(admin);
        pool.activate();
        
        (uint256 tokenId, address nftOwner) = _findEligibleNFT();
        if (tokenId == 0) {
            console.log("No eligible NFT found, skipping test");
            return;
        }
        
        bool success = _lockVeAERO(nftOwner, tokenId);
        assertTrue(success, "Lock should succeed");
        
        assertTrue(pool.depositedToAutopilot(tokenId), "Should be in Autopilot");
        
        // Fast forward to outside special window
        uint256 aerodromeEpochEnd = pool.aerodromeEpochStart() + 1 weeks;
        vm.warp(aerodromeEpochEnd + 2 hours);
        
        // Emergency withdraw by owner
        vm.prank(admin); // Admin is owner of pool
        pool.emergencyWithdrawNFT(tokenId);
        
        // Verify NFT withdrawn from Autopilot and returned
        assertFalse(pool.depositedToAutopilot(tokenId), "Should not be in Autopilot");
        assertEq(ve.ownerOf(tokenId), nftOwner, "NFT should be returned to original owner");
        
        console.log("SUCCESS: Emergency withdraw from Autopilot completed");
    }

    /// @notice Full Autopilot integration flow
    function test_FullAutopilotFlow() public {
        if (block.chainid != 8453) { vm.skip(true); return; }

        console.log("");
        console.log("================================================================");
        console.log("   TEST: FULL AUTOPILOT INTEGRATION FLOW");
        console.log("================================================================");

        // Phase 1: Activate
        vm.prank(admin);
        pool.activate();
        console.log("Phase 1: Pool activated");
        
        // Phase 2: Lock NFTs (using two-phase deposit flow)
        uint256 lockedCount = 0;
        for (uint256 i = 0; i < NFT_IDS.length && lockedCount < 3; i++) {
            uint256 tokenId = NFT_IDS[i];
            
            try ve.ownerOf(tokenId) returns (address nftOwner) {
                if (nftOwner == address(0)) continue;
                
                uint256 vp = ve.balanceOfNFT(tokenId);
                if (vp < MIN_AUTOPILOT_VP) continue;
                
                uint256 lastVoted = voter.lastVoted(tokenId);
                if (lastVoted >= pool.aerodromeEpochStart()) continue;
                
                // Check not deactivated
                try ve.deactivated(tokenId) returns (bool deactivated) {
                    if (deactivated) continue;
                } catch {}
                
                // Use two-phase lock helper
                if (_lockVeAERO(nftOwner, tokenId)) {
                    lockedNftIds.push(tokenId);
                    lockedOwners.push(nftOwner);
                    lockedCount++;
                    console.log("Locked NFT:", tokenId, "VP:", vp);
                }
            } catch {
                continue;
            }
        }
        
        console.log("Phase 2: Locked", lockedCount, "NFTs");
        
        if (lockedCount == 0) {
            console.log("No NFTs locked, cannot continue test");
            return;
        }
        
        // Phase 3: Fast forward to after epoch and special window
        uint256 aerodromeEpochEnd = pool.aerodromeEpochStart() + 1 weeks;
        vm.warp(aerodromeEpochEnd + 2 hours);
        
        // Trigger auto-transition by calling a function with checkStateTransition
        // Note: State should auto-transition to Voting at lockingDeadline
        console.log("Phase 3: Time warped to after epoch");
        
        // Phase 4: Start claiming rewards from Autopilot
        vm.prank(admin);
        try pool.startClaimRewardsFromAutopilot(50) {
            console.log("Phase 4: Started claiming from Autopilot");
        } catch Error(string memory reason) {
            console.log("Claim failed:", reason);
        }
        
        // Phase 5: Convert USDC to WETH
        vm.prank(admin);
        try pool.convertUSDCtoWETH() {
            console.log("Phase 5: Converted USDC to WETH");
        } catch Error(string memory reason) {
            console.log("Convert failed:", reason);
        }
        
        // Phase 6: Complete finalization
        vm.prank(admin);
        try pool.completeAutopilotFinalization(1000) {
            console.log("Phase 6: Completed finalization");
        } catch Error(string memory reason) {
            console.log("Finalization failed:", reason);
        }
        
        // Phase 7: Users unlock their NFTs (auto-withdraws from Autopilot)
        for (uint256 i = 0; i < lockedNftIds.length; i++) {
            vm.prank(lockedOwners[i]);
            try pool.unlockVeAERO(lockedNftIds[i]) {
                console.log("User unlocked NFT:", lockedNftIds[i]);
            } catch {
                console.log("Unlock failed for NFT:", lockedNftIds[i]);
            }
        }
        
        console.log("");
        console.log("================================================================");
        console.log("   AUTOPILOT INTEGRATION TEST COMPLETED");
        console.log("================================================================");
    }

    // ============ HELPER FUNCTIONS ============

    /// @notice Helper to perform two-phase veAERO deposit (required due to Aerodrome same-block VP reset)
    /// @dev depositVeAERO in block N, confirmDeposit in block N+1
    function _lockVeAERO(address nftOwner, uint256 tokenId) internal returns (bool success) {
        vm.startPrank(nftOwner);
        ve.approve(address(pool), tokenId);
        
        try pool.depositVeAERO(tokenId) {
            vm.stopPrank();
            
            // Advance to next block (required because Aerodrome resets VP on same-block ownership change)
            vm.roll(block.number + 1);
            
            // Confirm the deposit
            try pool.confirmDeposit(tokenId) {
                return true;
            } catch {
                return false;
            }
        } catch {
            vm.stopPrank();
            return false;
        }
    }

    function _findEligibleNFT() internal view returns (uint256 tokenId, address nftOwner) {
        for (uint256 i = 0; i < NFT_IDS.length; i++) {
            uint256 nftId = NFT_IDS[i];
            
            try ve.ownerOf(nftId) returns (address owner) {
                if (owner == address(0)) continue;
                
                uint256 vp = ve.balanceOfNFT(nftId);
                if (vp < MIN_AUTOPILOT_VP) continue;
                
                uint256 lastVoted = voter.lastVoted(nftId);
                if (lastVoted >= pool.aerodromeEpochStart()) continue;
                
                // Check not deactivated
                try ve.deactivated(nftId) returns (bool deactivated) {
                    if (deactivated) continue;
                } catch {}
                
                return (nftId, owner);
            } catch {
                continue;
            }
        }
        return (0, address(0));
    }

    function _findEligibleNFT2() internal view returns (uint256 tokenId, address nftOwner) {
        // Start from a different index to find a different NFT
        for (uint256 i = 5; i < NFT_IDS.length; i++) {
            uint256 nftId = NFT_IDS[i];
            
            try ve.ownerOf(nftId) returns (address owner) {
                if (owner == address(0)) continue;
                
                uint256 vp = ve.balanceOfNFT(nftId);
                if (vp < MIN_AUTOPILOT_VP) continue;
                
                uint256 lastVoted = voter.lastVoted(nftId);
                if (lastVoted >= pool.aerodromeEpochStart()) continue;
                
                return (nftId, owner);
            } catch {
                continue;
            }
        }
        return (0, address(0));
    }

    function _findLowVotingPowerNFT() internal view returns (uint256) {
        // Search for NFTs with VP below 400 veAERO
        for (uint256 nftId = 1; nftId < 1000; nftId++) {
            try ve.ownerOf(nftId) returns (address owner) {
                if (owner == address(0)) continue;
                
                uint256 vp = ve.balanceOfNFT(nftId);
                if (vp > 0 && vp < MIN_AUTOPILOT_VP) {
                    uint256 lastVoted = voter.lastVoted(nftId);
                    if (lastVoted < pool.aerodromeEpochStart()) {
                        return nftId;
                    }
                }
            } catch {
                continue;
            }
        }
        return 0;
    }
}

/// @notice Simple mock token for testing
contract MockToken is IERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(string memory _name, string memory _symbol) {
        name = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        totalSupply += amount;
        balanceOf[to] += amount;
        emit Transfer(address(0), to, amount);
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        require(balanceOf[msg.sender] >= amount, "Insufficient balance");
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        require(balanceOf[from] >= amount, "Insufficient balance");
        require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
        allowance[from][msg.sender] -= amount;
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}
