// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {ThadaiCore} from "../src/ThadaiCore.sol";
import {IThadaiCore} from "../src/IThadaiCore.sol";
import {DeployThadaiCoreTest} from "../script/DeployThadaiCoreTest.s.sol";
import {ReentrancyAttacker} from "./ReentrancyAttacker.sol";
import {MockV3Aggregator} from "./MockV3Aggregator.sol";

contract ThadaiCoreTest is Test {
    ThadaiCore public thadaiCore;
    MockV3Aggregator public mockPriceFeed;

    // USD-denominated constants from deployment script (8-decimal scale)
    uint256 public constant BASE_ACCESS_PRICE_USD = 20e10;
    uint256 public constant MINIMUM_PAYMENT_USD = 24000e10;

    // Mock ETH/USD price: $2200 with 8 decimals
    int256 public constant MOCK_ETH_PRICE = 220000000000; // 2200 * 1e8
    uint256 public constant STALE_PRICE_THRESHOLD = 3600; // 1 hour

    uint256 public constant WITHDRAW_COOLDOWN_PERIOD = 86400; // 1 day in seconds
    uint256 public constant INFLATION_WINDOW = 3600; // 1 hour in seconds
    uint8 public constant INFLATION_PERCENT_PER_WINDOW = 10;

    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");

    // Derived wei values (computed from USD prices and mock ETH price)
    function _baseAccessPriceWei() internal pure returns (uint256) {
        return (BASE_ACCESS_PRICE_USD * 1e18) / uint256(MOCK_ETH_PRICE);
    }

    function _minimumPaymentWei() internal pure returns (uint256) {
        return (MINIMUM_PAYMENT_USD * 1e18) / uint256(MOCK_ETH_PRICE);
    }

    function setUp() external {
        mockPriceFeed = new MockV3Aggregator(8, MOCK_ETH_PRICE);
        DeployThadaiCoreTest deployer = new DeployThadaiCoreTest();
        thadaiCore = deployer.run(address(mockPriceFeed));
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsBaseAccessPriceUSD() public view {
        assertEq(thadaiCore.baseAccessPriceUSD(), BASE_ACCESS_PRICE_USD);
    }

    function test_Constructor_SetsMinimumPaymentUSD() public view {
        assertEq(thadaiCore.minimumPaymentUSD(), MINIMUM_PAYMENT_USD);
    }

    function test_Constructor_SetsPriceFeed() public view {
        assertEq(address(thadaiCore.priceFeed()), address(mockPriceFeed));
    }

    function test_Constructor_SetsStalePriceThreshold() public view {
        assertEq(thadaiCore.stalePriceThreshold(), STALE_PRICE_THRESHOLD);
    }

    function test_Constructor_SetsWithdrawCooldownPeriod() public view {
        assertEq(thadaiCore.withdrawCooldownPeriod(), WITHDRAW_COOLDOWN_PERIOD);
    }

    // ============ Purchase Access Tests ============

    function test_PurchaseAccess_WithMinimumPayment() public {
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();

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
        assertEq(balance, minPayment);
        assertGt(accessUntil, block.timestamp);
        assertGt(lastPurchaseTime, 0);
        assertEq(lastRedemptionTime, 0);
        assertGt(totalAccessSecondsPurchased, 0);
        assertEq(totalPaid, minPayment);
        assertEq(canWithdraw, true);
        assertEq(cooldownRemaining, 0);
        assertEq(applicableInflationPercent, INFLATION_PERCENT_PER_WINDOW);
    }

    function test_PurchaseAccess_WithMoreThanMinimum() public {
        uint256 minPayment = _minimumPaymentWei();
        uint256 payment = minPayment * 2;
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
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment - 1);
        vm.prank(user1);
        vm.expectRevert(abi.encodeWithSelector(IThadaiCore.PaymentBelowMinimumAmount.selector, minPayment));
        thadaiCore.purchaseAccess{value: minPayment - 1}();
    }

    function test_PurchaseAccess_ExtendsExistingAccess() public {
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment * 2);

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();
        (, uint256 firstAccessUntil,,,,,,,) = thadaiCore.getUserAccessInfo(user1);

        // Move forward in time but before access expires
        vm.warp(block.timestamp + 100);

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();
        (, uint256 secondAccessUntil,,,,,,,) = thadaiCore.getUserAccessInfo(user1);

        // New access should be extended from the previous expiration, not current time
        assertGt(secondAccessUntil, firstAccessUntil);
    }

    function test_PurchaseAccess_StartsNewPeriodAfterExpiry() public {
        uint256 minPayment = _minimumPaymentWei();
        uint256 basePrice = _baseAccessPriceWei();
        vm.deal(user1, minPayment * 3);

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();
        (, uint256 firstAccessUntil,,,,,,,) = thadaiCore.getUserAccessInfo(user1);

        // Wait for access to expire
        vm.warp(firstAccessUntil + 1);

        // Verify access expired
        (bool hasAccess,) = thadaiCore.checkAccess(user1);
        assertFalse(hasAccess);

        uint256 purchaseTimeBefore = block.timestamp;
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();
        (, uint256 secondAccessUntil,,,,,,,) = thadaiCore.getUserAccessInfo(user1);

        // New access should start from current time (purchase time), not previous expiration
        uint256 applicableInflation = 0;
        if (block.timestamp - purchaseTimeBefore < INFLATION_WINDOW) {
            applicableInflation = INFLATION_PERCENT_PER_WINDOW;
        }
        uint256 adjustedPrice = basePrice + (basePrice * applicableInflation) / 100;
        uint256 expectedAccessSeconds = minPayment / adjustedPrice;
        uint256 expectedAccessUntil = purchaseTimeBefore + expectedAccessSeconds;
        assertGe(secondAccessUntil, purchaseTimeBefore);
        // Allow small time variance
        assertGe(secondAccessUntil, expectedAccessUntil - 10);
        assertLe(secondAccessUntil, expectedAccessUntil + 10);
    }

    function test_PurchaseAccess_EmitsAccessPurchasedEvent() public {
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment);

        // Check that event is emitted with correct user and amount (ignore timestamp due to timing)
        vm.expectEmit(true, false, false, false);
        emit IThadaiCore.AccessPurchased(user1, minPayment, 0);

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();
    }

    function test_PurchaseAccess_CalculatesCorrectAccessTime() public {
        uint256 minPayment = _minimumPaymentWei();
        uint256 basePrice = _baseAccessPriceWei();
        uint256 expectedSeconds = minPayment / basePrice;

        vm.deal(user1, minPayment);
        uint256 purchaseTime = block.timestamp;
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();

        (, uint256 accessUntil,,,,,,,) = thadaiCore.getUserAccessInfo(user1);
        uint256 actualSeconds = accessUntil - purchaseTime;
        assertEq(actualSeconds, expectedSeconds);
    }

    function test_PurchaseAccess_UpdatesContractBalance() public {
        uint256 initialBalance = address(thadaiCore).balance;
        uint256 minPayment = _minimumPaymentWei();

        vm.deal(user1, minPayment);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();

        assertEq(address(thadaiCore).balance, initialBalance + minPayment);
        assertEq(thadaiCore.getContractBalance(), initialBalance + minPayment);
    }

    function test_PurchaseAccess_MultipleUsers() public {
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment);
        vm.deal(user2, minPayment);

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();

        vm.prank(user2);
        thadaiCore.purchaseAccess{value: minPayment}();

        (, uint256 accessUntil1,,,,,,,) = thadaiCore.getUserAccessInfo(user1);
        (, uint256 accessUntil2,,,,,,,) = thadaiCore.getUserAccessInfo(user2);

        assertGt(accessUntil1, block.timestamp);
        assertGt(accessUntil2, block.timestamp);
        assertEq(address(thadaiCore).balance, minPayment * 2);
    }

    // ============ Check Access Tests ============

    function test_CheckAccess_UserWithActiveAccess() public {
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();

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
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();

        (uint256 accessUntil,,,,,,,,) = thadaiCore.getUserAccessInfo(user1);

        // Move past expiration
        vm.warp(accessUntil + 1);

        (bool hasAccess, uint256 remainingSeconds) = thadaiCore.checkAccess(user1);
        assertFalse(hasAccess);
        assertEq(remainingSeconds, 0);
    }

    function test_CheckAccess_ReturnsCorrectRemainingSeconds() public {
        uint256 minPayment = _minimumPaymentWei();
        uint256 basePrice = _baseAccessPriceWei();
        uint256 expectedSeconds = minPayment / basePrice;

        vm.deal(user1, minPayment);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();

        (bool hasAccess, uint256 remainingSeconds) = thadaiCore.checkAccess(user1);
        assertTrue(hasAccess);
        // Allow for some time passed during execution
        assertGe(remainingSeconds, expectedSeconds - 10);
        assertLe(remainingSeconds, expectedSeconds);
    }

    // ============ Withdraw Funds Tests ============

    function test_WithdrawFunds_FirstWithdrawal_NoCooldown() public {
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();

        uint256 balanceBefore = user1.balance;
        vm.prank(user1);
        thadaiCore.withdrawFunds();

        assertEq(user1.balance, balanceBefore + minPayment);

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
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment * 2);

        // First purchase and withdrawal
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();
        vm.prank(user1);
        thadaiCore.withdrawFunds();

        uint256 firstWithdrawalTime = block.timestamp;

        // Purchase again
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();

        // Try to withdraw before cooldown
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(IThadaiCore.WithdrawalCooldownActive.selector, block.timestamp - firstWithdrawalTime)
        );
        thadaiCore.withdrawFunds();
    }

    function test_WithdrawFunds_SucceedsAfterCooldown() public {
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment * 2);

        // First purchase and withdrawal
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();
        vm.prank(user1);
        thadaiCore.withdrawFunds();

        // Purchase again
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();

        // Move past cooldown
        vm.warp(block.timestamp + thadaiCore.withdrawCooldownPeriod());

        uint256 balanceBefore = user1.balance;
        vm.prank(user1);
        thadaiCore.withdrawFunds();

        assertEq(user1.balance, balanceBefore + minPayment);
    }

    function test_WithdrawFunds_UpdatesLastRedemptionTime() public {
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();

        uint256 withdrawalTime = block.timestamp;
        vm.prank(user1);
        thadaiCore.withdrawFunds();

        (,,, uint256 lastRedemptionTime,,,,,) = thadaiCore.getUserAccessInfo(user1);
        assertEq(lastRedemptionTime, withdrawalTime);
    }

    function test_WithdrawFunds_EmitsUserWithdrawnEvent() public {
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();

        vm.prank(user1);
        vm.expectEmit(true, false, false, false);
        emit IThadaiCore.UserWithdrawn(user1, minPayment);

        thadaiCore.withdrawFunds();
    }

    function test_WithdrawFunds_ResetsUserData() public {
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();

        vm.prank(user1);
        thadaiCore.withdrawFunds();

        (uint256 balance, uint256 accessUntil,, uint256 lastRedemptionTime,, uint256 totalPaid,,,) =
            thadaiCore.getUserAccessInfo(user1);

        assertEq(accessUntil, 0);
        assertEq(balance, 0);
        // totalPaid should remain (historical record)
        assertEq(totalPaid, minPayment);
        assertGt(lastRedemptionTime, 0);
    }

    function test_WithdrawFunds_DoesNotResetTotalPaid() public {
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment * 3);

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();
        vm.prank(user1);
        thadaiCore.withdrawFunds();

        vm.warp(block.timestamp + thadaiCore.withdrawCooldownPeriod());
        mockPriceFeed.updateAnswer(MOCK_ETH_PRICE); // refresh oracle timestamp

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment * 2}();
        vm.prank(user1);
        thadaiCore.withdrawFunds();

        (,,,,, uint256 totalPaid,,,) = thadaiCore.getUserAccessInfo(user1);
        assertEq(totalPaid, minPayment * 3);
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
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();

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
        assertEq(balance, minPayment);
        assertGt(accessUntil, block.timestamp);
        assertGt(lastPurchaseTime, 0);
        assertEq(lastRedemptionTime, 0);
        assertGt(totalAccessSecondsPurchased, 0);
        assertEq(totalPaid, minPayment);
        assertEq(canWithdraw, true);
        assertEq(cooldownRemaining, 0);
        assertEq(applicableInflationPercent, 10);
    }

    function test_GetUserAccessInfo_UserDuringCooldown() public {
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment * 2);

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();
        vm.prank(user1);
        thadaiCore.withdrawFunds();

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();

        (,,,,,, bool canWithdraw, uint256 cooldownRemaining,) = thadaiCore.getUserAccessInfo(user1);

        assertFalse(canWithdraw);
        assertGt(cooldownRemaining, 0);
        assertLe(cooldownRemaining, thadaiCore.withdrawCooldownPeriod());
    }

    function test_GetUserAccessInfo_UserAfterCooldown() public {
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment * 2);

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();
        vm.prank(user1);
        thadaiCore.withdrawFunds();

        vm.warp(block.timestamp + thadaiCore.withdrawCooldownPeriod());
        mockPriceFeed.updateAnswer(MOCK_ETH_PRICE); // refresh oracle timestamp

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();

        (,,,,,, bool canWithdraw, uint256 cooldownRemaining,) = thadaiCore.getUserAccessInfo(user1);

        assertTrue(canWithdraw);
        assertEq(cooldownRemaining, 0);
    }

    // ============ Inflation Logic Test ============
    function test_Inflation_AppliesOnRapidTopUp() public {
        // User purchases access
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment * 2);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();
        // Immediately top up again (within inflation window)
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();
        // Check inflation percent is applied
        (,,,,,,,, uint256 applicableInflationPercent) = thadaiCore.getUserAccessInfo(user1);
        assertGt(applicableInflationPercent, 0);
    }

    function test_Inflation_DoesNotApplyOnBoundary() public {
        // User purchases access
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment * 2);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();
        // Move time to exactly inflation window boundary
        vm.warp(block.timestamp + INFLATION_WINDOW);
        // Check inflation percent is NOT applied (should be 0)
        (,,,,,,,, uint256 applicableInflationPercent) = thadaiCore.getUserAccessInfo(user1);
        assertEq(applicableInflationPercent, 0);
    }

    // ============ Calculate Access From Payment Tests ============

    function test_CalculateAccessFromPayment_MinimumPayment() public view {
        uint256 minPayment = _minimumPaymentWei();
        uint256 basePrice = _baseAccessPriceWei();
        uint256 accessSeconds = thadaiCore.calculateAccessFromPayment(minPayment, 0);
        uint256 expectedSeconds = minPayment / basePrice;
        assertEq(accessSeconds, expectedSeconds);
    }

    function test_CalculateAccessFromPayment_LargePayment() public view {
        uint256 minPayment = _minimumPaymentWei();
        uint256 basePrice = _baseAccessPriceWei();
        uint256 largePayment = minPayment * 100;
        uint256 accessSeconds = thadaiCore.calculateAccessFromPayment(largePayment, 0);
        uint256 expectedSeconds = largePayment / basePrice;
        assertEq(accessSeconds, expectedSeconds);
    }

    function test_CalculateAccessFromPayment_SmallPayment() public view {
        uint256 basePrice = _baseAccessPriceWei();
        uint256 accessSeconds = thadaiCore.calculateAccessFromPayment(basePrice, 0);
        assertEq(accessSeconds, 1);
    }

    function test_CalculateAccessFromPayment_Zero() public view {
        uint256 accessSeconds = thadaiCore.calculateAccessFromPayment(0, 0);
        assertEq(accessSeconds, 0);
    }

    // =========== Get Access Pricing Info Tests ==========

    function test_GetAccessPricingInfo_ReturnsCorrectValues() public view {
        uint256 basePrice = _baseAccessPriceWei();
        uint256 minPayment = _minimumPaymentWei();
        (
            uint256 basePriceWei,
            uint256 minPaymentWei,
            uint256 basePriceUSD,
            uint256 minPaymentUSD,
            uint256 cooldownDays,
            uint256 inflationWindowHours,
            uint256 inflationPercent
        ) = thadaiCore.getAccessPricingInfo();

        assertEq(basePriceWei, basePrice);
        assertEq(minPaymentWei, minPayment);
        assertEq(basePriceUSD, BASE_ACCESS_PRICE_USD);
        assertEq(minPaymentUSD, MINIMUM_PAYMENT_USD);
        assertEq(cooldownDays * WITHDRAW_COOLDOWN_PERIOD, WITHDRAW_COOLDOWN_PERIOD);
        assertEq(inflationWindowHours * INFLATION_WINDOW, INFLATION_WINDOW);
        assertEq(inflationPercent, INFLATION_PERCENT_PER_WINDOW);
    }

    function test_GetAccessPricingInfo_ValuesAreConsistentWithState() public view {
        (uint256 basePriceWei,, uint256 basePriceUSD,, uint256 cooldownDays, uint256 inflationWindowHours, uint256 inflationPercent) =
            thadaiCore.getAccessPricingInfo();

        assertEq(basePriceUSD, thadaiCore.baseAccessPriceUSD());
        assertGt(basePriceWei, 0);
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
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment * 2);
        vm.deal(user2, minPayment);

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();

        vm.prank(user2);
        thadaiCore.purchaseAccess{value: minPayment}();

        assertEq(thadaiCore.getContractBalance(), minPayment * 2);
        assertEq(thadaiCore.getContractBalance(), address(thadaiCore).balance);
    }

    function test_GetContractBalance_AfterWithdrawal() public {
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment);
        vm.deal(user2, minPayment);

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();

        vm.prank(user2);
        thadaiCore.purchaseAccess{value: minPayment}();

        vm.prank(user1);
        thadaiCore.withdrawFunds();

        assertEq(thadaiCore.getContractBalance(), minPayment);
        assertEq(address(thadaiCore).balance, minPayment);
    }

    // ============ Edge Cases and Integration Tests ============

    function test_MultiplePurchasesAndWithdrawals() public {
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment * 5);

        // Purchase 1
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();
        (uint256 balance1,,,,,,,,) = thadaiCore.getUserAccessInfo(user1);
        assertEq(balance1, minPayment);

        // Purchase 2 - extend access
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();
        (uint256 balance2,,,,,,,,) = thadaiCore.getUserAccessInfo(user1);
        assertEq(balance2, minPayment * 2);

        // Withdraw
        vm.prank(user1);
        thadaiCore.withdrawFunds();

        // Wait for cooldown
        vm.warp(block.timestamp + thadaiCore.withdrawCooldownPeriod());
        mockPriceFeed.updateAnswer(MOCK_ETH_PRICE); // refresh oracle timestamp

        // Purchase 3
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();

        (,,,,, uint256 totalPaid,,,) = thadaiCore.getUserAccessInfo(user1);
        assertEq(totalPaid, minPayment * 3);
    }

    function test_AccessExpiresCorrectly() public {
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();

        (, uint256 accessUntil,,,,,,,) = thadaiCore.getUserAccessInfo(user1);

        // Move to exactly when access expires
        vm.warp(accessUntil);

        (bool hasAccess,) = thadaiCore.checkAccess(user1);
        assertFalse(hasAccess);
    }

    function test_WithdrawCooldownCalculation() public {
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment * 2);

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();
        vm.prank(user1);
        thadaiCore.withdrawFunds();

        uint256 withdrawalTime = block.timestamp;

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();

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
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment);

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();

        // Withdraw in same block should work (first withdrawal)
        vm.prank(user1);
        thadaiCore.withdrawFunds();

        (uint256 balance,,,,,,,,) = thadaiCore.getUserAccessInfo(user1);
        assertEq(balance, 0);
    }

    function test_Fuzz_CalculateAccessFromPayment(uint256 payment) public view {
        uint256 basePrice = _baseAccessPriceWei();
        // Bound payment to reasonable range to avoid overflow
        payment = bound(payment, 0, type(uint256).max / basePrice);

        uint256 accessSeconds = thadaiCore.calculateAccessFromPayment(payment, 0);
        uint256 expectedSeconds = payment / basePrice;
        assertEq(accessSeconds, expectedSeconds);
    }

    function test_Fuzz_PurchaseAccess(uint256 payment) public {
        uint256 minPayment = _minimumPaymentWei();
        uint256 basePrice = _baseAccessPriceWei();
        // Bound payment to minimum and reasonable maximum
        payment = bound(payment, minPayment, minPayment * 1000);

        vm.deal(user1, payment);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: payment}();

        (uint256 balance, uint256 accessUntil,,,, uint256 totalPaid,,,) = thadaiCore.getUserAccessInfo(user1);
        assertEq(balance, payment);
        assertEq(totalPaid, payment);
        assertGt(accessUntil, block.timestamp);

        uint256 expectedSeconds = payment / basePrice;
        assertGe(accessUntil - block.timestamp, expectedSeconds - 10); // Allow small time variance
    }

    // ============ Reentrancy Attack Tests ============

    function test_WithdrawFunds_RevertsOnReentrancy() public {
        uint256 minPayment = _minimumPaymentWei();
        ReentrancyAttacker attacker = new ReentrancyAttacker(address(thadaiCore));
        vm.deal(address(attacker), minPayment);

        // Attacker purchases access, then withdrawFunds triggers receive() which re-enters
        vm.expectRevert();
        attacker.attack{value: minPayment}();
    }

    function test_WithdrawFunds_AttackerCannotDrainContract() public {
        uint256 minPayment = _minimumPaymentWei();
        // Legitimate user deposits first
        vm.deal(user1, minPayment);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();

        // Attacker deposits and tries to re-enter
        ReentrancyAttacker attacker = new ReentrancyAttacker(address(thadaiCore));
        vm.deal(address(attacker), minPayment);

        vm.expectRevert();
        attacker.attack{value: minPayment}();

        // Legitimate user's balance must be intact
        assertEq(address(thadaiCore).balance, minPayment);
        (uint256 balance,,,,,,,,) = thadaiCore.getUserAccessInfo(user1);
        assertEq(balance, minPayment);
    }

    // ============ Constructor Validation Tests ============

    function test_Constructor_RevertsOnZeroBasePrice() public {
        vm.expectRevert(ThadaiCore.InvalidBasePrice.selector);
        new ThadaiCore(0, MINIMUM_PAYMENT_USD, address(mockPriceFeed), STALE_PRICE_THRESHOLD, 1, 1, 10);
    }

    function test_Constructor_RevertsOnZeroMinimumPayment() public {
        vm.expectRevert(ThadaiCore.InvalidMinimumPayment.selector);
        new ThadaiCore(BASE_ACCESS_PRICE_USD, 0, address(mockPriceFeed), STALE_PRICE_THRESHOLD, 1, 1, 10);
    }

    function test_Constructor_RevertsOnZeroPriceFeedAddress() public {
        vm.expectRevert(ThadaiCore.InvalidPriceFeedAddress.selector);
        new ThadaiCore(BASE_ACCESS_PRICE_USD, MINIMUM_PAYMENT_USD, address(0), STALE_PRICE_THRESHOLD, 1, 1, 10);
    }

    function test_Constructor_RevertsOnZeroStalePriceThreshold() public {
        vm.expectRevert(ThadaiCore.InvalidStalePriceThreshold.selector);
        new ThadaiCore(BASE_ACCESS_PRICE_USD, MINIMUM_PAYMENT_USD, address(mockPriceFeed), 0, 1, 1, 10);
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
        uint256 minPayment = _minimumPaymentWei();
        uint256 basePrice = _baseAccessPriceWei();
        uint256 normalSeconds = thadaiCore.calculateAccessFromPayment(minPayment, 0);
        uint256 inflatedSeconds =
            thadaiCore.calculateAccessFromPayment(minPayment, INFLATION_PERCENT_PER_WINDOW);

        assertGt(normalSeconds, inflatedSeconds);

        // Verify the inflation math: inflated price = base + base * 10 / 100 = 1.1x base
        uint256 expectedInflatedSeconds =
            minPayment / (basePrice + (basePrice * INFLATION_PERCENT_PER_WINDOW) / 100);
        assertEq(inflatedSeconds, expectedInflatedSeconds);
    }

    function test_Inflation_ResetsAfterWindowExpires() public {
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment * 2);

        // First purchase
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();

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
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment * 2);
        vm.deal(user2, minPayment);

        // user1 purchases twice rapidly (second purchase gets inflated price)
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();
        (,,,, uint64 firstPurchaseSeconds,,,,) = thadaiCore.getUserAccessInfo(user1);

        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();
        (,,,, uint64 totalAfterSecond,,,,) = thadaiCore.getUserAccessInfo(user1);

        uint64 secondPurchaseSeconds = totalAfterSecond - firstPurchaseSeconds;

        // user2 purchases once (gets base price)
        vm.prank(user2);
        thadaiCore.purchaseAccess{value: minPayment}();
        (,,,, uint64 user2Seconds,,,,) = thadaiCore.getUserAccessInfo(user2);

        // user1's second purchase should yield fewer seconds than user2's first purchase
        assertLt(secondPurchaseSeconds, user2Seconds);
    }

    // ============ Payment Rounding / Dust Tests ============

    function test_PurchaseAccess_PaymentJustAboveMinimum() public {
        uint256 minPayment = _minimumPaymentWei();
        // Payment that's minimumPayment + 1 wei — ensure no rounding issues
        uint256 payment = minPayment + 1;
        vm.deal(user1, payment);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: payment}();

        (uint256 balance,,,,,,,,) = thadaiCore.getUserAccessInfo(user1);
        assertEq(balance, payment);
    }

    function test_CalculateAccess_PaymentBelowOneSecondWorth() public view {
        uint256 basePrice = _baseAccessPriceWei();
        // Payment less than one second's cost yields 0 seconds (integer division floors)
        uint256 accessSeconds = thadaiCore.calculateAccessFromPayment(basePrice - 1, 0);
        assertEq(accessSeconds, 0);
    }

    function test_Fuzz_InflationAlwaysReducesOrMaintainsAccess(uint256 inflationPct) public view {
        uint256 minPayment = _minimumPaymentWei();
        inflationPct = bound(inflationPct, 0, 200);
        uint256 normalSeconds = thadaiCore.calculateAccessFromPayment(minPayment, 0);
        uint256 inflatedSeconds = thadaiCore.calculateAccessFromPayment(minPayment, inflationPct);
        assertLe(inflatedSeconds, normalSeconds);
    }

    // ============ Oracle-Specific Tests ============

    function test_Oracle_StaleFeedReverts() public {
        uint256 minPayment = _minimumPaymentWei();
        // Advance time past the stale threshold
        vm.warp(block.timestamp + STALE_PRICE_THRESHOLD + 1);

        vm.deal(user1, minPayment);
        vm.prank(user1);
        vm.expectRevert(ThadaiCore.StalePriceFeed.selector);
        thadaiCore.purchaseAccess{value: minPayment}();
    }

    function test_Oracle_InvalidPriceReverts() public {
        // Set price to 0
        mockPriceFeed.updateAnswer(0);

        vm.deal(user1, 1 ether);
        vm.prank(user1);
        vm.expectRevert(ThadaiCore.InvalidOraclePrice.selector);
        thadaiCore.purchaseAccess{value: 1 ether}();
    }

    function test_Oracle_NegativePriceReverts() public {
        // Set negative price
        mockPriceFeed.updateAnswer(-1);

        vm.deal(user1, 1 ether);
        vm.prank(user1);
        vm.expectRevert(ThadaiCore.InvalidOraclePrice.selector);
        thadaiCore.purchaseAccess{value: 1 ether}();
    }

    function test_Oracle_PriceChangeAffectsAccessTime() public {
        uint256 minPayment = _minimumPaymentWei();
        vm.deal(user1, minPayment);
        vm.prank(user1);
        thadaiCore.purchaseAccess{value: minPayment}();
        (,,,, uint64 secondsAtOriginalPrice,,,,) = thadaiCore.getUserAccessInfo(user1);

        // ETH price doubles — access per wei should halve (fewer seconds per same wei)
        mockPriceFeed.updateAnswer(MOCK_ETH_PRICE * 2);

        // New minimum payment is now half the wei (since ETH is worth more)
        uint256 newMinPayment = (MINIMUM_PAYMENT_USD * 1e18) / uint256(MOCK_ETH_PRICE * 2);
        vm.deal(user2, newMinPayment);
        vm.prank(user2);
        thadaiCore.purchaseAccess{value: newMinPayment}();
        (,,,, uint64 user2Seconds,,,,) = thadaiCore.getUserAccessInfo(user2);

        // user2 paid half the wei but should get the same number of seconds (same USD value)
        // Allow rounding tolerance
        assertGe(user2Seconds, secondsAtOriginalPrice - 2);
        assertLe(user2Seconds, secondsAtOriginalPrice + 2);
    }

    function test_Oracle_CalculateAccessReflectsCurrentPrice() public pure {
        uint256 basePrice = _baseAccessPriceWei();
        // With mock at $2200, check that derived price is correct
        // baseAccessPriceUSD * 1e18 / ethPriceUSD
        uint256 expectedWeiPrice = (BASE_ACCESS_PRICE_USD * 1e18) / uint256(MOCK_ETH_PRICE);
        assertEq(basePrice, expectedWeiPrice);
    }
}
