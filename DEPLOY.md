<p align="center">
   <img src="img/logo_transparent_bg_1000px.png" alt="Thadai Logo" height="300" />
</p>

# Deploying ThadaiCore

This guide will walk you through deploying the ThadaiCore contract to a local Anvil instance. To deploy to a testnet or mainnet, adjust the RPC URL and private key accordingly.

## Prerequisites

- Foundry (Forge, Anvil) installed
- Anvil running locally

## Step 1: Start Anvil

Open a terminal and start Anvil (default runs on `http://localhost:8545`):

```bash
anvil
```

You should see output like:
```
Available Accounts
==================

(0) 0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 (10000 ETH)
Private Keys
==================

(0) 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80
```

**Keep this terminal running** - Anvil needs to stay active.

## Step 2: Deploy the Contract

Open a **new terminal** and navigate to the smart contract directory:

```bash
cd thadai-smart-contract
```

Deploy the contract using Forge:

```bash
forge script script/DeployThadaiCore.s.sol:DeployThadaiCore \
  --rpc-url http://localhost:8545 \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --broadcast
```

### What this does:

- `--rpc-url http://localhost:8545`: Points to your local Anvil instance
- `--private-key ...`: Uses the first Anvil account's private key (this account has 10000 ETH by default)
- `--broadcast`: Actually deploys the contract (without this, it only simulates)

### Deployment Parameters

The contract will be deployed with these constructor parameters (defined in `DeployThadaiCore.s.sol`):

- **Base Access Price USD** — Price per second of access (8-decimal scale)
- **Minimum Payment USD** — Minimum payment required (8-decimal scale)
- **Price Feed Address** — Chainlink ETH/USD oracle
- **Withdrawal Cooldown** — Days between withdrawals
- **Inflation Window** — Hours within which inflation applies
- **Inflation Percent** — Price increase for rapid re-purchases

## Step 3: Verify Deployment

After deployment, you should see output like:

```
== Logs ==
  0: contract ThadaiCore 0x5b73C5498c1E3b4dbA84de0F1833c4a029d90519

## Setting up 1 EVM.

==========================

Chain 31337

Estimated gas price: 1.000876068 gwei
Estimated total gas used for script: 1010483
Estimated amount required: 0.001011368251820844 ETH

==========================

SIMULATION COMPLETE.
```

The contract address will be displayed (e.g., `0x5b73C5498c1E3b4dbA84de0F1833c4a029d90519`).

### Verify the Contract

You can verify the contract was deployed by calling a view function:

```bash
cast call <CONTRACT_ADDRESS> "getContractBalance()" --rpc-url http://localhost:8545
```

This should return `0x0000000000000000000000000000000000000000000000000000000000000000` (zero balance initially).

## Step 4: Update Extension Configuration

Make sure the contract address in your Chrome extension matches the deployed address.

## Troubleshooting

### "Connection refused" error

- Make sure Anvil is running
- Verify Anvil is on port 8545: `anvil --port 8545`
- Check the RPC URL matches: `http://localhost:8545`

### "Insufficient funds" error

- Anvil accounts start with 10000 ETH, so this shouldn't happen
- If it does, check you're using the correct private key

### Contract address mismatch

- The contract address is deterministic based on deployer and nonce
- If you restart Anvil, the address will change (unless you use `--fork` or save state)
- Update the address in your extension configuration

### "No contract code found" error

- Verify the contract was actually deployed (check the deployment output)
- Confirm the address is correct
- Try calling a view function to verify the contract exists

## Quick Deploy Script

You can also create a simple bash script to deploy:

```bash
#!/bin/bash
# deploy.sh

RPC_URL="http://localhost:8545"
PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

forge script script/DeployThadaiCore.s.sol:DeployThadaiCore \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast
```

Make it executable and run:

```bash
chmod +x deploy.sh
./deploy.sh
```

## Notes

- **Anvil State**: Anvil's state is ephemeral - if you restart Anvil, all deployed contracts are lost
- **Persistent State**: To persist state, you can use Anvil's `--state` flag or fork a mainnet/testnet
- **Contract Address**: The address may vary if you've deployed other contracts first (nonce-based)
- **Testing**: After deployment, you can test purchasing access using the extension or directly via cast/forge

## Deploying to Sepolia Testnet

### Prerequisites

- **Sepolia ETH** from a faucet (e.g. sepoliafaucet.com or Alchemy's faucet)
- **Sepolia RPC URL** from Alchemy, Infura, or another provider
- **Etherscan API key** (optional, for contract verification)

### Deploy

```bash
forge script script/DeployThadaiCore.s.sol:DeployThadaiCore \
  --rpc-url <YOUR_SEPOLIA_RPC_URL> \
  --private-key <YOUR_PRIVATE_KEY> \
  --broadcast \
  --verify \
  --etherscan-api-key <YOUR_ETHERSCAN_API_KEY>
```

The deploy script uses the Sepolia Chainlink ETH/USD feed (`0x694AA1769357215DE4FAC081bf1f309aDC325306`) by default.

### Verify Deployment

```bash
# Check contract config
cast call <CONTRACT_ADDRESS> "baseAccessPriceUSD()(uint256)" --rpc-url <YOUR_SEPOLIA_RPC_URL>

# Check live pricing (returns basePriceWei, minimumPaymentWei, baseAccessPriceUSD, minimumPaymentUSD, ethPriceUSD)
cast call <CONTRACT_ADDRESS> "getAccessPricingInfo()(uint256,uint256,uint256,uint256,uint256)" --rpc-url <YOUR_SEPOLIA_RPC_URL>

# Purchase access (adjust value based on getAccessPricingInfo minimumPaymentWei)
cast send <CONTRACT_ADDRESS> "purchaseAccess()" --value 0.02ether --rpc-url <YOUR_SEPOLIA_RPC_URL> --private-key <YOUR_PRIVATE_KEY>

# Check access status
cast call <CONTRACT_ADDRESS> "checkAccess(address)(bool,uint256)" <YOUR_ADDRESS> --rpc-url <YOUR_SEPOLIA_RPC_URL>
```

> **Security:** Never commit private keys or API keys to the repository. Use environment variables or a `.env` file (already in `.gitignore`).

## Testing the Deployment

Once deployed, you can test by purchasing access:

```bash
# Purchase access with 0.001 ETH
cast send 0x5b73C5498c1E3b4dbA84de0F1833c4a029d90519 \
  "purchaseAccess()" \
  --value 0.001ether \
  --private-key 0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80 \
  --rpc-url http://localhost:8545

# Check access
cast call 0x5b73C5498c1E3b4dbA84de0F1833c4a029d90519 \
  "checkAccess(address)" \
  0xf39Fd6e51aad88F6F4ce6aB8827279cffFb92266 \
  --rpc-url http://localhost:8545
```

This should return `(bool, uint256)` indicating if the user has access and remaining seconds.

