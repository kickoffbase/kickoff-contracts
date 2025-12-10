// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {KickoffFactory} from "../src/KickoffFactory.sol";
import {LPLocker} from "../src/LPLocker.sol";

/**
 * @title Deploy
 * @notice Universal deploy script for Kickoff veAERO Sale contracts
 * @dev Works on both Base Mainnet and Base Sepolia (with mainnet Aerodrome addresses)
 * 
 * Usage:
 *   Base Mainnet: forge script script/Deploy.s.sol:Deploy --rpc-url https://mainnet.base.org --broadcast --verify -vvvv
 *   Base Sepolia: forge script script/Deploy.s.sol:Deploy --rpc-url https://sepolia.base.org --broadcast --verify -vvvv
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
        console.log("  KICKOFF veAERO SALE - DEPLOYMENT");
        console.log("========================================");
        console.log("");
        console.log("Network:", network);
        console.log("Chain ID:", block.chainid);
        console.log("Deployer:", deployer);
        console.log("Balance:", deployer.balance / 1e15, "finney");
        console.log("");

        if (block.chainid == 84532) {
            console.log("WARNING: Deploying to testnet with mainnet Aerodrome addresses.");
            console.log("         Contracts will deploy but won't be functional.");
            console.log("         Use this only to test deployment & verification process.");
            console.log("");
        }

        vm.startBroadcast(deployerPrivateKey);

        // ============ Deploy KickoffFactory ============
        // LPLocker is deployed automatically in KickoffFactory constructor
        KickoffFactory factory = new KickoffFactory(
            VOTING_ESCROW,
            VOTER,
            ROUTER,
            WETH
        );

        vm.stopBroadcast();

        // ============ Output Results ============
        console.log("========================================");
        console.log("  DEPLOYMENT SUCCESSFUL!");
        console.log("========================================");
        console.log("");
        console.log("Deployed Contracts:");
        console.log("  KickoffFactory:", address(factory));
        console.log("  LPLocker:", address(factory.lpLocker()));
        console.log("");
        console.log("Configuration (Aerodrome):");
        console.log("  VotingEscrow:", VOTING_ESCROW);
        console.log("  Voter:", VOTER);
        console.log("  Router:", ROUTER);
        console.log("  WETH:", WETH);
        console.log("");
        console.log("========================================");
        console.log("  NEXT STEPS");
        console.log("========================================");
        console.log("");
        console.log("1. Verify contracts are verified on Basescan");
        console.log("2. Save deployed addresses");
        console.log("3. Create Vote-Sale pools via factory.createPool()");
        console.log("");

        // Output for easy copy-paste
        console.log("========================================");
        console.log("  SAVE TO .env");
        console.log("========================================");
        console.log("");
        console.log("KICKOFF_FACTORY=", address(factory));
        console.log("LP_LOCKER=", address(factory.lpLocker()));
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

        KickoffFactory factory = new KickoffFactory{salt: salt}(
            VOTING_ESCROW,
            VOTER,
            ROUTER,
            WETH
        );

        vm.stopBroadcast();

        console.log("KickoffFactory:", address(factory));
        console.log("LPLocker:", address(factory.lpLocker()));
    }
}
