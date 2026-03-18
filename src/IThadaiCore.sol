// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/// @title IThadaiCore
/// @notice Interface for the ThadaiCore access control contract
/// @dev Enables lightweight integration by external contracts (e.g. deposit routers, DeFi adapters)
///      without importing the full implementation or its dependencies.
interface IThadaiCore {
    // Errors
    error PaymentBelowMinimumAmount(uint256 minimumAmount);
    error NoBalanceToWithdraw();
    error WithdrawalCooldownActive(uint64 cooldownRemaining);
    error WithdrawalTransferFailed(address user, uint256 amount);

    // Events
    event AccessPurchased(address indexed user, uint256 amount, uint256 accessUntilTime);
    event UserWithdrawn(address indexed user, uint256 amount);

    /// @notice Purchase access time by sending ETH
    function purchaseAccess() external payable;

    /// @notice Check if a user currently has active access
    /// @param _user Address of the user to check
    /// @return hasAccess True if user has active access
    /// @return remainingSeconds Seconds remaining in access period
    function checkAccess(address _user) external view returns (bool hasAccess, uint256 remainingSeconds);

    /// @notice Withdraw user deposited funds if not in cooldown period
    function withdrawFunds() external;

    /// @notice Get comprehensive access information for a user
    /// @param _user Address of the user to query
    function getUserAccessInfo(address _user)
        external
        view
        returns (
            uint256 balance,
            uint256 accessUntilTime,
            uint256 lastPurchaseTime,
            uint256 lastRedemptionTime,
            uint64 totalAccessSecondsPurchased,
            uint256 totalPaid,
            bool canWithdraw,
            uint64 cooldownRemaining,
            uint256 applicableInflationPercent
        );

    /// @notice Get current pricing and cooldown configuration
    function getAccessPricingInfo()
        external
        view
        returns (
            uint256 _baseAccessPrice,
            uint256 _minimumPaymentAmount,
            uint256 _withdrawCooldownInDays,
            uint256 _inflationWindowInHours,
            uint256 _inflationPercent
        );

    /// @notice Calculate how many seconds of access a payment would provide
    /// @param _payment Amount in wei
    /// @param _applicableInflationPercent Inflation percent to apply
    /// @return accessSeconds Seconds of access the payment buys
    function calculateAccessFromPayment(uint256 _payment, uint256 _applicableInflationPercent)
        external
        view
        returns (uint256 accessSeconds);

    /// @notice Get the current ETH balance held by the contract
    function getContractBalance() external view returns (uint256);
}
