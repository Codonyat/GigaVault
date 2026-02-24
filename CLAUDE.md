# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

GigaVault is a Solidity smart contract project implementing an ERC20 token (USDmZ) backed by USDmY (from Avon) with daily lottery mechanics and auction-based fee distribution. The token uses a 1:1 ratio (both 18 decimals) and implements a 1% fee structure on all operations.

## Development Commands

### Build

```bash
forge build
```

### Run Tests

```bash
forge test
# Run specific test
forge test --match-test testMintingWithFee
# Run with verbosity for debugging
forge test -vvv
```

### Deploy

```bash
# Requires PRIVATE_KEY environment variable
forge script script/Deploy.s.sol --rpc-url mega_mainnet --broadcast
```

### Clean Build

```bash
forge clean && forge build
```

## Architecture Overview

### Core Contract Structure

- **Main Contract**: `src/GigaVault.sol` - Inherits from OpenZeppelin's ERC20, ReentrancyGuardTransient, and Ownable2Step
- **Fee System**: 1% total fee split into 30% lottery pool and 70% auction pool
- **Ownership**: Uses Ownable2Step; owner receives unclaimed prizes. renounceOwnership() is disabled
- **Holder Tracking**: Uses Fenwick tree (Binary Indexed Tree) for O(log n) cumulative balance queries, enabling efficient lottery winner selection
- **Randomness**: Uses prevrandao for lottery winner selection

### Key Design Patterns

1. **Synthetic Addresses**: Uses hardcoded addresses for FEES_POOL and LOT_POOL to track fee distributions
2. **Fenwick Tree Implementation**: Maintains cumulative holder balances for efficient random selection from total supply
3. **Time-based Phases**:
   - 3-day initial minting period with unlimited supply
   - After minting period: fixed max supply based on initial deposits
   - Daily lottery cycles with 25-hour pseudo-days
4. **Fail-Fast Philosophy**: Avoid defensive coding patterns that hide errors
5. **Code Simplicity**: Prioritize clarity and efficiency
6. **Storage Optimization**: Apply variable packing when it reduces storage reads (SLOADs)

### External Dependencies

- **OpenZeppelin Contracts**: ERC20, ReentrancyGuardTransient, Ownable2Step
- **USDmY Token**: ERC20 token at 0x2eA493384F42d7Ea78564F3EF4C86986eAB4a890 (Avon's stablecoin on MegaETH)
- **Forge-std**: Testing framework and utilities

## Testing Strategy

Tests are located in `test/` directory and use Foundry's testing framework. Key test areas:

- Minting and redemption with fee calculations
- Lottery winner selection using Fenwick tree
- Auction mechanics with bidding and finalization
- Ownership transfer and renounce prevention
- Edge cases around time transitions and phase changes
- **Test Debugging Priority**: When tests fail, first verify the test logic is correct before assuming contract bugs

## Important Implementation Details

1. **Fenwick Tree Updates**: When balances change, the contract updates the Fenwick tree to maintain cumulative sums for lottery selection
2. **Smart Contract Exclusion**: Smart contracts are excluded from lottery participation (only EOAs can win)
3. **Fee Minting During Initial Period**: During the 3-day minting period, fees are also minted as new tokens rather than redistributed
4. **Redemption Creates Capacity**: After minting period ends, burning tokens creates capacity for new mints up to the original max supply
5. **Unclaimed Prizes**: Owner (via Ownable2Step) receives unclaimed prizes as USDmY after conversion from USDmZ
