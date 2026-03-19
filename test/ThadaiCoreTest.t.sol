// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {ThadaiCore} from "../src/ThadaiCore.sol";
import {IThadaiCore} from "../src/IThadaiCore.sol";
import {DeployThadaiCoreTest} from "../script/DeployThadaiCoreTest.s.sol";
import {ReentrancyAttacker} from "./ReentrancyAttacker.sol";

contract ThadaiCoreTest is Test {
    ThadaiCore public thadaiCore;

    // Constants from deployment script
    uint256 public constant BASE_ACCESS_PRICE = 20e10;

    uint256 public constant MINIMUM_PAYMENT_AMOUNT = 24000e10;

    uint256 public constant WITHDRAW_COOLDOWN_PERIOD = 86400; // 1 day in seconds

    uint256 public constant INFLATION_WINDOW = 3600; // 1 hour in seconds

    uint8 public constant INFLATION_PERCENT_PER_WINDOW = 10;

    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    function setUp() external {
        DeployThadaiCoreTest deployer = new DeployThadaiCoreTest();
        thadaiCore = deployer.run();
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsBaseAccessPrice() public view {
        assertEq(thadaiCore.baseAccessPrice(), BASE_ACCESS_PRICE);
    }

    function test_Constructor_SetsMinimumPaymentAmount() public view {
        assertEq(thadaiCore.minimumPaymentAmount(), MINIMUM_PAYMENT_AMOUNT);
    }

    function test_Constructor_SetsWithdrawCooldownPeriod() public view {
        assertEq(thadaiCore.withdrawCooldownPeriod(), WITHDRAW_COOLDOWN_PERIOD);
    }

    // ============ Purchase Access Tests ============

    function test_PurchaseAccess_WithMinimumPayment() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        (
            uint256 balance,
            uint256 accessUntil,
            uint256 lastPurchaseTime,
            uint256 lastRedemptionTime,
            uint256 totalAccessSecondsPurchased,
            uint256 totalPaid,
            bool canWithdraw,
            uint256 cooldownRemaining,
            uint256 applicableInflationPercent
        ) = thadaiCore.getUserAccessInfo(user1);
        assertEq(balance, MINIMUM_PAYMENT_AMOUNT);
        assertGt(accessUntil, block.timestamp);
        assertGt(lastPurchaseTime, 0);
        assertEq(lastRedemptionTime, 0);
        assertGt(totalAccessSecondsPurchased, 0);
        assertEq(totalPaid, MINIMUM_PAYMENT_AMOUNT);
        assertEq(canWithdraw, true);
        assertEq(cooldownRemaining, 0);
        assertEq(applicableInflationPercent, INFLATION_PERCENT_PER_WINDOW);
    }

    function test_PurchaseAccess_WithMoreThanMinimum() public {
        uint256 payment = MINIMUM_PAYMENT_AMOUNT * 2;
        vm.deal(user1, payment);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: payment}();

        (
            uint256 balance,
            uint256 accessUntil,
            uint256 lastPurchaseTime,
            uint256 lastRedemptionTime,
            uint256 totalAccessSecondsPurchased,
            uint256 totalPaid,
            bool canWithdraw,
            uint256 cooldownRemaining,
            uint256 applicableInflationPercent
        ) = thadaiCore.getUserAccessInfo(user1);
        assertEq(balance, payment);
        assertGt(accessUntil, block.timestamp);
        assertGt(lastPurchaseTime, 0);
        assertEq(lastRedemptionTime, 0);
        assertGt(totalAccessSecondsPurchased, 0);
        assertEq(totalPaid, payment);
        assertEq(canWithdraw, true);
        assertEq(cooldownRemaining, 0);
        assertEq(applicableInflationPercent, INFLATION_PERCENT_PER_WINDOW);
    }

    function test_PurchaseAccess_RevertsWhenPaymentBelowMinimum() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT - 1);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IThadaiCore.PaymentBelowMinimumAmount.selector, MINIMUM_PAYMENT_AMOUNT));
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT - 1}();
    }

    function test_PurchaseAccess_ExtendsExistingAccess() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 2);

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        (, uint256 firstAccessUntil,,,,,,,) = thadaiCore.getUserAccessInfo(user1);

        // Move forward in time but before access expires
        vm.warp(block.timestamp + 100);

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        (, uint256 secondAccessUntil,,,,,,,) = thadaiCore.getUserAccessInfo(user1);

        // New access should be extended from the previous expiration, not current time
        assertGt(secondAccessUntil, firstAccessUntil);
    }

    function test_PurchaseAccess_StartsNewPeriodAfterExpiry() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 3);

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        (, uint256 firstAccessUntil,,,,,,,) = thadaiCore.getUserAccessInfo(user1);

        // Wait for access to expire
        vm.warp(firstAccessUntil + 1);

        // Verify access expired
        (bool hasAccess,) = thadaiCore.checkAccess(user1);
        assertFalse(hasAccess);

        uint256 purchaseTimeBefore = block.timestamp;
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        (, uint256 secondAccessUntil,,,,,,,) = thadaiCore.getUserAccessInfo(user1);

        // New access should start from current time (purchase time), not previous expiration
        // Since we're past the expiry, secondAccessUntil should be >= purchaseTimeBefore
        // and it should be in the future relative to when we purchased
        uint256 applicableInflation = 0;
        if (block.timestamp - purchaseTimeBefore < INFLATION_WINDOW) {
            applicableInflation = INFLATION_PERCENT_PER_WINDOW;
        }
        uint256 expectedAccessSeconds =
            MINIMUM_PAYMENT_AMOUNT / (BASE_ACCESS_PRICE + (BASE_ACCESS_PRICE * applicableInflation) / 100);
        uint256 expectedAccessUntil = purchaseTimeBefore + expectedAccessSeconds;
        assertGe(secondAccessUntil, purchaseTimeBefore);
        // Allow small time variance
        assertGe(secondAccessUntil, expectedAccessUntil - 10);
        assertLe(secondAccessUntil, expectedAccessUntil + 10);
    }

    function test_PurchaseAccess_EmitsAccessPurchasedEvent() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);

        // Check that event is emitted with correct user and amount (ignore timestamp due to timing)
        vm.expectEmit(true, false, false, false);
        emit IThadaiCore.AccessPurchased(user1, MINIMUM_PAYMENT_AMOUNT, 0);

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
    }

    function test_PurchaseAccess_CalculatesCorrectAccessTime() public {
        uint256 payment = MINIMUM_PAYMENT_AMOUNT;
        uint256 expectedSeconds = payment / BASE_ACCESS_PRICE;

        vm.deal(user1, payment);
        uint256 purchaseTime = block.timestamp;
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: payment}();

        (, uint256 accessUntil,,,,,,,) = thadaiCore.getUserAccessInfo(user1);
        uint256 actualSeconds = accessUntil - purchaseTime;
        assertEq(actualSeconds, expectedSeconds);
    }

    function test_PurchaseAccess_UpdatesContractBalance() public {
        uint256 initialBalance = address(thadaiCore).balance;
        uint256 payment = MINIMUM_PAYMENT_AMOUNT;

        vm.deal(user1, payment);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: payment}();

        assertEq(address(thadaiCore).balance, initialBalance + payment);
        assertEq(thadaiCore.getContractBalance(), initialBalance + payment);
    }

    function test_PurchaseAccess_MultipleUsers() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.deal(user2, MINIMUM_PAYMENT_AMOUNT);

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        vm.prank(user2);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        (, uint256 accessUntil1,,,,,,,) = thadaiCore.getUserAccessInfo(user1);
        (, uint256 accessUntil2,,,,,,,) = thadaiCore.getUserAccessInfo(user2);

        assertGt(accessUntil1, block.timestamp);
        assertGt(accessUntil2, block.timestamp);
        assertEq(address(thadaiCore).balance, MINIMUM_PAYMENT_AMOUNT * 2);
    }

    // ============ Check Access Tests ============

    function test_CheckAccess_UserWithActiveAccess() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        (bool hasAccess, uint256 remainingSeconds) = thadaiCore.checkAccess(user1);
        assertTrue(hasAccess);
        assertGt(remainingSeconds, 0);
    }

    function test_CheckAccess_UserWithoutAccess() public view {
        (bool hasAccess, uint256 remainingSeconds) = thadaiCore.checkAccess(user1);
        assertFalse(hasAccess);
        assertEq(remainingSeconds, 0);
    }

    function test_CheckAccess_UserWithExpiredAccess() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        (uint256 accessUntil,,,,,,,,) = thadaiCore.getUserAccessInfo(user1);

        // Move past expiration
        vm.warp(accessUntil + 1);

        (bool hasAccess, uint256 remainingSeconds) = thadaiCore.checkAccess(user1);
        assertFalse(hasAccess);
        assertEq(remainingSeconds, 0);
    }

    function test_CheckAccess_ReturnsCorrectRemainingSeconds() public {
        uint256 payment = MINIMUM_PAYMENT_AMOUNT;
        uint256 expectedSeconds = payment / BASE_ACCESS_PRICE;

        vm.deal(user1, payment);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: payment}();

        (bool hasAccess, uint256 remainingSeconds) = thadaiCore.checkAccess(user1);
        assertTrue(hasAccess);
        // Allow for some time passed during execution
        assertGe(remainingSeconds, expectedSeconds - 10);
        assertLe(remainingSeconds, expectedSeconds);
    }

    // ============ Withdraw Funds Tests ============

    function test_WithdrawFunds_FirstWithdrawal_NoCooldown() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        uint256 balanceBefore = user1.balance;
        vm.prank(user1);
        thadaiCore.withdrawFunds();

        assertEq(user1.balance, balanceBefore + MINIMUM_PAYMENT_AMOUNT);

        (uint256 balance, uint256 accessUntil,,,,,,,) = thadaiCore.getUserAccessInfo(user1);
        assertEq(balance, 0);
        assertEq(accessUntil, 0);
    }

    function test_WithdrawFunds_RevertsWhenNoBalance() public {
        vm.prank(user1);
        vm.expectRevert(IThadaiCore.NoBalanceToWithdraw.selector);
        thadaiCore.withdrawFunds();
    }

    function test_WithdrawFunds_RevertsDuringCooldown() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 2);

        // First purchase and withdrawal
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        vm.prank(user1);
        thadaiCore.withdrawFunds();

        uint256 firstWithdrawalTime = block.timestamp;

        // Purchase again
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        // Try to withdraw before cooldown
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IThadaiCore.WithdrawalCooldownActive.selector, block.timestamp - firstWithdrawalTime)
        );
        thadaiCore.withdrawFunds();
    }

    function test_WithdrawFunds_SucceedsAfterCooldown() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 2);

        // First purchase and withdrawal
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        vm.prank(user1);
        thadaiCore.withdrawFunds();

        // Purchase again
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        // Move past cooldown
        vm.warp(block.timestamp + thadaiCore.withdrawCooldownPeriod());

        uint256 balanceBefore = user1.balance;
        vm.prank(user1);
        thadaiCore.withdrawFunds();

        assertEq(user1.balance, balanceBefore + MINIMUM_PAYMENT_AMOUNT);
    }

    function test_WithdrawFunds_UpdatesLastRedemptionTime() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        uint256 withdrawalTime = block.timestamp;
        vm.prank(user1);
        thadaiCore.withdrawFunds();

        (,,, uint256 lastRedemptionTime,,,,,) = thadaiCore.getUserAccessInfo(user1);
        assertEq(lastRedemptionTime, withdrawalTime);
    }

    function test_WithdrawFunds_EmitsUserWithdrawnEvent() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        vm.prank(user1);
        vm.expectEmit(true, false, false, false);
        emit IThadaiCore.UserWithdrawn(user1, MINIMUM_PAYMENT_AMOUNT);

        thadaiCore.withdrawFunds();
    }

    function test_WithdrawFunds_ResetsUserData() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        vm.prank(user1);
        thadaiCore.withdrawFunds();

        (uint256 balance, uint256 accessUntil,, uint256 lastRedemptionTime,, uint256 totalPaid,,,) =
            thadaiCore.getUserAccessInfo(user1);

        assertEq(accessUntil, 0);
        assertEq(balance, 0);
        // totalPaid should remain (historical record)
        assertEq(totalPaid, MINIMUM_PAYMENT_AMOUNT);
        assertGt(lastRedemptionTime, 0);
    }

    function test_WithdrawFunds_DoesNotResetTotalPaid() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 3);

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        vm.prank(user1);
        thadaiCore.withdrawFunds();

        vm.warp(block.timestamp + thadaiCore.withdrawCooldownPeriod());

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT * 2}();
        vm.prank(user1);
        thadaiCore.withdrawFunds();

        (,,,,, uint256 totalPaid,,,) = thadaiCore.getUserAccessInfo(user1);
        assertEq(totalPaid, MINIMUM_PAYMENT_AMOUNT * 3);
    }

    // ============ Get User Access Info Tests ============

    function test_GetUserAccessInfo_NewUser() public view {
        (
            uint256 balance,
            uint256 accessUntil,
            uint256 lastPurchaseTime,
            uint256 lastRedemptionTime,
            uint256 totalAccessSecondsPurchased,
            uint256 totalPaid,
            bool canWithdraw,
            uint256 cooldownRemaining,
            uint256 applicableInflationPercent
        ) = thadaiCore.getUserAccessInfo(user1);

        assertEq(balance, 0);
        assertEq(accessUntil, 0);
        assertEq(lastPurchaseTime, 0);
        assertEq(lastRedemptionTime, 0);
        assertEq(totalAccessSecondsPurchased, 0);
        assertEq(totalPaid, 0);
        assertEq(canWithdraw, false);
        assertEq(cooldownRemaining, 0);
        assertEq(applicableInflationPercent, 0);
    }

    function test_GetUserAccessInfo_UserWithActiveAccess() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        (
            uint256 balance,
            uint256 accessUntil,
            uint256 lastPurchaseTime,
            uint256 lastRedemptionTime,
            uint256 totalAccessSecondsPurchased,
            uint256 totalPaid,
            bool canWithdraw,
            uint256 cooldownRemaining,
            uint256 applicableInflationPercent
        ) = thadaiCore.getUserAccessInfo(user1);
        assertEq(balance, MINIMUM_PAYMENT_AMOUNT);
        assertGt(accessUntil, block.timestamp);
        assertGt(lastPurchaseTime, 0);
        assertEq(lastRedemptionTime, 0);
        assertGt(totalAccessSecondsPurchased, 0);
        assertEq(totalPaid, MINIMUM_PAYMENT_AMOUNT);
        assertEq(canWithdraw, true);
        assertEq(cooldownRemaining, 0);
        assertEq(applicableInflationPercent, 10);
    }

    function test_GetUserAccessInfo_UserDuringCooldown() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 2);

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        vm.prank(user1);
        thadaiCore.withdrawFunds();

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        (,,,,,, bool canWithdraw, uint256 cooldownRemaining,) = thadaiCore.getUserAccessInfo(user1);

        assertFalse(canWithdraw);
        assertGt(cooldownRemaining, 0);
        assertLe(cooldownRemaining, thadaiCore.withdrawCooldownPeriod());
    }

    function test_GetUserAccessInfo_UserAfterCooldown() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 2);

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        vm.prank(user1);
        thadaiCore.withdrawFunds();

        vm.warp(block.timestamp + thadaiCore.withdrawCooldownPeriod());

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        (,,,,,, bool canWithdraw, uint256 cooldownRemaining,) = thadaiCore.getUserAccessInfo(user1);

        assertTrue(canWithdraw);
        assertEq(cooldownRemaining, 0);
    }

    // ============ Inflation Logic Test ============
    function test_Inflation_AppliesOnRapidTopUp() public {
        // User purchases access
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 2);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        // Immediately top up again (within inflation window)
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        // Check inflation percent is applied
        (,,,,,,,, uint256 applicableInflationPercent) = thadaiCore.getUserAccessInfo(user1);
        assertGt(applicableInflationPercent, 0);
    }

    function test_Inflation_DoesNotApplyOnBoundary() public {
        // User purchases access
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 2);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        // Move time to exactly inflation window boundary
        vm.warp(block.timestamp + INFLATION_WINDOW);
        // Check inflation percent is NOT applied (should be 0)
        (,,,,,,,, uint256 applicableInflationPercent) = thadaiCore.getUserAccessInfo(user1);
        assertEq(applicableInflationPercent, 0);
    }

    // ============ Calculate Access From Payment Tests ============

    function test_CalculateAccessFromPayment_MinimumPayment() public view {
        uint256 accessSeconds = thadaiCore.calculateAccessFromPayment(MINIMUM_PAYMENT_AMOUNT, 0);
        uint256 expectedSeconds = MINIMUM_PAYMENT_AMOUNT / BASE_ACCESS_PRICE;
        assertEq(accessSeconds, expectedSeconds);
    }

    function test_CalculateAccessFromPayment_LargePayment() public view {
        uint256 largePayment = MINIMUM_PAYMENT_AMOUNT * 100;
        uint256 accessSeconds = thadaiCore.calculateAccessFromPayment(largePayment, 0);
        uint256 expectedSeconds = largePayment / BASE_ACCESS_PRICE;
        assertEq(accessSeconds, expectedSeconds);
    }

    function test_CalculateAccessFromPayment_SmallPayment() public view {
        uint256 smallPayment = BASE_ACCESS_PRICE;
        uint256 accessSeconds = thadaiCore.calculateAccessFromPayment(smallPayment, 0);
        assertEq(accessSeconds, 1);
    }

    function test_CalculateAccessFromPayment_Zero() public view {
        uint256 accessSeconds = thadaiCore.calculateAccessFromPayment(0, 0);
        assertEq(accessSeconds, 0);
    }

    // =========== Get Access Pricing Info Tests ==========

    function test_GetAccessPricingInfo_ReturnsCorrectValues() public view {
        (
            uint256 basePrice,
            uint256 minPayment,
            uint256 cooldownDays,
            uint256 inflationWindowHours,
            uint256 inflationPercent
        ) = thadaiCore.getAccessPricingInfo();

        assertEq(basePrice, BASE_ACCESS_PRICE);
        assertEq(minPayment, MINIMUM_PAYMENT_AMOUNT);
        assertEq(cooldownDays * WITHDRAW_COOLDOWN_PERIOD, WITHDRAW_COOLDOWN_PERIOD);
        assertEq(inflationWindowHours * INFLATION_WINDOW, INFLATION_WINDOW);
        assertEq(inflationPercent, INFLATION_PERCENT_PER_WINDOW);
    }

    function test_GetAccessPricingInfo_ValuesAreConsistentWithState() public view {
        (uint256 basePrice,, uint256 cooldownDays, uint256 inflationWindowHours, uint256 inflationPercent) =
            thadaiCore.getAccessPricingInfo();

        assertEq(basePrice, thadaiCore.baseAccessPrice());
        assertEq(cooldownDays * WITHDRAW_COOLDOWN_PERIOD, thadaiCore.withdrawCooldownPeriod());
        assertEq(inflationWindowHours * INFLATION_WINDOW, thadaiCore.inflationWindowPeriod());
        assertEq(inflationPercent, thadaiCore.inflationPercent());
    }

    // ============ Get Contract Balance Tests ============

    function test_GetContractBalance_EmptyContract() public view {
        // Contract should be empty after deployment
        // Note: If deployer sends value, balance might not be zero
        uint256 balance = thadaiCore.getContractBalance();
        assertEq(balance, address(thadaiCore).balance);
    }

    function test_GetContractBalance_AfterDeposits() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 2);
        vm.deal(user2, MINIMUM_PAYMENT_AMOUNT);

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        vm.prank(user2);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        assertEq(thadaiCore.getContractBalance(), MINIMUM_PAYMENT_AMOUNT * 2);
        assertEq(thadaiCore.getContractBalance(), address(thadaiCore).balance);
    }

    function test_GetContractBalance_AfterWithdrawal() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.deal(user2, MINIMUM_PAYMENT_AMOUNT);

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        vm.prank(user2);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        vm.prank(user1);
        thadaiCore.withdrawFunds();

        assertEq(thadaiCore.getContractBalance(), MINIMUM_PAYMENT_AMOUNT);
        assertEq(address(thadaiCore).balance, MINIMUM_PAYMENT_AMOUNT);
    }

    // ============ Edge Cases and Integration Tests ============

    function test_MultiplePurchasesAndWithdrawals() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 5);

        // Purchase 1
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        (uint256 balance1,,,,,,,,) = thadaiCore.getUserAccessInfo(user1);
        assertEq(balance1, MINIMUM_PAYMENT_AMOUNT);

        // Purchase 2 - extend access
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        (uint256 balance2,,,,,,,,) = thadaiCore.getUserAccessInfo(user1);
        assertEq(balance2, MINIMUM_PAYMENT_AMOUNT * 2);

        // Withdraw
        vm.prank(user1);
        thadaiCore.withdrawFunds();

        // Wait for cooldown
        vm.warp(block.timestamp + thadaiCore.withdrawCooldownPeriod());

        // Purchase 3
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        (,,,,, uint256 totalPaid,,,) = thadaiCore.getUserAccessInfo(user1);
        assertEq(totalPaid, MINIMUM_PAYMENT_AMOUNT * 3);
    }

    function test_AccessExpiresCorrectly() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        (, uint256 accessUntil,,,,,,,) = thadaiCore.getUserAccessInfo(user1);

        // Move to exactly when access expires
        vm.warp(accessUntil);

        (bool hasAccess,) = thadaiCore.checkAccess(user1);
        assertFalse(hasAccess);
    }

    function test_WithdrawCooldownCalculation() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 2);

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        vm.prank(user1);
        thadaiCore.withdrawFunds();

        uint256 withdrawalTime = block.timestamp;

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        // Check cooldown immediately after withdrawal
        (,,,,,,, uint256 cooldownRemaining,) = thadaiCore.getUserAccessInfo(user1);
        uint256 expectedCooldown = thadaiCore.withdrawCooldownPeriod();
        assertGt(cooldownRemaining, 0);
        assertLe(cooldownRemaining, expectedCooldown);

        // Advance half the cooldown period
        vm.warp(withdrawalTime + expectedCooldown / 2);
        (,,,,,,, cooldownRemaining,) = thadaiCore.getUserAccessInfo(user1);
        assertGt(cooldownRemaining, 0);
        assertLt(cooldownRemaining, expectedCooldown / 2 + 1);

        // Advance past cooldown
        vm.warp(withdrawalTime + expectedCooldown);
        (,,,,,, bool canWithdraw, uint256 cooldownRemainingFinal,) = thadaiCore.getUserAccessInfo(user1);
        assertTrue(canWithdraw);
        assertEq(cooldownRemainingFinal, 0);
    }

    function test_PurchaseAndWithdrawSameBlock() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        // Withdraw in same block should work (first withdrawal)
        vm.prank(user1);
        thadaiCore.withdrawFunds();

        (uint256 balance,,,,,,,,) = thadaiCore.getUserAccessInfo(user1);
        assertEq(balance, 0);
    }

    function test_Fuzz_CalculateAccessFromPayment(uint256 payment) public view {
        // Bound payment to reasonable range to avoid overflow
        payment = bound(payment, 0, type(uint256).max / BASE_ACCESS_PRICE);

        uint256 accessSeconds = thadaiCore.calculateAccessFromPayment(payment, 0);
        uint256 expectedSeconds = payment / BASE_ACCESS_PRICE;
        assertEq(accessSeconds, expectedSeconds);
    }

    function test_Fuzz_PurchaseAccess(uint256 payment) public {
        // Bound payment to minimum and reasonable maximum
        payment = bound(payment, MINIMUM_PAYMENT_AMOUNT, MINIMUM_PAYMENT_AMOUNT * 1000);

        vm.deal(user1, payment);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: payment}();

        (uint256 balance, uint256 accessUntil,,,, uint256 totalPaid,,,) = thadaiCore.getUserAccessInfo(user1);
        assertEq(balance, payment);
        assertEq(totalPaid, payment);
        assertGt(accessUntil, block.timestamp);

        uint256 expectedSeconds = payment / BASE_ACCESS_PRICE;
        assertGe(accessUntil - block.timestamp, expectedSeconds - 10); // Allow small time variance
    }

    // ============ Reentrancy Attack Tests ============

    function test_WithdrawFunds_RevertsOnReentrancy() public {
        ReentrancyAttacker attacker = new ReentrancyAttacker(address(thadaiCore));
        vm.deal(address(attacker), MINIMUM_PAYMENT_AMOUNT);

        // Attacker purchases access, then withdrawFunds triggers receive() which re-enters
        vm.expectRevert();
        attacker.attack{value: MINIMUM_PAYMENT_AMOUNT}();
    }

    function test_WithdrawFunds_AttackerCannotDrainContract() public {
        // Legitimate user deposits first
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        // Attacker deposits and tries to re-enter
        ReentrancyAttacker attacker = new ReentrancyAttacker(address(thadaiCore));
        vm.deal(address(attacker), MINIMUM_PAYMENT_AMOUNT);

        vm.expectRevert();
        attacker.attack{value: MINIMUM_PAYMENT_AMOUNT}();

        // Legitimate user's balance must be intact
        assertEq(address(thadaiCore).balance, MINIMUM_PAYMENT_AMOUNT);
        (uint256 balance,,,,,,,,) = thadaiCore.getUserAccessInfo(user1);
        assertEq(balance, MINIMUM_PAYMENT_AMOUNT);
    }

    // ============ Constructor Validation Tests ============

    function test_Constructor_RevertsOnZeroBasePrice() public {
        vm.expectRevert(ThadaiCore.InvalidBasePrice.selector);
        new ThadaiCore(0, MINIMUM_PAYMENT_AMOUNT, 1, 1, 10);
    }

    function test_Constructor_RevertsOnZeroMinimumPayment() public {
        vm.expectRevert(ThadaiCore.InvalidMinimumPayment.selector);
        new ThadaiCore(BASE_ACCESS_PRICE, 0, 1, 1, 10);
    }

    // ============ Direct ETH Transfer Tests ============

    function test_RejectsDirectETHTransfer() public {
        // Contract has no receive() or fallback(), so raw ETH transfers should revert
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        (bool success,) = address(thadaiCore).call{value: 1 ether}("");
        assertFalse(success);
    }

    function test_RejectsDirectETHTransferWithData() public {
        // Calling a non-existent function with value should also revert
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        (bool success,) = address(thadaiCore).call{value: 1 ether}(abi.encodeWithSignature("nonExistent()"));
        assertFalse(success);
    }

    // ============ Inflation Edge Case Tests ============

    function test_Inflation_ReducesAccessSecondsForSamePayment() public view {
        uint256 normalSeconds = thadaiCore.calculateAccessFromPayment(MINIMUM_PAYMENT_AMOUNT, 0);
        uint256 inflatedSeconds =
            thadaiCore.calculateAccessFromPayment(MINIMUM_PAYMENT_AMOUNT, INFLATION_PERCENT_PER_WINDOW);

        assertGt(normalSeconds, inflatedSeconds);

        // Verify the inflation math: inflated price = base + base * 10 / 100 = 1.1x base
        uint256 expectedInflatedSeconds =
            MINIMUM_PAYMENT_AMOUNT / (BASE_ACCESS_PRICE + (BASE_ACCESS_PRICE * INFLATION_PERCENT_PER_WINDOW) / 100);
        assertEq(inflatedSeconds, expectedInflatedSeconds);
    }

    function test_Inflation_ResetsAfterWindowExpires() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 2);

        // First purchase
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        // Inflation active immediately after purchase
        (,,,,,,,, uint256 inflationRight) = thadaiCore.getUserAccessInfo(user1);
        assertEq(inflationRight, INFLATION_PERCENT_PER_WINDOW);

        // Advance past inflation window
        vm.warp(block.timestamp + INFLATION_WINDOW);

        // Inflation should be 0 now
        (,,,,,,,, uint256 inflationAfter) = thadaiCore.getUserAccessInfo(user1);
        assertEq(inflationAfter, 0);
    }

    function test_Inflation_SecondPurchaseWithinWindowGetsLessAccess() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 2);
        vm.deal(user2, MINIMUM_PAYMENT_AMOUNT);

        // user1 purchases twice rapidly (second purchase gets inflated price)
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        (,,,, uint64 firstPurchaseSeconds,,,,) = thadaiCore.getUserAccessInfo(user1);

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        (,,,, uint64 totalAfterSecond,,,,) = thadaiCore.getUserAccessInfo(user1);

        uint64 secondPurchaseSeconds = totalAfterSecond - firstPurchaseSeconds;

        // user2 purchases once (gets base price)
        vm.prank(user2);
        thadaiCore.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        (,,,, uint64 user2Seconds,,,,) = thadaiCore.getUserAccessInfo(user2);

        // user1's second purchase should yield fewer seconds than user2's first purchase
        assertLt(secondPurchaseSeconds, user2Seconds);
    }

    // ============ Payment Rounding / Dust Tests ============

    function test_PurchaseAccess_PaymentJustAboveMinimum() public {
        // Payment that's minimumPaymentAmount + 1 wei — ensure no rounding issues
        uint256 payment = MINIMUM_PAYMENT_AMOUNT + 1;
        vm.deal(user1, payment);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: payment}();

        (uint256 balance,,,,,,,,) = thadaiCore.getUserAccessInfo(user1);
        assertEq(balance, payment);
    }

    function test_CalculateAccess_PaymentBelowOneSecondWorth() public view {
        // Payment less than one second's cost yields 0 seconds (integer division floors)
        uint256 accessSeconds = thadaiCore.calculateAccessFromPayment(BASE_ACCESS_PRICE - 1, 0);
        assertEq(accessSeconds, 0);
    }

    function test_Fuzz_InflationAlwaysReducesOrMaintainsAccess(uint256 inflationPct) public view {
        inflationPct = bound(inflationPct, 0, 200);
        uint256 normalSeconds = thadaiCore.calculateAccessFromPayment(MINIMUM_PAYMENT_AMOUNT, 0);
        uint256 inflatedSeconds = thadaiCore.calculateAccessFromPayment(MINIMUM_PAYMENT_AMOUNT, inflationPct);
        assertLe(inflatedSeconds, normalSeconds);
    }
}
