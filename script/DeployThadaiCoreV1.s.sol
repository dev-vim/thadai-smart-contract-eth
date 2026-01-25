// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {ThadaiCoreV1} from "../src/ThadaiCoreV1.sol";

contract DeployThadaiCoreV1 is Script {
    // Pricing calculations:
    // - Target: $5 for 1 hour of usage
    // - 1 hour = 3,600 seconds
    // - Price per second = $5 / 3,600 = $0.001388888... per second
    // - 1 ETH = $3,300
    // - 1 wei = $3,300 / 1e18 = $3.3e-15
    // - Base access price (per second) = ($5 / 3,600) / ($3,300 / 1e18)
    //   = (5 * 1e18) / (3,600 * 3,300)
    //   = 5e18 / 11,880,000
    //   = 420,875,420,875 wei (approximately 420875e9 wei)
    //   Using exact calculation: 5000000000000000000 / 11880000 = 420875420875 wei
    uint256 public constant BASE_ACCESS_PRICE_IN_WEI = 420875420875;

    // Minimum payment calculation:
    // - Target: $2 minimum payment
    // - Minimum payment in ETH = $2 / $3,300 = 2 / 3,300 ETH
    // - Minimum payment in wei = (2 * 1e18) / 3,300
    //   = 2e18 / 3,300
    //   = 606,060,606,060,606 wei (approximately 606061e9 wei)
    //   Using exact calculation: 2000000000000000000 / 3300 = 606060606060606 wei
    uint256 public constant MINIMUM_PAYMENT_AMOUNT_IN_WEI = 606060606060606;

    uint8 public constant WITHDRAW_COOLDOWN_PERIOD_IN_DAYS = 1;

    uint256 public constant INFLATION_WINDOW_IN_HOURS = 1;

    uint8 public constant INFLATION_PERCENT_PER_WINDOW = 10;

    function deployThadaiCoreV1(
        uint256 base_access_price_in_wei,
        uint256 minimum_payment_amount_in_wei,
        uint8 withdraw_cooldown_period_in_days,
        uint256 inflation_window_in_hours,
        uint8 inflation_percent_per_window
    ) public returns (ThadaiCoreV1) {
        vm.startBroadcast();
        ThadaiCoreV1 thadaiCoreV1 = new ThadaiCoreV1(
            base_access_price_in_wei,
            minimum_payment_amount_in_wei,
            withdraw_cooldown_period_in_days,
            inflation_window_in_hours,
            inflation_percent_per_window
        );
        vm.stopBroadcast();
        return thadaiCoreV1;
    }

    function run() external returns (ThadaiCoreV1) {
        return deployThadaiCoreV1(
            BASE_ACCESS_PRICE_IN_WEI,
            MINIMUM_PAYMENT_AMOUNT_IN_WEI,
            WITHDRAW_COOLDOWN_PERIOD_IN_DAYS,
            INFLATION_WINDOW_IN_HOURS,
            INFLATION_PERCENT_PER_WINDOW
        );
    }
}
