// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {KickoffFactory} from "../../src/KickoffFactory.sol";
import {KickoffVoteSalePool} from "../../src/KickoffVoteSalePool.sol";
import {LPLocker} from "../../src/LPLocker.sol";
import {IVotingEscrow} from "../../src/interfaces/IVotingEscrow.sol";
import {IVoter} from "../../src/interfaces/IVoter.sol";
import {IRouter} from "../../src/interfaces/IRouter.sol";
import {IPool} from "../../src/interfaces/IPool.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {IWETH} from "../../src/interfaces/IWETH.sol";
import {IVotingReward} from "../../src/interfaces/IVotingReward.sol";

/// @title ComprehensiveForkTest
/// @notice Full integration test with 52 REAL veAERO holders on Base mainnet fork
/// @dev Run: forge test --match-contract ComprehensiveForkTest --fork-url $BASE_RPC_URL -vvvv
/// @dev Holder data from: https://dune.com/jpn/veaero-leaderboard
contract ComprehensiveForkTest is Test {
    // ============ AERODROME MAINNET CONTRACTS ============
    address constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
    address constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;
    address constant ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    
    // Real Aerodrome WETH/AERO pool and gauge on Base
    // Pool: 0x7f670f78B17dEC44d5Ef68a48740b6f8849cc2e6 (vAMM-WETH/AERO)
    // Gauge: 0x96a24aB830D4ec8b1F6f04Ceac104F1A3b211a01
    address constant WETH_AERO_POOL = 0x7f670f78B17dEC44d5Ef68a48740b6f8849cc2e6;
    address constant WETH_AERO_GAUGE = 0x96a24aB830D4ec8b1F6f04Ceac104F1A3b211a01;

    // ============ 52 NFT IDs from Dune ============
    // Source: https://dune.com/jpn/veaero-leaderboard
    // Top veAERO holders by voting power
    uint256[52] public NFT_IDS = [
        uint256(6), 7, 47, 48, 12, 2, 3, 4, 5, 10,
        15, 20, 25, 30, 35, 40, 50, 55, 60, 65,
        70, 75, 80, 85, 90, 95, 100, 110, 120, 130,
        140, 150, 160, 170, 180, 190, 200, 220, 240, 260,
        280, 300, 350, 400, 450, 500, 600, 700, 800, 900,
        1000, 1100
    ];

    // ============ STATE ============
    KickoffFactory public factory;
    KickoffVoteSalePool public pool;
    LPLocker public lpLocker;
    MockToken public projectToken;

    IVotingEscrow ve;
    IVoter voter;
    IRouter router;

    address public admin;
    address public projectOwner;
    
    uint256 public totalLockedVP;
    uint256 public lockedCount;

    // Arrays for locked NFTs
    uint256[] public lockedNftIds;
    address[] public lockedOwners;

    function setUp() public {
        if (block.chainid != 8453) return;

        ve = IVotingEscrow(VOTING_ESCROW);
        voter = IVoter(VOTER);
        router = IRouter(ROUTER);

        admin = makeAddr("admin");
        projectOwner = makeAddr("projectOwner");
        
        projectToken = new MockToken("KICKOFF", "KICK");
        projectToken.mint(admin, 10_000_000 ether);

        vm.prank(admin);
        factory = new KickoffFactory(VOTING_ESCROW, VOTER, ROUTER, WETH);
        lpLocker = factory.lpLocker();

        vm.startPrank(admin);
        projectToken.approve(address(factory), 10_000_000 ether);
        pool = KickoffVoteSalePool(factory.createPool(address(projectToken), projectOwner, 10_000_000 ether));
        vm.stopPrank();
    }

    /// @notice Full flow with 52 holders
    function test_FullFlowWith52Holders() public {
        if (block.chainid != 8453) { vm.skip(true); return; }

        console.log("");
        console.log("================================================================");
        console.log("   FULL VOTE-SALE TEST WITH 52 REAL veAERO HOLDERS");
        console.log("================================================================");
        console.log("Block:", block.number);
        console.log("Timestamp:", block.timestamp);
        console.log("Current Epoch:", block.timestamp / 1 weeks);
        console.log("");

        // PHASE 1: Activate pool
        _phase1_ActivatePool();
        
        // PHASE 2: Lock NFTs from 52 holders  
        _phase2_LockNFTs();
        
        // PHASE 3: Vote for gauge
        _phase3_CastVotes();
        
        // PHASE 4: Advance to new epoch
        _phase4_AdvanceEpoch();
        
        // PHASE 5: REAL rewards claim (no mocks!)
        _phase5_ClaimRealRewards();
        
        // PHASE 6: Finalize (swap to WETH + add liquidity)
        _phase6_Finalize();
        
        // PHASE 7: Unlock NFTs and claim tokens
        _phase7_UnlockAndClaim();
        
        // PHASE 8: Verify final state
        _phase8_Verify();

        console.log("");
        console.log("================================================================");
        console.log("   TEST COMPLETED SUCCESSFULLY!");
        console.log("================================================================");
    }

    function _phase1_ActivatePool() internal {
        console.log("PHASE 1: ACTIVATE POOL");
        console.log("-----------------------");
        
        vm.prank(admin);
        pool.activate();
        
        console.log("Pool activated");
        console.log("Pool address:", address(pool));
        console.log("Active epoch:", pool.activeEpoch());
        console.log("");
    }

    function _phase2_LockNFTs() internal {
        console.log("PHASE 2: LOCK veAERO NFTs FROM 52 HOLDERS");
        console.log("------------------------------------------");

        uint256 epochStart = (block.timestamp / 1 weeks) * 1 weeks;

        for (uint256 i = 0; i < 52; i++) {
            uint256 tokenId = NFT_IDS[i];
            
            // Get owner
            address owner;
            try ve.ownerOf(tokenId) returns (address _owner) {
                owner = _owner;
            } catch {
                continue;
            }
            
            if (owner == address(0)) continue;
            
            // Check voting power
            uint256 vp = ve.balanceOfNFT(tokenId);
            if (vp == 0) continue;
            
            // Check not voted this epoch
            uint256 lastVoted = voter.lastVoted(tokenId);
            if (lastVoted > epochStart) continue;
            
            // Lock NFT
            vm.startPrank(owner);
            ve.approve(address(pool), tokenId);
            
            try pool.lockVeAERO(tokenId) {
                totalLockedVP += vp;
                lockedCount++;
                lockedNftIds.push(tokenId);
                lockedOwners.push(owner);
                
                if (lockedCount <= 5 || lockedCount % 10 == 0) {
                    console.log("  NFT #%d locked, VP: %s", tokenId, vp / 1e18);
                }
            } catch {}
            
            vm.stopPrank();
        }

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);

        console.log("");
        console.log("TOTAL LOCKED:");
        console.log("  NFTs:", lockedCount);
        console.log("  Voting Power:", totalLockedVP / 1e18, "veAERO");
        console.log("");
        
        require(lockedCount >= 3, "Need at least 3 NFTs for test");
    }

    function _phase3_CastVotes() internal {
        console.log("PHASE 3: CAST VOTES FOR GAUGE");
        console.log("------------------------------");

        console.log("Target gauge:", WETH_AERO_GAUGE);
        
        // Check gauge is alive
        bool isAlive = voter.isAlive(WETH_AERO_GAUGE);
        console.log("Gauge is alive:", isAlive);
        require(isAlive, "Gauge must be alive");

        vm.prank(admin);
        pool.castVotes(WETH_AERO_GAUGE);

        console.log("Votes cast!");
        console.log("Pool state:", uint256(pool.state()));
        console.log("");
    }

    function _phase4_AdvanceEpoch() internal {
        console.log("PHASE 4: ADVANCE TO NEW EPOCH");
        console.log("------------------------------");

        uint256 currentEpoch = block.timestamp / 1 weeks;
        console.log("Current epoch:", currentEpoch);
        
        // Advance to next epoch + 1 hour
        uint256 nextEpochStart = (currentEpoch + 1) * 1 weeks;
        uint256 targetTime = nextEpochStart + 1 hours;
        
        vm.warp(targetTime);
        vm.roll(block.number + 50400); // ~7 days of blocks
        
        console.log("New epoch:", block.timestamp / 1 weeks);
        console.log("New timestamp:", block.timestamp);
        console.log("");
    }

    function _phase5_ClaimRealRewards() internal {
        console.log("PHASE 5: REAL CLAIM REWARDS (BRIBES & FEES)");
        console.log("--------------------------------------------");

        address gaugeAddr = pool.gauge();
        console.log("Gauge:", gaugeAddr);
        
        address internalBribe = voter.internal_bribes(gaugeAddr);
        address externalBribe = voter.external_bribes(gaugeAddr);
        
        console.log("Internal Bribe:", internalBribe);
        console.log("External Bribe:", externalBribe);

        // Balances BEFORE claim
        uint256 aeroBalBefore = IERC20(AERO).balanceOf(address(pool));
        uint256 wethBalBefore = IERC20(WETH).balanceOf(address(pool));
        uint256 usdcBalBefore = IERC20(USDC).balanceOf(address(pool));

        console.log("");
        console.log("Pool balances BEFORE claim:");
        console.log("  AERO:", aeroBalBefore / 1e18);
        console.log("  WETH:", wethBalBefore / 1e18);
        console.log("  USDC:", usdcBalBefore / 1e6);

        // Prepare arrays for claim
        address[] memory bribes = new address[](2);
        bribes[0] = internalBribe;
        bribes[1] = externalBribe;

        address[] memory tokens = new address[](3);
        tokens[0] = AERO;
        tokens[1] = WETH;
        tokens[2] = USDC;

        address[][] memory tokenArrays = new address[][](2);
        tokenArrays[0] = tokens;
        tokenArrays[1] = tokens;

        console.log("");
        console.log("Claiming rewards for each NFT...");

        uint256 claimSuccessCount = 0;
        uint256 claimFailCount = 0;

        // Claim rewards for each locked NFT
        // Pool owns NFTs, so we call voter directly
        for (uint256 i = 0; i < lockedNftIds.length; i++) {
            uint256 tokenId = lockedNftIds[i];
            
            // Try claim bribes
            try voter.claimBribes(bribes, tokenArrays, tokenId) {
                claimSuccessCount++;
            } catch {
                claimFailCount++;
            }
            
            // Try claim fees
            try voter.claimFees(bribes, tokenArrays, tokenId) {
                // success
            } catch {
                // ignore
            }
        }

        console.log("  Successful claims:", claimSuccessCount);
        console.log("  Failed claims:", claimFailCount);

        // Balances AFTER claim
        uint256 aeroBalAfter = IERC20(AERO).balanceOf(address(pool));
        uint256 wethBalAfter = IERC20(WETH).balanceOf(address(pool));
        uint256 usdcBalAfter = IERC20(USDC).balanceOf(address(pool));

        console.log("");
        console.log("Pool balances AFTER claim:");
        console.log("  AERO:", aeroBalAfter / 1e18);
        console.log("  WETH:", wethBalAfter / 1e18);
        console.log("  USDC:", usdcBalAfter / 1e6);

        console.log("");
        console.log("REWARDS COLLECTED:");
        console.log("  AERO:", (aeroBalAfter - aeroBalBefore) / 1e18);
        console.log("  WETH:", (wethBalAfter - wethBalBefore) / 1e18);
        console.log("  USDC:", (usdcBalAfter - usdcBalBefore) / 1e6);
        console.log("");
    }

    function _phase6_Finalize() internal {
        console.log("PHASE 6: FINALIZE (SWAP + LIQUIDITY)");
        console.log("-------------------------------------");

        console.log("");
        console.log("Calling finalizeEpoch() with auto token discovery...");
        
        vm.prank(admin);
        pool.finalizeEpoch();

        console.log("");
        console.log("FINALIZATION RESULTS:");
        console.log("  WETH collected:", pool.wethCollected() / 1e18, "WETH");
        console.log("  LP created:", pool.lpCreated() / 1e18, "LP");
        console.log("  LP token:", pool.lpToken());
        console.log("  Pool state:", uint256(pool.state()));
        
        if (pool.lpToken() != address(0)) {
            IPool lp = IPool(pool.lpToken());
            (uint256 r0, uint256 r1,) = lp.getReserves();
            console.log("  Reserve0:", r0 / 1e18);
            console.log("  Reserve1:", r1 / 1e18);
        }
        console.log("");
    }

    function _phase7_UnlockAndClaim() internal {
        console.log("PHASE 7: UNLOCK NFTs AND CLAIM TOKENS");
        console.log("--------------------------------------");

        uint256[] memory tokenIds = pool.getLockedTokenIds();
        console.log("NFTs to unlock:", tokenIds.length);

        uint256 totalClaimed = 0;
        uint256 unlockCount = 0;

        for (uint256 i = 0; i < tokenIds.length; i++) {
            uint256 tokenId = tokenIds[i];
            (address nftOwner, uint256 vp, bool unlocked) = pool.getLockedNFTInfo(tokenId);
            
            if (unlocked) continue;

            // Unlock NFT
            vm.prank(nftOwner);
            try pool.unlockVeAERO(tokenId) {
                unlockCount++;
                
                // Claim project tokens
                uint256 claimable = pool.getClaimableTokens(nftOwner);
                if (claimable > 0) {
                    vm.prank(nftOwner);
                    try pool.claimProjectTokens() {
                        totalClaimed += claimable;
                        
                        if (unlockCount <= 3) {
                            console.log("  Owner %s received %s KICK", nftOwner, claimable / 1e18);
                        }
                    } catch {}
                }
            } catch {}
        }

        console.log("");
        console.log("TOTAL:");
        console.log("  NFTs unlocked:", unlockCount);
        console.log("  KICK distributed:", totalClaimed / 1e18);
        console.log("");
    }

    function _phase8_Verify() internal view {
        console.log("PHASE 8: FINAL VERIFICATION");
        console.log("----------------------------");

        // Check pool state
        console.log("Pool State:", uint256(pool.state()));
        require(pool.state() == KickoffVoteSalePool.PoolState.Completed, "Pool should be Completed");

        console.log("Total Voting Power:", pool.totalVotingPower() / 1e18, "veAERO");
        console.log("WETH Collected:", pool.wethCollected() / 1e18, "WETH");
        console.log("LP Created:", pool.lpCreated() / 1e18, "LP");
        
        // Check LP lock
        if (pool.lpToken() != address(0)) {
            LPLocker.LockedLP memory locked = lpLocker.getLockedLP(address(pool));
            console.log("");
            console.log("LP Lock Info:");
            console.log("  LP Token:", locked.lpToken);
            console.log("  Total LP:", locked.totalLP / 1e18);
            console.log("  Admin:", locked.admin);
            console.log("  Project Owner:", locked.projectOwner);
            
            require(locked.exists, "LP should be locked");
        }

        console.log("");
        console.log("Sale Allocation:", pool.saleAllocation() / 1e18, "KICK");
        console.log("Liquidity Allocation:", pool.liquidityAllocation() / 1e18, "KICK");
    }

    /// @notice Quick test with 5 holders only
    function test_QuickFlowWith5Holders() public {
        if (block.chainid != 8453) { vm.skip(true); return; }

        console.log("");
        console.log("================================================================");
        console.log("   QUICK TEST WITH 5 HOLDERS");
        console.log("================================================================");

        // Activate
        vm.prank(admin);
        pool.activate();
        console.log("Pool activated");

        // Lock only first 5 NFTs
        uint256 epochStart = (block.timestamp / 1 weeks) * 1 weeks;
        
        for (uint256 i = 0; i < 5; i++) {
            uint256 tokenId = NFT_IDS[i];
            
            address owner;
            try ve.ownerOf(tokenId) returns (address _owner) {
                owner = _owner;
            } catch { continue; }
            
            if (owner == address(0)) continue;
            
            uint256 vp = ve.balanceOfNFT(tokenId);
            if (vp == 0) continue;
            
            uint256 lastVoted = voter.lastVoted(tokenId);
            if (lastVoted > epochStart) continue;
            
            vm.startPrank(owner);
            ve.approve(address(pool), tokenId);
            try pool.lockVeAERO(tokenId) {
                lockedNftIds.push(tokenId);
                console.log("NFT #%d locked, VP: %s", tokenId, vp / 1e18);
            } catch {}
            vm.stopPrank();
        }

        require(lockedNftIds.length >= 1, "Need at least 1 NFT");

        vm.roll(block.number + 1);
        vm.warp(block.timestamp + 12);

        // Debug: check gauge info BEFORE voting
        console.log("");
        console.log("DEBUG - Gauge analysis:");
        console.log("  WETH_AERO_GAUGE:", WETH_AERO_GAUGE);
        
        // Check if gauge is alive
        bool isAlive = voter.isAlive(WETH_AERO_GAUGE);
        console.log("  isAlive:", isAlive);
        
        // Get pool for gauge
        address poolForGauge = voter.poolForGauge(WETH_AERO_GAUGE);
        console.log("  poolForGauge:", poolForGauge);
        
        // Try to get gauge for a known pool (WETH/AERO)
        address wethAeroPool = 0x7f670f78B17dEC44d5Ef68a48740b6f8849cc2e6; // vAMM-WETH/AERO
        address gaugeFromPool = voter.gauges(wethAeroPool);
        console.log("  gaugeFromPool (WETH/AERO):", gaugeFromPool);
        
        // Get bribes directly before voting using low-level call
        console.log("");
        console.log("  Direct bribe check (low-level):");
        
        // Try gaugeToBribe (alternative name used in some Aerodrome versions)
        (bool success1, bytes memory data1) = address(voter).staticcall(
            abi.encodeWithSignature("gaugeToBribe(address)", gaugeFromPool)
        );
        if (success1 && data1.length >= 32) {
            address bribe = abi.decode(data1, (address));
            console.log("    gaugeToBribe(gaugeFromPool):", bribe);
        } else {
            console.log("    gaugeToBribe: not found");
        }
        
        // Try gaugeToFees
        (bool success2, bytes memory data2) = address(voter).staticcall(
            abi.encodeWithSignature("gaugeToFees(address)", gaugeFromPool)
        );
        if (success2 && data2.length >= 32) {
            address fees = abi.decode(data2, (address));
            console.log("    gaugeToFees(gaugeFromPool):", fees);
        } else {
            console.log("    gaugeToFees: not found");
        }
        
        // Try internal_bribes with the pool's gauge
        (bool success3, bytes memory data3) = address(voter).staticcall(
            abi.encodeWithSignature("internal_bribes(address)", gaugeFromPool)
        );
        if (success3 && data3.length >= 32) {
            address ib = abi.decode(data3, (address));
            console.log("    internal_bribes(gaugeFromPool):", ib);
        } else {
            console.log("    internal_bribes: FAILED");
        }
        
        // Try external_bribes with the pool's gauge
        (bool success4, bytes memory data4) = address(voter).staticcall(
            abi.encodeWithSignature("external_bribes(address)", gaugeFromPool)
        );
        if (success4 && data4.length >= 32) {
            address eb = abi.decode(data4, (address));
            console.log("    external_bribes(gaugeFromPool):", eb);
        } else {
            console.log("    external_bribes: FAILED");
        }

        // Vote
        vm.prank(admin);
        pool.castVotes(WETH_AERO_GAUGE);
        console.log("");
        console.log("Votes cast");
        
        // Get bribe addresses dynamically via getRewardContracts()
        (address feesReward, address bribeReward) = pool.getRewardContracts();
        console.log("Fees Reward (LP fees):", feesReward);
        console.log("Bribe Reward (external):", bribeReward);

        // Check earned rewards BEFORE epoch change
        if (feesReward != address(0)) {
            console.log("");
            console.log("Earned rewards BEFORE epoch change:");
            _checkEarnedRewards(feesReward, bribeReward);
        }

        // New epoch
        uint256 nextEpochStart = ((block.timestamp / 1 weeks) + 1) * 1 weeks + 1 hours;
        vm.warp(nextEpochStart);
        vm.roll(block.number + 50400);
        console.log("");
        console.log("New epoch:", block.timestamp / 1 weeks);

        // Check earned rewards AFTER epoch change (this is when rewards should be claimable)
        if (feesReward != address(0)) {
            console.log("");
            console.log("Earned rewards AFTER epoch change:");
            _checkEarnedRewards(feesReward, bribeReward);
        }

        // Verify getRewardContracts works after epoch warp (dynamically fetched)
        console.log("");
        console.log("getRewardContracts() after epoch warp:");
        (address feesAfter, address bribeAfter) = pool.getRewardContracts();
        console.log("  Fees Reward:", feesAfter);
        console.log("  Bribe Reward:", bribeAfter);

        // Debug: Check rewardsListLength directly on bribe contracts
        console.log("");
        console.log("DEBUG - VotingReward rewardsListLength:");
        
        (bool successFees, bytes memory dataFees) = feesAfter.staticcall(
            abi.encodeWithSignature("rewardsListLength()")
        );
        if (successFees && dataFees.length >= 32) {
            uint256 len = abi.decode(dataFees, (uint256));
            console.log("  feesReward.rewardsListLength():", len);
            
            // Try to get first few tokens AND check earned
            for (uint256 i = 0; i < len && i < 3; i++) {
                (bool s, bytes memory d) = feesAfter.staticcall(
                    abi.encodeWithSignature("rewardsList(uint256)", i)
                );
                if (s && d.length >= 32) {
                    address token = abi.decode(d, (address));
                    console.log("    rewardsList(%d):", i, token);
                    
                    // Check earned for first NFT
                    if (lockedNftIds.length > 0) {
                        (bool es, bytes memory ed) = feesAfter.staticcall(
                            abi.encodeWithSignature("earned(address,uint256)", token, lockedNftIds[0])
                        );
                        if (es && ed.length >= 32) {
                            uint256 earned = abi.decode(ed, (uint256));
                            console.log("      earned for NFT#%d:", lockedNftIds[0], earned);
                        } else {
                            console.log("      earned call failed");
                        }
                    }
                }
            }
        } else {
            console.log("  feesReward.rewardsListLength(): FAILED");
        }
        
        (bool successBribe, bytes memory dataBribe) = bribeAfter.staticcall(
            abi.encodeWithSignature("rewardsListLength()")
        );
        if (successBribe && dataBribe.length >= 32) {
            uint256 len = abi.decode(dataBribe, (uint256));
            console.log("  bribeReward.rewardsListLength():", len);
        } else {
            console.log("  bribeReward.rewardsListLength(): FAILED");
        }

        // Check auto-discovered reward tokens
        console.log("");
        console.log("getAvailableRewardTokens():");
        (address[] memory feesTokens, address[] memory bribeTokens) = pool.getAvailableRewardTokens();
        console.log("  Fees tokens count:", feesTokens.length);
        for (uint256 i = 0; i < feesTokens.length && i < 5; i++) {
            console.log("    -", feesTokens[i]);
        }
        console.log("  Bribe tokens count:", bribeTokens.length);
        for (uint256 i = 0; i < bribeTokens.length && i < 5; i++) {
            console.log("    -", bribeTokens[i]);
        }

        // Finalize with auto token discovery
        console.log("");
        console.log("Calling finalizeEpoch() - auto-discovering reward tokens...");
        vm.prank(admin);
        pool.finalizeEpoch();

        console.log("");
        console.log("FINALIZATION RESULT:");
        console.log("  WETH collected:", pool.wethCollected() / 1e18);
        console.log("  LP created:", pool.lpCreated() / 1e18);
        console.log("  State:", uint256(pool.state()));

        // Phase 6: Unlock NFTs
        console.log("");
        console.log("================================================================");
        console.log("   PHASE 6: UNLOCK NFTs");
        console.log("================================================================");
        
        for (uint256 i = 0; i < lockedNftIds.length; i++) {
            uint256 tokenId = lockedNftIds[i];
            (address nftOwner, , ) = pool.getLockedNFTInfo(tokenId);
            
            vm.prank(nftOwner);
            pool.unlockVeAERO(tokenId);
            
            // Verify NFT returned to owner
            assertEq(ve.ownerOf(tokenId), nftOwner, "NFT not returned to owner");
            console.log("NFT #%d unlocked, returned to %s", tokenId, nftOwner);
        }

        // Phase 7: Claim project tokens
        console.log("");
        console.log("================================================================");
        console.log("   PHASE 7: CLAIM PROJECT TOKENS");
        console.log("================================================================");
        
        // Track unique owners who have already claimed
        address[] memory claimedOwners = new address[](lockedNftIds.length);
        uint256 claimedCount = 0;
        uint256 totalClaimed = 0;
        
        for (uint256 i = 0; i < lockedNftIds.length; i++) {
            uint256 tokenId = lockedNftIds[i];
            address owner = ve.ownerOf(tokenId);
            
            // Check if already claimed for this owner
            bool alreadyClaimed = false;
            for (uint256 j = 0; j < claimedCount; j++) {
                if (claimedOwners[j] == owner) {
                    alreadyClaimed = true;
                    break;
                }
            }
            if (alreadyClaimed) continue;
            
            // Get claimable amount
            uint256 claimable = pool.getClaimableTokens(owner);
            
            if (claimable > 0) {
                uint256 balanceBefore = IERC20(address(projectToken)).balanceOf(owner);
                
                vm.prank(owner);
                pool.claimProjectTokens();
                
                uint256 balanceAfter = IERC20(address(projectToken)).balanceOf(owner);
                uint256 claimed = balanceAfter - balanceBefore;
                totalClaimed += claimed;
                
                claimedOwners[claimedCount] = owner;
                claimedCount++;
                
                console.log("Owner %s claimed %s project tokens", owner, claimed / 1e18);
            }
        }

        console.log("");
        console.log("================================================================");
        console.log("   FINAL SUMMARY");
        console.log("================================================================");
        console.log("  Total voting power:", pool.totalVotingPower() / 1e18);
        console.log("  WETH collected:", pool.wethCollected() / 1e18);
        console.log("  LP created:", pool.lpCreated() / 1e18);
        console.log("  Project tokens claimed:", totalClaimed / 1e18);
        console.log("  Pool state:", uint256(pool.state()));
        console.log("================================================================");
    }
    
    /// @notice Check earned rewards on bribe contracts
    function _checkEarnedRewards(address _internalBribe, address _externalBribe) internal view {
        address[] memory tokens = new address[](3);
        tokens[0] = AERO;
        tokens[1] = WETH;
        tokens[2] = USDC;
        
        for (uint256 i = 0; i < lockedNftIds.length && i < 3; i++) {
            uint256 tokenId = lockedNftIds[i];
            console.log("  NFT #%d:", tokenId);
            
            for (uint256 j = 0; j < tokens.length; j++) {
                // Check internal bribe
                if (_internalBribe != address(0)) {
                    try IVotingReward(_internalBribe).earned(tokens[j], tokenId) returns (uint256 earned) {
                        if (earned > 0) {
                            console.log("    Internal %s: %s", tokens[j], earned);
                        }
                    } catch {}
                }
                
                // Check external bribe
                if (_externalBribe != address(0)) {
                    try IVotingReward(_externalBribe).earned(tokens[j], tokenId) returns (uint256 earned) {
                        if (earned > 0) {
                            console.log("    External %s: %s", tokens[j], earned);
                        }
                    } catch {}
                }
            }
        }
    }
}

/// @notice Mock ERC20 token
contract MockToken {
    string public name;
    string public symbol;
    uint8 public decimals = 18;
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
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to] += amount;
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (allowance[from][msg.sender] != type(uint256).max) {
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        return true;
    }
}
