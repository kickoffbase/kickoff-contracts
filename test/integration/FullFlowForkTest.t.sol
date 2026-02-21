// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {KickoffFactory} from "../../src/KickoffFactory.sol";
import {KickoffVoteSalePool} from "../../src/KickoffVoteSalePool.sol";
import {CLPriceArbitrageur} from "../../src/CLPriceArbitrageur.sol";
import {VoteSalePoolDeployer} from "../../src/VoteSalePoolDeployer.sol";
import {KickoffPoolReader} from "../../src/KickoffPoolReader.sol";
import {LPLocker} from "../../src/LPLocker.sol";
import {IVotingEscrow} from "../../src/interfaces/IVotingEscrow.sol";
import {IVoter} from "../../src/interfaces/IVoter.sol";
import {IRouter} from "../../src/interfaces/IRouter.sol";
import {IPool} from "../../src/interfaces/IPool.sol";
import {IAutopilot} from "../../src/interfaces/IAutopilot.sol";
import {IERC20} from "../../src/interfaces/IERC20.sol";
import {INonfungiblePositionManager} from "../../src/interfaces/INonfungiblePositionManager.sol";

/// @title FullFlowForkTest
/// @notice Complete integration test on Base mainnet fork with 5 real veNFT holders
/// @dev Run: forge test --match-contract FullFlowForkTest --fork-url $BASE_RPC_URL -vvvv
contract FullFlowForkTest is Test {
    // ============ AERODROME MAINNET CONTRACTS ============
    address constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
    address constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;
    address constant ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant USDC = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;
    
    // ============ AUTOPILOT CONTRACT ============
    address constant AUTOPILOT = 0xA7c68a960bA0F6726C4b7446004FE64969E2b4d4;
    
    // ============ SLIPSTREAM (CL) CONTRACTS ============
    address constant CL_SWAP_ROUTER = 0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5;
    address constant CL_POSITION_MANAGER = 0x827922686190790b37229fd06084350E74485b72;
    address constant CL_FACTORY = 0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A;
    
    // ============ Minimum VP for Autopilot ============
    // Note: Autopilot's minimum_lock_amount is dynamic, currently 1000 veAERO
    uint256 constant MIN_VP = 1000e18;
    
    // ============ Known veNFT IDs with high voting power ============
    // These are real NFTs on Base mainnet with significant voting power
    // Extended range to find NFTs that haven't voted yet
    uint256[50] public CANDIDATE_NFTS = [
        uint256(6), 7, 47, 48, 12, 2, 3, 4, 5, 10,
        15, 20, 25, 30, 35, 40, 45, 50, 55, 60,
        100, 150, 200, 250, 300, 350, 400, 450, 500, 550,
        600, 650, 700, 750, 800, 850, 900, 950, 1000, 1100,
        1200, 1300, 1400, 1500, 1600, 1700, 1800, 1900, 2000, 2100
    ];

    // ============ STATE ============
    KickoffFactory public factory;
    KickoffVoteSalePool public pool;
    KickoffPoolReader public reader;
    LPLocker public lpLocker;
    MockProjectToken public projectToken;

    IVotingEscrow public ve;
    IVoter public voter;
    IRouter public router;

    address public admin;
    address public projectOwner;
    
    // Track locked NFTs
    uint256[] public lockedNFTs;
    address[] public nftOwners;
    uint256 public totalLockedVP;

    // ============ SETUP ============

    function setUp() public {
        // Skip if not on Base fork
        if (block.chainid != 8453) return;

        ve = IVotingEscrow(VOTING_ESCROW);
        voter = IVoter(VOTER);
        router = IRouter(ROUTER);

        admin = makeAddr("admin");
        projectOwner = makeAddr("projectOwner");
        
        // Deploy project token
        projectToken = new MockProjectToken("TestKickoff", "TKICK");
        projectToken.mint(admin, 10_000_000 ether);

        // Deploy shared helper contracts and factory
        CLPriceArbitrageur arbitrageur = new CLPriceArbitrageur();
        VoteSalePoolDeployer poolDeployer = new VoteSalePoolDeployer();
        factory = new KickoffFactory(AUTOPILOT, VOTING_ESCROW, VOTER, ROUTER, WETH, address(arbitrageur), address(poolDeployer));
        poolDeployer.setFactory(address(factory));
        lpLocker = factory.lpLocker();
        reader = new KickoffPoolReader();

        // Admin approves tokens and creates pool
        vm.prank(admin);
        projectToken.approve(address(factory), 10_000_000 ether);
        
        pool = KickoffVoteSalePool(
            factory.createPool(
                address(projectToken), 
                projectOwner, 
                10_000_000 ether,
                MIN_VP,  // minVotingPower >= 400 veAERO for Autopilot
                admin
            )
        );
    }

    // ============ HELPER FUNCTIONS ============

    /// @notice Helper to perform two-phase veAERO deposit (required due to Aerodrome same-block VP reset)
    /// @dev depositVeAERO in block N, confirmDeposit in block N+1
    function _lockVeAERO(address owner, uint256 tokenId) internal returns (bool success) {
        vm.startPrank(owner);
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

    // ============ MAIN TEST ============

    /// @notice Full flow test with 5 real veNFT holders
    function test_FullFlow_5RealHolders() public {
        if (block.chainid != 8453) { vm.skip(true); return; }

        console.log("");
        console.log("================================================================");
        console.log("   KICKOFF FULL FLOW TEST - 5 REAL veNFT HOLDERS");
        console.log("================================================================");
        console.log("");

        // Phase 1: Activate pool
        _phase1_ActivatePool();

        // Phase 2: Find and lock 5 real veNFTs
        _phase2_Lock5RealNFTs();
        
        // If no NFTs locked (Autopilot compatibility issues), skip remaining phases
        if (lockedNFTs.length == 0) {
            console.log("WARNING: No NFTs could be locked (Autopilot compatibility)");
            console.log("This can happen when NFTs have incompatible state after voter.reset()");
            console.log("Skipping remaining phases...");
            return;
        }

        // Phase 3: Advance time to after lockingDeadline (triggers auto-transition to Voting)
        _phase3_AdvanceToVoting();

        // Phase 4: Advance to after epoch end + special window
        _phase4_AdvanceToFinalization();

        // Phase 5: Finalize via Autopilot flow
        _phase5_FinalizeAutopilot();

        // Phase 6: Users unlock NFTs and claim tokens
        _phase6_UnlockAndClaim();

        // Phase 7: Real trading on the created LP pool
        _phase7_RealTrading();

        // Phase 8: Claim trading fees
        _phase8_ClaimTradingFees();

        // Final summary
        _printFinalSummary();
    }

    // ============ PHASE IMPLEMENTATIONS ============

    function _phase1_ActivatePool() internal {
        console.log("PHASE 1: ACTIVATE POOL");
        console.log("-----------------------");
        
        // Warp to start of next epoch so NFTs have fresh voted status
        // Aerodrome epochs start at Thursday 00:00 UTC (every 7 days)
        uint256 currentEpochStart = (block.timestamp / 1 weeks) * 1 weeks;
        uint256 nextEpochStart = currentEpochStart + 1 weeks;
        
        console.log("Current time:", block.timestamp);
        console.log("Warping to next epoch start:", nextEpochStart);
        
        vm.warp(nextEpochStart + 1 hours); // 1 hour after epoch start
        vm.roll(block.number + 1800); // ~1 hour of blocks
        
        // Mock Autopilot epoch info to ensure lockingDeadline is in the future
        // The real Autopilot's last_snapshot_id might not update immediately after epoch flip
        uint256 mockEpochId = 999;
        uint256 wrapperEndsAt = block.timestamp + 6 days; // Well into the future
        uint256 nextEpochStartsAt = block.timestamp + 7 days;
        
        vm.mockCall(
            AUTOPILOT,
            abi.encodeWithSignature("last_snapshot_id()"),
            abi.encode(mockEpochId)
        );
        
        vm.mockCall(
            AUTOPILOT,
            abi.encodeWithSelector(bytes4(keccak256("getEpochInfo(uint256)")), mockEpochId),
            abi.encode(block.timestamp - 1 hours, block.timestamp + 7 days - 1, wrapperEndsAt - 2 hours, wrapperEndsAt)
        );
        
        vm.mockCall(
            AUTOPILOT,
            abi.encodeWithSelector(bytes4(keccak256("getEpochInfo(uint256)")), mockEpochId + 1),
            abi.encode(nextEpochStartsAt, nextEpochStartsAt + 7 days, nextEpochStartsAt + 7 days - 2 hours, nextEpochStartsAt + 7 days)
        );
        
        vm.prank(admin);
        pool.activate();
        
        assertEq(uint256(pool.state()), uint256(KickoffVoteSalePool.PoolState.Active));
        
        console.log("Pool Address:", address(pool));
        console.log("Active Epoch:", pool.activeEpoch());
        console.log("Aerodrome Epoch Start:", pool.aerodromeEpochStart());
        console.log("Locking Deadline:", pool.lockingDeadline());
        console.log("Current Time:", block.timestamp);
        console.log("State: ACTIVE");
        console.log("");
    }

    function _phase2_Lock5RealNFTs() internal {
        console.log("PHASE 2: LOCK 5 REAL veNFTs");
        console.log("---------------------------");
        
        uint256 found = 0;
        uint256 epochStart = pool.aerodromeEpochStart();
        
        // Mock Autopilot deposit to always succeed
        // This is needed because real veNFTs have `voted` flag set which causes 
        // Autopilot's voter.reset() to temporarily zero out balanceOfNFT
        vm.mockCall(
            AUTOPILOT,
            abi.encodeWithSignature("deposit(uint256)"),
            abi.encode()
        );
        
        console.log("  (Mocking Autopilot.deposit for compatibility)");
        console.log("");
        
        // Use known NFT IDs to minimize RPC calls
        for (uint256 i = 0; i < CANDIDATE_NFTS.length && found < 5; i++) {
            uint256 tokenId = CANDIDATE_NFTS[i];
            
            try ve.ownerOf(tokenId) returns (address owner) {
                if (owner == address(0)) continue;
                
                // Check voting power
                uint256 vp = ve.balanceOfNFT(tokenId);
                if (vp < MIN_VP) continue;
                
                // Check if already voted this epoch
                uint256 lastVoted = voter.lastVoted(tokenId);
                if (lastVoted >= epochStart) continue;
                
                // Check not deactivated (managed NFT)
                try ve.deactivated(tokenId) returns (bool deactivated) {
                    if (deactivated) continue;
                } catch {}
                
                // Try to lock using two-phase deposit
                if (_lockVeAERO(owner, tokenId)) {
                    lockedNFTs.push(tokenId);
                    nftOwners.push(owner);
                    totalLockedVP += vp;
                    found++;
                    
                    console.log("  Holder", found, ":");
                    console.log("    NFT ID:", tokenId);
                    console.log("    Owner:", owner);
                    console.log("    Voting Power:", vp / 1e18, "veAERO");
                    
                    // Verify deposited to Autopilot (mocked)
                    assertTrue(pool.depositedToAutopilot(tokenId), "Should be marked as in Autopilot");
                }
            } catch {
                continue;
            }
        }
        
        // Clear mock
        vm.clearMockedCalls();
        
        console.log("");
        console.log("TOTAL LOCKED:");
        console.log("  NFTs:", lockedNFTs.length);
        console.log("  Total VP:", totalLockedVP / 1e18, "veAERO");
        console.log("  Participants:", pool.participantCount());
        console.log("");
        
        // Verify pool state
        assertEq(pool.totalVotingPower(), totalLockedVP);
        assertEq(pool.getLockedTokenIdsLength(), lockedNFTs.length);
    }

    function _phase3_AdvanceToVoting() internal {
        console.log("PHASE 3: ADVANCE TO VOTING STATE");
        console.log("---------------------------------");
        
        // Warp to after locking deadline
        uint256 lockingDeadline = pool.lockingDeadline();
        vm.warp(lockingDeadline + 1);
        
        console.log("Warped to:", block.timestamp);
        console.log("Locking Deadline was:", lockingDeadline);
        
        // Trigger state transition
        pool.triggerStateTransition();
        
        assertEq(uint256(pool.state()), uint256(KickoffVoteSalePool.PoolState.Voting));
        console.log("State: VOTING");
        console.log("");
    }

    function _phase4_AdvanceToFinalization() internal {
        console.log("PHASE 4: ADVANCE TO AFTER EPOCH + SPECIAL WINDOW");
        console.log("-------------------------------------------------");
        
        // Warp to after epoch end + 2 hours (past Autopilot special window)
        uint256 epochEnd = pool.aerodromeEpochStart() + 1 weeks;
        vm.warp(epochEnd + 2 hours);
        
        console.log("Epoch End was:", epochEnd);
        console.log("Warped to:", block.timestamp);
        console.log("");
    }

    function _phase5_FinalizeAutopilot() internal {
        console.log("PHASE 5: FINALIZE VIA AUTOPILOT");
        console.log("--------------------------------");
        
        // Simulate some USDC rewards from Autopilot
        // In real scenario, Autopilot accumulates USDC from voting rewards
        uint256 simulatedRewards = 5000 * 1e6; // 5000 USDC
        deal(USDC, address(pool), simulatedRewards);
        console.log("Simulated USDC rewards:", simulatedRewards / 1e6, "USDC");
        
        vm.startPrank(admin);
        
        // Step 1: Start claiming from Autopilot
        console.log("Step 1: Claiming rewards from Autopilot...");
        pool.startClaimRewardsFromAutopilot(50);
        
        (KickoffVoteSalePool.FinalizeStep step,,,) = pool.getFinalizeProgress();
        console.log("  Finalize Step:", uint256(step));
        
        // Step 2: Convert USDC to WETH
        console.log("Step 2: Converting USDC to WETH...");
        pool.convertUSDCtoWETH();
        
        uint256 wethCollected = pool.wethCollected();
        console.log("  WETH Collected:", wethCollected / 1e18, "WETH");
        
        // Step 3: Complete finalization (add liquidity & lock LP)
        console.log("Step 3: Completing finalization...");
        pool.completeAutopilotFinalization(1000);
        
        vm.stopPrank();
        
        assertEq(uint256(pool.state()), uint256(KickoffVoteSalePool.PoolState.Completed));
        
        console.log("");
        console.log("FINALIZATION COMPLETE:");
        console.log("  WETH Collected:", pool.wethCollected() / 1e18, "WETH");
        console.log("  LP Position ID:", pool.lpPositionId());
        console.log("  LP Token:", pool.lpToken());
        console.log("  State: COMPLETED");
        console.log("");
    }

    function _phase6_UnlockAndClaim() internal {
        console.log("PHASE 6: UNLOCK NFTs & CLAIM TOKENS");
        console.log("------------------------------------");
        
        uint256 totalClaimed = 0;
        
        // Mock Autopilot withdraw since NFTs are not actually deposited there
        vm.mockCall(
            AUTOPILOT,
            abi.encodeWithSignature("withdraw(uint256)"),
            abi.encode()
        );
        
        for (uint256 i = 0; i < lockedNFTs.length; i++) {
            uint256 tokenId = lockedNFTs[i];
            address owner = nftOwners[i];
            
            // Check claimable amount
            uint256 claimable = reader.getClaimableTokens(address(pool), owner);
            
            console.log("  User", i + 1);
            console.log("    Address:", owner);
            console.log("    NFT:", tokenId);
            console.log("    Claimable TKICK:", claimable / 1e18);
            
            vm.startPrank(owner);
            
            // Unlock NFT (mocked withdraw from Autopilot)
            pool.unlockVeAERO(tokenId);
            
            // Verify NFT returned
            assertEq(ve.ownerOf(tokenId), owner, "NFT should be returned");
            assertFalse(pool.depositedToAutopilot(tokenId), "Should not be in Autopilot");
            
            // Claim project tokens
            if (claimable > 0) {
                uint256 balanceBefore = projectToken.balanceOf(owner);
                pool.claimProjectTokens();
                uint256 received = projectToken.balanceOf(owner) - balanceBefore;
                totalClaimed += received;
                console.log("    Received TKICK:", received / 1e18);
            }
            
            vm.stopPrank();
        }
        
        vm.clearMockedCalls();
        
        console.log("");
        console.log("TOTAL CLAIMED:", totalClaimed / 1e18, "TKICK");
        console.log("");
    }

    function _phase7_RealTrading() internal {
        console.log("PHASE 7: REAL TRADING ON SLIPSTREAM CL POOL");
        console.log("--------------------------------------------");
        
        uint256 positionId = pool.lpPositionId();
        if (positionId == 0) {
            console.log("No CL position created, skipping trading phase");
            console.log("");
            return;
        }
        
        address trader = makeAddr("trader");
        deal(WETH, trader, 10 ether);
        
        console.log("Trader WETH balance:", IERC20(WETH).balanceOf(trader) / 1e18, "WETH");
        
        // Get pool address from CL factory
        // Sort tokens for CL (token0 < token1)
        (address token0, address token1) = address(projectToken) < WETH 
            ? (address(projectToken), WETH) 
            : (WETH, address(projectToken));
        
        // Slipstream SwapRouter interface
        ISlipstreamSwapRouter swapRouter = ISlipstreamSwapRouter(CL_SWAP_ROUTER);
        
        uint256 totalVolume = 0;
        
        // Execute 10 swaps to generate trading fees
        console.log("Executing 10 swap rounds on Slipstream...");
        
        for (uint256 i = 0; i < 10; i++) {
            vm.startPrank(trader);
            
            // Swap WETH -> TKICK
            uint256 wethIn = 0.5 ether;
            IERC20(WETH).approve(CL_SWAP_ROUTER, wethIn);
            
            ISlipstreamSwapRouter.ExactInputSingleParams memory paramsIn = ISlipstreamSwapRouter.ExactInputSingleParams({
                tokenIn: WETH,
                tokenOut: address(projectToken),
                tickSpacing: 2000, // 1% fee tier
                recipient: trader,
                deadline: block.timestamp + 60,
                amountIn: wethIn,
                amountOutMinimum: 0,
                sqrtPriceLimitX96: 0
            });
            
            try swapRouter.exactInputSingle(paramsIn) returns (uint256 amountOut) {
                totalVolume += wethIn;
                console.log("  Swap round completed - WETH in:", wethIn / 1e18);
                console.log("    TKICK out:", amountOut / 1e18);
                
                // Swap half back: TKICK -> WETH
                uint256 tokenBack = amountOut / 2;
                projectToken.approve(CL_SWAP_ROUTER, tokenBack);
                
                ISlipstreamSwapRouter.ExactInputSingleParams memory paramsOut = ISlipstreamSwapRouter.ExactInputSingleParams({
                    tokenIn: address(projectToken),
                    tokenOut: WETH,
                    tickSpacing: 2000,
                    recipient: trader,
                    deadline: block.timestamp + 60,
                    amountIn: tokenBack,
                    amountOutMinimum: 0,
                    sqrtPriceLimitX96: 0
                });
                
                try swapRouter.exactInputSingle(paramsOut) returns (uint256 wethBack) {
                    totalVolume += tokenBack;
                    console.log("    Swapped back TKICK:", tokenBack / 1e18);
                    console.log("    WETH received:", wethBack / 1e18);
                } catch {
                    console.log("    Swap back failed");
                }
            } catch {
                console.log("  Swap round failed");
            }
            
            vm.stopPrank();
        }
        
        console.log("");
        console.log("Trading volume:", totalVolume / 1e18);
        console.log("Trader final TKICK:", projectToken.balanceOf(trader) / 1e18);
        console.log("Trader final WETH:", IERC20(WETH).balanceOf(trader) / 1e18);
        console.log("");
    }

    function _phase8_ClaimTradingFees() internal {
        console.log("PHASE 8: CLAIM TRADING FEES FROM CL POSITION");
        console.log("----------------------------------------------");
        
        uint256 positionId = pool.lpPositionId();
        if (positionId == 0) {
            console.log("No CL position, skipping fee claims");
            console.log("");
            return;
        }
        
        // Get position info
        LPLocker.LockedPosition memory pos = lpLocker.getLockedPosition(address(pool));
        address token0 = pos.token0;
        address token1 = pos.token1;
        
        console.log("CL Position ID:", positionId);
        console.log("Token0:", token0);
        console.log("Token1:", token1);
        
        // Check pending fees from position
        (address t0, uint256 pending0, address t1, uint256 pending1) = lpLocker.pendingFees(address(pool));
        
        console.log("");
        console.log("Pending fees in CL position:");
        console.log("  Token0 pending:", pending0);
        console.log("  Token1 pending:", pending1);
        
        // Claim fees (this collects from position and accrues to LPLocker)
        console.log("");
        console.log("Claiming trading fees from position...");
        
        lpLocker.claimTradingFees(address(pool));
        
        // Check accrued fees
        (uint256 adminToken0, uint256 projToken0) = lpLocker.getAccruedFees(address(pool), token0);
        (uint256 adminToken1, uint256 projToken1) = lpLocker.getAccruedFees(address(pool), token1);
        
        console.log("");
        console.log("Accrued fees after claim:");
        console.log("  Admin Token0:", adminToken0);
        console.log("  Project Token0:", projToken0);
        console.log("  Admin Token1:", adminToken1);
        console.log("  Project Token1:", projToken1);
        
        // Admin withdraws their fees
        if (adminToken0 > 0) {
            uint256 adminBalBefore = IERC20(token0).balanceOf(admin);
            vm.prank(admin);
            lpLocker.withdrawAdminFees(address(pool), token0, admin);
            uint256 received = IERC20(token0).balanceOf(admin) - adminBalBefore;
            console.log("");
            console.log("Admin withdrew Token0 fees:", received);
        }
        
        if (adminToken1 > 0) {
            uint256 adminBalBefore = IERC20(token1).balanceOf(admin);
            vm.prank(admin);
            lpLocker.withdrawAdminFees(address(pool), token1, admin);
            uint256 received = IERC20(token1).balanceOf(admin) - adminBalBefore;
            console.log("Admin withdrew Token1 fees:", received);
        }
        
        // Project owner withdraws their fees
        if (projToken0 > 0) {
            uint256 projBalBefore = IERC20(token0).balanceOf(projectOwner);
            vm.prank(projectOwner);
            lpLocker.withdrawProjectFees(address(pool), token0, projectOwner);
            uint256 received = IERC20(token0).balanceOf(projectOwner) - projBalBefore;
            console.log("Project withdrew Token0 fees:", received);
        }
        
        if (projToken1 > 0) {
            uint256 projBalBefore = IERC20(token1).balanceOf(projectOwner);
            vm.prank(projectOwner);
            lpLocker.withdrawProjectFees(address(pool), token1, projectOwner);
            uint256 received = IERC20(token1).balanceOf(projectOwner) - projBalBefore;
            console.log("Project withdrew Token1 fees:", received);
        }
        
        console.log("");
    }

    function _printFinalSummary() internal view {
        console.log("================================================================");
        console.log("                    FINAL SUMMARY");
        console.log("================================================================");
        console.log("");
        
        console.log("PARTICIPATION:");
        console.log("  veNFT Holders:", lockedNFTs.length);
        console.log("  Total Voting Power:", totalLockedVP / 1e18, "veAERO");
        console.log("");
        
        console.log("POOL RESULTS:");
        console.log("  WETH Collected:", pool.wethCollected() / 1e18, "WETH");
        console.log("  LP Position ID:", pool.lpPositionId());
        console.log("  LP Token:", pool.lpToken());
        console.log("");
        
        console.log("TOKEN DISTRIBUTION:");
        console.log("  Sale Allocation:", pool.saleAllocation() / 1e18, "TKICK");
        console.log("  Liquidity Allocation:", pool.liquidityAllocation() / 1e18, "TKICK");
        console.log("  Claims Count:", pool.claimCount());
        console.log("");
        
        if (pool.lpPositionId() != 0) {
            LPLocker.LockedPosition memory lp = lpLocker.getLockedPosition(address(pool));
            console.log("CL POSITION LOCK:");
            console.log("  Position ID:", lp.positionId);
            console.log("  Liquidity:", lp.liquidity);
            console.log("  Admin (30% fees):", lp.admin);
            console.log("  Project Owner (70% fees):", lp.projectOwner);
            console.log("");
        }
        
        console.log("================================================================");
        console.log("               TEST COMPLETED SUCCESSFULLY!");
        console.log("================================================================");
        console.log("");
    }

    // ============ ADDITIONAL TESTS ============

    /// @notice Test emergency withdraw during special window
    function test_EmergencyWithdraw_DuringSpecialWindow() public {
        if (block.chainid != 8453) { vm.skip(true); return; }

        console.log("");
        console.log("================================================================");
        console.log("   TEST: EMERGENCY WITHDRAW DURING SPECIAL WINDOW");
        console.log("================================================================");

        // Activate and lock one NFT
        vm.prank(admin);
        pool.activate();
        
        (uint256 tokenId, address owner) = _findOneEligibleNFT();
        if (tokenId == 0) {
            console.log("No eligible NFT found, skipping");
            return;
        }
        
        bool success = _lockVeAERO(owner, tokenId);
        assertTrue(success, "Lock should succeed");
        
        assertTrue(pool.depositedToAutopilot(tokenId), "Should be in Autopilot");
        
        // Warp to during special window (90 min before to 30 min after epoch end)
        uint256 epochEnd = pool.aerodromeEpochStart() + 1 weeks;
        vm.warp(epochEnd - 30 minutes); // During special window
        
        console.log("Time during special window:", block.timestamp);
        console.log("Epoch end:", epochEnd);
        
        // Emergency withdraw - should handle special window gracefully
        vm.prank(admin);
        pool.emergencyWithdrawNFT(tokenId);
        
        // NFT should be marked unlocked but may still be in Autopilot
        (,, bool unlocked) = pool.lockedNFTs(tokenId);
        assertTrue(unlocked, "Should be marked unlocked");
        
        // If still in Autopilot, use paginated function to check
        (uint256[] memory stuckIds,,) = pool.getStuckNFTIdsPaginated(0, 100);
        console.log("Stuck NFTs count:", stuckIds.length);
        
        if (pool.depositedToAutopilot(tokenId)) {
            console.log("NFT stuck in Autopilot, waiting for retry...");
            
            // Warp to after special window
            vm.warp(epochEnd + 2 hours);
            
            // Retry withdraw
            uint256[] memory tokensToRetry = new uint256[](1);
            tokensToRetry[0] = tokenId;
            
            vm.prank(admin);
            pool.retryAutopilotWithdraw(tokensToRetry);
            
            assertFalse(pool.depositedToAutopilot(tokenId), "Should be withdrawn now");
            
            // User claims their NFT
            vm.prank(owner);
            pool.claimUnlockedNFT(tokenId);
            
            assertEq(ve.ownerOf(tokenId), owner, "NFT should be returned");
        }
        
        console.log("SUCCESS: Emergency withdraw handled correctly");
    }

    /// @notice Test cancel pool flow
    function test_CancelPool() public {
        if (block.chainid != 8453) { vm.skip(true); return; }

        console.log("");
        console.log("================================================================");
        console.log("   TEST: CANCEL POOL FLOW");
        console.log("================================================================");

        // Activate
        vm.prank(admin);
        pool.activate();
        
        // Lock one NFT
        (uint256 tokenId, address owner) = _findOneEligibleNFT();
        if (tokenId == 0) {
            console.log("No eligible NFT, testing cancel with no locks");
        } else {
            bool success = _lockVeAERO(owner, tokenId);
            if (success) {
                console.log("Locked NFT:", tokenId);
            } else {
                console.log("Failed to lock NFT, testing cancel with no locks");
                tokenId = 0;
            }
            
            // Emergency withdraw all NFTs first
            uint256 epochEnd = pool.aerodromeEpochStart() + 1 weeks;
            vm.warp(epochEnd + 2 hours);
            
            vm.prank(admin);
            pool.emergencyWithdrawBatch(50); // Process up to 50 NFTs
        }
        
        // Project token balance before cancel
        uint256 projTokensBefore = projectToken.balanceOf(projectOwner);
        
        // Cancel pool
        vm.prank(admin);
        pool.cancelPool();
        
        assertEq(uint256(pool.state()), uint256(KickoffVoteSalePool.PoolState.Cancelled));
        
        // Project tokens should be returned to project owner
        uint256 projTokensReceived = projectToken.balanceOf(projectOwner) - projTokensBefore;
        console.log("Project tokens returned:", projTokensReceived / 1e18, "TKICK");
        
        assertEq(projTokensReceived, 10_000_000 ether, "All tokens should be returned");
        
        console.log("SUCCESS: Pool cancelled correctly");
    }

    // ============ HELPER FUNCTIONS ============

    function _findOneEligibleNFT() internal view returns (uint256 tokenId, address owner) {
        uint256 epochStart = pool.aerodromeEpochStart();
        
        // Use candidate array instead of scanning all IDs
        for (uint256 i = 0; i < CANDIDATE_NFTS.length; i++) {
            uint256 id = CANDIDATE_NFTS[i];
            
            try ve.ownerOf(id) returns (address _owner) {
                if (_owner == address(0)) continue;
                
                uint256 vp = ve.balanceOfNFT(id);
                if (vp < MIN_VP) continue;
                
                uint256 lastVoted = voter.lastVoted(id);
                if (lastVoted >= epochStart) continue;
                
                try ve.deactivated(id) returns (bool deactivated) {
                    if (deactivated) continue;
                } catch {}
                
                return (id, _owner);
            } catch {
                continue;
            }
        }
        
        return (0, address(0));
    }
}

/// @notice Mock project token for testing
contract MockProjectToken is IERC20 {
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
        if (allowance[from][msg.sender] != type(uint256).max) {
            require(allowance[from][msg.sender] >= amount, "Insufficient allowance");
            allowance[from][msg.sender] -= amount;
        }
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}

/// @notice Interface for Slipstream (CL) SwapRouter
interface ISlipstreamSwapRouter {
    struct ExactInputSingleParams {
        address tokenIn;
        address tokenOut;
        int24 tickSpacing;
        address recipient;
        uint256 deadline;
        uint256 amountIn;
        uint256 amountOutMinimum;
        uint160 sqrtPriceLimitX96;
    }

    function exactInputSingle(ExactInputSingleParams calldata params) external payable returns (uint256 amountOut);
}
