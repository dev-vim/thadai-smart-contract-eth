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
| **Constructor misconfiguration** | Constructor validates that `baseAccessPriceUSD`, `minimumPaymentUSD`, and `priceFeed` address are non-zero, preventing division-by-zero and invalid oracle configuration. |
| **Withdrawal gaming** | A cooldown period between withdrawals prevents rapid deposit-withdraw cycling. |
| **Oracle failure** | If the Chainlink price feed returns a non-positive price, the contract reverts with `InvalidOraclePrice`. This prevents purchases at a zero or negative ETH price. |

## What This Contract Does NOT Do

- It does **not** hold funds on behalf of a protocol or treasury. All ETH belongs to individual users.
- It does **not** have upgrade or migration logic. If a new version is needed, a new contract is deployed independently.
- It interacts with a single external contract: the **Chainlink AggregatorV3Interface** price feed (read-only). There is no SSRF or flash loan attack surface. The oracle address is immutable and set at deploy time.

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
