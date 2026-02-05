// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {KickoffFactory} from "../src/KickoffFactory.sol";
import {KickoffVoteSalePool} from "../src/KickoffVoteSalePool.sol";
import {KickoffPoolReader} from "../src/KickoffPoolReader.sol";
import {LPLocker} from "../src/LPLocker.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockVotingEscrow} from "./mocks/MockVotingEscrow.sol";
import {MockVoter} from "./mocks/MockVoter.sol";
import {MockRouter} from "./mocks/MockRouter.sol";
import {MockAutopilot} from "./mocks/MockAutopilot.sol";
import {MockNonfungiblePositionManager} from "./mocks/MockNonfungiblePositionManager.sol";

contract KickoffVoteSalePoolTest is Test {
    KickoffFactory public factory;
    KickoffVoteSalePool public pool;
    KickoffPoolReader public reader;
    LPLocker public lpLocker;

    MockERC20 public projectToken;
    MockERC20 public weth;
    MockERC20 public usdc;
    MockVotingEscrow public votingEscrow;
    MockVoter public voter;
    MockRouter public router;
    MockAutopilot public autopilot;

    address public admin = address(0x1);
    address public projectOwner = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);

    address public mockGauge = address(0x100);
    address public mockPool = address(0x101);
    address public mockInternalBribe = address(0x102);
    address public mockExternalBribe = address(0x103);
    
    // Hardcoded addresses from KickoffVoteSalePool/LPLocker
    address constant AUTOPILOT_ADDRESS = 0xA7c68a960bA0F6726C4b7446004FE64969E2b4d4;
    address constant USDC_ADDRESS = 0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913;
    address constant AERODROME_POOL_FACTORY = 0x420DD381b31aEf6683db6B902084cB0FFECe40Da;
    address constant SLIPSTREAM_POSITION_MANAGER = 0x827922686190790b37229fd06084350E74485b72;

    address constant AUTOPILOT_DEPOSIT_VALIDATOR = address(0x999);
    
    uint256 public constant TOTAL_ALLOCATION = 1_000_000 ether;
    uint256 public constant USER1_VOTING_POWER = 100_000 ether;
    uint256 public constant USER2_VOTING_POWER = 50_000 ether;
    uint256 public constant MIN_VOTING_POWER = 1000 ether; // Autopilot minimum (dynamic)

    function setUp() public {
        // Set realistic timestamp (current epoch > 0)
        vm.warp(1700000000); // Nov 2023

        // Deploy mock contracts
        weth = new MockERC20("Wrapped ETH", "WETH", 18);
        votingEscrow = new MockVotingEscrow();
        voter = new MockVoter(address(votingEscrow));
        router = new MockRouter(address(weth));
        projectToken = new MockERC20("Project Token", "PROJECT", 18);
        
        // Deploy USDC mock at hardcoded address
        usdc = new MockERC20("USD Coin", "USDC", 6);
        vm.etch(USDC_ADDRESS, address(usdc).code);
        
        // Deploy Autopilot mock at hardcoded address
        autopilot = new MockAutopilot(USDC_ADDRESS);
        vm.etch(AUTOPILOT_ADDRESS, address(autopilot).code);
        
        // Mock Autopilot's deposit_validator and minimum_lock_amount
        vm.mockCall(AUTOPILOT_ADDRESS, abi.encodeWithSignature("deposit_validator()"), abi.encode(AUTOPILOT_DEPOSIT_VALIDATOR));
        vm.mockCall(AUTOPILOT_DEPOSIT_VALIDATOR, abi.encodeWithSignature("minimum_lock_amount()"), abi.encode(1000 ether));
        // Mock getMinDepositAmount to return global minimum (non-whitelisted users)
        vm.mockCall(AUTOPILOT_DEPOSIT_VALIDATOR, abi.encodeWithSignature("getMinDepositAmount(address)"), abi.encode(1000 ether));
        
        // Mock Autopilot's epoch info for dynamic lockingDeadline
        // Current epoch (id=1): Thursday-based epochs
        uint256 currentEpochStart = (block.timestamp / 1 weeks) * 1 weeks;
        uint256 currentEpochEnd = currentEpochStart + 1 weeks;
        uint256 wrappedStart = currentEpochEnd - 90 minutes;
        uint256 wrappedEnd = currentEpochEnd + 30 minutes;
        
        vm.mockCall(AUTOPILOT_ADDRESS, abi.encodeWithSignature("last_snapshot_id()"), abi.encode(uint256(1)));
        vm.mockCall(AUTOPILOT_ADDRESS, abi.encodeWithSelector(bytes4(keccak256("getEpochInfo(uint256)")), uint256(1)), 
            abi.encode(currentEpochStart, currentEpochEnd, wrappedStart, wrappedEnd));
        // Next epoch (id=2)
        vm.mockCall(AUTOPILOT_ADDRESS, abi.encodeWithSelector(bytes4(keccak256("getEpochInfo(uint256)")), uint256(2)), 
            abi.encode(currentEpochEnd, currentEpochEnd + 1 weeks, currentEpochEnd + 1 weeks - 90 minutes, currentEpochEnd + 1 weeks + 30 minutes));
        
        // Mock Aerodrome PoolFactory - always return true for isPool
        vm.mockCall(
            AERODROME_POOL_FACTORY,
            abi.encodeWithSignature("isPool(address)"),
            abi.encode(true)
        );
        
        // Deploy mock Slipstream position manager at hardcoded address
        MockNonfungiblePositionManager mockPositionManager = new MockNonfungiblePositionManager(address(0));
        vm.etch(SLIPSTREAM_POSITION_MANAGER, address(mockPositionManager).code);
        
        // Set nextTokenId to 1 in storage (slot 1 in MockNonfungiblePositionManager)
        // nextTokenId is the 3rd storage variable, after _positions (slot 0) and getApproved (slot 1)
        // Actually nextTokenId is declared after those mappings, so it's at slot 2
        vm.store(SLIPSTREAM_POSITION_MANAGER, bytes32(uint256(2)), bytes32(uint256(1)));

        // Setup voter mock
        voter.setGauge(mockPool, mockGauge);
        voter.setBribes(mockGauge, mockInternalBribe, mockExternalBribe);

        // Deploy factory
        factory = new KickoffFactory(
            AUTOPILOT_ADDRESS,
            address(votingEscrow),
            address(voter),
            address(router),
            address(weth)
        );

        lpLocker = factory.lpLocker();
        reader = new KickoffPoolReader();

        // Mint tokens to admin
        projectToken.mint(admin, TOTAL_ALLOCATION);

        // Approve tokens from admin (who will provide tokens)
        vm.prank(admin);
        projectToken.approve(address(factory), TOTAL_ALLOCATION);
        
        // Create pool - called by factory owner (this test contract)
        // Factory transfers tokens from poolAdmin (admin)
        // minVotingPower must be >= MIN_AUTOPILOT_VOTING_POWER (400e18)
        address poolAddr = factory.createPool(address(projectToken), projectOwner, TOTAL_ALLOCATION, MIN_VOTING_POWER, admin);
        pool = KickoffVoteSalePool(poolAddr);

        // Mint veAERO NFTs to users (must be >= MIN_VOTING_POWER)
        // isPermanent = false so lockVeAERO will call lockPermanent()
        votingEscrow.mint(user1, USER1_VOTING_POWER, false);
        votingEscrow.mint(user2, USER2_VOTING_POWER, false);
    }

    /// @notice Helper to update Autopilot mocks after warping to a new epoch
    /// @dev Call this after vm.warp() to ensure dynamic window checks work correctly
    function _updateAutopilotMocksForNextEpoch() internal {
        // Clear previous mocks
        vm.clearMockedCalls();
        
        // Re-mock deposit_validator
        vm.mockCall(AUTOPILOT_ADDRESS, abi.encodeWithSignature("deposit_validator()"), abi.encode(AUTOPILOT_DEPOSIT_VALIDATOR));
        vm.mockCall(AUTOPILOT_DEPOSIT_VALIDATOR, abi.encodeWithSignature("minimum_lock_amount()"), abi.encode(1000 ether));
        vm.mockCall(AUTOPILOT_DEPOSIT_VALIDATOR, abi.encodeWithSignature("getMinDepositAmount(address)"), abi.encode(1000 ether));
        
        // Calculate new epoch info based on current block.timestamp
        uint256 currentEpochStart = (block.timestamp / 1 weeks) * 1 weeks;
        uint256 currentEpochEnd = currentEpochStart + 1 weeks;
        uint256 wrappedStart = currentEpochEnd - 90 minutes;
        uint256 wrappedEnd = currentEpochEnd + 30 minutes;
        
        // Update epoch ID to 2 (we're in a new epoch)
        vm.mockCall(AUTOPILOT_ADDRESS, abi.encodeWithSignature("last_snapshot_id()"), abi.encode(uint256(2)));
        
        // Current epoch (id=2)
        vm.mockCall(AUTOPILOT_ADDRESS, abi.encodeWithSelector(bytes4(keccak256("getEpochInfo(uint256)")), uint256(2)), 
            abi.encode(currentEpochStart, currentEpochEnd, wrappedStart, wrappedEnd));
        // Next epoch (id=3)
        vm.mockCall(AUTOPILOT_ADDRESS, abi.encodeWithSelector(bytes4(keccak256("getEpochInfo(uint256)")), uint256(3)), 
            abi.encode(currentEpochEnd, currentEpochEnd + 1 weeks, currentEpochEnd + 1 weeks - 90 minutes, currentEpochEnd + 1 weeks + 30 minutes));
        
        // Re-mock PoolFactory
        vm.mockCall(
            AERODROME_POOL_FACTORY,
            abi.encodeWithSignature("isPool(address)"),
            abi.encode(true)
        );
    }

    /*//////////////////////////////////////////////////////////////
                           ACTIVATION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_Activate() public {
        assertEq(uint256(pool.state()), uint256(KickoffVoteSalePool.PoolState.Inactive));

        vm.prank(admin);
        pool.activate();

        assertEq(uint256(pool.state()), uint256(KickoffVoteSalePool.PoolState.Active));
    }

    function test_Activate_RevertNotAdmin() public {
        vm.prank(user1);
        vm.expectRevert(KickoffVoteSalePool.NotAdmin.selector);
        pool.activate();
    }

    function test_Activate_RevertWrongState() public {
        vm.prank(admin);
        pool.activate();

        vm.prank(admin);
        vm.expectRevert(KickoffVoteSalePool.InvalidState.selector);
        pool.activate();
    }

    /*//////////////////////////////////////////////////////////////
                           LOCK veAERO TESTS
    //////////////////////////////////////////////////////////////*/

    function test_DepositAndConfirmVeAERO() public {
        // Activate pool
        vm.prank(admin);
        pool.activate();

        // User1 deposits their veAERO (phase 1)
        vm.startPrank(user1);
        votingEscrow.approve(address(pool), 1);
        pool.depositVeAERO(1);
        vm.stopPrank();

        // Verify pending deposit
        (address pendingOwner, uint256 depositBlock, uint256 pendingVP) = pool.pendingDeposits(1);
        assertEq(pendingOwner, user1);
        assertEq(depositBlock, block.number);
        assertEq(pendingVP, USER1_VOTING_POWER);
        
        // NFT should be in pool but not yet confirmed
        assertEq(votingEscrow.ownerOf(1), address(pool));
        assertEq(pool.totalVotingPower(), 0); // Not yet added to total

        // Advance to next block
        vm.roll(block.number + 1);
        
        // Confirm deposit (phase 2)
        pool.confirmDeposit(1);

        // Verify lock is complete
        assertEq(pool.totalVotingPower(), USER1_VOTING_POWER);

        (address owner, uint256 votingPower, bool unlocked,) = reader.getLockedNFTInfo(address(pool), 1);
        assertEq(owner, user1);
        assertEq(votingPower, USER1_VOTING_POWER);
        assertFalse(unlocked);

        (uint256 userVotingPower, bool claimed) = pool.userInfo(user1);
        assertEq(userVotingPower, USER1_VOTING_POWER);
        assertFalse(claimed);
        
        // Pending deposit should be cleared
        (pendingOwner,,) = pool.pendingDeposits(1);
        assertEq(pendingOwner, address(0));
    }

    function test_DepositVeAERO_MultipleUsers() public {
        vm.prank(admin);
        pool.activate();

        // User1 and User2 lock using helper
        _lockVeAERO(pool, user1, 1);
        _lockVeAERO(pool, user2, 2);

        assertEq(pool.totalVotingPower(), USER1_VOTING_POWER + USER2_VOTING_POWER);
        assertEq(pool.getLockedTokenIds().length, 2);
    }

    function test_DepositVeAERO_RevertNotActive() public {
        vm.startPrank(user1);
        votingEscrow.approve(address(pool), 1);

        vm.expectRevert(KickoffVoteSalePool.InvalidState.selector);
        pool.depositVeAERO(1);
        vm.stopPrank();
    }

    function test_DepositVeAERO_RevertNotOwner() public {
        vm.prank(admin);
        pool.activate();

        vm.startPrank(user2);
        vm.expectRevert(KickoffVoteSalePool.NotNFTOwner.selector);
        pool.depositVeAERO(1); // Token 1 belongs to user1
        vm.stopPrank();
    }

    function test_DepositVeAERO_RevertAlreadyVoted() public {
        vm.prank(admin);
        pool.activate();

        // Set lastVoted to current timestamp (simulating already voted)
        voter.setLastVoted(1, block.timestamp);

        vm.startPrank(user1);
        votingEscrow.approve(address(pool), 1);

        vm.expectRevert(KickoffVoteSalePool.AlreadyVotedThisEpoch.selector);
        pool.depositVeAERO(1);
        vm.stopPrank();
    }

    function test_DepositVeAERO_RevertVotingPowerTooLow() public {
        // Create a new pool with minVotingPower requirement
        uint256 minVP = 500_000 ether; // 500k veAERO minimum
        
        MockERC20 newToken = new MockERC20("New Token", "NEW", 18);
        newToken.mint(admin, TOTAL_ALLOCATION);
        
        vm.prank(admin);
        newToken.approve(address(factory), TOTAL_ALLOCATION);
        
        // createPool called by factory owner (this test contract)
        KickoffVoteSalePool poolWithMin = KickoffVoteSalePool(
            factory.createPool(address(newToken), projectOwner, TOTAL_ALLOCATION, minVP, admin)
        );
        
        vm.prank(admin);
        poolWithMin.activate();
        
        // user1 has 100_000 ether VP which is less than 500_000 ether minimum
        vm.startPrank(user1);
        votingEscrow.approve(address(poolWithMin), 1);
        
        vm.expectRevert(KickoffVoteSalePool.VotingPowerTooLow.selector);
        poolWithMin.depositVeAERO(1);
        vm.stopPrank();
    }

    function test_DepositVeAERO_WithMinVotingPower() public {
        // Create a new pool with minVotingPower requirement that user1 meets
        uint256 minVP = 50_000 ether; // 50k veAERO minimum, user1 has 100k
        
        MockERC20 newToken = new MockERC20("New Token", "NEW", 18);
        newToken.mint(admin, TOTAL_ALLOCATION);
        
        vm.prank(admin);
        newToken.approve(address(factory), TOTAL_ALLOCATION);
        
        // createPool called by factory owner (this test contract)
        KickoffVoteSalePool poolWithMin = KickoffVoteSalePool(
            factory.createPool(address(newToken), projectOwner, TOTAL_ALLOCATION, minVP, admin)
        );
        
        vm.prank(admin);
        poolWithMin.activate();
        
        // user1 has 100_000 ether VP which is >= 50_000 ether minimum
        // Use helper for two-phase deposit
        _lockVeAERO(poolWithMin, user1, 1);
        
        assertEq(poolWithMin.totalVotingPower(), USER1_VOTING_POWER);
        assertEq(poolWithMin.minVotingPower(), minVP);
    }

    function test_ConfirmDeposit_RevertSameBlock() public {
        vm.prank(admin);
        pool.activate();

        vm.startPrank(user1);
        votingEscrow.approve(address(pool), 1);
        pool.depositVeAERO(1);
        vm.stopPrank();

        // Try to confirm in the same block - should revert
        vm.expectRevert(KickoffVoteSalePool.SameBlockDeposit.selector);
        pool.confirmDeposit(1);
    }

    function test_CancelDeposit() public {
        vm.prank(admin);
        pool.activate();

        vm.startPrank(user1);
        votingEscrow.approve(address(pool), 1);
        pool.depositVeAERO(1);
        
        // Cancel the pending deposit
        pool.cancelDeposit(1);
        vm.stopPrank();

        // NFT should be returned to user
        assertEq(votingEscrow.ownerOf(1), user1);
        
        // Pending deposit should be cleared
        (address pendingOwner,,) = pool.pendingDeposits(1);
        assertEq(pendingOwner, address(0));
    }

    function test_CancelDeposit_RevertNotOwner() public {
        vm.prank(admin);
        pool.activate();

        vm.startPrank(user1);
        votingEscrow.approve(address(pool), 1);
        pool.depositVeAERO(1);
        vm.stopPrank();

        // User2 tries to cancel user1's deposit
        vm.prank(user2);
        vm.expectRevert(KickoffVoteSalePool.NotNFTOwner.selector);
        pool.cancelDeposit(1);
    }

    /*//////////////////////////////////////////////////////////////
                        STATE TRANSITION TESTS
    //////////////////////////////////////////////////////////////*/

    function test_StateTransitionToVoting() public {
        // Setup and lock
        vm.prank(admin);
        pool.activate();

        _lockVeAERO(pool, user1, 1);

        // State should be Active
        assertEq(uint256(pool.state()), uint256(KickoffVoteSalePool.PoolState.Active));

        // Advance past lockingDeadline and trigger state transition
        uint256 lockingDeadline = pool.lockingDeadline();
        vm.warp(lockingDeadline + 1);
        
        vm.prank(admin);
        pool.triggerStateTransition();
        
        assertEq(uint256(pool.state()), uint256(KickoffVoteSalePool.PoolState.Voting));
    }

    /*//////////////////////////////////////////////////////////////
                        FINALIZE EPOCH TESTS (AUTOPILOT FLOW)
    //////////////////////////////////////////////////////////////*/

    function test_FinalizeWithAutopilot() public {
        // Setup and lock
        vm.prank(admin);
        pool.activate();

        _lockVeAERO(pool, user1, 1);

        // Advance to next epoch (rewards are claimable only after epoch ends)
        // checkStateTransition modifier will auto-transition from Active to Voting
        uint256 nextEpochStart = ((block.timestamp / 1 weeks) + 1) * 1 weeks;
        vm.warp(nextEpochStart + 2 hours); // Past special window
        
        // Update Autopilot mocks for the new epoch (so we're outside special window)
        _updateAutopilotMocksForNextEpoch();

        // Autopilot finalization flow (auto-transitions Active -> Voting)
        vm.startPrank(admin);
        pool.startClaimRewardsFromAutopilot(50);
        
        // Mint WETH after start (simulates USDC->WETH swap)
        // wethBeforeFinalization was captured, so this will count as claimed rewards
        weth.mint(address(pool), 10 ether);
        
        pool.convertUSDCtoWETH();
        pool.completeAutopilotFinalization();
        vm.stopPrank();

        assertEq(uint256(pool.state()), uint256(KickoffVoteSalePool.PoolState.Completed));
        assertTrue(pool.lpPositionId() > 0);
    }

    /*//////////////////////////////////////////////////////////////
                        UNLOCK & CLAIM TESTS
    //////////////////////////////////////////////////////////////*/

    function test_UnlockVeAERO() public {
        _setupAndFinalize();

        vm.prank(user1);
        pool.unlockVeAERO(1);

        assertEq(votingEscrow.ownerOf(1), user1);

        (, , bool unlocked,) = reader.getLockedNFTInfo(address(pool), 1);
        assertTrue(unlocked);
    }

    function test_UnlockVeAERO_RevertNotOwner() public {
        _setupAndFinalize();

        vm.prank(user2);
        vm.expectRevert(KickoffVoteSalePool.NotNFTOwner.selector);
        pool.unlockVeAERO(1);
    }

    function test_ClaimProjectTokens() public {
        _setupAndFinalize();

        uint256 expectedAmount = (TOTAL_ALLOCATION / 2) * USER1_VOTING_POWER / (USER1_VOTING_POWER + USER2_VOTING_POWER);

        vm.prank(user1);
        pool.claimProjectTokens();

        assertEq(projectToken.balanceOf(user1), expectedAmount);

        (, bool claimed) = pool.userInfo(user1);
        assertTrue(claimed);
    }

    function test_ClaimProjectTokens_RevertAlreadyClaimed() public {
        _setupAndFinalize();

        vm.prank(user1);
        pool.claimProjectTokens();

        vm.prank(user1);
        vm.expectRevert(KickoffVoteSalePool.AlreadyClaimed.selector);
        pool.claimProjectTokens();
    }

    function test_GetClaimableTokens() public {
        _setupAndFinalize();

        uint256 expectedUser1 = (TOTAL_ALLOCATION / 2) * USER1_VOTING_POWER / (USER1_VOTING_POWER + USER2_VOTING_POWER);
        uint256 expectedUser2 = (TOTAL_ALLOCATION / 2) * USER2_VOTING_POWER / (USER1_VOTING_POWER + USER2_VOTING_POWER);

        assertEq(reader.getClaimableTokens(address(pool), user1), expectedUser1);
        assertEq(reader.getClaimableTokens(address(pool), user2), expectedUser2);
    }

    /*//////////////////////////////////////////////////////////////
                       EMERGENCY WITHDRAW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_EmergencyWithdrawNFT() public {
        vm.prank(admin);
        pool.activate();

        _lockVeAERO(pool, user1, 1);

        assertEq(votingEscrow.ownerOf(1), address(pool));

        vm.prank(admin); // admin is also owner
        pool.emergencyWithdrawNFT(1);

        assertEq(votingEscrow.ownerOf(1), user1);
    }

    function test_EmergencyWithdrawBatch() public {
        vm.prank(admin);
        pool.activate();

        _lockVeAERO(pool, user1, 1);
        _lockVeAERO(pool, user2, 2);

        vm.prank(admin);
        pool.emergencyWithdrawBatch(50); // Process up to 50 NFTs

        assertEq(votingEscrow.ownerOf(1), user1);
        assertEq(votingEscrow.ownerOf(2), user2);
    }

    function test_EmergencyWithdraw_RevertNotOwner() public {
        vm.prank(admin);
        pool.activate();

        vm.prank(user1);
        vm.expectRevert(KickoffVoteSalePool.NotOwner.selector);
        pool.emergencyWithdrawNFT(1);
    }

    /*//////////////////////////////////////////////////////////////
                         RESCUE TOKENS TESTS
    //////////////////////////////////////////////////////////////*/

    function test_RescueTokens() public {
        MockERC20 stuckToken = new MockERC20("Stuck", "STUCK", 18);
        stuckToken.mint(address(pool), 100 ether);

        vm.prank(admin);
        pool.rescueTokens(address(stuckToken), admin, 100 ether);

        assertEq(stuckToken.balanceOf(admin), 100 ether);
        assertEq(stuckToken.balanceOf(address(pool)), 0);
    }

    function test_RescueTokens_RevertProjectToken() public {
        vm.prank(admin);
        vm.expectRevert(KickoffVoteSalePool.NotProjectToken.selector);
        pool.rescueTokens(address(projectToken), admin, 100 ether);
    }

    function test_RescueTokens_RevertNotAdmin() public {
        MockERC20 stuckToken = new MockERC20("Stuck", "STUCK", 18);
        stuckToken.mint(address(pool), 100 ether);

        vm.prank(user1);
        vm.expectRevert(KickoffVoteSalePool.NotAdmin.selector);
        pool.rescueTokens(address(stuckToken), user1, 100 ether);
    }

    /*//////////////////////////////////////////////////////////////
                            HELPER FUNCTIONS
    //////////////////////////////////////////////////////////////*/

    /// @notice Helper to perform two-phase veAERO deposit
    /// @dev Handles depositVeAERO + block advance + confirmDeposit
    function _lockVeAERO(KickoffVoteSalePool _pool, address user, uint256 tokenId) internal {
        vm.startPrank(user);
        votingEscrow.approve(address(_pool), tokenId);
        _pool.depositVeAERO(tokenId);
        vm.stopPrank();
        
        // Advance to next block (required because Aerodrome resets VP on same-block ownership change)
        vm.roll(block.number + 1);
        
        // Anyone can confirm the deposit in the next block
        _pool.confirmDeposit(tokenId);
    }

    function _setupAndFinalize() internal {
        // Activate
        vm.prank(admin);
        pool.activate();

        // Lock NFTs using two-phase flow
        _lockVeAERO(pool, user1, 1);
        _lockVeAERO(pool, user2, 2);

        // Advance to next epoch + past special window
        // checkStateTransition modifier will auto-transition Active -> Voting
        uint256 nextEpochStart = ((block.timestamp / 1 weeks) + 1) * 1 weeks;
        vm.warp(nextEpochStart + 2 hours);
        
        // Update Autopilot mocks for the new epoch (so we're outside special window)
        _updateAutopilotMocksForNextEpoch();

        // Autopilot finalization flow (auto-transitions state)
        vm.startPrank(admin);
        pool.startClaimRewardsFromAutopilot(50);
        
        // Mint WETH after start (simulates USDC->WETH swap rewards)
        weth.mint(address(pool), 10 ether);
        
        pool.convertUSDCtoWETH();
        pool.completeAutopilotFinalization();
        vm.stopPrank();
    }
}

