# Kickoff Protocol Contracts

Smart contracts for **Kickoff** - a liquidity bootstrapping launchpad that leverages Aerodrome's veAERO governance on Base.

## Overview

Kickoff enables projects to bootstrap liquidity by leveraging veAERO voting power:

1. **Projects** create tokens with customizable tokenomics via Token Factory
2. **Projects** deposit tokens and create a Vote-Sale Pool
3. **veAERO holders** lock their NFTs to provide voting power
4. **Autopilot** handles voting for optimal vAPR and converts rewards to USDC
5. **USDC rewards** are converted to WETH and paired with project tokens
6. **Slipstream CL Position** (1% fee tier, full-range) is permanently locked, generating trading fees forever
7. **Participants** claim project tokens proportional to their voting power contribution

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    ProjectTokenFactory                          │
│  - Creates ERC20 project tokens                                 │
│  - Configures tokenomics (TGE + vesting)                        │
│  - Distributes tokens to recipients & vesting                   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                       TokenVesting                              │
│  - Manages vesting schedules                                    │
│  - Supports cliff + linear vesting                              │
│  - Beneficiaries claim vested tokens                            │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                        KickoffFactory                           │
│  - Creates Vote-Sale Pools (via VoteSalePoolDeployer)           │
│  - Manages global configuration                                 │
└─────────────────────────────────────────────────────────────────┘
           │                                    │
           ▼                                    ▼
┌───────────────────────────┐    ┌─────────────────────────────────┐
│  VoteSalePoolDeployer     │    │     CLPriceArbitrageur          │
│  - Deploys pool instances │    │  - Fixes front-run pool prices  │
│  - EIP-170 bytecode split │    │  - Dust arbitrage via Slipstream│
└───────────────────────────┘    └─────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    KickoffVoteSalePool                          │
│  - Accepts veAERO NFT locks (two-phase deposit)                 │
│  - Deposits to Autopilot for vAPR optimization                  │
│  - Claims & converts USDC rewards to WETH                       │
│  - Creates PROJECT/WETH Slipstream CL position                  │
│  - Distributes project tokens to participants                   │
└─────────────────────────────────────────────────────────────────┘
           │                                    │
           ▼                                    ▼
┌───────────────────────────┐    ┌─────────────────────────────────┐
│      KickoffPoolReader    │    │           LPLocker              │
│  - View functions         │    │  - Locks Slipstream CL NFTs     │
│  - Pool state queries     │    │  - Collects trading fees via    │
│  - Reward calculations    │    │    positionManager.collect()    │
└───────────────────────────┘    │  - 30% admin / 70% project      │
                                 └─────────────────────────────────┘
```

## Contracts

### Token Factory

| Contract | Description |
|----------|-------------|
| `ProjectToken` | Standard ERC20 token template (18 decimals, no fees, DEX compatible) |
| `ProjectTokenFactory` | Factory for creating tokens with customizable tokenomics |
| `TokenVesting` | Universal vesting contract for all project tokens |

### Vote-Sale

| Contract | Description |
|----------|-------------|
| `KickoffFactory` | Factory for creating Vote-Sale pools |
| `KickoffVoteSalePool` | Main pool contract for vote-sale mechanism |
| `VoteSalePoolDeployer` | Deploys pool instances on behalf of factory (EIP-170 bytecode split) |
| `CLPriceArbitrageur` | Shared contract for fixing front-run CL pool prices via dust arbitrage |
| `KickoffPoolReader` | Read-only contract for pool state queries and reward calculations |
| `LPLocker` | Permanently locks Slipstream CL positions, distributes trading fees |
| `EpochLib` | Library for Aerodrome epoch calculations |
| `TickMathLib` | Library for precise tick ↔ sqrtPriceX96 conversions (Uniswap V3 port) |

### Interfaces

| Interface | Description |
|-----------|-------------|
| `ITokenVesting` | TokenVesting interface |
| `IVotingReward` | Aerodrome VotingReward contracts (FeesVotingReward, BribeVotingReward) |
| `IVoter` | Aerodrome Voter contract |
| `IVotingEscrow` | Aerodrome veAERO NFT contract |
| `IAutopilot` | Autopilot PermanentLocksPoolV1 for vAPR optimization |
| `INonfungiblePositionManager` | Slipstream CL position manager |
| `ICLFactory` | Slipstream CL pool factory |
| `ICLPool` | Slipstream CL pool interface |

## Features

### Token Factory
- **Standard ERC20** tokens compatible with any DEX (Aerodrome, Uniswap, etc.)
- **Flexible tokenomics**: TGE percentage, cliff, linear vesting per allocation
- **Separate recipients**: TGE tokens and vesting locks can go to different addresses
- **Multiple allocations**: Team, investors, community, etc. with different schedules
- **Gas optimized**: MAX_ALLOCATIONS limit prevents DoS

### Vote-Sale
- **Autopilot integration** for automated vAPR optimization
- **Two-phase deposit** (depositVeAERO + confirmDeposit) to handle Aerodrome's same-block voting power reset
- **USDC rewards** automatically converted to WETH for LP creation
- **Slipstream CL positions** (1% fee tier, full-range) for liquidity
- **Batch processing** for 100+ veAERO NFTs with gas limits (MAX_BATCH_SIZE = 50)
- **Slippage protection** for swaps and liquidity
- **Reentrancy guards** on all critical functions
- **Emergency withdraw** with Autopilot retry mechanisms
- **Epoch-aligned** with automatic locking deadline
- **Paginated view functions** for gas efficiency

## Installation

```bash
# Clone repository
git clone https://github.com/kickoffbase/kickoff-contracts.git
cd kickoff-contracts

# Install dependencies
forge install

# Build
forge build

# Test
forge test
```

## Testing

```bash
# Run all tests
forge test

# Run with verbosity
forge test -vvv

# Run fork tests on Base mainnet
forge test --fork-url https://mainnet.base.org -vvv

# Run specific test files
forge test --match-path test/ProjectTokenFactory.t.sol -vvv
forge test --match-path test/TokenVesting.t.sol -vvv
```

## Deployment

### Environment Setup

Create `.env` file:

```bash
PRIVATE_KEY=0x_your_private_key
BASESCAN_API_KEY=your_api_key
```

### Deploy All Contracts

Deploys: `CLPriceArbitrageur`, `VoteSalePoolDeployer`, `KickoffFactory`, `LPLocker`, `KickoffPoolReader`, `TokenVesting`, `ProjectTokenFactory`

```bash
source .env
forge script script/Deploy.s.sol:Deploy \
  --rpc-url https://sepolia.base.org \
  --broadcast \
  --verify \
  --etherscan-api-key $BASESCAN_API_KEY \
  -vvvv
```

### Deploy Only Token Factory

Deploys: `TokenVesting`, `ProjectTokenFactory`

```bash
source .env
forge script script/Deploy.s.sol:DeployTokenFactoryOnly \
  --rpc-url https://sepolia.base.org \
  --broadcast \
  --verify \
  --etherscan-api-key $BASESCAN_API_KEY \
  -vvvv
```

### Deploy Only Vote-Sale

Deploys: `CLPriceArbitrageur`, `VoteSalePoolDeployer`, `KickoffFactory`, `LPLocker`, `KickoffPoolReader`

```bash
source .env
forge script script/Deploy.s.sol:DeployVoteSaleOnly \
  --rpc-url https://sepolia.base.org \
  --broadcast \
  --verify \
  --etherscan-api-key $BASESCAN_API_KEY \
  -vvvv
```

### Deploy Only Pool Reader

```bash
source .env
forge script script/Deploy.s.sol:DeployPoolReader \
  --rpc-url https://sepolia.base.org \
  --broadcast \
  --verify \
  --etherscan-api-key $BASESCAN_API_KEY \
  -vvvv
```

### Mainnet Deployment

Replace `https://sepolia.base.org` with `https://mainnet.base.org`

## Deployed Contracts (Base Mainnet)

| Contract | Address | Basescan |
|----------|---------|----------|
| **CLPriceArbitrageur** | `0xb285c6fe5E5A9d777b47b08Ef9F5cF68c573576D` | [View](https://basescan.org/address/0xb285c6fe5E5A9d777b47b08Ef9F5cF68c573576D) |
| **VoteSalePoolDeployer** | `0xC0d8eB2309860761879b01AAcdeBEeF84a76C025` | [View](https://basescan.org/address/0xC0d8eB2309860761879b01AAcdeBEeF84a76C025) |
| **KickoffFactory** | `0x85f85603D374c398c8fc2459917719D7aE1e9383` | [View](https://basescan.org/address/0x85f85603D374c398c8fc2459917719D7aE1e9383) |
| **LPLocker** | `0x19842164463241092ab1b00f6EF62e4A172730c6` | [View](https://basescan.org/address/0x19842164463241092ab1b00f6EF62e4A172730c6) |
| **KickoffPoolReader** | `0x8Da8b2252070B0E1e2565CbABAC8478a3614CDf1` | [View](https://basescan.org/address/0x8Da8b2252070B0E1e2565CbABAC8478a3614CDf1) |
| **TokenVesting** | `0x3628ADBDCb26A17CA2359bf4795B212261Af24Cb` | [View](https://basescan.org/address/0x3628ADBDCb26A17CA2359bf4795B212261Af24Cb) |
| **ProjectTokenFactory** | `0x72F40B3fF806347D8A8D8AECe2125ee7e6C424e8` | [View](https://basescan.org/address/0x72F40B3fF806347D8A8D8AECe2125ee7e6C424e8) |

## Usage

### Token Factory

#### 1. Create Token with Tokenomics

```solidity
ProjectTokenFactory.TokenAllocation[] memory allocations = new ProjectTokenFactory.TokenAllocation[](3);

// Team: 15% - 10% TGE + 1 month cliff + 12 month vesting
allocations[0] = ProjectTokenFactory.TokenAllocation({
    recipient: teamOperationsWallet,    // receives TGE tokens
    lockOwner: teamMultisig,            // can claim vested tokens
    amount: 150_000_000e18,
    tgePercent: 1000,                   // 10% = 1000 basis points
    cliffDuration: 30 days,
    vestingDuration: 365 days
});

// Investors: 15% - no TGE, 24 month vesting
allocations[1] = ProjectTokenFactory.TokenAllocation({
    recipient: investorTreasury,
    lockOwner: investorMultisig,
    amount: 150_000_000e18,
    tgePercent: 0,
    cliffDuration: 60 days,
    vestingDuration: 720 days
});

// Airdrop: 10% - 100% TGE
allocations[2] = ProjectTokenFactory.TokenAllocation({
    recipient: airdropContract,
    lockOwner: address(0),              // no vesting, not used
    amount: 100_000_000e18,
    tgePercent: 10000,                  // 100%
    cliffDuration: 0,
    vestingDuration: 0
});

address token = factory.createToken(
    "My Project Token",
    "MPT",
    1_000_000_000e18,  // 1B total supply
    allocations
);
```

#### 2. Start Vesting (Owner Only)

```solidity
vesting.startVesting(tokenAddress);
```

#### 3. Claim Vested Tokens (Beneficiaries)

```solidity
// Get lock IDs for user
uint256[] memory lockIds = vesting.getUserLocks(userAddress);

// Claim single lock
vesting.claim(lockId);

// Or claim multiple at once
vesting.claimMultiple(lockIds);
```

#### 4. View Vesting Info

```solidity
// Get lock details
ITokenVesting.LockInfo memory info = vesting.getLockInfo(lockId);

// Get all user locks with full info
ITokenVesting.LockInfo[] memory userLocks = vesting.getUserLocksInfo(userAddress);

// Get claimable amount
uint256 claimable = vesting.getClaimable(lockId);
```

### Vote-Sale (with Autopilot Integration)

#### For Admins (Project Creators)

```solidity
// 1. Create Pool (onlyOwner on factory)
// Note: minVotingPower must be >= 400 veAERO for Autopilot compatibility
factory.createPool(projectToken, projectOwner, totalAllocation, minVotingPower, poolAdmin)

// 2. Activate Pool
pool.activate()
// Note: lockingDeadline is automatically set to 90 min before epoch end

// 3. Wait for epoch end + special window to pass (~2h after epoch end)

// 4. Finalize with Autopilot flow
pool.startClaimRewardsFromAutopilot(batchSize)
pool.continueClaimRewardsFromAutopilot(batchSize)  // repeat until done
pool.convertUSDCtoWETH()  // retryable: if swap fails, adjust slippage and call again
pool.completeAutopilotFinalization()

// Emergency functions (if needed)
pool.emergencyWithdrawNFT(tokenId)           // Withdraw single NFT
pool.emergencyWithdrawBatch(batchSize)       // Batch withdraw
pool.retryAutopilotWithdraw(tokenIds)        // Retry failed Autopilot withdrawals
pool.cancelPool()                            // Cancel and return project tokens
```

#### For veAERO Holders

```solidity
// 1. Deposit veAERO (two-phase flow, must have >= 400 veAERO voting power)
// WARNING: NFT will be permanently locked in Autopilot (4-year max lock)
veAERO.approve(poolAddress, tokenId)
pool.depositVeAERO(tokenId)  // Phase 1: Transfer NFT to pool

// 2. Confirm deposit (must be in NEXT block - required by Aerodrome)
pool.confirmDeposit(tokenId)  // Phase 2: Deposit to Autopilot (can be called by anyone)

// Alternative: Cancel deposit if you changed your mind
pool.cancelDeposit(tokenId)  // Returns NFT to original owner

// 3. Unlock NFT & Claim (after pool is Completed)
pool.unlockVeAERO(tokenId)  // Auto-withdraws from Autopilot and returns NFT
pool.claimProjectTokens()   // Claim project tokens

// If NFT stuck after emergency withdraw:
pool.claimUnlockedNFT(tokenId)  // Claim NFT after owner's retryAutopilotWithdraw()
```

#### Using KickoffPoolReader (View Functions)

```solidity
KickoffPoolReader reader = KickoffPoolReader(readerAddress);

// Get pool stats
(uint256 totalVotingPower, uint256 participantCount, uint256 nftCount, uint256 saleAllocation) 
    = reader.getPoolStats(pool);

// Get locked NFT info
(address owner, uint256 vp, bool unlocked, bool inAutopilot) 
    = reader.getLockedNFTInfo(pool, tokenId);

// Get paginated NFT list with Autopilot status
(uint256[] memory tokenIds, bool[] memory inAutopilot, uint256 totalCount) 
    = reader.getLockedNFTsWithStatusPaginated(pool, startIndex, limit);

// Get multiple NFT infos at once
(address[] memory owners, uint256[] memory votingPowers, bool[] memory unlockeds, bool[] memory inAutopilots) 
    = reader.getMultipleNFTInfos(pool, tokenIds);

// Get Autopilot pending rewards (paginated)
(uint256 totalPending, uint256 processedCount, uint256 totalCount) 
    = reader.getTotalAutopilotPendingRewardsPaginated(pool, startIndex, limit);

// Get claimable project tokens
uint256 claimable = reader.getClaimableTokens(pool, userAddress);

// Get Autopilot rewards token (USDC)
address rewardsToken = reader.getAutopilotRewardsToken();
```

## Autopilot Integration

**IMPORTANT**: The Vote-Sale pool is integrated with [Autopilot Protocol](https://autopilot-5.gitbook.io/autopilot/) for automated vAPR optimization.

### How It Works

1. **When you lock veAERO**: Your NFT is automatically deposited to Autopilot
2. **Autopilot handles voting**: Autopilot bots vote for optimal gauges to maximize vAPR
3. **Rewards in USDC**: Autopilot claims and converts all rewards to USDC
4. **Finalization**: Admin claims USDC from Autopilot, converts to WETH, adds liquidity
5. **NFT withdrawal**: Users can withdraw their NFTs after pool completion


### Autopilot Integrated Flow

```
┌──────────────────────────────────────────────────────────────────┐
│  User deposits veNFT (depositVeAERO) → NFT in pool contract       │
│                              ↓                                    │
│  User confirms (confirmDeposit in next block) → Autopilot deposit │
│                              ↓                                    │
│  Autopilot bots vote for optimal gauges → Best vAPR              │
│                              ↓                                    │
│  Admin claims USDC from Autopilot (batch)                         │
│                              ↓                                    │
│  Swap USDC → WETH → Mint Slipstream CL Position (1% fee tier)     │
│                              ↓                                    │
│  CL Position locked in LPLocker (trading fees: 30%/70%)           │
│                              ↓                                    │
│  Users call unlockVeAERO() → Auto-withdraws from Autopilot        │
│                              ↓                                    │
│  Users claim project tokens                                       │
└──────────────────────────────────────────────────────────────────┘
```

### Autopilot Contract

| Contract | Address |
|----------|---------|
| Autopilot PermanentLocksPoolV1 | `0xA7c68a960bA0F6726C4b7446004FE64969E2b4d4` |
| USDC (Rewards Token) | `0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913` |

### Admin Functions (Autopilot Flow)

```solidity
// After epoch ends and special window passes:
pool.startClaimRewardsFromAutopilot(batchSize);
pool.continueClaimRewardsFromAutopilot(batchSize);  // repeat until done
pool.convertUSDCtoWETH();  // retryable: adjust slippage via setSwapSlippage() and call again if needed
pool.completeAutopilotFinalization();
```

### User Functions (Autopilot Flow)

```solidity
// Deposit (two-phase, during Active state):
veAERO.approve(poolAddress, tokenId);
pool.depositVeAERO(tokenId);   // Phase 1: Transfer to pool
// ... wait for next block ...
pool.confirmDeposit(tokenId);  // Phase 2: Deposit to Autopilot

// After pool is Completed:
pool.unlockVeAERO(tokenId);  // Auto-withdraws from Autopilot and returns NFT
pool.claimProjectTokens();   // Claim your project tokens
```

## Aerodrome Integration

Contracts integrate with Aerodrome on Base:

| Contract | Address |
|----------|---------|
| VotingEscrow (veAERO) | `0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4` |
| Voter | `0x16613524e02ad97eDfeF371bC883F2F5d6C480A5` |
| Router | `0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43` |
| WETH | `0x4200000000000000000000000000000000000006` |

### Slipstream (Concentrated Liquidity)

| Contract | Address |
|----------|---------|
| NonfungiblePositionManager | `0x827922686190790b37229fd06084350E74485b72` |
| CL Factory | `0x5e7BB104d84c7CB9B682AaC2F3d509f5F406809A` |
| Swap Router | `0xBE6D8f0d05cC4be24d5167a3eF062215bE6D18a5` |

Liquidity is added as **full-range 1% fee tier** CL position for maximum coverage.

## Security

- **Audited by Halborn** - [View Audit Report](https://www.halborn.com/audits/kickofffun/kickoff-protocol-contracts-b5f786)

### Key Security Features

- **ReentrancyGuard** on all critical functions
- **Two-step ownership** transfer (Ownable2Step pattern)
- **Input validation** on all parameters
- **MAX_ALLOCATIONS** limit (50) prevents gas DoS
- **Emergency rescue** for stuck tokens
- **Slippage protection** for swaps and liquidity
- **Batch processing** to avoid gas limits
- **Safe ERC20 transfers** - handles non-standard tokens (USDT, etc.)
- **Deactivated NFT handling** - gracefully skips deactivated veAERO
- **Epoch alignment** - ensures operations within Aerodrome epoch boundaries
- **Pool cancellation** - allows recovery if no participants
- **Pull-based fee distribution** - prevents DoS on LPLocker
- **LPLocker deployer check** - only deployer can set factory
- **Paginated view functions** - prevents gas DoS on large datasets
- **Autopilot retry mechanism** - handles stuck NFTs during special window
- **Two-phase deposit** - bypasses Aerodrome's same-block voting power reset protection
- **Gas limit protection** - MAX_BATCH_SIZE=50 on all batch operations
- **Front-run protection** - CLPriceArbitrageur corrects manipulated CL pool prices via dust arbitrage
- **Retryable USDC conversion** - `convertUSDCtoWETH()` can be called multiple times with adjusted slippage

## License

MIT

## Links

- Website: https://www.kickoff.fun/
- Documentation: https://www.kickoff.fun/docs
- Aerodrome: https://aerodrome.finance
