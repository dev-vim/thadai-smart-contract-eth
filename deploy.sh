#!/bin/bash

# Deploy ThadaiCoreV1 to local Anvil instance
# Make sure Anvil is running before executing this script

RPC_URL="http://localhost:8545"
PRIVATE_KEY="0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"

echo "Deploying ThadaiCoreV1 to Anvil..."
echo "RPC URL: $RPC_URL"
echo ""

forge script script/DeployThadaiCoreV1.s.sol:DeployThadaiCoreV1 \
  --rpc-url $RPC_URL \
  --private-key $PRIVATE_KEY \
  --broadcast

echo ""
echo "Deployment complete!"
echo "Check the output above for the contract address."

