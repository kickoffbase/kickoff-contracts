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

/// @title FullFlowTest
/// @notice Integration test for the full Vote-Sale flow on Base mainnet fork
/// @dev Run with: forge test --fork-url $BASE_RPC_URL -vvv
contract FullFlowTest is Test {
    // Aerodrome contracts on Base mainnet
    address constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
    address constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;
    address constant ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant AERO = 0x940181a94A35A4569E4529A3CDfB74e38FD98631;

    // We'll use a real veAERO holder for testing
    // This address will be impersonated
    address constant VEAERO_WHALE = 0x1234567890123456789012345678901234567890; // Replace with actual whale

    KickoffFactory public factory;
    KickoffVoteSalePool public pool;
    LPLocker public lpLocker;

    address public admin;
    address public projectOwner;
    address public projectToken;

    uint256 public constant TOTAL_ALLOCATION = 1_000_000 ether;

    function setUp() public {
        // Skip if not on fork
        if (block.chainid != 8453) {
            return;
        }

        admin = makeAddr("admin");
        projectOwner = makeAddr("projectOwner");

        // Deploy a mock project token
        projectToken = address(new MockProjectToken());
        MockProjectToken(projectToken).mint(admin, TOTAL_ALLOCATION);

        // Deploy factory
        vm.prank(admin);
        factory = new KickoffFactory(VOTING_ESCROW, VOTER, ROUTER, WETH);
        lpLocker = factory.lpLocker();

        // Create pool
        vm.startPrank(admin);
        IERC20(projectToken).approve(address(factory), TOTAL_ALLOCATION);
        address poolAddr = factory.createPool(projectToken, projectOwner, TOTAL_ALLOCATION);
        pool = KickoffVoteSalePool(poolAddr);
        vm.stopPrank();
    }

    /// @notice Test factory deployment on fork
    function test_Fork_FactoryDeployment() public {
        if (block.chainid != 8453) {
            vm.skip(true);
        }

        assertEq(factory.votingEscrow(), VOTING_ESCROW);
        assertEq(factory.voter(), VOTER);
        assertEq(factory.router(), ROUTER);
        assertEq(factory.weth(), WETH);
    }

    /// @notice Test pool creation on fork
    function test_Fork_PoolCreation() public {
        if (block.chainid != 8453) {
            vm.skip(true);
        }

        assertEq(pool.admin(), admin);
        assertEq(pool.projectOwner(), projectOwner);
        assertEq(pool.projectToken(), projectToken);
        assertEq(pool.totalAllocation(), TOTAL_ALLOCATION);
        assertEq(IERC20(projectToken).balanceOf(address(pool)), TOTAL_ALLOCATION);
    }

    /// @notice Test pool activation on fork
    function test_Fork_PoolActivation() public {
        if (block.chainid != 8453) {
            vm.skip(true);
        }

        vm.prank(admin);
        pool.activate();

        assertEq(uint256(pool.state()), uint256(KickoffVoteSalePool.PoolState.Active));
    }

    /// @notice Test LPLocker constants
    function test_Fork_LPLockerConstants() public view {
        if (block.chainid != 8453) {
            return;
        }

        assertEq(lpLocker.ADMIN_FEE_BPS(), 3000); // 30%
        assertEq(lpLocker.PROJECT_OWNER_FEE_BPS(), 7000); // 70%
        assertEq(lpLocker.BPS_DENOMINATOR(), 10000);
    }

    /// @notice Verify Aerodrome contract interfaces
    function test_Fork_AerodromeInterfaces() public view {
        if (block.chainid != 8453) {
            return;
        }

        // Verify VotingEscrow
        IVotingEscrow ve = IVotingEscrow(VOTING_ESCROW);
        assertTrue(ve.totalSupply() > 0);

        // Verify Voter
        IVoter voter = IVoter(VOTER);
        assertEq(voter.ve(), VOTING_ESCROW);

        // Verify Router
        IRouter router = IRouter(ROUTER);
        assertEq(router.weth(), WETH);
    }
}

/// @notice Mock project token for fork testing
contract MockProjectToken {
    string public name = "Mock Project Token";
    string public symbol = "MOCK";
    uint8 public decimals = 18;

    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

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

