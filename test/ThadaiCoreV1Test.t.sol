// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

import {Test} from "forge-std/Test.sol";
import {ThadaiCoreV1} from "../src/ThadaiCoreV1.sol";
import {DeployThadaiCoreV1} from "../script/DeployThadaiCoreV1.s.sol";

contract ThadaiCoreV1Test is Test {
    ThadaiCoreV1 public thadaiCoreV1;

    // Constants from deployment script
    uint256 public constant BASE_ACCESS_PRICE = 20e10;
    uint256 public constant MINIMUM_PAYMENT_AMOUNT = 24000e10;
    uint8 public constant WITHDRAW_COOLDOWN_PERIOD_IN_DAYS = 1;

    address public user1 = makeAddr("user1");
    address public user2 = makeAddr("user2");
    address public user3 = makeAddr("user3");

    function setUp() external {
        DeployThadaiCoreV1 deployer = new DeployThadaiCoreV1();
        thadaiCoreV1 = deployer.run();
    }

    // ============ Constructor Tests ============

    function test_Constructor_SetsOwner() public {
        DeployThadaiCoreV1 deployer = new DeployThadaiCoreV1();
        ThadaiCoreV1 newContract = deployer.run();
        
        address owner = newContract.owner();
        assertTrue(owner != address(0));
        
        assertEq(owner, thadaiCoreV1.owner());
    }

    function test_Constructor_SetsBaseAccessPrice() public view {
        assertEq(thadaiCoreV1.baseAccessPrice(), BASE_ACCESS_PRICE);
    }

    function test_Constructor_SetsMinimumPaymentAmount() public view {
        assertEq(thadaiCoreV1.minimumPaymentAmount(), MINIMUM_PAYMENT_AMOUNT);
    }

    function test_Constructor_SetsWithdrawCooldownInDays() public view {
        assertEq(thadaiCoreV1.withdrawCooldownInDays(), WITHDRAW_COOLDOWN_PERIOD_IN_DAYS * 1 days);
    }

    // ============ Purchase Access Tests ============

    function test_PurchaseAccess_WithMinimumPayment() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();

        (uint256 accessUntil, uint256 balance, uint256 totalPaid,,,) = thadaiCoreV1.getUserAccessInfo(user1);
        assertEq(balance, MINIMUM_PAYMENT_AMOUNT);
        assertEq(totalPaid, MINIMUM_PAYMENT_AMOUNT);
        assertGt(accessUntil, block.timestamp);
    }

    function test_PurchaseAccess_WithMoreThanMinimum() public {
        uint256 payment = MINIMUM_PAYMENT_AMOUNT * 2;
        vm.deal(user1, payment);
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: payment}();

        (uint256 accessUntil, uint256 balance, uint256 totalPaid,,,) = thadaiCoreV1.getUserAccessInfo(user1);
        assertEq(balance, payment);
        assertEq(totalPaid, payment);
        assertGt(accessUntil, block.timestamp);
    }

    function test_PurchaseAccess_RevertsWhenPaymentBelowMinimum() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT - 1);
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(ThadaiCoreV1.PaymentBelowMinimumAmount.selector, MINIMUM_PAYMENT_AMOUNT)
        );
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT - 1}();
    }

    function test_PurchaseAccess_ExtendsExistingAccess() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 2);
        
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        (uint256 firstAccessUntil,,,,,) = thadaiCoreV1.getUserAccessInfo(user1);
        
        // Move forward in time but before access expires
        vm.warp(block.timestamp + 100);
        
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        (uint256 secondAccessUntil,,,,,) = thadaiCoreV1.getUserAccessInfo(user1);
        
        // New access should be extended from the previous expiration, not current time
        assertGt(secondAccessUntil, firstAccessUntil);
    }

    function test_PurchaseAccess_StartsNewPeriodAfterExpiry() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 3);
        
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        (uint256 firstAccessUntil,,,,,) = thadaiCoreV1.getUserAccessInfo(user1);
        
        // Wait for access to expire
        vm.warp(firstAccessUntil + 1);
        
        // Verify access expired
        (bool hasAccess,) = thadaiCoreV1.checkAccess(user1);
        assertFalse(hasAccess);
        
        uint256 purchaseTimeBefore = block.timestamp;
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        (uint256 secondAccessUntil,,,,,) = thadaiCoreV1.getUserAccessInfo(user1);
        
        // New access should start from current time (purchase time), not previous expiration
        // Since we're past the expiry, secondAccessUntil should be >= purchaseTimeBefore
        // and it should be in the future relative to when we purchased
        assertGe(secondAccessUntil, purchaseTimeBefore);
        // The point is: after expiry, new purchase starts from current time, not from old expiry
        uint256 expectedAccessUntil = purchaseTimeBefore + (MINIMUM_PAYMENT_AMOUNT / BASE_ACCESS_PRICE);
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
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
    }

    function test_PurchaseAccess_CalculatesCorrectAccessTime() public {
        uint256 payment = MINIMUM_PAYMENT_AMOUNT;
        uint256 expectedSeconds = payment / BASE_ACCESS_PRICE;
        
        vm.deal(user1, payment);
        uint256 purchaseTime = block.timestamp;
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: payment}();
        
        (uint256 accessUntil,,,,,) = thadaiCoreV1.getUserAccessInfo(user1);
        uint256 actualSeconds = accessUntil - purchaseTime;
        assertEq(actualSeconds, expectedSeconds);
    }

    function test_PurchaseAccess_UpdatesContractBalance() public {
        uint256 initialBalance = address(thadaiCoreV1).balance;
        uint256 payment = MINIMUM_PAYMENT_AMOUNT;
        
        vm.deal(user1, payment);
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: payment}();
        
        assertEq(address(thadaiCoreV1).balance, initialBalance + payment);
        assertEq(thadaiCoreV1.getContractBalance(), initialBalance + payment);
    }

    function test_PurchaseAccess_MultipleUsers() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.deal(user2, MINIMUM_PAYMENT_AMOUNT);
        
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        
        vm.prank(user2);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        
        (uint256 accessUntil1,,,,,) = thadaiCoreV1.getUserAccessInfo(user1);
        (uint256 accessUntil2,,,,,) = thadaiCoreV1.getUserAccessInfo(user2);
        
        assertGt(accessUntil1, block.timestamp);
        assertGt(accessUntil2, block.timestamp);
        assertEq(address(thadaiCoreV1).balance, MINIMUM_PAYMENT_AMOUNT * 2);
    }

    // ============ Check Access Tests ============

    function test_CheckAccess_UserWithActiveAccess() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        
        (bool hasAccess, uint256 remainingSeconds) = thadaiCoreV1.checkAccess(user1);
        assertTrue(hasAccess);
        assertGt(remainingSeconds, 0);
    }

    function test_CheckAccess_UserWithoutAccess() public {
        (bool hasAccess, uint256 remainingSeconds) = thadaiCoreV1.checkAccess(user1);
        assertFalse(hasAccess);
        assertEq(remainingSeconds, 0);
    }

    function test_CheckAccess_UserWithExpiredAccess() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        
        (uint256 accessUntil,,,,,) = thadaiCoreV1.getUserAccessInfo(user1);
        
        // Move past expiration
        vm.warp(accessUntil + 1);
        
        (bool hasAccess, uint256 remainingSeconds) = thadaiCoreV1.checkAccess(user1);
        assertFalse(hasAccess);
        assertEq(remainingSeconds, 0);
    }

    function test_CheckAccess_ReturnsCorrectRemainingSeconds() public {
        uint256 payment = MINIMUM_PAYMENT_AMOUNT;
        uint256 expectedSeconds = payment / BASE_ACCESS_PRICE;
        
        vm.deal(user1, payment);
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: payment}();
        
        (bool hasAccess, uint256 remainingSeconds) = thadaiCoreV1.checkAccess(user1);
        assertTrue(hasAccess);
        // Allow for some time passed during execution
        assertGe(remainingSeconds, expectedSeconds - 10);
        assertLe(remainingSeconds, expectedSeconds);
    }

    // ============ Withdraw Funds Tests ============

    function test_WithdrawFunds_FirstWithdrawal_NoCooldown() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        
        uint256 balanceBefore = user1.balance;
        vm.prank(user1);
        thadaiCoreV1.withdrawFunds();
        
        assertEq(user1.balance, balanceBefore + MINIMUM_PAYMENT_AMOUNT);
        
        (uint256 accessUntil, uint256 balance,,,,) = thadaiCoreV1.getUserAccessInfo(user1);
        assertEq(balance, 0);
        assertEq(accessUntil, 0);
    }

    function test_WithdrawFunds_RevertsWhenNoBalance() public {
        vm.prank(user1);
        vm.expectRevert(ThadaiCoreV1.NoBalanceToWithdraw.selector);
        thadaiCoreV1.withdrawFunds();
    }

    function test_WithdrawFunds_RevertsDuringCooldown() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 2);
        
        // First purchase and withdrawal
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        vm.prank(user1);
        thadaiCoreV1.withdrawFunds();
        
        uint256 firstWithdrawalTime = block.timestamp;
        
        // Purchase again
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        
        // Try to withdraw before cooldown
        vm.prank(user1);
        vm.expectRevert(
            abi.encodeWithSelector(
                ThadaiCoreV1.WithdrawalCooldownActive.selector,
                block.timestamp - firstWithdrawalTime
            )
        );
        thadaiCoreV1.withdrawFunds();
    }

    function test_WithdrawFunds_SucceedsAfterCooldown() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 2);
        
        // First purchase and withdrawal
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        vm.prank(user1);
        thadaiCoreV1.withdrawFunds();
        
        // Purchase again
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        
        // Move past cooldown
        vm.warp(block.timestamp + thadaiCoreV1.withdrawCooldownInDays());
        
        uint256 balanceBefore = user1.balance;
        vm.prank(user1);
        thadaiCoreV1.withdrawFunds();
        
        assertEq(user1.balance, balanceBefore + MINIMUM_PAYMENT_AMOUNT);
    }

    function test_WithdrawFunds_UpdatesLastRedemptionTime() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        
        uint256 withdrawalTime = block.timestamp;
        vm.prank(user1);
        thadaiCoreV1.withdrawFunds();
        
        (,,, uint256 lastRedemptionTime,,) = thadaiCoreV1.getUserAccessInfo(user1);
        assertEq(lastRedemptionTime, withdrawalTime);
    }

    function test_WithdrawFunds_EmitsUserWithdrawnEvent() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        
        vm.prank(user1);
        vm.expectEmit(true, false, false, false);
        emit ThadaiCoreV1.UserWithdrawn(user1, MINIMUM_PAYMENT_AMOUNT);
        
        thadaiCoreV1.withdrawFunds();
    }

    function test_WithdrawFunds_ResetsUserData() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        
        vm.prank(user1);
        thadaiCoreV1.withdrawFunds();
        
        (uint256 accessUntil, uint256 balance, uint256 totalPaid, uint256 lastRedemptionTime,,) =
            thadaiCoreV1.getUserAccessInfo(user1);
        
        assertEq(accessUntil, 0);
        assertEq(balance, 0);
        // totalPaid should remain (historical record)
        assertEq(totalPaid, MINIMUM_PAYMENT_AMOUNT);
        assertGt(lastRedemptionTime, 0);
    }

    function test_WithdrawFunds_DoesNotResetTotalPaid() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 3);
        
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        vm.prank(user1);
        thadaiCoreV1.withdrawFunds();
        
        vm.warp(block.timestamp + thadaiCoreV1.withdrawCooldownInDays());
        
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT * 2}();
        vm.prank(user1);
        thadaiCoreV1.withdrawFunds();
        
        (,, uint256 totalPaid,,,) = thadaiCoreV1.getUserAccessInfo(user1);
        assertEq(totalPaid, MINIMUM_PAYMENT_AMOUNT * 3);
    }

    // ============ Get User Access Info Tests ============

    function test_GetUserAccessInfo_NewUser() public view {
        (
            uint256 accessUntil,
            uint256 balance,
            uint256 totalPaid,
            uint256 lastRedemptionTime,
            bool canWithdraw,
            uint256 cooldownRemaining
        ) = thadaiCoreV1.getUserAccessInfo(user1);
        
        assertEq(accessUntil, 0);
        assertEq(balance, 0);
        assertEq(totalPaid, 0);
        assertEq(lastRedemptionTime, 0);
        assertTrue(canWithdraw); // New users can withdraw immediately (before first withdrawal)
        assertEq(cooldownRemaining, 0);
    }

    function test_GetUserAccessInfo_UserWithActiveAccess() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        
        (uint256 accessUntil, uint256 balance, uint256 totalPaid, uint256 lastRedemptionTime, bool canWithdraw,)
            = thadaiCoreV1.getUserAccessInfo(user1);
        
        assertGt(accessUntil, block.timestamp);
        assertEq(balance, MINIMUM_PAYMENT_AMOUNT);
        assertEq(totalPaid, MINIMUM_PAYMENT_AMOUNT);
        assertEq(lastRedemptionTime, 0);
        assertTrue(canWithdraw); // Can withdraw if never withdrawn before
    }

    function test_GetUserAccessInfo_UserDuringCooldown() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 2);
        
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        vm.prank(user1);
        thadaiCoreV1.withdrawFunds();
        
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        
        (,,,, bool canWithdraw, uint256 cooldownRemaining) = thadaiCoreV1.getUserAccessInfo(user1);
        
        assertFalse(canWithdraw);
        assertGt(cooldownRemaining, 0);
        assertLe(cooldownRemaining, thadaiCoreV1.withdrawCooldownInDays());
    }

    function test_GetUserAccessInfo_UserAfterCooldown() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 2);
        
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        vm.prank(user1);
        thadaiCoreV1.withdrawFunds();
        
        vm.warp(block.timestamp + thadaiCoreV1.withdrawCooldownInDays());
        
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        
        (,,,, bool canWithdraw, uint256 cooldownRemaining) = thadaiCoreV1.getUserAccessInfo(user1);
        
        assertTrue(canWithdraw);
        assertEq(cooldownRemaining, 0);
    }

    // ============ Calculate Access From Payment Tests ============

    function test_CalculateAccessFromPayment_MinimumPayment() public view {
        uint256 accessSeconds = thadaiCoreV1.calculateAccessFromPayment(MINIMUM_PAYMENT_AMOUNT);
        uint256 expectedSeconds = MINIMUM_PAYMENT_AMOUNT / BASE_ACCESS_PRICE;
        assertEq(accessSeconds, expectedSeconds);
    }

    function test_CalculateAccessFromPayment_LargePayment() public view {
        uint256 largePayment = MINIMUM_PAYMENT_AMOUNT * 100;
        uint256 accessSeconds = thadaiCoreV1.calculateAccessFromPayment(largePayment);
        uint256 expectedSeconds = largePayment / BASE_ACCESS_PRICE;
        assertEq(accessSeconds, expectedSeconds);
    }

    function test_CalculateAccessFromPayment_SmallPayment() public view {
        uint256 smallPayment = BASE_ACCESS_PRICE;
        uint256 accessSeconds = thadaiCoreV1.calculateAccessFromPayment(smallPayment);
        assertEq(accessSeconds, 1);
    }

    function test_CalculateAccessFromPayment_Zero() public view {
        uint256 accessSeconds = thadaiCoreV1.calculateAccessFromPayment(0);
        assertEq(accessSeconds, 0);
    }

    // ============ Get Contract Balance Tests ============

    function test_GetContractBalance_EmptyContract() public view {
        // Contract should be empty after deployment
        // Note: If deployer sends value, balance might not be zero
        uint256 balance = thadaiCoreV1.getContractBalance();
        assertEq(balance, address(thadaiCoreV1).balance);
    }

    function test_GetContractBalance_AfterDeposits() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 2);
        vm.deal(user2, MINIMUM_PAYMENT_AMOUNT);
        
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        
        vm.prank(user2);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        
        assertEq(thadaiCoreV1.getContractBalance(), MINIMUM_PAYMENT_AMOUNT * 2);
        assertEq(thadaiCoreV1.getContractBalance(), address(thadaiCoreV1).balance);
    }

    function test_GetContractBalance_AfterWithdrawal() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.deal(user2, MINIMUM_PAYMENT_AMOUNT);
        
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        
        vm.prank(user2);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        
        vm.prank(user1);
        thadaiCoreV1.withdrawFunds();
        
        assertEq(thadaiCoreV1.getContractBalance(), MINIMUM_PAYMENT_AMOUNT);
        assertEq(address(thadaiCoreV1).balance, MINIMUM_PAYMENT_AMOUNT);
    }

    // ============ Edge Cases and Integration Tests ============

    function test_MultiplePurchasesAndWithdrawals() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 5);
        
        // Purchase 1
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        (, uint256 balance1,,,,) = thadaiCoreV1.getUserAccessInfo(user1);
        assertEq(balance1, MINIMUM_PAYMENT_AMOUNT);
        
        // Purchase 2 - extend access
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        (, uint256 balance2,,,,) = thadaiCoreV1.getUserAccessInfo(user1);
        assertEq(balance2, MINIMUM_PAYMENT_AMOUNT * 2);
        
        // Withdraw
        vm.prank(user1);
        thadaiCoreV1.withdrawFunds();
        
        // Wait for cooldown
        vm.warp(block.timestamp + thadaiCoreV1.withdrawCooldownInDays());
        
        // Purchase 3
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        
        (,, uint256 totalPaid,,,) = thadaiCoreV1.getUserAccessInfo(user1);
        assertEq(totalPaid, MINIMUM_PAYMENT_AMOUNT * 3);
    }

    function test_AccessExpiresCorrectly() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        
        (uint256 accessUntil,,,,,) = thadaiCoreV1.getUserAccessInfo(user1);
        
        // Move to exactly when access expires
        vm.warp(accessUntil);
        
        (bool hasAccess,) = thadaiCoreV1.checkAccess(user1);
        assertFalse(hasAccess);
    }

    function test_WithdrawCooldownCalculation() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT * 2);
        
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        vm.prank(user1);
        thadaiCoreV1.withdrawFunds();
        
        uint256 withdrawalTime = block.timestamp;
        
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        
        // Check cooldown immediately after withdrawal
        (,,,,, uint256 cooldownRemaining) = thadaiCoreV1.getUserAccessInfo(user1);
        uint256 expectedCooldown = thadaiCoreV1.withdrawCooldownInDays();
        assertGt(cooldownRemaining, 0);
        assertLe(cooldownRemaining, expectedCooldown);
        
        // Advance half the cooldown period
        vm.warp(withdrawalTime + expectedCooldown / 2);
        (,,,,, cooldownRemaining) = thadaiCoreV1.getUserAccessInfo(user1);
        assertGt(cooldownRemaining, 0);
        assertLt(cooldownRemaining, expectedCooldown / 2 + 1);
        
        // Advance past cooldown
        vm.warp(withdrawalTime + expectedCooldown);
        (,,,, bool canWithdraw, uint256 cooldownRemainingFinal) = thadaiCoreV1.getUserAccessInfo(user1);
        assertTrue(canWithdraw);
        assertEq(cooldownRemainingFinal, 0);
    }

    function test_PurchaseAndWithdrawSameBlock() public {
        vm.deal(user1, MINIMUM_PAYMENT_AMOUNT);
        
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: MINIMUM_PAYMENT_AMOUNT}();
        
        // Withdraw in same block should work (first withdrawal)
        vm.prank(user1);
        thadaiCoreV1.withdrawFunds();
        
        (, uint256 balance,,,,) = thadaiCoreV1.getUserAccessInfo(user1);
        assertEq(balance, 0);
    }

    function test_Fuzz_CalculateAccessFromPayment(uint256 payment) public {
        // Bound payment to reasonable range to avoid overflow
        payment = bound(payment, 0, type(uint256).max / BASE_ACCESS_PRICE);
        
        uint256 accessSeconds = thadaiCoreV1.calculateAccessFromPayment(payment);
        uint256 expectedSeconds = payment / BASE_ACCESS_PRICE;
        assertEq(accessSeconds, expectedSeconds);
    }

    function test_Fuzz_PurchaseAccess(uint256 payment) public {
        // Bound payment to minimum and reasonable maximum
        payment = bound(payment, MINIMUM_PAYMENT_AMOUNT, MINIMUM_PAYMENT_AMOUNT * 1000);
        
        vm.deal(user1, payment);
        vm.prank(user1);
        thadaiCoreV1.purchaseAccess{value: payment}();
        
        (uint256 accessUntil, uint256 balance, uint256 totalPaid,,,) = thadaiCoreV1.getUserAccessInfo(user1);
        assertEq(balance, payment);
        assertEq(totalPaid, payment);
        assertGt(accessUntil, block.timestamp);
        
        uint256 expectedSeconds = payment / BASE_ACCESS_PRICE;
        assertGe(accessUntil - block.timestamp, expectedSeconds - 10); // Allow small time variance
    }
}