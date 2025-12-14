# Kickoff Security & Audit Documentation

This directory contains comprehensive security documentation and audit materials for the Kickoff veAERO Sale Contracts.

## Contents

### Main Documentation

- **[AUDIT_DOC.md](./AUDIT_DOC.md)** — Complete audit document for external security reviewers
  - System summary, architecture overview, and trust model
  - Comprehensive actor/role table with access controls
  - 5 primary user flows with diagrams, preconditions, and edge cases
  - State invariants, assumptions, and security properties
  - Build/test reproduction steps
  - Known issues and areas of concern
  - Test mapping and coverage analysis
  - Glossary of terms

### Diagrams

User flows are illustrated with Mermaid diagrams in `./diagrams/`:

| Diagram | Purpose |
|---------|---------|
| [flow_pool_lifecycle.md](./diagrams/flow_pool_lifecycle.md) | State machine: Inactive → Active → Voting → Finalizing → Completed |
| [flow_voting.md](./diagrams/flow_voting.md) | NFT locking and vote casting (single & batch) |
| [flow_finalization.md](./diagrams/flow_finalization.md) | Reward claiming, token conversion, LP creation & lock |
| [flow_claim.md](./diagrams/flow_claim.md) | Project token claims, NFT unlock, trading fee distribution |
| [flow_emergency.md](./diagrams/flow_emergency.md) | Emergency withdrawal procedures (single, batch, all-at-once) |

### Test Mapping

- **[test-matrix.csv](./test-matrix.csv)** — Mapping of user flows, invariants, and specific tests
  - Maps each flow/invariant to test files and functions
  - Aids in understanding test coverage and validation strategy

## Quick Start for Auditors

### Read the Audit Document
Start with [AUDIT_DOC.md](./AUDIT_DOC.md) for a complete overview. Key sections:
- **Summary**: What the system does, who uses it, how it works
- **Actors & Roles**: Access control and emergency procedures
- **User Flows**: Five primary workflows with linked diagrams
- **Invariants**: Safety properties that must hold

### Review Diagrams
Follow the user flows in `./diagrams/` to understand the state machine and interactions:
- Start with [flow_pool_lifecycle.md](./diagrams/flow_pool_lifecycle.md) for the big picture
- Drill into specific flows (voting, finalization, claims)

### Examine Tests
Consult [test-matrix.csv](./test-matrix.csv) to find tests that exercise each invariant and flow.

### Environment Setup
```bash
# Clone and install
git clone https://github.com/kickoffbase/kickoff-contracts.git
cd kickoff-contracts

# Install Foundry if needed
curl -L https://foundry.paradigm.xyz | bash && source ~/.bashrc && foundryup

# Install dependencies and build
forge install
forge build

# Run tests locally
forge test -vv

# Run with fork (if BASE_RPC_URL is set)
BASE_RPC_URL=https://mainnet.base.org forge test --fork-url $BASE_RPC_URL -vv
```

### Use the Test Script
```bash
# Run full CI locally
bash scripts/ci-local.sh

# Include fork tests
bash scripts/ci-local.sh --fork

# Generate coverage report
bash scripts/ci-local.sh --fork --coverage
```

## Commit Freeze

**Freeze Point:** Commit `c6cdea7` (Dec 2024)  
**Branch:** `main`  
**Scope:** All files in `src/` and `test/` directories  
**External Dependencies:**
- Foundry (solc ^0.8.24)
- Aerodrome protocol (Base mainnet contracts, unchanged)
- Base network

No breaking changes to frozen contracts; all safety properties frozen as of this commit.

## Key Safety Properties

| Property | Status | Evidence |
|----------|--------|----------|
| **State Machine Linearity** | ✓ Enforced | `inState()` modifiers; no state reversion |
| **NFT Ownership Conservation** | ✓ Enforced | Locked NFTs tracked; returned only to original owner |
| **Voting Power Accounting** | ✓ Enforced | Atomic updates to user & total on lock |
| **Single Claim Per User** | ✓ Enforced | `claimed` flag prevents double-claim |
| **LP Lock Finality** | ✓ Enforced | LPLocker has no unlock; permanent by design |
| **Reentrancy Safety** | ✓ Enforced | `nonReentrant` guards on critical functions |
| **Access Control** | ✓ Enforced | Role-based modifiers (admin, owner); 2-step transfers |
| **Slippage Bounds** | ✓ Enforced | Max 50% slippage; default 5% |

## External Audits & References

None prior. This is the initial freeze for external audit.

## Contact

For questions about this documentation, contact the Kickoff protocol team.