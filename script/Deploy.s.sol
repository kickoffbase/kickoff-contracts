// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {KickoffFactory} from "../src/KickoffFactory.sol";
import {LPLocker} from "../src/LPLocker.sol";
import {TokenVesting} from "../src/TokenVesting.sol";
import {ProjectTokenFactory} from "../src/ProjectTokenFactory.sol";

/**
 * @title Deploy
 * @notice Universal deploy script for all Kickoff protocol contracts
 * @dev Works on both Base Mainnet and Base Sepolia
 * 
 * Deploys:
 *   - KickoffFactory (Vote-Sale pools)
 *   - LPLocker (auto-deployed by KickoffFactory)
 *   - TokenVesting (vesting schedules)
 *   - ProjectTokenFactory (token creation with tokenomics)
 * 
 * Usage:
 *   Base Mainnet: forge script script/Deploy.s.sol:Deploy --rpc-url https://mainnet.base.org --broadcast --verify -vvvv
 *   Base Sepolia: forge script script/Deploy.s.sol:Deploy --rpc-url https://sepolia.base.org --broadcast --verify -vvvv
 * 
 * Required env vars:
 *   PRIVATE_KEY - deployer private key (with 0x prefix)
 *   BASESCAN_API_KEY - for contract verification
 */
contract Deploy is Script {
    // ============ Aerodrome Contracts on Base Mainnet ============
    // These addresses are the same for testnet deployment testing
    // (contracts won't be functional on testnet, but deployment/verification can be tested)
    
    address constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
    address constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;
    address constant ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        // Determine network
        string memory network = block.chainid == 8453 ? "Base Mainnet" : 
                                block.chainid == 84532 ? "Base Sepolia" : "Unknown";

        console.log("");
        console.log("========================================");
        console.log("  KICKOFF PROTOCOL - FULL DEPLOYMENT");
        console.log("========================================");
        console.log("");
        console.log("Network:", network);
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance / 1e15, "finney");
        console.log("");

        if (block.chainid == 84532) {
            console.log("WARNING: Deploying to testnet with mainnet Aerodrome addresses.");
            console.log("         VoteSale contracts will deploy but won't be functional.");
            console.log("         TokenFactory & Vesting will work normally.");
            console.log("");
        }

        vm.startBroadcast(deployerPrivateKey);

        // ============ Part 1: Vote-Sale Infrastructure ============
        console.log("--- Deploying Vote-Sale Infrastructure ---");
        
        // LPLocker is deployed automatically in KickoffFactory constructor
        KickoffFactory kickoffFactory = new KickoffFactory(
            VOTING_ESCROW,
            VOTER,
            ROUTER,
            WETH
        );
        console.log("KickoffFactory deployed:", address(kickoffFactory));
        console.log("LPLocker deployed:", address(kickoffFactory.lpLocker()));

        // ============ Part 2: Token Factory Infrastructure ============
        console.log("");
        console.log("--- Deploying Token Factory Infrastructure ---");
        
        // Deploy TokenVesting
        TokenVesting vesting = new TokenVesting();
        console.log("TokenVesting deployed:", address(vesting));

        // Deploy ProjectTokenFactory
        ProjectTokenFactory tokenFactory = new ProjectTokenFactory(address(vesting));
        console.log("ProjectTokenFactory deployed:", address(tokenFactory));

        // Set factory in vesting contract
        vesting.setFactory(address(tokenFactory));
        console.log("Factory set in TokenVesting");

        vm.stopBroadcast();

        // ============ Output Results ============
        console.log("");
        console.log("========================================");
        console.log("  DEPLOYMENT SUCCESSFUL!");
        console.log("========================================");
        console.log("");
        console.log("Vote-Sale Contracts:");
        console.log("  KickoffFactory:", address(kickoffFactory));
        console.log("  LPLocker:", address(kickoffFactory.lpLocker()));
        console.log("");
        console.log("Token Factory Contracts:");
        console.log("  TokenVesting:", address(vesting));
        console.log("  ProjectTokenFactory:", address(tokenFactory));
        console.log("");
        console.log("Configuration (Aerodrome):");
        console.log("  VotingEscrow:", VOTING_ESCROW);
        console.log("  Voter:", VOTER);
        console.log("  Router:", ROUTER);
        console.log("  WETH:", WETH);
        console.log("");
        console.log("Owner:", deployer);
        console.log("");
        
        console.log("========================================");
        console.log("  NEXT STEPS");
        console.log("========================================");
        console.log("");
        console.log("1. Verify all contracts on Basescan");
        console.log("2. Save deployed addresses");
        console.log("3. Create tokens via tokenFactory.createToken()");
        console.log("4. Start vesting via vesting.startVesting(token)");
        console.log("5. Create Vote-Sale pools via kickoffFactory.createPool()");
        console.log("");

        // Output for easy copy-paste
        console.log("========================================");
        console.log("  SAVE TO .env");
        console.log("========================================");
        console.log("");
        console.log("# Vote-Sale");
        console.log("KICKOFF_FACTORY=", address(kickoffFactory));
        console.log("LP_LOCKER=", address(kickoffFactory.lpLocker()));
        console.log("");
        console.log("# Token Factory");
        console.log("TOKEN_VESTING=", address(vesting));
        console.log("PROJECT_TOKEN_FACTORY=", address(tokenFactory));
    }
}

/**
 * @title DeployVoteSaleOnly
 * @notice Deploy only Vote-Sale infrastructure (KickoffFactory + LPLocker)
 */
contract DeployVoteSaleOnly is Script {
    address constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
    address constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;
    address constant ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying Vote-Sale Infrastructure...");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        KickoffFactory factory = new KickoffFactory(
            VOTING_ESCROW,
            VOTER,
            ROUTER,
            WETH
        );

        vm.stopBroadcast();

        console.log("");
        console.log("KickoffFactory:", address(factory));
        console.log("LPLocker:", address(factory.lpLocker()));
    }
}

/**
 * @title DeployTokenFactoryOnly
 * @notice Deploy only Token Factory infrastructure (TokenVesting + ProjectTokenFactory)
 */
contract DeployTokenFactoryOnly is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying Token Factory Infrastructure...");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        TokenVesting vesting = new TokenVesting();
        ProjectTokenFactory factory = new ProjectTokenFactory(address(vesting));
        vesting.setFactory(address(factory));

        vm.stopBroadcast();

        console.log("");
        console.log("TokenVesting:", address(vesting));
        console.log("ProjectTokenFactory:", address(factory));
    }
}

/**
 * @title DeployWithSalt
 * @notice Deploy with CREATE2 for deterministic addresses
 * @dev Use when you need predictable contract addresses
 */
contract DeployWithSalt is Script {
    address constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
    address constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;
    address constant ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        bytes32 salt = vm.envOr("DEPLOY_SALT", bytes32(0));

        console.log("Deploying with CREATE2...");
        console.log("Salt:", vm.toString(salt));

        vm.startBroadcast(deployerPrivateKey);

        // Vote-Sale
        KickoffFactory kickoffFactory = new KickoffFactory{salt: salt}(
            VOTING_ESCROW,
            VOTER,
            ROUTER,
            WETH
        );

        // Token Factory
        TokenVesting vesting = new TokenVesting{salt: salt}();
        ProjectTokenFactory tokenFactory = new ProjectTokenFactory{salt: salt}(address(vesting));
        vesting.setFactory(address(tokenFactory));

        vm.stopBroadcast();

        console.log("");
        console.log("KickoffFactory:", address(kickoffFactory));
        console.log("LPLocker:", address(kickoffFactory.lpLocker()));
        console.log("TokenVesting:", address(vesting));
        console.log("ProjectTokenFactory:", address(tokenFactory));
    }
}
