// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Test.sol";
import {KickoffFactory} from "../src/KickoffFactory.sol";
import {KickoffVoteSalePool} from "../src/KickoffVoteSalePool.sol";
import {LPLocker} from "../src/LPLocker.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {MockVotingEscrow} from "./mocks/MockVotingEscrow.sol";
import {MockVoter} from "./mocks/MockVoter.sol";
import {MockRouter} from "./mocks/MockRouter.sol";

contract KickoffVoteSalePoolTest is Test {
    KickoffFactory public factory;
    KickoffVoteSalePool public pool;
    LPLocker public lpLocker;

    MockERC20 public projectToken;
    MockERC20 public weth;
    MockVotingEscrow public votingEscrow;
    MockVoter public voter;
    MockRouter public router;

    address public admin = address(0x1);
    address public projectOwner = address(0x2);
    address public user1 = address(0x3);
    address public user2 = address(0x4);

    address public mockGauge = address(0x100);
    address public mockPool = address(0x101);
    address public mockInternalBribe = address(0x102);
    address public mockExternalBribe = address(0x103);

    uint256 public constant TOTAL_ALLOCATION = 1_000_000 ether;
    uint256 public constant USER1_VOTING_POWER = 100_000 ether;
    uint256 public constant USER2_VOTING_POWER = 50_000 ether;

    function setUp() public {
        // Set realistic timestamp (current epoch > 0)
        vm.warp(1700000000); // Nov 2023

        // Deploy mock contracts
        weth = new MockERC20("Wrapped ETH", "WETH", 18);
        votingEscrow = new MockVotingEscrow();
        voter = new MockVoter(address(votingEscrow));
        router = new MockRouter(address(weth));
        projectToken = new MockERC20("Project Token", "PROJECT", 18);

        // Setup voter mock
        voter.setGauge(mockPool, mockGauge);
        voter.setBribes(mockGauge, mockInternalBribe, mockExternalBribe);

        // Deploy factory
        factory = new KickoffFactory(
            address(votingEscrow),
            address(voter),
            address(router),
            address(weth)
        );

        lpLocker = factory.lpLocker();

        // Mint tokens to admin
        projectToken.mint(admin, TOTAL_ALLOCATION);

        // Create pool
        vm.startPrank(admin);
        projectToken.approve(address(factory), TOTAL_ALLOCATION);
        address poolAddr = factory.createPool(address(projectToken), projectOwner, TOTAL_ALLOCATION, 0);
        pool = KickoffVoteSalePool(poolAddr);
        vm.stopPrank();

        // Mint veAERO NFTs to users
        votingEscrow.mint(user1, USER1_VOTING_POWER, block.timestamp + 365 days);
        votingEscrow.mint(user2, USER2_VOTING_POWER, block.timestamp + 365 days);
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

    function test_LockVeAERO() public {
        // Activate pool
        vm.prank(admin);
        pool.activate();

        // User1 locks their veAERO
        vm.startPrank(user1);
        votingEscrow.approve(address(pool), 1);
        pool.lockVeAERO(1);
        vm.stopPrank();

        // Verify lock
        assertEq(pool.totalVotingPower(), USER1_VOTING_POWER);
        assertEq(votingEscrow.ownerOf(1), address(pool));

        (address owner, uint256 votingPower, bool unlocked) = pool.getLockedNFTInfo(1);
        assertEq(owner, user1);
        assertEq(votingPower, USER1_VOTING_POWER);
        assertFalse(unlocked);

        (uint256 userVotingPower, bool claimed) = pool.userInfo(user1);
        assertEq(userVotingPower, USER1_VOTING_POWER);
        assertFalse(claimed);
    }

    function test_LockVeAERO_MultipleUsers() public {
        vm.prank(admin);
        pool.activate();

        // User1 locks
        vm.startPrank(user1);
        votingEscrow.approve(address(pool), 1);
        pool.lockVeAERO(1);
        vm.stopPrank();

        // User2 locks
        vm.startPrank(user2);
        votingEscrow.approve(address(pool), 2);
        pool.lockVeAERO(2);
        vm.stopPrank();

        assertEq(pool.totalVotingPower(), USER1_VOTING_POWER + USER2_VOTING_POWER);
        assertEq(pool.getLockedNFTCount(), 2);
    }

    function test_LockVeAERO_RevertNotActive() public {
        vm.startPrank(user1);
        votingEscrow.approve(address(pool), 1);

        vm.expectRevert(KickoffVoteSalePool.InvalidState.selector);
        pool.lockVeAERO(1);
        vm.stopPrank();
    }

    function test_LockVeAERO_RevertNotOwner() public {
        vm.prank(admin);
        pool.activate();

        vm.startPrank(user2);
        vm.expectRevert(KickoffVoteSalePool.NotNFTOwner.selector);
        pool.lockVeAERO(1); // Token 1 belongs to user1
        vm.stopPrank();
    }

    function test_LockVeAERO_RevertAlreadyVoted() public {
        vm.prank(admin);
        pool.activate();

        // Set lastVoted to current timestamp (simulating already voted)
        voter.setLastVoted(1, block.timestamp);

        vm.startPrank(user1);
        votingEscrow.approve(address(pool), 1);

        vm.expectRevert(KickoffVoteSalePool.AlreadyVotedThisEpoch.selector);
        pool.lockVeAERO(1);
        vm.stopPrank();
    }

    function test_LockVeAERO_RevertVotingPowerTooLow() public {
        // Create a new pool with minVotingPower requirement
        uint256 minVP = 500_000 ether; // 500k veAERO minimum
        
        vm.startPrank(admin);
        MockERC20 newToken = new MockERC20("New Token", "NEW", 18);
        newToken.mint(admin, TOTAL_ALLOCATION);
        newToken.approve(address(factory), TOTAL_ALLOCATION);
        
        KickoffVoteSalePool poolWithMin = KickoffVoteSalePool(
            factory.createPool(address(newToken), projectOwner, TOTAL_ALLOCATION, minVP)
        );
        poolWithMin.activate();
        vm.stopPrank();
        
        // user1 has 100_000 ether VP which is less than 500_000 ether minimum
        vm.startPrank(user1);
        votingEscrow.approve(address(poolWithMin), 1);
        
        vm.expectRevert(KickoffVoteSalePool.VotingPowerTooLow.selector);
        poolWithMin.lockVeAERO(1);
        vm.stopPrank();
    }

    function test_LockVeAERO_WithMinVotingPower() public {
        // Create a new pool with minVotingPower requirement that user1 meets
        uint256 minVP = 50_000 ether; // 50k veAERO minimum, user1 has 100k
        
        vm.startPrank(admin);
        MockERC20 newToken = new MockERC20("New Token", "NEW", 18);
        newToken.mint(admin, TOTAL_ALLOCATION);
        newToken.approve(address(factory), TOTAL_ALLOCATION);
        
        KickoffVoteSalePool poolWithMin = KickoffVoteSalePool(
            factory.createPool(address(newToken), projectOwner, TOTAL_ALLOCATION, minVP)
        );
        poolWithMin.activate();
        vm.stopPrank();
        
        // user1 has 100_000 ether VP which is >= 50_000 ether minimum
        vm.startPrank(user1);
        votingEscrow.approve(address(poolWithMin), 1);
        poolWithMin.lockVeAERO(1); // Should succeed
        vm.stopPrank();
        
        assertEq(poolWithMin.totalVotingPower(), USER1_VOTING_POWER);
        assertEq(poolWithMin.minVotingPower(), minVP);
    }

    /*//////////////////////////////////////////////////////////////
                           CAST VOTES TESTS
    //////////////////////////////////////////////////////////////*/

    function test_CastVotes() public {
        // Setup
        vm.prank(admin);
        pool.activate();

        vm.startPrank(user1);
        votingEscrow.approve(address(pool), 1);
        pool.lockVeAERO(1);
        vm.stopPrank();

        // Cast votes
        vm.prank(admin);
        pool.castVotes(mockGauge);

        assertEq(pool.gauge(), mockGauge);
        assertEq(pool.aerodromePool(), mockPool);
        assertEq(uint256(pool.state()), uint256(KickoffVoteSalePool.PoolState.Voting));
    }

    function test_CastVotes_RevertNotAdmin() public {
        vm.prank(admin);
        pool.activate();

        vm.prank(user1);
        vm.expectRevert(KickoffVoteSalePool.NotAdmin.selector);
        pool.castVotes(mockGauge);
    }

    function test_CastVotes_RevertZeroAddress() public {
        vm.prank(admin);
        pool.activate();

        vm.prank(admin);
        vm.expectRevert(KickoffVoteSalePool.ZeroAddress.selector);
        pool.castVotes(address(0));
    }

    /*//////////////////////////////////////////////////////////////
                        FINALIZE EPOCH TESTS
    //////////////////////////////////////////////////////////////*/

    function test_FinalizeEpoch() public {
        // Setup and lock
        vm.prank(admin);
        pool.activate();

        vm.startPrank(user1);
        votingEscrow.approve(address(pool), 1);
        pool.lockVeAERO(1);
        vm.stopPrank();

        // Cast votes
        vm.prank(admin);
        pool.castVotes(mockGauge);

        // Mint some WETH to simulate bribe rewards
        weth.mint(address(pool), 10 ether);

        // Advance to next epoch (rewards are claimable only after epoch ends)
        uint256 nextEpochStart = ((block.timestamp / 1 weeks) + 1) * 1 weeks;
        vm.warp(nextEpochStart + 1 hours);

        // Finalize (auto token discovery)
        vm.prank(admin);
        pool.finalizeEpoch();

        assertEq(uint256(pool.state()), uint256(KickoffVoteSalePool.PoolState.Completed));
        assertTrue(pool.lpCreated() > 0);
    }

    /*//////////////////////////////////////////////////////////////
                        UNLOCK & CLAIM TESTS
    //////////////////////////////////////////////////////////////*/

    function test_UnlockVeAERO() public {
        _setupAndFinalize();

        vm.prank(user1);
        pool.unlockVeAERO(1);

        assertEq(votingEscrow.ownerOf(1), user1);

        (, , bool unlocked) = pool.getLockedNFTInfo(1);
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

        assertEq(pool.getClaimableTokens(user1), expectedUser1);
        assertEq(pool.getClaimableTokens(user2), expectedUser2);
    }

    /*//////////////////////////////////////////////////////////////
                       EMERGENCY WITHDRAW TESTS
    //////////////////////////////////////////////////////////////*/

    function test_EmergencyWithdrawNFT() public {
        vm.prank(admin);
        pool.activate();

        vm.startPrank(user1);
        votingEscrow.approve(address(pool), 1);
        pool.lockVeAERO(1);
        vm.stopPrank();

        assertEq(votingEscrow.ownerOf(1), address(pool));

        vm.prank(admin); // admin is also owner
        pool.emergencyWithdrawNFT(1);

        assertEq(votingEscrow.ownerOf(1), user1);
    }

    function test_EmergencyWithdrawAllNFTs() public {
        vm.prank(admin);
        pool.activate();

        vm.startPrank(user1);
        votingEscrow.approve(address(pool), 1);
        pool.lockVeAERO(1);
        vm.stopPrank();

        vm.startPrank(user2);
        votingEscrow.approve(address(pool), 2);
        pool.lockVeAERO(2);
        vm.stopPrank();

        vm.prank(admin);
        pool.emergencyWithdrawAllNFTs();

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

    function _setupAndFinalize() internal {
        // Activate
        vm.prank(admin);
        pool.activate();

        // Lock NFTs
        vm.startPrank(user1);
        votingEscrow.approve(address(pool), 1);
        pool.lockVeAERO(1);
        vm.stopPrank();

        vm.startPrank(user2);
        votingEscrow.approve(address(pool), 2);
        pool.lockVeAERO(2);
        vm.stopPrank();

        // Cast votes
        vm.prank(admin);
        pool.castVotes(mockGauge);

        // Simulate bribes
        weth.mint(address(pool), 10 ether);

        // Advance to next epoch (rewards are claimable only after epoch ends)
        uint256 nextEpochStart = ((block.timestamp / 1 weeks) + 1) * 1 weeks;
        vm.warp(nextEpochStart + 1 hours);

        // Finalize (auto token discovery)
        vm.prank(admin);
        pool.finalizeEpoch();
    }
}

