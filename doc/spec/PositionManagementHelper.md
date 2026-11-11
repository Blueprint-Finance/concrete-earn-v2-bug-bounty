# Position Management Helper — Specification

**Title:** Position Management Helper (PMH) — LTV-based leveraged position operator
**Authors:** Blueprint Finance
**Status:** Final
**Last updated:** 2026-11-04
**Package:** `@concrete-xyz/earn-v2-core@1.7.0`

**Related docs:**
- `CHANGELOG.md` — release notes
- `doc/spec/PeripheryFactory.md` — factory spec

**Glossary:**
- **LTV** — Loan-to-Value: `debt / (collateral × price)`, in WAD (1e18 = 100%)
- **Collateral token** — the asset supplied to the lender as security (e.g. wstETH)
- **Borrow token** — the asset borrowed from the lender and deployed into the yield vault (e.g. USDC)
- **aToken** — Aave V3's interest-bearing receipt for deposited collateral
- **Credit delegation** — Aave V3 mechanism allowing a third party to borrow on behalf of the delegator
- **WAD** — 1e18, used as the fixed-point denominator for LTV percentages and rates
- **RAY** — 1e27, used as the fixed-point denominator for prices
- **positionOwner** — the account (multisig, strategy contract, or EOA) that retains custody of all collateral, debt, and vault shares

---

## Architecture

### Co-ownership model

The PMH is an **approved operator**, not a custodian. It never holds a position outright. The `positionOwner` retains custody at all times:

- Collateral (aTokens) → in the `positionOwner` wallet
- Debt (variable debt tokens) → recorded against `positionOwner` at the lender
- Vault shares → held by `positionOwner`
- Idle tokens (collateral and borrow) → in the `positionOwner` wallet

The helper is approved to pull tokens from the `positionOwner`, interact with the lender and target vault on its behalf, and route results back — but MUST NOT hold any token balance between transactions (**zero-balance invariant**).

### Two-layer split

| Layer | Contract | Role |
|---|---|---|
| Abstract base | `PositionHelperBase` | Clone lifecycle, AccessControl, ILenderModule, IContractId, all lender-agnostic flows |
| Lender integration | `PositionHelperAaveV3` | Aave V3 immutables, concrete lender primitives |

`PositionHelperBase` inherits:
- `Clone` (wighawag/clones-with-immutable-args) — reads per-position immutable args from appended bytecode
- `AccessControlEnumerableUpgradeable` (OZ) — role management with enumeration
- `IPositionHelperBase` — full external interface
- `ILenderModule` — lender primitive interface (shared with BaseLoopingStrategy)
- `IContractId` — `ID()` identity interface

### Deployment model — ClonesWithImmutableArgs

PMH contracts are **not proxies**. Each position gets a dedicated non-upgradeable lightweight clone. A 62-byte immutable arg payload is baked in at clone time:

```
Offset  Size  Field
0       20    positionOwner
20      20    collateralToken
40      20    borrowToken
60      1     collateralDecimals
61      1     borrowDecimals
```

These fields are NOT stored in contract storage. They are read via `_getArgAddress(offset)` / `_getArgUint8(offset)` and exposed as `pure` view functions: `POSITION_OWNER()`, `COLLATERAL_TOKEN()`, `BORROW_TOKEN()`, `COLLATERAL_DECIMALS()`, `BORROW_DECIMALS()`.

**Clone lifecycle:**
1. Deploy the concrete implementation once (sets lender immutables, calls `_disableInitializers()`).
2. For each position: `ClonesWithImmutableArgs.clone(implementation, immutableArgs)`.
3. Call `initialize(...)` on the clone to set per-instance state and token approvals.

### Role-based guards

Two roles are set once at `initialize()`:

| Role | Purpose |
|---|---|
| `POSITION_ADMIN_ROLE` | Admin over the helper: can grant/revoke `POSITION_OPERATOR_ROLE`, call `rescueFunds` and change the LTV band and self-liquidation parameters |
| `POSITION_OPERATOR_ROLE` | Gate for all position operations (supply, borrow, deploy, retract, …) |

`POSITION_ADMIN_ROLE` is self-administered. `POSITION_OPERATOR_ROLE` is administered by `POSITION_ADMIN_ROLE`.

### Contract identity (IContractId)

`PositionHelperAaveV3` is ID-compliant. `ID()` is `pure` and returns `400110100`:

```
contractType = 4  (position helper)
flavour      = 1  (aave-v3)
version      = 1.1.1  (major=1, minor=1, patch=1)

ID = version + flavour×100000 + contractType×100000000
   = 10100 + 100000 + 400000000 = 400110100
```

### Self-liquidation capability

The PMH can unwind its own position without external intervention using flash-loan-assisted self-liquidation:
- `selfLiquidate(debtAmount, maxSlippageInWad)` — repays a specific debt amount
- `selfLiquidateToLtv(targetLtvInWad, maxSlippageInWad)` — reduces LTV to a target

Both paths delegate to a registered `IFlashModule` (flash loan) and `ISwapModule` (collateral-to-borrow swap). Math for computing the exact collateral to withdraw is in `PositionManagementHelperLib`.

### Pre-approved allowances (set at `initialize()`)

| From | To | Used for |
|---|---|---|
| `collateralToken` | Aave pool | `supply` |
| `collateralToken` | swapModule | self-liquidation swap |
| `borrowToken` | Aave pool | `repay` |
| `borrowToken` | yieldVault | `depositOnTarget` |
| `borrowToken` | flashModule | flash repayment |
| yieldVault shares | yieldVault | redemption requests |

No per-call approvals are needed after initialization.

---

## Position model

The full state of a position is captured by the 7-tuple **(a, b, c, d, s, q, r)**:

| Symbol | Description |
|--------|-------------|
| **a**  | Principal tokens (`COLLATERAL_TOKEN`) held in the positionOwner wallet (idle principal) |
| **b**  | Borrow tokens (`BORROW_TOKEN`) held in the positionOwner wallet (idle borrow proceeds) |
| **c**  | Position tokens (aTokens on Aave) held by positionOwner — the lender's obligation to return principal |
| **d**  | Debt outstanding at the lender (variable debt tokens), in borrow token units |
| **s**  | Vault shares of the target ERC4626 vault held by positionOwner |
| **q**  | Vault shares sitting in the redemption queue, awaiting fulfilment |
| **r**  | Outstanding principal withdrawal obligation toward the strategy (off-chain tracking only) |

At rest: `a` and `b` represent idle capital not yet deployed, `c`/`d` form the active leverage, `s`/`q` represent the deployed yield-earning position, and `r` represents any outstanding withdrawal obligation.

> **Token roles:**
> - **Principal token** = `COLLATERAL_TOKEN` (e.g. wstETH) — supplied to the lender and held as `a` (idle) or `c` (at lender).
> - **Position token** = aToken (Aave V3) — the lender's receipt for deposited principal; tracked as `c`.
> - **Borrow token** = `BORROW_TOKEN` (e.g. USDC) — borrowed from the lender and deployed into the target vault; idle in wallet as `b`.
> - **Debt token** = Aave variable debt token — the positionOwner's repayment obligation; tracked as `d`.

### Zero-balance invariant

The `PositionManagementHelper` contract MUST NOT hold any tokens at rest. Tokens may transiently flow through the contract during execution of an operation, but by the end of every transaction the contract's balance of every relevant token MUST be zero.

All token custody belongs to the `positionOwner`. The helper merely acts as an approved operator that pulls tokens in, performs lender/target interactions, and routes results back — never retaining a balance between transactions.

---

## Math helpers

All formulas use WAD (1e18 = 100%) for LTV percentages and RAY (1e27 = 1.0) for prices. Amounts are in native token units. The helpers live in `PositionManagementHelperLib` (`src/periphery/lib/PositionManagementHelperLib.sol`).

### `minLtv(d, c, x, p)` — post-supply LTV

After supplying `x` additional collateral into a position that already has `c` collateral and `d` debt at price `p`, the resulting LTV is:

```
minLtv = d / ((c + x) · p)
```

This is the *lowest possible* LTV for the given debt — any subsequent borrowing will push it higher. Used in `deploy` to decide whether additional borrowing is meaningful.

Returns `type(uint256).max` when collateral value is zero.

### `withdrawable(c, d, y, p, λ)` — max collateral withdrawable at LTV λ

Given that `y` borrow tokens will be repaid, the maximum collateral that can be withdrawn while keeping LTV ≤ λ is:

```
x = c − (d − y) / (p · λ)
```

Returns 0 when the formula goes negative. Returns `c` when `d ≤ y` (debt fully covered).

### `borrowAmountForTargetLtv(p, λ, c, x, d)` — borrow to hit λ

```
borrowAmount = max(0, (c + x) · p · λ − d)
```

The additional debt needed so that `newDebt / ((c + x) · p) = λ`. Returns 0 if already at or above λ.

### `repayAmountForTargetLtv(p, λ, c, R, d)` — repay to hit λ after withdrawing R

```
repayAmount = max(0, d − (c − R) · p · λ)
```

The mirror of `borrowAmountForTargetLtv`. Solves for repay given that `R` collateral will be withdrawn. Used by `calculateTargetRepayAmount()` view function.

Returns 0 when already at or below λ. Returns `d` when `R ≥ c`.

### `redepositAmount(p, λ, c, R, d, y)` — surplus to redeploy at LTV λ

After withdrawing `R` collateral and having `y` borrow tokens available:

```
redepositAmt = max(0, (c − R) · p · λ − (d − y))
```

The borrow tokens that should be redeployed to the vault so the position stays exactly at λ. Returns 0 if already under-leveraged relative to λ.

### `flashWithdrawAmount(y, pr, f, pi)` — collateral to withdraw for flash self-liq

Given flash amount `y`, premium rate `pr`, max slippage `f`, and price `pi`:

```
F = WAD · (WAD + pr) / (WAD − f)
x = y · F / WAD · RAY / pi    (ceiling)
```

Result is ceiling-rounded. Returns 0 if price is zero.

### `flashWithdrawAmountFromTargetLtv(ltv, pr, f, c, d, pi)` — collateral to reach target LTV via self-liq

Solves the two-equation system: post-liq LTV equation + flash cost equation simultaneously:

```
numerator   = d · RAY/pi − ltv · c/WAD    (collateral units)
denominator = WAD²/F − ltv               (WAD units)
x           = numerator · WAD / denominator  (ceiling)
```

Returns 0 if position is already at or below `ltv`. Returns `type(uint256).max` if target is unreachable (flash + slippage cost exceeds liquidation gain).

---

## High-level flows

### `deploy(collateralAmount, targetLtvInWad)` — Open / extend leverage

**Tuple change:** `a ↓, c ↑, d ↑, s ↑`

1. **Read state** — capture `price`, `collateralBefore` (= c), `existingDebt` (= d).
2. **Supply** — pull `collateralAmount` from positionOwner and supply to the lender (`a ↓, c ↑`). Skip if amount is 0.
3. **Check post-supply LTV** — compute `minLtv(d, c, x, p)`. If `targetLtv ≤ minLtv`, no borrowing is needed (skip steps 4–5).
4. **Cap to pool liquidity** — `borrowAmount = min(borrowAmountForTargetLtv(...), availablePoolLiquidity)`.
5. **Borrow + deposit** — borrow from the lender (`d ↑`) and deposit into the target vault (`s ↑`). Borrowed tokens transit through the helper; they are not forwarded to positionOwner.

Guards:
- `targetLtvInWad > getMaxLtvInWad()` → reverts `TargetLtvExceedsMaxLtv`.

---

### `retract(repayAmount, withdrawalAmount, maxPermissibleLtv)` — Core unwind primitive

**Tuple change:** `d ↓, c ↓, b ↓ (repay source), a ↑ (withdrawal)`

The operator pulls `repayAmount` borrow tokens directly from positionOwner at the start of the call. The same internal `_retract` logic is reused by `claimAndRetract` and `redeemAndRetract` (where tokens arrive from vault operations within the same transaction).

**Execution order (repay-before-withdraw):**
1. Pull `repayAmount` borrow tokens from positionOwner → this contract.
2. Validate `maxPermissibleLtv ≤ lenderMaxLtv` → reverts `MaxPermissibleLtvExceedsLenderMaxLtv`.
3. If `repayAmount > 0`: assert contract balance ≥ repayAmount (reverts `InsufficientRepayBalance`), then repay at the lender (`d ↓`).
4. If `withdrawalAmount > 0`: compute `xMax = withdrawable(c, d, 0, p, maxPermissibleLtv)`. If `withdrawalAmount > xMax` → reverts `WithdrawalWouldBreachMaxPermissibleLtv`. Otherwise withdraw to positionOwner (`c ↓, a ↑`).

Either amount may be zero. There is no automatic redeployment of surplus borrow tokens — the caller controls all amounts explicitly.

> **Repay-before-withdraw ordering (Aave V3):** Aave evaluates the health factor of the aToken sender at the moment of transfer. Repaying first raises the health factor and prevents revert during the aToken pull.

---

### `claimAndRetract(requestIds, withdrawalAmount, maxPermissibleLtv)` — Claim then retract

**Tuple change:** `q → 0, d ↓, c ↓, a ↑`

1. **Claim** — claim all fulfilled redemption requests. Borrow tokens land in positionOwner's wallet.
2. **Pull** — transfer claimed tokens from positionOwner to this contract.
3. **Retract** — call `_retract(claimed, withdrawalAmount, maxPermissibleLtv)`.

Requires this contract to hold `WITHDRAWAL_MANAGER_ROLE` on the yield vault.

---

### `redeemAndRetract(shares, withdrawalAmount, maxPermissibleLtv)` — Synchronous redeem then retract

**Tuple change:** `s ↓, d ↓, c ↓, a ↑`

Only works when the yield vault queue is **inactive** (synchronous redemption mode). Reverts with `QueueIsActive` if the queue is on.

1. **Redeem** — redeem `shares` from the yield vault synchronously. Assets arrive in this contract.
2. **Retract** — call `_retract(redeemedAmount, withdrawalAmount, maxPermissibleLtv)`.

---

### `selfLiquidate(debtAmount, maxSlippageInWad)` — Flash-loan self-liquidation (fixed debt amount)

**Tuple change:** `c ↓ (net), d ↓`

1. Compute `collateralToWithdraw = flashWithdrawAmount(debtAmount, flashPremium, slippage, price)`.
2. Initiate flash loan for `debtAmount` of borrowToken via the registered `IFlashModule`.
3. In `executeFlash` callback:
   a. Repay `debtAmount` at the lender (tokens already in contract from flash).
   b. Pull `collateralToWithdraw` aTokens from positionOwner and withdraw underlying from lender.
   c. Swap exact-out: collateral → `debtAmount + premium` borrow tokens via `ISwapModule`.
   d. Re-supply any surplus collateral (swap used less than withdrawn) to the lender.
   e. Approve flash module to collect `debtAmount + premium`.

Pass `type(uint256).max` as `debtAmount` to liquidate the entire outstanding debt.

Guards:
- `debtAmount == 0` → reverts `NoDebt`.

---

### `selfLiquidateToLtv(targetLtvInWad, maxSlippageInWad)` — Flash-loan self-liquidation (target LTV)

**Tuple change:** `c ↓ (net), d ↓`

1. Compute `collateralToWithdraw = flashWithdrawAmountFromTargetLtv(targetLtv, premium, slippage, c, d, price)`.
2. Recover flash amount: `y = collateralToWithdraw · price/RAY · WAD/F`.
3. Proceed identically to `selfLiquidate` with the computed amounts.

Guards:
- `collateralToWithdraw == 0` → reverts `TargetLtvTooHigh` (already at or below target).
- `collateralToWithdraw == type(uint256).max` → reverts `SelfLiqCostExceedsLiquidatorBonus`.

---

## Invariants

### Zero-balance invariant

The helper contract holds no token balance at rest. Every external function that moves tokens routes any residual balance back to positionOwner before returning:

- `retract` pulls borrow tokens from positionOwner at the start; after repayment any dust remaining in the contract is swept back.
- After a `withdraw`, collateral tokens are transferred to positionOwner.
- During self-liquidation, surplus collateral after the swap is re-supplied to the lender.

### Repay-before-withdraw ordering (Aave V3)

All unwind operations repay debt **before** transferring position tokens (aTokens) away from positionOwner. Aave V3 evaluates the health factor of the aToken sender at the moment of transfer; repaying first reduces outstanding debt and raises the health factor, preventing an HF-triggered revert.

> Callers operating near the liquidation threshold should be aware that even transferring aTokens can revert if it momentarily breaches the health-factor requirement.

### LTV ordering

```
0 ≤ targetLtv ≤ maxPermissibleLtv ≤ lenderMaxLtv < lenderLiquidationThreshold
```

| Threshold | Meaning |
|---|---|
| `maxPermissibleLtv` | Hard cap passed to retract; no withdrawal may push LTV above this |
| `lenderMaxLtv` | The lender's maximum borrowable LTV for this collateral |
| `lenderLiquidationThreshold` | Breach triggers external (third-party) liquidation |
| `selfLiqThreshold` | Configured buffer below liq threshold; breach triggers self-liquidation |

### Required approvals from positionOwner (Aave V3)

| Operation | Token approved | Mechanism |
|---|---|---|
| `supply` | collateralToken | `approve(helper, type(uint256).max)` |
| `withdraw` / `selfLiquidate` | aToken (collateral reserve) | `approve(helper, type(uint256).max)` |
| `borrow` | variable debt token | `approveDelegation(helper, type(uint256).max)` |
| `repay` | borrowToken | `approve(helper, type(uint256).max)` |
| `requestRedemptionFromTarget` | yield vault shares | `approve(helper, type(uint256).max)` |
| `cancelRedemptionRequestFromTarget` / `claimRedemptionFromTarget` | — | helper must hold `WITHDRAWAL_MANAGER_ROLE` on vault |

### Decimal encoding invariant

At `initialize()` time the encoded `collateralDecimals` and `borrowDecimals` in the clone's immutable args are validated against `IERC20Metadata(token).decimals()`. Mismatch reverts with `InvalidTokenDecimals`. This prevents price calculations from silently using wrong precision.

---

### Redemption requests and parameter setters

Besides `requestRedemptionFromTarget`, `cancelRedemptionRequestFromTarget` and `claimRedemptionFromTarget`, the operator (`POSITION_OPERATOR_ROLE`) can:
- `updateRedemptionRequestFromTarget(requestIdToCancel, newSharesAmount)`: cancel an outstanding request and submit a new one in one call. For `ConcreteAsyncVaultImpl`, `requestIdToCancel` is the epoch ID. Returns the amount received if the vault processed the redemption atomically (0 otherwise).
- `requestPriorityRedemptionFromTarget(requestId)` / `revokePriorityRedemptionFromTarget(requestId)`: escalate a request to priority status or revoke that. By default this only emits an event for off-chain processing; a subcontract can override it where the vault supports on-chain priority queuing.

The position admin (`POSITION_ADMIN_ROLE`) can change the parameters set at `initialize()`:
- `setHealthyLtvInWad` / `setHealthyLtvDeviationInWad`: centre and half-width of the healthy LTV band
- `setMaxSelfLiquidationSlippageInWad`: maximum swap slippage for self-liquidation
- `setSelfLiqThrBufferInWad`: self-liquidation threshold buffer

## View helpers

| Function | Returns |
|---|---|
| `getPosition()` | `(collateralAmount, debtAmount)` |
| `getCollateralAmount()` | aToken balance of positionOwner |
| `getTokenPair()` | `(collateralToken, borrowToken)` |
| `maxSelfLiquidationSlippageInWad()` | Max allowed self-liquidation slippage (WAD) |
| `getDebtAmount()` | variable debt balance of positionOwner (+ `REPAY_RAY_ROUNDING_BUFFER = 2` if > 0) |
| `getCurrentLtvInWad()` | live LTV from lender account data |
| `getMaxLtvInWad()` | lender protocol max LTV for this collateral |
| `getLiquidationThresholdInWad()` | lender liquidation threshold for this collateral |
| `getBorrowRateInWad()` | current variable borrow rate |
| `getSupplyRateInWad()` | current collateral supply rate |
| `collateralPriceInBorrowTokensInRay()` | price of one collateral token in borrow tokens, in RAY |
| `getAvailablePoolLiquidity()` | idle borrow token liquidity in the lending pool |
| `getFullPosition()` | all of the above in one call |
| `checkApprovals()` | `PositionApprovals` struct — all required approvals/roles in one call |
| `calculateTargetRepayAmount(R, ltv)` | borrow tokens to repay to withdraw `R` collateral and land at `ltv` |

---

## EIP-7201 storage (`PMHStorage`)

Stored at `keccak256(abi.encode(uint256(keccak256("concrete.storage.PositionManagementHelperStorage")) - 1)) & ~bytes32(0xff)`.

| Field | Type | Description |
|---|---|---|
| `yieldVault` | `address` | ERC4626 vault where borrowed funds are deployed |
| `flashModule` | `address` | Flash loan module |
| `swapModule` | `address` | Swap module |
| `selfLiqThrBufferInWad` | `uint64` | WAD buffer below liq threshold triggering self-liq |
| `healthyLtvInWad` | `uint64` | Centre of the healthy LTV band |
| `healthyLtvDeviationInWad` | `uint64` | Half-width of the healthy band |

No `positionOwner` in storage — it is a clone immutable arg.
