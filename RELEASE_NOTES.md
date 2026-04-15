# Release Notes

## Version 1.2.0

This release introduces a hurdle rate oracle system that gates performance fees on above-benchmark yield, a fee distribution contract, and a set of audit remediations.

---

### 1. Hurdle Rate Performance Fees

Performance fees can now be tied to an exchange-rate hurdle: the vault only charges fees on yield that pushes the share price above the configured threshold. This prevents fee extraction during periods where the vault underperforms its benchmark.

Three oracle implementations are provided:

- **`APRRateHurdleOracle`** — on-chain continuous compounding using a nominal APR (`hurdleFloor × exp(APR × Δt / year)`).
- **`APYRateHurdleOracle`** — on-chain compound growth targeting an exact APY via the `exp(ln(1+APY) × Δt / year)` identity. Caches the log factor at configuration time.
- **`OffchainHurdleRateOracle`** — push-based oracle whose rate is updated by the owner off-chain. Reverts with `StaleRate` if the stored rate has not been refreshed within `maxStaleness` (configurable; defaults to 100 years).

All oracles enforce input bounds: floor 0–100×, rate 0.1–25%, non-zero start timestamp.

`ConcreteStandardVaultImpl` gains `setHurdleRateOracle` / `getHurdleRateOracle`, restricted to `VAULT_MANAGER`. Setting the oracle to `address(0)` reverts to flat performance fees. A yield accrual is forced before any oracle change takes effect.

---

### 2. FeeAccountant

A new UUPS-upgradeable `FeeAccountant` contract can be set as the vault's performance fee recipient. It accumulates vault shares and lets `DISTRIBUTOR_ROLE` holders distribute them to a whitelisted set of addresses in a single call. Each distribution emits per-transfer events and an aggregate event that includes the share price at the time of distribution.

---

### 3. Max Deposit / Withdraw Now Respect Minimum Amounts

`maxDeposit`, `maxMint`, `maxWithdraw`, and `maxRedeem` now return `0` when the available capacity or resulting asset amount falls below the configured minimum transaction amount. This closes a gap where the ERC-4626 preview functions could return values the vault would immediately reject.

---

### 4. Performance Fee Cap Raised

`MAX_PERFORMANCE_FEE` has been raised from 3,000 bp (30%) to 10,000 bp (100%). With a hurdle oracle in place, a higher nominal fee rate is practical because the hurdle already limits fee exposure to genuine above-benchmark returns.

---

### 5. Audit Remediations (CONC-3308)

- `OffchainHurdleRateOracle` staleness check: `getHurdleRate` reverts when the stored rate has not been updated within `maxStaleness`.
- Minimum-amount enforcement in ERC-4626 preview functions (see §3 above).
- Virtual `+1` alignment in the hurdle cap computation to match the virtual share used in share-price calculations.
