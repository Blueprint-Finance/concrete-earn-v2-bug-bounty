# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.2.0] - 2026-04-14

### Added

- **Hurdle rate oracle system**: Performance fees are now only charged on yield that exceeds a configurable exchange-rate hurdle, preventing fee collection on below-benchmark periods.
  - `IHurdleRateOracle` interface: oracle returns a minimum assets-per-share rate scaled to `precision()`. Vault applies fees only on yield above the hurdle.
  - `APRRateHurdleOracle`: on-chain oracle using continuous compounding (`hurdleFloor × exp(nominalAPR × Δt / year)`). Configurable bounds: 0.1–25% APR.
  - `APYRateHurdleOracle`: on-chain oracle using `exp(ln(1+APY) × Δt / year)` identity for exact compound targeting. Caches `ln(1+APY)` at configuration time. Configurable bounds: 0.1–25% APY.
  - `OffchainHurdleRateOracle`: push-based oracle whose rate is set by the owner off-chain. Reverts on stale data (`StaleRate`) when `block.timestamp > lastUpdateTimestamp + maxStaleness`. Default staleness window is 100 years (effectively unlimited); deployments can tighten it via `setMaxStaleness`.
  - All oracle constructors validate bounds: `hurdleFloor` 0–100×, rate 0.1–25%, non-zero `startTimestamp`.
- **`setHurdleRateOracle(IHurdleRateOracle)` / `getHurdleRateOracle()`** on `ConcreteStandardVaultImpl`: restricted to `VAULT_MANAGER`; triggers yield accrual before the change. Set to `address(0)` to disable hurdle gating. Emits `HurdleRateOracleUpdated`.
- **`FeeAccountant`** (periphery): UUPS-upgradeable contract that receives vault shares as the performance fee recipient and allows `DISTRIBUTOR_ROLE` holders to distribute accumulated shares to a whitelisted set of recipients. Emits per-transfer and aggregate events including the share price at distribution time. Bound to a single ERC-4626 vault at initialization.
- **Architecture diagrams** (`doc/diagrams/`): Excalidraw + SVG diagrams for smart contract architecture and async queue flow.
- **`HurdleRatePerformanceFee.md`** spec document covering oracle mechanics, fee computation, and edge cases.

### Changed

- **Performance fee computation** (`YieldAccrualLib`): when a hurdle oracle is set, net positive yield is capped to the excess above the hurdle (`totalAssets − hurdleRate × (totalSupply + 1) / precision`) before applying the fee rate. The `_previewPerformanceFee` logic is now shared between the view path and the state-mutating accrual path. Virtual share offset (`+1`) is applied consistently to prevent inflation-attack edge cases.
- **`MAX_PERFORMANCE_FEE`** raised from 3,000 bp (30%) to 10,000 bp (100%) to accommodate hurdle-gated fee structures where a higher nominal rate is acceptable because the hurdle already limits fee exposure.
- **`maxDeposit` / `maxMint`**: now return `0` when the remaining capacity below `maxGlobalDepositAmount` is less than `minTxDepositAmount`, preventing deposits that would immediately fail the minimum-amount check.
- **`maxWithdraw` / `maxRedeem`**: now return `0` when the resulting asset amount would be less than `minTxWithdrawAmount`, preventing withdrawals that would immediately fail the minimum-amount check.

### Fixed

- **Audit remediations** (CONC-3308 — hurdle rate audit):
  - `OffchainHurdleRateOracle` staleness check added; `getHurdleRate` reverts with `StaleRate` if the stored rate has not been refreshed within `maxStaleness`.
  - `maxDeposit` / `maxMint` / `maxWithdraw` / `maxRedeem` now account for minimum transaction amounts, closing a gap where ERC-4626 preview functions could return amounts that the vault would then reject.
  - Virtual total assets alignment: `_capNetYieldToExcessAboveHurdleRate` applies `+1` to both sides of the comparison, matching the virtual share used in share-price calculations.

## [1.1.0] - 2025-02-xx

### Added

- **Contract ID system** (`ContractIdEncoding`, `IContractId`): Each contract implementation now exposes a pure `ID() returns (uint64)` encoding contract type, flavour, and semantic version. All concrete vault and strategy implementations override it with their own hardcoded ID.
- **`ROLE_ADMIN`** (vault and strategy): Single unified role admin replacing all legacy per-role admin roles. Administered by itself.
- **`PAUSER` role** (vault and strategy): Dedicated role for `pause()` / `unpause()`. Previously conflated with vault manager / strategy admin.
- **`PRIORITY_WITHDRAWAL_EXECUTOR` role**: Authorises immediate fulfilment of queued async withdrawal requests outside the epoch cycle.
- **`claimPriorityWithdrawal(user, sharesToFulfil, unwindCost, strategy)`** on `ConcreteAsyncVaultImpl`: Burns shares, transfers net assets to the user, and calls `IAsyncAccounting.adjustTotalAssets(-unwindCost)` on the strategy so the next yield accrual reconciles cleanly.
- **`IAsyncAccounting` interface**: Exposes `adjustTotalAssets(int256 diff)` for vault-initiated accounting adjustments on strategies. Implemented by `MultisigStrategy`.
- **Unwind cost cap** (`setUnwindCostCap` / `getUnwindCostCap`): Basis-point cap on unwind cost passed to `claimPriorityWithdrawal` (default 500 bp = 5%).
- **`HookContainer`**: Standalone non-upgradeable contract implementing `IHook` that dispatches to up to 6 registered sub-hooks. Managed by `HOOK_MANAGER_ROLE`. Execution order is not stable (swap-and-pop removal).
- **`HookContainerStorageLib`**: EIP-7201 namespaced storage for `HookContainer`.
- **`AccessControlDefaultAdminRulesEnumerable`** (non-upgradeable) and **`AccessControlDefaultAdminRulesEnumerableUpgradeable`**: Base contracts combining OZ `AccessControlDefaultAdminRules` and `AccessControlEnumerable`.
- **`LegacyAdminRolesLib`**: Enumerates all deprecated per-role admin roles for use during migration.
- **`RoleMigrationLib`**: Migration library called on vault upgrade; promotes first `VAULT_MANAGER_ADMIN` to `ROLE_ADMIN`, rewires role admin relationships, revokes legacy admin roles.
- **`DefaultEnforcedVaultConfigStorageLib`** / **`IDefaultEnforcedVaultConfiguration`**: Factory-held default management and performance fee recipients injected into every new vault at deployment time.
- **`BaseLoopingHelperLib`**: External library (DELEGATECALL) holding heavy preview and lender-module-setter logic extracted from `BaseLoopingStrategy` to reduce bytecode size.
- **`onlyAdminOrOperatorWhenNotPaused` modifier** on `BaseLoopingStrategy`: Allows `STRATEGY_ADMIN` to act while paused, requires `OPERATOR_ROLE` otherwise.
- **`getHooks()` getter** on `ConcreteStandardVaultImpl`.
- **`HooksLibV1.setFlag(h, flagIndex)`**: Programmatic hook flag setter.
- **`blockImplementationByAddress` / `setMigratableByAddress`** on factory: Address-based convenience wrappers that resolve impl → vault impl ID internally.

### Changed

- **ID-based implementation registry** (factory): Implementations are now registered by their `IContractId.ID()` value via `vaultImplToImplementation: mapping(uint64 => address)`. Old sequential-version `EnumerableSet` retained as `legacyImplementationSet` for backward compatibility.
- **Role system simplified**: Legacy per-role admin roles (`VAULT_MANAGER_ADMIN`, `HOOK_MANAGER_ADMIN`, `STRATEGY_MANAGER_ADMIN`, `ALLOCATOR_ADMIN`, `WITHDRAWAL_MANAGER_ADMIN`, `OPERATOR_ADMIN`, `STRATEGY_ADMIN_ADMIN`) replaced by single `ROLE_ADMIN`.
- **`PeripheryRolesLib`**: Removed `OPERATOR_ADMIN` and `STRATEGY_ADMIN_ADMIN`; added `PAUSER`, `HOOK_MANAGER_ROLE`, `ROLE_ADMIN`.
- **`pause()` / `unpause()`** at vault and strategy level now gated to `PAUSER` role.
- **`whenNotPaused`** added to all critical vault operations (allocate, accrueYield, setHooks, strategy management, epoch lifecycle functions on async vault) and strategy admin functions (setMaxWithdraw, rescueToken, permissionless adjustLeverage).
- **`accrueYield()`** now requires `ALLOCATOR` role and `whenNotPaused`.
- **`adjustLeverage(maxSlippageInWad, targetLtvInWad, setNewTargetLtv)`** migrated from `onlyRole(OPERATOR_ROLE)` to `onlyAdminOrOperatorWhenNotPaused`.
- **`BaseStrategy`** upgraded from `AccessControlUpgradeable` to `AccessControlEnumerableUpgradeable`; now implements `IContractId`.
- **`maxGlobalDepositAmount`** (was `maxDepositAmount`): Semantics changed — now applies to total vault assets globally, not per-transaction.
- **`minTxDepositAmount`** (was `minDepositAmount`), **`maxTxWithdrawAmount`** (was `maxWithdrawAmount`), **`minTxWithdrawAmount`** (was `minWithdrawAmount`): Renames only, semantics unchanged.
- **`maxDeposit` / `maxMint`** on standard vault now call `_previewAccrueYieldAndFees` to return values against the expected post-yield state.
- **`_previewOperation`** on `BaseLoopingStrategy` delegates non-looping path to `BaseLoopingHelperLib.previewOperationNonLooping` and looping path to `BaseLoopingHelperLib.previewOperationLooping`.
- **`_setLenderModule`** on `BaseLoopingStrategy` delegates entirely to `BaseLoopingHelperLib.setLenderModule`.
- **`_checkAndStage`** signature simplified: `currentLtvInWad` removed from parameters and fetched internally.
- **`_supply` / `_withdraw` / `_repay` / `_borrow`** wrappers on `BaseLoopingStrategy`: `virtual` removed.
- **`version()`** on `UpgradeableVault` changed from `external` to `public`.
- **`IUpgradeableVaultLegacy`** extracted as standalone interface for legacy single-argument `upgrade` callers; `IUpgradeableVault` is now self-contained, `IUpgradeableVaultBase` removed.
- **Strategy initialisers** renamed to `__<ContractName>_init(...)` OZ convention; `__BaseStrategy_init` marked `onlyInitializing`.
- **`MultisigStrategy`** now implements `IAsyncAccounting`; `adjustTotalAssets(int256)` callable by bound vault only.

### Deprecated

- `getImplementationByVersion(uint64 version)` — still functional; new code should use `getImplementationByVaultImpl(uint64)`.
- All `*_ADMIN` roles (`VAULT_MANAGER_ADMIN`, `HOOK_MANAGER_ADMIN`, etc.) — superseded by `ROLE_ADMIN`; revoked automatically on upgrade via `RoleMigrationLib`.


## [1.0.6] - 2025-02-06

### Added

- **Looping Strategy System** - Comprehensive leveraged strategy implementation using flash loans
  - `BaseLoopingStrategy` - Base contract for looping strategies with leverage management
  - `ConcreteStandardLoopingStrategy` - Standard looping strategy implementation
  - `LoopingPrimitive` - Core primitive contract for atomic leverage/deleverage operations using flash loans
  - Modular architecture supporting pluggable lender, flash, and swap modules
  - Four operational modes:
    - Allocate and loop supply (wind up) - Increases leverage when allocating funds
    - Allocate and loop repay (wind down) - Decreases LTV while allocating funds
    - Deallocate and loop supply (wind up) - Increases LTV while deallocating funds
    - Deallocate and loop repay (wind down) - Decreases leverage when deallocating funds
  - Automatic mode selection based on target LTV and current position state
  - Permissionless leverage adjustment when LTV falls outside acceptable bounds
  - Permissioned leverage adjustment with custom target LTV and slippage parameters
  - Emergency unwinding capability (set target LTV to 0 for full position unwinding)
  - Looping can be enabled/disabled dynamically, allowing strategies to operate as simple lender strategies
  - Comprehensive preview functions for operations, slippage, and costs
  - Surplus staging mechanism to prevent inflation attacks from swap rounding and favorable slippage

- **Lender Module System** - Modular integration with lending protocols
  - `ILenderModule` interface for standardized lender interactions
  - `ILenderStaging` interface for surplus fund management
  - `AaveV3LenderAdapter` - Aave V3 lending protocol adapter
  - `LenderModuleAaveV3` - Aave V3 lender module implementation
  - Support for supplying, withdrawing, borrowing, and repaying operations
  - Staged liquidity management for surplus funds from swaps
  - Lender module substitution capability (can change lender modules while maintaining position)

- **Flash Module System** - Flash loan integration
  - `IFlashModule` interface for flash loan providers
  - `FlashModuleAaveV3` - Aave V3 flash loan module implementation
  - Dynamic flash premium calculation based on liquidity depth
  - Flash liquidity checks to ensure operations can complete

- **Swap Module System** - DEX integration for token swaps
  - `ISwapModule` interface for swap providers
  - `UniV3Swapper` - Uniswap V3 swap module implementation (currently only a mock, but in audit)
  - Support for exact-in and exact-out swap operations
  - Slippage protection with configurable maximum slippage

- **Looping Strategy Features**:
  - LTV (Loan-to-Value) bounds management with configurable target LTV and deviation
  - Zero borrow token balance invariant - strategy never holds debt tokens at transaction end
  - Zero collateral token balance invariant - all collateral is either supplied, staged, or withdrawn
  - Position accounting with three distinct asset locations: lender position, floating amount (only transiently non-zero), and staged amount
  - Max withdraw/deallocate calculations accounting for flash liquidity and lender liquidity constraints
  - Invalid LTV detection for edge cases where plain withdrawals are not possible
  - Comprehensive error reporting with detailed error information for debugging

- **Preview and View Functions**:
  - `previewOperation()` - Preview any operation (allocation, deallocation, withdrawal) with slippage and cost estimates
  - `maxWithdrawable()` - Calculate maximum withdrawable amount given liquidity constraints
  - `maxDeallocate()` - Calculate maximum deallocatable amount
  - `totalAssets()` - Position value accounting for unwinding costs
  - `checkLeverageCondition()` - Check if leverage adjustment is needed and possible

- **Administrative Functions**:
  - `enableLooping()` - Enable looping functionality with configuration parameters
  - `disableLooping()` - Disable looping and revert to simple lender strategy (requires zero debt)
  - `setTargetLtvAndDeviation()` - Update target LTV and deviation parameters
  - `setMaxSlippage()` - Update maximum allowed slippage for swaps
  - `adjustLeverage()` - Permissionless or permissioned leverage adjustment
  - `setLenderModule()` - Change lender module (requires previous module to have no funds)
  - `setFlashModule()` - Update flash loan provider
  - `setSwapModule()` - Update swap provider
  - `rescueFunds()` - Emergency function to recover stuck tokens

- **Documentation**:
  - Complete technical specification (`ConcreteLoopingStrategy.md`) covering:
    - Architecture and design principles
    - Operational flows and state transitions
    - Mathematical formulas for all four looping modes
    - Invariants and safety guarantees
    - Rounding considerations and edge cases
    - Lifecycle management and recommended workflows
  - Comprehensive audit remediation report documenting all findings and fixes

### Fixed

- **Audit Remediations** (from preliminary audit report):
  - Fixed missing return statement in `_adjustLtvBoundsIfWithdrawEntirePosition()` preventing target LTV persistence during full withdrawals
  - Remediated DoS vulnerability in `disableLooping()` by checking active debt instead of token balance
  - Fixed incorrect argument order in `maxWithdrawableGivenLiquidityDepth()` when target LTV is zero
  - Added explicit `InsufficientSwapOutput` error for better debugging when swap output is insufficient
  - Improved invalid LTV detection with explicit `isInvalid` flag instead of sentinel value
  - Removed redundant looping state check in `adjustLeverage()` for better code clarity
  - Added guard for zero flash amount to skip unnecessary flash loan operations
  - Added defense-in-depth validation for floating amount invariants
  - Improved staged liquidity accounting in equity calculations
  - Enhanced error messaging throughout the codebase

- **Code Quality Improvements**:
  - Added staged liquidity to equity calculations in `previewOperation()` for accurate total assets reporting
  - Refactored `_prepareLoopParams()` for better code organization
  - Improved `isMaxWithdraw` detection to handle zero target LTV scenarios
  - Added buffer to `AaveV3LenderAdapter.getDebtAmount()` to ensure complete debt repayment
  - Added `rescueToken()` function to `AaveV3LenderAdapter` for emergency token recovery
  - Removed unused flag documentation from `LoopModality`
  - Improved code comments and documentation throughout

### Changed

- Package name changed from `@blueprint-finance/earn-v2-core` to `@concrete-xyz/earn-v2-core`

### Security

- All looping strategy code has undergone a security audit by Halborn
- Comprehensive test coverage including unit tests, fuzz tests, and end-to-end scenario tests
- Multiple layers of safety checks and invariants enforced
- Defense-in-depth validations added throughout the codebase

## [1.0.2] - 2025-11-28

### Added

- `unbackedMint` functionality for vault migration in `ConcreteBridgedStandardVaultImpl` and `ConcreteBridgedAsyncVaultImpl`
  - Enables minting vault shares without depositing underlying assets
  - Designed for cross-chain vault migrations and migration from old vaults to new vaults
  - Restricted to `VAULT_MANAGER` role and only available during initial mint (when totalSupply is zero)
  - Requires deposit limits to be set to zero
  - Assets backing newly minted shares are expected to be allocated directly at the strategy level

## [1.0.1] - 2025-11-27

### Added

- `WhitelistUserDepositHook` - Access control hook for restricting deposits and mints to whitelisted users only
  - Batch whitelist/unwhitelist functionality
  - Owner-controlled whitelist management
  - Integration with existing user deposit cap functionality

## [1.0.0] - 2025-11-04

### Added

- Factory-based permissionless vault deployment system with version management
- ERC4626 multi-strategy vault implementations:
  - `ConcreteStandardVaultImpl` - Standard multi-strategy vault
  - `ConcreteAsyncVaultImpl` - Vault with queue-based async withdrawals
  - `ConcreteBridgedAsyncVaultImpl` - Cross-chain vault support
  - `ConcretePreDepositVaultImpl` - Pre-deposit vault functionality
- Allocation module for optimized fund distribution across multiple strategies
- Comprehensive fee management system:
  - Management fees
  - Performance fees
  - Configurable fee recipients
  - `TwoWayFeeSplitter` for fee distribution
- Async withdrawal queue system for improved liquidity management
- UUPS proxy pattern for upgradeable vaults and factory
- Hooks system for custom validation logic at vault operation points
- Strategy implementations:
  - `BaseStrategy` - Base strategy contract
  - `SimpleStrategy` - Simple strategy with direct fund management
  - `MultisigStrategy` - Strategy with multisig forwarding
- Comprehensive testing suite:
  - Unit tests for core and periphery
  - Fuzz testing
  - Invariant testing
  - End-to-end scenario tests
- Complete documentation:
  - Architecture guide
  - Testing guide
  - ConcreteAsyncVaultImpl technical specification
- Audit reports for Standard Vault, Async Vault, and Hooks system
- Ethereum Mainnet deployment support (Chain ID: 1)
- Arbitrum deployment support (Chain ID: 42161)

[1.2.0]: https://www.npmjs.com/package/@concrete-xyz/earn-v2-core/v/1.2.0
[1.1.0]: https://www.npmjs.com/package/@concrete-xyz/earn-v2-core/v/1.1.0
[1.0.6]: https://www.npmjs.com/package/@concrete-xyz/earn-v2-core/v/1.0.6
[1.0.2]: https://www.npmjs.com/package/@blueprint-finance/earn-v2-core/v/1.0.2
[1.0.1]: https://www.npmjs.com/package/@blueprint-finance/earn-v2-core/v/1.0.1
[1.0.0]: https://www.npmjs.com/package/@blueprint-finance/earn-v2-core/v/1.0.0

