# Security

## Design Philosophy

ThadaiCore is an **intentionally ownerless and immutable** smart contract. There is no admin, no multisig, no upgrade path. All configuration is fixed at deploy time. This eliminates an entire class of centralization and governance risks.

## Trust Model

- **No privileged roles.** No address has special permissions after deployment. There is no `owner`, no `admin`, no `pause` key.
- **Immutable configuration.** Base access price, minimum payment, cooldown period, inflation window, and inflation percent are all set via `immutable` constructor parameters and cannot change.
- **Users control their own funds.** Each user's deposited ETH is tracked individually. Only the depositor can withdraw their own balance — the contract has no mechanism for any party to move another user's funds.
- **Full refundability by design.** Users can withdraw their entire deposited balance (subject to cooldown). This is intentional — the contract serves as a commitment device for time management, not a revenue-extracting protocol.

## Known Risks and Mitigations

| Risk | Mitigation |
|------|-----------|
| **Reentrancy** | `withdrawFunds()` uses OpenZeppelin's `ReentrancyGuard` (`nonReentrant` modifier). State is also updated before the external call (checks-effects-interactions pattern). Both defenses are tested with a malicious attacker contract. |
| **Integer overflow** | Solidity ^0.8.19 has built-in overflow checks. `totalAccessSecondsPurchased` uses `uint64`, which can hold ~584 billion years of seconds. |
| **Direct ETH transfers** | The contract has no `receive()` or `fallback()` function. Raw ETH transfers revert. Users must go through `purchaseAccess()`. |
| **Constructor misconfiguration** | Constructor validates that `baseAccessPrice` and `minimumPaymentAmount` are non-zero, preventing division-by-zero in `calculateAccessFromPayment()`. |
| **Withdrawal gaming** | A cooldown period between withdrawals prevents rapid deposit-withdraw cycling. |
| **Price staleness** | Current pricing is hardcoded at deploy time. A Chainlink price feed integration is planned for a future version to dynamically reflect ETH/USD rates. |

## What This Contract Does NOT Do

- It does **not** hold funds on behalf of a protocol or treasury. All ETH belongs to individual users.
- It does **not** have upgrade or migration logic. If a new version is needed, a new contract is deployed independently.
- It does **not** interact with external contracts or oracles (current version). There is no SSRF, oracle manipulation, or flash loan attack surface.

## Testing

The test suite includes:
- Unit tests for all public and view functions
- Constructor validation tests (zero-value rejection)
- Reentrancy attack simulation with a malicious contract
- Direct ETH transfer rejection tests
- Inflation edge case and boundary tests
- Fuzz tests for payment calculations and purchase flows
- Withdrawal cooldown timing verification

Run the full suite: `forge test`
Gas snapshots: `forge snapshot`

## Reporting Vulnerabilities

If you discover a security issue, please email developer.thevimal98@gmail.com.
