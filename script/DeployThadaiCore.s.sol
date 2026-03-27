// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {ThadaiCore} from "../src/ThadaiCore.sol";

contract DeployThadaiCore is Script {
    // Pricing in USD (8-decimal scale, matching Chainlink ETH/USD feed)
    // - Target: $5 for 1 hour of usage
    // - 1 hour = 3,600 seconds
    // - Price per second = $5 / 3,600 = $0.001388...
    // - In 8-decimal scale: 0.001388... * 1e8 = 138_888 (~1.389e5)
    uint256 public constant BASE_ACCESS_PRICE_USD = 138888; // $0.00138888/sec (8-dec)

    // - Target: $2 minimum payment
    // - In 8-decimal scale: 2 * 1e8 = 200_000_000
    uint256 public constant MINIMUM_PAYMENT_USD = 200000000; // $2.00 (8-dec)

    // Chainlink ETH/USD feed address (Sepolia by default)
    address public constant PRICE_FEED_ADDRESS = 0x694AA1769357215DE4FAC081bf1f309aDC325306;

    uint16 public constant WITHDRAW_COOLDOWN_PERIOD_IN_DAYS = 1;

    uint16 public constant INFLATION_WINDOW_IN_HOURS = 1;

    uint16 public constant INFLATION_PERCENT_PER_WINDOW = 10;

    function deployThadaiCore(
        uint256 base_access_price_usd,
        uint256 minimum_payment_usd,
        address price_feed,
        uint16 withdraw_cooldown_period_in_days,
        uint16 inflation_window_in_hours,
        uint16 inflation_percent_per_window
    ) public returns (ThadaiCore) {
        vm.startBroadcast();
        ThadaiCore thadaiCore = new ThadaiCore(
            base_access_price_usd,
            minimum_payment_usd,
            price_feed,
            withdraw_cooldown_period_in_days,
            inflation_window_in_hours,
            inflation_percent_per_window
        );
        vm.stopBroadcast();
        return thadaiCore;
    }

    function run() external returns (ThadaiCore) {
        return deployThadaiCore(
            BASE_ACCESS_PRICE_USD,
            MINIMUM_PAYMENT_USD,
            PRICE_FEED_ADDRESS,
            WITHDRAW_COOLDOWN_PERIOD_IN_DAYS,
            INFLATION_WINDOW_IN_HOURS,
            INFLATION_PERCENT_PER_WINDOW
        );
    }
}
