# Kickoff Protocol Contracts

Smart contracts for **Kickoff** - a liquidity bootstrapping launchpad that leverages Aerodrome's veAERO governance on Base.

## Overview

Kickoff enables projects to bootstrap liquidity by leveraging veAERO voting power:

1. **Projects** create tokens with customizable tokenomics via Token Factory
2. **Projects** deposit tokens and create a Vote-Sale Pool
3. **veAERO holders** lock their NFTs to provide voting power
4. **Voting power** is used to vote for the project's gauge on Aerodrome
5. **Rewards** (bribes + fees) are converted to WETH and paired with project tokens
6. **LP tokens** are permanently locked, generating trading fees forever
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
│  - Creates Vote-Sale Pools                                      │
│  - Manages global configuration                                 │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                    KickoffVoteSalePool                          │
│  - Accepts veAERO NFT locks                                     │
│  - Casts votes on Aerodrome                                     │
│  - Claims & converts rewards to WETH                            │
│  - Creates PROJECT/WETH liquidity                               │
│  - Distributes project tokens to participants                   │
└─────────────────────────────────────────────────────────────────┘
                              │
                              ▼
┌─────────────────────────────────────────────────────────────────┐
│                         LPLocker                                │
│  - Permanently locks LP tokens                                  │
│  - Distributes trading fees (30% admin / 70% project)           │
└─────────────────────────────────────────────────────────────────┘
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
| `LPLocker` | Permanently locks LP tokens, distributes trading fees |
| `EpochLib` | Library for Aerodrome epoch calculations |

### Interfaces

| Interface | Description |
|-----------|-------------|
| `ITokenVesting` | TokenVesting interface |
| `IVotingReward` | Aerodrome VotingReward contracts (FeesVotingReward, BribeVotingReward) |
| `IVoter` | Aerodrome Voter contract |
| `IVotingEscrow` | Aerodrome veAERO NFT contract |

## Features

### Token Factory
- **Standard ERC20** tokens compatible with any DEX (Aerodrome, Uniswap, etc.)
- **Flexible tokenomics**: TGE percentage, cliff, linear vesting per allocation
- **Separate recipients**: TGE tokens and vesting locks can go to different addresses
- **Multiple allocations**: Team, investors, community, etc. with different schedules
- **Gas optimized**: MAX_ALLOCATIONS limit prevents DoS

### Vote-Sale
- **Auto-discovery** of reward tokens (fees & bribes)
- **Batch processing** for 100+ veAERO NFTs
- **Slippage protection** for swaps and liquidity
- **Reentrancy guards** on all critical functions
- **Emergency withdraw** mechanisms
- **Epoch-aligned** voting with Aerodrome

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

```bash
source .env
forge script script/Deploy.s.sol:Deploy \
  --rpc-url https://sepolia.base.org \
  --broadcast \
  --verify \
  -vvvv
```

### Deploy Only Token Factory

```bash
source .env
forge script script/Deploy.s.sol:DeployTokenFactoryOnly \
  --rpc-url https://sepolia.base.org \
  --broadcast \
  --verify \
  -vvvv
```

### Deploy Only Vote-Sale

```bash
source .env
forge script script/Deploy.s.sol:DeployVoteSaleOnly \
  --rpc-url https://sepolia.base.org \
  --broadcast \
  --verify \
  -vvvv
```

### Mainnet Deployment

Replace `https://sepolia.base.org` with `https://mainnet.base.org`

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

### Vote-Sale

#### For Admins (Project Creators)

```solidity
// 1. Create Pool
factory.createPool(projectToken, projectOwner, totalAllocation, minVotingPower)

// 2. Activate Pool
pool.activate()

// 3. Cast Votes (after veAERO holders lock)
pool.castVotes(gaugeAddress)

// 4. Finalize (after epoch ends)
pool.finalizeEpoch()
```

#### For veAERO Holders

```solidity
// 1. Lock veAERO
veAERO.setApprovalForAll(poolAddress, true)
pool.lockVeAERO(tokenId)

// 2. Unlock & Claim (after finalization)
pool.unlockVeAERO(tokenId)
pool.claimProjectTokens()
```

## Aerodrome Integration

Contracts integrate with Aerodrome on Base:

| Contract | Address |
|----------|---------|
| VotingEscrow (veAERO) | `0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4` |
| Voter | `0x16613524e02ad97eDfeF371bC883F2F5d6C480A5` |
| Router | `0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43` |
| WETH | `0x4200000000000000000000000000000000000006` |

## Security

- Audited: [Pending]

### Key Security Features

- **ReentrancyGuard** on all claim functions
- **Two-step ownership** transfer (Ownable2Step pattern)
- **Input validation** on all parameters
- **MAX_ALLOCATIONS** limit (50) prevents gas DoS
- **Emergency rescue** for stuck tokens (only excess, not vested)
- **Slippage protection** for swaps and liquidity
- **Batch processing** to avoid gas limits

## License

MIT

## Links

- Website: https://www.kickoff.fun/
- Documentation: https://www.kickoff.fun/docs
- Aerodrome: https://aerodrome.finance
