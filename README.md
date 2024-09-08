# OmniVault

OmniVault is a cross-chain yield optimizer for USDC, leveraging Chainlink's Cross-Chain Interoperability Protocol (CCIP) and the ERC4626 vault standard. It dynamically finds the best yield across Aave on Base, Arbitrum, Optimism, and Sepolia, and automatically rebalances assets for maximum returns.

## Features

- **Cross-Chain Yield Optimization**: Automatically finds and optimizes yield across multiple chains.
- **Automated Rebalancing**: Uses Chainlink CCIP to bridge assets and reallocate them to the chain offering the best returns.
- **ERC4626 Standard**: Follows the ERC4626 vault standard for compatibility with existing DeFi infrastructure.
- **Seamless User Experience**: Simple deposit and withdrawal processes with automated yield management.

## Usage

### Build

```shell
$ forge build
```

### Test

```shell
$ forge test
```

### Format

```shell
$ forge fmt
```
