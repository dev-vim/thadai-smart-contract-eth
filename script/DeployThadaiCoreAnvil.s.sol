// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Script, console} from "forge-std/Script.sol";
import {ThadaiCore} from "../src/ThadaiCore.sol";
import {MockV3Aggregator} from "../test/MockV3Aggregator.sol";
import {DeployThadaiCore} from "./DeployThadaiCore.s.sol";

/// @notice Deploys MockV3Aggregator + ThadaiCore to a local Anvil chain.
///         Usage:
///           anvil --port 7777 --dump-state ./state.json
///           forge script script/DeployThadaiCoreAnvil.s.sol --rpc-url http://localhost:7777 --broadcast
///         Then Ctrl-C Anvil to write state.json.
contract DeployThadaiCoreAnvil is Script {
    uint8 public constant MOCK_DECIMALS = 8;
    int256 public constant MOCK_ETH_PRICE = 220000000000; // $2,200

    // Same pricing constants as DeployThadaiCore (production)
    uint256 public constant BASE_ACCESS_PRICE_USD = 138888; // $0.00138888/sec (8-dec)
    uint256 public constant MINIMUM_PAYMENT_USD = 200000000; // $2.00 (8-dec)
    // Stale threshold set very high for local testing — the mock feed never truly goes stale,
    // and Anvil's block.timestamp jumps to wall-clock time on reload.
    uint256 public constant STALE_PRICE_THRESHOLD = 365 days;
    uint16 public constant WITHDRAW_COOLDOWN_PERIOD_IN_DAYS = 1;
    uint16 public constant INFLATION_WINDOW_IN_HOURS = 1;
    uint16 public constant INFLATION_PERCENT_PER_WINDOW = 10;

    function run() external {
        vm.startBroadcast();

        // 1. Deploy mock Chainlink price feed
        MockV3Aggregator mockPriceFeed = new MockV3Aggregator(MOCK_DECIMALS, MOCK_ETH_PRICE);
        console.log("MockV3Aggregator deployed at:", address(mockPriceFeed));

        // 2. Deploy ThadaiCore with the mock feed
        ThadaiCore thadaiCore = new ThadaiCore(
            BASE_ACCESS_PRICE_USD,
            MINIMUM_PAYMENT_USD,
            address(mockPriceFeed),
            STALE_PRICE_THRESHOLD,
            WITHDRAW_COOLDOWN_PERIOD_IN_DAYS,
            INFLATION_WINDOW_IN_HOURS,
            INFLATION_PERCENT_PER_WINDOW
        );
        console.log("ThadaiCore deployed at:", address(thadaiCore));

        vm.stopBroadcast();
    }
}
