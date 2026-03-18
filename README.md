<p align="center">
   <img src="img/logo_transparent_bg_1000px.png" alt="Thadai Logo" height="300" />
</p>

# Thadai Smart Contract

The **Thadai Smart Contract** (`ThadaiCore`) is the decentralized access control engine powering the Thadai productivity ecosystem. It enables blockchain-based, time-limited access to restricted web resources, creating a financial incentive for users to stay focused and avoid distractions.

## Key Features

- **Time-Based Access Control**: Users can purchase access time to blocked websites by sending ETH to the contract. Access is granted for the purchased duration only.
- **On-Chain Payments**: All access purchases and withdrawals are handled on-chain, ensuring transparency and decentralization.
- **Configurable Pricing**: Access pricing, minimum payment, and withdrawal cooldowns are settable via contract parameters.
- **Self-Service Withdrawals**: Users can withdraw unused balances after a cooldown period.
- **Event Emission**: Emits events for access purchases, withdrawals, and configuration changes for easy off-chain monitoring.

## Usage

This contract is designed to be deployed on any EVM-compatible blockchain and can support access-control for various applications, such as the [Thadai Chrome Extension](https://github.com/dev-vim/thadai-chrome-extension/tree/main).

This smart contract can be integrated into applications that require time-limited access control, such as productivity tools, content platforms, or subscription services.

### Build & Test

```sh
forge build
forge test
```

### Local Deployment (with Anvil)

See [DEPLOY.md](./DEPLOY.md) for detailed deployment instructions using Foundry and Anvil.

### Interacting

- Use the Thadai Chrome Extension for end-user interaction.
- Use `cast` or any ethers-compatible tool for direct contract calls.

## Contract Overview

- `purchaseAccess()`: Pay ETH to buy access time.
- `checkAccess(address)`: View function to check if a user has active access and remaining time.
- `withdrawFunds()`: Withdraw unused balance after cooldown.
- `getAccessPricingInfo()`: View function for pricing and cooldown parameters.
