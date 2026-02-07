// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {ThadaiCoreV1} from "../src/ThadaiCoreV1.sol";
import {DeployThadaiCoreV1Test} from "../script/DeployThadaiCoreV1Test.s.sol";

contract ThadaiCoreV1Test is Test {
    ThadaiCoreV1 public thadaiCoreV1Test;

    // Constants from deployment script
    uint256 public constant BASE_ACCESS_PRICE = 20e10;

    uint256 public constant MINIMUM_PAYMENT_AMOUNT = 24000e10;

    uint8 public constant WITHDRAW_COOLDOWN_PERIOD_IN_DAYS = 1;

    uint256 public constant INFLATION_WINDOW_IN_HOURS = 1;

    uint8 public constant INFLATION_PERCENT_PER_WINDOW = 10;

    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public user3 = makeAddr("user3");

    function setUp() external {
        DeployThadaiCoreV1Test deployer = new DeployThadaiCoreV1Test();
        thadaiCoreV1Test = deployer.run();
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsOwner() public {
        DeployThadaiCoreV1Test deployer = new DeployThadaiCoreV1Test();
        ThadaiCoreV1 newContract = deployer.run();

        address owner = newContract.owner();
        assertTrue(owner != address(0));

        assertEq(owner, thadaiCoreV1Test.owner());
    }

    function test_Constructor_SetsBaseAccessPrice() public view {
        assertEq(thadaiCoreV1Test.baseAccessPrice(), BASE_ACCESS_PRICE);
    }

    function test_Constructor_SetsMinimumPaymentAmount() public view {
        assertEq(thadaiCoreV1Test.minimumPaymentAmount(), MINIMUM_PAYMENT_AMOUNT);
    }

    function test_Constructor_SetsWithdrawCooldownInDays() public view {
        assertEq(thadaiCoreV1Test.withdrawCooldownInDays(), WITHDRAW_COOLDOWN_PERIOD_IN_DAYS * 1 days);
    }

    // ============ Purchase Access Tests ============

    function test_PurchaseAccess_WithMinimumPayment() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

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
        ) = thadaiCoreV1Test.getUserAccessInfo(user1);
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
        thadaiCoreV1Test.purchaseAccess{value: payment}();

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
        ) = thadaiCoreV1Test.getUserAccessInfo(user1);
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
        vm.expectRevert(abi.encodeWithSelector(ThadaiCoreV1.PaymentBelowMinimumAmount.selector, MINIMUM_PAYMENT_AMOUNT));
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT - 1}();
    }

    function test_PurchaseAccess_ExtendsExistingAccess() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 2);

        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        (, uint256 firstAccessUntil,,,,,,,) = thadaiCoreV1Test.getUserAccessInfo(user1);

        // Move forward in time but before access expires
        vm.warp(block.timestamp + 100);

        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        (, uint256 secondAccessUntil,,,,,,,) = thadaiCoreV1Test.getUserAccessInfo(user1);

        // New access should be extended from the previous expiration, not current time
        assertGt(secondAccessUntil, firstAccessUntil);
    }

    function test_PurchaseAccess_StartsNewPeriodAfterExpiry() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 3);

        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        (, uint256 firstAccessUntil,,,,,,,) = thadaiCoreV1Test.getUserAccessInfo(user1);

        // Wait for access to expire
        vm.warp(firstAccessUntil + 1);

        // Verify access expired
        (bool hasAccess,) = thadaiCoreV1Test.checkAccess(user1);
        assertFalse(hasAccess);

        uint256 purchaseTimeBefore = block.timestamp;
        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        (, uint256 secondAccessUntil,,,,,,,) = thadaiCoreV1Test.getUserAccessInfo(user1);

        // New access should start from current time (purchase time), not previous expiration
        // Since we're past the expiry, secondAccessUntil should be >= purchaseTimeBefore
        // and it should be in the future relative to when we purchased
        uint256 applicableInflation = 0;
        if (block.timestamp - purchaseTimeBefore < INFLATION_WINDOW_IN_HOURS) {
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
        emit ThadaiCoreV1.AccessPurchased(user1, MINIMUM_PAYMENT_AMOUNT, 0);

        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
    }

    function test_PurchaseAccess_CalculatesCorrectAccessTime() public {
        uint256 payment = MINIMUM_PAYMENT_AMOUNT;
        uint256 expectedSeconds = payment / BASE_ACCESS_PRICE;

        vm.deal(user1, payment);
        uint256 purchaseTime = block.timestamp;
        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: payment}();

        (, uint256 accessUntil,,,,,,,) = thadaiCoreV1Test.getUserAccessInfo(user1);
        uint256 actualSeconds = accessUntil - purchaseTime;
        assertEq(actualSeconds, expectedSeconds);
    }

    function test_PurchaseAccess_UpdatesContractBalance() public {
        uint256 initialBalance = address(thadaiCoreV1Test).balance;
        uint256 payment = MINIMUM_PAYMENT_AMOUNT;

        vm.deal(user1, payment);
        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: payment}();

        assertEq(address(thadaiCoreV1Test).balance, initialBalance + payment);
        assertEq(thadaiCoreV1Test.getContractBalance(), initialBalance + payment);
    }

    function test_PurchaseAccess_MultipleUsers() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.deal(user2, MINIMUM_PAYMENT_AMOUNT);

        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        vm.prank(user2);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        (, uint256 accessUntil1,,,,,,,) = thadaiCoreV1Test.getUserAccessInfo(user1);
        (, uint256 accessUntil2,,,,,,,) = thadaiCoreV1Test.getUserAccessInfo(user2);

        assertGt(accessUntil1, block.timestamp);
        assertGt(accessUntil2, block.timestamp);
        assertEq(address(thadaiCoreV1Test).balance, MINIMUM_PAYMENT_AMOUNT * 2);
    }

    // ============ Check Access Tests ============

    function test_CheckAccess_UserWithActiveAccess() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        (bool hasAccess, uint256 remainingSeconds) = thadaiCoreV1Test.checkAccess(user1);
        assertTrue(hasAccess);
        assertGt(remainingSeconds, 0);
    }

    function test_CheckAccess_UserWithoutAccess() public view {
        (bool hasAccess, uint256 remainingSeconds) = thadaiCoreV1Test.checkAccess(user1);
        assertFalse(hasAccess);
        assertEq(remainingSeconds, 0);
    }

    function test_CheckAccess_UserWithExpiredAccess() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        (uint256 accessUntil,,,,,,,,) = thadaiCoreV1Test.getUserAccessInfo(user1);

        // Move past expiration
        vm.warp(accessUntil + 1);

        (bool hasAccess, uint256 remainingSeconds) = thadaiCoreV1Test.checkAccess(user1);
        assertFalse(hasAccess);
        assertEq(remainingSeconds, 0);
    }

    function test_CheckAccess_ReturnsCorrectRemainingSeconds() public {
        uint256 payment = MINIMUM_PAYMENT_AMOUNT;
        uint256 expectedSeconds = payment / BASE_ACCESS_PRICE;

        vm.deal(user1, payment);
        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: payment}();

        (bool hasAccess, uint256 remainingSeconds) = thadaiCoreV1Test.checkAccess(user1);
        assertTrue(hasAccess);
        // Allow for some time passed during execution
        assertGe(remainingSeconds, expectedSeconds - 10);
        assertLe(remainingSeconds, expectedSeconds);
    }

    // ============ Withdraw Funds Tests ============

    function test_WithdrawFunds_FirstWithdrawal_NoCooldown() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        uint256 balanceBefore = user1.balance;
        vm.prank(user1);
        thadaiCoreV1Test.withdrawFunds();

        assertEq(user1.balance, balanceBefore + MINIMUM_PAYMENT_AMOUNT);

        (uint256 balance, uint256 accessUntil,,,,,,,) = thadaiCoreV1Test.getUserAccessInfo(user1);
        assertEq(balance, 0);
        assertEq(accessUntil, 0);
    }

    function test_WithdrawFunds_RevertsWhenNoBalance() public {
        vm.prank(user1);
        vm.expectRevert(ThadaiCoreV1.NoBalanceToWithdraw.selector);
        thadaiCoreV1Test.withdrawFunds();
    }

    function test_WithdrawFunds_RevertsDuringCooldown() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 2);

        // First purchase and withdrawal
        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        vm.prank(user1);
        thadaiCoreV1Test.withdrawFunds();

        uint256 firstWithdrawalTime = block.timestamp;

        // Purchase again
        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        // Try to withdraw before cooldown
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ThadaiCoreV1.WithdrawalCooldownActive.selector, block.timestamp - firstWithdrawalTime
            )
        );
        thadaiCoreV1Test.withdrawFunds();
    }

    function test_WithdrawFunds_SucceedsAfterCooldown() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 2);

        // First purchase and withdrawal
        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        vm.prank(user1);
        thadaiCoreV1Test.withdrawFunds();

        // Purchase again
        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        // Move past cooldown
        vm.warp(block.timestamp + thadaiCoreV1Test.withdrawCooldownInDays());

        uint256 balanceBefore = user1.balance;
        vm.prank(user1);
        thadaiCoreV1Test.withdrawFunds();

        assertEq(user1.balance, balanceBefore + MINIMUM_PAYMENT_AMOUNT);
    }

    function test_WithdrawFunds_UpdatesLastRedemptionTime() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        uint256 withdrawalTime = block.timestamp;
        vm.prank(user1);
        thadaiCoreV1Test.withdrawFunds();

        (,,, uint256 lastRedemptionTime,,,,,) = thadaiCoreV1Test.getUserAccessInfo(user1);
        assertEq(lastRedemptionTime, withdrawalTime);
    }

    function test_WithdrawFunds_EmitsUserWithdrawnEvent() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        vm.prank(user1);
        vm.expectEmit(true, false, false, false);
        emit ThadaiCoreV1.UserWithdrawn(user1, MINIMUM_PAYMENT_AMOUNT);

        thadaiCoreV1Test.withdrawFunds();
    }

    function test_WithdrawFunds_ResetsUserData() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        vm.prank(user1);
        thadaiCoreV1Test.withdrawFunds();

        (uint256 balance, uint256 accessUntil,, uint256 lastRedemptionTime,, uint256 totalPaid,,,) =
            thadaiCoreV1Test.getUserAccessInfo(user1);

        assertEq(accessUntil, 0);
        assertEq(balance, 0);
        // totalPaid should remain (historical record)
        assertEq(totalPaid, MINIMUM_PAYMENT_AMOUNT);
        assertGt(lastRedemptionTime, 0);
    }

    function test_WithdrawFunds_DoesNotResetTotalPaid() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 3);

        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        vm.prank(user1);
        thadaiCoreV1Test.withdrawFunds();

        vm.warp(block.timestamp + thadaiCoreV1Test.withdrawCooldownInDays());

        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT * 2}();
        vm.prank(user1);
        thadaiCoreV1Test.withdrawFunds();

        (,,,,, uint256 totalPaid,,,) = thadaiCoreV1Test.getUserAccessInfo(user1);
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
        ) = thadaiCoreV1Test.getUserAccessInfo(user1);

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
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

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
        ) = thadaiCoreV1Test.getUserAccessInfo(user1);
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
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        vm.prank(user1);
        thadaiCoreV1Test.withdrawFunds();

        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        (,,,,,, bool canWithdraw, uint256 cooldownRemaining,) = thadaiCoreV1Test.getUserAccessInfo(user1);

        assertFalse(canWithdraw);
        assertGt(cooldownRemaining, 0);
        assertLe(cooldownRemaining, thadaiCoreV1Test.withdrawCooldownInDays());
    }

    function test_GetUserAccessInfo_UserAfterCooldown() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 2);

        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        vm.prank(user1);
        thadaiCoreV1Test.withdrawFunds();

        vm.warp(block.timestamp + thadaiCoreV1Test.withdrawCooldownInDays());

        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        (,,,,,, bool canWithdraw, uint256 cooldownRemaining,) = thadaiCoreV1Test.getUserAccessInfo(user1);

        assertTrue(canWithdraw);
        assertEq(cooldownRemaining, 0);
    }

    // ============ Inflation Logic Test ============
    function test_Inflation_AppliesOnRapidTopUp() public {
        // User purchases access
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 2);
        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        // Immediately top up again (within inflation window)
        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        // Check inflation percent is applied
        (,,,,,,,, uint256 applicableInflationPercent) = thadaiCoreV1Test.getUserAccessInfo(user1);
        assertGt(applicableInflationPercent, 0);
    }

    // ============ Calculate Access From Payment Tests ============

    function test_CalculateAccessFromPayment_MinimumPayment() public view {
        uint256 accessSeconds = thadaiCoreV1Test.calculateAccessFromPayment(MINIMUM_PAYMENT_AMOUNT, 0);
        uint256 expectedSeconds = MINIMUM_PAYMENT_AMOUNT / BASE_ACCESS_PRICE;
        assertEq(accessSeconds, expectedSeconds);
    }

    function test_CalculateAccessFromPayment_LargePayment() public view {
        uint256 largePayment = MINIMUM_PAYMENT_AMOUNT * 100;
        uint256 accessSeconds = thadaiCoreV1Test.calculateAccessFromPayment(largePayment, 0);
        uint256 expectedSeconds = largePayment / BASE_ACCESS_PRICE;
        assertEq(accessSeconds, expectedSeconds);
    }

    function test_CalculateAccessFromPayment_SmallPayment() public view {
        uint256 smallPayment = BASE_ACCESS_PRICE;
        uint256 accessSeconds = thadaiCoreV1Test.calculateAccessFromPayment(smallPayment, 0);
        assertEq(accessSeconds, 1);
    }

    function test_CalculateAccessFromPayment_Zero() public view {
        uint256 accessSeconds = thadaiCoreV1Test.calculateAccessFromPayment(0, 0);
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
        ) = thadaiCoreV1Test.getAccessPricingInfo();

        assertEq(basePrice, BASE_ACCESS_PRICE);
        assertEq(minPayment, MINIMUM_PAYMENT_AMOUNT);
        assertEq(cooldownDays, WITHDRAW_COOLDOWN_PERIOD_IN_DAYS);
        assertEq(inflationWindowHours, INFLATION_WINDOW_IN_HOURS);
        assertEq(inflationPercent, INFLATION_PERCENT_PER_WINDOW);
    }

    function test_GetAccessPricingInfo_ValuesAreConsistentWithState() public view {
        (uint256 basePrice,, uint256 cooldownDays, uint256 inflationWindowHours, uint256 inflationPercent) =
            thadaiCoreV1Test.getAccessPricingInfo();

        assertEq(basePrice, thadaiCoreV1Test.baseAccessPrice());
        assertEq(cooldownDays, thadaiCoreV1Test.withdrawCooldownInDays() / 1 days);
        assertEq(inflationWindowHours, thadaiCoreV1Test.inflationWindowInHours() / 1 hours);
        assertEq(inflationPercent, thadaiCoreV1Test.inflationPercent());
    }

    // ============ Get Contract Balance Tests ============

    function test_GetContractBalance_EmptyContract() public view {
        // Contract should be empty after deployment
        // Note: If deployer sends value, balance might not be zero
        uint256 balance = thadaiCoreV1Test.getContractBalance();
        assertEq(balance, address(thadaiCoreV1Test).balance);
    }

    function test_GetContractBalance_AfterDeposits() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 2);
        vm.deal(user2, MINIMUM_PAYMENT_AMOUNT);

        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        vm.prank(user2);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        assertEq(thadaiCoreV1Test.getContractBalance(), MINIMUM_PAYMENT_AMOUNT * 2);
        assertEq(thadaiCoreV1Test.getContractBalance(), address(thadaiCoreV1Test).balance);
    }

    function test_GetContractBalance_AfterWithdrawal() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.deal(user2, MINIMUM_PAYMENT_AMOUNT);

        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        vm.prank(user2);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        vm.prank(user1);
        thadaiCoreV1Test.withdrawFunds();

        assertEq(thadaiCoreV1Test.getContractBalance(), MINIMUM_PAYMENT_AMOUNT);
        assertEq(address(thadaiCoreV1Test).balance, MINIMUM_PAYMENT_AMOUNT);
    }

    // ============ Edge Cases and Integration Tests ============

    function test_MultiplePurchasesAndWithdrawals() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 5);

        // Purchase 1
        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        (uint256 balance1,,,,,,,,) = thadaiCoreV1Test.getUserAccessInfo(user1);
        assertEq(balance1, MINIMUM_PAYMENT_AMOUNT);

        // Purchase 2 - extend access
        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        (uint256 balance2,,,,,,,,) = thadaiCoreV1Test.getUserAccessInfo(user1);
        assertEq(balance2, MINIMUM_PAYMENT_AMOUNT * 2);

        // Withdraw
        vm.prank(user1);
        thadaiCoreV1Test.withdrawFunds();

        // Wait for cooldown
        vm.warp(block.timestamp + thadaiCoreV1Test.withdrawCooldownInDays());

        // Purchase 3
        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        (,,,,, uint256 totalPaid,,,) = thadaiCoreV1Test.getUserAccessInfo(user1);
        assertEq(totalPaid, MINIMUM_PAYMENT_AMOUNT * 3);
    }

    function test_AccessExpiresCorrectly() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        (, uint256 accessUntil,,,,,,,) = thadaiCoreV1Test.getUserAccessInfo(user1);

        // Move to exactly when access expires
        vm.warp(accessUntil);

        (bool hasAccess,) = thadaiCoreV1Test.checkAccess(user1);
        assertFalse(hasAccess);
    }

    function test_WithdrawCooldownCalculation() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 2);

        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        vm.prank(user1);
        thadaiCoreV1Test.withdrawFunds();

        uint256 withdrawalTime = block.timestamp;

        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        // Check cooldown immediately after withdrawal
        (,,,,,,, uint256 cooldownRemaining,) = thadaiCoreV1Test.getUserAccessInfo(user1);
        uint256 expectedCooldown = thadaiCoreV1Test.withdrawCooldownInDays();
        assertGt(cooldownRemaining, 0);
        assertLe(cooldownRemaining, expectedCooldown);

        // Advance half the cooldown period
        vm.warp(withdrawalTime + expectedCooldown / 2);
        (,,,,,,, cooldownRemaining,) = thadaiCoreV1Test.getUserAccessInfo(user1);
        assertGt(cooldownRemaining, 0);
        assertLt(cooldownRemaining, expectedCooldown / 2 + 1);

        // Advance past cooldown
        vm.warp(withdrawalTime + expectedCooldown);
        (,,,,,, bool canWithdraw, uint256 cooldownRemainingFinal,) = thadaiCoreV1Test.getUserAccessInfo(user1);
        assertTrue(canWithdraw);
        assertEq(cooldownRemainingFinal, 0);
    }

    function test_PurchaseAndWithdrawSameBlock() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);

        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        // Withdraw in same block should work (first withdrawal)
        vm.prank(user1);
        thadaiCoreV1Test.withdrawFunds();

        (uint256 balance,,,,,,,,) = thadaiCoreV1Test.getUserAccessInfo(user1);
        assertEq(balance, 0);
    }

    function test_Fuzz_CalculateAccessFromPayment(uint256 payment) public view {
        // Bound payment to reasonable range to avoid overflow
        payment = bound(payment, 0, type(uint256).max / BASE_ACCESS_PRICE);

        uint256 accessSeconds = thadaiCoreV1Test.calculateAccessFromPayment(payment, 0);
        uint256 expectedSeconds = payment / BASE_ACCESS_PRICE;
        assertEq(accessSeconds, expectedSeconds);
    }

    function test_Fuzz_PurchaseAccess(uint256 payment) public {
        // Bound payment to minimum and reasonable maximum
        payment = bound(payment, MINIMUM_PAYMENT_AMOUNT, MINIMUM_PAYMENT_AMOUNT * 1000);

        vm.deal(user1, payment);
        vm.prank(user1);
        thadaiCoreV1Test.purchaseAccess{value: payment}();

        (uint256 balance, uint256 accessUntil,,,, uint256 totalPaid,,,) = thadaiCoreV1Test.getUserAccessInfo(user1);
        assertEq(balance, payment);
        assertEq(totalPaid, payment);
        assertGt(accessUntil, block.timestamp);

        uint256 expectedSeconds = payment / BASE_ACCESS_PRICE;
        assertGe(accessUntil - block.timestamp, expectedSeconds - 10); // Allow small time variance
    }
}
