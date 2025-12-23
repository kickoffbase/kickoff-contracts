# Kickoff veAERO Sale Contracts

Smart contracts for **Kickoff** - a liquidity bootstrapping launchpad that leverages Aerodrome's veAERO governance on Base.

## Overview

Kickoff enables projects to bootstrap liquidity by leveraging veAERO voting power:

1. **Projects** deposit tokens and create a Vote-Sale Pool
2. **veAERO holders** lock their NFTs to provide voting power
3. **Voting power** is used to vote for the project's gauge on Aerodrome
4. **Rewards** (bribes + fees) are converted to WETH and paired with project tokens
5. **LP tokens** are permanently locked, generating trading fees forever
6. **Participants** claim project tokens proportional to their voting power contribution and withdraw their locked voting power after epoch ending

## Architecture

```
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

| Contract | Description |
|----------|-------------|
| `KickoffFactory` | Factory for creating Vote-Sale pools |
| `KickoffVoteSalePool` | Main pool contract for vote-sale mechanism |
| `LPLocker` | Permanently locks LP tokens, distributes trading fees |
| `EpochLib` | Library for Aerodrome epoch calculations |

### Interfaces

| Interface | Description |
|-----------|-------------|
| `IVotingReward` | Aerodrome VotingReward contracts (FeesVotingReward, BribeVotingReward) |
| `IVoter` | Aerodrome Voter contract (gaugeToFees, gaugeToBribe) |
| `IVotingEscrow` | Aerodrome veAERO NFT contract |

## Features

- ✅ **Auto-discovery** of reward tokens (fees & bribes) — no manual token lists needed
- ✅ **Batch processing** for 100+ veAERO NFTs
- ✅ **Slippage protection** for swaps and liquidity
- ✅ **Reentrancy guards** on all critical functions
- ✅ **Emergency withdraw** mechanisms
- ✅ **Epoch-aligned** voting with Aerodrome

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

# Run comprehensive integration test (full flow with real veAERO holders)
forge test --match-contract ComprehensiveForkTest --fork-url https://mainnet.base.org -vvv
```

## Deployment

### Environment Setup

Create `.env` file:

```bash
PRIVATE_KEY=0x_your_private_key
BASESCAN_API_KEY=your_api_key
```

### Deploy to Base Sepolia (Testnet)

```bash
source .env
forge script script/Deploy.s.sol:Deploy \
  --rpc-url https://sepolia.base.org \
  --broadcast \
  --verify \
  -vvvv
```

### Deploy to Base Mainnet

```bash
source .env
forge script script/Deploy.s.sol:Deploy \
  --rpc-url https://mainnet.base.org \
  --broadcast \
  --verify \
  -vvvv
```

## Usage Flow

### For Admins (Project Creators)

1. **Create Pool**
   ```solidity
   factory.createPool(projectToken, projectOwner, totalAllocation)
   ```

2. **Activate Pool**
   ```solidity
   pool.activate()
   ```

3. **Cast Votes** (after veAERO holders lock)
   ```solidity
   pool.castVotes(gaugeAddress)
   // or for 100+ NFTs:
   pool.castVotesBatch(gaugeAddress, 50)
   ```

4. **Finalize** (after epoch ends)
   ```solidity
   // Auto-discovers reward tokens and claims them
   pool.finalizeEpoch()
   
   // For 100+ NFTs (batch processing):
   pool.startClaimRewardsBatch(50)       // Start batch, auto-discovers tokens
   pool.continueClaimRewardsBatch(50)    // Continue until all NFTs processed
   pool.completeFinalization()           // Finalize after all rewards claimed
   ```

5. **View Pending Rewards** (optional)
   ```solidity
   // Get all available reward tokens with claimable amounts
   address[] memory tokens = pool.getAvailableRewardTokens()
   
   // Get pending rewards for specific NFT
   uint256[] memory amounts = pool.getPendingRewards(tokenId, tokens)
   
   // Get total claimable rewards across all locked NFTs
   uint256[] memory totals = pool.getTotalClaimableRewards(tokens)
   ```

### For veAERO Holders

1. **Lock veAERO**
   ```solidity
   veAERO.setApprovalForAll(poolAddress, true)
   pool.lockVeAERO(tokenId)
   ```

2. **Unlock & Claim** (after finalization)
   ```solidity
   pool.unlockVeAERO(tokenId)
   pool.claimProjectTokens()
   ```

### For Fee Recipients

```solidity
lpLocker.claimTradingFees(poolAddress)
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

- ReentrancyGuard on all state-changing functions
- Slippage protection (configurable, default 1%)
- Minimum output of 1 wei to prevent dust attacks
- Batch processing to avoid gas limits
- Emergency withdraw for locked NFTs
- Ownable2Step for ownership transfers

## License

MIT

## Links

- Website: https://www.kickoff.fun/
- Documentation: [Coming Soon]
- Aerodrome: https://aerodrome.finance


