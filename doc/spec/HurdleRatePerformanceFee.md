## Overview

Performance fees are charged only on vault yield that exceeds a configurable hurdle rate. The hurdle rate represents the minimum exchange rate (assets per share) the vault must reach before any performance fee activates. This ensures that depositors retain returns up to the agreed-upon benchmark and fees apply exclusively to outperformance.

The performance fee can be set from 0 to 100% (0–10 000 bps).

**Current solution has no high-water mark implemented by design.**

## Hurdle Rate Oracle

Any vault can have a hurdle rate oracle configured by the vault manager via `configure(VaultManagerConfig.HurdleRateOracle, abi.encode(oracle))` (timelocked once the vault's timelock is active; `address(0)` removes it). The oracle implements `IHurdleRateOracle` and exposes two functions:

- `precision()` — the scaling denominator for the rate (always 1e18 for shipped oracles).
- `getHurdleRate()` — returns the minimum assets-per-share threshold at the current timestamp.

Three oracle implementations are provided:

### APR Oracle (`APRRateHurdleOracle`)

Computes continuous compounding from a nominal APR:

```
rate(t) = hurdleFloor * exp(targetAPR * dt / SECONDS_PER_YEAR)
```

A 5% nominal APR yields approximately 5.127% effective annual growth.

### APY Oracle (`APYRateHurdleOracle`)

Computes compound growth targeting an exact APY via the identity:

```
rate(t) = hurdleFloor * exp(ln(1 + targetAPY) * dt / SECONDS_PER_YEAR)
```

A 5% target APY yields exactly 5% after one year.

### Offchain Oracle (`OffchainHurdleRateOracle`)

A minimal oracle whose rate is pushed by a privileged off-chain keeper via `setRate`. No on-chain compounding is performed. Designed for async vaults with discrete NAV updates where the hurdle curve is computed off-chain with arbitrary precision.

The rate has a staleness limit: `getHurdleRate()` reverts with `StaleRate` once the last `setRate` is older than `maxStaleness`. The owner sets the limit via `setMaxStaleness`; the default (and maximum) is 100 years, which effectively disables the check. The vault does not catch this revert, so a stale rate makes yield accrual, and with it every vault operation that accrues yield, revert until the keeper updates the rate. Choose `maxStaleness` with that in mind.

## Validation and Tested Ranges

- On-chain oracles (APR and APY) accept target rates from **0.01% to 25%**.
- Fuzz tested for **0–100 years** of continuous operation.
- Accepted inaccuracy of **0.001%** relative to the Python reference implementation.
- On-chain oracles enforce a maximum target rate cap based on fuzz-tested ranges.

## Fee Accrual Mechanics

When `accrueYield` is called the vault:

1. Sums positive yield and losses across all active strategies.
2. Updates `cachedTotalAssets` with the net yield.
3. Accrues management fees (time-based, independent of hurdle).
4. Accrues the performance fee:
    - Queries the hurdle oracle for the current rate and precision.
    - Computes `hurdleAssets = hurdleRate * (totalSupply + 1) / oraclePrecision`.
    - Derives excess: `excessAboveHurdle = (totalAssets + 1) - hurdleAssets` (zero if at or below hurdle).
    - Caps the taxable yield to `min(netPositiveYield, excessAboveHurdle)`.
    - Mints fee shares to the performance fee recipient for `performanceFee% * cappedYield`.

The `+1` virtual offset mirrors the vault's ERC-4626 share conversion, ensuring the hurdle comparison is consistent with the exchange rate seen by depositors.

When no oracle is configured the full net positive yield is subject to the performance fee (standard behaviour).

## Async Vault Flow

For async vaults where a NAV update is performed off-chain:

1. An off-chain keeper pushes a new NAV update.
2. In the **same batched transaction**, `accrueYield` is called so the hurdle floor is evaluated against the freshest possible NAV, minimising stale-price error.

## Fee Accountant

The `FeeAccountant` contract is the designated performance fee recipient. It holds vault shares and provides a controlled distribution mechanism:

- An authorised backend operator (with `DISTRIBUTOR_ROLE`) calls `distributeFeeShares` to transfer accumulated fee shares to multiple recipients in a single call.
- Recipients and amounts are computed off-chain and passed as arrays.
- Recipients are validated against a whitelist (zero-address check).
- Each individual transfer emits a `FeeTransferred` event; the batch emits a `FeeDistribution` event that includes the vault share price at distribution time.
- Designed to facilitate periodical fee distribution in discrete time intervals, e.g. daily, monthly
