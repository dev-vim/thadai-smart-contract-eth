#!/bin/bash

# Deploy ThadaiCore to local Anvil instance
# Make sure Anvil is running before executing this script

RPC_URL="http://localhost:8545"
PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

echo "Deploying ThadaiCore to Anvil..."
echo "RPC URL: $RPC_URL"
echo ""

forge script script/DeployThadaiCoreAnvil.s.sol:DeployThadaiCoreAnvil \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast

echo ""
echo "Deployment complete!"
echo "Check the output above for the contract address."

