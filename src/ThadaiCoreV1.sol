// SPDX-License-Identifier: MIT
pragma solidity ^0.8.19;

/**
 * @title ThadaiCoreV1
 * @notice Access control contract with a payment based approach and withdrawal cooldowns
 * @dev Users purchase access time with ETH and can withdraw their funds after a cooldown period.
 *      Implements time-based access control with configurable pricing and withdrawal restrictions.
 * @author developer.thevimal98@gmail.com
 */
contract ThadaiCoreV1 {
    // Errors
    error PaymentBelowMinimumAmount(uint256 minimumAmount);
    error NoBalanceToWithdraw();
    error WithdrawalCooldownActive(uint256 cooldownRemaining);

    // Struct to store user access information
    struct UserAccess {
        uint256 balance; // Total balance deposited by user
        uint256 accessUntil; // Timestamp until which user has access
        uint256 lastPurchaseTime; // Last time user purchased access
        uint256 lastRedemptionTime; // Last time user redeemed/withdrew funds
        uint256 totalAccessSecondsPurchased; // Total access time purchased by user
        uint256 totalPaid; // Total amount paid by user
    }

    // Contract configuration
    /// @notice Owner of the contract with administrative privileges
    address public owner;

    /// @notice Price for 1 second of access in wei
    uint256 public baseAccessPrice;

    /// @notice Minimum payment required to purchase access
    uint256 public minimumPaymentAmount;

    /// @notice Time period users must wait between withdrawals
    uint256 public withdrawCooldownInDays;

    /// @notice User inflation parameters for dynamic pricing
    uint256 public inflationWindowInHours;
    uint256 public inflationPercent;

    /// @notice Mapping from user address to their access information
    mapping(address => UserAccess) public userAccess;

    // Events for tracking important actions
    /// @notice Emitted when a user purchases access time
    /// @param user Address of the user who purchased access
    /// @param amount Amount of ETH paid for access
    /// @param accessUntil Timestamp when access expires
    event AccessPurchased(address indexed user, uint256 amount, uint256 accessUntil);

    /// @notice Emitted when a user withdraws their funds
    /// @param user Address of the user who withdrew
    /// @param amount Amount of ETH withdrawn
    event UserWithdrawn(address indexed user, uint256 amount);

    /// @notice Emitted when contract configuration is updated
    /// @param newBasePrice New price per second of access
    /// @param newRedemptionCooldown New withdrawal cooldown period
    /// TODO: Remove this (and perform subsequent downstream ABI updations)
    event ConfigurationUpdated(uint256 newBasePrice, uint256 newRedemptionCooldown);

    /**
     * @notice Initialize the contract with configuration parameters
     * @dev Constructor sets initial configuration and assigns contract owner
     * @param _baseAccessPrice Price for 1 second of access in wei
     * @param _minimumPaymentAmount Minimum payment required to purchase access
     * @param _withdrawCooldownInDays Days users must wait between withdrawals
     * @param _inflationWindowInHours Hours within which inflation applies
     * @param _inflationPercent Percent increase in price during inflation window
     */
    constructor(
        uint256 _baseAccessPrice,
        uint256 _minimumPaymentAmount,
        uint256 _withdrawCooldownInDays,
        uint256 _inflationWindowInHours,
        uint256 _inflationPercent
    ) {
        owner = msg.sender;
        baseAccessPrice = _baseAccessPrice;
        minimumPaymentAmount = _minimumPaymentAmount;
        withdrawCooldownInDays = _withdrawCooldownInDays * 1 days;
        inflationWindowInHours = _inflationWindowInHours * 1 hours;
        inflationPercent = _inflationPercent;
    }

    /**
     * @notice Purchase access time by sending ETH to the contract
     * @dev Main function to purchase access time. Users can deposit anytime and access time
     *      is calculated based on the payment amount. Existing access is extended if still active.
     */
    function purchaseAccess() external payable {
        if (msg.value < minimumPaymentAmount) {
            revert PaymentBelowMinimumAmount(minimumPaymentAmount);
        }
        UserAccess storage access = userAccess[msg.sender];
        uint256 unlockedAccessSeconds =
            calculateAccessFromPayment(msg.value, _getApplicableInflationPercent(access.lastPurchaseTime));
        uint256 currentTime = block.timestamp;
        uint256 newAccessUntil;
        if (access.accessUntil > currentTime) {
            newAccessUntil = access.accessUntil + unlockedAccessSeconds;
        } else {
            newAccessUntil = currentTime + unlockedAccessSeconds;
        }
        access.balance += msg.value;
        access.accessUntil = newAccessUntil;
        access.totalPaid += msg.value;
        access.lastPurchaseTime = currentTime;
        access.totalAccessSecondsPurchased += unlockedAccessSeconds;
        emit AccessPurchased(msg.sender, msg.value, newAccessUntil);
    }

    /**
     * @notice Check if a user currently has active access
     * @dev Checks if user's access period has not expired and returns remaining time
     * @param _user Address of the user to check
     * @return hasAccess Boolean indicating if user has active access
     * @return remainingSeconds Seconds remaining in access period (0 if no access)
     */
    function checkAccess(address _user) public view returns (bool hasAccess, uint256 remainingSeconds) {
        UserAccess storage access = userAccess[_user];
        uint256 currentTime = block.timestamp;
        if (access.accessUntil > currentTime) {
            hasAccess = true;
            remainingSeconds = access.accessUntil - currentTime;
        } else {
            hasAccess = false;
            remainingSeconds = 0;
        }
    }

    /**
     * @notice Withdraw user deposited funds if not in cooldown period
     * @dev Allows user (msg.sender) to withdraw their entire balance if eligible. Enforces redemption cooldown
     *      to prevent frequent withdrawals. Resets user data after successful withdrawal.
     */
    function withdrawFunds() external {
        UserAccess storage access = userAccess[msg.sender];
        if (access.balance == 0) {
            revert NoBalanceToWithdraw();
        }

        // User can only withdraw after redemption cooldown
        if (!_canUserWithdraw(access)) {
            revert WithdrawalCooldownActive(block.timestamp - access.lastRedemptionTime);
        }

        uint256 withdrawAmount = access.balance;

        // Reset user data and update redemption time
        access.balance = 0;
        access.accessUntil = 0;
        access.lastRedemptionTime = block.timestamp;

        // Transfer funds
        payable(msg.sender).transfer(withdrawAmount);

        emit UserWithdrawn(msg.sender, withdrawAmount);
    }

    /**
     * @notice Get comprehensive access information for a user
     * @dev Returns all user access data including balance, access status, and withdrawal eligibility
     * @param _user Address of the user to query
     * @return balance User's current balance in contract
     * @return accessUntil Timestamp when access expires
     * @return lastPurchaseTime Last time user purchased access
     * @return lastRedemptionTime Last time user withdrew funds (0 if never withdrawn)
     * @return totalAccessSecondsPurchased Total access time user has purchased historically
     * @return totalPaid Total amount user has paid historically
     * @return canWithdraw True if user can withdraw now (cooldown passed)
     * @return cooldownRemaining Time remaining until next withdrawal (0 if can withdraw)
     * @return applicableInflationPercent Inflation percent applicable to user based on last purchase time
     */
    function getUserAccessInfo(address _user)
        public
        view
        returns (
            uint256 balance,
            uint256 accessUntil,
            uint256 lastPurchaseTime,
            uint256 lastRedemptionTime,
            uint256 totalAccessSecondsPurchased,
            uint256 totalPaid,
            bool canWithdraw,
            uint256 cooldownRemaining,
            uint256 applicableInflationPercent
        )
    {
        UserAccess storage access = userAccess[_user];
        canWithdraw = _canUserWithdraw(access);
        cooldownRemaining = _getWithdrawalCooldownRemaining(access);
        applicableInflationPercent = _getApplicableInflationPercent(access.lastPurchaseTime);
        return (
            access.balance,
            access.accessUntil,
            access.lastPurchaseTime,
            access.lastRedemptionTime,
            access.totalAccessSecondsPurchased,
            access.totalPaid,
            canWithdraw,
            cooldownRemaining,
            applicableInflationPercent
        );
    }

    /**
     * @notice Get current pricing and cooldown configuration
     * @dev Returns the base access price, minimum payment, withdrawal cooldown, inflation window, and inflation percent
     * @return _baseAccessPrice Price for 1 second of access in wei
     * @return _minimumPaymentAmount Minimum payment required to purchase access
     * @return _withdrawCooldownInDays Days users must wait between withdrawals
     * @return _inflationWindowInHours Hours within which inflation applies
     * @return _inflationPercent Percent increase in price during inflation window
     */
    function getAccessPricingInfo()
        public
        view
        returns (
            uint256 _baseAccessPrice,
            uint256 _minimumPaymentAmount,
            uint256 _withdrawCooldownInDays,
            uint256 _inflationWindowInHours,
            uint256 _inflationPercent
        )
    {
        return (
            baseAccessPrice,
            minimumPaymentAmount,
            withdrawCooldownInDays / 1 days,
            inflationWindowInHours / 1 hours,
            inflationPercent
        );
    }

    /**
     * @notice Check if user can withdraw based on redemption cooldown
     * @dev Internal function to check withdrawal eligibility. First-time users can withdraw immediately,
     *      returning users must wait for cooldown period to pass.
     * @param userAccessData Storage reference to the user's access data
     * @return canWithdraw True if user can withdraw now
     */
    function _canUserWithdraw(UserAccess storage userAccessData) internal view returns (bool canWithdraw) {
        // If user has no balance, they cannot withdraw
        if (userAccessData.balance == 0) {
            return false;
        }
        // If user has never withdrawn before, they can withdraw immediately
        if (userAccessData.lastRedemptionTime == 0) {
            return true;
        }
        // Check if enough time has passed since last withdrawal
        uint256 timeSinceLastWithdrawal = block.timestamp - userAccessData.lastRedemptionTime;
        return timeSinceLastWithdrawal >= withdrawCooldownInDays;
    }

    /**
     * @notice Get time remaining until user can withdraw again
     * @dev Internal function to calculate remaining cooldown time. Returns 0 if user can withdraw now
     *      or has never withdrawn before.
     * @param _userAccessData Storage reference to the user's access data
     * @return cooldownRemaining Time remaining in seconds (0 if can withdraw now)
     */
    function _getWithdrawalCooldownRemaining(UserAccess storage _userAccessData)
        internal
        view
        returns (uint256 cooldownRemaining)
    {
        if (_userAccessData.lastRedemptionTime == 0) {
            return 0;
        }

        uint256 timeSinceLastWithdrawal = block.timestamp - _userAccessData.lastRedemptionTime;

        if (timeSinceLastWithdrawal >= withdrawCooldownInDays) {
            return 0;
        } else {
            return withdrawCooldownInDays - timeSinceLastWithdrawal;
        }
    }

    /**
     * @notice Internal function to determine applicable inflation percent based on last purchase time
     * @param lastPurchaseTime Last time user purchased access
     * @return percent Inflation percent to apply
     */
    function _getApplicableInflationPercent(uint256 lastPurchaseTime) internal view returns (uint256 percent) {
        if (lastPurchaseTime != 0 && block.timestamp - lastPurchaseTime < inflationWindowInHours) {
            return inflationPercent;
        }
        return 0;
    }

    /**
     * @notice Calculate how many seconds of access a payment amount would provide
     * @dev Public view function to calculate access time from payment amount using base price
     * @param _payment Amount in wei to calculate access for
     * @param _applicableInflationPercent Inflation percent to apply to base price
     * @return accessSeconds Number of seconds of access the payment would provide
     */
    function calculateAccessFromPayment(uint256 _payment, uint256 _applicableInflationPercent)
        public
        view
        returns (uint256 accessSeconds)
    {
        uint256 adjustedPrice = baseAccessPrice + ((baseAccessPrice * _applicableInflationPercent) / 100);
        accessSeconds = _payment / adjustedPrice;
    }

    /**
     * @notice Get the current ETH balance held by the contract
     * @dev Returns the total ETH balance stored in the contract from all user deposits
     * @return Current contract balance in wei
     */
    function getContractBalance() public view returns (uint256) {
        return address(this).balance;
    }
}
