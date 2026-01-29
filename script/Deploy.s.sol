// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "forge-std/Script.sol";
import {KickoffFactory} from "../src/KickoffFactory.sol";
import {KickoffVoteSalePool} from "../src/KickoffVoteSalePool.sol";
import {KickoffPoolReader} from "../src/KickoffPoolReader.sol";
import {LPLocker} from "../src/LPLocker.sol";
import {TokenVesting} from "../src/TokenVesting.sol";
import {ProjectTokenFactory} from "../src/ProjectTokenFactory.sol";

/**
 * @title Deploy
 * @notice Universal deploy script for all Kickoff protocol contracts
 * @dev Works on both Base Mainnet and Base Sepolia. Includes automatic verification.
 * 
 * Deploys:
 *   - KickoffFactory (Vote-Sale pools factory)
 *   - LPLocker (auto-deployed by KickoffFactory)
 *   - KickoffPoolReader (view functions for Vote-Sale pools)
 *   - TokenVesting (vesting schedules)
 *   - ProjectTokenFactory (token creation with tokenomics)
 * 
 * Usage with auto-verification:
 *   Base Mainnet:
 *     forge script script/Deploy.s.sol:Deploy \
 *       --rpc-url https://mainnet.base.org \
 *       --broadcast \
 *       --verify \
 *       --etherscan-api-key $BASESCAN_API_KEY \
 *       -vvvv
 * 
 *   Base Sepolia:
 *     forge script script/Deploy.s.sol:Deploy \
 *       --rpc-url https://sepolia.base.org \
 *       --broadcast \
 *       --verify \
 *       --etherscan-api-key $BASESCAN_API_KEY \
 *       -vvvv
 * 
 * Required env vars:
 *   PRIVATE_KEY - deployer private key (with 0x prefix)
 *   BASESCAN_API_KEY - for contract verification on Basescan
 */
contract Deploy is Script {
    // ============ Aerodrome Contracts on Base ============
    // Same addresses on Mainnet and Sepolia (Sepolia won't be functional but can verify deployment)
    
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
            console.log("NOTE: Deploying to testnet with mainnet Aerodrome addresses.");
            console.log("      VoteSale contracts will deploy but won't be functional.");
            console.log("      TokenFactory & Vesting will work normally.");
            console.log("");
        }

        vm.startBroadcast(deployerPrivateKey);

        // ============ Part 1: Vote-Sale Infrastructure ============
        console.log("--- Deploying Vote-Sale Infrastructure ---");
        
        // 1.1 KickoffFactory (deploys LPLocker in constructor)
        KickoffFactory kickoffFactory = new KickoffFactory(
            VOTING_ESCROW,
            VOTER,
            ROUTER,
            WETH
        );
        console.log("KickoffFactory deployed:", address(kickoffFactory));
        console.log("LPLocker deployed:", address(kickoffFactory.lpLocker()));
        
        // 1.2 KickoffPoolReader (view functions for pools)
        KickoffPoolReader poolReader = new KickoffPoolReader();
        console.log("KickoffPoolReader deployed:", address(poolReader));

        // ============ Part 2: Token Factory Infrastructure ============
        console.log("");
        console.log("--- Deploying Token Factory Infrastructure ---");
        
        // 2.1 TokenVesting
        TokenVesting vesting = new TokenVesting();
        console.log("TokenVesting deployed:", address(vesting));

        // 2.2 ProjectTokenFactory
        ProjectTokenFactory tokenFactory = new ProjectTokenFactory(address(vesting));
        console.log("ProjectTokenFactory deployed:", address(tokenFactory));

        // 2.3 Link factory to vesting
        vesting.setFactory(address(tokenFactory));
        console.log("Factory linked to TokenVesting");

        vm.stopBroadcast();

        // ============ Output Results ============
        _printDeploymentSummary(kickoffFactory, poolReader, vesting, tokenFactory, deployer);
    }

    function _printDeploymentSummary(
        KickoffFactory kickoffFactory,
        KickoffPoolReader poolReader,
        TokenVesting vesting,
        ProjectTokenFactory tokenFactory,
        address deployer
    ) internal view {
        console.log("");
        console.log("========================================");
        console.log("  DEPLOYMENT SUCCESSFUL!");
        console.log("========================================");
        console.log("");
        console.log("Vote-Sale Contracts:");
        console.log("  KickoffFactory:", address(kickoffFactory));
        console.log("  LPLocker:", address(kickoffFactory.lpLocker()));
        console.log("  KickoffPoolReader:", address(poolReader));
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
        console.log("  VERIFICATION");
        console.log("========================================");
        console.log("");
        console.log("If --verify flag was used, contracts are being verified automatically.");
        console.log("Otherwise, verify manually with:");
        console.log("");
        console.log("forge verify-contract <ADDRESS> <CONTRACT> --chain-id <CHAIN_ID> --etherscan-api-key $BASESCAN_API_KEY");
        console.log("");

        console.log("========================================");
        console.log("  NEXT STEPS");
        console.log("========================================");
        console.log("");
        console.log("1. Save deployed addresses to .env");
        console.log("2. Create project tokens via tokenFactory.createToken()");
        console.log("3. Start vesting via vesting.startVesting(token)");
        console.log("4. Create Vote-Sale pools via kickoffFactory.createPool()");
        console.log("");

        // Output for easy copy-paste
        console.log("========================================");
        console.log("  SAVE TO .env");
        console.log("========================================");
        console.log("");
        console.log("# Vote-Sale");
        console.log("KICKOFF_FACTORY=", address(kickoffFactory));
        console.log("LP_LOCKER=", address(kickoffFactory.lpLocker()));
        console.log("POOL_READER=", address(poolReader));
        console.log("");
        console.log("# Token Factory");
        console.log("TOKEN_VESTING=", address(vesting));
        console.log("PROJECT_TOKEN_FACTORY=", address(tokenFactory));
    }
}

/**
 * @title DeployVoteSaleOnly
 * @notice Deploy only Vote-Sale infrastructure (KickoffFactory + LPLocker + Reader)
 * 
 * Usage:
 *   forge script script/Deploy.s.sol:DeployVoteSaleOnly \
 *     --rpc-url https://mainnet.base.org \
 *     --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY -vvvv
 */
contract DeployVoteSaleOnly is Script {
    address constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
    address constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;
    address constant ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("");
        console.log("========================================");
        console.log("  VOTE-SALE ONLY DEPLOYMENT");
        console.log("========================================");
        console.log("");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        // Deploy Factory (includes LPLocker)
        KickoffFactory factory = new KickoffFactory(
            VOTING_ESCROW,
            VOTER,
            ROUTER,
            WETH
        );
        
        // Deploy Reader
        KickoffPoolReader reader = new KickoffPoolReader();

        vm.stopBroadcast();

        console.log("");
        console.log("KickoffFactory:", address(factory));
        console.log("LPLocker:", address(factory.lpLocker()));
        console.log("KickoffPoolReader:", address(reader));
    }
}

/**
 * @title DeployLPLockerOnly
 * @notice Deploy only LPLocker (for manual pool creation)
 * @dev IMPORTANT: After deployment, setFactory() MUST be called to enable lockLP().
 *      Only pools registered in the factory via isPool() can call lockLP().
 * 
 * Usage:
 *   forge script script/Deploy.s.sol:DeployLPLockerOnly \
 *     --rpc-url https://mainnet.base.org \
 *     --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY -vvvv
 */
contract DeployLPLockerOnly is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying LPLocker...");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        LPLocker locker = new LPLocker();

        vm.stopBroadcast();

        console.log("");
        console.log("LPLocker:", address(locker));
        console.log("");
        console.log("IMPORTANT: Call setFactory(factoryAddress) to enable lockLP()");
        console.log("Only pools registered via factory.isPool() can lock LP tokens.");
    }
}

/**
 * @title DeployPoolReader
 * @notice Deploy KickoffPoolReader for view functions
 * 
 * Usage:
 *   forge script script/Deploy.s.sol:DeployPoolReader \
 *     --rpc-url https://mainnet.base.org \
 *     --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY -vvvv
 */
contract DeployPoolReader is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("Deploying KickoffPoolReader...");
        console.log("Deployer:", deployer);

        vm.startBroadcast(deployerPrivateKey);

        KickoffPoolReader reader = new KickoffPoolReader();

        vm.stopBroadcast();

        console.log("");
        console.log("KickoffPoolReader:", address(reader));
    }
}

/**
 * @title DeployVoteSaleDirect
 * @notice DEPRECATED: Use DeployVoteSaleOnly instead
 * @dev This script is deprecated because LPLocker now requires factory linkage for security.
 *      Without a factory, lockLP() will revert with NotVoteSalePool.
 *      Use DeployVoteSaleOnly which deploys KickoffFactory (includes LPLocker).
 */
contract DeployVoteSaleDirect is Script {
    function run() external pure {
        revert("DEPRECATED: Use DeployVoteSaleOnly instead. LPLocker requires factory linkage.");
    }
}

/**
 * @title DeployTokenFactoryOnly
 * @notice Deploy only Token Factory infrastructure (TokenVesting + ProjectTokenFactory)
 * 
 * Usage:
 *   forge script script/Deploy.s.sol:DeployTokenFactoryOnly \
 *     --rpc-url https://mainnet.base.org \
 *     --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY -vvvv
 */
contract DeployTokenFactoryOnly is Script {
    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        address deployer = vm.addr(deployerPrivateKey);

        console.log("");
        console.log("========================================");
        console.log("  TOKEN FACTORY ONLY DEPLOYMENT");
        console.log("========================================");
        console.log("");
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
 * 
 * Usage:
 *   DEPLOY_SALT=0x... forge script script/Deploy.s.sol:DeployWithSalt \
 *     --rpc-url https://mainnet.base.org \
 *     --broadcast --verify --etherscan-api-key $BASESCAN_API_KEY -vvvv
 */
contract DeployWithSalt is Script {
    address constant VOTING_ESCROW = 0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4;
    address constant VOTER = 0x16613524e02ad97eDfeF371bC883F2F5d6C480A5;
    address constant ROUTER = 0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43;
    address constant WETH = 0x4200000000000000000000000000000000000006;

    function run() external {
        uint256 deployerPrivateKey = vm.envUint("PRIVATE_KEY");
        bytes32 salt = vm.envOr("DEPLOY_SALT", bytes32(0));

        console.log("");
        console.log("========================================");
        console.log("  CREATE2 DEPLOYMENT (DETERMINISTIC)");
        console.log("========================================");
        console.log("");
        console.log("Salt:", vm.toString(salt));

        vm.startBroadcast(deployerPrivateKey);

        // Vote-Sale Infrastructure
        KickoffFactory kickoffFactory = new KickoffFactory{salt: salt}(
            VOTING_ESCROW,
            VOTER,
            ROUTER,
            WETH
        );
        KickoffPoolReader reader = new KickoffPoolReader{salt: salt}();

        // Token Factory Infrastructure
        TokenVesting vesting = new TokenVesting{salt: salt}();
        ProjectTokenFactory tokenFactory = new ProjectTokenFactory{salt: salt}(address(vesting));
        vesting.setFactory(address(tokenFactory));

        vm.stopBroadcast();

        console.log("");
        console.log("KickoffFactory:", address(kickoffFactory));
        console.log("LPLocker:", address(kickoffFactory.lpLocker()));
        console.log("KickoffPoolReader:", address(reader));
        console.log("TokenVesting:", address(vesting));
        console.log("ProjectTokenFactory:", address(tokenFactory));
    }
}
