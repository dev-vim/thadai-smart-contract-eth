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
        uint256 totalPaid; // Total amount paid by user (for analytics)
        uint256 lastRedemptionTime; // Last time user redeemed/withdrew funds
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
    event ConfigurationUpdated(uint256 newBasePrice, uint256 newRedemptionCooldown);

    /**
     * @notice Initialize the contract with configuration parameters
     * @dev Constructor sets initial configuration and assigns contract owner
     * @param _baseAccessPrice Price for 1 second of access in wei
     * @param _minimumPaymentAmount Minimum payment required to purchase access
     * @param _withdrawCooldownInDays Days users must wait between withdrawals
     */
    constructor(uint256 _baseAccessPrice, uint256 _minimumPaymentAmount, uint256 _withdrawCooldownInDays) {
        owner = msg.sender;
        baseAccessPrice = _baseAccessPrice;
        minimumPaymentAmount = _minimumPaymentAmount;
        withdrawCooldownInDays = _withdrawCooldownInDays * 1 days;
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

        // Calculate how much access the payment can buy
        uint256 unlockedAccessSeconds = calculateAccessFromPayment(msg.value);

        // Calculate new access expiration
        uint256 currentTime = block.timestamp;
        uint256 newAccessUntil;

        if (access.accessUntil > currentTime) {
            // Extend existing access with all purchased seconds
            newAccessUntil = access.accessUntil + unlockedAccessSeconds;
        } else {
            // Start new access period
            newAccessUntil = currentTime + unlockedAccessSeconds;
        }

        // Update user access information
        access.balance += msg.value;
        access.accessUntil = newAccessUntil;
        access.totalPaid += msg.value;

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
        if (!_canUserWithdraw(msg.sender)) {
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
     * @return accessUntil Timestamp when access expires
     * @return balance User's current balance in contract
     * @return totalPaid Total amount user has paid historically
     * @return lastRedemptionTime Last time user withdrew funds (0 if never withdrawn)
     * @return canWithdraw True if user can withdraw now (cooldown passed)
     * @return cooldownRemaining Time remaining until next withdrawal (0 if can withdraw)
     */
    function getUserAccessInfo(address _user)
        public
        view
        returns (
            uint256 accessUntil,
            uint256 balance,
            uint256 totalPaid,
            uint256 lastRedemptionTime,
            bool canWithdraw,
            uint256 cooldownRemaining
        )
    {
        UserAccess storage access = userAccess[_user];

        canWithdraw = _canUserWithdraw(_user);
        cooldownRemaining = _getWithdrawalCooldownRemaining(_user);

        return (
            access.accessUntil,
            access.balance,
            access.totalPaid,
            access.lastRedemptionTime,
            canWithdraw,
            cooldownRemaining
        );
    }

    /**
     * @notice Check if user can withdraw based on redemption cooldown
     * @dev Internal function to check withdrawal eligibility. First-time users can withdraw immediately,
     *      returning users must wait for cooldown period to pass.
     * @param _user Address to check
     * @return canWithdraw True if user can withdraw now
     */
    function _canUserWithdraw(address _user) internal view returns (bool canWithdraw) {
        UserAccess storage access = userAccess[_user];

        // If user has never withdrawn before, they can withdraw immediately
        if (access.lastRedemptionTime == 0) {
            return true;
        }

        // Check if enough time has passed since last withdrawal
        uint256 timeSinceLastWithdrawal = block.timestamp - access.lastRedemptionTime;
        return timeSinceLastWithdrawal >= withdrawCooldownInDays;
    }

    /**
     * @notice Get time remaining until user can withdraw again
     * @dev Internal function to calculate remaining cooldown time. Returns 0 if user can withdraw now
     *      or has never withdrawn before.
     * @param _user Address to check
     * @return cooldownRemaining Time remaining in seconds (0 if can withdraw now)
     */
    function _getWithdrawalCooldownRemaining(address _user) internal view returns (uint256 cooldownRemaining) {
        UserAccess storage access = userAccess[_user];

        if (access.lastRedemptionTime == 0) {
            return 0;
        }

        uint256 timeSinceLastWithdrawal = block.timestamp - access.lastRedemptionTime;

        if (timeSinceLastWithdrawal >= withdrawCooldownInDays) {
            return 0;
        } else {
            return withdrawCooldownInDays - timeSinceLastWithdrawal;
        }
    }

    /**
     * @notice Calculate how many seconds of access a payment amount would provide
     * @dev Public view function to calculate access time from payment amount using base price
     * @param _payment Amount in wei to calculate access for
     * @return accessSeconds Number of seconds of access the payment would provide
     */
    function calculateAccessFromPayment(uint256 _payment) public view returns (uint256 accessSeconds) {
        return _payment / baseAccessPrice;
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
