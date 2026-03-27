// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.19;

import {Script} from "forge-std/Script.sol";
import {ThadaiCore} from "../src/ThadaiCore.sol";
import {DeployThadaiCore} from "./DeployThadaiCore.s.sol";

contract DeployThadaiCoreTest is Script {
    function run(address priceFeed) external returns (ThadaiCore) {
        uint256 base_access_price_usd = 20e10; // test value in 8-decimal USD scale
        uint256 minimum_payment_usd = 24000e10; // test value in 8-decimal USD scale
        uint16 withdraw_cooldown_period_in_days = 1;
        uint16 inflation_window_in_hours = 1;
        uint16 inflation_percent_per_window = 10;
        DeployThadaiCore deployer = new DeployThadaiCore();
        return deployer.deployThadaiCore(
            base_access_price_usd,
            minimum_payment_usd,
            priceFeed,
            withdraw_cooldown_period_in_days,
            inflation_window_in_hours,
            inflation_percent_per_window
        );
    }
}
