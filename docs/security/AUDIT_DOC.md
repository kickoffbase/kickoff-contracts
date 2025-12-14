# Kickoff veAERO Sale Contracts - Audit Documentation

**Version:** 1.0  
**Date:** December 2024  
**Commit Freeze:** [`5897ed25744c66232d52f8c6d443bd3b74d0a072`](https://github.com/kickoffbase/kickoff-contracts/commit/5897ed25744c66232d52f8c6d443bd3b74d0a072) (`main` branch)  
**Scope:** `src/`, `test/` directories


## Summary (What, Who, How)

### What the system does

Kickoff is a liquidity bootstrapping launchpad that enables projects to bootstrap liquidity by leveraging Aerodrome's veAERO governance on Base. Projects deposit tokens into a Vote-Sale Pool where veAERO holders lock their governance NFTs to provide voting power. This voting power is delegated to the project's Aerodrome gauge to earn bribes and trading fees. The protocol collects these rewards, converts them to WETH, and pairs them with project tokens to create permanent liquidity. Project token holders receive shares proportional to their voting power contribution.

### Who uses it

| Actor | Role | Description |
|-------|------|-------------|
| **Project Admin** | Pool Creator | Deploys a pool, deposits project tokens, initiates voting/finalization phases |
| **Project Owner** | Beneficiary | Receives 80% of permanent LP trading fees; designated at pool creation |
| **veAERO Holders** | Participants | Lock veAERO NFTs to contribute voting power; receive project tokens pro-rata |
| **Protocol Owner** | Emergency Control | Owns the factory; can transfer ownership and manage global settings |
| **Keeper/Bot** | Operational Support | Calls batch functions when NFT count exceeds gas limits; off-chain monitoring |

### How at a high level

1. **Factory** deploys isolated Vote-Sale Pools for each project
2. **Pool activation** opens a locking phase where veAERO holders deposit their NFTs
3. **Voting phase** casts all locked NFTs' voting power to the project's Aerodrome gauge
4. **Finalization** (batch processing):
   - Claims internal bribes (veAERO emissions) and external bribes (protocols)
   - Converts bribe tokens to WETH
   - Adds liquidity (project token + WETH) to Aerodrome volatile pool
   - Locks LP tokens permanently in LPLocker, freezing capital and enabling fee collection
5. **Claim phase** allows:
   - Participants to claim project tokens (share of 50% allocation)
   - Both admin and project owner to claim their split of trading fees forever

The system is secured by reentrancy guards, access control (onlyAdmin/onlyOwner), and batch processing limits. Epoch alignment with Aerodrome ensures votes count in the intended voting period.


## Architecture Overview

### Module map

| Contract | Responsibility | Key External Interfaces | Critical State |
|----------|-----------------|-------------------------|-----------------|
| **KickoffFactory** | Pool factory; global config | `createPool(projectToken, projectOwner, totalAllocation)` → deployed pool | Mapping of token → pool; array of all pools |
| **KickoffVoteSalePool** | Main vote-sale pool | `lockVeAERO()`, `castVotes()`, `finalizeEpoch()`, `claimProjectTokens()`, `unlockVeAERO()` | Pool state machine (Inactive→Active→Voting→Finalizing→Completed); locked NFTs; user voting power; WETH collected; LP created |
| **LPLocker** | Permanent LP custody | `lockLP(lpToken, aerodromePool, admin, projectOwner, amount)`, `claimTradingFees(votePool)` | Mapping of votePool → locked LP info; fee distribution state |
| **EpochLib** | Epoch calculations | `currentEpoch()`, `currentEpochStart()`, `hasVotedThisEpoch()` | None (pure/view functions) |

### Entry points

| Function | Caller | Purpose |
|----------|--------|---------|
| `createPool()` | Project admin | Create a new Vote-Sale pool with project token allocation |
| `activate()` | Pool admin | Transition pool to Active state; record activation epoch |
| `lockVeAERO(tokenId)` | veAERO holder | Deposit veAERO NFT; record voting power |
| `castVotes(gauge)` / `castVotesBatch(gauge, batchSize)` | Pool admin | Vote all locked NFTs for Aerodrome gauge (small/large-scale) |
| `finalizeEpoch(bribeTokens)` / `startClaimRewardsBatch(bribeTokens, batchSize)` + `continueClaimRewardsBatch(batchSize)` + `completeFinalization()` | Pool admin | Claim bribes, convert to WETH, add liquidity, lock LP (small/large-scale) |
| `unlockVeAERO(tokenId)` | Original NFT owner | Withdraw locked veAERO NFT after pool completion |
| `claimProjectTokens()` | Participant | Claim project tokens based on voting power share |
| `claimTradingFees(votePool)` | Admin or Project Owner | Claim accrued trading fees from locked LP |
| `emergencyWithdrawNFT(tokenId)` / `emergencyWithdrawBatch()` | Protocol owner | Force-return NFTs to original owners in emergency |
| `rescueTokens(token, to, amount)` | Pool admin | Rescue stuck non-project tokens |

### Data flows (high level)

1. **Token inflow:** Project admin transfers 50% allocation to sale pool, 50% to liquidity pool via factory
2. **Voting power aggregation:** Each locked NFT's voting balance (veAERO) is summed into `totalVotingPower`; per-user contribution tracked in `userInfo[].totalVotingPower`
3. **Bribe collection:** Aerodrome voter contract (via claimBribes/claimFees) transfers bribe tokens to pool
4. **Token conversion:** Bribe tokens swapped to WETH via Aerodrome Router with slippage protection
5. **Liquidity creation:** Project token + WETH added to volatile Aerodrome pool; LP token sent to LPLocker
6. **Fee accrual:** Aerodrome pool generates trading fees; LPLocker's `claimFees()` extracts and splits 20% admin / 80% project owner


## Actors, Roles & Privileges

### Roles and capabilities

| Role | Held By | Key Capabilities |
|------|---------|------------------|
| **Admin** (KickoffVoteSalePool) | Pool creator (msg.sender in factory.createPool) | `activate()`, `castVotes()`, `finalizeEpoch()`, `setSwapSlippage()`, `setLiquiditySlippage()`, `rescueTokens()` |
| **Project Owner** | Designated at pool creation | Receives 80% of locked LP trading fees; no direct on-chain control; designated in `projectOwner` immutable |
| **NFT Owner** | Original caller of `lockVeAERO()` | `unlockVeAERO()`, `claimProjectTokens()` after pool completion |
| **Protocol Owner** (KickoffFactory) | Factory deployer or successor via 2-step transfer | `acceptOwnership()` (factory); can transfer factory ownership |
| **Pool Owner** (KickoffVoteSalePool) | Admin at deployment (immutable) | `emergencyWithdrawNFT()`, `emergencyWithdrawBatch()`, `emergencyWithdrawAllNFTs()`, `transferOwnership()`, `acceptOwnership()` |

### Access control design

- **KickoffFactory:**
  - `owner` — factory admin; 2-step `transferOwnership()` + `acceptOwnership()`
  - `pendingOwner` — staged ownership transfer
  - No pausable mechanisms; no role-based access control library used

- **KickoffVoteSalePool:**
  - `admin` (immutable) — pool creator; checked via `onlyAdmin()` modifier
  - `owner` (mutable via 2-step transfer) — initialized to `admin` at construction; used for emergency functions
  - `onlyAdmin()` modifier — enforces `msg.sender == admin`
  - `onlyOwner()` modifier — enforces `msg.sender == owner`
  - `inState(PoolState)` modifier — enforces state machine transitions

- **LPLocker:**
  - No owner/admin; permissionless `lockLP()` but checks `msg.sender` in `claimTradingFees()` against stored admin/project owner
  - Access to fees is role-based (admin XOR project owner)

### Emergency controls

| Control | Triggered By | Effect | Blast Radius |
|---------|-------------|--------|-------------|
| **emergencyWithdrawNFT(tokenId)** | Pool owner | Returns single NFT to original owner | Single NFT; pool state unchanged |
| **emergencyWithdrawBatch(batchSize)** | Pool owner | Returns up to 50 NFTs at a time | Batch of up to 50 NFTs; pool state unchanged |
| **emergencyWithdrawAllNFTs()** | Pool owner | Returns all locked NFTs in one call (gas risk for large N) | All NFTs; fails if batch in progress; pool state unchanged |
| **rescueTokens(token, to, amount)** | Pool admin | Recovers non-project tokens stuck in pool | Specified token only (projectToken excluded); participants unaffected |

**Note:** No global pause mechanism exists. Freezing requires state transitions or emergency withdrawals. LPLocker does not have emergency unlock; once locked, LP is permanent (by design).


## User Flows (Primary Workflows)

### Flow 1: Pool Creation and Activation

**User Story:** *As a project admin, I create a vote-sale pool and activate it so veAERO holders can begin locking their NFTs.*

**Preconditions:**
- Project has ERC20 token deployed on Base
- Admin has project tokens and allowance approved to factory
- Admin is the msg.sender (becomes admin of the pool)

**Happy path:**
1. Admin calls `factory.createPool(projectToken, projectOwner, totalAllocation)`
2. Factory validates inputs (no zero addresses, allocation > 0, no duplicate pools)
3. Factory deploys new `KickoffVoteSalePool` instance
4. Factory transfers `totalAllocation` project tokens to pool (with fee-on-transfer handling)
5. Pool is added to factory's pool registry
6. Admin calls `pool.activate()` within the same epoch as intended
7. Pool transitions to `PoolState.Active`; `activeEpoch` is recorded

**Alternates / edge cases:**
- **Fee-on-transfer token:** Factory checks balance before/after to detect shortfall; reverts if insufficient
- **Duplicate pool:** Factory rejects if `poolByToken[projectToken]` already set
- **Cross-epoch activation:** If activate() called in later epoch, voting in that epoch may not count; recommend same-epoch call
- **Revert on bad parameters:** Zero address, zero amount, insufficient allowance → pool creation fails

**On-chain ↔ off-chain interactions:**
- Admin monitors Base RPC to confirm pool deployment and state transitions
- Keeper bot may monitor factory events to notify admin of pool creation

**Linked diagram:** [Pool Lifecycle](./diagrams/flow_pool_lifecycle.md)

**Linked tests:**
- [test/KickoffFactory.t.sol::test_CreatePool](../../test/KickoffFactory.t.sol)
- [test/KickoffFactory.t.sol::test_Constructor](../../test/KickoffFactory.t.sol)


### Flow 2: Lock veAERO and Cast Votes

**User Story:** *As a veAERO holder, I lock my governance NFT to contribute voting power for a project launch.*

**Preconditions:**
- Pool is in `PoolState.Active`
- Caller owns a veAERO NFT on Base (held in VotingEscrow contract)
- NFT has not voted this epoch (`lastVoted` timestamp < current epoch start)
- Pool admin has selected target gauge (Aerodrome)

**Happy path:**
1. Participant approves veAERO NFT transfer or uses `safeTransferFrom()`
2. Participant calls `pool.lockVeAERO(tokenId)`
3. Pool validates:
   - Caller owns NFT
   - NFT has not voted this epoch
4. Pool transfers NFT to itself via `votingEscrow.safeTransferFrom()`
5. Pool records NFT in `lockedNFTs[tokenId]` with owner and voting power
6. Pool increments `userInfo[msg.sender].totalVotingPower` and `totalVotingPower`
7. After all NFTs locked, admin calls `pool.castVotes(gauge)` or `pool.castVotesBatch(gauge, 25)` (in batches if >50 NFTs)
8. Pool casts all votes to target gauge using `voter.vote(tokenId, [gauge], [100%])`
9. Pool transitions to `PoolState.Voting`

**Alternates / edge cases:**
- **Already voted this epoch:** If NFT voted in current epoch, lock reverts
- **Large NFT count (>50):** Use batch functions; multiple calls required
- **Batch in progress:** Cannot start new batch if one is running; poll `batchInProgress` or `getVotingProgress()`
- **Invalid gauge:** Votes revert if gauge is not on pool or not alive
- **NFT transfer failure:** Reentrancy guard active; fail-safe returns

**On-chain ↔ off-chain interactions:**
- Keeper polls `getVotingProgress()` to monitor batch completion
- Verifiy the intended gauge before calling `castVotes()`; immutable after recording

**Linked diagram:** [Voting Phase](./diagrams/flow_voting.md)

**Linked tests:**
- [test/KickoffVoteSalePool.t.sol::test_LockVeAERO](../../test/KickoffVoteSalePool.t.sol)
- [test/KickoffVoteSalePool.t.sol::test_CastVotes](../../test/KickoffVoteSalePool.t.sol)
- [test/KickoffVoteSalePool.t.sol::test_CastVotesBatch](../../test/KickoffVoteSalePool.t.sol)


### Flow 3: Finalize Epoch and Claim Trading Fees

**User Story:** *As a pool admin, I claim Aerodrome bribes, convert to WETH, create liquidity, and lock it permanently. As admin/project owner, I begin accruing trading fees.*

**Preconditions:**
- Pool is in `PoolState.Voting`
- Voting epoch has passed (new epoch started, so voting is final)
- Admin has list of bribe token addresses expected from Aerodrome

**Happy path:**
1. Admin calls `pool.finalizeEpoch(bribeTokens)` (if ≤50 NFTs) or initiates batch:
   - `pool.startClaimRewardsBatch(bribeTokens, batchSize)`
   - `pool.continueClaimRewardsBatch(batchSize)` (repeat until `batchIndex >= totalNFTs`)
   - `pool.completeFinalization()`
2. For each locked NFT, pool calls:
   - `voter.claimBribes(bribes=[internalBribe, externalBribe], tokens=bribeTokens, tokenId)`
   - `voter.claimFees(bribes=[internalBribe, externalBribe], tokens=bribeTokens, tokenId)`
3. Pool receives bribe tokens (try/catch; non-essential failures are silent)
4. Pool converts all bribe tokens to WETH via `router.swapExactTokensForTokens()` with slippage protection
5. Pool calls `router.addLiquidity(projectToken, WETH, volatile, liquidityAllocation, wethCollected, minProjectToken, minWETH, ...)`
6. Aerodrome pool issues LP token; pool records `lpToken` and `lpCreated` amount
7. Pool approves LP tokens to LPLocker and calls `lpLocker.lockLP(lpToken, aerodromePool, admin, projectOwner, lpCreated)`
8. LPLocker stores LP info; pool transitions to `PoolState.Completed`

**Alternates / edge cases:**
- **Large NFT count (>50):** Use batch functions; keeper calls sequentially
- **Bribe claim failure:** Try/catch silently skips failed claims (some bribes may be unavailable)
- **Swap failure:** If token ↔ WETH swap fails, token is left on contract for `rescueTokens()`
- **Slippage exceeded:** If swap output < minOut (5% default), revert; admin can increase slippage via `setSwapSlippage()`
- **Batch in progress:** Cannot start finalize if voting batch still active
- **Wrong bribe token list:** Missing tokens result in no swap; use `rescueTokens()` to recover
- **Zero WETH collected:** Liquidity creation skipped if no bribe rewards received

**On-chain ↔ off-chain interactions:**
- Keeper monitors `getFinalizeProgress()` to track batch completion
- Admin pre-fetches bribe tokens from Aerodrome Voter contract to pass to `finalizeEpoch()`
- Trading fees accrue automatically as Aerodrome pool generates swap fees; admin/project owner call `lpLocker.claimTradingFees(votePool)` anytime

**Linked diagram:** [Finalization Phase](./diagrams/flow_finalization.md)

**Linked tests:**
- [test/KickoffVoteSalePool.t.sol::test_FinalizeEpoch](../../test/KickoffVoteSalePool.t.sol)
- [test/KickoffVoteSalePool.t.sol::test_FinalizeEpochBatch](../../test/KickoffVoteSalePool.t.sol)
- [test/LPLocker.t.sol::test_ClaimTradingFees](../../test/LPLocker.t.sol)


### Flow 4: Claim Project Tokens and Unlock NFT

**User Story:** *As a participant, I claim my share of project tokens based on voting power contribution, then retrieve my veAERO NFT.*

**Preconditions:**
- Pool is in `PoolState.Completed`
- Caller has contributed voting power (locked at least one NFT)
- Caller has not yet claimed

**Happy path:**
1. Participant calls `pool.claimProjectTokens()`
2. Pool calculates share: `userShare = (saleAllocation * userInfo[msg.sender].totalVotingPower) / totalVotingPower`
3. Pool marks `userInfo[msg.sender].claimed = true`
4. Pool transfers `userShare` project tokens to participant
5. Participant calls `pool.unlockVeAERO(tokenId)` for each locked NFT
6. Pool verifies caller is original owner and NFT is not already unlocked
7. Pool returns NFT to participant via `votingEscrow.safeTransferFrom(address(this), msg.sender, tokenId)`

**Alternates / edge cases:**
- **Already claimed:** Revert with `AlreadyClaimed()` if called twice
- **Zero voting power:** Revert with `NothingToClaim()` if user never locked an NFT
- **Unlock before claim:** No requirement to claim before unlocking; NFTs returned independently
- **NFT not in pool:** If tokenId not found in `lockedNFTs`, unlock reverts
- **Transfer failure:** If veAERO safeTransferFrom fails, revert; NFT stays in pool

**On-chain ↔ off-chain interactions:**
- Participant monitors `pool.getClaimableTokens(address)` before calling `claimProjectTokens()`
- No keeper required; participants self-execute

**Linked diagram:** [Claim Phase](./diagrams/flow_claim.md)

**Linked tests:**
- [test/KickoffVoteSalePool.t.sol::test_ClaimProjectTokens](../../test/KickoffVoteSalePool.t.sol)
- [test/KickoffVoteSalePool.t.sol::test_UnlockVeAERO](../../test/KickoffVoteSalePool.t.sol)


### Flow 5: Emergency Withdrawal (Contingency)

**User Story:** *As a protocol owner, in case of bug or governance attack, I force-return all locked veAERO NFTs to their original owners to unwind the sale.*

**Preconditions:**
- Pool owner (admin or successor via 2-step transfer) initiates
- Can be called in any pool state

**Happy path:**
1. Pool owner calls `pool.emergencyWithdrawBatch(50)` or `pool.emergencyWithdrawNFT(tokenId)`
2. Pool returns specified NFT(s) to original owner(s) without state checks
3. Pool marks NFT as unlocked
4. Pool emits `EmergencyWithdraw(owner, tokenId)`

**Alternates / edge cases:**
- **Large withdrawal (100+ NFTs):** Use batch function; call repeatedly until `batchInProgress == false`
- **Batch in progress:** Cannot start new batch until current one completes; poll `batchInProgress`
- **Already unlocked:** Skip already-unlocked NFTs; no double-return
- **Zero NFTs:** Gracefully returns if no NFTs locked

**On-chain ↔ off-chain interactions:**
- None; emergency action
- Owner monitors `getEmergencyWithdrawProgress()` for batch completion

**Linked diagram:** [Emergency Withdrawal](./diagrams/flow_emergency.md)

**Linked tests:**
- [test/KickoffVoteSalePool.t.sol::test_EmergencyWithdraw](../../test/KickoffVoteSalePool.t.sol)


## State, Invariants & Properties

### State variables that matter to safety/economics

| Variable | Type | Scope | Purpose | Risk |
|----------|------|-------|---------|------|
| `state` | `PoolState` | Per-pool | Enforces phase transitions (Inactive→Active→Voting→Finalizing→Completed) | State bypass allows out-of-sequence operations |
| `totalVotingPower` | `uint256` | Per-pool | Sum of all locked NFT voting powers; denominator for pro-rata claims | Overflow (negligible; limited by VE supply) |
| `userInfo[addr].totalVotingPower` | `uint256` | Per-user | Voting power contributed by user; basis for token claim share | Mismatch with global total if user not tracked on lock |
| `lockedNFTs[tokenId]` | `LockedNFT` struct | Per-NFT | Owner, voting power, unlock status | Missing or stale data if NFT transfers bypass `lockVeAERO()` |
| `wethCollected` | `uint256` | Per-pool | Total WETH from bribe conversion; denominator for LP creation | Underflow if swaps fail silently (mitigated by try/catch) |
| `lpCreated` | `uint256` | Per-pool | Total LP issued; immutable after finalization; used for fee distributions | Inaccuracy if router returns wrong amount |
| `batchInProgress` | `bool` | Per-pool | Flag to prevent concurrent batch operations | Stuck if batch logic exits without clearing flag |
| `batchIndex` | `uint256` | Per-pool | Current position in batch loop; not reset between phases | Incorrect range if batches overlap |
| `_reentrancyStatus` | `uint256` | Per-contract | Reentrancy guard; prevents nested calls | Bypass if guard not checked on all external functions |

### Invariants (must always hold)

1. **State Machine Linearity**
   - Pool state only transitions in sequence: `Inactive → Active → Voting → Finalizing → Completed`
   - **Justification:** Enforces phase-dependent access control (e.g., cannot claim tokens before finalization)
   - **Enforced by:** `inState()` modifiers on all state-dependent functions
   - **Tested in:** [test/KickoffVoteSalePool.t.sol](../../test/KickoffVoteSalePool.t.sol) — state transition tests

2. **NFT Ownership Conservation**
   - If `lockedNFTs[tokenId].owner == X`, then either:
     - Pool holds the NFT (unlocked == false), OR
     - X holds the NFT (unlocked == true)
   - **Justification:** Ensures NFTs are always in correct custodian; prevents theft
   - **Enforced by:** NFT transfer logic in `lockVeAERO()`, `unlockVeAERO()`, emergency withdrawal
   - **Tested in:** [test/KickoffVoteSalePool.t.sol](../../test/KickoffVoteSalePool.t.sol) — lock/unlock tests

3. **Voting Power Accounting**
   - `sum(userInfo[*].totalVotingPower) == totalVotingPower`
   - **Justification:** Per-user shares must aggregate to total; required for pro-rata claims
   - **Enforced by:** Atomic increment on `lockVeAERO()`: both `userInfo[msg.sender].totalVotingPower` and `totalVotingPower` updated together
   - **Tested in:** [test/KickoffVoteSalePool.t.sol](../../test/KickoffVoteSalePool.t.sol) — test_VotingPowerAggregation (if present)

4. **Token Allocation Conservation**
   - `saleAllocation + liquidityAllocation == totalAllocation`
   - **Justification:** Ensures full token supply is allocated; prevents over-issuance or loss
   - **Enforced by:** Constructor: `saleAllocation = totalAllocation / 2; liquidityAllocation = totalAllocation - saleAllocation`
   - **Tested in:** [test/KickoffVoteSalePool.t.sol](../../test/KickoffVoteSalePool.t.sol) — test_Allocations

5. **Single Claim Per User**
   - If `userInfo[user].claimed == true`, then `claimProjectTokens()` reverts
   - **Justification:** Prevents double-claiming; ensures each user receives only their pro-rata share once
   - **Enforced by:** Check in `claimProjectTokens()` and flag set atomically
   - **Tested in:** [test/KickoffVoteSalePool.t.sol](../../test/KickoffVoteSalePool.t.sol) — test_DoubleClaim

6. **LP Lock Finality**
   - Once `lpCreated > 0` and `state == Completed`, LP token is locked in LPLocker permanently
   - **Justification:** LP tokens generate trading fees forever; capital is immobilized to guarantee perpetual fee stream
   - **Enforced by:** `LPLocker.lockLP()` immutability; no unlock mechanism in LPLocker
   - **Tested in:** [test/LPLocker.t.sol](../../test/LPLocker.t.sol) — test_LPLocked

7. **Reentrancy Safety**
   - If function is marked `nonReentrant`, it cannot call another `nonReentrant` function in the same contract within the same transaction
   - **Justification:** Protects critical operations (claims, withdrawals) from reentrancy attacks
   - **Enforced by:** `nonReentrant` modifier; sets `_reentrancyStatus = ENTERED` at start, `NOT_ENTERED` at end
   - **Tested in:** [test/KickoffVoteSalePool.t.sol](../../test/KickoffVoteSalePool.t.sol) — test_Reentrancy (if present)

8. **Admin Fee Split**
   - In `LPLocker`, `ADMIN_FEE_BPS == 2000` and `PROJECT_OWNER_FEE_BPS == 8000` always
   - **Justification:** Ensures protocol captures 20% of LP fees; project owner receives 80%
   - **Enforced by:** Immutable constants in LPLocker
   - **Tested in:** [test/LPLocker.t.sol](../../test/LPLocker.t.sol) — test_FeeDistribution

9. **Slippage Bounds**
   - `swapSlippageBps <= 5000` (max 50%) and `liquiditySlippageBps <= 5000`
   - **Justification:** Prevents admin from setting slippage so high it opens MEV/sandwich attack surface
   - **Enforced by:** Bounds check in `setSwapSlippage()` and `setLiquiditySlippage()`
   - **Tested in:** [test/KickoffVoteSalePool.t.sol](../../test/KickoffVoteSalePool.t.sol) — test_SlippageValidation

### Property checks / assertions / differential tests

- **Batch Progress Monotonicity:** `batchIndex` only increases during batch operations; never resets mid-batch
  - Tested implicitly in batch continuation tests
- **Voting Power Immutability:** Once an NFT is locked, its `votingPower` cannot change
  - Enforced by immutable recording in `lockedNFTs[tokenId]`
- **Epoch Alignment:** All voting must occur in the same epoch to ensure votes count in one distribution cycle
  - Validated by EpochLib; checked on `castVotes()`


## Economic & External Assumptions

### Token assumptions

| Assumption | Implication | Mitigation |
|-----------|------------|-----------|
| **ERC20 Standard Compliance** | Project token must implement `transfer()`, `transferFrom()`, `approve()`, `balanceOf()` | Factory uses standard ERC20 checks; non-standard tokens will fail during pool creation |
| **No Fee-on-Transfer (unless handled)** | If project token has transfer tax, `totalAllocation` received may be < amount sent | Factory checks `balanceAfter - balanceBefore` to detect shortfall; reverts if insufficient |
| **No Rebasing** | Token balance should not auto-adjust; Kickoff does not handle rebasing | If token rebases, locked amounts may increase/decrease; users' claims would be based on stale voting power |
| **Sufficient Liquidity** | Project token must have trading pairs on Aerodrome; WETH pair required for LP creation | Liquidity check is implicit; if pair doesn't exist, `addLiquidity()` will revert |
| **Non-Malicious Decimals** | Assumes standard decimals (6, 8, 18); extremely unusual decimals may cause rounding errors | Slippage protection catches most rounding issues; manual review recommended for <6 decimal tokens |

### Oracle assumptions

| Assumption | Source | Staleness Bound | Impact |
|-----------|--------|-----------------|--------|
| **Aerodrome Gauge Validity** | Aerodrome Voter contract (`voter.isAlive(gauge)`) | Gauge must be alive at vote-cast time | If gauge is killed before voting, `castVotes()` reverts; admin must select new gauge |
| **Voting Power Accuracy** | VotingEscrow (`votingEscrow.balanceOfNFT(tokenId)`) | Read at lock-time; no staleness check | Voting power is frozen at lock-time; subsequent VE balance changes do not affect contribution |
| **Bribe Distribution Accuracy** | Aerodrome Voter (`voter.claimBribes()`, `voter.claimFees()`) | Bribes finalized after voting epoch ends | If claim occurs too early (same epoch), some bribes may not be available; revert caught and ignored |
| **Router Swap Quotes** | Aerodrome Router (`router.getAmountsOut()`) | Quote valid only at time of call; no chainlink oracle | Slippage protection (default 5%) mitigates sandwich attacks; quote freshness depends on block time |

### Liquidity/MEV/DoS assumptions

| Assumption | Risk | Mitigation |
|-----------|------|-----------|
| **Sufficient WETH Liquidity on Base** | If WETH is illiquid, bribe swaps may fail or incur high slippage | Aerodrome Router has stable WETH pairs; fallback to stable swap if volatile fails |
| **Keeper Availability** | If batch operations stall (keeper goes down), pool stuck in Voting or Finalizing | Admin can call batch functions manually; no hard dependency on keeper |
| **MEV on Finalization** | Sandwich attacks during `completeFinalization()` (large swaps + LP creation) | Slippage tolerance (5% default) protects; admin can adjust via `setSwapSlippage()` |
| **Gas Limit on Large Batches** | If 100+ NFTs and batch size set too high, single tx exceeds gas block limit | MAX_BATCH_SIZE = 50; batches split over multiple txs; keeper ensures safe batch sizing |
| **Bribe Token Volatility** | Bribe tokens (e.g., alt-L1 tokens) may be illiquid on Base | Swap failures caught silently; stuck tokens recoverable via `rescueTokens()` |


## Upgradeability & Initialization

### Pattern

**None — Immutable Deployment**

All contracts are deployed as immutable instances:
- KickoffFactory is a singleton deployed once per protocol
- Each KickoffVoteSalePool is unique per project; no proxy
- LPLocker is a singleton deployed once per protocol (embedded in factory)
- All external contract addresses (Aerodrome, WETH) are immutable constructor arguments

### Initialization path

1. **Factory deployment:** Constructor called with Aerodrome contract addresses
   - No proxy; contract lives at deployment address forever
   - LPLocker deployed as new instance within factory constructor
2. **Pool deployment:** Factory.createPool() deploys new KickoffVoteSalePool instance
   - Constructor parameters set all immutable state (addresses, allocations)
   - Pool initialized in `Inactive` state
3. **Pool activation:** Admin calls pool.activate() once per epoch
   - Transition to `Active` state; records activation epoch
   - Can be called multiple times if admin wishes to extend (resets state)

### Re-initialization protections

- **No initialize() function:** All setup happens in constructor; no re-initialization possible
- **State machine enforcement:** Pool cannot return to earlier states; `activate()` allowed only from `Inactive` state
- **Immutable addresses:** All external contract references are immutable; cannot be swapped mid-stream

### Upgrade implications

Since contracts are immutable:
- **Code bug discovered:** Requires new factory + pool deployment; old contracts remain in state they were left
- **Parameter change needed (e.g., slippage):** Only possible if not yet activated (can activate new pool); once active, requires pool-specific setters (e.g., `setSwapSlippage()`)
- **Aerodrome contract upgrade:** If Aerodrome upgrades their contracts, new pools must specify new address in factory deployment; old pools pinned to old addresses


## Parameters & Admin Procedures

### Config surface

| Parameter | Type | Safe Range | Default | Who Sets | When | Impact |
|-----------|------|-----------|---------|----------|------|--------|
| `swapSlippageBps` | `uint256` | 0–5000 (0–50%) | 500 (5%) | Pool admin | Anytime | Determines min output for bribe→WETH swap; too high = MEV risk; too low = swap may fail |
| `liquiditySlippageBps` | `uint256` | 0–5000 (0–50%) | 500 (5%) | Pool admin | Anytime | Determines min amounts for addLiquidity; too high = capital loss; too low = LP creation may fail |
| `totalAllocation` | `uint256` | 1–1M USDC equiv. | Admin-specified | Project admin | At pool creation | Total project tokens deposited; split 50/50 into sale and liquidity |
| `activeEpoch` | `uint256` | Current epoch or later | Set at activate() | Admin (implicit) | At activate() | Aerodrome voting epoch; votes only count if cast in this epoch |

### Authorized actors and processes

| Change | Actor | Mechanism | Timelock | Constraints |
|--------|-------|-----------|----------|-------------|
| **Pool creation** | Project admin | Calls factory.createPool(); factory validates | None | No duplicate projects; tokens transferred immediately |
| **Pool activation** | Pool admin | Calls pool.activate(); state machine enforces | None | Only from Inactive state; can be called per-epoch |
| **Slippage adjustment** | Pool admin | Calls setSwapSlippage() or setLiquiditySlippage() | None | Max 50%; checked at call time |
| **Gauge selection** | Pool admin | Implicit in castVotes(gauge) call; immutable once set | None | Gauge must be alive; validated at vote-cast time |
| **NFT emergency withdrawal** | Pool owner (admin or successor) | Calls emergencyWithdrawNFT() or emergencyWithdrawBatch(); no state checks | None | Pool owner can transfer ownership via 2-step transfer |
| **Factory ownership** | Factory owner | Calls factory.transferOwnership() + acceptOwnership() | None | 2-step transfer; pending owner must accept |
| **Pool ownership** | Pool owner (admin) | Calls pool.transferOwnership() + acceptOwnership() | None | 2-step transfer; pending owner must accept |

### Runbooks

#### **Pause / Unpause (N/A)**
No pause mechanism exists. To freeze a pool:
1. Leave in current state without calling transition functions
2. If pool is stuck in Finalizing (batch in progress), call emergencyWithdrawNFTs() to unwind

#### **Rotate Pool Owner**
1. Current owner calls `pool.transferOwnership(newOwner)`
2. newOwner receives pending ownership
3. newOwner calls `pool.acceptOwnership()`
4. Ownership transferred; previous owner loses emergency control

#### **Recover Stuck Tokens**
1. Admin identifies stuck token (e.g., failed swap left bribe token on contract)
2. Admin calls `pool.rescueTokens(token, recipient, amount)`
3. Tokens transferred to recipient (cannot rescue projectToken)

#### **Recover Stuck NFT**
1. Pool owner calls `pool.emergencyWithdrawNFT(tokenId)` or `pool.emergencyWithdrawBatch(batchSize)`
2. NFT returned to original owner
3. State unchanged; does not trigger any phase transitions

#### **Recover Stuck LP (N/A)**
LP tokens are locked permanently in LPLocker by design. No recovery mechanism.


## External Integrations

### Addresses / versions (Base mainnet)

| Contract | Address | Purpose | Version / Standard |
|----------|---------|---------|-------------------|
| **VotingEscrow (veAERO)** | `0xeBf418Fe2512e7E6bd9b87a8F0f294aCDC67e6B4` | NFT-based governance token; holds user voting power | ERC721 + custom veAERO logic |
| **Voter** | `0x16613524e02ad97eDfeF371bC883F2F5d6C480A5` | Voting & bribe distribution; claims bribes from gauges | Aerodrome Voter v1 |
| **Router** | `0xcF77a3Ba9A5CA399B7c97c74d54e5b1Beb874E43` | Token swaps & liquidity provision | Aerodrome Router v1 (no TWAP oracle) |
| **WETH (Wrapped ETH)** | `0x4200000000000000000000000000000000000006` | Canonical wrapped Ether on Base | ERC20 standard |
| **Project Token** | User-specified | Project's ERC20 token | Any ERC20 (with caveats on fee-on-transfer) |
| **Aerodrome Pool** | Derived from Router | Volatile pool for Project/WETH pair | Aerodrome pool (concentrated liquidity v1) |

### Failure assumptions and mitigations

| Failure Mode | Root Cause | Impact | Mitigation |
|-------------|-----------|--------|-----------|
| **Gauge Killed During Voting** | Aerodrome governance kills gauge before epoch end | castVotes() reverts | Admin must select new gauge; revote with castVotes(newGauge) |
| **Bribe Claim Fails** | Bribe contract has insufficient balance or is paused | Some bribes not claimed | Try/catch in claimBribes/claimFees; use rescueTokens() for leftover tokens |
| **Swap Fails (Liquidity)** | Bribe token has no WETH pair or zero liquidity | convertToWETH() catches exception; token stays on contract | Use rescueTokens() to recover token; manual swap off-chain or retry with different slippage |
| **addLiquidity Fails** | Insufficient balance, slippage exceeded, or pair doesn't exist | LP creation reverts; WETH + projectToken left on contract | Increase slippage via setLiquiditySlippage(); manually provide liquidity; rescue tokens |
| **veAERO Transfer Fails** | VotingEscrow contract bug or NFT frozen | lockVeAERO() or unlockVeAERO() reverts | Contact Aerodrome support; deploy new pool; manual NFT recovery |
| **WETH Transfer Fails** | Canonical WETH paused or removed | finalizeEpoch() reverts at LP creation | Extremely unlikely on Base; fallback to use alternative stable coin if available |
| **Router Contract Removed** | Aerodrome sunsetting old router | finalizeEpoch() reverts; new factory must specify new router address | Factory immutable; new pools use new router; old pools cannot be finalized |

### Cross-contract call ordering

1. `lockVeAERO()` → `votingEscrow.safeTransferFrom()` (user's NFT to pool) + internal state update
2. `castVotes()` → `voter.vote(tokenId, [gauge], [weights])` for each NFT
3. `finalizeEpoch()` → `voter.claimBribes()`, `voter.claimFees()` → `router.swapExactTokensForTokens()` → `router.addLiquidity()` → `lpLocker.lockLP()`
4. `claimTradingFees()` (LPLocker) → `IPool(aerodromePool).claimFees()` → `IERC20.transfer()`

All interactions are external calls with proper error handling (try/catch where appropriate).


## Build, Test & Reproduction

### Environment prerequisites

| Component | Version | Install | Verify |
|-----------|---------|---------|--------|
| **OS** | Ubuntu 24.04 LTS (Linux) | N/A | `uname -a` |
| **Foundry** | Latest (>=0.2.0) | `curl -L https://foundry.paradigm.xyz \| bash && foundryup` | `forge --version` |
| **Solidity** | ^0.8.24 | Installed with Foundry | `solc --version` |
| **Node.js** | 18+ (optional, for scripts) | `apt-get install nodejs npm` | `node --version` |
| **Git** | 2.0+ | `apt-get install git` | `git --version` |

### Clean-machine setup

```bash
# 1. Clone repository
git clone https://github.com/kickoffbase/kickoff-contracts.git
cd kickoff-contracts

# 2. Install Foundry (if not present)
curl -L https://foundry.paradigm.xyz | bash
source ~/.bashrc
foundryup

# 3. Verify Foundry
forge --version
cast --version

# 4. Install Solidity dependencies
forge install

# 5. Copy environment template
cp .env.example .env
# Edit .env and fill in:
#   - BASE_RPC_URL (e.g., https://mainnet.base.org)
#   - BASESCAN_API_KEY (for contract verification, optional)

# 6. Verify project setup
forge build
```

Expected output:
```
Compiling 12 files with 0.8.24
Solc 0.8.24 finished in 2.45s
Compiler run successful!
```

### Build

```bash
# Standard build
forge build

# Build with optimizer (default, 200 runs)
forge build --optimize

# Build in debug mode (unoptimized)
FOUNDRY_PROFILE=debug forge build

# Check for compile errors
forge build 2>&1 | grep -i error
```

**Expected output:** No errors; 12 files compiled; gas snapshot may vary.

### Tests

```bash
# Run all tests locally (unit + integration)
forge test

# Run with verbose output (show test names, gas used)
forge test -vv

# Run with very verbose output (show console logs + revert reasons)
forge test -vvv

# Run a single test file
forge test --match-path test/KickoffVoteSalePool.t.sol

# Run a single test function
forge test --match-test test_LockVeAERO

# Run with fork (Base mainnet) — requires BASE_RPC_URL set in .env
forge test --fork-url $BASE_RPC_URL -vvv

# Run fork tests only
forge test --match-path test/integration/FullFlow.t.sol --fork-url $BASE_RPC_URL

# Run with coverage (requires lcov)
forge coverage

# Run with gas reporting
forge test --gas-report
```

**Expected test output:**
```
[PASS] test/KickoffFactory.t.sol::KickoffFactoryTest::test_CreatePool (success in X ms)
[PASS] test/KickoffVoteSalePool.t.sol::KickoffVoteSalePoolTest::test_LockVeAERO (success in X ms)
...
Test result: ok. X passed; 0 failed; 0 skipped; Y ms gas metering
```

### Coverage

```bash
# Generate coverage report (requires lcov: apt-get install lcov)
forge coverage --report lcov

# Generate HTML report
genhtml lcov.info -o coverage && open coverage/index.html
```

Target coverage: >90% for core functions; >80% overall.

### Reproduction checklist

- [ ] Clone repo, run `forge build` — no errors
- [ ] Run `forge test` — all tests pass
- [ ] Run `forge test --fork-url $BASE_RPC_URL` — integration tests pass (requires live RPC)
- [ ] No hardcoded addresses in contracts (all constructor-parameterized)
- [ ] No private keys in repo or .env (use .env.example)


## Known Issues & Areas of Concern

### Known limitations

1. **No Pause Mechanism**
   - Pool transitions cannot be reversed once activated
   - **Mitigation:** Ensure careful testing before activation; use emergency withdrawal if needed
   - **Trade-off:** Simpler design; no admin tyranny risk

2. **Batch Operations Must Complete Sequentially**
   - If a batch is in progress (e.g., castVotes), new operations block until complete
   - **Mitigation:** Keeper monitors batchInProgress; calls operations in correct order
   - **Trade-off:** Prevents concurrent execution; simpler state management

3. **Bribe Token List Is Manual Input**
   - Admin must pre-fetch and pass bribe token list to finalizeEpoch()
   - Missing tokens are not claimed; admin must rescueTokens() later
   - **Mitigation:** Off-chain keeper provides accurate list; recommend querying Aerodrome Voter API
   - **Trade-off:** Simplicity; no automatic bribe discovery (which would add complexity)

4. **No Slippage Protection on Bribe Claims**
   - Claimed bribe amounts are not guaranteed; Aerodrome distributes available balance
   - **Mitigation:** Slippage on swaps (5% default) absorbs minor bribe shortfalls
   - **Trade-off:** Accepted; bribe amounts are outputs not inputs

5. **LP Tokens Permanently Locked**
   - Once locked in LPLocker, LP capital is frozen forever (intentional design)
   - No partial unlock or withdrawal mechanism
   - **Mitigation:** Design intent; perpetual capital ensures sustainable fee stream
   - **Trade-off:** Permanent lock; cannot recapture liquidity

6. **Voting Power Frozen at Lock Time**
   - User's contribution is recorded at lockVeAERO() time; subsequent VE balance changes do not affect share
   - **Mitigation:** Recommend users lock immediately before voting if they expect balance increase
   - **Trade-off:** Simplicity; no need for oracle feeds on VE balance

7. **Fee-on-Transfer Tokens Not Fully Supported**
   - Factory checks balance delta; reverts if insufficient received
   - If project token has 1% transfer fee, only 99% is deposited; pool creation fails unless admin adjusts allocation
   - **Mitigation:** Pre-check token decimals and fee structure; use exact amounts
   - **Trade-off:** Simplicity; no automatic rebasing support

8. **Zero WETH Collected Edge Case**
   - If no bribes are collected (or all swaps fail), `wethCollected == 0` and no LP is created
   - The `liquidityAllocation` (50% of project tokens) remains stuck in the contract permanently
   - `rescueTokens()` explicitly blocks rescuing `projectToken`, so there's no recovery mechanism
   - **Mitigation:** Admin should verify bribe availability before finalizing; consider adding admin rescue for project tokens in edge cases
   - **Trade-off:** Current design prevents admin from draining project tokens maliciously, but sacrifices recovery in edge cases

9. **Zero NFTs Locked Edge Case**
   - Pool can transition through all states (Active → Voting → Finalizing → Completed) with zero NFTs locked
   - Results in: 0 voting power, 0 bribes claimed, 0 WETH collected, 0 LP created
   - 100% of project tokens (both `saleAllocation` and `liquidityAllocation`) remain stuck in the contract
   - **Mitigation:** Admin should verify at least one NFT is locked before calling `castVotes()` or `finalizeEpoch()`
   - **Trade-off:** Design simplicity; no minimum lock requirement enforced on-chain

### Deferred items / TODOs

None identified at freeze commit. All major features implemented and tested.

### Code notes and recommendations

The following notes were embedded in the codebase by the author of the documentation:

- **Use Fuzz Tests**
  - **Recommendation:** Test the full expression of your functions using fuzz testing, verify extremely small values are properly handled. Default to fuzz testing in all senarios by default for functions changing state.

- **KickoffVoteSalePool.sol — `aerodromePool` variable (line 153)**
  - **Note:** This variable stores state that is derived from `gauge` via `voter.poolForGauge(_gauge)`, requiring redundant storage operations.
  - **Recommendation:** Consider computing `aerodromePool` on-the-fly from `gauge` instead of storing it separately to reduce storage costs.

- **KickoffVoteSalePool.sol — `castVotesBatch()` gauge parameter (line 323)**
  - **Note:** Seems unreasonable to have a parameter that's only used on the first call.
  - **Recommendation:** Consider refactoring batch voting to accept gauge only on the initial call, not on every batch continuation.

- **KickoffVoteSalePool.sol — `totalVotingPower` accounting on unlock (line 727)**
  - **Note:** When NFTs are unlocked, `totalVotingPower` is NOT decremented. Voting power remains in pool accounting even after NFT withdrawal.
  - **Recommendation:** Clarify design intent: if voting power should persist for historical tracking, document this explicitly. If it should be decremented, this is an accounting bug.

- **KickoffVoteSalePool.sol — Aerodrome lpToken equality (line 709)**
  - **Note:** In Aerodrome, lpToken address IS the pool address (they're the same contract).
  - **Recommendation:** Ensure this relationship is understood and tested; may impact future integrations if Aerodrome structure changes.

- **LPLocker.sol — Claimable amounts accuracy (line 206)**
  - **Note:** Actual claimable amounts may differ slightly from view function approximations.
  - **Recommendation:** Monitor fee claims for discrepancies between `claimable0()/claimable1()` estimates and actual amounts received.

- **FullFlow.t.sol — Helper function consolidation (line 67)**
  - **Note:** This can be a helper function to cut down on repeat code.
  - **Recommendation:** Extract common test setup/teardown logic into reusable helpers to improve maintainability.

- **FullFlow.t.sol — Mock organization (line 135)**
  - **Note:** Recommend move all mocks into the mocks/ folder for better organization.
  - **Recommendation:** Consolidate mock contracts from test files into centralized `test/mocks/` directory for consistency.

### Audit considerations

- [ ] Verify reentrancy guard on all external functions (no call nesting exploits)
- [ ] Confirm batch loop indices never skip or double-process NFTs
- [ ] Validate epoch calculations match Aerodrome's epoch (Thursday 00:00 UTC)
- [ ] Test edge case: pool created and activated in different epochs; ensure votes count
- [ ] Test large NFT count (1000+) with batch size limit; confirm completion in reasonable tx count
- [ ] Test slippage protection: confirm swap reverts if quote < minOut
- [ ] Verify LPLocker fee distribution: 2000 bps admin, 8000 bps project owner
- [ ] Test emergency withdrawal does not interfere with normal claims
- [ ] Confirm zero-address, zero-amount, and duplicate pool checks in factory
- [ ] Test edge case: finalize with zero NFTs locked; verify tokens are stuck
- [ ] Test edge case: finalize with zero WETH collected (no bribes); verify liquidityAllocation is stuck
- [ ] Verify division by zero protection in `claimProjectTokens()` when `totalVotingPower == 0`


## Appendix

### A. Glossary

| Term | Definition |
|------|-----------|
| **Aerodrome** | DEX protocol on Base; provides gauges, voting, and bribe rewards |
| **Bribe** | Incentive tokens paid to veAERO voters for voting on specific gauges |
| **veAERO** | Vote-escrowed AERO; NFT-based governance token; required to vote on gauges |
| **Gauge** | Aerodrome contract receiving votes; distributes bribes to NFT voters |
| **Epoch** | Weekly period (604800 seconds); voting windows align to epoch boundaries |
| **Volatile Pool** | Aerodrome pool with concentrated liquidity at current price (vs. stable); higher fees, higher impermanence loss |
| **LP Token** | Liquidity provider token; represents share of pool; embedded in Aerodrome pool contract |
| **Reentrancy** | Exploit where function calls itself (directly or indirectly) before state is finalized |
| **Slippage** | Difference between expected and actual swap output; can result from MEV/sandwich attacks |
| **Voting Power** | veAERO NFT's AERO-equivalent balance; used to weight votes and claim bribes |

### B. Test mapping (Test → Flow/Invariant)

| Test File | Test Name | Flow | Invariants Tested | Purpose |
|-----------|-----------|------|------------------|---------|
| KickoffFactory.t.sol | test_CreatePool | Pool Creation | Single pool per token; tokens transferred | Verify pool factory |
| KickoffFactory.t.sol | test_CreatePool_RevertDuplicate | Pool Creation | Reject duplicate pools | Prevent multiple pools per token |
| KickoffVoteSalePool.t.sol | test_LockVeAERO | Voting | NFT ownership, voting power conservation | Verify NFT locking |
| KickoffVoteSalePool.t.sol | test_CastVotes | Voting | Vote execution, state transition | Verify voting phase |
| KickoffVoteSalePool.t.sol | test_CastVotesBatch | Voting | Batch progress, multi-tx voting | Verify batch voting |
| KickoffVoteSalePool.t.sol | test_FinalizeEpoch | Finalization | Token conversion, LP creation | Verify single-tx finalization |
| KickoffVoteSalePool.t.sol | test_FinalizeEpochBatch | Finalization | Batch claim, async finalization | Verify batch finalization |
| KickoffVoteSalePool.t.sol | test_ClaimProjectTokens | Claim | Pro-rata token distribution | Verify user claims |
| KickoffVoteSalePool.t.sol | test_UnlockVeAERO | Claim | NFT return, state finality | Verify NFT unlock |
| KickoffVoteSalePool.t.sol | test_EmergencyWithdraw | Emergency | NFT recovery, state bypass | Verify emergency safety |
| LPLocker.t.sol | test_ClaimTradingFees | Fee Distribution | Fee split (20/80), claim authorization | Verify fee distribution |
| LPLocker.t.sol | test_LPLocked | Fee Distribution | LP immutability, permanent lock | Verify LP permanence |
| integration/FullFlow.t.sol | test_Fork_FactoryDeployment | Pool Creation | External contract integration | Verify factory on Base fork |
| integration/FullFlow.t.sol | test_Fork_PoolActivation | Pool Creation | State transition on fork | Verify activation on Base |

### C. Diagram index

- [Pool Lifecycle](./diagrams/flow_pool_lifecycle.md) — State machine and phase transitions
- [Voting Phase](./diagrams/flow_voting.md) — Lock NFTs, cast votes
- [Finalization Phase](./diagrams/flow_finalization.md) — Claim bribes, create liquidity, lock LP
- [Claim Phase](./diagrams/flow_claim.md) — Claim project tokens, unlock NFTs
- [Emergency Withdrawal](./diagrams/flow_emergency.md) — Force-return NFTs


## Document Metadata

| Property | Value |
|----------|-------|
| **Prepared for** | Security Auditors |
| **Commit Freeze** | `c6cdea7` (main branch, Dec 2024) |
| **Scope** | src/, test/ (unit + integration tests) |
| **Out of Scope** | Aerodrome protocol internals; Base network security |
| **Last Updated** | December 2024 |
| **Review Cadence** | Update on significant code changes or new versions |


**End of Audit Document**
