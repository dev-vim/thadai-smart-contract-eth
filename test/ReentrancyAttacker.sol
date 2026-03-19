// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {ThadaiCore} from "../src/ThadaiCore.sol";

/// @notice Malicious contract that attempts reentrancy on ThadaiCore.withdrawFunds()
contract ReentrancyAttacker {
    ThadaiCore public target;
    uint256 public attackCount;

    constructor(address _target) {
        target = ThadaiCore(_target);
    }

    function attack() external payable {
        target.purchaseAccess{value: msg.value}();
        target.withdrawFunds();
    }

    receive() external payable {
        if (attackCount < 2) {
            attackCount++;
            target.withdrawFunds();
        }
    }
}
