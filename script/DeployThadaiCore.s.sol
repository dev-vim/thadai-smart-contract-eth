// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {ThadaiCore} from "../src/ThadaiCore.sol";

contract DeployThadaiCore is Script {
    // Pricing calculations:
    // - Target: $5 for 1 hour of usage
    // - 1 hour = 3,600 seconds
    // - Price per second = $5 / 3,600 = $0.001388888... per second
    // - 1 ETH = $2,200
    // - 1 wei = $2,200 / 1e18 = $2.2e-15
    // - Base access price (per second) = ($5 / 3,600) / ($2,200 / 1e18)
    //   = (5 * 1e18) / (3,600 * 2,200)
    //   = 5e18 / 7,920,000
    //   = 631,313,131,313 wei (approximately 631313e9 wei)
    //   Using exact calculation: 5000000000000000000 / 7920000 = 631313131313 wei
    uint256 public constant BASE_ACCESS_PRICE_IN_WEI = 631313131313;

    // Minimum payment calculation:
    // - Target: $2 minimum payment
    // - Minimum payment in ETH = $2 / $2,200 = 2 / 2,200 ETH
    // - Minimum payment in wei = (2 * 1e18) / 2,200
    //   = 2e18 / 2,200
    //   = 909,090,909,090,909 wei (approximately 909091e9 wei)
    //   Using exact calculation: 2000000000000000000 / 2200 = 909090909090909 wei
    uint256 public constant MINIMUM_PAYMENT_AMOUNT_IN_WEI = 909090909090909;

    uint16 public constant WITHDRAW_COOLDOWN_PERIOD_IN_DAYS = 1;

    uint16 public constant INFLATION_WINDOW_IN_HOURS = 1;

    uint16 public constant INFLATION_PERCENT_PER_WINDOW = 10;

    function deployThadaiCore(
        uint256 base_access_price_in_wei,
        uint256 minimum_payment_amount_in_wei,
        uint16 withdraw_cooldown_period_in_days,
        uint16 inflation_window_in_hours,
        uint16 inflation_percent_per_window
    ) public returns (ThadaiCore) {
        vm.startBroadcast();
        ThadaiCore thadaiCore = new ThadaiCore(
            base_access_price_in_wei,
            minimum_payment_amount_in_wei,
            withdraw_cooldown_period_in_days,
            inflation_window_in_hours,
            inflation_percent_per_window
        );
        vm.stopBroadcast();
        return thadaiCore;
    }

    function run() external returns (ThadaiCore) {
        return deployThadaiCore(
            BASE_ACCESS_PRICE_IN_WEI,
            MINIMUM_PAYMENT_AMOUNT_IN_WEI,
            WITHDRAW_COOLDOWN_PERIOD_IN_DAYS,
            INFLATION_WINDOW_IN_HOURS,
            INFLATION_PERCENT_PER_WINDOW
        );
    }
}
