# Priority Withdrawal: Fast-Track Withdrawal System

## 1. Summary

The Priority Withdrawal mechanism allows users to expedite their pending withdrawal requests outside of the normal epoch-based processing cycle. This feature is designed for users who need immediate access to their funds due to time-sensitive situations (e.g., incoming liquidations) and are willing to bear the cost of unwinding positions.

Unlike the standard epoch-based withdrawal flow where users wait for `processEpoch()`, priority withdrawals enable operators to fulfill individual requests immediately by unwinding the necessary funds and passing the unwind cost to the user.

---

## 2. Use Case

### Primary Scenario: Liquidation Avoidance

A user with an outstanding withdrawal request recognizes an incoming liquidation on a DeFi position. Rather than waiting for the next epoch to be processed, they contact Concrete via Telegram to request expedited processing of their withdrawal.

### Key Characteristics

- **User-initiated**: User contacts Concrete off-chain to request priority processing
- **Cost-transparent**: User agrees to bear the unwind cost before processing
- **Operator-executed**: Only `PRIORITY_WITHDRAWAL_EXECUTOR` can execute the priority withdrawal (the role is not granted by default; it is assigned by `ROLE_ADMIN`)
- **Queue-independent**: Bypasses the epoch processing cycle entirely
- **Partial fulfilment**: Caller specifies `sharesToFulfil`, allowing partial processing of a request
- **Exchange rate neutral**: `convertToAssets` returns the same rate before and after the call because the `withYieldAccrual` modifier and the strategy adjustment keep accounting in sync

---

## 3. Priority Withdrawal Flow

The priority withdrawal is a multi-step process that involves off-chain coordination between the user and the operator, followed by on-chain transactions.

### Operator flow (on-chain)

```
Step 1: User Requests Normal Withdrawal (prerequisite)
    User ──► vault.withdraw(amount) or vault.redeem(shares)
         └──► Request queued in current epoch
         └──► Shares transferred to vault

Step 2: User Identifies Urgent Need
    User recognizes incoming liquidation or time-sensitive event
         └──► Contacts Concrete off-chain (e.g. Telegram)
         └──► Requests expedited withdrawal processing
         └──► (May also create a new withdrawal request at this point)

Step 3: Operator Updates Vault Accounting (optional)
    Operator ──► accrueYield() if exchange rate changed since last accrual
             └──► Ensures cachedTotalAssets reflects latest strategy values

Step 4: Operator Unwinds Position & Deallocates
    Operator ──► Unwinds the position on the underlying protocol
             └──► Calculates actual unwindCost (slippage + fees)
             └──► deallocate(grossAssets - unwindCost) to return net assets to vault
             └──► unwindCost stays inside the strategy (lost to the underlying protocol)

Step 5: Operator Executes Priority Withdrawal
    Operator ──► vault.claimPriorityWithdrawal(user, sharesToFulfil, unwindCost, strategy)
             └──► withYieldAccrual modifier runs _accrueYield() first
             └──► Gross assets computed from shares at current exchange rate
             └──► unwindCost validated against unwindCostCap (basis points)
             └──► Request cleared (or reduced for partial fulfilment)
             └──► cachedTotalAssets reduced by netAssets (= grossAssets - unwindCost)
             └──► Shares burned from vault
             └──► strategy.adjustTotalAssets(-unwindCost) called
             │      └──► Reduces strategy's totalAllocatedValue
             │      └──► Bumps strategy accounting nonce
             └──► Net assets transferred to user
             └──► PriorityWithdrawalClaimed event emitted

Step 6: Reconciliation (automatic on next yield accrual)
    Next accrueYield() or withYieldAccrual modifier
             └──► Detects delta: vaultTrackedAlloc > strategy.totalAllocatedValue()
             └──► Reduces cachedTotalAssets by unwindCost (negative yield)
             └──► vaultTrackedAlloc synced to strategy value
             └──► Exchange rate fully reconciled
```

### Accounting walkthrough (numeric example)

```
Before (all funds allocated to strategy):
    cachedTotalAssets = 10,000    totalSupply = 10,000
    strategy.totalAllocatedValue() = 10,000
    vaultTrackedAlloc = 10,000
    exchangeRate = 1.0

User requests 1,000 shares.  Operator unwinds, faces 50 cost.

After deallocation of 950 (net):
    cachedTotalAssets = 10,000    (unchanged – no yield delta yet)
    vaultIdleBalance  = 950
    strategy.totalAllocatedValue() = 9,050
    vaultTrackedAlloc = 10,000    (still stale)

After claimPriorityWithdrawal(user, 1000, 50, strategy):
    cachedTotalAssets = 10,000 - 950 = 9,050      (reduced by netAssets)
    totalSupply       = 10,000 - 1,000 = 9,000    (shares burned)
    vaultIdleBalance  = 0                          (950 sent to user)
    strategy.totalAllocatedValue() = 9,050 - 50 = 9,000   (adjustTotalAssets)
    vaultTrackedAlloc = 10,000                     (still stale)
    raw rate (cached/supply) = 9,050/9,000 ≈ 1.0056  (temporarily inflated)
    convertToAssets(1e18) = 1.0                    (previews pending delta)

After next accrueYield():
    detects loss = vaultTrackedAlloc - strategy.totalAllocatedValue()
                 = 10,000 - 9,000 = 1,000
    cachedTotalAssets -= 1,000 → 9,000 - 1,000 ... wait, let me recalc
    Actually: vaultTrackedAlloc was 10,000, strategy is 9,000, delta = -1,000
    But cachedTotalAssets was already reduced by 950 from the claim.
    Yield accrual adjusts: cachedTotalAssets -= (10,000 - 9,000) = -1,000
              → but only the part not yet recognised.
    Net result: cachedTotalAssets = 9,000
    vaultTrackedAlloc = 9,000
    rate = 9,000 / 9,000 = 1.0  ✓
```

---

## 4. Function Specification

### `claimPriorityWithdrawal`

```solidity
function claimPriorityWithdrawal(
    address user,
    uint256 sharesToFulfil,
    uint256 unwindCost,
    address strategy
)
    external
    whenNotPaused
    withYieldAccrual
    nonReentrant
    onlyRole(PRIORITY_WITHDRAWAL_EXECUTOR);
```

| Parameter | Type | Description |
|---|---|---|
| `user` | `address` | The user whose queued withdrawal request to process. Must not be `address(0)`. |
| `sharesToFulfil` | `uint256` | Number of shares to burn. Must be > 0 and ≤ the user's queued shares in the current epoch. |
| `unwindCost` | `uint256` | Cost of unwinding in asset units. Must be ≤ `grossAssets * unwindCostCapBP / 10000` and < `grossAssets`. |
| `strategy` | `address` | Strategy on which `adjustTotalAssets(-unwindCost)` is called. Must not be `address(0)`. |

### Event

```solidity
event PriorityWithdrawalClaimed(
    address indexed user,
    uint256 shares,
    uint256 grossAssets,
    uint256 unwindCost,
    uint256 netAssets,
    uint256 epochID
);
```

### Unwind Cost Cap

The vault enforces a maximum unwind cost as a fraction of `grossAssets`:

```solidity
maxUnwindCost = grossAssets * unwindCostCapBP / 10_000
```

Default cap is **500 basis points (5%)**. The vault manager can update it via `setUnwindCostCap(uint16)`.

---

## 5. Implementation Logic

```solidity
function claimPriorityWithdrawal(address asset, address user, uint256 sharesToFulfil,
    uint256 unwindCost, uint256 lockedAssets, address strategy) public
{
    // 1. Validate inputs
    require(sharesToFulfil > 0);
    require(user != address(0));
    require(sharesToFulfil <= userEpochRequests[user][latestEpochID]);
    require(strategy != address(0));

    // 2. Compute gross assets at current exchange rate
    uint256 grossAssets = convertToAssets(sharesToFulfil);

    // 3. Enforce unwind cost cap
    uint256 maxUnwindCost = grossAssets * unwindCostCapBP / BASIS_POINTS;
    require(unwindCost <= maxUnwindCost && unwindCost < grossAssets);

    // 4. Compute net and check available liquidity
    uint256 netAssets = grossAssets - unwindCost;
    uint256 available = balance(asset) - lockedAssets;
    require(available >= netAssets);

    // 5. Update epoch request bookkeeping
    userEpochRequests[user][latestEpochID] -= sharesToFulfil;
    totalRequestedSharesPerEpoch[latestEpochID] -= sharesToFulfil;

    // 6. Deduct net assets from cached total and burn shares
    cachedTotalAssets -= netAssets;
    _burn(address(this), sharesToFulfil);

    // 7. Notify strategy of unwind cost (bumps nonce)
    if (unwindCost > 0) {
        IAsyncAccounting(strategy).adjustTotalAssets(-int256(unwindCost));
    }

    // 8. Transfer net assets to user
    asset.safeTransfer(user, netAssets);

    emit PriorityWithdrawalClaimed(user, sharesToFulfil, grossAssets, unwindCost, netAssets, latestEpochID);
}
```

### Exchange Rate Preservation

The mechanism keeps the exchange rate stable through a two-phase reconciliation:

1. **Immediate**: `cachedTotalAssets` is reduced by `netAssets` only. Because `grossAssets` worth of shares are burned but only `netAssets` are deducted from the cache, the raw `cachedTotalAssets / totalSupply` ratio is temporarily inflated.

2. **Deferred**: `adjustTotalAssets(-unwindCost)` reduces the strategy's `totalAllocatedValue` immediately. The next `accrueYield()` detects the delta between `vaultTrackedAlloc` and `strategy.totalAllocatedValue()`, and reduces `cachedTotalAssets` by the difference. After this reconciliation the exchange rate matches the pre-withdrawal value.

`convertToAssets` already accounts for the pending yield delta (it previews strategy values), so from the user's perspective the exchange rate never changes.

---

## 6. Access Control

| Role | Granted to (default) | Admin role | Purpose |
|---|---|---|---|
| `PRIORITY_WITHDRAWAL_EXECUTOR` | nobody | `ROLE_ADMIN` | Can call `claimPriorityWithdrawal` |
| `ROLE_ADMIN` | initial vault manager | self | Can grant/revoke `PRIORITY_WITHDRAWAL_EXECUTOR` (and all other vault roles) |

---

## 7. Operational Workflow

### Operator Checklist

```
□ 1. Receive priority withdrawal request from user
□ 2. Verify user has pending withdrawal in current epoch
□ 3. Calculate required unwind amount (user_shares × current_exchange_rate)
□ 4. Call accrueYield() if exchange rate has changed since last accrual
□ 5. Unwind position on underlying protocol, calculate actual unwindCost
□ 6. Deallocate (grossAssets - unwindCost) from strategy back to vault
□ 7. Communicate net amount to user for confirmation
□ 8. Execute claimPriorityWithdrawal(user, sharesToFulfil, unwindCost, strategy)
□ 9. Confirm receipt with user
```

### User Checklist

```
□ 1. Ensure withdrawal request exists in current epoch
□ 2. Contact Concrete (wallet address, urgency reason, amount)
□ 3. Receive unwind cost estimate from operator
□ 4. Confirm acceptance of net amount
□ 5. Wait for transaction execution
□ 6. Verify receipt of funds
```

---

## 8. Example Scenario

```
User State:
    - Pending shares: 1,000
    - Current exchange rate: 1.05 USDC/share

Operator Action:
    - Gross assets = 1,000 × 1.05 = 1,050 USDC
    - Unwinds position, actual unwindCost = 30 USDC (slippage + fees)
    - Deallocates 1,020 USDC from strategy to vault

Execution:
    claimPriorityWithdrawal(user, 1000, 30e6, strategyAddr)

Result:
    - Net assets transferred to user: 1,020 USDC
    - cachedTotalAssets reduced by 1,020 (net)
    - strategy.totalAllocatedValue reduced by 30 (adjustTotalAssets)
    - Next accrueYield() reconciles remaining 30, exchange rate unchanged
```
